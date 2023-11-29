//! Renderer implementation for Metal.
//!
//! Open questions:
//!
pub const Metal = @This();

const std = @import("std");
const builtin = @import("builtin");
const glfw = @import("glfw");
const objc = @import("objc");
const macos = @import("macos");
const imgui = @import("imgui");
const glslang = @import("glslang");
const apprt = @import("../apprt.zig");
const configpkg = @import("../config.zig");
const font = @import("../font/main.zig");
const terminal = @import("../terminal/main.zig");
const renderer = @import("../renderer.zig");
const math = @import("../math.zig");
const Surface = @import("../Surface.zig");
const link = @import("link.zig");
const shadertoy = @import("shadertoy.zig");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Terminal = terminal.Terminal;

const mtl = @import("metal/api.zig");
const mtl_buffer = @import("metal/buffer.zig");
const mtl_image = @import("metal/image.zig");
const mtl_sampler = @import("metal/sampler.zig");
const mtl_shaders = @import("metal/shaders.zig");
const Image = mtl_image.Image;
const ImageMap = mtl_image.ImageMap;
const Shaders = mtl_shaders.Shaders;

const CellBuffer = mtl_buffer.Buffer(mtl_shaders.Cell);
const ImageBuffer = mtl_buffer.Buffer(mtl_shaders.Image);
const InstanceBuffer = mtl_buffer.Buffer(u16);

const ImagePlacementList = std.ArrayListUnmanaged(mtl_image.Placement);

// Get native API access on certain platforms so we can do more customization.
const glfwNative = glfw.Native(.{
    .cocoa = builtin.os.tag == .macos,
});

const log = std.log.scoped(.metal);

/// Allocator that can be used
alloc: std.mem.Allocator,

/// The configuration we need derived from the main config.
config: DerivedConfig,

/// The mailbox for communicating with the window.
surface_mailbox: apprt.surface.Mailbox,

/// Current cell dimensions for this grid.
cell_size: renderer.CellSize,

/// Current screen size dimensions for this grid. This is set on the first
/// resize event, and is not immediately available.
screen_size: ?renderer.ScreenSize,

/// Explicit padding.
padding: renderer.Options.Padding,

/// True if the window is focused
focused: bool,

/// The actual foreground color. May differ from the config foreground color if
/// changed by a terminal application
foreground_color: terminal.color.RGB,

/// The actual background color. May differ from the config background color if
/// changed by a terminal application
background_color: terminal.color.RGB,

/// The actual cursor color. May differ from the config cursor color if changed
/// by a terminal application
cursor_color: ?terminal.color.RGB,

/// The current frame background color. This is only updated during
/// the updateFrame method.
current_background_color: terminal.color.RGB,

/// The current set of cells to render. This is rebuilt on every frame
/// but we keep this around so that we don't reallocate. Each set of
/// cells goes into a separate shader.
cells_bg: std.ArrayListUnmanaged(mtl_shaders.Cell),
cells: std.ArrayListUnmanaged(mtl_shaders.Cell),

/// The current GPU uniform values.
uniforms: mtl_shaders.Uniforms,

/// The font structures.
font_group: *font.GroupCache,
font_shaper: font.Shaper,

/// The images that we may render.
images: ImageMap = .{},
image_placements: ImagePlacementList = .{},
image_bg_end: u32 = 0,
image_text_end: u32 = 0,

/// Metal state
shaders: Shaders, // Compiled shaders
buf_cells: CellBuffer, // Vertex buffer for cells
buf_cells_bg: CellBuffer, // Vertex buffer for background cells
buf_instance: InstanceBuffer, // MTLBuffer

/// Metal objects
device: objc.Object, // MTLDevice
queue: objc.Object, // MTLCommandQueue
swapchain: objc.Object, // CAMetalLayer
texture_greyscale: objc.Object, // MTLTexture
texture_color: objc.Object, // MTLTexture

/// Custom shader state. This is only set if we have custom shaders.
custom_shader_state: ?CustomShaderState = null,

pub const CustomShaderState = struct {
    /// The screen texture that we render the terminal to. If we don't have
    /// custom shaders, we render directly to the drawable.
    screen_texture: objc.Object, // MTLTexture
    sampler: mtl_sampler.Sampler,
    uniforms: mtl_shaders.PostUniforms,
    last_frame_time: std.time.Instant,

    pub fn deinit(self: *CustomShaderState) void {
        deinitMTLResource(self.screen_texture);
        self.sampler.deinit();
    }
};

/// The configuration for this renderer that is derived from the main
/// configuration. This must be exported so that we don't need to
/// pass around Config pointers which makes memory management a pain.
pub const DerivedConfig = struct {
    arena: ArenaAllocator,

    font_thicken: bool,
    font_features: std.ArrayListUnmanaged([]const u8),
    font_styles: font.Group.StyleStatus,
    cursor_color: ?terminal.color.RGB,
    cursor_opacity: f64,
    cursor_text: ?terminal.color.RGB,
    background: terminal.color.RGB,
    background_opacity: f64,
    foreground: terminal.color.RGB,
    selection_background: ?terminal.color.RGB,
    selection_foreground: ?terminal.color.RGB,
    invert_selection_fg_bg: bool,
    custom_shaders: std.ArrayListUnmanaged([]const u8),
    custom_shader_animation: bool,
    links: link.Set,

    pub fn init(
        alloc_gpa: Allocator,
        config: *const configpkg.Config,
    ) !DerivedConfig {
        var arena = ArenaAllocator.init(alloc_gpa);
        errdefer arena.deinit();
        const alloc = arena.allocator();

        // Copy our shaders
        const custom_shaders = try config.@"custom-shader".value.list.clone(alloc);

        // Copy our font features
        const font_features = try config.@"font-feature".list.clone(alloc);

        // Get our font styles
        var font_styles = font.Group.StyleStatus.initFill(true);
        font_styles.set(.bold, config.@"font-style-bold" != .false);
        font_styles.set(.italic, config.@"font-style-italic" != .false);
        font_styles.set(.bold_italic, config.@"font-style-bold-italic" != .false);

        // Our link configs
        const links = try link.Set.fromConfig(
            alloc,
            config.link.links.items,
        );

        return .{
            .background_opacity = @max(0, @min(1, config.@"background-opacity")),
            .font_thicken = config.@"font-thicken",
            .font_features = font_features,
            .font_styles = font_styles,

            .cursor_color = if (config.@"cursor-color") |col|
                col.toTerminalRGB()
            else
                null,

            .cursor_text = if (config.@"cursor-text") |txt|
                txt.toTerminalRGB()
            else
                null,

            .cursor_opacity = @max(0, @min(1, config.@"cursor-opacity")),

            .background = config.background.toTerminalRGB(),
            .foreground = config.foreground.toTerminalRGB(),
            .invert_selection_fg_bg = config.@"selection-invert-fg-bg",

            .selection_background = if (config.@"selection-background") |bg|
                bg.toTerminalRGB()
            else
                null,

            .selection_foreground = if (config.@"selection-foreground") |bg|
                bg.toTerminalRGB()
            else
                null,

            .custom_shaders = custom_shaders,
            .custom_shader_animation = config.@"custom-shader-animation",
            .links = links,

            .arena = arena,
        };
    }

    pub fn deinit(self: *DerivedConfig) void {
        const alloc = self.arena.allocator();
        self.links.deinit(alloc);
        self.arena.deinit();
    }
};

/// Returns the hints that we want for this
pub fn glfwWindowHints(config: *const configpkg.Config) glfw.Window.Hints {
    return .{
        .client_api = .no_api,
        .transparent_framebuffer = config.@"background-opacity" < 1,
    };
}

/// This is called early right after window creation to setup our
/// window surface as necessary.
pub fn surfaceInit(surface: *apprt.Surface) !void {
    _ = surface;

    // We don't do anything else here because we want to set everything
    // else up during actual initialization.
}

