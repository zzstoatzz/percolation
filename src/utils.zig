const std = @import("std");
const root = @import("root.zig");

pub const Config = struct {
    size: usize,
    p: f64,
    seed: u64,
    out_dir: []const u8,
    top_n: usize = 3,
};

pub const State = struct {
    roots: []usize,
    sizes: []usize,
    top_sizes: []usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, size: usize, top_n: usize) !State {
        const roots = try allocator.alloc(usize, size * size);
        const sizes = try allocator.alloc(usize, size * size);
        const top_sizes = try allocator.alloc(usize, top_n);
        @memset(top_sizes, 0);
        return .{ .roots = roots, .sizes = sizes, .top_sizes = top_sizes, .allocator = allocator };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.roots);
        self.allocator.free(self.sizes);
        self.allocator.free(self.top_sizes);
    }
};

pub fn captureState(states: *std.ArrayList(State), perc: *root.Percolation, size: usize, top_n: usize) !void {
    var state = try State.init(states.allocator, size, top_n);

    // Single pass: capture roots, sizes, and track top N clusters
    var i: usize = 0;
    while (i < size * size) : (i += 1) {
        const root_i = perc.uf.find(i);
        state.roots[i] = root_i;
        state.sizes[i] = perc.uf.size[root_i];

        // If this is a root node with size > 1, check if it's in top N
        if (root_i == i and state.sizes[i] > 1) {
            // Find insertion point in top_sizes (which maintains descending order)
            const size_i = state.sizes[i];
            var j: usize = 0;
            while (j < top_n and size_i <= state.top_sizes[j]) : (j += 1) {}

            if (j < top_n) {
                // Shift smaller sizes down
                var k: usize = top_n - 1;
                while (k > j) : (k -= 1) {
                    state.top_sizes[k] = state.top_sizes[k - 1];
                }
                state.top_sizes[j] = size_i;
            }
        }
    }

    try states.append(state);
}

pub fn ensureOutputDir(dir: []const u8) !void {
    try std.fs.cwd().makePath(dir);
}

pub fn writeMetadata(allocator: std.mem.Allocator, cfg: Config, total_bonds: usize) !void {
    var json_str = std.ArrayList(u8).init(allocator);
    defer json_str.deinit();

    try std.json.stringify(.{
        .size = cfg.size,
        .p = cfg.p,
        .seed = cfg.seed,
        .total_bonds = total_bonds,
        .total_states = total_bonds + 1,
    }, .{}, json_str.writer());

    const meta_path = try std.fs.path.join(allocator, &[_][]const u8{ cfg.out_dir, "percolation.json" });
    defer allocator.free(meta_path);

    const meta_file = try std.fs.cwd().createFile(meta_path, .{});
    defer meta_file.close();
    try meta_file.writeAll(json_str.items);
}

