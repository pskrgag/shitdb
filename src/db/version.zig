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
const KeyOwned = @import("storage").manifest.KeyOwned;
const WalTable = @import("wal_table.zig").WalTable;
const Wal = @import("wal.zig").Wal;
const MemTableOpts = @import("storage").MemTableOpts;
const KVSeq = @import("storage").KVSeq;
const Statistics = @import("stat.zig").Statistics;
const Slab = @import("slab").Slab;
const MemTableSlab = Slab(WalTable, 20);

const MaxLevel: usize = 2;
const MaxTablesLVL: usize = 1;

const CompactionPlan = struct {
    input_files: std.ArrayList(FoundFile),
    overlap_files: std.ArrayList(FoundFile),
    dst_lvl: u8,

    const FoundFile = struct {
        meta: FileMeta,
        idx: usize,
    };

    fn find_cadidates(files: []FileMeta, alloc: Allocator, lvl: u8) !std.ArrayList(FoundFile) {
        var res = try std.ArrayList(FoundFile).initCapacity(alloc, 2);
        var found: usize = 0;

        for (files, 0..) |file, idx| {
            if (file.lvl == lvl) {
                try res.append(alloc, .{ .meta = file, .idx = idx });
                found += 1;

                if (found == 2)
                    break;
            }
        }

        std.debug.assert(found == 2);
        return res;
    }

    pub fn new(files: []FileMeta, lvl: u8, alloc: Allocator) !CompactionPlan {
        // Step 1: find 2 lvl0 tables to compact. Basically take first 2 in a list
        var candidates = try CompactionPlan.find_cadidates(files, alloc, lvl);
        errdefer candidates.deinit(alloc);

        var next_lvl_files = try std.ArrayList(FoundFile).initCapacity(alloc, 0);
        errdefer next_lvl_files.deinit(alloc);

        // Step 2: once we've found them. Find all lvl1 tables that have overlapping key ranges
        for (files, 0..) |file, idx| {
            if (file.lvl == lvl + 1) {
                var should_consider = false;

                for (candidates.items) |candidate| {
                    should_consider |= file.key_range_overlap(candidate.meta.min.data, candidate.meta.max.data);
                    if (should_consider)
                        break;
                }

                if (should_consider)
                    try next_lvl_files.append(alloc, .{ .meta = file, .idx = idx });
            }
        }

        return .{ .dst_lvl = lvl + 1, .input_files = candidates, .overlap_files = next_lvl_files };
    }

    fn deinit(self: *CompactionPlan, alloc: Allocator) void {
        self.overlap_files.deinit(alloc);
        self.input_files.deinit(alloc);
    }
};

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
    // Stats
    stat: *Statistics,
    // Slab for freeing memtables
    slab: ?*MemTableSlab,

    const Self = @This();

    pub fn apply(self: *Self, edit: VersionEdit, dir: std.Io.Dir, io: std.Io, alloc: Allocator) !void {
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

        // Staring from here manifest is on disk. Now we can clean things up

        for (edit.new_files.items) |file| {
            try self.tables.append(alloc, file);

            std.debug.assert(file.lvl < MaxLevel);
            self.active_tables[file.lvl] += 1;
        }

        // it's n^2, but len(deleted_files) should be small
        for (edit.deleted_files.items) |file| {
            for (self.tables.items, 0..) |f, i| {
                if (f.file_seq.get() == file.file.get()) {
                    var res = self.tables.swapRemove(i);
                    res.deinit(alloc);

                    self.active_tables[file.lvl] -= 1;

                    const fname = try Self.file_name(file.file, alloc);
                    defer alloc.free(fname);
                    try dir.deleteFile(io, fname);
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

    pub fn from_file(
        dir: std.Io.Dir,
        path: []const u8,
        opts: MemTableOpts,
        stat: *Statistics,
        io: std.Io,
        alloc: Allocator,
    ) !*Self {
        return from_file_with_slab(dir, path, opts, stat, null, io, alloc);
    }

    pub fn from_file_with_slab(
        dir: std.Io.Dir,
        path: []const u8,
        opts: MemTableOpts,
        stat: *Statistics,
        slab: ?*MemTableSlab,
        io: std.Io,
        alloc: Allocator,
    ) !*Self {
        const file = dir.openFile(io, path, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => try dir.createFile(io, path, .{ .read = true }),
            else => return err,
        };
        errdefer file.close(io);

        const file_stat = try file.stat(io);
        const size = file_stat.size;
        const res = try alloc.create(Self);

        res.* = .{
            .slab = slab,
            .flusher = try Flusher.new(alloc, res, dir, io),
            .file = file,
            .tables = try std.ArrayList(FileMeta).initCapacity(alloc, 0),
            .next_file = Value(FileSeq).init(FileSeq.init(0)),
            .next_sequence = Value(KVSeq).init(KVSeq.init(0)),
            .mutex = Mutex.init,
            .wals = try std.ArrayList(FileSeq).initCapacity(alloc, 0),
            .active_tables = [_]u8{0} ** MaxLevel,
            .stat = stat,
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

        var opened_tables = try std.ArrayList(SSTable).initCapacity(alloc, 0);

        self.mutex.lockUncancelable(io);
        errdefer self.mutex.unlock(io);

        var plan = try CompactionPlan.new(self.tables.items, 0, alloc);
        defer plan.deinit(alloc);
        self.mutex.unlock(io);

        const merged_seq = self.new_file_seq();
        // name will be freed later, since it will be added to tables array
        const name = try Self.file_name(merged_seq, alloc);

        defer {
            for (opened_tables.items) |sstable|
                sstable.deinit();

            opened_tables.deinit(alloc);
        }

        for (plan.overlap_files.items) |lvl1| {
            try opened_tables.append(alloc, try SSTable.open(dir, io, lvl1.meta.name));
        }

        for (plan.input_files.items) |lvl1| {
            try opened_tables.append(alloc, try SSTable.open(dir, io, lvl1.meta.name));
        }

        const new = try SSTable.merge(dir, name, io, opened_tables.items, 1, alloc);
        defer new.deinit();

        var edit = try VersionEdit.empty(alloc);
        defer edit.deinit(alloc);

        try edit.new_files.append(alloc, FileMeta{
            .lvl = 1,
            .name = name,
            .max = try KeyOwned.from_raw(new.max(), alloc),
            .min = try KeyOwned.from_raw(new.min(), alloc),
            .file_seq = merged_seq,
            .value_seq = new.maximum_seq(),
        });

        for (plan.input_files.items) |lvl1| {
            try edit.deleted_files.append(alloc, .{ .file = lvl1.meta.file_seq, .lvl = 0 });
        }

        for (plan.overlap_files.items) |lvl1| {
            try edit.deleted_files.append(alloc, .{ .file = lvl1.meta.file_seq, .lvl = 1 });
        }

        try self.apply(edit, dir, io, alloc);
    }

    // Flushes a memtable synchronously into an SSTable and records it in the manifest.
    pub fn flush_memtable(
        self: *Version,
        table: *WalTable,
        io: std.Io,
        dir: std.Io.Dir,
        alloc: Allocator,
    ) !void {
        if (table.min() == null)
            return;

        const min = try KeyOwned.from_kv(table.min().?, alloc);
        const max = try KeyOwned.from_kv(table.max().?, alloc);

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
        var sstable = try SSTable.create(dir, name, &table.table, 0, io, alloc);
        defer sstable.deinit();

        try self.apply(edit, dir, io, alloc);
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
            const min = table.min;
            const max = table.max;
            const cmp_min = std.mem.order(u8, min.data, key);
            const cmp_max = std.mem.order(u8, max.data, key);

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
                            var res = self.tables.swapRemove(idx);
                            res.deinit(alloc);

                            self.active_tables[file.lvl] -= 1;

                            dir.deleteFile(io, file.name) catch |err| {
                                switch (err) {
                                    error.FileNotFound => {},
                                    else => return err,
                                }
                            };

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
            const alive_wal = if (self.slab) |slab|
                slab.alloc()
            else
                try alloc.create(WalTable);
            alive_wal.* = try WalTable.open(dir, opts, wal, io, alloc);

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
    deleted_files: std.ArrayList(DeletedFile),
    next_seq: ?KVSeq,
    add_wal: ?FileSeq,

    pub const DeletedFile = struct {
        file: FileSeq,
        lvl: usize,
    };

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
            try res.append(alloc, .{ .DeleteFile = file.file });
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
            .deleted_files = try std.ArrayList(DeletedFile).initCapacity(alloc, 0),
            .next_seq = null,
            .add_wal = null,
        };
    }
};

const testing_memtable_opts = MemTableOpts{ .memtable_size = 1 << 20 };

const TestSSTableKV = struct {
    key: []const u8,
    value: ?[]const u8,
    seq: usize,
};

test "Version serialization" {
    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }
    const allocator = arena.allocator();
    const testing_io = std.testing.io;
    var stat = std.mem.zeroes(Statistics);

    const dirname = "test_db10";
    try std.Io.Dir.cwd().createDir(testing_io, dirname, .default_dir);

    var dir = try std.Io.Dir.cwd().openDir(testing_io, dirname, .{});

    defer {
        dir.close(testing_io);
        std.Io.Dir.cwd().deleteTree(testing_io, dirname) catch {
            @panic("gg");
        };
    }

    var version = try Version.from_file(dir, "manifest", testing_memtable_opts, &stat, testing_io, allocator);
    defer version.deinit(testing_io, allocator);

    {
        var edit = try VersionEdit.empty(allocator);
        defer edit.deinit(allocator);
        edit.next_seq = KVSeq.init(1);
        try version.apply(edit, dir, testing_io, allocator);
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
    var memtable = try MemTable.new(alloc, std.testing.io, null);
    defer memtable.deinit(alloc);

    try memtable.put(min_key, min_value, KVSeq.init(seq));
    try memtable.put(max_key, max_value, KVSeq.init(seq + 1));

    return .{
        .name = try alloc.dupe(u8, name),
        .lvl = lvl,
        .file_seq = FileSeq.init(seq),
        .min = try KeyOwned.from_kv(memtable.min().?, alloc),
        .max = try KeyOwned.from_kv(memtable.max().?, alloc),
        .value_seq = KVSeq.init(seq + 1),
    };
}

fn create_test_sstable(
    dir: std.Io.Dir,
    io: std.Io,
    alloc: Allocator,
    name: []const u8,
    lvl: u8,
    file_seq: usize,
    keys: []const TestSSTableKV,
) !FileMeta {
    var memtable = try MemTable.new(alloc, io, null);
    defer memtable.deinit(alloc);

    for (keys) |kv| {
        if (kv.value) |value| {
            try memtable.put(kv.key, value, KVSeq.init(kv.seq));
        } else {
            try memtable.remove(kv.key, KVSeq.init(kv.seq));
        }
    }

    var sstable = try SSTable.create(dir, name, &memtable, lvl, io, alloc);
    defer sstable.deinit();

    return .{
        .name = try alloc.dupe(u8, name),
        .lvl = lvl,
        .file_seq = FileSeq.init(file_seq),
        .min = try KeyOwned.from_raw(sstable.min(), alloc),
        .max = try KeyOwned.from_raw(sstable.max(), alloc),
        .value_seq = sstable.maximum_seq(),
    };
}

fn expect_l1_non_overlapping(version: *const Version) !void {
    for (version.tables.items, 0..) |lhs, lhs_idx| {
        if (lhs.lvl != 1)
            continue;

        for (version.tables.items[lhs_idx + 1 ..]) |rhs| {
            if (rhs.lvl != 1)
                continue;

            try std.testing.expect(!lhs.key_range_overlap(rhs.min.data, rhs.max.data));
        }
    }
}

fn expect_file_exists(dir: std.Io.Dir, io: std.Io, name: []const u8) !void {
    const file = try dir.openFile(io, name, .{});
    file.close(io);
}

fn expect_file_deleted(dir: std.Io.Dir, io: std.Io, name: []const u8) !void {
    const file = dir.openFile(io, name, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    file.close(io);

    return error.FileStillExists;
}

test "FileMeta key range overlap includes shared boundary keys" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const meta = try test_file_meta(
        allocator,
        "memtable1.sst",
        1,
        1,
        "c",
        "first",
        "m",
        "last",
    );

    try std.testing.expect(meta.key_range_overlap("a", "c"));
    try std.testing.expect(meta.key_range_overlap("m", "z"));
    try std.testing.expect(meta.key_range_overlap("d", "e"));
    try std.testing.expect(!meta.key_range_overlap("a", "b"));
    try std.testing.expect(!meta.key_range_overlap("n", "z"));
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
    var stat = std.mem.zeroes(Statistics);

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
        var version = try Version.from_file(dir, "manifest", testing_memtable_opts, &stat, testing_io, allocator);
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

        try version.apply(edit, dir, testing_io, allocator);
    }

    {
        var reopened = try Version.from_file(dir, "manifest", testing_memtable_opts, &stat, testing_io, allocator);
        defer reopened.deinit(testing_io, allocator);

        try std.testing.expectEqual(@as(usize, 13), reopened.current_seq().get());
        try std.testing.expectEqual(@as(usize, 12), reopened.next_file.load(.monotonic).get());
        try std.testing.expectEqual(@as(usize, 1), reopened.tables.items.len);
        try std.testing.expectEqualSlices(u8, "memtable11.sst", reopened.tables.items[0].name);
    }
}

test "lvl0 compaction merges overlapping lvl1 table" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const testing_io = std.testing.io;
    var stat = std.mem.zeroes(Statistics);

    const dirname = "test_db_l0_compaction_overlapping_l1";
    std.Io.Dir.cwd().deleteTree(testing_io, dirname) catch {};
    try std.Io.Dir.cwd().createDir(testing_io, dirname, .default_dir);

    var dir = try std.Io.Dir.cwd().openDir(testing_io, dirname, .{});
    defer {
        dir.close(testing_io);
        std.Io.Dir.cwd().deleteTree(testing_io, dirname) catch {
            @panic("failed to delete test db");
        };
    }

    var version = try Version.from_file(dir, "manifest", testing_memtable_opts, &stat, testing_io, allocator);
    defer version.deinit(testing_io, allocator);

    var edit = try VersionEdit.empty(allocator);
    defer edit.deinit(allocator);
    edit.next_file = FileSeq.init(4);

    try edit.new_files.append(
        allocator,
        try create_test_sstable(
            dir,
            testing_io,
            allocator,
            "memtable1.sst",
            1,
            1,
            &[_]TestSSTableKV{
                .{ .key = "b", .value = "old", .seq = 1 },
            },
        ),
    );
    try edit.new_files.append(
        allocator,
        try create_test_sstable(
            dir,
            testing_io,
            allocator,
            "memtable2.sst",
            0,
            2,
            &[_]TestSSTableKV{
                .{ .key = "b", .value = null, .seq = 2 },
            },
        ),
    );
    try edit.new_files.append(
        allocator,
        try create_test_sstable(
            dir,
            testing_io,
            allocator,
            "memtable3.sst",
            0,
            3,
            &[_]TestSSTableKV{
                .{ .key = "a", .value = "fresh", .seq = 3 },
            },
        ),
    );

    try version.apply(edit, dir, testing_io, allocator);
    try version.compact_lvl0(dir, testing_io, allocator);

    try std.testing.expectEqual(@as(usize, 1), version.tables.items.len);
    try std.testing.expectEqual(@as(u8, 0), version.active_tables[0]);
    try std.testing.expectEqual(@as(u8, 1), version.active_tables[1]);
    try std.testing.expectEqual(@as(u8, 1), version.tables.items[0].lvl);
    try expect_l1_non_overlapping(version);

    try std.testing.expectEqual(null, try version.get("b", dir, testing_io, allocator));

    const value = (try version.get("a", dir, testing_io, allocator)).?;
    try std.testing.expectEqualSlices(u8, "fresh", value);
}

test "lvl0 compaction keeps non-overlapping lvl1 table" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const testing_io = std.testing.io;
    var stat = std.mem.zeroes(Statistics);

    const dirname = "test_db_l0_compaction_non_overlapping_l1";
    std.Io.Dir.cwd().deleteTree(testing_io, dirname) catch {};
    try std.Io.Dir.cwd().createDir(testing_io, dirname, .default_dir);

    var dir = try std.Io.Dir.cwd().openDir(testing_io, dirname, .{});
    defer {
        dir.close(testing_io);
        std.Io.Dir.cwd().deleteTree(testing_io, dirname) catch {
            @panic("failed to delete test db");
        };
    }

    var version = try Version.from_file(dir, "manifest", testing_memtable_opts, &stat, testing_io, allocator);
    defer version.deinit(testing_io, allocator);

    var edit = try VersionEdit.empty(allocator);
    defer edit.deinit(allocator);
    edit.next_file = FileSeq.init(4);

    try edit.new_files.append(
        allocator,
        try create_test_sstable(
            dir,
            testing_io,
            allocator,
            "memtable1.sst",
            1,
            1,
            &[_]TestSSTableKV{
                .{ .key = "z", .value = "old", .seq = 1 },
            },
        ),
    );
    try edit.new_files.append(
        allocator,
        try create_test_sstable(
            dir,
            testing_io,
            allocator,
            "memtable2.sst",
            0,
            2,
            &[_]TestSSTableKV{
                .{ .key = "a", .value = "fresh-a", .seq = 2 },
            },
        ),
    );
    try edit.new_files.append(
        allocator,
        try create_test_sstable(
            dir,
            testing_io,
            allocator,
            "memtable3.sst",
            0,
            3,
            &[_]TestSSTableKV{
                .{ .key = "b", .value = "fresh-b", .seq = 3 },
            },
        ),
    );

    try version.apply(edit, dir, testing_io, allocator);
    try version.compact_lvl0(dir, testing_io, allocator);

    try std.testing.expectEqual(@as(usize, 2), version.tables.items.len);
    try std.testing.expectEqual(@as(u8, 0), version.active_tables[0]);
    try std.testing.expectEqual(@as(u8, 2), version.active_tables[1]);
    try expect_l1_non_overlapping(version);

    const old = (try version.get("z", dir, testing_io, allocator)).?;
    try std.testing.expectEqualSlices(u8, "old", old);

    const fresh_a = (try version.get("a", dir, testing_io, allocator)).?;
    try std.testing.expectEqualSlices(u8, "fresh-a", fresh_a);

    const fresh_b = (try version.get("b", dir, testing_io, allocator)).?;
    try std.testing.expectEqualSlices(u8, "fresh-b", fresh_b);
}

