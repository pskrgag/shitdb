const std = @import("std");
const MemTableOpts = @import("storage").MemTableOpts;
const Dir = std.Io.Dir;
const Allocator = std.mem.Allocator;
const KeyValue = @import("storage").KeyValue;
const Version = @import("version.zig").Version;
const WalTable = @import("wal_table.zig").WalTable;
const WalOpts = @import("wal.zig").WalOpts;
const test_utils = @import("test_utils");
const Statistics = @import("stat.zig").Statistics;
const Mutex = @import("sync").mutex.Mutex;
const Condition = @import("sync").cv.Condition;
const KVSeq = @import("storage").KVSeq;
const ei = @import("test_utils").Injections.error_injection;

// Request kind of the write.
pub const WriteOp = union(enum) {
    Put: struct {
        key: []const u8,
        value: []const u8,
        seq: KVSeq,
    },
    Remove: struct {
        key: []const u8,
        seq: KVSeq,
    },

    pub fn assign_seq(self: *WriteOp, seq: KVSeq) void {
        switch (self.*) {
            .Put => |*p| {
                p.seq = seq;
            },
            .Remove => |*p| {
                p.seq = seq;
            },
        }
    }
};

pub const TransactionIter = struct {
    head: ?*std.DoublyLinkedList.Node,

    pub fn next(self: *TransactionIter) ?*PendingWrite {
        if (self.head) |h| {
            const res: *PendingWrite = @fieldParentPtr("active_node", h);

            self.head = h.next;
            return res;
        } else {
            return null;
        }
    }
};

// Atomic transaction
pub const Transaction = struct {
    // List of pending writers.
    ops: std.DoublyLinkedList = .{},
    // Initial count of pending requests.
    count: usize = 0,

    pub fn iter(self: *const Transaction) TransactionIter {
        return .{ .head = self.ops.first };
    }

    pub fn push_active(self: *Transaction, op: *PendingWrite) void {
        self.count += 1;
        self.ops.append(&op.active_node);
    }

    pub fn abort(self: *Transaction, op: *PendingWrite, err: anyerror) void {
        op.err = err;
        self.ops.remove(&op.active_node);
    }

    pub fn mark_error(self: *Transaction, err: anyerror) void {
        var i = self.iter();

        while (i.next()) |op| {
            self.abort(op, err);
        }
    }
};

// Pending write request
pub const PendingWrite = struct {
    // Write request kin
    op: WriteOp,
    // If request was done by the leader
    done: bool = false,
    // Request error if any
    err: ?anyerror = null,
    // Linked list node for pending list
    pending_node: std.DoublyLinkedList.Node = .{},
    // Linked list node for in-flight list
    active_node: std.DoublyLinkedList.Node = .{},
};

pub const ManagerState = enum(u8) {
    // DB is fine.
    Healthy,
    // Something went wrong and db does not accept new requests.
    Broken,
};

