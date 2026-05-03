const std = @import("std");

fn is_primitive_type(Key: type) bool {
    return switch (@typeInfo(Key)) {
        .int, .float, .bool => true,
        else => false,
    };
}

fn compare_same(Key: type, lhs: Key, rhs: Key) std.math.Order {
    return switch (@typeInfo(Key)) {
        .int, .float, .bool => {
            return std.math.order(lhs, rhs);
        },
        .pointer => |ptr| {
            if (ptr.size == .slice and is_primitive_type(ptr.child)) {
                return std.mem.order(ptr.child, lhs, rhs);
            } else {
                @compileError("todo " ++ @typeName(ptr.child));
            }
        },
        .@"struct" => |_| {
            if (@hasDecl(Key, "cmp")) {
                return lhs.cmp(&rhs);
            } else {
                @compileError("Custom structs must implement 'cmp' method" ++ @typeName(Key));
            }
        },
        else => @compileError("Unsupported type for comparison: " ++ @typeName(Key)),
    };
}

fn transform_struct_name(comptime input: []const u8) [input.len]u8 {
    comptime {
        var result: [input.len]u8 = undefined;

        for (input, 0..) |c, i| {
            result[i] = if (c == '.') '_' else c;
        }

        return result;
    }
}

pub fn compare_keys(Key: type, Other: type, lhs: Key, rhs: Other) std.math.Order {
    if (Key == Other) {
        return compare_same(Key, lhs, rhs);
    } else {
        return switch (@typeInfo(Key)) {
            .@"struct" => |_| {
                const suffix = blk: {
                    switch (@typeInfo(Other)) {
                        .pointer => |ptr| {
                            if (ptr.size == .slice) {
                                break :blk "slice_" ++ @typeName(ptr.child);
                            } else {
                                @compileError("todo");
                            }
                        },
                        else => break :blk @typeName(Other),
                    }
                };

                if (@hasDecl(Key, "cmp_with_" ++ &transform_struct_name(suffix))) {
                    return @field(Key, "cmp_with_" ++ &transform_struct_name(suffix))(&lhs, &rhs);
                } else {
                    @compileError("Custom structs must implement 'cmp_with_" ++ &transform_struct_name(suffix) ++ "' method. Type name is " ++ @typeName(Key));
                }
            },
            else => @compileError("Unsupported type for comparison: " ++ @typeName(Key)),
        };
    }
}
