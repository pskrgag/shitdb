const std = @import("std");
const zbench = @import("zbench");
const db_mod = @import("db");
const SkipListPrng = @import("skiplist").Prng;

const Db = db_mod.KeyValue;
const DbOptions = db_mod.KeyValueOptions;

const BenchDirPrefix = "bench_db";
const InsertCount = 1_000;
const ReadCount = 5_000;
const KeySize = 24;
const ValueSize = 128;

const KeySizeBig = 1 << 10;
const ValueSizeBig = KeySizeBig * 2;

var Allocator = std.heap.DebugAllocator(.{}){};
var DbInstance: Db = undefined;
var DbActive = false;
var DirBuf: [64]u8 = undefined;
var DirName: []const u8 = BenchDirPrefix;
var DirSeq: usize = 0;

fn allocator() std.mem.Allocator {
    return Allocator.allocator();
}

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn make_key(comptime size: usize, idx: usize) []u8 {
    var key = allocator().alloc(u8, size) catch @panic("failed to allocate");

    @memset(key, 'k');
    std.mem.writeInt(u64, key[size - @sizeOf(u64) ..][0..@sizeOf(u64)], idx, .little);
    return key;
}

fn make_value(comptime size: usize, idx: usize) []u8 {
    var value = allocator().alloc(u8, size) catch @panic("failed to allocate");

    @memset(value, 'v');
    std.mem.writeInt(u64, value[0..@sizeOf(u64)], idx, .little);
    return value;
}

fn next_dir_name() []const u8 {
    const name = std.fmt.bufPrint(&DirBuf, "{s}_{d}", .{ BenchDirPrefix, DirSeq }) catch {
        @panic("failed to format benchmark dir");
    };
    DirSeq += 1;

    return name;
}

fn clean_dir(name: []const u8) void {
    std.Io.Dir.cwd().deleteTree(io(), name) catch {
        @panic("Failed to clean up dir");
    };
}

fn open_db(memtable_size: usize, sync: bool) void {
    DirName = next_dir_name();
    clean_dir(DirName);

    std.Io.Dir.cwd().createDirPath(io(), DirName) catch {
        @panic("failed to create benchmark dir");
    };

    DbInstance = Db.new(
        DirName,
        allocator(),
        io(),
        DbOptions{ .memtable = .{ .memtable_size = memtable_size }, .wal = .{ .sync = sync } },
    ) catch {
        @panic("failed to open benchmark db");
    };

    SkipListPrng.reset();
    DbActive = true;
}

fn close_db() void {
    if (DbActive) {
        DbInstance.deinit(allocator());
        DbActive = false;
    }
}

fn setup_large_memtable() void {
    open_db(1 << 30, false);
}

fn setup_large_memtable_sync() void {
    open_db(1 << 30, true);
}

fn setup_small_memtable() void {
    open_db(32 << 10, false);
}

fn seed_db(count: usize) void {
    for (0..count) |idx| {
        const key = make_key(KeySize, idx);
        const value = make_value(ValueSize, idx);

        DbInstance.put(key, value, allocator()) catch {
            @panic("failed to seed benchmark db");
        };
    }
}

fn setup_active_gets() void {
    open_db(1 << 30, false);
    seed_db(InsertCount);
}

fn setup_sstable() void {
    open_db(1 << 30, false);
    seed_db(InsertCount);
    close_db();

    DbInstance = Db.new(
        DirName,
        allocator(),
        io(),
        DbOptions{ .memtable = .{ .memtable_size = 1 << 30 } },
    ) catch {
        @panic("failed to reopen benchmark db");
    };

    DbActive = true;
}

fn teardown_db() void {
    close_db();
    clean_dir(DirName);
}

fn put_sequential(bench_alloc: std.mem.Allocator) void {
    _ = bench_alloc;

    for (0..InsertCount) |idx| {
        const key = make_key(KeySize, idx);
        const value = make_value(ValueSize, idx);

        DbInstance.put(key, value, allocator()) catch {
            @panic("db put failed");
        };
    }
}

