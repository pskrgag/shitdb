const std = @import("std");
const FileMeta = manifest.FileMeta;
const FileSeq = manifest.FileSeq;
const Allocator = std.mem.Allocator;
const manifest = @import("manifest.zig");
const SSTableFile = @import("ssfile.zig").SSTableFile;

pub const Stats = struct {
    // Size of sstables on each level.
    sstables: std.ArrayList(usize),

    fn new(max_lvl: usize, alloc: Allocator) !Stats {
        var arr = try std.ArrayList(usize).initCapacity(alloc, max_lvl);

        arr.appendNTimes(alloc, 0, max_lvl) catch unreachable;
        return .{ .sstables = arr };
    }

    pub fn sstable_size(self: *const Stats, lvl: u8) usize {
        return self.sstables.items[lvl];
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

    pub fn open_or_create_manifest(
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
        errdefer file.close(io);
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

        const stat = try self.dir.statFile(io, name, .{ .follow_symlinks = false });
        try self.dir.deleteFile(io, name);

        self.stat.sstables.items[fmeta.lvl] -= stat.size;
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

    pub fn deinit(self: *Self, io: std.Io, alloc: Allocator) void {
        self.stat.deinit(alloc);
        self.dir.close(io);
    }

    fn sstable_size(self: *Storage, fmeta: FileMeta, io: std.Io, alloc: Allocator) !usize {
        const name = try manifest.alloc_sstable_name(fmeta.file_seq, alloc);
        defer alloc.free(name);

        const stat = try self.dir.statFile(io, name, .{ .follow_symlinks = false });
        return stat.size;
    }

    pub fn record_sstable(self: *Self, fmeta: FileMeta, io: std.Io, alloc: Allocator) !void {
        self.stat.sstables.items[fmeta.lvl] += try self.sstable_size(fmeta, io, alloc);
    }

    pub fn stats(self: *const Self) *const Stats {
        return &self.stat;
    }
};

const testing_io = std.testing.io;

const TestSSTableKV = struct {
    key: []const u8,
    value: ?[]const u8,
    seq: usize,
};

fn create_test_sstable(
    storage: *Storage,
    io: std.Io,
    alloc: Allocator,
    lvl: u8,
    file_seq: usize,
    keys: []const TestSSTableKV,
) !usize {
    const MemTable = @import("memtable.zig").MemTable;
    const KVSeq = @import("memtable.zig").KVSeq;
    const KeyOwned = @import("manifest.zig").KeyOwned;
    const SSTable = @import("sstable.zig").SSTable;

    var memtable = try MemTable.new(alloc, io, .{});
    defer memtable.deinit(alloc);

    for (keys) |kv| {
        if (kv.value) |value| {
            try memtable.put(kv.key, value, KVSeq.init(kv.seq));
        } else {
            try memtable.remove(kv.key, KVSeq.init(kv.seq));
        }
    }

    var meta = FileMeta{
        .lvl = lvl,
        .file_seq = FileSeq.init(file_seq),
        .min = try KeyOwned.from_kv(memtable.min().?, alloc),
        .max = try KeyOwned.from_kv(memtable.max().?, alloc),
        .value_seq = KVSeq.init(0),
    };
    defer meta.deinit(alloc);

    var sstable = try SSTable.create(storage, meta, &memtable, io, alloc);
    defer sstable.deinit(io);

    const stat = try sstable.file.file.stat(testing_io);
    try std.testing.expect(stat.size == sstable.file.size);

    return sstable.file.size;
}

test "Storage statistics works" {
    const KVSeq = @import("memtable.zig").KVSeq;

    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }
    const allocator = arena.allocator();
    const dirname = "test_storage_statistics";
    std.Io.Dir.cwd().deleteTree(testing_io, dirname) catch {};
    try std.Io.Dir.cwd().createDir(testing_io, dirname, .default_dir);

    const dir = try std.Io.Dir.cwd().openDir(testing_io, dirname, .{});
    var storage = try Storage.new(dir, 100, allocator);

    defer {
        storage.deinit(testing_io, allocator);
        std.Io.Dir.cwd().deleteTree(testing_io, dirname) catch {
            @panic("failed to delete test db");
        };
    }

    const size1 = try create_test_sstable(
        &storage,
        testing_io,
        allocator,
        0,
        0,
        &[_]TestSSTableKV{
            .{ .key = "b", .value = "old", .seq = 1 },
        },
    );

    try std.testing.expectEqual(storage.stats().sstable_size(0), size1);
    try std.testing.expectEqual(storage.stats().sstable_size(1), 0);

    const size2 = try create_test_sstable(
        &storage,
        testing_io,
        allocator,
        0,
        1,
        &[_]TestSSTableKV{
            .{ .key = "adfsdffdb", .value = "dwsdgffdgdfgold", .seq = 2 },
        },
    );

    try std.testing.expectEqual(storage.stats().sstable_size(0), size1 + size2);
    try std.testing.expectEqual(storage.stats().sstable_size(1), 0);

    const size3 = try create_test_sstable(
        &storage,
        testing_io,
        allocator,
        1,
        2,
        &[_]TestSSTableKV{
            .{ .key = "adfsdffdb", .value = "dwsdgffdgdfgold", .seq = 2 },
        },
    );

    try std.testing.expectEqual(storage.stats().sstable_size(0), size1 + size2);
    try std.testing.expectEqual(storage.stats().sstable_size(1), size3);
    try std.testing.expectEqual(storage.stats().sstable_size(2), 0);

    const first_meta = FileMeta{
        .lvl = 0,
        .file_seq = FileSeq.init(0),
        .max = undefined,
        .min = undefined,
        .value_seq = KVSeq.init(0),
    };
    try storage.unlink_sstable(first_meta, testing_io, allocator);

    try std.testing.expectEqual(storage.stats().sstable_size(0), size2);
    try std.testing.expectEqual(storage.stats().sstable_size(1), size3);
    try std.testing.expectEqual(storage.stats().sstable_size(2), 0);
}