pub const Manager = struct {
    // Root folder
    root: Dir,
    // Mutex that protects new table creation
    dblock: Mutex,
    // CV for writers
    write_cv: Condition,
    // MemTable options
    opts: MemTableOpts,
    // Current version of db
    version: *Version,
    // IO instance,
    io: std.Io,
    // Statistics
    stat: *Statistics,
    // Active writers
    writers: std.DoublyLinkedList,
    // Number of writers
    writers_count: usize,
    // State of the database
    state: ManagerState,

    const Self = @This();

    pub fn new(dir: Dir, alloc: Allocator, io: std.Io, opts: MemTableOpts, wal_opts: WalOpts) !Self {
        const stat = try Statistics.new(alloc);
        errdefer stat.deinit(alloc);

        const version = try Version.from_file(
            dir,
            "MANIFEST",
            opts,
            wal_opts,
            stat,
            true,
            io,
            alloc,
        );

        return .{
            .writers = std.DoublyLinkedList{},
            .writers_count = 0,
            .write_cv = Condition.init,
            .version = version,
            .root = dir,
            .dblock = Mutex.init,
            .opts = opts,
            .io = io,
            .stat = stat,
            .state = .Healthy,
        };
    }

    fn is_healty(self: *Self) !void {
        if (self.state == .Broken)
            return error.Broken;
    }

    fn build_transaction(self: *Self) Transaction {
        var trans = Transaction{ .ops = std.DoublyLinkedList{} };
        const seqs = self.version.allocate_seqs(self.writers_count);
        var iter = self.writers.first;

        while (iter) |nd| {
            const writer: *PendingWrite = @fieldParentPtr("pending_node", nd);

            writer.op.assign_seq(KVSeq.init(seqs.get() + trans.count));
            trans.push_active(writer);
            iter = nd.next;
        }

        return trans;
    }

    // Writes one record into DB.
    //
    // Protocol follows LevelDB structure:
    //
    // 1) One writer is the leader. It pops all pending writes and batch them into one write.
    fn write(self: *Self, op: WriteOp, alloc: Allocator) !void {
        var pending = PendingWrite{
            .op = op,
        };
        var broken = false;

        const transaction = blk: {
            self.dblock.lockUncancelable(self.io);
            defer self.dblock.unlock(self.io);

            try self.is_healty();

            self.writers.append(&pending.pending_node);
            self.writers_count += 1;

            while (pending.done == false and self.writers.first != &pending.pending_node) {
                ei.maybe_error(.write_cv_wait, self.write_cv.wait(
                    self.io,
                    &self.dblock,
                )) catch |err| {
                    self.dblock.assert_locked();

                    self.writers.remove(&pending.pending_node);
                    self.writers_count -= 1;
                    return err;
                };
            }

            // There was an error during request handling
            if (pending.err) |err| {
                std.debug.assert(pending.done == true);
                return err;
            }

            // It was completed by the leader.
            if (pending.done) {
                return;
            }

            break :blk self.build_transaction();
        };

        test_utils.Scheduler.yield(.TransactionBuilt);

        // Now mutex is released and we can push to memtable and write WAL.
        // self.dblock.assert_not_locked();
        //
        // Each request is either completed via done or marked with error. In any case
        // caller return pending.err. Failure of this call does not mean that current write
        // has failed. In means that some of writes failed.
        self.version.commit(transaction, self.root, self.io, alloc) catch {
            broken = true;
        };

        // Now take the mutex back and remove all pending writes from the queue.
        self.dblock.lockUncancelable(self.io);

        if (broken)
            self.state = .Broken;

        for (0..transaction.count) |_| {
            const old = self.writers.popFirst();
            std.debug.assert(old != null);

            const writer: *PendingWrite = @fieldParentPtr("pending_node", old.?);
            writer.done = true;
            self.writers_count -= 1;
        }

        self.dblock.unlock(self.io);
        self.write_cv.broadcast(self.io);
        return if (pending.err) |e| e else {};
    }

    /// Puts new value into memtable.
    pub fn put(self: *Self, key: []const u8, value: []const u8, alloc: Allocator) !void {
        try self.is_healty();
        try self.write(WriteOp{ .Put = .{ .key = key, .value = value, .seq = undefined } }, alloc);
    }

    /// Removes a value from database
    pub fn remove(self: *Self, key: []const u8, alloc: Allocator) !void {
        try self.is_healty();
        try self.write(WriteOp{ .Remove = .{ .key = key, .seq = undefined } }, alloc);
    }

    /// Retrieves a value from database
    pub fn get(self: *Self, key: []const u8, alloc: Allocator) !?[]u8 {
        try self.is_healty();

        self.dblock.lockUncancelable(self.io);
        defer self.dblock.unlock(self.io);

        return try self.version.get(key, self.root, self.io, alloc);
    }

    pub fn deinit(self: *Self, alloc: Allocator) void {
        self.version.deinit(self.io, alloc);
        self.stat.deinit(alloc);
    }
};

fn openOrCreateDir(io: std.Io, path: []const u8) !Dir {
    const cwd = Dir.cwd();
    const opts = Dir.OpenOptions{ .iterate = true };

    return cwd.openDir(io, path, opts) catch |err| switch (err) {
        error.FileNotFound => {
            try cwd.createDir(io, path, .default_dir);
            return try cwd.openDir(io, path, opts);
        },
        else => return err,
    };
}

fn uaf_thread(manager: *Manager, alloc: Allocator) !void {
    try manager.put("hey", "bro", alloc);
}

fn insert_thread(manager: *Manager, alloc: Allocator) !void {
    // Now insert a lot of shit and wait while active memtable is flushed
    while (manager.stat.read(.memtable_flush) == 0) {
        try manager.put("hey" ** 10, "baby" ** 10, alloc);
    }
}

fn insert_second(manager: *Manager, alloc: Allocator) !void {
    // Now insert a lot of shit and wait while active memtable is flushed
    while (manager.stat.read(.memtable_flush) < 2) {
        try manager.put("hey" ** 10, "baby" ** 10, alloc);
    }
}

fn big_insert(manager: *Manager, alloc: Allocator) !void {
    try manager.put("a" ** 35, "a" ** 35, alloc);
}

