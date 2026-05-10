const std = @import("std");
const File = std.fs.File;
const MemTable = @import("storage").MemTable;
const SSTable = @import("storage").sstable.SSTable;
const manifest = @import("storage").manifest;
const Flusher = @import("flusher.zig").Flusher;
const Allocator = std.mem.Allocator;
const KeyValueOwned = @import("storage").KeyValueOwned;
const Mutex = std.Thread.Mutex;
const Value = std.atomic.Value;
const FileMeta = @import("storage").manifest.FileMeta;

pub const Version = struct {
    // File handle
    file: File,
    // Next file number
    next_file: Value(usize),
    // Next sequence number
    next_sequence: Value(usize),
    // Alive SSTables
    tables: std.ArrayList(FileMeta),
    // Protects concurrent edit applies
    mutex: Mutex,
    // Flusher that periodically flushes immutable tables
    flusher: *Flusher,

    const Self = @This();

    pub fn apply(self: *Self, edit: VersionEdit, alloc: Allocator) !void {
        var records = try edit.as_manifest_records(alloc);
        defer records.deinit(alloc);

        var serialized_records = try std.ArrayList(u8).initCapacity(alloc, 0);
        defer serialized_records.deinit(alloc);

        for (records.items) |rec| {
            try rec.serialize_to(&serialized_records, alloc);
        }

        try self.file.writeAll(serialized_records.items);

        self.mutex.lock();
        defer self.mutex.unlock();

        for (edit.new_files.items) |file| {
            try self.tables.append(alloc, file);
        }

        if (edit.next_file) |next_file| {
            self.next_file = Value(usize).init(next_file);
        }
    }

    pub fn next_seq(self: *Self) usize {
        return self.next_sequence.fetchAdd(1, .monotonic);
    }

    pub fn current_seq(self: *Self) usize {
        return self.next_sequence.load(.monotonic);
    }

    pub fn new_file(self: *Self, alloc: Allocator, seq: *usize) ![]const u8 {
        const s = self.next_file.fetchAdd(1, .monotonic);
        const res = std.fmt.allocPrint(alloc, "memtable{}.sst", .{s});

        seq.* = s;
        return res;
    }

    pub fn from_file(dir: std.fs.Dir, path: []const u8, alloc: Allocator) !*Self {
        const file = dir.openFile(path, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => try dir.createFile(path, .{ .read = true }),
            else => return err,
        };
        const stat = try file.stat();
        const size = stat.size;
        const empty = size == 0;
        const res = try alloc.create(Self);

        res.* = .{
            .flusher = try Flusher.new(alloc, res, dir),
            .file = file,
            .tables = try std.ArrayList(FileMeta).initCapacity(alloc, 0),
            .next_file = Value(usize).init(0),
            .next_sequence = Value(usize).init(0),
            .mutex = Mutex{},
        };
        errdefer res.deinit(alloc);

        if (size > 1) {
            const mmap = try std.posix.mmap(
                null,
                size,
                std.posix.PROT.READ | std.posix.PROT.WRITE,
                .{ .TYPE = .SHARED },
                file.handle,
                0,
            );
            defer std.posix.munmap(mmap);

            const rep = try manifest.ManifestRecord.deserialize_from(mmap, alloc);
            try res.replay(rep, alloc);
        }

        if (empty) {
            try file.seekTo(0);
        } else {
            try file.seekFromEnd(0);
        }

        return res;
    }

    // Inserts new immutable memtable
    pub fn insert(self: *Version, table: *MemTable) void {
        self.flusher.insert(table);
    }

    // Resolves value request.
    pub fn get(self: *Self, key: []const u8, dir: std.fs.Dir, alloc: Allocator) !?[]u8 {
        // Resolved from immutable table
        if (try self.flusher.get(key, self.current_seq(), alloc)) |val| {
            var res = try std.ArrayList(u8).initCapacity(alloc, val.len);

            try res.appendSlice(alloc, val);
            return res.items;
        }

        // Search sstables on a disk
        return self.search_disk(key, dir, alloc);
    }

    fn search_disk(self: *Self, key: []const u8, dir: std.fs.Dir, alloc: Allocator) !?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        var candidates = try std.ArrayList(FileMeta).initCapacity(alloc, self.tables.items.len);

        for (self.tables.items) |table| {
            const min = table.min.as_kv().as_key();
            const max = table.max.as_kv().as_key();
            const cmp_min = std.mem.order(u8, min, key);
            const cmp_max = std.mem.order(u8, max, key);

            if ((cmp_min == .lt or cmp_min == .eq) and (cmp_max == .gt or cmp_max == .eq)) {
                try candidates.append(alloc, table);
            }
        }

        if (candidates.items.len == 0)
            return null;

        std.mem.sort(FileMeta, candidates.items, {}, FileMeta.less_than);

        for (candidates.items) |table| {
            const ss = try SSTable.open(dir, table.name);
            const value = try ss.find_value(key, alloc);

            switch (value) {
                .Removed => return null,
                .Found => |v| return v,
                else => {},
            }
        }

        return null;
    }

    fn replay(
        self: *Version,
        edits: std.ArrayList(manifest.ManifestRecord),
        alloc: Allocator,
    ) !void {
        for (edits.items) |edit| {
            switch (edit) {
                .NextFileNumber => |next| self.next_file.store(next, .monotonic),
                .NextSeqNumber => |next| self.next_sequence.store(next, .monotonic),
                .AddFile => |f| {
                    try self.tables.append(alloc, f);
                },
                .DeleteFile => |f| {
                    for (self.tables.items, 0..) |file, idx| {
                        if (file.seq == f.seq and file.lvl == f.lvl) {
                            _ = self.tables.swapRemove(idx);
                            continue;
                        }
                    }

                    // File was not created??
                    std.debug.assert(false);
                },
            }
        }
    }

    // De-initializes version
    pub fn deinit(self: *Version, alloc: Allocator) void {
        self.tables.deinit(alloc);
        self.flusher.deinit(alloc);
        alloc.destroy(self);
    }
};

