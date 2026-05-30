const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const Mutex = std.Io.Mutex;

const BlockSize: usize = 1 << 20;

const BlockAllocator = struct {
    ptr: []u8,
    offset: std.atomic.Value([*]u8),

    const Self = @This();

    fn init(child_alloc: Allocator, size: usize) !*BlockAllocator {
        const p = try child_alloc.alloc(u8, size);
        const self = try child_alloc.create(Self);

        self.ptr = p;
        self.offset = std.atomic.Value([*]u8).init(p.ptr);

        return self;
    }

    fn alloc(self: *BlockAllocator, n: usize, alignment: Alignment) ?[*]u8 {
        const end = self.ptr.ptr + self.ptr.len;

        while (true) {
            const current_ptr = self.offset.load(.monotonic);
            const current_ptr_aligned: [*]u8 = @ptrFromInt(alignment.forward(@intFromPtr(current_ptr)));

            const new_offset = current_ptr_aligned + n;
            if (@intFromPtr(new_offset) > @intFromPtr(end))
                return null;

            if (self.offset.cmpxchgWeak(
                current_ptr,
                new_offset,
                .monotonic,
                .monotonic,
            ) == null)
                return current_ptr_aligned;
        }

        return null;
    }

    fn deinit(self: *BlockAllocator, child_alloc: Allocator) void {
        child_alloc.free(self.ptr);
        child_alloc.destroy(self);
    }
};

pub const ThreadSafeArenaBounded = struct {
    current_block: *BlockAllocator,

    const Self = @This();

    pub fn new(child_alloc: Allocator, sz: usize) !Self {
        const block = try BlockAllocator.init(child_alloc, sz);

        return .{ .current_block = block };
    }

    fn alloc(ctx: *anyopaque, n: usize, alignment: Alignment, ra: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));

        _ = ra;
        return self.current_block.alloc(n, alignment);
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        _ = context;
        _ = memory;
        _ = alignment;
        _ = new_len;
        _ = return_address;
        return null;
    }

    fn free(ctx: *anyopaque, buf: []u8, alignment: Alignment, ret_addr: usize) void {
        _ = ctx;
        _ = buf;
        _ = alignment;
        _ = ret_addr;
    }

    fn resize(ctx: *anyopaque, buf: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        _ = ctx;
        _ = buf;
        _ = alignment;
        _ = new_len;
        _ = ret_addr;
        return false;
    }

    pub fn allocator(self: *Self) Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = Self.alloc,
            .free = Self.free,
            .resize = Self.resize,
            .remap = Self.remap,
        } };
    }

    pub fn deinit(self: *Self, child_alloc: Allocator) void {
        self.current_block.deinit(child_alloc);
    }
};

pub const ThreadSafeArena = struct {
    full_blocks: std.ArrayList(*BlockAllocator),
    current_block: std.atomic.Value(*BlockAllocator),
    child_alloc: Allocator,
    lock: std.Io.Mutex,
    io: std.Io,

    const Self = @This();

    pub fn new(child_alloc: Allocator, io: std.Io) !Self {
        const first_block = try BlockAllocator.init(child_alloc, BlockSize);

        return .{
            .full_blocks = try std.ArrayList(*BlockAllocator).initCapacity(child_alloc, 0),
            .current_block = std.atomic.Value(*BlockAllocator).init(first_block),
            .child_alloc = child_alloc,
            .lock = std.Io.Mutex.init,
            .io = io,
        };
    }

    fn alloc(ctx: *anyopaque, n: usize, alignment: Alignment, ra: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const current = self.current_block.load(.monotonic);

        const res = current.alloc(n, alignment);
        if (res == null) {
            self.lock.lockUncancelable(self.io);
            errdefer self.lock.unlock(self.io);

            if (self.current_block.load(.monotonic) == current) {
                const new_block = BlockAllocator.init(self.child_alloc, BlockSize) catch {
                    return null;
                };
                const old = self.current_block.swap(new_block, .release);

                std.debug.assert(old == current);
                self.full_blocks.append(self.child_alloc, old) catch {
                    return null;
                };
            }

            self.lock.unlock(self.io);
            return Self.alloc(ctx, n, alignment, ra);
        }

        return res;
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        _ = context;
        _ = memory;
        _ = alignment;
        _ = new_len;
        _ = return_address;
        return null;
    }

    fn free(ctx: *anyopaque, buf: []u8, alignment: Alignment, ret_addr: usize) void {
        _ = ctx;
        _ = buf;
        _ = alignment;
        _ = ret_addr;
    }

    fn resize(ctx: *anyopaque, buf: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        _ = ctx;
        _ = buf;
        _ = alignment;
        _ = new_len;
        _ = ret_addr;
        return false;
    }

    pub fn allocator(self: *Self) Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = Self.alloc,
            .free = Self.free,
            .resize = Self.resize,
            .remap = Self.remap,
        } };
    }

    pub fn deinit(self: *Self) void {
        for (self.full_blocks.items) |block| {
            block.deinit(self.child_alloc);
        }

        self.current_block.load(.monotonic).deinit(self.child_alloc);
        self.full_blocks.deinit(self.child_alloc);
    }
};

// TODO: more tests
test "Allocate" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var a = try ThreadSafeArenaBounded.new(allocator, 100);
    defer a.deinit(allocator);
    const alloc = a.allocator();

    for (0..100) |_| {
        _ = try alloc.alloc(u8, 1);
    }

    for (0..10) |_| {
        try std.testing.expectError(std.mem.Allocator.Error.OutOfMemory, alloc.alloc(u8, 1));
    }
}