fn checked_big_insert(manager: *Manager, alloc: Allocator) !void {
    try std.testing.expect(KeyValue.calculate_size("a" ** 35, "a" ** 35) < 100);
    try std.testing.expectEqual(manager.stat.read(.memtable_flush), 0);
    try big_insert(manager, alloc);
}

fn add_test_sstable(
    manager: *Manager,
    file_seq: usize,
    value_seq: usize,
    key: []const u8,
    value: []const u8,
    alloc: Allocator,
) !void {
    const storage = @import("storage");
    const MemTable = storage.MemTable;
    const SSTable = storage.sstable.SSTable;
    const FileMeta = storage.manifest.FileMeta;
    const FileSeq = storage.manifest.FileSeq;
    const KeyOwned = storage.manifest.KeyOwned;
    const VersionEdit = @import("version.zig").VersionEdit;

    var memtable = try MemTable.new(alloc, manager.io, .{});
    defer memtable.deinit(alloc);
    try memtable.put(key, value, storage.KVSeq.init(value_seq));

    const file = FileSeq.init(file_seq);
    const name = try std.fmt.allocPrint(alloc, "memtable{}.sst", .{file.get()});

    var sstable = try SSTable.create(manager.root, name, &memtable, 0, manager.io, alloc);
    defer sstable.deinit();

    var edit = try VersionEdit.empty(alloc);
    defer edit.deinit(alloc);

    try edit.new_files.append(alloc, FileMeta{
        .lvl = 0,
        .name = name,
        .max = try KeyOwned.from_raw(sstable.max(), alloc),
        .min = try KeyOwned.from_raw(sstable.min(), alloc),
        .file_seq = file,
        .value_seq = sstable.maximum_seq(),
    });

    try manager.version.apply(edit, manager.root, manager.io, alloc);
}

test "Disk search checks newest SSTable first" {
    const io = std.testing.io;
    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }
    const allocator = arena.allocator();

    const dirname = "test_db_disk_newest_first";
    std.Io.Dir.cwd().deleteTree(io, dirname) catch {};

    const dir = try openOrCreateDir(io, dirname);
    defer {
        std.Io.Dir.cwd().deleteTree(io, dirname) catch {
            @panic("failed to delete test db");
        };
    }

    var manager = try Manager.new(dir, allocator, io, .{}, .{});
    defer manager.deinit(allocator);

    try add_test_sstable(&manager, 100, 10, "shared", "old", allocator);
    try add_test_sstable(&manager, 101, 11, "shared", "new", allocator);

    const value = (try manager.get("shared", allocator)).?;
    defer allocator.free(value);
    try std.testing.expectEqualSlices(u8, "new", value);
}

fn insert_values_until_immutable(manager: *Manager, offset: u8, count: usize, alloc: Allocator) !void {
    const current = manager.version.flusher.count;
    var symbol: u8 = 'a';

    while (manager.version.flusher.count == current) {
        const key = try alloc.alloc(u8, count);
        defer alloc.free(key);

        const value = try alloc.alloc(u8, count);
        defer alloc.free(value);

        @memset(key, symbol);
        @memset(value, symbol + offset);

        try manager.put(key, value, alloc);
        symbol += 1;
    }
}

fn remove_values_until_immutable(manager: *Manager, count: usize, alloc: Allocator) !void {
    const current = manager.version.flusher.count;
    var symbol: u8 = 'a';

    while (manager.version.flusher.count == current) {
        const key = try alloc.alloc(u8, count);
        defer alloc.free(key);

        @memset(key, symbol);

        try manager.remove(key, alloc);
        symbol += 1;
    }
}

fn insert_values_until_flushed(manager: *Manager, offset: u8, count: usize, alloc: Allocator) !void {
    const current = manager.version.stat.read(.memtable_flush);
    var symbol: u8 = 'a';

    while (manager.version.stat.read(.memtable_flush) == current) {
        const key = try alloc.alloc(u8, count);
        defer alloc.free(key);

        const value = try alloc.alloc(u8, count);
        defer alloc.free(value);

        @memset(key, symbol);
        @memset(value, symbol + offset);

        try manager.put(key, value, alloc);
        symbol += 1;
    }
}

