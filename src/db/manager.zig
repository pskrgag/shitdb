const std = @import("std");
const MemTable = @import("storage").MemTable;
const MemTableOpts = @import("storage").MemTableOpts;
const Flusher = @import("flusher.zig").Flusher;
const fs = std.fs;
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;

pub const Manager = struct {
    // Active MemTable
    active: std.atomic.Value(*MemTable),
    // Root folder
    root: fs.Dir,
    // Root path
    path: []const u8,
    // Flusher that manages immutable memtables
    flusher: Flusher,
    // Mutex that protects new table creation
    flusher_mutex: Mutex,
    // MemTable options
    opts: ?MemTableOpts,

    const Self = @This();

    pub fn new(dir: fs.Dir, path: []const u8, alloc: Allocator, opts: ?MemTableOpts) !Self {
        return .{
            .active = std.atomic.Value(*MemTable).init(try MemTable.new(alloc, opts)),
            .path = path,
            .root = dir,
            .flusher = Flusher.new(),
            .flusher_mutex = Mutex{},
            .opts = opts,
        };
    }

    fn allocate_new_table(self: *Self, old: *MemTable, alloc: Allocator) !void {
        self.flusher_mutex.lock();
        defer self.flusher_mutex.unlock();

        if (self.active.load(.unordered) == old) {
            const new_table = try MemTable.new(alloc, self.opts);

            // Put current table into the flusher
            self.flusher.insert(old);

            const old_table = self.active.swap(new_table, .monotonic);
            std.debug.assert(old_table == old);
        }
    }

    pub fn put(self: *Self, key: []const u8, value: []const u8, alloc: Allocator) !void {
        // consume would suffice, but whatever
        const table = self.active.load(.acquire);

        // Current table is full. Allocate new one
        table.put(key, value) catch {
            try self.allocate_new_table(table, alloc);
            // It was updated. Retry the operation
            return self.put(key, value, alloc);
        };
    }

    pub fn remove(self: *Self, key: []const u8, alloc: Allocator) !void {
        // consume would suffice, but whatever
        const table = self.active.load(.acquire);

        // Current table is full. Allocate new one
        table.remove(key) catch {
            try self.allocate_new_table(table, alloc);
            // It was updated. Retry the operation
            return self.remove(key, alloc);
        };
    }

    pub fn get(self: *Self, key: []const u8) ?[]const u8 {
        const table = self.active.load(.acquire);
        const val = table.get(key);

        switch (val) {
            .Found => |v| {
                return v;
            },
            .Removed => return null,
            .NotFound => {
                self.flusher_mutex.lock();
                defer self.flusher_mutex.unlock();

                // Check immutable
                return self.flusher.get(key);
            },
        }
    }
};
