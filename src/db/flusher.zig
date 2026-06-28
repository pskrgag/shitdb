const std = @import("std");
const MemTable = @import("storage").memtable.MemTable;
const KeyValueOwned = @import("storage").memtable.KeyValueOwned;
const VersionEdit = @import("version.zig").VersionEdit;
const FileMeta = @import("storage").manifest.FileMeta;
const Version = @import("version.zig").Version;
const DoublyLinkedList = std.DoublyLinkedList;
const Thread = std.Thread;
const Allocator = std.mem.Allocator;
const SSTable = @import("storage").sstable.SSTable;
const WalTable = @import("wal_table.zig").WalTable;
const KVSeq = @import("storage").memtable.KVSeq;
const GetResult = @import("storage").memtable.GetResult;
const ei = @import("test_utils").Injections.error_injection;
const Mutex = @import("sync").mutex.Mutex;
const Condition = @import("sync").cv.Condition;
const Storage = @import("storage").storage.Storage;

const MaxNumTables: usize = 5;

pub const Flusher = struct {
    // List of full memtables
    list: [MaxNumTables]?*WalTable,
    // Number of tables
    count: usize,
    // Flusher thread
    thread: std.Thread,
    // Protects concurrent access to list
    mutex: Mutex,
    // CV for empty state
    empty_cv: Condition,
    // CV for full state
    full_cv: Condition,
    // Allocator
    alloc: std.mem.Allocator,
    // Stop flag
    stop: std.atomic.Value(bool),
    // DB storage
    storage: Storage,
    // IO instance
    io: std.Io,
    // Version manager
    version: *Version,
    // Error from the thread
    err: ?anyerror,

    // NOTE: we hold the lock there to keep consistency:
    //
    // - Inserted values should be either in memtable or on the disk. If we drop the lock there,
    //   the first table would be unreachable from the user.
    fn flush_one(self: *Flusher) !void {
        const first = self.list[0].?;

        @memmove(self.list[0 .. MaxNumTables - 1], self.list[1..MaxNumTables]);
        self.list[MaxNumTables - 1] = null;
        self.count -= 1;

        first.wait_no_users();
        try self.version.flush_memtable(first, self.io, &self.storage, self.alloc);
        first.deinit(self.alloc) catch @panic("Failed to deinit flushed MemTable");

        self.version.slab.free(first);
        self.version.stat.inc(.memtable_flush);
    }

    fn flusher_thread(self: *Flusher) void {
        while (!self.stop.load(.monotonic)) {
            self.mutex.lockUncancelable(self.io);

            while (self.count == 0 and !self.stop.load(.monotonic))
                self.empty_cv.waitUncancelable(self.io, &self.mutex);

            if (self.stop.load(.monotonic)) {
                self.mutex.unlock(self.io);
                return;
            }

            ei.maybe_error(.memtable_flush, self.flush_one()) catch |e| {
                self.err = e;

                self.mutex.unlock(self.io);
                self.full_cv.signal(self.io);
                return;
            };

            self.full_cv.signal(self.io);
            self.mutex.unlock(self.io);
        }
    }

    fn is_healthy(self: *Flusher) !void {
        if (self.err) |e| {
            return e;
        }
    }

    pub fn new(alloc: Allocator, version: *Version, storage: *Storage, io: std.Io) !*Flusher {
        const flusher = try alloc.create(Flusher);
        errdefer alloc.destroy(flusher);

        flusher.* = .{
            .list = .{null} ** MaxNumTables,
            .count = 0,
            .mutex = Mutex.init,
            .empty_cv = Condition.init,
            .full_cv = Condition.init,
            .alloc = alloc,
            .stop = std.atomic.Value(bool).init(false),
            .version = version,
            .storage = storage.*,
            .io = io,
            .err = null,
            .thread = undefined,
        };

        // Spawning a thread is a release operation, so all writes should be reversed.
        flusher.thread = try Thread.spawn(.{}, Flusher.flusher_thread, .{flusher});

        return flusher;
    }

    pub fn insert(self: *Flusher, table: *WalTable) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        try self.is_healthy();

        if (self.count < MaxNumTables) {
            self.list[self.count] = table;
            self.count += 1;
        } else {
            self.empty_cv.signal(self.io);

            while (self.count == MaxNumTables)
                self.full_cv.waitUncancelable(self.io, &self.mutex);

            self.list[self.count] = table;
            self.count += 1;
        }
    }

    pub fn flush_all(self: *Flusher) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        self.empty_cv.signal(self.io);

        while (self.count > 0 and self.err == null)
            self.full_cv.waitUncancelable(self.io, &self.mutex);

        try self.is_healthy();
    }

    pub fn get(self: *Flusher, key: []const u8, seq: KVSeq, alloc: Allocator) !GetResult {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        try self.is_healthy();

        for (0..self.count) |i| {
            const table: *WalTable = self.list[self.count - 1 - i].?;
            const val = try table.get(key, seq, alloc);

            switch (val) {
                .Found, .Removed => return val,
                .NotFound => {},
            }
        }

        return .NotFound;
    }

    pub fn deinit(self: *Flusher, alloc: Allocator) void {
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            self.stop.store(true, .monotonic);
            self.empty_cv.broadcast(self.io);
            self.full_cv.broadcast(self.io);
        }

        self.thread.join();

        while (self.count > 0) {
            self.flush_one() catch @panic("Failed to flush MemTable during deinit");
        }

        alloc.destroy(self);
    }
};
