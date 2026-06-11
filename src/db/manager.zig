const std = @import("std");
const MemTable = @import("storage").MemTable;
const MemTableOpts = @import("storage").MemTableOpts;
const Flusher = @import("flusher.zig").Flusher;
const Dir = std.Io.Dir;
const Allocator = std.mem.Allocator;
const Mutex = std.Io.Mutex;
const KeyValue = @import("storage").KeyValue;
const Version = @import("version.zig").Version;
const WalTable = @import("wal_table.zig").WalTable;
const test_utils = @import("test_utils");
const fi = test_utils.Injections;
const Statistics = @import("stat.zig").Statistics;
const Slab = @import("slab").Slab;

pub const MemTableSlab = Slab(WalTable, 20);

pub const Manager = struct {
    // Active MemTable
    active: std.atomic.Value(*WalTable),
    // Root folder
    root: Dir,
    // Mutex that protects new table creation
    new_table_lock: Mutex,
    // MemTable options
    opts: MemTableOpts,
    // Current version of db
    version: *Version,
    // IO instance,
    io: std.Io,
    // Statistics
    stat: *Statistics,
    // MemTable allocator
    slab: *MemTableSlab,

    const Self = @This();

    pub fn new(dir: Dir, alloc: Allocator, io: std.Io, opts: ?MemTableOpts) !Self {
        const real_opts = opts orelse MemTableOpts.default();
        const stat = try Statistics.new(alloc);
        errdefer stat.deinit(alloc);

        const slab = try alloc.create(MemTableSlab);
        errdefer alloc.destroy(slab);
        slab.* = try MemTableSlab.init(alloc, io);
        errdefer slab.deinit(alloc);

        const version = try Version.from_file_with_slab(
            dir,
            "MANIFEST",
            real_opts,
            stat,
            slab,
            io,
            alloc,
        );
        const new_file_seq = version.new_file_seq();
        const new_table = slab.alloc();

        new_table.* = try WalTable.new(dir, opts, new_file_seq, version, io, alloc);

        return .{
            .version = version,
            .active = std.atomic.Value(*WalTable).init(new_table),
            .root = dir,
            .new_table_lock = Mutex.init,
            .opts = real_opts,
            .io = io,
            .stat = stat,
            .slab = slab,
        };
    }

    fn allocate_new_table(self: *Self, old: *WalTable, alloc: Allocator) !void {
        self.new_table_lock.lockUncancelable(self.io);
        defer self.new_table_lock.unlock(self.io);

        if (self.active.load(.unordered) == old) {
            const new_file_seq = self.version.new_file_seq();
            const new_table = self.slab.alloc();

            new_table.* = try WalTable.new(
                self.root,
                self.opts,
                new_file_seq,
                self.version,
                self.io,
                alloc,
            );

            // NOTE: swap BEFORE publishing a new table.
            const old_table = self.active.swap(new_table, .monotonic);
            std.debug.assert(old_table == old);

            // Make immune only after new table was published.
            old.make_immune();

            // Put current table into the flusher
            self.version.insert(old);
        }
    }

    pub fn put(self: *Self, key: []const u8, value: []const u8, alloc: Allocator) !void {
        // consume would suffice, but whatever
        const table = self.active.load(.acquire);
        const new_seq = self.version.next_seq();

        test_utils.Scheduler.yield(.LoadCurrentMemtable);

        // Current table is full. Allocate new one
        table.put(key, value, new_seq, alloc) catch |e| {
            if (e == error.OutOfMemory or e == error.Immutable) {
                try self.allocate_new_table(table, alloc);
                // It was updated. Retry the operation
                return self.put(key, value, alloc);
            } else {
                return e;
            }
        };
    }

    /// Removes a value from database
    pub fn remove(self: *Self, key: []const u8, alloc: Allocator) !void {
        // consume would suffice, but whatever
        const table = self.active.load(.acquire);
        const new_seq = self.version.next_seq();

        // Current table is full. Allocate new one
        table.remove(key, new_seq, alloc) catch |e| {
            if (e == error.OutOfMemory or e == error.Immutable) {
                try self.allocate_new_table(table, alloc);
                // It was updated. Retry the operation
                return self.remove(key, alloc);
            } else {
                return e;
            }
        };
    }

    /// Retrieves a value from database
    pub fn get(self: *Self, key: []const u8, alloc: Allocator) !?[]u8 {
        const table = self.active.load(.acquire);
        const val = try table.get(key, self.version.current_seq(), alloc);

        switch (val) {
            .Found => |v| {
                return v;
            },
            .Removed => return null,
            .NotFound => {
                // Resolve from other memtables
                return try self.version.get(key, self.root, self.io, alloc);
            },
        }
    }

    pub fn deinit(self: *Self, alloc: Allocator) void {
        // here we expect that no other user accesses data-base
        const active = self.active.load(.acquire);

        active.make_immune();
        active.assert_no_users();

        self.version.flush_memtable(active, self.io, self.root, alloc) catch {
            @panic("failed to flush active memtable");
        };

        active.deinit(alloc);
        self.version.deinit(self.io, alloc);
        self.slab.free(active);
        self.slab.deinit(alloc);
        alloc.destroy(self.slab);
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

test "UAF during flush" {
    const io = std.testing.io;
    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }
    const allocator = arena.allocator();

    std.Io.Dir.cwd().deleteTree(io, "test_db3") catch {};

    const dir = try openOrCreateDir(io, "test_db3");
    defer {
        std.Io.Dir.cwd().deleteTree(io, "test_db3") catch {
            @panic("gg");
        };
    }

    var manager = try Manager.new(dir, allocator, io, .{ .memtable_size = 5000 });
    defer manager.deinit(allocator);

    var sched = try test_utils.Scheduler.Scheduler.new(allocator);
    defer sched.deinit(allocator);

    const uaf = try sched.spawn(uaf_thread, .{ &manager, allocator }, allocator);
    const insert = try sched.spawn(insert_thread, .{ &manager, allocator }, allocator);

    var plan = try test_utils.Scheduler.SchedulerPlan.new(allocator);
    defer plan.deinit(allocator);

    try plan.add(.{ .fiber = uaf, .run = .{ .Sleep = .LoadCurrentMemtable } }, allocator);
    try plan.add(.{ .fiber = insert, .run = .{ .Sleep = .WalWritten } }, allocator);
    try plan.add(.{ .fiber = uaf, .run = .End }, allocator);

    try sched.run_with_plan(plan, allocator);
}

test "In progress insert" {
    const io = std.testing.io;
    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }
    const allocator = arena.allocator();

    std.Io.Dir.cwd().deleteTree(io, "test_db3") catch {};

    const dir = try openOrCreateDir(io, "test_db3");
    defer {
        std.Io.Dir.cwd().deleteTree(io, "test_db3") catch {
            @panic("gg");
        };
    }

    var manager = try Manager.new(dir, allocator, io, .{ .memtable_size = 100 });
    defer manager.deinit(allocator);

    var sched = try test_utils.Scheduler.Scheduler.new(allocator);
    defer sched.deinit(allocator);

    const first_insert = try sched.spawn(checked_big_insert, .{ &manager, allocator }, allocator);
    const in_progress = try sched.spawn(uaf_thread, .{ &manager, allocator }, allocator);
    const flush_trigger = try sched.spawn(big_insert, .{ &manager, allocator }, allocator);

    var plan = try test_utils.Scheduler.SchedulerPlan.new(allocator);
    defer plan.deinit(allocator);

    try plan.add(.{ .fiber = first_insert, .run = .End }, allocator);
    try plan.add(.{ .fiber = in_progress, .run = .{ .Sleep = .WalWritten } }, allocator);
    try plan.add(.{ .fiber = flush_trigger, .run = .End }, allocator);
    try plan.add(.{ .fiber = in_progress, .run = .End }, allocator);

    try sched.run_with_plan(plan, allocator);
}

