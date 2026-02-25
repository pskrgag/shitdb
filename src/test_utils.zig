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