test "lvl0 compaction includes lvl1 table that shares boundary key" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const testing_io = std.testing.io;
    var stat = std.mem.zeroes(Statistics);

    const dirname = "test_db_l0_compaction_boundary_l1";
    std.Io.Dir.cwd().deleteTree(testing_io, dirname) catch {};
    try std.Io.Dir.cwd().createDir(testing_io, dirname, .default_dir);

    var dir = try std.Io.Dir.cwd().openDir(testing_io, dirname, .{});
    defer {
        dir.close(testing_io);
        std.Io.Dir.cwd().deleteTree(testing_io, dirname) catch {
            @panic("failed to delete test db");
        };
    }

    var version = try Version.from_file(dir, "manifest", testing_memtable_opts, &stat, testing_io, allocator);
    defer version.deinit(testing_io, allocator);

    var edit = try VersionEdit.empty(allocator);
    defer edit.deinit(allocator);
    edit.next_file = FileSeq.init(4);

    try edit.new_files.append(
        allocator,
        try create_test_sstable(
            dir,
            testing_io,
            allocator,
            "memtable1.sst",
            1,
            1,
            &[_]TestSSTableKV{
                .{ .key = "b", .value = "old", .seq = 1 },
            },
        ),
    );
    try edit.new_files.append(
        allocator,
        try create_test_sstable(
            dir,
            testing_io,
            allocator,
            "memtable2.sst",
            0,
            2,
            &[_]TestSSTableKV{
                .{ .key = "a", .value = "fresh-a", .seq = 2 },
                .{ .key = "b", .value = null, .seq = 3 },
            },
        ),
    );
    try edit.new_files.append(
        allocator,
        try create_test_sstable(
            dir,
            testing_io,
            allocator,
            "memtable3.sst",
            0,
            3,
            &[_]TestSSTableKV{
                .{ .key = "c", .value = "fresh-c", .seq = 4 },
            },
        ),
    );

    try version.apply(edit, dir, testing_io, allocator);
    try version.compact_lvl0(dir, testing_io, allocator);

    try std.testing.expectEqual(@as(usize, 1), version.tables.items.len);
    try std.testing.expectEqual(@as(u8, 0), version.active_tables[0]);
    try std.testing.expectEqual(@as(u8, 1), version.active_tables[1]);
    try expect_l1_non_overlapping(version);

    try std.testing.expectEqual(null, try version.get("b", dir, testing_io, allocator));

    const fresh_a = (try version.get("a", dir, testing_io, allocator)).?;
    try std.testing.expectEqualSlices(u8, "fresh-a", fresh_a);

    const fresh_c = (try version.get("c", dir, testing_io, allocator)).?;
    try std.testing.expectEqualSlices(u8, "fresh-c", fresh_c);
}