test "Flusher searches new memtables first" {
    const io = std.testing.io;
    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }
    const allocator = arena.allocator();

    const dirname = "flusher_searches_memtable_first";
    std.Io.Dir.cwd().deleteTree(io, dirname) catch {};

    const dir = try openOrCreateDir(io, dirname);
    defer {
        std.Io.Dir.cwd().deleteTree(io, dirname) catch {
            @panic("failed to delete test db");
        };
    }

    var manager = try Manager.new(dir, allocator, io, .{ .memtable_size = 200 }, .{});
    defer manager.deinit(allocator);

    try std.testing.expectEqual(manager.version.flusher.count, 0);

    try insert_values_until_immutable(&manager, 0, 10, allocator);
    try std.testing.expectEqual(manager.version.flusher.count, 1);

    try insert_values_until_immutable(&manager, 1, 10, allocator);
    try std.testing.expectEqual(manager.version.flusher.count, 2);

    const value = (try manager.get("a" ** 10, allocator)).?;
    defer allocator.free(value);
    try std.testing.expectEqualSlices(u8, "b" ** 10, value);
}

test "Removed in flusher does not result in disk search" {
    const io = std.testing.io;
    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }
    const allocator = arena.allocator();

    const dirname = "flusher_removed_no_disk";
    std.Io.Dir.cwd().deleteTree(io, dirname) catch {};

    const dir = try openOrCreateDir(io, dirname);
    defer {
        std.Io.Dir.cwd().deleteTree(io, dirname) catch {
            @panic("failed to delete test db");
        };
    }

    var manager = try Manager.new(dir, allocator, io, .{ .memtable_size = 200 }, .{});
    defer manager.deinit(allocator);

    try insert_values_until_flushed(&manager, 0, 10, allocator);
    try remove_values_until_immutable(&manager, 10, allocator);

    const value = try manager.get("a" ** 10, allocator);
    try std.testing.expectEqual(null, value);
}

test "WAL GC no crash" {
    const Wal = @import("wal.zig").Wal;

    const io = std.testing.io;
    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }
    const allocator = arena.allocator();

    const dirname = "wal_gc";
    std.Io.Dir.cwd().deleteTree(io, dirname) catch {};

    const dir = try openOrCreateDir(io, dirname);
    defer {
        std.Io.Dir.cwd().deleteTree(io, dirname) catch {
            @panic("failed to delete test db");
        };
    }

    {
        var manager = try Manager.new(dir, allocator, io, .{ .memtable_size = 200 }, .{});
        defer manager.deinit(allocator);

        while (manager.version.stat.read(.memtable_flush) < 3) {
            try manager.put("a" ** 10, "a" ** 10, allocator);
        }
    }

    var manager = try Manager.new(dir, allocator, io, .{ .memtable_size = 200 }, .{});
    defer manager.deinit(allocator);

    var diriter = dir.iterate();
    var wals: usize = 0;

    while (try diriter.next(io)) |entry| {
        wals += @intFromBool(Wal.is_wal_name(entry.name));
    }

    try std.testing.expectEqual(@as(usize, 1), wals);
}

test "WAL GC crash" {
    const Wal = @import("wal.zig").Wal;
    const builtin = @import("builtin");

    if (builtin.sanitize_thread) {
        return;
    }

    const io = std.testing.io;
    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }
    const allocator = arena.allocator();

    const dirname = "wal_gc_crash";
    std.Io.Dir.cwd().deleteTree(io, dirname) catch {};

    const dir = try openOrCreateDir(io, dirname);
    defer {
        std.Io.Dir.cwd().deleteTree(io, dirname) catch {
            @panic("failed to delete test db");
        };
    }

    const Child = struct {
        fn run(child_dir: Dir, child_alloc: Allocator, child_io: std.Io) void {
            var manager = Manager.new(child_dir, child_alloc, child_io, .{
                .memtable_size = 500,
            }, .{}) catch |e| {
                std.debug.print("Unexpected error returned during create {}\n", .{e});
                std.process.exit(0);
            };

            manager.put("a" ** 10, "a" ** 10, child_alloc) catch |e| {
                std.debug.print("Unexpected error returned during put{}\n", .{e});
                std.process.exit(0);
            };

            std.process.exit(255);
        }
    };

    try test_utils.fork.expectCrash(Child.run, .{ dir, allocator, io });

    var manager = try Manager.new(dir, allocator, io, .{ .memtable_size = 200 }, .{});
    defer manager.deinit(allocator);

    var diriter = dir.iterate();
    var wals: usize = 0;

    while (try diriter.next(io)) |entry| {
        wals += @intFromBool(Wal.is_wal_name(entry.name));
    }

    try std.testing.expectEqual(@as(usize, 1), wals);

    const value = (try manager.get("a" ** 10, allocator)).?;
    defer allocator.free(value);
    try std.testing.expectEqualSlices(u8, "a" ** 10, value);
}

const SuccessKey = "a" ** 10;
const SuccessValue = "aa" ** 10;

