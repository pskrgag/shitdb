const std = @import("std");
const File = std.Io.File;
const MemTable = @import("storage").MemTable;
const SSTable = @import("storage").sstable.SSTable;
const manifest = @import("storage").manifest;
const Flusher = @import("flusher.zig").Flusher;
const Allocator = std.mem.Allocator;
const KeyValueOwned = @import("storage").KeyValueOwned;
const Mutex = std.Io.Mutex;
const Value = std.atomic.Value;
const FileMeta = @import("storage").manifest.FileMeta;
const io = std.Options.debug_io;
const WalTable = @import("wal_table.zig").WalTable;
const Wal = @import("wal.zig").Wal;
const MemTableOpts = @import("storage").MemTableOpts;

pub const Version = struct {
    // File handle
    file: File,
    // Next file number
    next_file: Value(usize),
    // Next sequence number
    next_sequence: Value(usize),
    // Alive SSTables
    tables: std.ArrayList(FileMeta),
    // Alive WALs
    wals: std.ArrayList(usize),
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

        const offset = try self.file.length(io);
        try self.file.writePositionalAll(io, serialized_records.items, offset);

        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        for (edit.new_files.items) |file| {
            try self.tables.append(alloc, file);
        }

        // if (edit.next_file) |next_file| {
        //     self.next_file = Value(usize).init(next_file);
        // }
    }

    pub fn next_seq(self: *Self) usize {
        return self.next_sequence.fetchAdd(1, .monotonic);
    }

    pub fn current_seq(self: *Self) usize {
        return self.next_sequence.load(.monotonic);
    }

    pub fn new_file_seq(self: *Self) usize {
        return self.next_file.fetchAdd(1, .monotonic);
    }

    pub fn from_file(dir: std.Io.Dir, path: []const u8, opts: MemTableOpts, alloc: Allocator) !*Self {
        const file = dir.openFile(io, path, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => try dir.createFile(io, path, .{ .read = true }),
            else => return err,
        };
        errdefer file.close(io);

        const stat = try file.stat(io);
        const size = stat.size;
        const res = try alloc.create(Self);

        res.* = .{
            .flusher = try Flusher.new(alloc, res, dir),
            .file = file,
            .tables = try std.ArrayList(FileMeta).initCapacity(alloc, 0),
            .next_file = Value(usize).init(0),
            .next_sequence = Value(usize).init(0),
            .mutex = Mutex.init,
            .wals = try std.ArrayList(usize).initCapacity(alloc, 0),
        };
        errdefer res.deinit(alloc);

        if (size > 0) {
            const mmap = try std.posix.mmap(
                null,
                size,
                .{ .READ = true, .WRITE = true },
                .{ .TYPE = .SHARED },
                file.handle,
                0,
            );
            defer std.posix.munmap(mmap);

            var rep = try manifest.ManifestRecord.deserialize_from(mmap, alloc);
            defer rep.deinit(alloc);
            try res.replay(dir, rep, opts, alloc);
        }

        return res;
    }

    // Inserts new immutable memtable
    pub fn insert(self: *Version, table: *WalTable) void {
        self.flusher.insert(table);
    }

    fn file_name(seq: usize, alloc: Allocator) ![]const u8 {
        const res = std.fmt.allocPrint(alloc, "memtable{}.sst", .{seq});
        return res;
    }

    // Flushes a memtable synchronously into an SSTable and records it in the manifest.
    pub fn flush_memtable(self: *Version, table: *WalTable, dir: std.Io.Dir, alloc: Allocator) !void {
        if (table.min() == null)
            return;

        const min = try KeyValueOwned.from_kv(table.min().?, alloc);
        const max = try KeyValueOwned.from_kv(table.max().?, alloc);

        const name = try Self.file_name(table.seq, alloc);
        var edit = try VersionEdit.empty(alloc);
        defer edit.new_files.deinit(alloc);

        try edit.new_files.append(alloc, FileMeta{
            .lvl = 0,
            .name = name,
            .max = max,
            .min = min,
            .seq = table.seq,
        });
        edit.next_file = table.seq + 1;

        // TODO: maybe make SSTable::create generic over table type? Accessing table.table is ugly af.
        var sstable = try SSTable.create(dir, name, &table.table, alloc);
        defer sstable.deinit();

        try self.apply(edit, alloc);
    }

    // Resolves value request.
    pub fn get(self: *Self, key: []const u8, dir: std.Io.Dir, alloc: Allocator) !?[]u8 {
        // Resolved from immutable table
        if (try self.flusher.get(key, self.current_seq(), alloc)) |val| {
            var res = try std.ArrayList(u8).initCapacity(alloc, val.len);

            try res.appendSlice(alloc, val);
            return res.items;
        }

        // Search sstables on a disk
        return self.search_disk(key, dir, alloc);
    }

    fn search_disk(self: *Self, key: []const u8, dir: std.Io.Dir, alloc: Allocator) !?[]u8 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        var candidates = try std.ArrayList(FileMeta).initCapacity(alloc, self.tables.items.len);
        defer candidates.deinit(alloc);

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
            var ss = try SSTable.open(dir, table.name);
            defer ss.deinit();
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
        dir: std.Io.Dir,
        edits: std.ArrayList(manifest.ManifestRecord),
        opts: MemTableOpts,
        alloc: Allocator,
    ) !void {
        for (edits.items) |edit| {
            switch (edit) {
                .NextFileNumber => |next| self.next_file.store(next, .monotonic),
                .NextSeqNumber => |next| self.next_sequence.store(next, .monotonic),
                .AddFile => |f| {
                    try self.tables.append(alloc, f);

                    while (self.next_file.load(.monotonic) <= f.seq) {
                        self.next_file.store(f.seq + 1, .monotonic);
                    }

                    for (self.wals.items, 0..) |wal, idx| {
                        if (wal == f.seq) {
                            _ = self.wals.swapRemove(idx);
                            break;
                        }
                    }
                },
                .AddWal => |wal| {
                    try self.wals.append(alloc, wal);
                },
                .DeleteFile => |f| {
                    var found = false;

                    for (self.tables.items, 0..) |file, idx| {
                        if (file.seq == f.seq and file.lvl == f.lvl) {
                            _ = self.tables.swapRemove(idx);
                            found = true;
                            break;
                        }
                    }

                    // File was not created??
                    std.debug.assert(found);
                },
            }
        }

        // Replay from active WALs
        for (self.wals.items) |wal| {
            const alive_wal = try WalTable.open(dir, opts, wal, io, alloc);
            self.insert(alive_wal);
        }
    }

    // De-initializes version
    pub fn deinit(self: *Version, alloc: Allocator) void {
        for (self.tables.items) |*table| {
            table.deinit(alloc);
        }

        self.tables.deinit(alloc);
        self.wals.deinit(alloc);
        self.flusher.deinit(alloc);
        self.file.close(io);
        alloc.destroy(self);
    }
};