pub fn init(alloc: Allocator, options: renderer.Options) !Metal {
    var arena = ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // Initialize our metal stuff
    const device = objc.Object.fromId(mtl.MTLCreateSystemDefaultDevice());
    const queue = device.msgSend(objc.Object, objc.sel("newCommandQueue"), .{});
    const swapchain = swapchain: {
        const CAMetalLayer = objc.getClass("CAMetalLayer").?;
        const swapchain = CAMetalLayer.msgSend(objc.Object, objc.sel("layer"), .{});
        swapchain.setProperty("device", device.value);
        swapchain.setProperty("opaque", options.config.background_opacity >= 1);

        // disable v-sync
        swapchain.setProperty("displaySyncEnabled", false);

        break :swapchain swapchain;
    };

    // Get our cell metrics based on a regular font ascii 'M'. Why 'M'?
    // Doesn't matter, any normal ASCII will do we're just trying to make
    // sure we use the regular font.
    const metrics = metrics: {
        const index = (try options.font_group.indexForCodepoint(alloc, 'M', .regular, .text)).?;
        const face = try options.font_group.group.faceFromIndex(index);
        break :metrics face.metrics;
    };
    log.debug("cell dimensions={}", .{metrics});

    // Set the sprite font up
    options.font_group.group.sprite = font.sprite.Face{
        .width = metrics.cell_width,
        .height = metrics.cell_height,
        .thickness = metrics.underline_thickness *
            @as(u32, if (options.config.font_thicken) 2 else 1),
        .underline_position = metrics.underline_position,
    };

    // Create the font shaper. We initially create a shaper that can support
    // a width of 160 which is a common width for modern screens to help
    // avoid allocations later.
    var font_shaper = try font.Shaper.init(alloc, .{
        .features = options.config.font_features.items,
    });
    errdefer font_shaper.deinit();

    // Vertex buffers
    var buf_cells = try CellBuffer.init(device, 160 * 160);
    errdefer buf_cells.deinit();
    var buf_cells_bg = try CellBuffer.init(device, 160 * 160);
    errdefer buf_cells_bg.deinit();
    var buf_instance = try InstanceBuffer.initFill(device, &.{
        0, 1, 3, // Top-left triangle
        1, 2, 3, // Bottom-right triangle
    });
    errdefer buf_instance.deinit();

    // Load our custom shaders
    const custom_shaders: []const [:0]const u8 = shadertoy.loadFromFiles(
        arena_alloc,
        options.config.custom_shaders.items,
        .msl,
    ) catch |err| err: {
        log.warn("error loading custom shaders err={}", .{err});
        break :err &.{};
    };

    // If we have custom shaders then setup our state
    var custom_shader_state: ?CustomShaderState = state: {
        if (custom_shaders.len == 0) break :state null;

        // Build our sampler for our texture
        var sampler = try mtl_sampler.Sampler.init(device);
        errdefer sampler.deinit();

        break :state .{
            // Resolution and screen texture will be fixed up by first
            // call to setScreenSize. This happens before any draw call.
            .screen_texture = undefined,
            .sampler = sampler,
            .uniforms = .{
                .resolution = .{ 0, 0, 1 },
                .time = 1,
                .time_delta = 1,
                .frame_rate = 1,
                .frame = 1,
                .channel_time = [1][4]f32{.{ 0, 0, 0, 0 }} ** 4,
                .channel_resolution = [1][4]f32{.{ 0, 0, 0, 0 }} ** 4,
                .mouse = .{ 0, 0, 0, 0 },
                .date = .{ 0, 0, 0, 0 },
                .sample_rate = 1,
            },

            .last_frame_time = try std.time.Instant.now(),
        };
    };
    errdefer if (custom_shader_state) |*state| state.deinit();

    // Initialize our shaders
    var shaders = try Shaders.init(alloc, device, custom_shaders);
    errdefer shaders.deinit(alloc);

    // Font atlas textures
    const texture_greyscale = try initAtlasTexture(device, &options.font_group.atlas_greyscale);
    const texture_color = try initAtlasTexture(device, &options.font_group.atlas_color);

    return Metal{
        .alloc = alloc,
        .config = options.config,
        .surface_mailbox = options.surface_mailbox,
        .cell_size = .{ .width = metrics.cell_width, .height = metrics.cell_height },
        .screen_size = null,
        .padding = options.padding,
        .focused = true,
        .foreground_color = options.config.foreground,
        .background_color = options.config.background,
        .cursor_color = options.config.cursor_color,
        .current_background_color = options.config.background,

        // Render state
        .cells_bg = .{},
        .cells = .{},
        .uniforms = .{
            .projection_matrix = undefined,
            .cell_size = undefined,
            .strikethrough_position = @floatFromInt(metrics.strikethrough_position),
            .strikethrough_thickness = @floatFromInt(metrics.strikethrough_thickness),
        },

        // Fonts
        .font_group = options.font_group,
        .font_shaper = font_shaper,

        // Shaders
        .shaders = shaders,
        .buf_cells = buf_cells,
        .buf_cells_bg = buf_cells_bg,
        .buf_instance = buf_instance,

        // Metal stuff
        .device = device,
        .queue = queue,
        .swapchain = swapchain,
        .texture_greyscale = texture_greyscale,
        .texture_color = texture_color,
        .custom_shader_state = custom_shader_state,
    };
}

pub fn deinit(self: *Metal) void {
    self.cells.deinit(self.alloc);
    self.cells_bg.deinit(self.alloc);

    self.font_shaper.deinit();

    self.config.deinit();

    {
        var it = self.images.iterator();
        while (it.next()) |kv| kv.value_ptr.deinit(self.alloc);
        self.images.deinit(self.alloc);
    }
    self.image_placements.deinit(self.alloc);

    self.buf_cells_bg.deinit();
    self.buf_cells.deinit();
    self.buf_instance.deinit();
    deinitMTLResource(self.texture_greyscale);
    deinitMTLResource(self.texture_color);
    self.queue.msgSend(void, objc.sel("release"), .{});

    if (self.custom_shader_state) |*state| state.deinit();

    self.shaders.deinit(self.alloc);

    self.* = undefined;
}

/// This is called just prior to spinning up the renderer thread for
/// final main thread setup requirements.
pub fn finalizeSurfaceInit(self: *const Metal, surface: *apprt.Surface) !void {
    const Info = struct {
        view: objc.Object,
        scaleFactor: f64,
    };

    // Get the view and scale factor for our surface.
    const info: Info = switch (apprt.runtime) {
        apprt.glfw => info: {
            // Everything in glfw is window-oriented so we grab the backing
            // window, then derive everything from that.
            const nswindow = objc.Object.fromId(glfwNative.getCocoaWindow(surface.window).?);
            const contentView = objc.Object.fromId(nswindow.getProperty(?*anyopaque, "contentView").?);
            const scaleFactor = nswindow.getProperty(macos.graphics.c.CGFloat, "backingScaleFactor");
            break :info .{
                .view = contentView,
                .scaleFactor = scaleFactor,
            };
        },

        apprt.embedded => .{
            .view = surface.nsview,
            .scaleFactor = @floatCast(surface.content_scale.x),
        },

        else => @compileError("unsupported apprt for metal"),
    };

    // Make our view layer-backed with our Metal layer
    info.view.setProperty("layer", self.swapchain.value);
    info.view.setProperty("wantsLayer", true);

    // Ensure that our metal layer has a content scale set to match the
    // scale factor of the window. This avoids magnification issues leading
    // to blurry rendering.
    const layer = info.view.getProperty(objc.Object, "layer");
    layer.setProperty("contentsScale", info.scaleFactor);
}

/// Callback called by renderer.Thread when it begins.
pub fn threadEnter(self: *const Metal, surface: *apprt.Surface) !void {
    _ = self;
    _ = surface;

    // Metal requires no per-thread state.
}

/// Callback called by renderer.Thread when it exits.
pub fn threadExit(self: *const Metal) void {
    _ = self;

    // Metal requires no per-thread state.
}

/// True if our renderer has animations so that a higher frequency
/// timer is used.
pub fn hasAnimations(self: *const Metal) bool {
    return self.custom_shader_state != null and
        self.config.custom_shader_animation;
}

