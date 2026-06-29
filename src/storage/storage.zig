const std = @import("std");
const FileMeta = manifest.FileMeta;
const FileSeq = manifest.FileSeq;
const Allocator = std.mem.Allocator;
const manifest = @import("manifest.zig");
const SSTableFile = @import("ssfile.zig").SSTableFile;

const Stats = struct {
    // Size of sstables on each level.
    sstables: std.ArrayList(usize),

    fn new(max_lvl: usize, alloc: Allocator) !Stats {
        var arr = try std.ArrayList(usize).initCapacity(alloc, max_lvl);

        arr.appendNTimes(alloc, 0, max_lvl) catch unreachable;
        return .{ .sstables = arr };
    }

    fn deinit(self: *Stats, alloc: Allocator) void {
        self.sstables.deinit(alloc);
    }
};

/// Wrapper around DB directory
pub const Storage = struct {
    dir: std.Io.Dir,
    stat: Stats,

    const Self = @This();

    // NOTE: takes ownership of the dir.
    pub fn new(dir: std.Io.Dir, max_lvl: usize, alloc: Allocator) !Self {
        return .{ .dir = dir, .stat = try Stats.new(max_lvl, alloc) };
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
        lvl: u8,
        io: std.Io,
        alloc: Allocator,
    ) !SSTableFile {
        const name = try manifest.alloc_sstable_name(file_seq, alloc);
        defer alloc.free(name);

        return .{
            .file = try self.dir.createFile(io, name, .{
                .truncate = true,
                .read = true,
                .exclusive = true,
            }),
            .size = 0,
            .lvl = lvl,
            .storage = self,
        };
    }

    pub fn open_sstable(
        self: *Storage,
        fmeta: FileMeta,
        io: std.Io,
        alloc: Allocator,
    ) !SSTableFile {
        const name = try manifest.alloc_sstable_name(fmeta.file_seq, alloc);
        defer alloc.free(name);

        const file = try self.dir.openFile(io, name, .{});
        errdefer {
            self.unlink_sstable(fmeta, io, alloc) catch @panic("todo");
        }
        const st = try file.stat(io);

        return .{
            .size = st.size,
            .storage = self,
            .lvl = fmeta.lvl,
            .file = file,
        };
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

    pub fn deinit(self: *Self, io: std.Io, alloc: Allocator) void {
        self.stat.deinit(alloc);
        self.dir.close(io);
    }
};
