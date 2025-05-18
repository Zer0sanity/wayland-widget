const std = @import("std");
const posix = std.posix;
const lib = @import("wayland_widgit_lib");

pub fn main() !void {
    var general_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = general_allocator.deinit();
    const gpa = general_allocator.allocator();

    const display_path = try lib.getDisplayPath(gpa);
    defer gpa.free(display_path);

    std.log.info("wayland display = {}", .{std.zig.fmtEscapes(display_path)});

    const socket = try std.net.connectUnixSocket(display_path);
    defer socket.close();

    // Now that the socket is open, we are going to construct and send two packets over it. The first packet will get the wl_registry and bind it to an id. The second packet tells the server to send a reply to the client.

    // Wayland messages require knowing the schema before hand. You can see a description of the various protocols here.

    // The first message will be a Request on a wl_display object. Wayland specifies that every connection will automatically get a wl_display object assigned to the id 1.

    const display_id = 1;
    var next_id: u32 = 2;

    // reserve an object id for the registry
    const registry_id = next_id;
    next_id += 1;

    try socket.writeAll(std.mem.sliceAsBytes(&[_]u32{
        // ID of the object; in this case the default wl_display object at 1
        1,

        // The size (in bytes) of the message and the opcode, which is object specific.
        // In this case we are using opcode 1, which corresponds to `wl_display::get_registry`.
        //
        // The size includes the size of the header.
        (0x000C << 16) | (0x0001),

        // Finally, we pass in the only argument that this opcode takes: an id for the `wl_registry`
        // we are creating.
        registry_id,
    }));

    // Now we create the second packet, a wl_display sync request. This will let us loop until the server has finished sending us global object events.
    // create a sync callback so we know when we are caught up with the server
    const registry_done_callback_id = next_id;
    next_id += 1;

    try socket.writeAll(std.mem.sliceAsBytes(&[_]u32{
        display_id,

        // The size (in bytes) of the message and the opcode.
        // In this case we are using opcode 0, which corresponds to `wl_display::sync`.
        //
        // The size includes the size of the header.
        (0x000C << 16) | (0x0000),

        // Finally, we pass in the only argument that this opcode takes: an id for the `wl_registry`
        // we are creating.
        registry_done_callback_id,
    }));

    // create a ArrayList that we will read messages into for the rest of the program
    var message_buffer = std.ArrayList(u8).init(gpa);
    defer message_buffer.deinit();

    // How do we know that the opcode for WL_REGISTRY_REQUEST is 0? Because it is the first `request` in the protocol for `wl_registry`.
    const WL_REGISTRY_REQUEST_BIND = 0;
    // https://wayland.app/protocols/wayland#wl_registry:event:global
    const WL_REGISTRY_EVENT_GLOBAL = 0;
    // The version of the wl_shm protocol we will be targeting.
    const WL_SHM_VERSION = 1;
    // The version of the wl_compositor protocol we will be targeting.
    const WL_COMPOSITOR_VERSION = 5;
    // The version of the xdg_wm_base protocol we will be targeting.
    const XDG_WM_BASE_VERSION = 2;

    var shm_id_opt: ?u32 = null;
    var compositor_id_opt: ?u32 = null;
    var xdg_wm_base_id_opt: ?u32 = null;

    while (true) {
        const event = try lib.Event.read(socket, &message_buffer);

        // Parse event messages based on which object it is for
        if (event.header.object_id == registry_done_callback_id) {
            // No need to parse the message body, there is only one possible opcode
            break;
        }

        if (event.header.object_id == registry_id and event.header.opcode == WL_REGISTRY_EVENT_GLOBAL) {
            // Parse out the fields of the global event
            const name: u32 = @bitCast(event.body[0..4].*);

            const interface_str_len: u32 = @bitCast(event.body[4..8].*);
            // The interface_str is `interface_str_len - 1` because `interface_str_len` includes the null pointer
            const interface_str: [:0]const u8 = event.body[8..][0 .. interface_str_len - 1 :0];

            const interface_str_len_u32_align = std.mem.alignForward(u32, interface_str_len, @alignOf(u32));
            const version: u32 = @bitCast(event.body[8 + interface_str_len_u32_align ..][0..4].*);

            // Check to see if the interface is one of the globals we are looking for
            if (std.mem.eql(u8, interface_str, "wl_shm")) {
                if (version < WL_SHM_VERSION) {
                    std.log.err("compositor supports only {s} version {}, client expected version >= {}", .{ interface_str, version, WL_SHM_VERSION });
                    return error.WaylandInterfaceOutOfDate;
                }
                shm_id_opt = next_id;
                next_id += 1;

                try lib.writeRequest(socket, registry_id, WL_REGISTRY_REQUEST_BIND, &[_]u32{
                    // The numeric name of the global we want to bind.
                    name,

                    // `new_id` arguments have three parts when the sub-type is not specified by the protocol:
                    //   1. A string specifying the textual name of the interface
                    "wl_shm".len + 1, // length of "wl_shm" plus one for the required null byte
                    @bitCast(@as([4]u8, "wl_s".*)),
                    @bitCast(@as([4]u8, "hm\x00\x00".*)), // we have two 0x00 bytes to align the string with u32

                    //   2. The version you are using, affects which functions you can access
                    WL_SHM_VERSION,

                    //   3. And the `new_id` part, where we tell it which client id we are giving it
                    shm_id_opt.?,
                });
            } else if (std.mem.eql(u8, interface_str, "wl_compositor")) {
                if (version < WL_COMPOSITOR_VERSION) {
                    std.log.err("compositor supports only {s} version {}, client expected version >= {}", .{ interface_str, version, WL_COMPOSITOR_VERSION });
                    return error.WaylandInterfaceOutOfDate;
                }
                compositor_id_opt = next_id;
                next_id += 1;

                try lib.writeRequest(socket, registry_id, WL_REGISTRY_REQUEST_BIND, &[_]u32{
                    name,
                    "wl_compositor".len + 1, // add one for the required null byte
                    @bitCast(@as([4]u8, "wl_c".*)),
                    @bitCast(@as([4]u8, "ompo".*)),
                    @bitCast(@as([4]u8, "sito".*)),
                    @bitCast(@as([4]u8, "r\x00\x00\x00".*)),
                    WL_COMPOSITOR_VERSION,
                    compositor_id_opt.?,
                });
            } else if (std.mem.eql(u8, interface_str, "xdg_wm_base")) {
                if (version < XDG_WM_BASE_VERSION) {
                    std.log.err("compositor supports only {s} version {}, client expected version >= {}", .{ interface_str, version, XDG_WM_BASE_VERSION });
                    return error.WaylandInterfaceOutOfDate;
                }
                xdg_wm_base_id_opt = next_id;
                next_id += 1;

                try lib.writeRequest(socket, registry_id, WL_REGISTRY_REQUEST_BIND, &[_]u32{
                    name,
                    "xdg_wm_base".len + 1,
                    @bitCast(@as([4]u8, "xdg_".*)),
                    @bitCast(@as([4]u8, "wm_b".*)),
                    @bitCast(@as([4]u8, "ase\x00".*)),
                    XDG_WM_BASE_VERSION,
                    xdg_wm_base_id_opt.?,
                });
            }
            continue;
        }
    }

    const shm_id = shm_id_opt orelse return error.NeccessaryWaylandExtensionMissing;
    const compositor_id = compositor_id_opt orelse return error.NeccessaryWaylandExtensionMissing;
    const xdg_wm_base_id = xdg_wm_base_id_opt orelse return error.NeccessaryWaylandExtensionMissing;

    std.log.debug("wl_shm client id = {}; wl_compositor client id = {}; xdg_wm_base client id = {}", .{ shm_id, compositor_id, xdg_wm_base_id });

    // Create a surface using wl_compositor::create_surface
    const surface_id = next_id;
    next_id += 1;
    // https://wayland.app/protocols/wayland#wl_compositor:request:create_surface
    const WL_COMPOSITOR_REQUEST_CREATE_SURFACE = 0;
    try lib.writeRequest(socket, compositor_id, WL_COMPOSITOR_REQUEST_CREATE_SURFACE, &[_]u32{
        // id: new_id<wl_surface>
        surface_id,
    });

    // Create an xdg_surface
    const xdg_surface_id = next_id;
    next_id += 1;
    // https://wayland.app/protocols/xdg-shell#xdg_wm_base:request:get_xdg_surface
    const XDG_WM_BASE_REQUEST_GET_XDG_SURFACE = 2;
    try lib.writeRequest(socket, xdg_wm_base_id, XDG_WM_BASE_REQUEST_GET_XDG_SURFACE, &[_]u32{
        // id: new_id<xdg_surface>
        xdg_surface_id,
        // surface: object<wl_surface>
        surface_id,
    });

    // Get the xdg_surface as an xdg_toplevel object
    const xdg_toplevel_id = next_id;
    next_id += 1;
    // https://wayland.app/protocols/xdg-shell#xdg_surface:request:get_toplevel
    const XDG_SURFACE_REQUEST_GET_TOPLEVEL = 1;
    try lib.writeRequest(socket, xdg_surface_id, XDG_SURFACE_REQUEST_GET_TOPLEVEL, &[_]u32{
        // id: new_id<xdg_surface>
        xdg_toplevel_id,
    });

    // Commit the surface. This tells the compositor that the current batch of
    // changes is ready, and they can now be applied.

    // https://wayland.app/protocols/wayland#wl_surface:request:commit
    const WL_SURFACE_REQUEST_COMMIT = 6;
    try lib.writeRequest(socket, surface_id, WL_SURFACE_REQUEST_COMMIT, &[_]u32{});

    while (true) {
        const event = try lib.Event.read(socket, &message_buffer);

        if (event.header.object_id == xdg_surface_id) {
            switch (event.header.opcode) {
                // https://wayland.app/protocols/xdg-shell#xdg_surface:event:configure
                0 => {
                    // This was not in the tutorial, but I found the opcode here
                    // https://doc.servo.org/wayland_protocols/xdg/shell/client/xdg_surface/constant.REQ_ACK_CONFIGURE_OPCODE.html
                    const REQ_ACK_CONFIGURE_OPCODE = 4;

                    // The configure event acts as a heartbeat. Every once in a while the compositor will send us
                    // a `configure` event, and if our application doesn't respond with an `ack_configure` response
                    // it will assume our program has died and destroy the window.
                    const serial: u32 = @bitCast(event.body[0..4].*);

                    //try lib.writeRequest(socket, xdg_surface_id, XDG_SURFACE_REQUEST_ACK_CONFIGURE, &[_]u32{
                    try lib.writeRequest(socket, xdg_surface_id, REQ_ACK_CONFIGURE_OPCODE, &[_]u32{
                        // We respond with the number it sent us, so it knows which configure we are responding to.
                        serial,
                    });

                    try lib.writeRequest(socket, surface_id, WL_SURFACE_REQUEST_COMMIT, &[_]u32{});

                    // The surface has been configured! We can move on
                    break;
                },
                else => return error.InvalidOpcode,
            }
        } else {
            std.log.warn("unknown event {{ .object_id = {}, .opcode = {x}, .message = \"{}\" }}", .{ event.header.object_id, event.header.opcode, std.zig.fmtEscapes(std.mem.sliceAsBytes(event.body)) });
        }
    }

    const Pixel = [4]u8;
    const framebuffer_size = [2]usize{ 128, 128 };
    const shared_memory_pool_len = framebuffer_size[0] * framebuffer_size[1] * @sizeOf(Pixel);
    const shared_memory_pool_fd = posix.memfd_create("my-wayland-framebuffer", 0);
    _ = posix.ftruncate(@intCast(shared_memory_pool_fd), shared_memory_pool_len);

    // Create a wl_shm_pool (wayland shared memory pool). This will be used to create framebuffers,
    // though in this article we only plan on creating one.
    const wl_shm_pool_id = try lib.writeWlShmRequestCreatePool(
        socket,
        shm_id,
        &next_id,
        @intCast(shared_memory_pool_fd),
        @intCast(shared_memory_pool_len),
    );

    // Now we allocate a framebuffer from the shared memory pool
    const wl_buffer_id = next_id;
    next_id += 1;

    // https://wayland.app/protocols/wayland#wl_shm_pool:request:create_buffer
    const WL_SHM_POOL_REQUEST_CREATE_BUFFER = 0;
    // https://wayland.app/protocols/wayland#wl_shm:enum:format
    const WL_SHM_POOL_ENUM_FORMAT_ARGB8888 = 0;
    try lib.writeRequest(socket, wl_shm_pool_id, WL_SHM_POOL_REQUEST_CREATE_BUFFER, &[_]u32{
        // id: new_id<wl_buffer>,
        wl_buffer_id,
        // Byte offset of the framebuffer in the pool. In this case we allocate it at the very start of the file.
        0,
        // Width of the framebuffer.
        framebuffer_size[0],
        // Height of the framebuffer.
        framebuffer_size[1],
        // Stride of the framebuffer, or rather, how many bytes are in a single row of pixels.
        framebuffer_size[0] * @sizeOf(Pixel),
        // The format of the framebuffer. In this case we choose argb8888.
        WL_SHM_POOL_ENUM_FORMAT_ARGB8888,
    });
}