/// Returns the grid size for a given screen size. This is safe to call
/// on any thread.
fn gridSize(self: *Metal) ?renderer.GridSize {
    const screen_size = self.screen_size orelse return null;
    return renderer.GridSize.init(
        screen_size.subPadding(self.padding.explicit),
        self.cell_size,
    );
}

/// Callback when the focus changes for the terminal this is rendering.
///
/// Must be called on the render thread.
pub fn setFocus(self: *Metal, focus: bool) !void {
    self.focused = focus;
}

/// Set the new font size.
///
/// Must be called on the render thread.
pub fn setFontSize(self: *Metal, size: font.face.DesiredSize) !void {
    log.info("set font size={}", .{size});

    // Set our new size, this will also reset our font atlas.
    try self.font_group.setSize(size);

    // Recalculate our metrics
    const metrics = metrics: {
        const index = (try self.font_group.indexForCodepoint(self.alloc, 'M', .regular, .text)).?;
        const face = try self.font_group.group.faceFromIndex(index);
        break :metrics face.metrics;
    };
    const new_cell_size = .{ .width = metrics.cell_width, .height = metrics.cell_height };

    // Update our uniforms
    self.uniforms = .{
        .projection_matrix = self.uniforms.projection_matrix,
        .cell_size = .{
            @floatFromInt(new_cell_size.width),
            @floatFromInt(new_cell_size.height),
        },
        .strikethrough_position = @floatFromInt(metrics.strikethrough_position),
        .strikethrough_thickness = @floatFromInt(metrics.strikethrough_thickness),
    };

    // Recalculate our cell size. If it is the same as before, then we do
    // nothing since the grid size couldn't have possibly changed.
    if (std.meta.eql(self.cell_size, new_cell_size)) return;
    self.cell_size = new_cell_size;

    // Set the sprite font up
    self.font_group.group.sprite = font.sprite.Face{
        .width = self.cell_size.width,
        .height = self.cell_size.height,
        .thickness = metrics.underline_thickness * @as(u32, if (self.config.font_thicken) 2 else 1),
        .underline_position = metrics.underline_position,
    };

    // Notify the window that the cell size changed.
    _ = self.surface_mailbox.push(.{
        .cell_size = new_cell_size,
    }, .{ .forever = {} });
}

/// Update the frame data.
pub fn updateFrame(
    self: *Metal,
    surface: *apprt.Surface,
    state: *renderer.State,
    cursor_blink_visible: bool,
) !void {
    _ = surface;

    // Data we extract out of the critical area.
    const Critical = struct {
        bg: terminal.color.RGB,
        selection: ?terminal.Selection,
        screen: terminal.Screen,
        preedit: ?renderer.State.Preedit,
        cursor_style: ?renderer.CursorStyle,
    };

    // Update all our data as tightly as possible within the mutex.
    var critical: Critical = critical: {
        state.mutex.lock();
        defer state.mutex.unlock();

        // If we're in a synchronized output state, we pause all rendering.
        if (state.terminal.modes.get(.synchronized_output)) {
            log.debug("synchronized output started, skipping render", .{});
            return;
        }

        // Swap bg/fg if the terminal is reversed
        const bg = self.background_color;
        const fg = self.foreground_color;
        defer {
            self.background_color = bg;
            self.foreground_color = fg;
        }
        if (state.terminal.modes.get(.reverse_colors)) {
            self.background_color = fg;
            self.foreground_color = bg;
        }

        // We used to share terminal state, but we've since learned through
        // analysis that it is faster to copy the terminal state than to
        // hold the lock while rebuilding GPU cells.
        const viewport_bottom = state.terminal.screen.viewportIsBottom();
        var screen_copy = if (viewport_bottom) try state.terminal.screen.clone(
            self.alloc,
            .{ .active = 0 },
            .{ .active = state.terminal.rows - 1 },
        ) else try state.terminal.screen.clone(
            self.alloc,
            .{ .viewport = 0 },
            .{ .viewport = state.terminal.rows - 1 },
        );
        errdefer screen_copy.deinit();

        // Convert our selection to viewport points because we copy only
        // the viewport above.
        const selection: ?terminal.Selection = if (state.terminal.screen.selection) |sel|
            sel.toViewport(&state.terminal.screen)
        else
            null;

        // Whether to draw our cursor or not.
        const cursor_style = renderer.cursorStyle(
            state,
            self.focused,
            cursor_blink_visible,
        );

        // If we have Kitty graphics data, we enter a SLOW SLOW SLOW path.
        // We only do this if the Kitty image state is dirty meaning only if
        // it changes.
        if (state.terminal.screen.kitty_images.dirty) {
            try self.prepKittyGraphics(state.terminal);
        }

        break :critical .{
            .bg = self.background_color,
            .selection = selection,
            .screen = screen_copy,
            .preedit = if (cursor_style != null) state.preedit else null,
            .cursor_style = cursor_style,
        };
    };
    defer critical.screen.deinit();

    // Build our GPU cells
    try self.rebuildCells(
        critical.selection,
        &critical.screen,
        critical.preedit,
        critical.cursor_style,
    );

    // Update our background color
    self.current_background_color = critical.bg;

    // Go through our images and see if we need to setup any textures.
    {
        var image_it = self.images.iterator();
        while (image_it.next()) |kv| {
            switch (kv.value_ptr.*) {
                .ready => {},

                .pending_rgb,
                .pending_rgba,
                => try kv.value_ptr.upload(self.alloc, self.device),

                .unload_pending,
                .unload_ready,
                => {
                    kv.value_ptr.deinit(self.alloc);
                    self.images.removeByPtr(kv.key_ptr);
                },
            }
        }
    }
}

