const std = @import("std");
const MemTable = @import("storage").MemTable;
const MemTableOpts = @import("storage").MemTableOpts;
const Flusher = @import("flusher.zig").Flusher;
const fs = std.Io.Dir;
const io = std.Options.debug_io;
const Allocator = std.mem.Allocator;
const Mutex = std.Io.Mutex;
const Version = @import("version.zig").Version;
const WalTable = @import("wal_table.zig").WalTable;

pub const Manager = struct {
    // Active MemTable
    active: std.atomic.Value(*WalTable),
    // Root folder
    root: fs,
    // Root path
    path: []const u8,
    // Mutex that protects new table creation
    new_table_lock: Mutex,
    // MemTable options
    opts: ?MemTableOpts,
    // Current version of db
    version: *Version,
    // Allocator used for owned DB structures
    alloc: Allocator,

    const Self = @This();

    pub fn new(dir: fs, path: []const u8, alloc: Allocator, opts: ?MemTableOpts) !Self {
        const version = try Version.from_file(dir, "MANIFEST", alloc);
        const new_file_seq = version.new_file_seq();

        return .{
            .version = version,
            .active = std.atomic.Value(*WalTable).init(try WalTable.new(dir, opts, new_file_seq, alloc)),
            .path = path,
            .root = dir,
            .new_table_lock = Mutex.init,
            .opts = opts,
            .alloc = alloc,
        };
    }

    fn allocate_new_table(self: *Self, old: *WalTable, alloc: Allocator) !void {
        self.new_table_lock.lockUncancelable(io);
        defer self.new_table_lock.unlock(io);

        if (self.active.load(.unordered) == old) {
            const new_file_seq = self.version.new_file_seq();
            const new_table = try WalTable.new(self.root, self.opts, new_file_seq, alloc);

            // Put current table into the flusher
            self.version.insert(old);

            const old_table = self.active.swap(new_table, .monotonic);
            std.debug.assert(old_table == old);
        }
    }

    pub fn put(self: *Self, key: []const u8, value: []const u8, alloc: Allocator) !void {
        // consume would suffice, but whatever
        const table = self.active.load(.acquire);

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
                return try self.version.get(key, self.root, alloc);
            },
        }
    }

    pub fn deinit(self: *Self) void {
        // here we expect that no other user accesses data-base
        const active = self.active.load(.acquire);

        self.version.flush_memtable(active, self.root, self.alloc) catch @panic("failed to flush active memtable");
        active.deinit(self.alloc);
        self.version.deinit(self.alloc);
        self.root.close(io);
    }
};
