const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn random_size(rng: std.Random, start: usize, end: usize) usize {
    const random = rng.int(usize);
    const range_len = end - start;

    return start + (random % range_len);
}

pub fn generate_random_text(rng: std.Random, start: usize, end: usize, alloc: Allocator) !std.ArrayList(u8) {
    const size = random_size(rng, start, end);
    var res = try std.ArrayList(u8).initCapacity(alloc, size);

    for (0..size) |_| {
        // Take lower-case ascii chars: a-z. The range is 97 - 122.
        const range_len = 122 - 97 + 1;
        try res.append(alloc, rng.int(u8) % range_len + 97);
    }

    return res;
}

const Step = union(enum) {
    Insert: struct {
        key: std.ArrayList(u8),
        value: std.ArrayList(u8),
    },
    Remove: struct {
        key: std.ArrayList(u8),
    },

    fn dump(self: *const Step) void {
        switch (self.*) {
            .Insert => |s| std.debug.print("Insert key: {s} value: {s}\n", .{ s.key.items, s.value.items }),
            .Remove => |s| std.debug.print("Remove {s}\n", .{s.key.items}),
        }
    }
};

fn random_step(rng: std.Random, alloc: Allocator, values: *InsertedValues) !Step {
    const enum_info = @typeInfo(Step).@"union";
    const count = enum_info.fields.len;
    const step = rng.int(u8) % count;
    const remove_exisiting = rng.int(u8) % 2;

    const random_key = try generate_random_text(rng, 1, 40, alloc);
    const value = try generate_random_text(rng, 1, 40, alloc);

    try values.append(alloc, .{ .key = random_key.items, .value = value.items });

    return switch (step) {
        0 => Step{
            .Insert = .{
                .key = random_key,
                .value = value,
            },
        },
        1 => Step{
            .Remove = .{
                .key = blk: {
                    if (remove_exisiting == 1) {
                        const idx = rng.int(usize) % values.items.len;
                        var new_arr = try std.ArrayList(u8).initCapacity(alloc, 0);

                        try new_arr.appendSlice(alloc, values.items[idx].key);
                        break :blk new_arr;
                    } else {
                        break :blk random_key;
                    }
                },
            },
        },
        else => @panic(""),
    };
}

const InsertedValues = std.ArrayList(struct { key: []const u8, value: []const u8 });

pub fn test_hash_table_equavalance(c: anytype, debug: bool, steps: usize) !void {
    var container = c;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const seed = std.time.timestamp();
    var prng = std.Random.DefaultPrng.init(@bitCast(seed));
    const rng = prng.random();

    var table = std.StringArrayHashMap([]const u8).init(allocator);
    var inserted_pairs = try InsertedValues.initCapacity(allocator, 0);
    var seq: usize = 0;

    if (debug) {
        std.debug.print("Seed = {}\n", .{seed});
    }

    for (0..steps) |_| {
        const step = try random_step(rng, allocator, &inserted_pairs);

        if (debug) {
            step.dump();
        }

        switch (step) {
            .Insert => |i| {
                const fn_type = switch (@typeInfo(@TypeOf(container))) {
                    .pointer => @typeInfo(@TypeOf(@TypeOf(container.*).put)),
                    else => @typeInfo(@TypeOf(@TypeOf(container).put)),
                };

                switch (fn_type) {
                    .@"fn" => |f| {
                        switch (f.params.len) {
                            3 => try container.put(i.key.items, i.value.items),
                            4 => {
                                switch (@typeInfo(f.params[3].type.?)) {
                                    .int => {
                                        try container.put(i.key.items, i.value.items, seq);
                                        seq += 1;
                                    },
                                    else => try container.put(i.key.items, i.value.items, allocator),
                                }
                            },
                            else => @compileError("ohhh2"),
                        }
                    },
                    else => @compileError("ohh"),
                }

                try table.put(i.key.items, i.value.items);
            },
            .Remove => |rm| {
                const fn_type = switch (@typeInfo(@TypeOf(container))) {
                    .pointer => @typeInfo(@TypeOf(@TypeOf(container.*).remove)),
                    else => @typeInfo(@TypeOf(@TypeOf(container).remove)),
                };

                switch (fn_type) {
                    .@"fn" => |f| {
                        switch (f.params.len) {
                            2 => try container.remove(rm.key.items),
                            3 => {
                                switch (@typeInfo(f.params[2].type.?)) {
                                    .int => {
                                        try container.remove(rm.key.items, seq);
                                        seq += 1;
                                    },
                                    else => try container.remove(rm.key.items, allocator),
                                }
                            },
                            else => @compileError("ohhh2"),
                        }
                    },
                    else => @compileError("ohh"),
                }

                _ = table.swapRemove(rm.key.items);
            },
        }

        var iter = table.iterator();
        while (iter.next()) |next| {
            const fn_type = switch (@typeInfo(@TypeOf(container))) {
                .pointer => @typeInfo(@TypeOf(@TypeOf(container.*).get)),
                else => @typeInfo(@TypeOf(@TypeOf(container).get)),
            };

            switch (fn_type) {
                .@"fn" => |f| {
                    const value = switch (f.params.len) {
                        3 => container.get(next.key_ptr.*, allocator),
                        4 => container.get(next.key_ptr.*, seq, allocator),
                        else => @compileError("ohhh2"),
                    };

                    const value_unwrapped = switch (@typeInfo(@TypeOf(value))) {
                        .optional => value.?,
                        .@"union" => @field(@TypeOf(value), "as_key")(&value).?,
                        .error_union => |err| switch (@typeInfo(err.payload)) {
                            .optional => (value catch |e| return e).?,
                            .@"union" => switch (value catch |e| return e) {
                                .Found => |v| v,
                                else => @panic("yo bro"),
                            },
                            else => @compileError("todo"),
                        },
                        else => @compileError("ohh"),
                    };

                    try std.testing.expectEqualSlices(u8, value_unwrapped, next.value_ptr.*);
                },
                else => @compileError("ohh"),
            }
        }
    }
}