test "OOB write" {
    const io = std.testing.io;
    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }
    const allocator = arena.allocator();

    std.Io.Dir.cwd().deleteTree(io, "test_db4") catch {};

    const dir = try openOrCreateDir(io, "test_db4");
    defer {
        std.Io.Dir.cwd().deleteTree(io, "test_db4") catch {
            @panic("gg");
        };
    }

    var manager = try Manager.new(dir, allocator, io, .{ .memtable_size = 100 });
    defer manager.deinit(allocator);

    var sched = try test_utils.Scheduler.Scheduler.new(allocator);
    defer sched.deinit(allocator);

    const first_insert = try sched.spawn(checked_big_insert, .{ &manager, allocator }, allocator);
    const flush_trigger = try sched.spawn(insert_thread, .{ &manager, allocator }, allocator);
    const flush1_trigger = try sched.spawn(insert_second, .{ &manager, allocator }, allocator);

    var plan = try test_utils.Scheduler.SchedulerPlan.new(allocator);
    defer plan.deinit(allocator);

    // 1. Allocate new seq
    try plan.add(.{ .fiber = first_insert, .run = .{ .Sleep = .LoadCurrentMemtable } }, allocator);
    // 2. Fill current memtable with seq > 1st one
    try plan.add(.{ .fiber = flush_trigger, .run = .End }, allocator);
    // 3. Continue first insert. It must allocate new memtable
    try plan.add(.{ .fiber = first_insert, .run = .End }, allocator);
    // 4. Flush second memtable
    try plan.add(.{ .fiber = flush1_trigger, .run = .End }, allocator);

    try sched.run_with_plan(plan, allocator);
    try std.testing.expect(manager.stat.read(.memtable_flush) >= 2);
    try manager.version.sanitize_disk_state(dir, allocator, io);
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

    // There is a race, tho... I am not sure I want to make this counter atomic only for tests
    // (maybe I am)
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

    // There is a race, tho... I am not sure I want to make this counter atomic only for tests
    // (maybe I am)
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

    // 1 create one full memtable
    try insert_values_until_immutable(&manager, 0, 10, allocator);
    try std.testing.expectEqual(manager.version.flusher.count, 1);

    // 2 create second full memtable with values offseted by 1
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

    // Flush some tables to disk with real values.
    try insert_values_until_flushed(&manager, 0, 10, allocator);

    // Put removed values into immutable memtable.
    try remove_values_until_immutable(&manager, 10, allocator);

    const value = manager.get("a" ** 10, allocator);
    try std.testing.expectEqual(null, value);
}

