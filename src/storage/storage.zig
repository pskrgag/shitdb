const std = @import("std");
const FileMeta = manifest.FileMeta;
const FileSeq = manifest.FileSeq;
const Allocator = std.mem.Allocator;
const manifest = @import("manifest.zig");

/// Wrapper around DB directory
pub const Storage = struct {
    dir: std.Io.Dir,

    const Self = @This();

    pub fn new(dir: std.Io.Dir) !Self {
        return .{ .dir = dir };
    }

    pub fn openOrCreateManifest(
        self: *Storage,
        path: []const u8,
        io: std.Io,
    ) !std.Io.File {
        return self.dir.openFile(io, path, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => try self.dir.createFile(io, path, .{ .read = true }),
            else => return err,
        };
    }

    pub fn create_sstable(
        self: *Storage,
        file_seq: FileSeq,
        io: std.Io,
        alloc: Allocator,
    ) !std.Io.File {
        const name = try manifest.alloc_sstable_name(file_seq, alloc);
        defer alloc.free(name);

        return try self.dir.createFile(io, name, .{
            .truncate = true,
            .read = true,
            .exclusive = true,
        });
    }

    pub fn open_sstable(
        self: *Storage,
        fmeta: FileMeta,
        io: std.Io,
        alloc: Allocator,
    ) !std.Io.File {
        const name = try manifest.alloc_sstable_name(fmeta.file_seq, alloc);
        defer alloc.free(name);

        return try self.dir.openFile(io, name, .{});
    }

    pub fn unlink_sstable(self: *Storage, fmeta: FileMeta, io: std.Io, alloc: Allocator) !void {
        const name = try manifest.alloc_sstable_name(fmeta.file_seq, alloc);
        defer alloc.free(name);

        try self.dir.deleteFile(io, name);
    }

    pub fn open_wal(self: *Storage, seq: FileSeq, io: std.Io, alloc: Allocator) !std.Io.File {
        const name = try std.fmt.allocPrint(alloc, "WAL{}.sst", .{seq.get()});
        defer alloc.free(name);

        return try self.dir.openFile(io, name, .{ .mode = .read_write });
    }

    pub fn create_wal(self: *Storage, seq: FileSeq, io: std.Io, alloc: Allocator) !std.Io.File {
        const name = try std.fmt.allocPrint(alloc, "WAL{}.sst", .{seq.get()});
        defer alloc.free(name);

        return try self.dir.createFile(io, name, .{ .read = true });
    }

    pub fn unlink_wal(self: *Storage, seq: FileSeq, io: std.Io, alloc: Allocator) !void {
        const name = try std.fmt.allocPrint(alloc, "WAL{}.sst", .{seq.get()});
        defer alloc.free(name);

        try self.dir.deleteFile(io, name);
    }

    pub fn delete_sstable(self: *Storage, fmeta: FileMeta, io: std.Io, alloc: Allocator) !void {
        const name = try manifest.alloc_sstable_name(fmeta.file_seq, alloc);
        defer alloc.free(name);

        try self.dir.deleteFile(io, name);
    }

    pub fn deinit(self: *Self, io: std.Io) void {
        self.dir.close(io);
    }
};