pub fn writeBondsAndStates(
    allocator: std.mem.Allocator,
    bonds: []const root.Bond,
    states: []const State,
    cfg: Config,
) !void {
    const bonds_path = try std.fs.path.join(allocator, &[_][]const u8{ cfg.out_dir, "bonds.bin" });
    defer allocator.free(bonds_path);

    const roots_path = try std.fs.path.join(allocator, &[_][]const u8{ cfg.out_dir, "roots.bin" });
    defer allocator.free(roots_path);

    const sizes_path = try std.fs.path.join(allocator, &[_][]const u8{ cfg.out_dir, "sizes.bin" });
    defer allocator.free(sizes_path);

    const top_sizes_path = try std.fs.path.join(allocator, &[_][]const u8{ cfg.out_dir, "top_sizes.bin" });
    defer allocator.free(top_sizes_path);

    // Write bonds
    const bonds_file = try std.fs.cwd().createFile(bonds_path, .{});
    defer bonds_file.close();
    var buffered_bonds = std.io.bufferedWriter(bonds_file.writer());
    const bonds_writer = buffered_bonds.writer();

    for (bonds, 0..) |bond, i| {
        const is_horizontal = bond.site2 == bond.site1 + 1;
        const row = bond.site1 / cfg.size;
        const col = bond.site1 % cfg.size;

        try bonds_writer.writeByte(if (is_horizontal) 1 else 0);
        try bonds_writer.writeInt(u32, @intCast(row), .little);
        try bonds_writer.writeInt(u32, @intCast(col), .little);

        if ((i + 1) % (bonds.len / 10) == 0) {
            const percent = (i + 1) * 100 / bonds.len;
            std.debug.print("Writing bonds: {d}% ({d}/{d})\n", .{ percent, i + 1, bonds.len });
        }
    }
    try buffered_bonds.flush();

    // Write roots and sizes
    const roots_file = try std.fs.cwd().createFile(roots_path, .{});
    defer roots_file.close();
    var buffered_roots = std.io.bufferedWriter(roots_file.writer());
    const roots_writer = buffered_roots.writer();

    const sizes_file = try std.fs.cwd().createFile(sizes_path, .{});
    defer sizes_file.close();
    var buffered_sizes = std.io.bufferedWriter(sizes_file.writer());
    const sizes_writer = buffered_sizes.writer();

    const top_sizes_file = try std.fs.cwd().createFile(top_sizes_path, .{});
    defer top_sizes_file.close();
    var buffered_top_sizes = std.io.bufferedWriter(top_sizes_file.writer());
    const top_sizes_writer = buffered_top_sizes.writer();

    // Pre-allocate buffers
    const buffer_size = cfg.size * cfg.size * @sizeOf(u32);
    var roots_buffer = try allocator.alloc(u8, buffer_size);
    defer allocator.free(roots_buffer);
    var sizes_buffer = try allocator.alloc(u8, buffer_size);
    defer allocator.free(sizes_buffer);
    var top_sizes_buffer = try allocator.alloc(u8, cfg.top_n * @sizeOf(u32));
    defer allocator.free(top_sizes_buffer);

    std.debug.print("Writing {d} states to file...\n", .{states.len});
    for (states, 0..) |state, i| {
        // Convert roots and sizes to bytes
        for (state.roots, 0..) |root_val, j| {
            const root_bytes = std.mem.asBytes(&@as(u32, @intCast(root_val)));
            @memcpy(roots_buffer[j * 4 .. (j + 1) * 4], root_bytes);
        }
        for (state.sizes, 0..) |size_val, j| {
            const size_bytes = std.mem.asBytes(&@as(u32, @intCast(size_val)));
            @memcpy(sizes_buffer[j * 4 .. (j + 1) * 4], size_bytes);
        }
        for (state.top_sizes, 0..) |size_val, j| {
            const size_bytes = std.mem.asBytes(&@as(u32, @intCast(size_val)));
            @memcpy(top_sizes_buffer[j * 4 .. (j + 1) * 4], size_bytes);
        }

        try roots_writer.writeAll(roots_buffer);
        try sizes_writer.writeAll(sizes_buffer);
        try top_sizes_writer.writeAll(top_sizes_buffer);

        if ((i + 1) % (states.len / 10) == 0) {
            const percent = (i + 1) * 100 / states.len;
            std.debug.print("Writing states: {d}% ({d}/{d})\n", .{ percent, i + 1, states.len });
        }
    }
    try buffered_roots.flush();
    try buffered_sizes.flush();
    try buffered_top_sizes.flush();
}

pub fn generateBonds(perc: *root.Percolation, cfg: Config, allocator: std.mem.Allocator) !std.ArrayList(root.Bond) {
    var bonds = std.ArrayList(root.Bond).init(allocator);
    try perc.generateBonds(cfg.p, &bonds);

    // Shuffle bonds
    var rng = std.rand.DefaultPrng.init(cfg.seed);
    const random = rng.random();
    var i: usize = bonds.items.len;
    while (i > 1) {
        i -= 1;
        const j = random.uintLessThan(usize, i + 1);
        const temp = bonds.items[i];
        bonds.items[i] = bonds.items[j];
        bonds.items[j] = temp;
    }

    return bonds;
}