test "Wal does not include not-inserted entries" {
    const builtin = @import("builtin");

    // Zig spawns threads, so fork in multi-threaded env is not really supported
    // (tho whole test is unsafe)
    if (builtin.sanitize_thread) {
        return;
    }

    try fi.fault_injection.enable(.after_insert_oom, 1);
    defer fi.fault_injection.clear();

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

    const expected_kv_size = 44;
    const iterations = 11;
    const memtable_size = expected_kv_size * (iterations - 1);

    const pid = std.posix.system.fork();

    if (pid == -1) {
        std.debug.print("Failed to fork\n", .{});
        return error.ForkFailed;
    }

    if (pid == 0) {
        var manager = Manager.new(dir, allocator, io, .{
            .memtable_size = memtable_size,
        }) catch |e| {
            std.debug.print("Unexpected error returned during create {}\n", .{e});
            std.process.exit(0);
        };

        var key_buf: [10]u8 = undefined;
        var value_buf: [10]u8 = undefined;
        const key = key_buf[0..];
        const value = value_buf[0..];

        std.testing.expectEqual(expected_kv_size, KeyValue.calculate_size(key, value)) catch |e| {
            std.debug.print("Unexpected size of KV {}\n", .{e});
            std.process.exit(0);
        };

        for (1..iterations) |i| {
            @memset(key, 'a' + @as(u8, @intCast(i)));
            @memset(value, 'a' + @as(u8, @intCast(i)));

            manager.put(key, value, allocator) catch {
                std.debug.print("Unexpected error returned during put\n", .{});
                std.process.exit(0);
            };
        }

        // This is should be unreachable
        std.process.exit(0);
    } else {
        var status: u32 = 0;
        const res = std.posix.system.waitpid(@intCast(pid), &status, 0);

        if (res == -1) {
            std.debug.print("Failed to wait\n", .{});
            return error.WaitPidFailed;
        }

        try std.testing.expect(status != 0);
    }
    var key_buf: [10]u8 = undefined;
    const key = key_buf[0..];

    @memset(key, 'a' + @as(u8, @intCast(iterations - 1)));

    // Now reopen it
    var manager = try Manager.new(dir, allocator, io, null);
    defer manager.deinit(allocator);

    // Failed one should not be there
    try std.testing.expectEqual(manager.get(key, allocator), null);

    for (1..iterations - 1) |i| {
        @memset(key, 'a' + @as(u8, @intCast(i)));

        const val = (try manager.get(key, allocator)).?;
        defer allocator.free(val);

        try std.testing.expectEqualSlices(u8, val, key);
    }
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

        // Flush some memtables
        while (manager.version.stat.read(.memtable_flush) < 3) {
            try manager.put("a" ** 10, "a" ** 10, allocator);
        }
    }

    // Reopen it. Should read current manifest and GC old WALs.
    var manager = try Manager.new(dir, allocator, io, .{ .memtable_size = 200 });
    defer manager.deinit(allocator);

    var diriter = dir.iterate();

    var wals: usize = 0;

    while (try diriter.next(io)) |entry| {
        const is_wal = Wal.is_wal_name(entry.name);

        if (is_wal) {
            const stat = try dir.statFile(io, entry.name, .{ .follow_symlinks = false });

            // It must be empty, since it's for the current memtable.
            try std.testing.expectEqual(stat.size, 0);
        }

        wals += @intFromBool(is_wal);
    }

    // There is one empty WAL for the current active table. Others must be deleted.
    try std.testing.expectEqual(wals, 1);
}