pub const VersionEdit = struct {
    next_file: ?usize,
    new_files: std.ArrayList(FileMeta),
    next_seq: ?usize,

    pub fn as_manifest_records(
        self: *const VersionEdit,
        alloc: Allocator,
    ) !std.ArrayList(manifest.ManifestRecord) {
        var res = try std.ArrayList(manifest.ManifestRecord).initCapacity(alloc, 0);

        if (self.next_seq) |seq| {
            try res.append(alloc, .{ .NextSeqNumber = seq });
        }

        if (self.next_file) |file| {
            try res.append(alloc, .{ .NextFileNumber = file });
        }

        for (self.new_files.items) |file| {
            try res.append(alloc, .{ .AddFile = file });
        }

        return res;
    }

    pub fn empty(alloc: Allocator) !VersionEdit {
        return .{
            .next_file = null,
            .new_files = try std.ArrayList(FileMeta).initCapacity(alloc, 0),
            .next_seq = null,
        };
    }
};

test "Version serialization" {
    var arena = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }
    const allocator = arena.allocator();

    const dirname = "test_db10";
    try std.fs.cwd().makeDir(dirname);

    var dir = try std.fs.cwd().openDir(dirname, .{});

    defer {
        dir.close();
        std.fs.cwd().deleteTree(dirname) catch {
            @panic("gg");
        };
    }

    var version = try Version.from_file(dir, "manifest", allocator);
    defer version.deinit(allocator);

    {
        var edit = try VersionEdit.empty(allocator);
        edit.next_seq = 1;
        try version.apply(edit, allocator);
    }
}

fn test_file_meta(
    alloc: Allocator,
    name: []const u8,
    lvl: u8,
    seq: usize,
    min_key: []const u8,
    min_value: []const u8,
    max_key: []const u8,
    max_value: []const u8,
) !FileMeta {
    var memtable = try MemTable.new(alloc, null);
    defer memtable.deinit(alloc);

    try memtable.put(min_key, min_value, seq);
    try memtable.put(max_key, max_value, seq + 1);

    return .{
        .name = name,
        .lvl = lvl,
        .seq = seq,
        .min = try KeyValueOwned.from_kv(memtable.min().?, alloc),
        .max = try KeyValueOwned.from_kv(memtable.max().?, alloc),
    };
}

test "VersionEdit serializes manifest records in replay order" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var edit = try VersionEdit.empty(allocator);
    edit.next_seq = 17;
    edit.next_file = 42;
    try edit.new_files.append(allocator, try test_file_meta(
        allocator,
        "memtable42.sst",
        0,
        42,
        "a",
        "first",
        "z",
        "last",
    ));

    const records = try edit.as_manifest_records(allocator);
    try std.testing.expectEqual(@as(usize, 3), records.items.len);
    try std.testing.expectEqual(@as(usize, 17), records.items[0].NextSeqNumber);
    try std.testing.expectEqual(@as(usize, 42), records.items[1].NextFileNumber);
    try std.testing.expectEqualSlices(u8, "memtable42.sst", records.items[2].AddFile.name);

    var serialized = try std.ArrayList(u8).initCapacity(allocator, 0);
    for (records.items) |rec| {
        try rec.serialize_to(&serialized, allocator);
    }

    const deserialized = try manifest.ManifestRecord.deserialize_from(serialized.items, allocator);
    try std.testing.expectEqual(@as(usize, 3), deserialized.items.len);
    try std.testing.expectEqual(@as(usize, 17), deserialized.items[0].NextSeqNumber);
    try std.testing.expectEqual(@as(usize, 42), deserialized.items[1].NextFileNumber);
    try std.testing.expectEqualSlices(u8, "memtable42.sst", deserialized.items[2].AddFile.name);
    try std.testing.expectEqual(@as(u8, 0), deserialized.items[2].AddFile.lvl);
}

test "Version apply persists edits that reopen can replay" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const dirname = "test_db_version_replay";
    std.fs.cwd().deleteTree(dirname) catch {};
    try std.fs.cwd().makeDir(dirname);

    var dir = try std.fs.cwd().openDir(dirname, .{});
    defer {
        dir.close();
        std.fs.cwd().deleteTree(dirname) catch {
            @panic("failed to delete test db");
        };
    }

    {
        var version = try Version.from_file(dir, "manifest", allocator);
        defer version.deinit(allocator);

        var edit = try VersionEdit.empty(allocator);
        edit.next_seq = 9;
        edit.next_file = 11;
        try edit.new_files.append(allocator, try test_file_meta(
            allocator,
            "memtable11.sst",
            0,
            11,
            "k1",
            "v1",
            "k9",
            "v9",
        ));

        try version.apply(edit, allocator);
    }

    {
        var reopened = try Version.from_file(dir, "manifest", allocator);
        defer reopened.deinit(allocator);

        try std.testing.expectEqual(@as(usize, 9), reopened.current_seq());
        try std.testing.expectEqual(@as(usize, 11), reopened.next_file.load(.monotonic));
        try std.testing.expectEqual(@as(usize, 1), reopened.tables.items.len);
        try std.testing.expectEqualSlices(u8, "memtable11.sst", reopened.tables.items[0].name);
    }
}