fn put_sequential_big(bench_alloc: std.mem.Allocator) void {
    _ = bench_alloc;

    for (0..InsertCount) |idx| {
        const key = make_key(KeySizeBig, idx);
        const value = make_value(ValueSizeBig, idx);

        DbInstance.put(key, value, allocator()) catch {
            @panic("db put failed");
        };
    }
}

fn get_existing(bench_alloc: std.mem.Allocator) void {
    _ = bench_alloc;

    for (0..ReadCount) |idx| {
        const key = make_key(KeySize, idx % InsertCount);
        const value = DbInstance.get(key, allocator()) catch {
            @panic("db get failed");
        };

        if (value) |v| {
            allocator().free(v);
        } else {
            @panic("db get missed existing key");
        }
    }
}

fn get_missing(bench_alloc: std.mem.Allocator) void {
    _ = bench_alloc;

    for (0..ReadCount) |idx| {
        const key = make_key(KeySize, InsertCount + idx);
        const value = DbInstance.get(key, allocator()) catch {
            @panic("db get failed");
        };

        if (value) |v| {
            allocator().free(v);
            @panic("db get found missing key");
        }
    }
}

fn create_name_insert(prefix: []const u8, key_size: usize, value_size: usize) []const u8 {
    return std.fmt.allocPrint(Allocator.allocator(), "{s}. Count {d}, key size {d} value size {d}", .{
        prefix,
        InsertCount,
        key_size,
        value_size,
    }) catch {
        @panic("Failed to allocate name");
    };
}

fn create_find_insert(prefix: []const u8, key_size: usize, value_size: usize) []const u8 {
    return std.fmt.allocPrint(Allocator.allocator(), "{s}. Count {d}, key size {d} value size {d}", .{
        prefix,
        ReadCount,
        key_size,
        value_size,
    }) catch {
        @panic("Failed to allocate name");
    };
}

pub fn add_benches(bench: *zbench.Benchmark) !void {
    try bench.add(create_name_insert(
        "DB put sequential large memtable",
        KeySize,
        ValueSize,
    ), put_sequential, .{
        .hooks = .{
            .before_each = setup_large_memtable,
            .after_each = teardown_db,
        },
        .iterations = 100,
    });

    try bench.add(create_name_insert(
        "DB put sequential large memtable",
        KeySizeBig,
        ValueSizeBig,
    ), put_sequential_big, .{
        .hooks = .{
            .before_each = setup_large_memtable,
            .after_each = teardown_db,
        },
        .iterations = 100,
    });

    try bench.add(create_name_insert(
        "DB put sequential large memtable+sync",
        KeySize,
        ValueSize,
    ), put_sequential, .{
        .hooks = .{
            .before_each = setup_large_memtable_sync,
            .after_each = teardown_db,
        },
        .iterations = 3,
    });

    try bench.add(create_name_insert(
        "DB put sequential small memtable",
        KeySize,
        ValueSize,
    ), put_sequential, .{
        .hooks = .{
            .before_each = setup_small_memtable,
            .after_each = teardown_db,
        },
        .iterations = 100,
    });

    try bench.add(create_find_insert(
        "DB get active memtable hit",
        KeySize,
        ValueSize,
    ), get_existing, .{
        .hooks = .{
            .before_each = setup_active_gets,
            .after_each = teardown_db,
        },
        .iterations = 100,
    });

    try bench.add(create_find_insert(
        "DB get SSTable hit",
        KeySize,
        ValueSize,
    ), get_existing, .{
        .hooks = .{
            .before_each = setup_sstable,
            .after_each = teardown_db,
        },
        .iterations = 100,
    });

    try bench.add(create_find_insert(
        "DB get missing",
        KeySize,
        ValueSize,
    ), get_missing, .{
        .hooks = .{
            .before_each = setup_sstable,
            .after_each = teardown_db,
        },
        .iterations = 100,
    });
}