test "WAL GC crash" {
    const Wal = @import("wal.zig").Wal;
    const builtin = @import("builtin");

    // Zig spawns threads, so fork in multi-threaded env is not really supported
    // (tho whole test is unsafe)
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

    const pid = std.posix.system.fork();
    if (pid == -1) {
        std.debug.print("Failed to fork\n", .{});
        return error.ForkFailed;
    }

    if (pid == 0) {
        var manager = Manager.new(dir, allocator, io, .{
            .memtable_size = 500,
        }) catch |e| {
            std.debug.print("Unexpected error returned during create {}\n", .{e});
            std.process.exit(0);
        };

        // Insert something, so WAL is active and should not be GCed
        manager.put("a" ** 10, "a" ** 10, allocator) catch |e| {
            std.debug.print("Unexpected error returned during put{}\n", .{e});
            std.process.exit(0);
        };

        std.process.exit(255);
    } else {
        var status: u32 = 0;
        const res = std.posix.system.waitpid(@intCast(pid), &status, 0);

        if (res == -1) {
            std.debug.print("Failed to wait\n", .{});
            return error.WaitPidFailed;
        }

        try std.testing.expect(status != 0);
    }

    // Reopen it. Should read current manifest and GC old WALs.
    var manager = try Manager.new(dir, allocator, io, .{ .memtable_size = 200 });
    defer manager.deinit(allocator);

    var diriter = dir.iterate();
    var wals: usize = 0;

    while (try diriter.next(io)) |entry| {
        const is_wal = Wal.is_wal_name(entry.name);
        wals += @intFromBool(is_wal);
    }

    // There should be one WAL. And it should contain pushed value.
    try std.testing.expectEqual(wals, 1);

    const value = (try manager.get("a" ** 10, allocator)).?;
    defer allocator.free(value);
    try std.testing.expectEqualSlices(u8, "a" ** 10, value);
}