const Success1Key = "c" ** 10;
const Success1Value = "cc" ** 10;

const Success2Key = "d" ** 10;
const Success2Value = "dd" ** 10;

const FailKey = "b" ** 10;
const FailKeySmall = "bb" ** 10;
const FailValueBig = "bb" ** (40 << 10);

fn success_put(man: *Manager, alloc: Allocator) !void {
    // This one must not fail
    try man.put(SuccessKey, SuccessValue, alloc);
}

fn success_put_wal_fail(man: *Manager, alloc: Allocator) !void {
    // This one must not fail
    try man.put(SuccessKey, SuccessValue, alloc);
}

fn error_put(man: *Manager, alloc: Allocator) !void {
    man.put(FailKey, FailKeySmall, alloc) catch |e| {
        try std.testing.expectEqual(error.InjectedError, e);
        return;
    };

    return error.UnexpectedReturn;
}

fn wal_write_error_put(man: *Manager, alloc: Allocator) !void {
    try man.put(Success1Key, Success1Value, alloc);
}

fn wal_write_error_put1(man: *Manager, alloc: Allocator) !void {
    try man.put(Success2Key, Success2Value, alloc);
}

fn wal_sync_error_put(man: *Manager, alloc: Allocator) !void {
    man.put(FailKey, FailKeySmall, alloc) catch |e| {
        try std.testing.expectEqual(error.SyncError, e);
        return;
    };

    return error.UnexpectedReturn;
}

fn too_big(man: *Manager, alloc: Allocator) !void {
    man.put(FailKey, FailValueBig, alloc) catch |e| {
        try std.testing.expectEqual(error.TooBig, e);
        return;
    };

    return error.UnexpectedReturn;
}

fn sanitize_manager_after_run(manager: *Manager, alloc: Allocator) !void {
    // try to push smth and verify that it still works
    {
        try manager.put("z", "z", alloc);
        const value = (try manager.get("z", alloc)).?;
        defer alloc.free(value);
        try std.testing.expectEqualSlices(u8, "z", value);
    }

    // Check that successful key is there
    {
        const value = (try manager.get(SuccessKey, alloc)).?;
        defer alloc.free(value);
        try std.testing.expectEqualSlices(u8, SuccessValue, value);
    }
}

test "Transaction commit crash" {
    const Scheduler = test_utils.Scheduler.Scheduler;
    const SchedulerPlan = test_utils.Scheduler.SchedulerPlan;

    ei.init();
    defer ei.clear();

    const io = std.testing.io;
    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }
    const allocator = arena.allocator();

    const dirname = "commit_crash";
    std.Io.Dir.cwd().deleteTree(io, dirname) catch {};

    const dir = try openOrCreateDir(io, dirname);
    defer {
        std.Io.Dir.cwd().deleteTree(io, dirname) catch {
            @panic("failed to delete test db");
        };
    }

    var manager = try Manager.new(dir, allocator, io, .{ .memtable_size = 200 }, .{});
    defer manager.deinit(allocator);

    {
        var sched = try Scheduler.new(allocator);
        defer sched.deinit(allocator);

        const leader = try sched.spawn(
            success_put,
            .{ &manager, allocator },
            allocator,
        );

        const t1 = try sched.spawn(
            wal_write_error_put,
            .{ &manager, allocator },
            allocator,
        );

        const t2 = try sched.spawn(
            wal_write_error_put1,
            .{ &manager, allocator },
            allocator,
        );

        var plan = try SchedulerPlan.new(allocator);
        defer plan.deinit(allocator);

        // 1. Build transaction and release the mutex
        try plan.add(
            .{ .fiber = leader, .run = .{ .Sleep = .TransactionBuilt } },
            allocator,
        );
        // 2. Take the mutex and wait for cv
        try plan.add(.{ .fiber = t1, .run = .{ .Sleep = .ConditionWait } }, allocator);
        // 3. Take the mutex and wait for cv (queue length must be 2)
        try plan.add(.{ .fiber = t2, .run = .{ .Sleep = .ConditionWait } }, allocator);
        // 4. Commit first transaction
        try plan.add(.{
            .fiber = leader,
            .run = .End,
        }, allocator);
        // 4. Run failing transaction
        try plan.add(.{
            .fiber = t1,
            .run = .End,
            .inject_error = &.{.wal_flush},
        }, allocator);
        // 5. Continue follower
        try plan.add(.{
            .fiber = t2,
            .run = .End,
        }, allocator);

        try sched.run_with_plan(plan, allocator);
    }
    try sanitize_manager_after_run(&manager, allocator);

    // They should be found on disk.
    {
        const value = (try manager.get(Success1Key, allocator)).?;
        defer allocator.free(value);
        try std.testing.expectEqualSlices(u8, Success1Value, value);
    }
    {
        const value = (try manager.get(Success2Key, allocator)).?;
        defer allocator.free(value);
        try std.testing.expectEqualSlices(u8, Success2Value, value);
    }
}

