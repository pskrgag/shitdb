const std = @import("std");
const MemTable = @import("storage").MemTable;
const KeyValueOwned = @import("storage").KeyValueOwned;
const VersionEdit = @import("version.zig").VersionEdit;
const FileMeta = @import("storage").manifest.FileMeta;
const Version = @import("version.zig").Version;
const DoublyLinkedList = std.DoublyLinkedList;
const Thread = std.Thread;
const Allocator = std.mem.Allocator;
const SSTable = @import("storage").sstable.SSTable;
const io = std.Options.debug_io;
const WalTable = @import("wal_table.zig").WalTable;

const MaxNumTables: usize = 5;

pub const Flusher = struct {
    // List of full memtables
    list: [MaxNumTables]?*WalTable,
    // Number of tables
    count: usize,
    // Flusher thread
    thread: std.Thread,
    // Protects concurrent access to list
    mutex: std.Io.Mutex,
    // CV for empty state
    empty_cv: std.Io.Condition,
    // CV for full state
    full_cv: std.Io.Condition,
    // Allocator
    alloc: std.mem.Allocator,
    // Stop flag
    stop: std.atomic.Value(bool),
    // DB directory
    dir: std.Io.Dir,
    // Version manager
    version: *Version,

    fn flush_one(self: *Flusher) !void {
        const first = self.list[0].?;
        try self.version.flush_memtable(first, self.dir, self.alloc);
        first.deinit(self.alloc);

        @memmove(self.list[0 .. MaxNumTables - 1], self.list[1..MaxNumTables]);
        self.list[MaxNumTables - 1] = null;
        self.count -= 1;
    }

    fn flusher_thread_impl(self: *Flusher) !void {
        while (!self.stop.load(.monotonic)) {
            self.mutex.lockUncancelable(io);

            while (self.count == 0 and !self.stop.load(.monotonic))
                self.empty_cv.waitUncancelable(io, &self.mutex);

            if (self.stop.load(.monotonic)) {
                self.mutex.unlock(io);
                return;
            }

            try self.flush_one();

            self.full_cv.signal(io);
            self.mutex.unlock(io);
        }
    }

    fn flusher_thread(self: *Flusher) !void {
        // TODO: smth better please
        flusher_thread_impl(self) catch @panic("Flusher thread panicked");
    }

    pub fn new(alloc: Allocator, version: *Version, dir: std.Io.Dir) !*Flusher {
        const flusher = try alloc.create(Flusher);

        flusher.list = .{null} ** MaxNumTables;
        flusher.count = 0;
        flusher.mutex = std.Io.Mutex.init;
        flusher.empty_cv = std.Io.Condition.init;
        flusher.full_cv = std.Io.Condition.init;
        flusher.alloc = alloc;
        flusher.stop = std.atomic.Value(bool).init(false);
        flusher.version = version;
        flusher.dir = dir;

        // Spawning a thread is a release operation, so all writes should be reversed.
        flusher.thread = try Thread.spawn(.{}, Flusher.flusher_thread, .{flusher});

        return flusher;
    }

    pub fn insert(self: *Flusher, table: *WalTable) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (self.count < MaxNumTables) {
            self.list[self.count] = table;
            self.count += 1;

            self.empty_cv.signal(io);
        } else {
            while (self.count == MaxNumTables)
                self.full_cv.waitUncancelable(io, &self.mutex);

            self.list[self.count] = table;
            self.count += 1;
        }
    }

    pub fn get(self: *Flusher, key: []const u8, seq: usize, alloc: Allocator) !?[]const u8 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        for (0..self.count) |i| {
            const table: *WalTable = self.list[i].?;
            const val = try table.get(key, seq, alloc);

            switch (val) {
                .Found => |v| {
                    return v;
                },
                .Removed => return null,
                .NotFound => {},
            }
        }

        return null;
    }

    pub fn deinit(self: *Flusher, alloc: Allocator) void {
        self.mutex.lockUncancelable(io);
        self.stop.store(true, .monotonic);
        self.empty_cv.broadcast(io);
        self.full_cv.broadcast(io);
        self.mutex.unlock(io);

        self.thread.join();

        while (self.count > 0)
            self.flush_one() catch @panic("Failed to flush MemTable during deinit");

        alloc.destroy(self);
    }
};