test "lvl0 compaction physically deletes obsolete input files" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const testing_io = std.testing.io;
    var stat = std.mem.zeroes(Statistics);

    const dirname = "test_db_l0_compaction_physical_delete";
    std.Io.Dir.cwd().deleteTree(testing_io, dirname) catch {};
    try std.Io.Dir.cwd().createDir(testing_io, dirname, .default_dir);

    var dir = try std.Io.Dir.cwd().openDir(testing_io, dirname, .{});
    defer {
        dir.close(testing_io);
        std.Io.Dir.cwd().deleteTree(testing_io, dirname) catch {
            @panic("failed to delete test db");
        };
    }

    var version = try Version.from_file(dir, "manifest", testing_memtable_opts, &stat, testing_io, allocator);
    defer version.deinit(testing_io, allocator);

    var edit = try VersionEdit.empty(allocator);
    defer edit.deinit(allocator);
    edit.next_file = FileSeq.init(4);

    try edit.new_files.append(
        allocator,
        try create_test_sstable(
            dir,
            testing_io,
            allocator,
            "memtable1.sst",
            1,
            1,
            &[_]TestSSTableKV{
                .{ .key = "b", .value = "old", .seq = 1 },
            },
        ),
    );
    try edit.new_files.append(
        allocator,
        try create_test_sstable(
            dir,
            testing_io,
            allocator,
            "memtable2.sst",
            0,
            2,
            &[_]TestSSTableKV{
                .{ .key = "b", .value = null, .seq = 2 },
            },
        ),
    );
    try edit.new_files.append(
        allocator,
        try create_test_sstable(
            dir,
            testing_io,
            allocator,
            "memtable3.sst",
            0,
            3,
            &[_]TestSSTableKV{
                .{ .key = "a", .value = "fresh", .seq = 3 },
            },
        ),
    );

    try version.apply(edit, dir, testing_io, allocator);
    try expect_file_exists(dir, testing_io, "memtable1.sst");
    try expect_file_exists(dir, testing_io, "memtable2.sst");
    try expect_file_exists(dir, testing_io, "memtable3.sst");

    try version.compact_lvl0(dir, testing_io, allocator);

    try expect_file_deleted(dir, testing_io, "memtable1.sst");
    try expect_file_deleted(dir, testing_io, "memtable2.sst");
    try expect_file_deleted(dir, testing_io, "memtable3.sst");
    try expect_file_exists(dir, testing_io, version.tables.items[0].name);
}

