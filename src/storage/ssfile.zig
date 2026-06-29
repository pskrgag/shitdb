const std = @import("std");
const Storage = @import("storage.zig").Storage;
const Io = std.Io;

/// File wrapper for sstable file.
pub const SSTableFile = struct {
    file: std.Io.File,
    lvl: u8,
    storage: *Storage,
    size: u64,

    pub fn set_length(self: *SSTableFile, io: Io, new_len: usize) !void {
        try self.file.setLength(io, new_len);

        if (self.size < new_len) {
            self.storage.stat.sstables.items[self.lvl] += new_len - self.size;
        } else {
            self.storage.stat.sstables.items[self.lvl] -= self.size - new_len;
        }

        self.size = new_len;
    }

    pub fn close(self: *SSTableFile, io: Io) void {
        self.file.close(io);
    }

    pub fn sync(self: *SSTableFile, io: Io) !void {
        try self.file.sync(io);
    }
};
