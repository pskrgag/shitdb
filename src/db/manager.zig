const std = @import("std");
const MemTable = @import("storage").MemTable;
const MemTableOpts = @import("storage").MemTableOpts;
const Flusher = @import("flusher.zig").Flusher;
const fs = std.fs;
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;
const Version = @import("version.zig").Version;

pub const Manager = struct {
    // Active MemTable
    active: std.atomic.Value(*MemTable),
    // Root folder
    root: fs.Dir,
    // Root path
    path: []const u8,
    // Mutex that protects new table creation
    new_table_lock: Mutex,
    // MemTable options
    opts: ?MemTableOpts,
    // Current version of db
    version: *Version,

    const Self = @This();

    pub fn new(dir: fs.Dir, path: []const u8, alloc: Allocator, opts: ?MemTableOpts) !Self {
        const version = try Version.from_file(dir, "MANIFEST", alloc);

        return .{
            .version = version,
            .active = std.atomic.Value(*MemTable).init(try MemTable.new(alloc, opts)),
            .path = path,
            .root = dir,
            .new_table_lock = Mutex{},
            .opts = opts,
        };
    }

    fn allocate_new_table(self: *Self, old: *MemTable, alloc: Allocator) !void {
        self.new_table_lock.lock();
        defer self.new_table_lock.unlock();

        if (self.active.load(.unordered) == old) {
            const new_table = try MemTable.new(alloc, self.opts);

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
        table.put(key, value, self.version.next_seq()) catch {
            try self.allocate_new_table(table, alloc);
            // It was updated. Retry the operation
            return self.put(key, value, alloc);
        };
    }

    pub fn remove(self: *Self, key: []const u8, alloc: Allocator) !void {
        // consume would suffice, but whatever
        const table = self.active.load(.acquire);

        // Current table is full. Allocate new one
        table.remove(key, self.version.next_seq()) catch {
            try self.allocate_new_table(table, alloc);
            // It was updated. Retry the operation
            return self.remove(key, alloc);
        };
    }

    pub fn deinit_value(self: *Self, value: std.ArrayList(u8)) void {
        value.deinit(self.alloc.allocator());
    }

    pub fn get(self: *Self, key: []const u8, alloc: Allocator) !?[]u8 {
        const table = self.active.load(.acquire);
        const val = try table.get(key, self.version.current_seq(), alloc);

        switch (val) {
            .Found => |v| {
                var res = try std.ArrayList(u8).initCapacity(alloc, v.len);

                try res.appendSlice(alloc, v);
                return res.items;
            },
            .Removed => return null,
            .NotFound => {
                // Resolve from other memtables
                return try self.version.get(key, self.root, alloc);
            },
        }
    }
};
