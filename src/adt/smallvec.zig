const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn SmallVec(T: type, comptime n: usize) type {
    return struct {
        const State = union(enum) { InPlace: struct {
            buffer: [n]T,
            size: usize,
        }, OnHeap: struct {
            array: std.ArrayList(T),
        } };

        state: State,

        const Self = @This();

        pub fn init() Self {
            return .{ .state = .{ .InPlace = .{
                .size = 0,
                .buffer = [_]T{undefined} ** n,
            } } };
        }

        fn reallocate_stack_to_heap(self: *Self, alloc: Allocator) !void {
            switch (self.state) {
                .InPlace => |stack| {
                    std.debug.assert(stack.size == n);
                    var array = try std.ArrayList(T).initCapacity(alloc, n + 1);
                    array.appendSlice(alloc, &stack.buffer) catch unreachable;

                    self.state = .{ .OnHeap = .{ .array = array } };
                },
                else => unreachable,
            }
        }

        // The order is fucking insane, but it's compatible with ArrayList.
        pub fn append(self: *Self, alloc: Allocator, val: T) !void {
            switch (self.state) {
                .InPlace => |*stack| {
                    if (stack.size < n) {
                        stack.buffer[stack.size] = val;
                        stack.size += 1;
                    } else {
                        try self.reallocate_stack_to_heap(alloc);
                        try self.append(alloc, val);
                    }
                },
                .OnHeap => |*heap| {
                    try heap.array.append(alloc, val);
                },
            }
        }

        pub fn deinit(self: *Self, alloc: Allocator) void {
            switch (self.state) {
                .OnHeap => |*heap| {
                    heap.array.deinit(alloc);
                },
                else => {},
            }
        }

        pub fn items(self: *Self) []T {
            switch (self.state) {
                .InPlace => |*stack| {
                    return stack.buffer[0..stack.size];
                },
                .OnHeap => |*heap| {
                    return heap.array.items;
                },
            }
        }
    };
}
