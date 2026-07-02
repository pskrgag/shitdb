const std = @import("std");
const File = std.Io.File;
const MemTable = @import("storage").memtable.MemTable;
const SSTable = @import("storage").sstable.SSTable;
const manifest = @import("storage").manifest;
const Flusher = @import("flusher.zig").Flusher;
const Allocator = std.mem.Allocator;
const KeyValueOwned = @import("storage").memtable.KeyValueOwned;
const Mutex = @import("sync").mutex.Mutex;
const Value = std.atomic.Value;
const FileMeta = @import("storage").manifest.FileMeta;
const FileSeq = @import("storage").manifest.FileSeq;
const KeyOwned = @import("storage").manifest.KeyOwned;
const WalTable = @import("wal_table.zig").WalTable;
const Wal = @import("wal.zig").Wal;
const WalOpts = @import("wal.zig").WalOpts;
const MemTableOpts = @import("storage").memtable.MemTableOpts;
const KVSeq = @import("storage").memtable.KVSeq;
const Statistics = @import("stat.zig").Statistics;
const Slab = @import("slab").Slab;
const MemTableSlab = Slab(WalTable, 20);
const Transaction = @import("manager.zig").Transaction;
const CompactionPlan = @import("compaction.zig").CompactionPlan;
const OutputFileSource = @import("storage").sstable.OutputFileSource;
const MaxSupportedLvls = @import("compaction.zig").MaxSupportedLvls;
const CompactionOptions = @import("compaction.zig").CompactionOptions;
const KeyValueOptions = @import("manager.zig").KeyValueOptions;
const Storage = @import("storage").storage.Storage;

