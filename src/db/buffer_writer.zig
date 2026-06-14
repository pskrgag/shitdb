pub const BufferWriter = struct {
    buf: []u8,
    offset: usize,

    pub fn init(buffer: []u8) BufferWriter {
        return .{ .buf = buffer, .offset = 0 };
    }

    pub fn writeAll(self: *BufferWriter, bytes: []const u8) void {
        if (self.offset + bytes.len <= self.buf.len) {
            @memcpy(self.buf[self.offset .. self.offset + bytes.len], bytes);
            self.offset += bytes.len;
        } else {
            @panic("Buffer overflow");
        }
    }
};
