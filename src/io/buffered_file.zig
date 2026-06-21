const std = @import("std");
const Allocator = std.mem.Allocator;
const StatError = std.Io.File.StatError;
const Stat = std.Io.File.Stat;

const BufferSize = 64 << 10;

/// File with automatic buffering
pub const BufferedFile = struct {
    // File handle
    file: std.Io.File,
    // In memory buffer
    buffer: []u8,
    // Filled part of the buffer
    filled: usize,

    const Self = @This();

    pub fn new(file: std.Io.File, alloc: Allocator) !Self {
        return .{ .file = file, .buffer = try alloc.alloc(u8, BufferSize), .filled = 0 };
    }

    pub fn readonly(file: std.Io.File) Self {
        return .{ .file = file, .buffer = @constCast(&[_]u8{}), .filled = 0 };
    }

    pub fn stat(self: *const Self, io: std.Io) StatError!Stat {
        return self.file.stat(io);
    }

    pub fn append(self: *Self, slice: []const u8, io: std.Io) !void {
        std.debug.assert(self.filled <= BufferSize);

        const free_space = BufferSize - self.filled;
        const can_copy = @min(free_space, slice.len);
        @memcpy(self.buffer[self.filled .. self.filled + can_copy], slice[0..can_copy]);
        self.filled += can_copy;

        if (can_copy != slice.len) {
            try self.flush(io);
            return self.append(slice[can_copy..slice.len], io);
        }
    }

    pub fn sync(self: *Self, io: std.Io) !void {
        try self.file.sync(io);
    }

    pub fn flush(self: *Self, io: std.Io) !void {
        try self.file.writeStreamingAll(io, self.buffer[0..self.filled]);
        self.filled = 0;
    }

    pub fn close(self: *Self, alloc: Allocator, io: std.Io) void {
        self.flush(io) catch @panic("Failed to flush file");

        if (self.buffer.len > 0)
            alloc.free(self.buffer);

        self.file.close(io);
    }
};