pub const VersionEdit = struct {
    next_file: ?usize,
    new_files: std.ArrayList(FileMeta),
    next_seq: ?usize,
    add_wal: ?usize,

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

        if (self.add_wal) |wal| {
            try res.append(alloc, .{ .AddWal = wal });
        }

        return res;
    }

    pub fn empty(alloc: Allocator) !VersionEdit {
        return .{
            .next_file = null,
            .new_files = try std.ArrayList(FileMeta).initCapacity(alloc, 0),
            .next_seq = null,
            .add_wal = null,
        };
    }
};

const testing_memtable_opts = MemTableOpts{ .memtable_size = 1 << 20 };

test "Version serialization" {
    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }
    const allocator = arena.allocator();

    const dirname = "test_db10";
    try std.Io.Dir.cwd().createDir(io, dirname, .default_dir);

    var dir = try std.Io.Dir.cwd().openDir(io, dirname, .{});

    defer {
        dir.close(io);
        std.Io.Dir.cwd().deleteTree(io, dirname) catch {
            @panic("gg");
        };
    }

    var version = try Version.from_file(dir, "manifest", testing_memtable_opts, allocator);
    defer version.deinit(allocator);

    {
        var edit = try VersionEdit.empty(allocator);
        defer edit.new_files.deinit(allocator);
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
        .name = try alloc.dupe(u8, name),
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
    std.Io.Dir.cwd().deleteTree(io, dirname) catch {};
    try std.Io.Dir.cwd().createDir(io, dirname, .default_dir);

    var dir = try std.Io.Dir.cwd().openDir(io, dirname, .{});
    defer {
        dir.close(io);
        std.Io.Dir.cwd().deleteTree(io, dirname) catch {
            @panic("failed to delete test db");
        };
    }

    {
        var version = try Version.from_file(dir, "manifest", testing_memtable_opts, allocator);
        defer version.deinit(allocator);

        var edit = try VersionEdit.empty(allocator);
        defer edit.new_files.deinit(allocator);
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
        var reopened = try Version.from_file(dir, "manifest", testing_memtable_opts, allocator);
        defer reopened.deinit(allocator);

        try std.testing.expectEqual(@as(usize, 9), reopened.current_seq());
        try std.testing.expectEqual(@as(usize, 12), reopened.next_file.load(.monotonic));
        try std.testing.expectEqual(@as(usize, 1), reopened.tables.items.len);
        try std.testing.expectEqualSlices(u8, "memtable11.sst", reopened.tables.items[0].name);
    }
}