test "WAL sync failure fails the whole transaction" {
    const Scheduler = test_utils.Scheduler.Scheduler;
    const SchedulerPlan = test_utils.Scheduler.SchedulerPlan;

    ei.init();
    defer ei.clear();

    const io = std.testing.io;
    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }
    const allocator = arena.allocator();

    const dirname = "wal_sync_failure";
    std.Io.Dir.cwd().deleteTree(io, dirname) catch {};

    const dir = try openOrCreateDir(io, dirname);
    defer {
        std.Io.Dir.cwd().deleteTree(io, dirname) catch {
            @panic("failed to delete test db");
        };
    }

    var manager = try Manager.new(dir, allocator, io, .{ .memtable_size = 200 }, .{ .sync = true });
    defer manager.deinit(allocator);

    {
        var sched = try Scheduler.new(allocator);
        defer sched.deinit(allocator);

        const leader = try sched.spawn(
            success_put,
            .{ &manager, allocator },
            allocator,
        );

        const t1 = try sched.spawn(
            wal_write_error_put,
            .{ &manager, allocator },
            allocator,
        );

        const t2 = try sched.spawn(
            wal_write_error_put1,
            .{ &manager, allocator },
            allocator,
        );

        var plan = try SchedulerPlan.new(allocator);
        defer plan.deinit(allocator);

        // 1. Build transaction and release the mutex
        try plan.add(
            .{ .fiber = leader, .run = .{ .Sleep = .TransactionBuilt } },
            allocator,
        );
        // 2. Take the mutex and wait for cv
        try plan.add(.{ .fiber = t1, .run = .{ .Sleep = .ConditionWait } }, allocator);
        // 3. Take the mutex and wait for cv (queue length must be 2)
        try plan.add(.{ .fiber = t2, .run = .{ .Sleep = .ConditionWait } }, allocator);
        // 4. Commit first transaction
        try plan.add(.{
            .fiber = leader,
            .run = .End,
        }, allocator);
        // 5. Fail while syncing the grouped transaction
        try plan.add(.{
            .fiber = t1,
            .run = .End,
            .inject_error = &.{.wal_sync},
        }, allocator);
        // 6. Continue follower
        try plan.add(.{
            .fiber = t2,
            .run = .End,
        }, allocator);

        try sched.run_with_plan(plan, allocator);
    }

    try std.testing.expectEqual(null, try manager.get(FailKey, allocator));
    try sanitize_manager_after_run(&manager, allocator);

    // They should be found on disk.
    {
        const value = (try manager.get(Success1Key, allocator)).?;
        defer allocator.free(value);
        try std.testing.expectEqualSlices(u8, Success1Value, value);
    }
    {
        const value = (try manager.get(Success2Key, allocator)).?;
        defer allocator.free(value);
        try std.testing.expectEqualSlices(u8, Success2Value, value);
    }
}

test "Invalid argument in one request does not affect the whole group" {
    const Scheduler = test_utils.Scheduler.Scheduler;
    const SchedulerPlan = test_utils.Scheduler.SchedulerPlan;

    ei.init();
    defer ei.clear();

    const io = std.testing.io;
    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }
    const allocator = arena.allocator();

    const dirname = "invalid_val";
    std.Io.Dir.cwd().deleteTree(io, dirname) catch {};

    const dir = try openOrCreateDir(io, dirname);
    defer {
        std.Io.Dir.cwd().deleteTree(io, dirname) catch {
            @panic("failed to delete test db");
        };
    }

    var manager = try Manager.new(dir, allocator, io, .{ .memtable_size = 200 }, .{});
    defer manager.deinit(allocator);

    {
        var sched = try Scheduler.new(allocator);
        defer sched.deinit(allocator);

        const leader = try sched.spawn(
            success_put,
            .{ &manager, allocator },
            allocator,
        );

        const t1 = try sched.spawn(
            too_big,
            .{ &manager, allocator },
            allocator,
        );

        const t2 = try sched.spawn(
            success_put,
            .{ &manager, allocator },
            allocator,
        );

        var plan = try SchedulerPlan.new(allocator);
        defer plan.deinit(allocator);

        // 1. Build transaction and release the mutex
        try plan.add(
            .{ .fiber = leader, .run = .{ .Sleep = .TransactionBuilt } },
            allocator,
        );
        // 2. Take the mutex and wait for cv
        try plan.add(.{ .fiber = t1, .run = .{ .Sleep = .ConditionWait } }, allocator);
        // 3. Take the mutex and wait for cv (queue length must be 2)
        try plan.add(.{ .fiber = t2, .run = .{ .Sleep = .ConditionWait } }, allocator);
        // 4. Commit first transaction
        try plan.add(.{
            .fiber = leader,
            .run = .End,
        }, allocator);
        // 4. Run failing transaction
        try plan.add(.{
            .fiber = t1,
            .run = .End,
        }, allocator);
        // 5. Continue follower
        try plan.add(.{
            .fiber = t2,
            .run = .End,
        }, allocator);

        try sched.run_with_plan(plan, allocator);
    }
    try sanitize_manager_after_run(&manager, allocator);
}