/// Draw the frame to the screen.
pub fn drawFrame(self: *Metal, surface: *apprt.Surface) !void {
    _ = surface;

    // If we have custom shaders, update the animation time.
    if (self.custom_shader_state) |*state| {
        const now = std.time.Instant.now() catch state.last_frame_time;
        const since_ns: f32 = @floatFromInt(now.since(state.last_frame_time));
        state.uniforms.time = since_ns / std.time.ns_per_s;
        state.uniforms.time_delta = since_ns / std.time.ns_per_s;
    }

    // @autoreleasepool {}
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    // Get our drawable (CAMetalDrawable)
    const drawable = self.swapchain.msgSend(objc.Object, objc.sel("nextDrawable"), .{});

    // Get our screen texture. If we don't have a dedicated screen texture
    // then we just use the drawable texture.
    const screen_texture = if (self.custom_shader_state) |state|
        state.screen_texture
    else tex: {
        const texture = drawable.msgSend(objc.c.id, objc.sel("texture"), .{});
        break :tex objc.Object.fromId(texture);
    };

    // If our font atlas changed, sync the texture data
    if (self.font_group.atlas_greyscale.modified) {
        try syncAtlasTexture(self.device, &self.font_group.atlas_greyscale, &self.texture_greyscale);
        self.font_group.atlas_greyscale.modified = false;
    }
    if (self.font_group.atlas_color.modified) {
        try syncAtlasTexture(self.device, &self.font_group.atlas_color, &self.texture_color);
        self.font_group.atlas_color.modified = false;
    }

    // Command buffer (MTLCommandBuffer)
    const buffer = self.queue.msgSend(objc.Object, objc.sel("commandBuffer"), .{});

    {
        // MTLRenderPassDescriptor
        const desc = desc: {
            const MTLRenderPassDescriptor = objc.getClass("MTLRenderPassDescriptor").?;
            const desc = MTLRenderPassDescriptor.msgSend(
                objc.Object,
                objc.sel("renderPassDescriptor"),
                .{},
            );

            // Set our color attachment to be our drawable surface.
            const attachments = objc.Object.fromId(desc.getProperty(?*anyopaque, "colorAttachments"));
            {
                const attachment = attachments.msgSend(
                    objc.Object,
                    objc.sel("objectAtIndexedSubscript:"),
                    .{@as(c_ulong, 0)},
                );

                // Texture is a property of CAMetalDrawable but if you run
                // Ghostty in XCode in debug mode it returns a CaptureMTLDrawable
                // which ironically doesn't implement CAMetalDrawable as a
                // property so we just send a message.
                //const texture = drawable.msgSend(objc.c.id, objc.sel("texture"), .{});
                attachment.setProperty("loadAction", @intFromEnum(mtl.MTLLoadAction.clear));
                attachment.setProperty("storeAction", @intFromEnum(mtl.MTLStoreAction.store));
                attachment.setProperty("texture", screen_texture.value);
                attachment.setProperty("clearColor", mtl.MTLClearColor{
                    .red = @as(f32, @floatFromInt(self.current_background_color.r)) / 255,
                    .green = @as(f32, @floatFromInt(self.current_background_color.g)) / 255,
                    .blue = @as(f32, @floatFromInt(self.current_background_color.b)) / 255,
                    .alpha = self.config.background_opacity,
                });
            }

            break :desc desc;
        };

        // MTLRenderCommandEncoder
        const encoder = buffer.msgSend(
            objc.Object,
            objc.sel("renderCommandEncoderWithDescriptor:"),
            .{desc.value},
        );
        defer encoder.msgSend(void, objc.sel("endEncoding"), .{});

        // Draw background images first
        try self.drawImagePlacements(encoder, self.image_placements.items[0..self.image_bg_end]);

        // Then draw background cells
        try self.drawCells(encoder, &self.buf_cells_bg, self.cells_bg);

        // Then draw images under text
        try self.drawImagePlacements(encoder, self.image_placements.items[self.image_bg_end..self.image_text_end]);

        // Then draw fg cells
        try self.drawCells(encoder, &self.buf_cells, self.cells);

        // Then draw remaining images
        try self.drawImagePlacements(encoder, self.image_placements.items[self.image_text_end..]);
    }

    // If we have custom shaders AND we have a screen texture, then we
    // render the custom shaders.
    if (self.custom_shader_state) |state| {
        // MTLRenderPassDescriptor
        const desc = desc: {
            const MTLRenderPassDescriptor = objc.getClass("MTLRenderPassDescriptor").?;
            const desc = MTLRenderPassDescriptor.msgSend(
                objc.Object,
                objc.sel("renderPassDescriptor"),
                .{},
            );

            // Set our color attachment to be our drawable surface.
            const attachments = objc.Object.fromId(desc.getProperty(?*anyopaque, "colorAttachments"));
            {
                const attachment = attachments.msgSend(
                    objc.Object,
                    objc.sel("objectAtIndexedSubscript:"),
                    .{@as(c_ulong, 0)},
                );

                // Texture is a property of CAMetalDrawable but if you run
                // Ghostty in XCode in debug mode it returns a CaptureMTLDrawable
                // which ironically doesn't implement CAMetalDrawable as a
                // property so we just send a message.
                const texture = drawable.msgSend(objc.c.id, objc.sel("texture"), .{});
                attachment.setProperty("loadAction", @intFromEnum(mtl.MTLLoadAction.clear));
                attachment.setProperty("storeAction", @intFromEnum(mtl.MTLStoreAction.store));
                attachment.setProperty("texture", texture);
                attachment.setProperty("clearColor", mtl.MTLClearColor{
                    .red = 0,
                    .green = 0,
                    .blue = 0,
                    .alpha = 1,
                });
            }

            break :desc desc;
        };

        // MTLRenderCommandEncoder
        const encoder = buffer.msgSend(
            objc.Object,
            objc.sel("renderCommandEncoderWithDescriptor:"),
            .{desc.value},
        );
        defer encoder.msgSend(void, objc.sel("endEncoding"), .{});

        for (self.shaders.post_pipelines) |pipeline| {
            try self.drawPostShader(encoder, pipeline, &state);
        }
    }

    buffer.msgSend(void, objc.sel("presentDrawable:"), .{drawable.value});
    buffer.msgSend(void, objc.sel("commit"), .{});
}

fn drawPostShader(
    self: *Metal,
    encoder: objc.Object,
    pipeline: objc.Object,
    state: *const CustomShaderState,
) !void {
    _ = self;

    // Use our custom shader pipeline
    encoder.msgSend(
        void,
        objc.sel("setRenderPipelineState:"),
        .{pipeline.value},
    );

    // Set our sampler
    encoder.msgSend(
        void,
        objc.sel("setFragmentSamplerState:atIndex:"),
        .{ state.sampler.sampler.value, @as(c_ulong, 0) },
    );

    // Set our uniforms
    encoder.msgSend(
        void,
        objc.sel("setFragmentBytes:length:atIndex:"),
        .{
            @as(*const anyopaque, @ptrCast(&state.uniforms)),
            @as(c_ulong, @sizeOf(@TypeOf(state.uniforms))),
            @as(c_ulong, 0),
        },
    );

    // Screen texture
    encoder.msgSend(
        void,
        objc.sel("setFragmentTexture:atIndex:"),
        .{
            state.screen_texture.value,
            @as(c_ulong, 0),
        },
    );

    // Draw!
    encoder.msgSend(
        void,
        objc.sel("drawPrimitives:vertexStart:vertexCount:"),
        .{
            @intFromEnum(mtl.MTLPrimitiveType.triangle_strip),
            @as(c_ulong, 0),
            @as(c_ulong, 4),
        },
    );
}

fn drawImagePlacements(
    self: *Metal,
    encoder: objc.Object,
    placements: []const mtl_image.Placement,
) !void {
    if (placements.len == 0) return;

    // Use our image shader pipeline
    encoder.msgSend(
        void,
        objc.sel("setRenderPipelineState:"),
        .{self.shaders.image_pipeline.value},
    );

    // Set our uniform, which is the only shared buffer
    encoder.msgSend(
        void,
        objc.sel("setVertexBytes:length:atIndex:"),
        .{
            @as(*const anyopaque, @ptrCast(&self.uniforms)),
            @as(c_ulong, @sizeOf(@TypeOf(self.uniforms))),
            @as(c_ulong, 1),
        },
    );

    for (placements) |placement| {
        try self.drawImagePlacement(encoder, placement);
    }
}

fn drawImagePlacement(
    self: *Metal,
    encoder: objc.Object,
    p: mtl_image.Placement,
) !void {
    // Look up the image
    const image = self.images.get(p.image_id) orelse {
        log.warn("image not found for placement image_id={}", .{p.image_id});
        return;
    };

    // Get the texture
    const texture = switch (image) {
        .ready => |t| t,
        else => {
            log.warn("image not ready for placement image_id={}", .{p.image_id});
            return;
        },
    };

    // Create our vertex buffer, which is always exactly one item.
    // future(mitchellh): we can group rendering multiple instances of a single image
    const Buffer = mtl_buffer.Buffer(mtl_shaders.Image);
    var buf = try Buffer.initFill(self.device, &.{.{
        .grid_pos = .{
            @as(f32, @floatFromInt(p.x)),
            @as(f32, @floatFromInt(p.y)),
        },

        .cell_offset = .{
            @as(f32, @floatFromInt(p.cell_offset_x)),
            @as(f32, @floatFromInt(p.cell_offset_y)),
        },

        .source_rect = .{
            @as(f32, @floatFromInt(p.source_x)),
            @as(f32, @floatFromInt(p.source_y)),
            @as(f32, @floatFromInt(p.source_width)),
            @as(f32, @floatFromInt(p.source_height)),
        },

        .dest_size = .{
            @as(f32, @floatFromInt(p.width)),
            @as(f32, @floatFromInt(p.height)),
        },
    }});
    defer buf.deinit();

    // Set our buffer
    encoder.msgSend(
        void,
        objc.sel("setVertexBuffer:offset:atIndex:"),
        .{ buf.buffer.value, @as(c_ulong, 0), @as(c_ulong, 0) },
    );

    // Set our texture
    encoder.msgSend(
        void,
        objc.sel("setVertexTexture:atIndex:"),
        .{
            texture.value,
            @as(c_ulong, 0),
        },
    );
    encoder.msgSend(
        void,
        objc.sel("setFragmentTexture:atIndex:"),
        .{
            texture.value,
            @as(c_ulong, 0),
        },
    );

    // Draw!
    encoder.msgSend(
        void,
        objc.sel("drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:"),
        .{
            @intFromEnum(mtl.MTLPrimitiveType.triangle),
            @as(c_ulong, 6),
            @intFromEnum(mtl.MTLIndexType.uint16),
            self.buf_instance.buffer.value,
            @as(c_ulong, 0),
            @as(c_ulong, 1),
        },
    );

    // log.debug("drawImagePlacement: {}", .{p});
}

