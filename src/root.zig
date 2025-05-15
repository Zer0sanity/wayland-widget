const std = @import("std");

pub fn getDisplayPath(gpa: std.mem.Allocator) ![]u8 {
    const xdg_runtime_dir_path = try std.process.getEnvVarOwned(gpa, "XDG_RUNTIME_DIR");
    // const xdg_runtime_dir_path = try std.os.getEnvVarOwned(gpa, "XDG_RUNTIME_DIR");
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