pub const Version = struct {
    // File handle
    file: File,
    // Next file number
    next_file: Value(FileSeq),
    // Next sequence number
    next_sequence: Value(KVSeq),
    // Alive SSTables
    tables: std.ArrayList(FileMeta),
    // Protects concurrent edit applies
    mutex: Mutex,
    // Flusher that periodically flushes immutable tables
    flusher: *Flusher,
    // Stats
    stat: *Statistics,
    // Slab for freeing memtables
    slab: *MemTableSlab,
    // Active MemTable.
    //
    // TODO: this must not be null, but it helps for error handling during Version creation. There
    // is weird thing that Wal actually want version pointer... This should be fixed one day.
    active: ?*WalTable,
    // Options
    opts: KeyValueOptions,

    const Self = @This();

    pub fn apply(self: *Self, edit: VersionEdit, storage: *Storage, io: std.Io, alloc: Allocator) !void {
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
        }

        // it's n^2, but len(deleted_files) should be small
        for (edit.deleted_files.items) |file| {
            for (self.tables.items, 0..) |f, i| {
                if (f.file_seq.get() == file.file.get()) {
                    var res = self.tables.swapRemove(i);
                    try storage.unlink_sstable(res, io, alloc);
                    res.deinit(alloc);

                    break;
                }
            }
        }

        if (edit.next_file) |next_file| {
            self.next_file = Value(FileSeq).init(next_file);
        }
    }

    pub fn rotate_active(self: *Self, storage: *Storage, flush: bool, io: std.Io, alloc: Allocator) !void {
        const next_file = self.new_file_seq();
        const new_table = self.slab.alloc();

        new_table.* = try WalTable.new(
            storage,
            self.opts.memtable,
            self.opts.wal,
            next_file,
            self,
            io,
            alloc,
        );
        try self.flusher.insert(self.active.?);
        self.active = new_table;

        if (flush)
            try self.flusher.flush_all();
    }

    // Tries to commits transaction into DB. In case of any failure it must mark failed requests
    // with an error.
    pub fn commit(
        self: *Self,
        t: Transaction,
        storage: *Storage,
        io: std.Io,
        alloc: Allocator,
    ) !void {
        var trans = t;
        const res = self.active.?.commit(&trans, alloc);
        if (res.need_rotate or res.wal_failed) {
            errdefer |e| {
                // There was an error while processing transaction. We need to mark all pending
                // transactions as failed to propagate this info to callers.
                //
                // If error happened in active.commit, it will return !full and
                // we will retry the request.
                trans.mark_error(e);
            }

            try self.rotate_active(storage, res.wal_failed, io, alloc);
            // Try to commit to new table
            try self.commit(trans, storage, io, alloc);
        }
    }

    pub fn allocate_seqs(self: *Self, count: usize) KVSeq {
        return self.next_sequence.fetchAdd(KVSeq.init(count), .monotonic);
    }

    pub fn current_seq(self: *Self) KVSeq {
        return self.next_sequence.load(.monotonic);
    }

    pub fn new_file_seq(self: *Self) FileSeq {
        return self.next_file.fetchAdd(FileSeq.init(1), .monotonic);
    }

    pub fn from_file(
        storage: *Storage,
        path: []const u8,
        opts: KeyValueOptions,
        stat: *Statistics,
        sanitize: bool,
        io: std.Io,
        alloc: Allocator,
    ) !*Self {
        var file = try storage.open_or_create_manifest(path, io);
        errdefer file.close(io);

        const slab = try alloc.create(MemTableSlab);
        errdefer alloc.destroy(slab);
        slab.* = try MemTableSlab.init(alloc, io);
        errdefer slab.deinit(alloc);

        const file_stat = try file.stat(io);
        const size = file_stat.size;
        const res = try alloc.create(Self);

        res.* = .{
            .slab = slab,
            .flusher = try Flusher.new(alloc, res, storage, io),
            .file = file,
            .tables = try std.ArrayList(FileMeta).initCapacity(alloc, 0),
            .next_file = Value(FileSeq).init(FileSeq.init(0)),
            .next_sequence = Value(KVSeq).init(KVSeq.init(0)),
            .mutex = Mutex.init,
            .stat = stat,
            .opts = opts,
            .active = null,
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
            try res.replay(storage, rep, opts.memtable, opts.wal, io, alloc);
        }

        const active = res.slab.alloc();

        active.* = try WalTable.new(
            storage,
            opts.memtable,
            opts.wal,
            res.new_file_seq(),
            res,
            io,
            alloc,
        );
        errdefer {
            active.deinit(alloc) catch @panic("Should not happen, since MemTable is empty");
        }
        res.active = active;

        if (sanitize)
            try res.sanitize_disk_state(storage, alloc, io);

        return res;
    }

    // Inserts new immutable memtable
    pub fn insert(self: *Version, table: *WalTable) !void {
        try self.flusher.insert(table);
    }

    fn file_name(seq: FileSeq, alloc: Allocator) ![]const u8 {
        const res = std.fmt.allocPrint(alloc, "memtable{}.sst", .{seq.get()});
        return res;
    }

    fn file_seq_source(self: *Self) OutputFileSource {
        return .{
            .ctx = self,
            .nextFile = struct {
                fn next(ctx: *anyopaque) !FileSeq {
                    const ptr: *Self = @ptrCast(@alignCast(ctx));

                    return ptr.new_file_seq();
                }
            }.next,
        };
    }

    fn run_compaction_plan(
        self: *Version,
        plan: CompactionPlan,
        storage: *Storage,
        io: std.Io,
        alloc: Allocator,
    ) !void {
        var edit = try VersionEdit.empty(alloc);
        defer edit.deinit(alloc);

        var opened_tables = try std.ArrayList(SSTable).initCapacity(alloc, 0);
        defer {
            for (opened_tables.items) |*sstable|
                sstable.deinit(io);

            opened_tables.deinit(alloc);
        }

        for (plan.overlap_files.items) |n| {
            try opened_tables.append(alloc, try SSTable.open(storage, n.meta, io, alloc));
            try edit.deleted_files.append(alloc, .{ .file = n.meta.file_seq, .lvl = n.meta.lvl });
        }

        for (plan.input_files.items) |n| {
            try opened_tables.append(alloc, try SSTable.open(storage, n.meta, io, alloc));
            try edit.deleted_files.append(alloc, .{ .file = n.meta.file_seq, .lvl = n.meta.lvl });
        }

        var new = try SSTable.merge(
            storage,
            self.file_seq_source(),
            io,
            opened_tables.items,
            plan.dst_lvl,
            self.opts.compaction.sstable_target_size,
            alloc,
        );

        defer {
            new.deinit(alloc);
        }

        // There is a hacky ownership transfer. In case of success of this push, transfer is moved
        // to edit. Otherwise we need to free min/max allocated in SSTable.merge.
        edit.new_files.appendSlice(alloc, new.items) catch |e| {
            for (new.items) |*meta| {
                meta.deinit(alloc);
            }
            return e;
        };

        try self.apply(edit, storage, io, alloc);
    }

    fn compact(
        self: *Version,
        storage: *Storage,
        opts: CompactionOptions,
        io: std.Io,
        alloc: Allocator,
    ) !void {
        while (true) {
            // Plans borrow FileMeta key slices. This is safe because compaction is single-threaded
            // in the flusher, and only compaction removes table metadata.
            const p = blk: {
                self.mutex.lockUncancelable(io);
                defer self.mutex.unlock(io);

                break :blk try CompactionPlan.new(storage, self.tables.items, opts, alloc);
            };

            if (p) |pp| {
                // fucking zig, lol. Captures are const, so I have to make an extra local variable
                // here
                var plan = pp;
                defer plan.deinit(alloc);

                try self.run_compaction_plan(plan, storage, io, alloc);
                self.stat.inc(.compaction);
            } else {
                break;
            }
        }
    }

    // Flushes a memtable synchronously into an SSTable and records it in the manifest.
    pub fn flush_memtable(
        self: *Version,
        table: *WalTable,
        do_compact: bool,
        io: std.Io,
        storage: *Storage,
        alloc: Allocator,
    ) !void {
        if (table.min() == null)
            return;

        const min = try KeyOwned.from_kv(table.min().?, alloc);
        const max = try KeyOwned.from_kv(table.max().?, alloc);

        var edit = try VersionEdit.empty(alloc);
        defer edit.deinit(alloc);

        const meta = FileMeta{
            .lvl = 0,
            .max = max,
            .min = min,
            .file_seq = table.seq,
            .value_seq = table.max_seq(),
        };
        try edit.new_files.append(alloc, meta);

        // TODO: maybe make SSTable::create generic over table type? Accessing table.table is ugly
        // af.
        var sstable = try SSTable.create(storage, meta, &table.table, io, alloc);
        defer sstable.deinit(io);

        try self.apply(edit, storage, io, alloc);
        if (do_compact)
            try self.compact(storage, self.opts.compaction, io, alloc);
    }

    // Resolves value request.
    pub fn get(self: *Self, key: []const u8, storage: *Storage, io: std.Io, alloc: Allocator) !?[]u8 {
        // Resolve from current active table
        const active_find_res = try self.active.?.get(key, self.current_seq(), alloc);

        switch (active_find_res) {
            .Found => |val| {
                defer alloc.free(val);
                var res = try std.ArrayList(u8).initCapacity(alloc, val.len);

                try res.appendSlice(alloc, val);
                return res.items;
            },
            .Removed => return null,
            .NotFound => {},
        }

        // Resolved from immutable table
        const find_res = try self.flusher.get(key, self.current_seq(), alloc);

        switch (find_res) {
            .Found => |val| {
                defer alloc.free(val);
                var res = try std.ArrayList(u8).initCapacity(alloc, val.len);

                try res.appendSlice(alloc, val);
                return res.items;
            },
            .Removed => return null,
            .NotFound => {},
        }

        // Search sstables on a disk
        return self.search_disk(key, storage, io, alloc);
    }

    fn search_disk(self: *Self, key: []const u8, storage: *Storage, io: std.Io, alloc: Allocator) !?[]u8 {
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
            var ss = try SSTable.open(storage, table, io, alloc);
            defer ss.deinit(io);
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
        storage: *Storage,
        edits: std.ArrayList(manifest.ManifestRecord),
        opts: MemTableOpts,
        wal_opts: WalOpts,
        io: std.Io,
        alloc: Allocator,
    ) !void {
        var wals = try std.ArrayList(FileSeq).initCapacity(alloc, 0);
        defer wals.deinit(alloc);

        for (edits.items) |edit| {
            switch (edit) {
                .NextFileNumber => |next| self.next_file.store(next, .monotonic),
                .NextSeqNumber => |next| self.next_sequence.store(KVSeq.init(next), .monotonic),
                .AddFile => |f| {
                    try self.tables.append(alloc, f);
                    std.debug.assert(f.lvl < MaxSupportedLvls);

                    if (self.next_file.load(.monotonic).get() <= f.file_seq.get()) {
                        self.next_file.store(FileSeq.init(f.file_seq.get() + 1), .monotonic);
                    }

                    if (self.next_sequence.load(.monotonic).get() <= f.value_seq.get()) {
                        self.next_sequence.store(KVSeq.init(f.value_seq.get() + 1), .monotonic);
                    }

                    for (wals.items, 0..) |wal, idx| {
                        if (wal.get() == f.file_seq.get()) {
                            const old_wal = wals.swapRemove(idx);

                            // I don't really want to abort initialization in of WAL GC failure.
                            Wal.unlink(storage, old_wal, io, alloc) catch |e| {
                                std.debug.print("Failed to delete old WAL {}", .{e});
                            };
                            break;
                        }
                    }

                    storage.record_sstable(f, io, alloc) catch |e| {
                        if (e != error.FileNotFound)
                            return e;
                    };
                },
                .AddWal => |wal| {
                    try wals.append(alloc, wal);
                },
                .DeleteFile => |f| {
                    var found = false;

                    for (self.tables.items, 0..) |file, idx| {
                        if (file.file_seq.get() == f.get()) {
                            var res = self.tables.swapRemove(idx);
                            storage.unlink_sstable(res, io, alloc) catch |err| {
                                switch (err) {
                                    error.FileNotFound => {},
                                    else => return err,
                                }
                            };
                            res.deinit(alloc);

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
        for (wals.items) |wal| {
            const alive_wal = self.slab.alloc();

            alive_wal.* = try WalTable.open(storage, opts, wal_opts, wal, io, alloc);

            if (alive_wal.max_seq().get() > self.next_sequence.load(.monotonic).get()) {
                self.next_sequence.store(KVSeq.init(alive_wal.max_seq().get() + 1), .monotonic);
            }

            alive_wal.make_immune();
            try self.insert(alive_wal);
        }
    }

    pub fn sanitize_disk_state(self: *Self, storage: *Storage, alloc: Allocator, io: std.Io) !void {
        var sorted = try std.ArrayList(FileMeta).initCapacity(alloc, self.tables.items.len);

        defer sorted.deinit(alloc);

        try sorted.appendSlice(alloc, self.tables.items);
        std.mem.sort(FileMeta, sorted.items, {}, FileMeta.less_than);

        var max: ?usize = null;

        for (sorted.items) |table| {
            const name = try manifest.alloc_sstable_name(table.file_seq, alloc);
            defer alloc.free(name);

            const sstable = SSTable.open(storage, table, io, alloc) catch |e| {
                std.debug.print("Failed to open {s}\n", .{name});
                return e;
            };

            if (max) |m| {
                std.debug.assert(sstable.maximum_seq().get() < m);
                max = sstable.maximum_seq().get();
            }
        }
    }

    // De-initializes version
    pub fn deinit(self: *Version, io: std.Io, alloc: Allocator) void {
        if (self.active) |active| {
            self.flusher.insert(active) catch {
                std.debug.print("Failed to insert data into flusher\n", .{});
                active.deinit(alloc) catch @panic("todo");
            };

            self.active = undefined;
        }

        // It's required to destroy flusher first, since it may want to apply some changes to version.
        self.flusher.deinit(alloc);
        self.slab.deinit(alloc);
        alloc.destroy(self.slab);

        for (self.tables.items) |*table| {
            table.deinit(alloc);
        }

        self.tables.deinit(alloc);
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
const testing_opts = KeyValueOptions{ .memtable = testing_memtable_opts };

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
    std.Io.Dir.cwd().deleteTree(testing_io, dirname) catch {};
    try std.Io.Dir.cwd().createDir(testing_io, dirname, .default_dir);

    const dir = try std.Io.Dir.cwd().openDir(testing_io, dirname, .{});
    var storage = try Storage.new(dir, 100, allocator);

    defer {
        storage.deinit(testing_io, allocator);
        std.Io.Dir.cwd().deleteTree(testing_io, dirname) catch {
            @panic("gg");
        };
    }

    var version = try Version.from_file(&storage, "manifest", testing_opts, &stat, false, testing_io, allocator);
    defer version.deinit(testing_io, allocator);

    {
        var edit = try VersionEdit.empty(allocator);
        defer edit.deinit(allocator);
        edit.next_seq = KVSeq.init(1);
        try version.apply(edit, &storage, testing_io, allocator);
    }
}

fn test_file_meta(
    storage: ?*Storage,
    alloc: Allocator,
    lvl: u8,
    seq: usize,
    min_key: []const u8,
    min_value: []const u8,
    max_key: []const u8,
    max_value: []const u8,
) !FileMeta {
    var memtable = try MemTable.new(alloc, std.testing.io, .{});
    defer memtable.deinit(alloc);
    const testing_io = std.testing.io;

    try memtable.put(min_key, min_value, KVSeq.init(seq));
    try memtable.put(max_key, max_value, KVSeq.init(seq + 1));

    const meta = FileMeta{
        .lvl = lvl,
        .file_seq = FileSeq.init(seq),
        .min = try KeyOwned.from_kv(memtable.min().?, alloc),
        .max = try KeyOwned.from_kv(memtable.max().?, alloc),
        .value_seq = KVSeq.init(seq + 1),
    };

    if (storage) |st| {
        var table = try SSTable.create(st, meta, &memtable, testing_io, alloc);
        table.deinit(testing_io);
    }

    return meta;
}

fn create_test_sstable(
    storage: *Storage,
    io: std.Io,
    alloc: Allocator,
    lvl: u8,
    file_seq: usize,
    keys: []const TestSSTableKV,
) !FileMeta {
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

    var sstable = try SSTable.create(storage, meta, &memtable, io, alloc);
    defer sstable.deinit(io);

    meta.value_seq = sstable.maximum_seq();
    return meta;
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

fn table_count_at_lvl(version: *const Version, lvl: u8) usize {
    var count: usize = 0;

    for (version.tables.items) |table| {
        count += @intFromBool(table.lvl == lvl);
    }

    return count;
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
        null,
        allocator,
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
        null,
        allocator,
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
    {
        const name = try manifest.alloc_sstable_name(records.items[2].AddFile.file_seq, allocator);
        defer allocator.free(name);
        try std.testing.expectEqualSlices(u8, "memtable42.sst", name);
    }

    var serialized = try std.ArrayList(u8).initCapacity(allocator, 0);
    for (records.items) |rec| {
        try rec.serialize_to(&serialized, allocator);
    }

    const deserialized = try manifest.ManifestRecord.deserialize_from(serialized.items, allocator);
    try std.testing.expectEqual(@as(usize, 3), deserialized.items.len);
    try std.testing.expectEqual(@as(usize, 17), deserialized.items[0].NextSeqNumber);
    try std.testing.expectEqual(@as(usize, 42), deserialized.items[1].NextFileNumber.get());
    {
        const name = try manifest.alloc_sstable_name(deserialized.items[2].AddFile.file_seq, allocator);
        defer allocator.free(name);
        try std.testing.expectEqualSlices(u8, "memtable42.sst", name);
    }
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

    const dir = try std.Io.Dir.cwd().openDir(testing_io, dirname, .{});
    var storage = try Storage.new(dir, 100, allocator);

    defer {
        storage.deinit(testing_io, allocator);
        std.Io.Dir.cwd().deleteTree(testing_io, dirname) catch {
            @panic("failed to delete test db");
        };
    }

    {
        var version = try Version.from_file(
            &storage,
            "manifest",
            testing_opts,
            &stat,
            false,
            testing_io,
            allocator,
        );
        defer version.deinit(testing_io, allocator);

        var edit = try VersionEdit.empty(allocator);
        defer edit.deinit(allocator);
        edit.next_seq = KVSeq.init(9);
        edit.next_file = FileSeq.init(11);
        try edit.new_files.append(allocator, try test_file_meta(
            &storage,
            allocator,
            0,
            11,
            "k1",
            "v1",
            "k9",
            "v9",
        ));

        try version.apply(edit, &storage, testing_io, allocator);
    }

    {
        var reopened = try Version.from_file(
            &storage,
            "manifest",
            testing_opts,
            &stat,
            false,
            testing_io,
            allocator,
        );
        defer reopened.deinit(testing_io, allocator);

        try std.testing.expectEqual(@as(usize, 13), reopened.current_seq().get());

        // Since version opens new active table, it should be 12 + 1
        try std.testing.expectEqual(@as(usize, 13), reopened.next_file.load(.monotonic).get());
        try std.testing.expectEqual(@as(usize, 1), reopened.tables.items.len);

        {
            const name = try manifest.alloc_sstable_name(reopened.tables.items[0].file_seq, allocator);
            defer allocator.free(name);
            try std.testing.expectEqualSlices(u8, "memtable11.sst", name);
        }
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

    const dir = try std.Io.Dir.cwd().openDir(testing_io, dirname, .{});
    var storage = try Storage.new(dir, 100, allocator);

    defer {
        storage.deinit(testing_io, allocator);
        std.Io.Dir.cwd().deleteTree(testing_io, dirname) catch {
            @panic("failed to delete test db");
        };
    }

    var version = try Version.from_file(
        &storage,
        "manifest",
        testing_opts,
        &stat,
        false,
        testing_io,
        allocator,
    );
    defer version.deinit(testing_io, allocator);

    var edit = try VersionEdit.empty(allocator);
    defer edit.deinit(allocator);
    edit.next_file = FileSeq.init(4);

    try edit.new_files.append(
        allocator,
        try create_test_sstable(
            &storage,
            testing_io,
            allocator,
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
            &storage,
            testing_io,
            allocator,
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
            &storage,
            testing_io,
            allocator,
            0,
            3,
            &[_]TestSSTableKV{
                .{ .key = "a", .value = "fresh", .seq = 3 },
            },
        ),
    );

    try version.apply(edit, &storage, testing_io, allocator);
    try version.compact(&storage, .{ .max_lvl0 = 1 }, testing_io, allocator);

    try std.testing.expectEqual(@as(usize, 1), version.tables.items.len);
    try std.testing.expectEqual(@as(usize, 0), table_count_at_lvl(version, 0));
    try std.testing.expectEqual(@as(usize, 1), table_count_at_lvl(version, 1));
    try std.testing.expectEqual(@as(u8, 1), version.tables.items[0].lvl);
    try expect_l1_non_overlapping(version);

    try std.testing.expectEqual(null, try version.get("b", &storage, testing_io, allocator));

    const value = (try version.get("a", &storage, testing_io, allocator)).?;
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

    const dir = try std.Io.Dir.cwd().openDir(testing_io, dirname, .{});
    var storage = try Storage.new(dir, 100, allocator);

    defer {
        storage.deinit(testing_io, allocator);
        std.Io.Dir.cwd().deleteTree(testing_io, dirname) catch {
            @panic("failed to delete test db");
        };
    }

    var version = try Version.from_file(&storage, "manifest", testing_opts, &stat, false, testing_io, allocator);
    defer version.deinit(testing_io, allocator);

    var edit = try VersionEdit.empty(allocator);
    defer edit.deinit(allocator);
    edit.next_file = FileSeq.init(4);

    try edit.new_files.append(
        allocator,
        try create_test_sstable(
            &storage,
            testing_io,
            allocator,
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
            &storage,
            testing_io,
            allocator,
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
            &storage,
            testing_io,
            allocator,
            0,
            3,
            &[_]TestSSTableKV{
                .{ .key = "b", .value = "fresh-b", .seq = 3 },
            },
        ),
    );

    try version.apply(edit, &storage, testing_io, allocator);
    try version.compact(&storage, .{ .max_lvl0 = 1 }, testing_io, allocator);

    try std.testing.expectEqual(@as(usize, 2), version.tables.items.len);
    try std.testing.expectEqual(@as(usize, 0), table_count_at_lvl(version, 0));
    try std.testing.expectEqual(@as(usize, 2), table_count_at_lvl(version, 1));
    try expect_l1_non_overlapping(version);

    const old = (try version.get("z", &storage, testing_io, allocator)).?;
    try std.testing.expectEqualSlices(u8, "old", old);

    const fresh_a = (try version.get("a", &storage, testing_io, allocator)).?;
    try std.testing.expectEqualSlices(u8, "fresh-a", fresh_a);

    const fresh_b = (try version.get("b", &storage, testing_io, allocator)).?;
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

    const dir = try std.Io.Dir.cwd().openDir(testing_io, dirname, .{});
    var storage = try Storage.new(dir, 100, allocator);

    defer {
        storage.deinit(testing_io, allocator);
        std.Io.Dir.cwd().deleteTree(testing_io, dirname) catch {
            @panic("failed to delete test db");
        };
    }

    var version = try Version.from_file(
        &storage,
        "manifest",
        testing_opts,
        &stat,
        false,
        testing_io,
        allocator,
    );
    defer version.deinit(testing_io, allocator);

    var edit = try VersionEdit.empty(allocator);
    defer edit.deinit(allocator);
    edit.next_file = FileSeq.init(4);

    try edit.new_files.append(
        allocator,
        try create_test_sstable(
            &storage,
            testing_io,
            allocator,
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
            &storage,
            testing_io,
            allocator,
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
            &storage,
            testing_io,
            allocator,
            0,
            3,
            &[_]TestSSTableKV{
                .{ .key = "c", .value = "fresh-c", .seq = 4 },
            },
        ),
    );

    try version.apply(edit, &storage, testing_io, allocator);
    try version.compact(&storage, .{ .max_lvl0 = 1 }, testing_io, allocator);

    try std.testing.expectEqual(@as(usize, 1), version.tables.items.len);
    try std.testing.expectEqual(@as(usize, 0), table_count_at_lvl(version, 0));
    try std.testing.expectEqual(@as(usize, 1), table_count_at_lvl(version, 1));
    try expect_l1_non_overlapping(version);

    try std.testing.expectEqual(null, try version.get("b", &storage, testing_io, allocator));

    const fresh_a = (try version.get("a", &storage, testing_io, allocator)).?;
    try std.testing.expectEqualSlices(u8, "fresh-a", fresh_a);

    const fresh_c = (try version.get("c", &storage, testing_io, allocator)).?;
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

    const dir = try std.Io.Dir.cwd().openDir(testing_io, dirname, .{});
    var storage = try Storage.new(dir, 100, allocator);

    defer {
        storage.deinit(testing_io, allocator);
        std.Io.Dir.cwd().deleteTree(testing_io, dirname) catch {
            @panic("failed to delete test db");
        };
    }

    var version = try Version.from_file(&storage, "manifest", testing_opts, &stat, false, testing_io, allocator);
    defer version.deinit(testing_io, allocator);

    var edit = try VersionEdit.empty(allocator);
    defer edit.deinit(allocator);
    edit.next_file = FileSeq.init(4);

    try edit.new_files.append(
        allocator,
        try create_test_sstable(
            &storage,
            testing_io,
            allocator,
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
            &storage,
            testing_io,
            allocator,
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
            &storage,
            testing_io,
            allocator,
            0,
            3,
            &[_]TestSSTableKV{
                .{ .key = "a", .value = "fresh", .seq = 3 },
            },
        ),
    );

    try version.apply(edit, &storage, testing_io, allocator);
    try expect_file_exists(dir, testing_io, "memtable1.sst");
    try expect_file_exists(dir, testing_io, "memtable2.sst");
    try expect_file_exists(dir, testing_io, "memtable3.sst");

    try version.compact(&storage, .{ .max_lvl0 = 1 }, testing_io, allocator);

    try expect_file_deleted(dir, testing_io, "memtable1.sst");
    try expect_file_deleted(dir, testing_io, "memtable2.sst");
    try expect_file_deleted(dir, testing_io, "memtable3.sst");

    {
        const name = try manifest.alloc_sstable_name(version.tables.items[0].file_seq, allocator);
        defer allocator.free(name);
        try expect_file_exists(dir, testing_io, name);
    }
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

    const dir = try std.Io.Dir.cwd().openDir(testing_io, dirname, .{});
    var storage = try Storage.new(dir, 100, allocator);

    defer {
        storage.deinit(testing_io, allocator);
        std.Io.Dir.cwd().deleteTree(testing_io, dirname) catch {
            @panic("failed to delete test db");
        };
    }

    var version = try Version.from_file(
        &storage,
        "manifest",
        testing_opts,
        &stat,
        false,
        testing_io,
        allocator,
    );
    defer version.deinit(testing_io, allocator);

    var edit = try VersionEdit.empty(allocator);
    defer edit.deinit(allocator);
    edit.next_file = FileSeq.init(4);

    try edit.new_files.append(
        allocator,
        try create_test_sstable(
            &storage,
            testing_io,
            allocator,
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
            &storage,
            testing_io,
            allocator,
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
            &storage,
            testing_io,
            allocator,
            0,
            3,
            &[_]TestSSTableKV{
                .{ .key = "b", .value = "fresh-b", .seq = 3 },
            },
        ),
    );

    try version.apply(edit, &storage, testing_io, allocator);
    try version.compact(&storage, .{ .max_lvl0 = 1 }, testing_io, allocator);

    try expect_file_exists(dir, testing_io, "memtable1.sst");
    try expect_file_deleted(dir, testing_io, "memtable2.sst");
    try expect_file_deleted(dir, testing_io, "memtable3.sst");

    for (version.tables.items) |table| {
        const name = try manifest.alloc_sstable_name(table.file_seq, allocator);
        defer allocator.free(name);
        try expect_file_exists(dir, testing_io, name);
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

    const dir = try std.Io.Dir.cwd().openDir(testing_io, dirname, .{});
    var storage = try Storage.new(dir, 100, allocator);

    defer {
        storage.deinit(testing_io, allocator);
        std.Io.Dir.cwd().deleteTree(testing_io, dirname) catch {
            @panic("failed to delete test db");
        };
    }

    {
        var version = try Version.from_file(
            &storage,
            "manifest",
            testing_opts,
            &stat,
            false,
            testing_io,
            allocator,
        );
        defer version.deinit(testing_io, allocator);

        var edit = try VersionEdit.empty(allocator);
        defer edit.deinit(allocator);
        edit.next_file = FileSeq.init(4);

        try edit.new_files.append(
            allocator,
            try create_test_sstable(
                &storage,
                testing_io,
                allocator,
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
                &storage,
                testing_io,
                allocator,
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
                &storage,
                testing_io,
                allocator,
                0,
                3,
                &[_]TestSSTableKV{
                    .{ .key = "a", .value = "fresh", .seq = 3 },
                },
            ),
        );

        try version.apply(edit, &storage, testing_io, allocator);
        try version.compact(&storage, .{ .max_lvl0 = 1 }, testing_io, allocator);
    }

    {
        var reopened = try Version.from_file(&storage, "manifest", testing_opts, &stat, false, testing_io, allocator);
        defer reopened.deinit(testing_io, allocator);

        try std.testing.expectEqual(@as(usize, 1), reopened.tables.items.len);
        try std.testing.expectEqual(@as(usize, 0), table_count_at_lvl(reopened, 0));
        try std.testing.expectEqual(@as(usize, 1), table_count_at_lvl(reopened, 1));
        try std.testing.expectEqual(@as(u8, 1), reopened.tables.items[0].lvl);
        try expect_l1_non_overlapping(reopened);

        try std.testing.expectEqual(null, try reopened.get("b", &storage, testing_io, allocator));

        const value = (try reopened.get("a", &storage, testing_io, allocator)).?;
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

    const dir = try std.Io.Dir.cwd().openDir(testing_io, dirname, .{});
    var storage = try Storage.new(dir, 100, allocator);

    defer {
        storage.deinit(testing_io, allocator);
        std.Io.Dir.cwd().deleteTree(testing_io, dirname) catch {
            @panic("failed to delete test db");
        };
    }

    {
        var version = try Version.from_file(
            &storage,
            "manifest",
            testing_opts,
            &stat,
            false,
            testing_io,
            allocator,
        );
        defer version.deinit(testing_io, allocator);

        var edit = try VersionEdit.empty(allocator);
        defer edit.deinit(allocator);
        edit.next_file = FileSeq.init(4);

        try edit.new_files.append(
            allocator,
            try create_test_sstable(
                &storage,
                testing_io,
                allocator,
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
                &storage,
                testing_io,
                allocator,
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
                &storage,
                testing_io,
                allocator,
                0,
                3,
                &[_]TestSSTableKV{
                    .{ .key = "b", .value = "fresh-b", .seq = 3 },
                },
            ),
        );

        try version.apply(edit, &storage, testing_io, allocator);
        try version.compact(&storage, .{ .max_lvl0 = 1 }, testing_io, allocator);
    }

    try std.testing.expectEqual(storage.stats().sstable_size(0), 0);
    try std.testing.expect(storage.stats().sstable_size(1) > 0);

    {
        var reopened = try Version.from_file(&storage, "manifest", testing_opts, &stat, false, testing_io, allocator);
        defer reopened.deinit(testing_io, allocator);

        try std.testing.expectEqual(@as(usize, 2), reopened.tables.items.len);
        try std.testing.expectEqual(@as(usize, 0), table_count_at_lvl(reopened, 0));
        try std.testing.expectEqual(@as(usize, 2), table_count_at_lvl(reopened, 1));
        try expect_l1_non_overlapping(reopened);

        const old = (try reopened.get("z", &storage, testing_io, allocator)).?;
        try std.testing.expectEqualSlices(u8, "old", old);

        const fresh_a = (try reopened.get("a", &storage, testing_io, allocator)).?;
        try std.testing.expectEqualSlices(u8, "fresh-a", fresh_a);

        const fresh_b = (try reopened.get("b", &storage, testing_io, allocator)).?;
        try std.testing.expectEqualSlices(u8, "fresh-b", fresh_b);
    }
}

test "Version updates storage stats on boot" {
    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }
    const allocator = arena.allocator();
    const testing_io = std.testing.io;
    var stat = std.mem.zeroes(Statistics);

    const dirname = "test_version_updates_storage_stats_on_boot";
    std.Io.Dir.cwd().deleteTree(testing_io, dirname) catch {};
    try std.Io.Dir.cwd().createDir(testing_io, dirname, .default_dir);

    defer {
        std.Io.Dir.cwd().deleteTree(testing_io, dirname) catch {
            @panic("failed to delete test db");
        };
    }

    var expected_lvl0: usize = 0;
    var expected_lvl1: usize = 0;

    {
        const dir = try std.Io.Dir.cwd().openDir(testing_io, dirname, .{});
        var storage = try Storage.new(dir, 100, allocator);
        defer storage.deinit(testing_io, allocator);

        var version = try Version.from_file(
            &storage,
            "manifest",
            testing_opts,
            &stat,
            false,
            testing_io,
            allocator,
        );
        defer version.deinit(testing_io, allocator);

        var edit = try VersionEdit.empty(allocator);
        defer edit.deinit(allocator);
        edit.next_file = FileSeq.init(4);

        try edit.new_files.append(
            allocator,
            try create_test_sstable(
                &storage,
                testing_io,
                allocator,
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
                &storage,
                testing_io,
                allocator,
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
                &storage,
                testing_io,
                allocator,
                0,
                3,
                &[_]TestSSTableKV{
                    .{ .key = "b", .value = "fresh-b", .seq = 3 },
                },
            ),
        );

        try version.apply(edit, &storage, testing_io, allocator);

        expected_lvl0 = storage.stats().sstable_size(0);
        expected_lvl1 = storage.stats().sstable_size(1);
        try std.testing.expect(expected_lvl0 > 0);
        try std.testing.expect(expected_lvl1 > 0);
    }

    {
        const dir = try std.Io.Dir.cwd().openDir(testing_io, dirname, .{});
        var storage = try Storage.new(dir, 100, allocator);
        defer storage.deinit(testing_io, allocator);

        try std.testing.expectEqual(@as(usize, 0), storage.stats().sstable_size(0));
        try std.testing.expectEqual(@as(usize, 0), storage.stats().sstable_size(1));

        var version = try Version.from_file(
            &storage,
            "manifest",
            testing_opts,
            &stat,
            false,
            testing_io,
            allocator,
        );
        defer version.deinit(testing_io, allocator);

        try std.testing.expectEqual(expected_lvl0, storage.stats().sstable_size(0));
        try std.testing.expectEqual(expected_lvl1, storage.stats().sstable_size(1));
        try std.testing.expectEqual(@as(usize, 0), storage.stats().sstable_size(2));
    }
}
