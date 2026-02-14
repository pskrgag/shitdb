pub fn round_up(value: anytype, alignment: anytype) @TypeOf(value) {
    const mask = alignment - 1;
    return (value + mask) & ~@as(usize, mask);
}

pub fn data_as_u8_const_ptr(ptr: anytype) *const [@sizeOf(@TypeOf(ptr.*))]u8 {
    return @as(*const [@sizeOf(@TypeOf(ptr.*))]u8, @ptrCast(ptr));
}

pub fn data_as_u8_ptr(ptr: anytype) *[@sizeOf(@TypeOf(ptr.*))]u8 {
    return @as(*[@sizeOf(@TypeOf(ptr.*))]u8, @ptrCast(ptr));
}