test "lvl0 compaction preserves non-overlapping lvl1 file on disk" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const testing_io = std.testing.io;
    var stat = std.mem.zeroes(Statistics);

    const dirname = "test_db_l0_compaction_physical_keep";
    std.Io.Dir.cwd().deleteTree(testing_io, dirname) catch {};
    try std.Io.Dir.cwd().createDir(testing_io, dirname, .default_dir);

    var dir = try std.Io.Dir.cwd().openDir(testing_io, dirname, .{});
    defer {
        dir.close(testing_io);
        std.Io.Dir.cwd().deleteTree(testing_io, dirname) catch {
            @panic("failed to delete test db");
        };
    }

    var version = try Version.from_file(dir, "manifest", testing_memtable_opts, &stat, testing_io, allocator);
    defer version.deinit(testing_io, allocator);

    var edit = try VersionEdit.empty(allocator);
    defer edit.deinit(allocator);
    edit.next_file = FileSeq.init(4);

    try edit.new_files.append(
        allocator,
        try create_test_sstable(
            dir,
            testing_io,
            allocator,
            "memtable1.sst",
            1,
            1,
            &[_]TestSSTableKV{
                .{ .key = "z", .value = "old", .seq = 1 },
            },
        ),
    );
    try edit.new_files.append(
        allocator,
        try create_test_sstable(
            dir,
            testing_io,
            allocator,
            "memtable2.sst",
            0,
            2,
            &[_]TestSSTableKV{
                .{ .key = "a", .value = "fresh-a", .seq = 2 },
            },
        ),
    );
    try edit.new_files.append(
        allocator,
        try create_test_sstable(
            dir,
            testing_io,
            allocator,
            "memtable3.sst",
            0,
            3,
            &[_]TestSSTableKV{
                .{ .key = "b", .value = "fresh-b", .seq = 3 },
            },
        ),
    );

    try version.apply(edit, dir, testing_io, allocator);
    try version.compact_lvl0(dir, testing_io, allocator);

    try expect_file_exists(dir, testing_io, "memtable1.sst");
    try expect_file_deleted(dir, testing_io, "memtable2.sst");
    try expect_file_deleted(dir, testing_io, "memtable3.sst");

    for (version.tables.items) |table| {
        try expect_file_exists(dir, testing_io, table.name);
    }
}