/// Loads some set of cell data into our buffer and issues a draw call.
/// This expects all the Metal command encoder state to be setup.
///
/// Future: when we move to multiple shaders, this will go away and
/// we'll have a draw call per-shader.
fn drawCells(
    self: *Metal,
    encoder: objc.Object,
    buf: *CellBuffer,
    cells: std.ArrayListUnmanaged(mtl_shaders.Cell),
) !void {
    if (cells.items.len == 0) return;

    try buf.sync(self.device, cells.items);

    // Use our shader pipeline
    encoder.msgSend(
        void,
        objc.sel("setRenderPipelineState:"),
        .{self.shaders.cell_pipeline.value},
    );

    // Set our buffers
    encoder.msgSend(
        void,
        objc.sel("setVertexBytes:length:atIndex:"),
        .{
            @as(*const anyopaque, @ptrCast(&self.uniforms)),
            @as(c_ulong, @sizeOf(@TypeOf(self.uniforms))),
            @as(c_ulong, 1),
        },
    );
    encoder.msgSend(
        void,
        objc.sel("setFragmentTexture:atIndex:"),
        .{
            self.texture_greyscale.value,
            @as(c_ulong, 0),
        },
    );
    encoder.msgSend(
        void,
        objc.sel("setFragmentTexture:atIndex:"),
        .{
            self.texture_color.value,
            @as(c_ulong, 1),
        },
    );
    encoder.msgSend(
        void,
        objc.sel("setVertexBuffer:offset:atIndex:"),
        .{ buf.buffer.value, @as(c_ulong, 0), @as(c_ulong, 0) },
    );

    encoder.msgSend(
        void,
        objc.sel("drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:"),
        .{
            @intFromEnum(mtl.MTLPrimitiveType.triangle),
            @as(c_ulong, 6),
            @intFromEnum(mtl.MTLIndexType.uint16),
            self.buf_instance.buffer.value,
            @as(c_ulong, 0),
            @as(c_ulong, cells.items.len),
        },
    );
}

/// This goes through the Kitty graphic placements and accumulates the
/// placements we need to render on our viewport. It also ensures that
/// the visible images are loaded on the GPU.
fn prepKittyGraphics(
    self: *Metal,
    t: *terminal.Terminal,
) !void {
    const storage = &t.screen.kitty_images;
    defer storage.dirty = false;

    // We always clear our previous placements no matter what because
    // we rebuild them from scratch.
    self.image_placements.clearRetainingCapacity();

    // Go through our known images and if there are any that are no longer
    // in use then mark them to be freed.
    //
    // This never conflicts with the below because a placement can't
    // reference an image that doesn't exist.
    {
        var it = self.images.iterator();
        while (it.next()) |kv| {
            if (storage.imageById(kv.key_ptr.*) == null) {
                kv.value_ptr.markForUnload();
            }
        }
    }

    // The top-left and bottom-right corners of our viewport in screen
    // points. This lets us determine offsets and containment of placements.
    const top = (terminal.point.Viewport{}).toScreen(&t.screen);
    const bot = (terminal.point.Viewport{
        .x = t.screen.cols - 1,
        .y = t.screen.rows - 1,
    }).toScreen(&t.screen);

    // Go through the placements and ensure the image is loaded on the GPU.
    var it = storage.placements.iterator();
    while (it.next()) |kv| {
        // Find the image in storage
        const p = kv.value_ptr;
        const image = storage.imageById(kv.key_ptr.image_id) orelse {
            log.warn(
                "missing image for placement, ignoring image_id={}",
                .{kv.key_ptr.image_id},
            );
            continue;
        };

        // If the selection isn't within our viewport then skip it.
        const rect = p.rect(image, t);
        if (rect.top_left.y > bot.y) continue;
        if (rect.bottom_right.y < top.y) continue;

        // If the top left is outside the viewport we need to calc an offset
        // so that we render (0, 0) with some offset for the texture.
        const offset_y: u32 = if (rect.top_left.y < t.screen.viewport) offset_y: {
            const offset_cells = t.screen.viewport - rect.top_left.y;
            const offset_pixels = offset_cells * self.cell_size.height;
            break :offset_y @intCast(offset_pixels);
        } else 0;

        // If we already know about this image then do nothing
        const gop = try self.images.getOrPut(self.alloc, kv.key_ptr.image_id);
        if (!gop.found_existing) {
            // Copy the data into the pending state.
            const data = try self.alloc.dupe(u8, image.data);
            errdefer self.alloc.free(data);

            // Store it in the map
            const pending: Image.Pending = .{
                .width = image.width,
                .height = image.height,
                .data = data.ptr,
            };

            gop.value_ptr.* = switch (image.format) {
                .rgb => .{ .pending_rgb = pending },
                .rgba => .{ .pending_rgba = pending },
                .png => unreachable, // should be decoded by now
            };
        }

        // Convert our screen point to a viewport point
        const viewport = p.point.toViewport(&t.screen);

        // Calculate the source rectangle
        const source_x = @min(image.width, p.source_x);
        const source_y = @min(image.height, p.source_y + offset_y);
        const source_width = if (p.source_width > 0)
            @min(image.width - source_x, p.source_width)
        else
            image.width;
        const source_height = if (p.source_height > 0)
            @min(image.height, p.source_height)
        else
            image.height -| offset_y;

        // Calculate the width/height of our image.
        const dest_width = if (p.columns > 0) p.columns * self.cell_size.width else source_width;
        const dest_height = if (p.rows > 0) p.rows * self.cell_size.height else source_height;

        // Accumulate the placement
        if (image.width > 0 and image.height > 0) {
            try self.image_placements.append(self.alloc, .{
                .image_id = kv.key_ptr.image_id,
                .x = @intCast(p.point.x),
                .y = @intCast(viewport.y),
                .z = p.z,
                .width = dest_width,
                .height = dest_height,
                .cell_offset_x = p.x_offset,
                .cell_offset_y = p.y_offset,
                .source_x = source_x,
                .source_y = source_y,
                .source_width = source_width,
                .source_height = source_height,
            });
        }
    }

    // Sort the placements by their Z value.
    std.mem.sortUnstable(
        mtl_image.Placement,
        self.image_placements.items,
        {},
        struct {
            fn lessThan(
                ctx: void,
                lhs: mtl_image.Placement,
                rhs: mtl_image.Placement,
            ) bool {
                _ = ctx;
                return lhs.z < rhs.z or (lhs.z == rhs.z and lhs.image_id < rhs.image_id);
            }
        }.lessThan,
    );

    // Find our indices
    self.image_bg_end = 0;
    self.image_text_end = 0;
    const bg_limit = std.math.minInt(i32) / 2;
    for (self.image_placements.items, 0..) |p, i| {
        if (self.image_bg_end == 0 and p.z >= bg_limit) {
            self.image_bg_end = @intCast(i);
        }
        if (self.image_text_end == 0 and p.z >= 0) {
            self.image_text_end = @intCast(i);
        }
    }
    if (self.image_text_end == 0) {
        self.image_text_end = @intCast(self.image_placements.items.len);
    }
}

/// Update the configuration.
pub fn changeConfig(self: *Metal, config: *DerivedConfig) !void {
    // On configuration change we always reset our font group. There
    // are a variety of configurations that can change font settings
    // so to be safe we just always reset it. This has a performance hit
    // when its not necessary but config reloading shouldn't be so
    // common to cause a problem.
    self.font_group.reset();
    self.font_group.group.styles = config.font_styles;
    self.font_group.atlas_greyscale.clear();
    self.font_group.atlas_color.clear();

    // We always redo the font shaper in case font features changed. We
    // could check to see if there was an actual config change but this is
    // easier and rare enough to not cause performance issues.
    {
        var font_shaper = try font.Shaper.init(self.alloc, .{
            .features = config.font_features.items,
        });
        errdefer font_shaper.deinit();
        self.font_shaper.deinit();
        self.font_shaper = font_shaper;
    }

    self.config.deinit();
    self.config = config.*;
}

