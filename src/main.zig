const std = @import("std");
const root = @import("root.zig");
const json = std.json;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Read environment variables
    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    // Parse GRID_SIZE (default: 10)
    const size = blk: {
        if (env_map.get("GRID_SIZE")) |size_str| {
            break :blk try std.fmt.parseInt(usize, size_str, 10);
        }
        break :blk 10;
    };

    // Parse P (default: 0.5)
    const p = blk: {
        if (env_map.get("P")) |p_str| {
            break :blk try std.fmt.parseFloat(f64, p_str);
        }
        break :blk 0.5;
    };

    // Parse SEED (default: timestamp)
    const seed = blk: {
        if (env_map.get("SEED")) |seed_str| {
            break :blk try std.fmt.parseInt(u64, seed_str, 10);
        }
        break :blk @as(u64, @intCast(std.time.timestamp()));
    };

    // Initialize percolation
    var perc = try root.Percolation.init(allocator, size, seed);
    defer perc.deinit();

    // Generate bonds
    var bonds = std.ArrayList(root.Bond).init(allocator);
    defer bonds.deinit();
    try perc.generateBonds(p, &bonds);

    // Shuffle bonds
    var rng = std.rand.DefaultPrng.init(seed);
    const random = rng.random();
    var i: usize = bonds.items.len;
    while (i > 1) {
        i -= 1;
        const j = random.uintLessThan(usize, i + 1);
        const temp = bonds.items[i];
        bonds.items[i] = bonds.items[j];
        bonds.items[j] = temp;
    }

    // Create metadata JSON
    var json_str = std.ArrayList(u8).init(allocator);
    defer json_str.deinit();

    try std.json.stringify(.{
        .size = size,
        .p = p,
        .seed = seed,
        .total_bonds = bonds.items.len,
    }, .{}, json_str.writer());

    // Write metadata
    const meta_file = try std.fs.cwd().createFile("percolation.json", .{});
    defer meta_file.close();
    try meta_file.writeAll(json_str.items);

    // Write step-by-step evolution
    const steps_file = try std.fs.cwd().createFile("steps.bin", .{});
    defer steps_file.close();
    const writer = steps_file.writer();

    // Write initial state
    try writeState(writer, &perc, size);

    // Write bonds and states
    for (bonds.items) |bond| {
        const is_horizontal = bond.site2 == bond.site1 + 1;
        const row = bond.site1 / size;
        const col = bond.site1 % size;

        try writer.writeByte(if (is_horizontal) 1 else 0);
        try writer.writeInt(u32, @intCast(row), .little);
        try writer.writeInt(u32, @intCast(col), .little);

        perc.uf.merge(bond.site1, bond.site2);
        try writeState(writer, &perc, size);
    }
}

fn writeState(writer: anytype, perc: *root.Percolation, size: usize) !void {
    // For each site, write:
    // - its root (u32)
    // - cluster size (u32)
    var i: usize = 0;
    while (i < size * size) : (i += 1) {
        const _root = perc.uf.find(i);
        try writer.writeInt(u32, @intCast(_root), .little);
        try writer.writeInt(u32, @intCast(perc.uf.size[_root]), .little);
    }
}
