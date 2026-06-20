const std = @import("std");
const MemTableOpts = @import("storage").MemTableOpts;
const Dir = std.Io.Dir;
const Allocator = std.mem.Allocator;
const KeyValue = @import("storage").KeyValue;
const Version = @import("version.zig").Version;
const WalTable = @import("wal_table.zig").WalTable;
const test_utils = @import("test_utils");
const Statistics = @import("stat.zig").Statistics;
const Mutex = @import("sync").mutex.Mutex;
const KVSeq = @import("storage").KVSeq;

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
    // Count
    count: usize = 0,

    pub fn iter(self: *const Transaction) TransactionIter {
        return .{ .head = self.ops.first };
    }

    pub fn push_active(self: *Transaction, op: *PendingWrite) void {
        self.count += 1;
        self.ops.append(&op.active_node);
    }
};

// Pending write request
pub const PendingWrite = struct {
    op: WriteOp,
    done: bool,
    pending_node: std.DoublyLinkedList.Node = .{},
    active_node: std.DoublyLinkedList.Node = .{},
};

pub const Manager = struct {
    // Root folder
    root: Dir,
    // Mutex that protects new table creation
    dblock: Mutex,
    // CV for writers
    write_cv: std.Io.Condition,
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

    const Self = @This();

    pub fn new(dir: Dir, alloc: Allocator, io: std.Io, opts: ?MemTableOpts) !Self {
        const real_opts = opts orelse MemTableOpts.default();
        const stat = try Statistics.new(alloc);
        errdefer stat.deinit(alloc);

        const version = try Version.from_file(
            dir,
            "MANIFEST",
            real_opts,
            stat,
            true,
            io,
            alloc,
        );

        return .{
            .writers = std.DoublyLinkedList{},
            .writers_count = 0,
            .write_cv = std.Io.Condition.init,
            .version = version,
            .root = dir,
            .dblock = Mutex.init,
            .opts = real_opts,
            .io = io,
            .stat = stat,
        };
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
            .done = false,
        };

        const transaction = blk: {
            self.dblock.lockUncancelable(self.io);
            defer self.dblock.unlock(self.io);

            self.writers.append(&pending.pending_node);
            self.writers_count += 1;

            while (pending.done == false and self.writers.first != &pending.pending_node) {
                try self.write_cv.wait(self.io, &self.dblock.mtx);
            }

            // It was completed by the leader.
            if (pending.done) {
                return;
            }

            break :blk self.build_transaction();
        };

        // Now mutex is released and we can push to memtable and write WAL.
        // self.dblock.assert_not_locked();
        // TODO: handle
        try self.version.commit(transaction, self.root, self.io, alloc);

        // Now take the mutex back and remove all pending writes from the queue.
        self.dblock.lockUncancelable(self.io);

        for (0..transaction.count) |_| {
            const old = self.writers.popFirst();
            std.debug.assert(old != null);

            const writer: *PendingWrite = @fieldParentPtr("pending_node", old.?);
            writer.done = true;
            self.writers_count -= 1;
        }

        self.dblock.unlock(self.io);
        self.write_cv.broadcast(self.io);
    }

    /// Puts new value into memtable.
    pub fn put(self: *Self, key: []const u8, value: []const u8, alloc: Allocator) !void {
        try self.write(WriteOp{ .Put = .{ .key = key, .value = value, .seq = undefined } }, alloc);
    }

    /// Removes a value from database
    pub fn remove(self: *Self, key: []const u8, alloc: Allocator) !void {
        try self.write(WriteOp{ .Remove = .{ .key = key, .seq = undefined } }, alloc);
    }

    /// Retrieves a value from database
    pub fn get(self: *Self, key: []const u8, alloc: Allocator) !?[]u8 {
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

    var memtable = try MemTable.new(alloc, manager.io, null);
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

    var manager = try Manager.new(dir, allocator, io, null);
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

    var manager = try Manager.new(dir, allocator, io, .{ .memtable_size = 200 });
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

    var manager = try Manager.new(dir, allocator, io, .{ .memtable_size = 200 });
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
        var manager = try Manager.new(dir, allocator, io, .{ .memtable_size = 200 });
        defer manager.deinit(allocator);

        while (manager.version.stat.read(.memtable_flush) < 3) {
            try manager.put("a" ** 10, "a" ** 10, allocator);
        }
    }

    var manager = try Manager.new(dir, allocator, io, .{ .memtable_size = 200 });
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
            }) catch |e| {
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

    var manager = try Manager.new(dir, allocator, io, .{ .memtable_size = 200 });
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