/// Resize the screen.
pub fn setScreenSize(
    self: *Metal,
    dim: renderer.ScreenSize,
    pad: renderer.Padding,
) !void {
    // Store our sizes
    self.screen_size = dim;
    self.padding.explicit = pad;

    // Recalculate the rows/columns. This can't fail since we just set
    // the screen size above.
    const grid_size = self.gridSize().?;

    // Determine if we need to pad the window. For "auto" padding, we take
    // the leftover amounts on the right/bottom that don't fit a full grid cell
    // and we split them equal across all boundaries.
    const padding = if (self.padding.balance)
        renderer.Padding.balanced(dim, grid_size, self.cell_size)
    else
        self.padding.explicit;
    const padded_dim = dim.subPadding(padding);

    // Set the size of the drawable surface to the bounds
    self.swapchain.setProperty("drawableSize", macos.graphics.Size{
        .width = @floatFromInt(dim.width),
        .height = @floatFromInt(dim.height),
    });

    // Setup our uniforms
    const old = self.uniforms;
    self.uniforms = .{
        .projection_matrix = math.ortho2d(
            -1 * @as(f32, @floatFromInt(padding.left)),
            @floatFromInt(padded_dim.width + padding.right),
            @floatFromInt(padded_dim.height + padding.bottom),
            -1 * @as(f32, @floatFromInt(padding.top)),
        ),
        .cell_size = .{
            @floatFromInt(self.cell_size.width),
            @floatFromInt(self.cell_size.height),
        },
        .strikethrough_position = old.strikethrough_position,
        .strikethrough_thickness = old.strikethrough_thickness,
    };

    // Reset our buffer sizes so that we free memory when the screen shrinks.
    // This could be made more clever by only doing this when the screen
    // shrinks but the performance cost really isn't that much.
    self.cells.clearAndFree(self.alloc);
    self.cells_bg.clearAndFree(self.alloc);

    // If we have custom shaders then we update the state
    if (self.custom_shader_state) |*state| {
        // Only free our previous texture if this isn't our first
        // time setting the custom shader state.
        if (state.uniforms.resolution[0] > 0) {
            deinitMTLResource(state.screen_texture);
        }

        state.uniforms.resolution = .{
            @floatFromInt(dim.width),
            @floatFromInt(dim.height),
            1,
        };

        state.screen_texture = screen_texture: {
            // This texture is the size of our drawable but supports being a
            // render target AND reading so that the custom shaders can read from it.
            const desc = init: {
                const Class = objc.getClass("MTLTextureDescriptor").?;
                const id_alloc = Class.msgSend(objc.Object, objc.sel("alloc"), .{});
                const id_init = id_alloc.msgSend(objc.Object, objc.sel("init"), .{});
                break :init id_init;
            };
            desc.setProperty("pixelFormat", @intFromEnum(mtl.MTLPixelFormat.bgra8unorm));
            desc.setProperty("width", @as(c_ulong, @intCast(dim.width)));
            desc.setProperty("height", @as(c_ulong, @intCast(dim.height)));
            desc.setProperty(
                "usage",
                @intFromEnum(mtl.MTLTextureUsage.render_target) |
                    @intFromEnum(mtl.MTLTextureUsage.shader_read) |
                    @intFromEnum(mtl.MTLTextureUsage.shader_write),
            );

            // If we fail to create the texture, then we just don't have a screen
            // texture and our custom shaders won't run.
            const id = self.device.msgSend(
                ?*anyopaque,
                objc.sel("newTextureWithDescriptor:"),
                .{desc},
            ) orelse return error.MetalFailed;

            break :screen_texture objc.Object.fromId(id);
        };
    }

    log.debug("screen size screen={} grid={}, cell={}", .{ dim, grid_size, self.cell_size });
}

