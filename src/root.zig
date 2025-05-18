const std = @import("std");
const posix = std.posix;

pub fn getDisplayPath(gpa: std.mem.Allocator) ![]u8 {
    const xdg_runtime_dir_path = try std.process.getEnvVarOwned(gpa, "XDG_RUNTIME_DIR");
    defer gpa.free(xdg_runtime_dir_path);
    const display_name = try std.process.getEnvVarOwned(gpa, "WAYLAND_DISPLAY");
    defer gpa.free(display_name);

    return try std.fs.path.join(gpa, &.{ xdg_runtime_dir_path, display_name });
}

/// A wayland packet header
pub const Header = extern struct {
    object_id: u32 align(1),
    opcode: u16 align(1),
    size: u16 align(1),

    pub fn read(socket: std.net.Stream) !Header {
        var header: Header = undefined;
        const header_bytes_read = try socket.readAll(std.mem.asBytes(&header));
        if (header_bytes_read < @sizeOf(Header)) {
            return error.UnexpectedEOF;
        }
        return header;
    }
};

/// This is the general shape of a Wayland `Event` (a message from the compositor to the client).
pub const Event = struct {
    header: Header,
    body: []const u8,

    pub fn read(socket: std.net.Stream, body_buffer: *std.ArrayList(u8)) !Event {
        const header = try Header.read(socket);

        // read bytes until we match the size in the header, not including the bytes in the header.
        try body_buffer.resize(header.size - @sizeOf(Header));
        const message_bytes_read = try socket.readAll(body_buffer.items);
        if (message_bytes_read < body_buffer.items.len) {
            return error.UnexpectedEOF;
        }

        return Event{
            .header = header,
            .body = body_buffer.items,
        };
    }
};

/// Handles creating a header and writing the request to the socket.
pub fn writeRequest(socket: std.net.Stream, object_id: u32, opcode: u16, message: []const u32) !void {
    const message_bytes = std.mem.sliceAsBytes(message);
    const header = Header{
        .object_id = object_id,
        .opcode = opcode,
        .size = @sizeOf(Header) + @as(u16, @intCast(message_bytes.len)),
    };

    try socket.writeAll(std.mem.asBytes(&header));
    try socket.writeAll(message_bytes);
}

/// https://wayland.app/protocols/wayland#wl_shm:request:create_pool
const WL_SHM_REQUEST_CREATE_POOL = 0;

/// This request is more complicated that most other requests, because it has to send the file descriptor to the
/// compositor using a control message.
///
/// Returns the id of the newly create wl_shm_pool
pub fn writeWlShmRequestCreatePool(socket: std.net.Stream, wl_shm_id: u32, next_id: *u32, fd: posix.fd_t, fd_len: i32) !u32 {
    const wl_shm_pool_id = next_id.*;

    const message = [_]u32{
        // id: new_id<wl_shm_pool>
        wl_shm_pool_id,
        // size: int
        @intCast(fd_len),
    };
    // If you're paying close attention, you'll notice that our message only has two parameters in it, despite the
    // documentation calling for 3: wl_shm_pool_id, fd, and size. This is because `fd` is sent in the control message,
    // and so not included in the regular message body.

    // Create the message header as usual
    const message_bytes = std.mem.sliceAsBytes(&message);
    const header = Header{
        .object_id = wl_shm_id,
        .opcode = WL_SHM_REQUEST_CREATE_POOL,
        .size = @sizeOf(Header) + @as(u16, @intCast(message_bytes.len)),
    };
    const header_bytes = std.mem.asBytes(&header);

    // we'll be using `std.os.sendmsg` to send a control message, so we may as well use the vectorized
    // IO to send the header and the message body while we're at it.
    const msg_iov = [_]posix.iovec_const{
        .{
            .base = header_bytes.ptr,
            .len = header_bytes.len,
        },
        .{
            .base = message_bytes.ptr,
            .len = message_bytes.len,
        },
    };

    // Send the file descriptor through a control message

    // This is the control message! It is not a fixed size struct. Instead it varies depending on the message you want to send.
    // C uses macros to define it, here we make a comptime function instead.
    const control_message = cmsg(posix.fd_t){
        .level = posix.SOL.SOCKET,
        .type = 0x01, // value of SCM_RIGHTS
        .data = fd,
    };
    const control_message_bytes = std.mem.asBytes(&control_message);

    const socket_message = posix.msghdr_const{
        .name = null,
        .namelen = 0,
        .iov = &msg_iov,
        .iovlen = msg_iov.len,
        .control = control_message_bytes.ptr,
        // This is the size of the control message in bytes
        .controllen = control_message_bytes.len,
        .flags = 0,
    };

    const bytes_sent = try posix.sendmsg(socket.handle, &socket_message, 0);
    if (bytes_sent < header_bytes.len + message_bytes.len) {
        return error.ConnectionClosed;
    }

    // Wait to increment until we know the message has been sent
    next_id.* += 1;
    return wl_shm_pool_id;
}

fn cmsg(comptime T: type) type {
    const padding_size = (@sizeOf(T) + @sizeOf(c_long) - 1) & ~(@as(usize, @sizeOf(c_long)) - 1);
    return extern struct {
        len: c_ulong = @sizeOf(@This()) - padding_size,
        level: c_int,
        type: c_int,
        data: T,
        _padding: [padding_size]u8 align(1) = [_]u8{0} ** padding_size,
    };
}
