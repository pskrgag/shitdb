const std = @import("std");
const File = std.fs.File;
const MemTable = @import("storage").MemTable;
const SSTable = @import("storage").sstable.SSTable;
const manifest = @import("storage").manifest;
const Flusher = @import("flusher.zig").Flusher;
const Allocator = std.mem.Allocator;
const KeyValueOwned = @import("storage").KeyValueOwned;
const Mutex = std.Thread.Mutex;
const Value = std.atomic.Value;

pub const FileMeta = struct {
    name: []const u8,
    max: KeyValueOwned,
    min: KeyValueOwned,
    lvl: u8,
    seq: usize,

    fn less_than(ctx: void, lhs: FileMeta, rhs: FileMeta) bool {
        _ = ctx;

        if (lhs.lvl < rhs.lvl)
            return true;

        return lhs.seq > rhs.seq;
    }
};

pub const Version = struct {
    // File handle
    file: File,
    // File data
    data: [*]u8,
    // Next file number
    next_file: Value(usize),
    // Next sequence number
    next_sequence: Value(usize),
    // Alive SSTables
    tables: std.ArrayList(FileMeta),
    // Protects concurrent edit applies
    mutex: Mutex,
    // Flusher that periodically flushes immutable tables
    flusher: *Flusher,
    // Local allocator

    const Self = @This();

    pub fn apply(self: *Self, edit: VersionEdit, alloc: Allocator) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (edit.new_files.items) |file| {
            try self.tables.append(alloc, file);
        }

        if (edit.next_file) |next_file| {
            self.next_file = Value(usize).init(next_file);
        }
    }

    pub fn next_seq(self: *Self) usize {
        return self.next_sequence.fetchAdd(1, .monotonic);
    }

    pub fn current_seq(self: *Self) usize {
        return self.next_sequence.load(.monotonic);
    }

    pub fn new_file(self: *Self, alloc: Allocator, seq: *usize) ![]const u8 {
        const s = self.next_file.fetchAdd(1, .monotonic);
        const res = std.fmt.allocPrint(alloc, "memtable{}.sst", .{self.next_file.fetchAdd(1, .monotonic)});

        seq.* = s;
        return res;
    }

    pub fn from_file(dir: std.fs.Dir, path: []const u8, alloc: Allocator) !*Self {
        const file = try dir.createFile(path, .{
            .exclusive = false,
            .read = true,
        });
        const stat = try file.stat();
        var size = stat.size;
        const res = try alloc.create(Self);

        // Mmaping 0 is not valid thing (make sense, right?)
        if (size == 0) {
            try file.seekBy(1);
            size = 1;
        }

        const mmap = try std.posix.mmap(
            null,
            size,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            .{ .TYPE = .SHARED },
            file.handle,
            0,
        );

        res.* = .{
            .flusher = try Flusher.new(alloc, res, dir),
            .file = file,
            .data = mmap.ptr,
            .tables = try std.ArrayList(FileMeta).initCapacity(alloc, 0),
            .next_file = Value(usize).init(0),
            .next_sequence = Value(usize).init(0),
            .mutex = Mutex{},
        };
        return res;
    }

    // Inserts new immutable memtable
    pub fn insert(self: *Version, table: *MemTable) void {
        self.flusher.insert(table);
    }

    // Resolves value request.
    pub fn get(self: *Self, key: []const u8, dir: std.fs.Dir, alloc: Allocator) !?[]u8 {
        // Resolved from immutable table
        if (try self.flusher.get(key, self.current_seq(), alloc)) |val| {
            var res = try std.ArrayList(u8).initCapacity(alloc, val.len);

            try res.appendSlice(alloc, val);
            return res.items;
        }

        // Search sstables on a disk
        return self.search_disk(key, dir, alloc);
    }

    fn search_disk(self: *Self, key: []const u8, dir: std.fs.Dir, alloc: Allocator) !?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        var candidates = try std.ArrayList(FileMeta).initCapacity(alloc, self.tables.items.len);

        for (self.tables.items) |table| {
            const min = table.min.as_kv().as_key();
            const max = table.max.as_kv().as_key();
            const cmp_min = std.mem.order(u8, min, key);
            const cmp_max = std.mem.order(u8, max, key);

            if ((cmp_min == .lt or cmp_min == .eq) and (cmp_max == .gt or cmp_max == .eq)) {
                try candidates.append(alloc, table);
            }
        }

        if (candidates.items.len == 0)
            return null;

        std.mem.sort(FileMeta, candidates.items, {}, FileMeta.less_than);

        for (candidates.items) |table| {
            const ss = try SSTable.open(dir, table.name);
            const value = try ss.find_value(key, alloc);

            switch (value) {
                .Removed => return null,
                .Found => |v| return v,
                else => {},
            }
        }

        return null;
    }
};

pub const VersionEdit = struct {
    next_file: ?usize,
    new_files: std.ArrayList(FileMeta),
    next_seq: ?usize,

    pub fn empty(alloc: Allocator) !VersionEdit {
        return .{
            .next_file = null,
            .new_files = try std.ArrayList(FileMeta).initCapacity(alloc, 0),
            .next_seq = null,
        };
    }
};