test "Too large input is second in transaction" {
    const Scheduler = test_utils.Scheduler.Scheduler;
    const SchedulerPlan = test_utils.Scheduler.SchedulerPlan;

    ei.init();
    defer ei.clear();

    const io = std.testing.io;
    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }
    const allocator = arena.allocator();

    const dirname = "too_large_second_in_transaction";
    std.Io.Dir.cwd().deleteTree(io, dirname) catch {};

    const dir = try openOrCreateDir(io, dirname);
    defer {
        std.Io.Dir.cwd().deleteTree(io, dirname) catch {
            @panic("failed to delete test db");
        };
    }

    var manager = try Manager.new(dir, allocator, io, .{ .memtable_size = 200 }, .{});
    defer manager.deinit(allocator);

    {
        var sched = try Scheduler.new(allocator);
        defer sched.deinit(allocator);

        const leader = try sched.spawn(
            success_put,
            .{ &manager, allocator },
            allocator,
        );

        const t1 = try sched.spawn(
            success_put,
            .{ &manager, allocator },
            allocator,
        );

        const t2 = try sched.spawn(
            too_big,
            .{ &manager, allocator },
            allocator,
        );

        var plan = try SchedulerPlan.new(allocator);
        defer plan.deinit(allocator);

        // 1. Build transaction and release the mutex
        try plan.add(
            .{ .fiber = leader, .run = .{ .Sleep = .TransactionBuilt } },
            allocator,
        );
        // 2. Take the mutex and wait for cv
        try plan.add(.{ .fiber = t1, .run = .{ .Sleep = .ConditionWait } }, allocator);
        // 3. Take the mutex and wait for cv (queue length must be 2)
        try plan.add(.{ .fiber = t2, .run = .{ .Sleep = .ConditionWait } }, allocator);
        // 4. Commit first transaction
        try plan.add(.{
            .fiber = leader,
            .run = .End,
        }, allocator);
        // 5. Commit transaction with valid request followed by too large request
        try plan.add(.{
            .fiber = t1,
            .run = .End,
        }, allocator);
        // 6. Continue failed follower
        try plan.add(.{
            .fiber = t2,
            .run = .End,
        }, allocator);

        try sched.run_with_plan(plan, allocator);
    }
    try sanitize_manager_after_run(&manager, allocator);
}

test "CV wait fail removes write from the queue" {
    const Scheduler = test_utils.Scheduler.Scheduler;
    const SchedulerPlan = test_utils.Scheduler.SchedulerPlan;

    ei.init();
    defer ei.clear();

    const io = std.testing.io;
    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }
    const allocator = arena.allocator();

    const dirname = "invalid_val";
    std.Io.Dir.cwd().deleteTree(io, dirname) catch {};

    const dir = try openOrCreateDir(io, dirname);
    defer {
        std.Io.Dir.cwd().deleteTree(io, dirname) catch {
            @panic("failed to delete test db");
        };
    }

    var manager = try Manager.new(dir, allocator, io, .{ .memtable_size = 200 }, .{});
    defer manager.deinit(allocator);

    {
        var sched = try Scheduler.new(allocator);
        defer sched.deinit(allocator);

        const leader = try sched.spawn(
            success_put,
            .{ &manager, allocator },
            allocator,
        );

        const t1 = try sched.spawn(
            error_put,
            .{ &manager, allocator },
            allocator,
        );

        var plan = try SchedulerPlan.new(allocator);
        defer plan.deinit(allocator);

        // 1. Build transaction and release the mutex
        try plan.add(
            .{ .fiber = leader, .run = .{ .Sleep = .TransactionBuilt } },
            allocator,
        );
        // 2. Take the mutex and wait for cv
        try plan.add(.{ .fiber = t1, .run = .{ .Sleep = .ConditionWait } }, allocator);
        // 3. Run till the end
        try plan.add(
            .{ .fiber = leader, .run = .{ .Sleep = .TransactionBuilt } },
            allocator,
        );
        // 4. Fail on cv
        try plan.add(
            .{
                .fiber = leader,
                .run = .{ .Sleep = .TransactionBuilt },
                .inject_error = &.{.write_cv_wait},
            },
            allocator,
        );

        try sched.run_with_plan(plan, allocator);
    }
    try sanitize_manager_after_run(&manager, allocator);
}

