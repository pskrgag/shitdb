const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

pub const ThreadSafeArena = struct {
    ptr: [*]u8,
    size: usize,
    offset: std.atomic.Value([*]u8),

    const Self = @This();

    pub fn new(child_alloc: Allocator, sz: usize) !Self {
        const p = try child_alloc.alloc(u8, sz);

        return .{ .ptr = p.ptr, .size = sz, .offset = std.atomic.Value([*]u8).init(p.ptr) };
    }

    fn alloc(ctx: *anyopaque, n: usize, alignment: Alignment, ra: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const end = self.ptr + self.size;

        while (true) {
            const current_ptr = self.offset.load(.monotonic);
            const current_ptr_aligned: [*]u8 = @ptrFromInt(alignment.forward(@intFromPtr(current_ptr)));

            const new_offset = current_ptr + n;
            if (@intFromPtr(new_offset) > @intFromPtr(end))
                return null;

            if (self.offset.cmpxchgWeak(current_ptr_aligned, new_offset, .monotonic, .monotonic) == null)
                return current_ptr_aligned;
        }

        _ = ra;
        return null;
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
};

// TODO: more tests
test "Allocate" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var a = try ThreadSafeArena.new(allocator, 100);
    const alloc = a.allocator();

    for (0..100) |_| {
        _ = try alloc.alloc(u8, 1);
    }

    for (0..10) |_| {
        try std.testing.expectError(std.mem.Allocator.Error.OutOfMemory, alloc.alloc(u8, 1));
    }
}