pub fn printUsage() void {
    const usage =
        \\Usage: percolation [options]
        \\
        \\Options:
        \\  -s, --size <N>     Grid size (default: 16)
        \\  -p <float>         Bond probability [0.0-1.0] (default: 0.5)
        \\  --seed <N>         Random seed (default: timestamp)
        \\  --out <dir>        Output directory (default: ".")
        \\  --top-n <N>        Number of top cluster sizes to track (default: 3)
        \\  -h, --help         Print this help message
        \\
        \\Environment Variables (fallback):
        \\  GRID_SIZE          Same as --size
        \\  P                  Same as -p
        \\  SEED              Same as --seed
        \\  TOP_N             Same as --top-n
        \\
    ;
    std.debug.print("{s}", .{usage});
}

pub fn parseArgs(allocator: std.mem.Allocator) !Config {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    // Skip executable name
    _ = args.skip();

    var config = Config{
        .size = 16,
        .p = 0.5,
        .seed = @intCast(std.time.timestamp()),
        .out_dir = ".",
        .top_n = 3,
    };

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    // First check environment variables as defaults
    if (env_map.get("GRID_SIZE")) |size_str| {
        config.size = try std.fmt.parseInt(usize, size_str, 10);
    }
    if (env_map.get("P")) |p_str| {
        config.p = try std.fmt.parseFloat(f64, p_str);
    }
    if (env_map.get("SEED")) |seed_str| {
        config.seed = try std.fmt.parseInt(u64, seed_str, 10);
    }
    if (env_map.get("TOP_N")) |top_n_str| {
        config.top_n = try std.fmt.parseInt(usize, top_n_str, 10);
    }

    // Then parse CLI args which override environment variables
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printUsage();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--size")) {
            const size_str = args.next() orelse {
                std.debug.print("Error: Missing value for size argument\n", .{});
                printUsage();
                return error.InvalidArgument;
            };
            config.size = try std.fmt.parseInt(usize, size_str, 10);
        } else if (std.mem.eql(u8, arg, "-p")) {
            const p_str = args.next() orelse {
                std.debug.print("Error: Missing value for p argument\n", .{});
                printUsage();
                return error.InvalidArgument;
            };
            config.p = try std.fmt.parseFloat(f64, p_str);
        } else if (std.mem.eql(u8, arg, "--seed")) {
            const seed_str = args.next() orelse {
                std.debug.print("Error: Missing value for seed argument\n", .{});
                printUsage();
                return error.InvalidArgument;
            };
            config.seed = try std.fmt.parseInt(u64, seed_str, 10);
        } else if (std.mem.eql(u8, arg, "--out")) {
            config.out_dir = args.next() orelse {
                std.debug.print("Error: Missing value for out argument\n", .{});
                printUsage();
                return error.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "--top-n")) {
            const top_n_str = args.next() orelse {
                std.debug.print("Error: Missing value for top-n argument\n", .{});
                printUsage();
                return error.InvalidArgument;
            };
            config.top_n = try std.fmt.parseInt(usize, top_n_str, 10);
        }
    }

    // Validate configuration
    if (config.size < 2) {
        std.debug.print("Error: Grid size must be at least 2\n", .{});
        return error.InvalidArgument;
    }
    if (config.p < 0.0 or config.p > 1.0) {
        std.debug.print("Error: p must be between 0.0 and 1.0\n", .{});
        return error.InvalidArgument;
    }
    if (config.top_n < 1) {
        std.debug.print("Error: top-n must be at least 1\n", .{});
        return error.InvalidArgument;
    }

    return config;
}

pub fn getTimeUs() i64 {
    return std.time.microTimestamp();
}

pub fn logTiming(start: i64, comptime msg: []const u8) void {
    const elapsed = getTimeUs() - start;
    std.debug.print("{s}: {d}ms\n", .{ msg, @as(f64, @floatFromInt(elapsed)) / 1000.0 });
}
