const std = @import("std");
const zbench = @import("zbench");
const SkipList = @import("skiplist").SkipList;

const ListSize = 1_000_000;
const BackgroundThreadCount = 7;
const PinnedThreadCount = BackgroundThreadCount + 1;
var List: SkipList(usize) = undefined;
var Allocator = std.heap.DebugAllocator(.{}){};
var Arena = std.heap.ArenaAllocator.init(Allocator.allocator());
var Thread: std.Thread = undefined;
var BackgroundThreads: [BackgroundThreadCount]std.Thread = undefined;
var OriginalCpuSet: std.os.linux.cpu_set_t = undefined;
var Stop = std.atomic.Value(bool).init(false);
var Prng = std.Random.DefaultPrng.init(0x1234_5678_9abc_def0);

fn push_linear(allocator: std.mem.Allocator) void {
    _ = allocator;

    for (0..ListSize) |i| {
        List.insert(i) catch {
            @panic("Failed to push to the list");
        };
    }
}

fn push_random(allocator: std.mem.Allocator) void {
    _ = allocator;

    for (0..ListSize) |_| {
        List.insert(Prng.random().int(usize)) catch {
            // Random numbers could be equal
        };
    }
}

fn allowed_cpus() [PinnedThreadCount]usize {
    const cpu_set = std.posix.sched_getaffinity(0) catch {
        @panic("Failed to get CPU affinity");
    };

    var cpus: [PinnedThreadCount]usize = undefined;
    var cpu_count: usize = 0;
    for (cpu_set, 0..) |word, word_idx| {
        for (0..@bitSizeOf(usize)) |bit_idx| {
            if (word & (@as(usize, 1) << @intCast(bit_idx)) != 0) {
                cpus[cpu_count] = word_idx * @bitSizeOf(usize) + bit_idx;
                cpu_count += 1;
                if (cpu_count == cpus.len) {
                    return cpus;
                }
            }
        }
    }

    @panic("Not enough CPUs in affinity set");
}

fn bind_to_cpu(cpu: usize) void {
    var cpu_set: std.os.linux.cpu_set_t = @splat(0);

    cpu_set[cpu / @bitSizeOf(usize)] = @as(usize, 1) << @intCast(cpu % @bitSizeOf(usize));
    std.os.linux.sched_setaffinity(0, &cpu_set) catch {
        @panic("Failed to set CPU affinity");
    };
}

fn restore_cpu_affinity() void {
    std.os.linux.sched_setaffinity(0, &OriginalCpuSet) catch {
        @panic("Failed to restore CPU affinity");
    };
}

fn push_random_on_cpu(cpu: usize, seed: u64) void {
    bind_to_cpu(cpu);

    var prng = std.Random.DefaultPrng.init(seed);
    while (Stop.load(.monotonic) == false) {
        List.insert(prng.random().int(usize)) catch {
            // Random numbers could be equal
        };
    }
}

fn setup_pinned_background_threads() void {
    allocate_list();
    OriginalCpuSet = std.posix.sched_getaffinity(0) catch {
        @panic("Failed to get CPU affinity");
    };
    const cpus = allowed_cpus();
    bind_to_cpu(cpus[0]);
    Stop.store(false, .monotonic);

    for (&BackgroundThreads, 0..) |*thread, i| {
        thread.* = std.Thread.spawn(.{}, push_random_on_cpu, .{
            cpus[i + 1],
            0x1234_5678_9abc_def0 +% i,
        }) catch {
            @panic("Failed to start a thread");
        };
    }
}

fn teardown_pinned_background_threads() void {
    Stop.store(true, .monotonic);
    for (&BackgroundThreads) |thread| {
        thread.join();
    }
    restore_cpu_affinity();
    free_list();
}

fn allocate_list() void {
    List = SkipList(usize).new(
        Allocator.allocator(),
        std.Io.Threaded.global_single_threaded.io(),
    ) catch {
        @panic("Failed to allocate list");
    };
}

fn free_list() void {
    List.deinit();
    List = undefined;
}

fn push_thread() void {
    while (Stop.load(.monotonic) == false) {
        List.insert(Prng.random().int(usize)) catch {
            // Random numbers could be equal
        };
    }
}

fn setup_thread() void {
    allocate_list();
    Stop.store(false, .monotonic);

    Thread = std.Thread.spawn(.{}, push_thread, .{}) catch {
        @panic("Failed to start a thread");
    };
}

fn teardown_thread() void {
    Stop.store(true, .monotonic);
    Thread.join();
    free_list();
}

fn create_name(prefix: []const u8) []const u8 {
    return std.fmt.allocPrint(Allocator.allocator(), "{s}. Count {d} Value size {}", .{
        prefix,
        ListSize,
        @sizeOf(usize),
    }) catch {
        @panic("Failed to allocate name");
    };
}

pub fn add_benches(bench: *zbench.Benchmark) !void {
    try bench.add(create_name("Push linear ST"), push_linear, .{
        .hooks = .{
            .before_each = allocate_list,
            .after_each = free_list,
        },
        .iterations = 5,
    });

    try bench.add(create_name("Push random ST"), push_random, .{
        .hooks = .{
            .before_each = allocate_list,
            .after_each = free_list,
        },
        .iterations = 5,
    });

    try bench.add(create_name("Push random ST with 7 pinned writers"), push_random, .{
        .hooks = .{
            .before_each = setup_pinned_background_threads,
            .after_each = teardown_pinned_background_threads,
        },
        .iterations = 5,
    });
}
