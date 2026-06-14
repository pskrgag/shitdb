const std = @import("std");
const MemTable = @import("storage").MemTable;
const Wal = @import("wal.zig").Wal;
const WalEntry = @import("wal.zig").WalEntry;
const Allocator = std.mem.Allocator;
const MemTableOpts = @import("storage").MemTableOpts;
const GetResult = @import("storage").GetResult;
const KeyValue = @import("storage").KeyValue;
const KVSeq = @import("storage").KVSeq;
const FileSeq = @import("storage").manifest.FileSeq;
const test_utils = @import("test_utils");
const fi = test_utils.Injections;
const Version = @import("version.zig").Version;
const VersionEdit = @import("version.zig").VersionEdit;
const Value = std.atomic.Value;
const SleepingCounter = @import("sleeping_count.zig").SleepingCounter;

pub const State = enum(u8) {
    active,
    immutable,
};

/// Memtable + WAL
pub const WalTable = struct {
    table: MemTable,
    wal: Wal,
    seq: FileSeq,
    io: std.Io,
    state: Value(State),
    in_progress: SleepingCounter,

    /// Constructs new WAL+MemTable
    pub fn new(
        dir: std.Io.Dir,
        user_opts: ?MemTableOpts,
        seq: FileSeq,
        version: ?*Version,
        io: std.Io,
        alloc: Allocator,
    ) !WalTable {
        const opts = user_opts orelse MemTableOpts.default();

        return .{
            .table = try MemTable.new(alloc, io, opts),
            .wal = try Wal.new(dir, seq, version, opts.memtable_size, io, alloc),
            .seq = seq,
            .io = io,
            .state = Value(State).init(.active),
            .in_progress = SleepingCounter.init(),
        };
    }

    /// Opens existing WAL
    pub fn open(
        dir: std.Io.Dir,
        user_opts: MemTableOpts,
        seq: FileSeq,
        io: std.Io,
        alloc: Allocator,
    ) !WalTable {
        var self = WalTable{
            .table = try MemTable.new(alloc, io, user_opts),
            .wal = try Wal.open(dir, seq, io, alloc),
            .seq = seq,
            .io = io,
            .state = Value(State).init(.active),
            .in_progress = SleepingCounter.init(),
        };

        try self.wal.replay_to(&self, io);
        return self;
    }

    fn get_state(self: *WalTable) State {
        const s = self.state.load(.monotonic);

        // Sanity check that enum is sane (table was not freed or smth. See memset in deinit)
        std.debug.assert(std.enums.fromInt(State, @intFromEnum(s)) != null);
        return s;
    }

    pub fn assert_immutable(self: *WalTable) void {
        std.debug.assert(self.get_state() == .immutable);
    }

    pub fn assert_no_users(self: *WalTable) void {
        std.debug.assert(self.in_progress.counter.load(.monotonic) == 0);
    }

    fn assert_active(self: *WalTable) void {
        std.debug.assert(self.get_state() == .active);
    }

    fn guard_active(self: *WalTable) !void {
        if (self.get_state() != .active) {
            return error.Immutable;
        }
    }

    pub fn make_immune(self: *WalTable) void {
        const prev = self.state.swap(.immutable, .release);

        // After that all attempts to write must fail.
        std.debug.assert(prev == .active);
    }

    /// Special wrapper for WAL replay
    pub fn put_but_record(self: *WalTable, key: []const u8, value: []const u8, seq: KVSeq) !void {
        self.assert_active();
        try self.table.put(key, value, seq);
    }

    /// Special wrapper for WAL replay
    pub fn remove_but_record(self: *WalTable, key: []const u8, seq: KVSeq) !void {
        self.assert_active();
        try self.table.remove(key, seq);
    }

    pub fn wait_no_users(self: *WalTable) void {
        self.in_progress.wait_zero();
    }

    const Action = union(enum) {
        Put: struct {
            key: []const u8,
            value: []const u8,
            seq: KVSeq,
        },
        Remove: struct {
            key: []const u8,
            seq: KVSeq,
        },
    };

    fn insert(self: *WalTable, action: Action) !void {
        self.in_progress.inc();
        defer self.in_progress.dec();

        try self.guard_active();

        var kv: KeyValue = undefined;
        var entry: WalEntry = undefined;

        switch (action) {
            .Put => |p| {
                kv = self.table.create_add_kv(p.key, p.value, p.seq) catch |e| {
                    if (e == error.OutOfMemory) {
                        fi.fault_injection.crash(.after_insert_oom);
                    }

                    return e;
                };
                entry = .{ .Add = .{ .key = p.key, .value = p.value, .seq = p.seq } };
            },
            .Remove => |r| {
                kv = self.table.create_remove_kv(r.key, r.seq) catch |e| {
                    if (e == error.OutOfMemory) {
                        fi.fault_injection.crash(.after_insert_oom);
                    }

                    return e;
                };
                entry = .{ .Remove = .{ .key = r.key, .seq = r.seq } };
            },
        }

        // In case of WAL record failure, KV is leaked. Since allocator is bounded arena, there is
        // no way we can return it back.

        try self.wal.record(entry);
        test_utils.Scheduler.yield(.WalWritten);

        try self.table.put_kv(kv);
        fi.fault_injection.crash(.after_wal);
    }

    /// Puts value from the memtable and records it into WAL
    pub fn put(self: *WalTable, key: []const u8, value: []const u8, seq: KVSeq) !void {
        return self.insert(.{ .Put = .{ .key = key, .value = value, .seq = seq } });
    }

    /// Removes value from the memtable and records it into WAL
    pub fn remove(self: *WalTable, key: []const u8, seq: KVSeq) !void {
        return self.insert(.{ .Remove = .{ .key = key, .seq = seq } });
    }

    /// Retrieves value from the memtable
    pub fn get(self: *WalTable, key: []const u8, seq: KVSeq, alloc: Allocator) !GetResult {
        return try self.table.get(key, seq, alloc);
    }

    /// Returns maximum key
    pub fn max(self: *WalTable) ?KeyValue {
        return self.table.max();
    }

    /// Returns minimal key
    pub fn min(self: *WalTable) ?KeyValue {
        return self.table.min();
    }

    /// Returns minimal key
    pub fn max_seq(self: *WalTable) KVSeq {
        return self.table.max_seq.load(.monotonic);
    }

    /// Deinits table
    pub fn deinit(self: *WalTable, alloc: Allocator) !void {
        try self.wal.deinit(self.io);
        self.table.deinit(alloc);

        // if (@import("builtin").mode == .Debug)
        //     @memset(std.mem.asBytes(self), 0xAA);
    }
};