test "lvl0 compaction manifest replay restores live tables and counts" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const testing_io = std.testing.io;
    var stat = std.mem.zeroes(Statistics);

    const dirname = "test_db_l0_compaction_replay";
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
        var version = try Version.from_file(dir, "manifest", testing_memtable_opts, &stat, testing_io, allocator);
        defer version.deinit(testing_io, allocator);

        var edit = try VersionEdit.empty(allocator);
        defer edit.deinit(allocator);
        edit.next_file = FileSeq.init(4);

        try edit.new_files.append(
            allocator,
            try create_test_sstable(
                dir,
                testing_io,
                allocator,
                "memtable1.sst",
                1,
                1,
                &[_]TestSSTableKV{
                    .{ .key = "b", .value = "old", .seq = 1 },
                },
            ),
        );
        try edit.new_files.append(
            allocator,
            try create_test_sstable(
                dir,
                testing_io,
                allocator,
                "memtable2.sst",
                0,
                2,
                &[_]TestSSTableKV{
                    .{ .key = "b", .value = null, .seq = 2 },
                },
            ),
        );
        try edit.new_files.append(
            allocator,
            try create_test_sstable(
                dir,
                testing_io,
                allocator,
                "memtable3.sst",
                0,
                3,
                &[_]TestSSTableKV{
                    .{ .key = "a", .value = "fresh", .seq = 3 },
                },
            ),
        );

        try version.apply(edit, dir, testing_io, allocator);
        try version.compact_lvl0(dir, testing_io, allocator);
    }

    {
        var reopened = try Version.from_file(dir, "manifest", testing_memtable_opts, &stat, testing_io, allocator);
        defer reopened.deinit(testing_io, allocator);

        try std.testing.expectEqual(@as(usize, 1), reopened.tables.items.len);
        try std.testing.expectEqual(@as(u8, 0), reopened.active_tables[0]);
        try std.testing.expectEqual(@as(u8, 1), reopened.active_tables[1]);
        try std.testing.expectEqual(@as(u8, 1), reopened.tables.items[0].lvl);
        try expect_l1_non_overlapping(reopened);

        try std.testing.expectEqual(null, try reopened.get("b", dir, testing_io, allocator));

        const value = (try reopened.get("a", dir, testing_io, allocator)).?;
        try std.testing.expectEqualSlices(u8, "fresh", value);
    }
}

