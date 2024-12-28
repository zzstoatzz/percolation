const std = @import("std");

pub const Bond = struct { site1: usize, site2: usize };

pub const UnionFind = struct {
    parent: []usize,
    size: []usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, n: usize) !UnionFind {
        const parent = try allocator.alloc(usize, n);
        const size = try allocator.alloc(usize, n);

        for (0..n) |i| {
            parent[i] = i;
            size[i] = 1;
        }

        return .{ .parent = parent, .size = size, .allocator = allocator };
    }

    pub fn deinit(self: *UnionFind) void {
        self.allocator.free(self.parent);
        self.allocator.free(self.size);
    }

    pub fn find(self: *UnionFind, x: usize) usize {
        var current = x;
        while (current != self.parent[current]) {
            self.parent[current] = self.parent[self.parent[current]];
            current = self.parent[current];
        }
        return current;
    }

    pub fn merge(self: *UnionFind, a: usize, b: usize) void {
        var root_a = self.find(a);
        var root_b = self.find(b);
        if (root_a == root_b) return;

        if (self.size[root_a] < self.size[root_b]) {
            const temp = root_a;
            root_a = root_b;
            root_b = temp;
        }
        self.parent[root_b] = root_a;
        self.size[root_a] += self.size[root_b];
    }
};

pub const Percolation = struct {
    uf: UnionFind,
    size: usize,
    rng: std.rand.DefaultPrng,

    pub fn init(allocator: std.mem.Allocator, size: usize, seed: u64) !Percolation {
        return .{
            .uf = try UnionFind.init(allocator, size * size),
            .size = size,
            .rng = std.rand.DefaultPrng.init(seed),
        };
    }

    pub fn deinit(self: *Percolation) void {
        self.uf.deinit();
    }

    pub fn coordToIndex(self: Percolation, row: usize, col: usize) usize {
        return row * self.size + col;
    }

    pub fn generateBonds(self: *Percolation, p: f64, bonds: *std.ArrayList(Bond)) !void {
        var row: usize = 0;
        while (row < self.size) : (row += 1) {
            var col: usize = 0;
            while (col < self.size) : (col += 1) {
                const idx = self.coordToIndex(row, col);

                if (col < self.size - 1 and self.rng.random().float(f64) < p) {
                    try bonds.append(.{ .site1 = idx, .site2 = idx + 1 });
                }
                if (row < self.size - 1 and self.rng.random().float(f64) < p) {
                    try bonds.append(.{ .site1 = idx, .site2 = idx + self.size });
                }
            }
        }
    }
};

test "union find" {
    var uf = try UnionFind.init(std.testing.allocator, 10);
    defer uf.deinit();

    try std.testing.expectEqual(uf.find(5), 5);

    uf.merge(4, 5);
    uf.merge(5, 6);

    try std.testing.expectEqual(uf.find(4), uf.find(6));
    try std.testing.expectEqual(uf.size[uf.find(4)], 3);
}

test "percolation" {
    var perc = try Percolation.init(std.testing.allocator, 5, 42);
    defer perc.deinit();

    var bonds = std.ArrayList(Bond).init(std.testing.allocator);
    defer bonds.deinit();

    try perc.generateBonds(0.5, &bonds);

    // Test some bonds
    for (bonds.items) |bond| {
        perc.uf.merge(bond.site1, bond.site2);
    }

    try std.testing.expect(bonds.items.len > 0);
}
