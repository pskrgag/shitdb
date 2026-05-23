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
const FileSeq = @import("storage").manifest.FileSeq;
const WalTable = @import("wal_table.zig").WalTable;
const Wal = @import("wal.zig").Wal;
const MemTableOpts = @import("storage").MemTableOpts;
const KVSeq = @import("storage").KVSeq;

const MaxLevel: usize = 2;
const MaxTablesLVL: usize = 4;

pub const Version = struct {
    // File handle
    file: File,
    // Next file number
    next_file: Value(FileSeq),
    // Next sequence number
    next_sequence: Value(KVSeq),
    // Alive SSTables
    tables: std.ArrayList(FileMeta),
    // Alive WALs
    wals: std.ArrayList(FileSeq),
    // Protects concurrent edit applies
    mutex: Mutex,
    // Flusher that periodically flushes immutable tables
    flusher: *Flusher,
    // Active tables on each lvl
    active_tables: [MaxLevel]u8,

    const Self = @This();

    pub fn apply(self: *Self, edit: VersionEdit, io: std.Io, alloc: Allocator) !void {
        var records = try edit.as_manifest_records(alloc);
        defer records.deinit(alloc);

        var serialized_records = try std.ArrayList(u8).initCapacity(alloc, 0);
        defer serialized_records.deinit(alloc);

        for (records.items) |rec| {
            try rec.serialize_to(&serialized_records, alloc);
        }

        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        const offset = try self.file.length(io);

        // NOTE: writePositionalAll sends all data directly to kernel. Sync makes it go to the disk
        try self.file.writePositionalAll(io, serialized_records.items, offset);
        try self.file.sync(io);

        for (edit.new_files.items) |file| {
            try self.tables.append(alloc, file);

            std.debug.assert(file.lvl < MaxLevel);
            self.active_tables[file.lvl] += 1;
        }

        // it's n^2, but len(deleted_files) should be small (2)
        for (edit.deleted_files.items) |seq| {
            for (self.tables.items, 0..) |f, i| {
                if (f.file_seq.get() == seq.get()) {
                    _ = self.tables.swapRemove(i);
                    break;
                }
            }
        }

        if (edit.next_file) |next_file| {
            self.next_file = Value(FileSeq).init(next_file);
        }
    }

    pub fn next_seq(self: *Self) KVSeq {
        return self.next_sequence.fetchAdd(KVSeq.init(1), .monotonic);
    }

    pub fn current_seq(self: *Self) KVSeq {
        return self.next_sequence.load(.monotonic);
    }

    pub fn current_file_seq(self: *Self) FileSeq {
        return self.next_file.load(.monotonic);
    }

    pub fn new_file_seq(self: *Self) FileSeq {
        return self.next_file.fetchAdd(FileSeq.init(1), .monotonic);
    }

    pub fn from_file(dir: std.Io.Dir, path: []const u8, opts: MemTableOpts, io: std.Io, alloc: Allocator) !*Self {
        const file = dir.openFile(io, path, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => try dir.createFile(io, path, .{ .read = true }),
            else => return err,
        };
        errdefer file.close(io);

        const stat = try file.stat(io);
        const size = stat.size;
        const res = try alloc.create(Self);

        res.* = .{
            .flusher = try Flusher.new(alloc, res, dir, io),
            .file = file,
            .tables = try std.ArrayList(FileMeta).initCapacity(alloc, 0),
            .next_file = Value(FileSeq).init(FileSeq.init(0)),
            .next_sequence = Value(KVSeq).init(KVSeq.init(0)),
            .mutex = Mutex.init,
            .wals = try std.ArrayList(FileSeq).initCapacity(alloc, 0),
            .active_tables = [_]u8{0} ** MaxLevel,
        };
        errdefer res.deinit(io, alloc);

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
            try res.replay(dir, rep, opts, io, alloc);
        }

        return res;
    }

    // Inserts new immutable memtable
    pub fn insert(self: *Version, table: *WalTable) void {
        self.flusher.insert(table);
    }

    fn file_name(seq: FileSeq, alloc: Allocator) ![]const u8 {
        const res = std.fmt.allocPrint(alloc, "memtable{}.sst", .{seq.get()});
        return res;
    }

    fn compact_lvl0(self: *Version, dir: std.Io.Dir, io: std.Io, alloc: Allocator) !void {
        std.debug.assert(self.tables.items.len >= MaxLevel);
        std.debug.assert(MaxLevel >= 2);

        var tables: [2]struct { meta: FileMeta, idx: usize } = undefined;
        var found: usize = 0;

        {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);

            for (self.tables.items, 0..) |file, idx| {
                if (file.lvl == 0) {
                    tables[found] = .{ .meta = file, .idx = idx };
                    found += 1;
                    if (found == 2) break;
                }
            }
        }

        std.debug.assert(found == 2);

        const merged_seq = self.new_file_seq();
        // name will be freed later, since it will be added to tables array
        const name = try Self.file_name(merged_seq, alloc);

        const first = try SSTable.open(dir, io, tables[0].meta.name);
        defer first.deinit();
        const second = try SSTable.open(dir, io, tables[1].meta.name);
        defer second.deinit();

        const new = try SSTable.merge(dir, name, io, first, second, alloc);
        defer new.deinit();

        var edit = try VersionEdit.empty(alloc);
        defer edit.deinit(alloc);

        try edit.new_files.append(alloc, FileMeta{
            .lvl = 1,
            .name = name,
            .max = try KeyValueOwned.from_kv(&new.max().?, alloc),
            .min = try KeyValueOwned.from_kv(&new.min().?, alloc),
            .file_seq = merged_seq,
            .value_seq = new.maximum_seq().?,
        });

        try edit.deleted_files.append(alloc, tables[0].meta.file_seq);
        try edit.deleted_files.append(alloc, tables[1].meta.file_seq);

        try self.apply(edit, io, alloc);

        // NOTE: this should be safe to access without lock, since it's updated only from flusher thread.
        // tho it's better be moved to apply, but we don't store lvl there...
        self.active_tables[0] -= 2;
    }

    // Flushes a memtable synchronously into an SSTable and records it in the manifest.
    pub fn flush_memtable(self: *Version, table: *WalTable, io: std.Io, dir: std.Io.Dir, alloc: Allocator) !void {
        if (table.min() == null)
            return;

        const min = try KeyValueOwned.from_kv(table.min().?, alloc);
        const max = try KeyValueOwned.from_kv(table.max().?, alloc);

        const name = try Self.file_name(table.seq, alloc);
        var edit = try VersionEdit.empty(alloc);
        defer edit.deinit(alloc);

        try edit.new_files.append(alloc, FileMeta{
            .lvl = 0,
            .name = name,
            .max = max,
            .min = min,
            .file_seq = table.seq,
            .value_seq = table.max_seq(),
        });

        // TODO: maybe make SSTable::create generic over table type? Accessing table.table is ugly af.
        var sstable = try SSTable.create(dir, name, &table.table, io, alloc);
        defer sstable.deinit();

        try self.apply(edit, io, alloc);

        if (self.active_tables[0] > MaxTablesLVL)
            try self.compact_lvl0(dir, io, alloc);
    }

    // Resolves value request.
    pub fn get(self: *Self, key: []const u8, dir: std.Io.Dir, io: std.Io, alloc: Allocator) !?[]u8 {
        // Resolved from immutable table
        if (try self.flusher.get(key, self.current_seq(), alloc)) |val| {
            var res = try std.ArrayList(u8).initCapacity(alloc, val.len);

            try res.appendSlice(alloc, val);
            return res.items;
        }

        // Search sstables on a disk
        return self.search_disk(key, dir, io, alloc);
    }

    fn search_disk(self: *Self, key: []const u8, dir: std.Io.Dir, io: std.Io, alloc: Allocator) !?[]u8 {
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
            var ss = try SSTable.open(dir, io, table.name);
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
        io: std.Io,
        alloc: Allocator,
    ) !void {
        for (edits.items) |edit| {
            switch (edit) {
                .NextFileNumber => |next| self.next_file.store(next, .monotonic),
                .NextSeqNumber => |next| self.next_sequence.store(KVSeq.init(next), .monotonic),
                .AddFile => |f| {
                    try self.tables.append(alloc, f);
                    std.debug.assert(f.lvl < MaxLevel);
                    self.active_tables[f.lvl] += 1;

                    if (self.next_file.load(.monotonic).get() <= f.file_seq.get()) {
                        self.next_file.store(FileSeq.init(f.file_seq.get() + 1), .monotonic);
                    }

                    if (self.next_sequence.load(.monotonic).get() <= f.value_seq.get()) {
                        self.next_sequence.store(KVSeq.init(f.value_seq.get() + 1), .monotonic);
                    }

                    for (self.wals.items, 0..) |wal, idx| {
                        if (wal.get() == f.file_seq.get()) {
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
                        if (file.file_seq.get() == f.get()) {
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

            if (alive_wal.max_seq().get() > self.next_sequence.load(.monotonic).get()) {
                self.next_sequence.store(KVSeq.init(alive_wal.max_seq().get() + 1), .monotonic);
            }

            self.insert(alive_wal);
        }
    }

    // De-initializes version
    pub fn deinit(self: *Version, io: std.Io, alloc: Allocator) void {
        // It's required to destroy flusher first, since it may want to apply some changes to version.
        self.flusher.deinit(alloc);

        for (self.tables.items) |*table| {
            table.deinit(alloc);
        }

        self.tables.deinit(alloc);
        self.wals.deinit(alloc);
        self.file.close(io);
        alloc.destroy(self);
    }
};

pub const VersionEdit = struct {
    next_file: ?FileSeq,
    new_files: std.ArrayList(FileMeta),
    deleted_files: std.ArrayList(FileSeq),
    next_seq: ?KVSeq,
    add_wal: ?FileSeq,

    pub fn as_manifest_records(
        self: *const VersionEdit,
        alloc: Allocator,
    ) !std.ArrayList(manifest.ManifestRecord) {
        var res = try std.ArrayList(manifest.ManifestRecord).initCapacity(alloc, 0);

        if (self.next_seq) |seq| {
            try res.append(alloc, .{ .NextSeqNumber = seq.get() });
        }

        if (self.next_file) |file| {
            try res.append(alloc, .{ .NextFileNumber = file });
        }

        for (self.new_files.items) |file| {
            try res.append(alloc, .{ .AddFile = file });
        }

        for (self.deleted_files.items) |file| {
            try res.append(alloc, .{ .DeleteFile = file });
        }

        if (self.add_wal) |wal| {
            try res.append(alloc, .{ .AddWal = wal });
        }

        return res;
    }

    pub fn deinit(self: *VersionEdit, alloc: Allocator) void {
        self.new_files.deinit(alloc);
        self.deleted_files.deinit(alloc);
    }

    pub fn empty(alloc: Allocator) !VersionEdit {
        return .{
            .next_file = null,
            .new_files = try std.ArrayList(FileMeta).initCapacity(alloc, 0),
            .deleted_files = try std.ArrayList(FileSeq).initCapacity(alloc, 0),
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
    const testing_io = std.testing.io;

    const dirname = "test_db10";
    try std.Io.Dir.cwd().createDir(testing_io, dirname, .default_dir);

    var dir = try std.Io.Dir.cwd().openDir(testing_io, dirname, .{});

    defer {
        dir.close(testing_io);
        std.Io.Dir.cwd().deleteTree(testing_io, dirname) catch {
            @panic("gg");
        };
    }

    var version = try Version.from_file(dir, "manifest", testing_memtable_opts, testing_io, allocator);
    defer version.deinit(testing_io, allocator);

    {
        var edit = try VersionEdit.empty(allocator);
        defer edit.deinit(allocator);
        edit.next_seq = KVSeq.init(1);
        try version.apply(edit, testing_io, allocator);
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

    try memtable.put(min_key, min_value, KVSeq.init(seq));
    try memtable.put(max_key, max_value, KVSeq.init(seq + 1));

    return .{
        .name = try alloc.dupe(u8, name),
        .lvl = lvl,
        .file_seq = FileSeq.init(seq),
        .min = try KeyValueOwned.from_kv(memtable.min().?, alloc),
        .max = try KeyValueOwned.from_kv(memtable.max().?, alloc),
        .value_seq = KVSeq.init(seq + 1),
    };
}

test "VersionEdit serializes manifest records in replay order" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var edit = try VersionEdit.empty(allocator);
    edit.next_seq = KVSeq.init(17);
    edit.next_file = FileSeq.init(42);
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
    try std.testing.expectEqual(@as(usize, 42), records.items[1].NextFileNumber.get());
    try std.testing.expectEqualSlices(u8, "memtable42.sst", records.items[2].AddFile.name);

    var serialized = try std.ArrayList(u8).initCapacity(allocator, 0);
    for (records.items) |rec| {
        try rec.serialize_to(&serialized, allocator);
    }

    const deserialized = try manifest.ManifestRecord.deserialize_from(serialized.items, allocator);
    try std.testing.expectEqual(@as(usize, 3), deserialized.items.len);
    try std.testing.expectEqual(@as(usize, 17), deserialized.items[0].NextSeqNumber);
    try std.testing.expectEqual(@as(usize, 42), deserialized.items[1].NextFileNumber.get());
    try std.testing.expectEqualSlices(u8, "memtable42.sst", deserialized.items[2].AddFile.name);
    try std.testing.expectEqual(@as(u8, 0), deserialized.items[2].AddFile.lvl);
}

test "Version apply persists edits that reopen can replay" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const testing_io = std.testing.io;

    const dirname = "test_db_version_replay";
    std.Io.Dir.cwd().deleteTree(testing_io, dirname) catch {};
    try std.Io.Dir.cwd().createDir(testing_io, dirname, .default_dir);

    var dir = try std.Io.Dir.cwd().openDir(testing_io, dirname, .{});
    defer {
        dir.close(testing_io);
        std.Io.Dir.cwd().deleteTree(testing_io, dirname) catch {
            @panic("failed to delete test db");
        };
    }

    {
        var version = try Version.from_file(dir, "manifest", testing_memtable_opts, testing_io, allocator);
        defer version.deinit(testing_io, allocator);

        var edit = try VersionEdit.empty(allocator);
        defer edit.deinit(allocator);
        edit.next_seq = KVSeq.init(9);
        edit.next_file = FileSeq.init(11);
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

        try version.apply(edit, testing_io, allocator);
    }

    {
        var reopened = try Version.from_file(dir, "manifest", testing_memtable_opts, testing_io, allocator);
        defer reopened.deinit(testing_io, allocator);

        try std.testing.expectEqual(@as(usize, 13), reopened.current_seq().get());
        try std.testing.expectEqual(@as(usize, 12), reopened.next_file.load(.monotonic).get());
        try std.testing.expectEqual(@as(usize, 1), reopened.tables.items.len);
        try std.testing.expectEqualSlices(u8, "memtable11.sst", reopened.tables.items[0].name);
    }
}
