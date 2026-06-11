const std = @import("std");

// TODO: initialize seed during first access maybe
threadlocal var Prng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0x1234_5678_9abc_def0);

pub fn prng() *std.Random.DefaultPrng {
    return &Prng;
}
