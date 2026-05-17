const std = @import("std");
const File = std.Io.File;
const Dir = std.Io.Dir;
const io = std.Options.debug_io;
const Allocator = std.mem.Allocator;

pub const Wal = struct {
    // WAL file
    file: File,

    fn file_name(alloc: Allocator, seq: usize) ![]const u8 {
        const res = std.fmt.allocPrint(alloc, "WAL{}.sst", .{seq});
        return res;
    }

    pub fn new(dir: Dir, seq: usize, alloc: Allocator) !Wal {
        const name = try Wal.file_name(alloc, seq);
        defer alloc.free(name);

        const file = dir.openFile(io, name, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => try dir.createFile(io, name, .{ .read = true }),
            else => return err,
        };
        return .{ .file = file };
    }
};