/// Sync all the CPU cells with the GPU state (but still on the CPU here).
/// This builds all our "GPUCells" on this struct, but doesn't send them
/// down to the GPU yet.
fn rebuildCells(
    self: *Metal,
    term_selection: ?terminal.Selection,
    screen: *terminal.Screen,
    preedit: ?renderer.State.Preedit,
    cursor_style_: ?renderer.CursorStyle,
) !void {
    // Bg cells at most will need space for the visible screen size
    self.cells_bg.clearRetainingCapacity();
    try self.cells_bg.ensureTotalCapacity(self.alloc, screen.rows * screen.cols);

    // Over-allocate just to ensure we don't allocate again during loops.
    self.cells.clearRetainingCapacity();
    try self.cells.ensureTotalCapacity(
        self.alloc,

        // * 3 for background modes and cursor and underlines
        // + 1 for cursor
        (screen.rows * screen.cols * 2) + 1,
    );

    // Create an arena for all our temporary allocations while rebuilding
    var arena = ArenaAllocator.init(self.alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // Create our match set for the links.
    var link_match_set = try self.config.links.matchSet(
        arena_alloc,
        screen,
        .{}, // TODO: mouse hover point
    );

    // Determine our x/y range for preedit. We don't want to render anything
    // here because we will render the preedit separately.
    const preedit_range: ?struct {
        y: usize,
        x: [2]usize,
    } = if (preedit) |preedit_v| preedit: {
        break :preedit .{
            .y = screen.cursor.y,
            .x = preedit_v.range(screen.cursor.x, screen.cols - 1),
        };
    } else null;

    // This is the cell that has [mode == .fg] and is underneath our cursor.
    // We keep track of it so that we can invert the colors so the character
    // remains visible.
    var cursor_cell: ?mtl_shaders.Cell = null;

    // Build each cell
    var rowIter = screen.rowIterator(.viewport);
    var y: usize = 0;
    while (rowIter.next()) |row| {
        defer y += 1;

        // True if this is the row with our cursor. There are a lot of conditions
        // here because the reasons we need to know this are primarily to invert.
        //
        //   - If we aren't drawing the cursor then we don't need to change our rendering.
        //   - If the cursor is not visible, then we don't need to change rendering.
        //   - If the cursor style is not a box, then we don't need to change
        //     rendering because it'll never fully overlap a glyph.
        //   - If the viewport is not at the bottom, then we don't need to
        //     change rendering because the cursor is not visible.
        //     (NOTE: this may not be fully correct, we may be scrolled
        //     slightly up and the cursor may be visible)
        //   - If this y doesn't match our cursor y then we don't need to
        //     change rendering.
        //
        const cursor_row = if (cursor_style_) |cursor_style|
            cursor_style == .block and
                screen.viewportIsBottom() and
                y == screen.cursor.y
        else
            false;

        // True if we want to do font shaping around the cursor. We want to
        // do font shaping as long as the cursor is enabled.
        const shape_cursor = screen.viewportIsBottom() and
            y == screen.cursor.y;

        // If this is the row with our cursor, then we may have to modify
        // the cell with the cursor.
        const start_i: usize = self.cells.items.len;
        defer if (cursor_row) {
            // If we're on a wide spacer tail, then we want to look for
            // the previous cell.
            const screen_cell = row.getCell(screen.cursor.x);
            const x = screen.cursor.x - @intFromBool(screen_cell.attrs.wide_spacer_tail);
            for (self.cells.items[start_i..]) |cell| {
                if (cell.grid_pos[0] == @as(f32, @floatFromInt(x)) and
                    (cell.mode == .fg or cell.mode == .fg_color))
                {
                    cursor_cell = cell;
                    break;
                }
            }
        };

        // We need to get this row's selection if there is one for proper
        // run splitting.
        const row_selection = sel: {
            if (term_selection) |sel| {
                const screen_point = (terminal.point.Viewport{
                    .x = 0,
                    .y = y,
                }).toScreen(screen);
                if (sel.containedRow(screen, screen_point)) |row_sel| {
                    break :sel row_sel;
                }
            }

            break :sel null;
        };

        // Split our row into runs and shape each one.
        var iter = self.font_shaper.runIterator(
            self.font_group,
            row,
            row_selection,
            if (shape_cursor) screen.cursor.x else null,
        );
        while (try iter.next(self.alloc)) |run| {
            for (try self.font_shaper.shape(run)) |shaper_cell| {
                // If this cell falls within our preedit range then we skip it.
                // We do this so we don't have conflicting data on the same
                // cell.
                if (preedit_range) |range| {
                    if (range.y == y and
                        shaper_cell.x >= range.x[0] and
                        shaper_cell.x <= range.x[1])
                    {
                        continue;
                    }
                }

                // It this cell is within our hint range then we need to
                // underline it.
                const cell: terminal.Screen.Cell = cell: {
                    var cell = row.getCell(shaper_cell.x);

                    // If our links contain this cell then we want to
                    // underline it.
                    if (link_match_set.orderedContains(.{
                        .x = shaper_cell.x,
                        .y = y,
                    })) {
                        cell.attrs.underline = .single;
                    }

                    break :cell cell;
                };

                if (self.updateCell(
                    term_selection,
                    screen,
                    cell,
                    shaper_cell,
                    run,
                    shaper_cell.x,
                    y,
                )) |update| {
                    assert(update);
                } else |err| {
                    log.warn("error building cell, will be invalid x={} y={}, err={}", .{
                        shaper_cell.x,
                        y,
                        err,
                    });
                }
            }
        }

        // Set row is not dirty anymore
        row.setDirty(false);
    }

    // Add the cursor at the end so that it overlays everything. If we have
    // a cursor cell then we invert the colors on that and add it in so
    // that we can always see it.
    if (cursor_style_) |cursor_style| cursor_style: {
        // If we have a preedit, we try to render the preedit text on top
        // of the cursor.
        if (preedit) |preedit_v| {
            const range = preedit_range.?;
            var x = range.x[0];
            for (preedit_v.codepoints[0..preedit_v.len]) |cp| {
                self.addPreeditCell(cp, x, range.y) catch |err| {
                    log.warn("error building preedit cell, will be invalid x={} y={}, err={}", .{
                        x,
                        range.y,
                        err,
                    });
                };

                x += if (cp.wide) 2 else 1;
            }

            // Preedit hides the cursor
            break :cursor_style;
        }

        _ = self.addCursor(screen, cursor_style);
        if (cursor_cell) |*cell| {
            if (cell.mode == .fg) {
                cell.color = if (self.config.cursor_text) |txt|
                    .{ txt.r, txt.g, txt.b, 255 }
                else
                    .{ 0, 0, 0, 255 };
            }

            self.cells.appendAssumeCapacity(cell.*);
        }
    }

    // Some debug mode safety checks
    if (std.debug.runtime_safety) {
        for (self.cells_bg.items) |cell| assert(cell.mode == .bg);
        for (self.cells.items) |cell| assert(cell.mode != .bg);
    }
}

pub fn updateCell(
    self: *Metal,
    selection: ?terminal.Selection,
    screen: *terminal.Screen,
    cell: terminal.Screen.Cell,
    shaper_cell: font.shape.Cell,
    shaper_run: font.shape.TextRun,
    x: usize,
    y: usize,
) !bool {
    const BgFg = struct {
        /// Background is optional because in un-inverted mode
        /// it may just be equivalent to the default background in
        /// which case we do nothing to save on GPU render time.
        bg: ?terminal.color.RGB,

        /// Fg is always set to some color, though we may not render
        /// any fg if the cell is empty or has no attributes like
        /// underline.
        fg: terminal.color.RGB,
    };

    // True if this cell is selected
    // TODO(perf): we can check in advance if selection is in
    // our viewport at all and not run this on every point.
    const selected: bool = if (selection) |sel| selected: {
        const screen_point = (terminal.point.Viewport{
            .x = x,
            .y = y,
        }).toScreen(screen);

        break :selected sel.contains(screen_point);
    } else false;

    // The colors for the cell.
    const colors: BgFg = colors: {
        // The normal cell result
        const cell_res: BgFg = if (!cell.attrs.inverse) .{
            // In normal mode, background and fg match the cell. We
            // un-optionalize the fg by defaulting to our fg color.
            .bg = if (cell.attrs.has_bg) cell.bg else null,
            .fg = if (cell.attrs.has_fg) cell.fg else self.foreground_color,
        } else .{
            // In inverted mode, the background MUST be set to something
            // (is never null) so it is either the fg or default fg. The
            // fg is either the bg or default background.
            .bg = if (cell.attrs.has_fg) cell.fg else self.foreground_color,
            .fg = if (cell.attrs.has_bg) cell.bg else self.background_color,
        };

        // If we are selected, we our colors are just inverted fg/bg
        const selection_res: ?BgFg = if (selected) .{
            .bg = if (self.config.invert_selection_fg_bg)
                cell_res.fg
            else
                self.config.selection_background orelse self.foreground_color,
            .fg = if (self.config.invert_selection_fg_bg)
                cell_res.bg orelse self.background_color
            else
                self.config.selection_foreground orelse self.background_color,
        } else null;

        // If the cell is "invisible" then we just make fg = bg so that
        // the cell is transparent but still copy-able.
        const res: BgFg = selection_res orelse cell_res;
        if (cell.attrs.invisible) {
            break :colors BgFg{
                .bg = res.bg,
                .fg = res.bg orelse self.background_color,
            };
        }

        break :colors res;
    };

    // Alpha multiplier
    const alpha: u8 = if (cell.attrs.faint) 175 else 255;

    // If the cell has a background, we always draw it.
    if (colors.bg) |rgb| {
        // Determine our background alpha. If we have transparency configured
        // then this is dynamic depending on some situations. This is all
        // in an attempt to make transparency look the best for various
        // situations. See inline comments.
        const bg_alpha: u8 = bg_alpha: {
            const default: u8 = 255;

            if (self.config.background_opacity >= 1) break :bg_alpha default;

            // If we're selected, we do not apply background opacity
            if (selected) break :bg_alpha default;

            // If we're reversed, do not apply background opacity
            if (cell.attrs.inverse) break :bg_alpha default;

            // If we have a background and its not the default background
            // then we apply background opacity
            if (cell.attrs.has_bg and !std.meta.eql(rgb, self.background_color)) {
                break :bg_alpha default;
            }

            // We apply background opacity.
            var bg_alpha: f64 = @floatFromInt(default);
            bg_alpha *= self.config.background_opacity;
            bg_alpha = @ceil(bg_alpha);
            break :bg_alpha @intFromFloat(bg_alpha);
        };

        self.cells_bg.appendAssumeCapacity(.{
            .mode = .bg,
            .grid_pos = .{ @as(f32, @floatFromInt(x)), @as(f32, @floatFromInt(y)) },
            .cell_width = cell.widthLegacy(),
            .color = .{ rgb.r, rgb.g, rgb.b, bg_alpha },
        });
    }

    // If the cell has a character, draw it
    if (cell.char > 0) {
        // Render
        const glyph = try self.font_group.renderGlyph(
            self.alloc,
            shaper_run.font_index,
            shaper_cell.glyph_index,
            .{
                .max_height = @intCast(self.cell_size.height),
                .thicken = self.config.font_thicken,
            },
        );

        // If we're rendering a color font, we use the color atlas
        const presentation = try self.font_group.group.presentationFromIndex(shaper_run.font_index);
        const mode: mtl_shaders.Cell.Mode = switch (presentation) {
            .text => .fg,
            .emoji => .fg_color,
        };

        self.cells.appendAssumeCapacity(.{
            .mode = mode,
            .grid_pos = .{ @as(f32, @floatFromInt(x)), @as(f32, @floatFromInt(y)) },
            .cell_width = cell.widthLegacy(),
            .color = .{ colors.fg.r, colors.fg.g, colors.fg.b, alpha },
            .glyph_pos = .{ glyph.atlas_x, glyph.atlas_y },
            .glyph_size = .{ glyph.width, glyph.height },
            .glyph_offset = .{ glyph.offset_x, glyph.offset_y },
        });
    }

    if (cell.attrs.underline != .none) {
        const sprite: font.Sprite = switch (cell.attrs.underline) {
            .none => unreachable,
            .single => .underline,
            .double => .underline_double,
            .dotted => .underline_dotted,
            .dashed => .underline_dashed,
            .curly => .underline_curly,
        };

        const glyph = try self.font_group.renderGlyph(
            self.alloc,
            font.sprite_index,
            @intFromEnum(sprite),
            .{ .cell_width = if (cell.attrs.wide) 2 else 1 },
        );

        const color = if (cell.attrs.underline_color) cell.underline_fg else colors.fg;

        self.cells.appendAssumeCapacity(.{
            .mode = .fg,
            .grid_pos = .{ @as(f32, @floatFromInt(x)), @as(f32, @floatFromInt(y)) },
            .cell_width = cell.widthLegacy(),
            .color = .{ color.r, color.g, color.b, alpha },
            .glyph_pos = .{ glyph.atlas_x, glyph.atlas_y },
            .glyph_size = .{ glyph.width, glyph.height },
            .glyph_offset = .{ glyph.offset_x, glyph.offset_y },
        });
    }

    if (cell.attrs.strikethrough) {
        self.cells.appendAssumeCapacity(.{
            .mode = .strikethrough,
            .grid_pos = .{ @as(f32, @floatFromInt(x)), @as(f32, @floatFromInt(y)) },
            .cell_width = cell.widthLegacy(),
            .color = .{ colors.fg.r, colors.fg.g, colors.fg.b, alpha },
        });
    }

    return true;
}

fn addCursor(
    self: *Metal,
    screen: *terminal.Screen,
    cursor_style: renderer.CursorStyle,
) ?*const mtl_shaders.Cell {
    // Add the cursor. We render the cursor over the wide character if
    // we're on the wide characer tail.
    const wide, const x = cell: {
        // The cursor goes over the screen cursor position.
        const cell = screen.getCell(
            .active,
            screen.cursor.y,
            screen.cursor.x,
        );
        if (!cell.attrs.wide_spacer_tail or screen.cursor.x == 0)
            break :cell .{ cell.attrs.wide, screen.cursor.x };

        // If we're part of a wide character, we move the cursor back to
        // the actual character.
        break :cell .{ screen.getCell(
            .active,
            screen.cursor.y,
            screen.cursor.x - 1,
        ).attrs.wide, screen.cursor.x - 1 };
    };

    const color = self.cursor_color orelse self.foreground_color;
    const alpha: u8 = if (!self.focused) 255 else alpha: {
        const alpha = 255 * self.config.cursor_opacity;
        break :alpha @intFromFloat(@ceil(alpha));
    };

    const sprite: font.Sprite = switch (cursor_style) {
        .block => .cursor_rect,
        .block_hollow => .cursor_hollow_rect,
        .bar => .cursor_bar,
        .underline => .underline,
    };

    const glyph = self.font_group.renderGlyph(
        self.alloc,
        font.sprite_index,
        @intFromEnum(sprite),
        .{ .cell_width = if (wide) 2 else 1 },
    ) catch |err| {
        log.warn("error rendering cursor glyph err={}", .{err});
        return null;
    };

    self.cells.appendAssumeCapacity(.{
        .mode = .fg,
        .grid_pos = .{
            @as(f32, @floatFromInt(x)),
            @as(f32, @floatFromInt(screen.cursor.y)),
        },
        .cell_width = if (wide) 2 else 1,
        .color = .{ color.r, color.g, color.b, alpha },
        .glyph_pos = .{ glyph.atlas_x, glyph.atlas_y },
        .glyph_size = .{ glyph.width, glyph.height },
        .glyph_offset = .{ glyph.offset_x, glyph.offset_y },
    });

    return &self.cells.items[self.cells.items.len - 1];
}

fn addPreeditCell(
    self: *Metal,
    cp: renderer.State.Preedit.Codepoint,
    x: usize,
    y: usize,
) !void {
    // Preedit is rendered inverted
    const bg = self.foreground_color;
    const fg = self.background_color;

    // Get the font for this codepoint.
    const font_index = if (self.font_group.indexForCodepoint(
        self.alloc,
        @intCast(cp.codepoint),
        .regular,
        .text,
    )) |index| index orelse return else |_| return;

    // Get the font face so we can get the glyph
    const face = self.font_group.group.faceFromIndex(font_index) catch |err| {
        log.warn("error getting face for font_index={} err={}", .{ font_index, err });
        return;
    };

    // Use the face to now get the glyph index
    const glyph_index = face.glyphIndex(@intCast(cp.codepoint)) orelse return;

    // Render the glyph for our preedit text
    const glyph = self.font_group.renderGlyph(
        self.alloc,
        font_index,
        glyph_index,
        .{},
    ) catch |err| {
        log.warn("error rendering preedit glyph err={}", .{err});
        return;
    };

    // Add our opaque background cell
    self.cells_bg.appendAssumeCapacity(.{
        .mode = .bg,
        .grid_pos = .{ @as(f32, @floatFromInt(x)), @as(f32, @floatFromInt(y)) },
        .cell_width = if (cp.wide) 2 else 1,
        .color = .{ bg.r, bg.g, bg.b, 255 },
    });

    // Add our text
    self.cells.appendAssumeCapacity(.{
        .mode = .fg,
        .grid_pos = .{ @as(f32, @floatFromInt(x)), @as(f32, @floatFromInt(y)) },
        .cell_width = if (cp.wide) 2 else 1,
        .color = .{ fg.r, fg.g, fg.b, 255 },
        .glyph_pos = .{ glyph.atlas_x, glyph.atlas_y },
        .glyph_size = .{ glyph.width, glyph.height },
        .glyph_offset = .{ glyph.offset_x, glyph.offset_y },
    });
}

/// Sync the atlas data to the given texture. This copies the bytes
/// associated with the atlas to the given texture. If the atlas no longer
/// fits into the texture, the texture will be resized.
fn syncAtlasTexture(device: objc.Object, atlas: *const font.Atlas, texture: *objc.Object) !void {
    const width = texture.getProperty(c_ulong, "width");
    if (atlas.size > width) {
        // Free our old texture
        deinitMTLResource(texture.*);

        // Reallocate
        texture.* = try initAtlasTexture(device, atlas);
    }

    texture.msgSend(
        void,
        objc.sel("replaceRegion:mipmapLevel:withBytes:bytesPerRow:"),
        .{
            mtl.MTLRegion{
                .origin = .{ .x = 0, .y = 0, .z = 0 },
                .size = .{
                    .width = @intCast(atlas.size),
                    .height = @intCast(atlas.size),
                    .depth = 1,
                },
            },
            @as(c_ulong, 0),
            @as(*const anyopaque, atlas.data.ptr),
            @as(c_ulong, atlas.format.depth() * atlas.size),
        },
    );
}

/// Initialize a MTLTexture object for the given atlas.
fn initAtlasTexture(device: objc.Object, atlas: *const font.Atlas) !objc.Object {
    // Determine our pixel format
    const pixel_format: mtl.MTLPixelFormat = switch (atlas.format) {
        .greyscale => .r8unorm,
        .rgba => .bgra8unorm,
        else => @panic("unsupported atlas format for Metal texture"),
    };

    // Create our descriptor
    const desc = init: {
        const Class = objc.getClass("MTLTextureDescriptor").?;
        const id_alloc = Class.msgSend(objc.Object, objc.sel("alloc"), .{});
        const id_init = id_alloc.msgSend(objc.Object, objc.sel("init"), .{});
        break :init id_init;
    };

    // Set our properties
    desc.setProperty("pixelFormat", @intFromEnum(pixel_format));
    desc.setProperty("width", @as(c_ulong, @intCast(atlas.size)));
    desc.setProperty("height", @as(c_ulong, @intCast(atlas.size)));

    // Initialize
    const id = device.msgSend(
        ?*anyopaque,
        objc.sel("newTextureWithDescriptor:"),
        .{desc},
    ) orelse return error.MetalFailed;

    return objc.Object.fromId(id);
}

/// Deinitialize a metal resource (buffer, texture, etc.) and free the
/// memory associated with it.
fn deinitMTLResource(obj: objc.Object) void {
    obj.msgSend(void, objc.sel("release"), .{});
}