test "lvl0 compaction replay keeps non-overlapping lvl1 table" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const testing_io = std.testing.io;
    var stat = std.mem.zeroes(Statistics);

    const dirname = "test_db_l0_compaction_replay_non_overlapping_l1";
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
        var version = try Version.from_file(dir, "manifest", testing_memtable_opts, &stat, testing_io, allocator);
        defer version.deinit(testing_io, allocator);

        var edit = try VersionEdit.empty(allocator);
        defer edit.deinit(allocator);
        edit.next_file = FileSeq.init(4);

        try edit.new_files.append(
            allocator,
            try create_test_sstable(
                dir,
                testing_io,
                allocator,
                "memtable1.sst",
                1,
                1,
                &[_]TestSSTableKV{
                    .{ .key = "z", .value = "old", .seq = 1 },
                },
            ),
        );
        try edit.new_files.append(
            allocator,
            try create_test_sstable(
                dir,
                testing_io,
                allocator,
                "memtable2.sst",
                0,
                2,
                &[_]TestSSTableKV{
                    .{ .key = "a", .value = "fresh-a", .seq = 2 },
                },
            ),
        );
        try edit.new_files.append(
            allocator,
            try create_test_sstable(
                dir,
                testing_io,
                allocator,
                "memtable3.sst",
                0,
                3,
                &[_]TestSSTableKV{
                    .{ .key = "b", .value = "fresh-b", .seq = 3 },
                },
            ),
        );

        try version.apply(edit, dir, testing_io, allocator);
        try version.compact_lvl0(dir, testing_io, allocator);
    }

    {
        var reopened = try Version.from_file(dir, "manifest", testing_memtable_opts, &stat, testing_io, allocator);
        defer reopened.deinit(testing_io, allocator);

        try std.testing.expectEqual(@as(usize, 2), reopened.tables.items.len);
        try std.testing.expectEqual(@as(u8, 0), reopened.active_tables[0]);
        try std.testing.expectEqual(@as(u8, 2), reopened.active_tables[1]);
        try expect_l1_non_overlapping(reopened);

        const old = (try reopened.get("z", dir, testing_io, allocator)).?;
        try std.testing.expectEqualSlices(u8, "old", old);

        const fresh_a = (try reopened.get("a", dir, testing_io, allocator)).?;
        try std.testing.expectEqualSlices(u8, "fresh-a", fresh_a);

        const fresh_b = (try reopened.get("b", dir, testing_io, allocator)).?;
        try std.testing.expectEqualSlices(u8, "fresh-b", fresh_b);
    }
}