test "Too big record for memtable infinity loop" {
    const io = std.testing.io;
    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }
    const allocator = arena.allocator();

    const dirname = "invalid_val";
    std.Io.Dir.cwd().deleteTree(io, dirname) catch {};

    const dir = try openOrCreateDir(io, dirname);
    defer {
        std.Io.Dir.cwd().deleteTree(io, dirname) catch {
            @panic("failed to delete test db");
        };
    }

    var manager = try Manager.new(dir, allocator, io, .{ .memtable_size = 200 }, .{});
    defer manager.deinit(allocator);

    // This must not cause an infinity loop.
    try std.testing.expectEqual(manager.put("a" ** 200, "b" ** 200, allocator), error.TooBig);

    // Still should be fine to put after reject.
    {
        try manager.put("a" ** 20, "b" ** 20, allocator);
        const value = (try manager.get("a" ** 20, allocator)).?;
        defer allocator.free(value);
        try std.testing.expectEqualSlices(u8, "b" ** 20, value);
    }
}

test "Failed WAL sync makes table broken" {
    const Scheduler = test_utils.Scheduler.Scheduler;
    const SchedulerPlan = test_utils.Scheduler.SchedulerPlan;

    ei.init();
    defer ei.clear();

    const io = std.testing.io;
    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }
    const allocator = arena.allocator();

    const dirname = "failed_wal_sync_makes_table_broken";
    std.Io.Dir.cwd().deleteTree(io, dirname) catch {};

    const dir = try openOrCreateDir(io, dirname);
    defer {
        std.Io.Dir.cwd().deleteTree(io, dirname) catch {
            @panic("failed to delete test db");
        };
    }

    {
        var manager = try Manager.new(dir, allocator, io, .{ .memtable_size = 200 }, .{
            .sync = true,
        });
        defer manager.deinit(allocator);

        try ei.enable(.memtable_flush, 1);

        {
            var sched = try Scheduler.new(allocator);
            defer sched.deinit(allocator);

            const leader = try sched.spawn(
                success_put,
                .{ &manager, allocator },
                allocator,
            );

            const t1 = try sched.spawn(
                wal_write_error_put,
                .{ &manager, allocator },
                allocator,
            );

            const t2 = try sched.spawn(
                wal_write_error_put1,
                .{ &manager, allocator },
                allocator,
            );

            var plan = try SchedulerPlan.new(allocator);
            defer plan.deinit(allocator);

            // 1. Build transaction and release the mutex
            try plan.add(
                .{ .fiber = leader, .run = .{ .Sleep = .TransactionBuilt } },
                allocator,
            );
            // 2. Take the mutex and wait for cv
            try plan.add(.{ .fiber = t1, .run = .{ .Sleep = .ConditionWait } }, allocator);
            // 3. Take the mutex and wait for cv (queue length must be 2)
            try plan.add(.{ .fiber = t2, .run = .{ .Sleep = .ConditionWait } }, allocator);
            // 4. Commit first transaction
            try plan.add(.{
                .fiber = leader,
                .run = .End,
            }, allocator);
            // 5. Fail WAL sync; forced MemTable flush is already armed to fail.
            try plan.add(.{
                .fiber = t1,
                .run = .End,
                .inject_error = &.{ .wal_sync, .memtable_flush },
            }, allocator);
            // 6. Continue follower
            try plan.add(.{
                .fiber = t2,
                .run = .End,
            }, allocator);

            try sched.run_with_plan(plan, allocator);
        }

        try std.testing.expectEqual(ManagerState.Broken, manager.state);
        try std.testing.expectError(error.Broken, manager.put("z", "z", allocator));
        try std.testing.expectError(error.Broken, manager.remove("z", allocator));
        try std.testing.expectError(error.Broken, manager.get(SuccessKey, allocator));
    }

    var manager = try Manager.new(dir, allocator, io, .{}, .{});
    defer manager.deinit(allocator);
}
