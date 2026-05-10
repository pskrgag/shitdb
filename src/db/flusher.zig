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

const MaxNumTables: usize = 5;

pub const Flusher = struct {
    // List of full memtables
    list: [MaxNumTables]?*MemTable,
    // Number of tables
    count: usize,
    // Flusher thread
    thread: std.Thread,
    // Protects concurrent access to list
    mutex: std.Thread.Mutex,
    // CV for empty state
    empty_cv: std.Thread.Condition,
    // CV for full state
    full_cv: std.Thread.Condition,
    // Allocator
    alloc: std.mem.Allocator,
    // Stop flag
    stop: std.atomic.Value(bool),

    fn flusher_thread_impl(self: *Flusher, dir: std.fs.Dir, version: *Version) !void {
        while (!self.stop.load(.monotonic)) {
            self.mutex.lock();

            while (self.count == 0 and !self.stop.load(.monotonic))
                self.empty_cv.wait(&self.mutex);

            if (self.stop.load(.monotonic)) {
                self.mutex.unlock();
                return;
            }

            const first = self.list[0].?;
            const min = try KeyValueOwned.from_kv(first.min().?, self.alloc);
            const max = try KeyValueOwned.from_kv(first.max().?, self.alloc);
            var seq: usize = 0;

            const new_file = try version.new_file(self.alloc, &seq);
            var edit = try VersionEdit.empty(self.alloc);

            // var iter = first.table.iterator();
            // while (iter.next()) |i| {
            //     std.debug.print("flushing {s}\n", .{ i.as_key() });
            // }

            try edit.new_files.append(self.alloc, FileMeta{
                .lvl = 0,
                .name = new_file,
                .max = max,
                .min = min,
                .seq = seq,
            });

            var table = try SSTable.create(dir, new_file, first, self.alloc);
            try version.apply(edit, self.alloc);
            table.deinit();

            @memmove(self.list[0 .. MaxNumTables - 1], self.list[1..MaxNumTables]);
            self.count -= 1;

            self.full_cv.signal();
            self.mutex.unlock();
        }
    }

    fn flusher_thread(self: *Flusher, dir: std.fs.Dir, version: *Version) !void {
        // TODO: smth better please
        flusher_thread_impl(self, dir, version) catch @panic("Flusher thread panicked");
    }

    pub fn new(alloc: Allocator, version: *Version, dir: std.fs.Dir) !*Flusher {
        const flusher = try alloc.create(Flusher);

        flusher.list = .{null} ** MaxNumTables;
        flusher.count = 0;
        flusher.mutex = std.Thread.Mutex{};
        flusher.empty_cv = std.Thread.Condition{};
        flusher.full_cv = std.Thread.Condition{};
        flusher.alloc = alloc;
        flusher.stop = std.atomic.Value(bool).init(false);

        // Spawning a thread is a release operation, so all writes should be reversed.
        flusher.thread = try Thread.spawn(
            .{},
            Flusher.flusher_thread,
            .{ flusher, dir, version },
        );

        return flusher;
    }

    pub fn insert(self: *Flusher, table: *MemTable) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.count < MaxNumTables) {
            self.list[self.count] = table;
            self.count += 1;

            self.empty_cv.signal();
        } else {
            while (self.count == MaxNumTables)
                self.full_cv.wait(&self.mutex);

            self.list[self.count] = table;
            self.count += 1;
        }
    }

    pub fn get(self: *Flusher, key: []const u8, seq: usize, alloc: Allocator) !?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (0..self.count) |i| {
            const table: *MemTable = self.list[i].?;
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
        self.stop.store(true, .monotonic);
        self.empty_cv.signal();
        self.thread.join();

        alloc.destroy(self);
    }
};
