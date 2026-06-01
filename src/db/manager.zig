const std = @import("std");
const MemTable = @import("storage").MemTable;
const MemTableOpts = @import("storage").MemTableOpts;
const Flusher = @import("flusher.zig").Flusher;
const Dir = std.Io.Dir;
const Allocator = std.mem.Allocator;
const Mutex = std.Io.Mutex;
const Version = @import("version.zig").Version;
const WalTable = @import("wal_table.zig").WalTable;
const fi = @import("test_injection");
const Statistics = @import("stat.zig").Statistics;

const LoadSleep = "load UAF";

pub const Manager = struct {
    // Active MemTable
    active: std.atomic.Value(*WalTable),
    // Root folder
    root: Dir,
    // Root path
    path: []const u8,
    // Mutex that protects new table creation
    new_table_lock: Mutex,
    // MemTable options
    opts: MemTableOpts,
    // Current version of db
    version: *Version,
    // Allocator used for owned DB structures
    alloc: Allocator,
    // IO instance,
    io: std.Io,
    // Statistics
    stat: *Statistics,

    const Self = @This();

    pub fn new(dir: Dir, path: []const u8, alloc: Allocator, io: std.Io, opts: ?MemTableOpts) !Self {
        const real_opts = opts orelse MemTableOpts.default();
        const stat = try Statistics.new(alloc);
        errdefer stat.deinit(alloc);

        const version = try Version.from_file(dir, "MANIFEST", real_opts, stat, io, alloc);
        const new_file_seq = version.new_file_seq();

        return .{
            .version = version,
            .active = std.atomic.Value(*WalTable).init(
                try WalTable.new(dir, opts, new_file_seq, version, io, alloc),
            ),
            .path = path,
            .root = dir,
            .new_table_lock = Mutex.init,
            .opts = real_opts,
            .alloc = alloc,
            .io = io,
            .stat = stat,
        };
    }

    fn allocate_new_table(self: *Self, old: *WalTable, alloc: Allocator) !void {
        self.new_table_lock.lockUncancelable(self.io);
        defer self.new_table_lock.unlock(self.io);

        if (self.active.load(.unordered) == old) {
            const new_file_seq = self.version.new_file_seq();
            const new_table = try WalTable.new(
                self.root,
                self.opts,
                new_file_seq,
                self.version,
                self.io,
                alloc,
            );

            // Put current table into the flusher
            self.version.insert(old);

            const old_table = self.active.swap(new_table, .monotonic);
            std.debug.assert(old_table == old);
        }
    }

    pub fn put(self: *Self, key: []const u8, value: []const u8, alloc: Allocator) !void {
        // consume would suffice, but whatever
        const table = self.active.load(.acquire);

        try fi.sleep_injection.sleep(LoadSleep);

        // Current table is full. Allocate new one
        table.put(key, value, self.version.next_seq()) catch |e| {
            if (e == error.OutOfMemory) {
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

        // Current table is full. Allocate new one
        table.remove(key, self.version.next_seq()) catch |e| {
            if (e == error.OutOfMemory) {
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

    pub fn deinit(self: *Self) void {
        // here we expect that no other user accesses data-base
        const active = self.active.load(.acquire);

        self.version.flush_memtable(active, self.io, self.root, self.alloc) catch {
            @panic("failed to flush active memtable");
        };

        active.deinit(self.alloc);
        self.version.deinit(self.io, self.alloc);
        self.stat.deinit(self.alloc);
        self.root.close(self.io);
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

test "UAF during flush" {
    defer fi.sleep_injection.clear();
    try fi.sleep_injection.enable(LoadSleep);

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

    var manager = try Manager.new(dir, "test_db3", allocator, io, .{ .memtable_size = 5000 });
    defer manager.deinit();

    const thread = try std.Thread.spawn(.{}, uaf_thread, .{ &manager, allocator });
    try fi.sleep_injection.wait_sleep(LoadSleep);

    // Now insert a lot of shit and wait while active memtable is flushed
    while (manager.stat.read(.memtable_flush) == 0) {
        try manager.put("hey" ** 10, "baby" ** 10, allocator);
    }

    try fi.sleep_injection.wake(LoadSleep);
    thread.join();
}
