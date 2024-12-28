# simulate bond percolation

a union-find / path compression percolation simulation in zig with `matplotlib` visualization

> [!NOTE]
> inspired by the work of [Dr. Robert M. Ziff](https://scholar.google.com/citations?hl=en&user=CUqzFcEAAAAJ)

## requirements
- [zig](https://ziglang.org/learn/getting-started/#managers)
- [uv](https://docs.astral.sh/uv/getting-started/installation/)

```
git clone https://github.com/zzstoatzz/percolation
cd percolation
```

## Usage

The simplest way to run the simulation is using the provided `run` script:

```bash
# Run with default parameters
chmod +x run
./run

# Run with custom parameters
GRID_SIZE=20 P=0.6 SEED=42 ./run
```

You can also run the steps manually:

```bash
# Build
zig build

# Run simulation with custom parameters
GRID_SIZE=20 P=0.6 SEED=42 ./zig-out/bin/percolation

# Visualize
uv run read.py
```

## Configuration

The simulation can be controlled via environment variables:

```bash
GRID_SIZE=20  # Grid size (default: 10)
P=0.6         # Bond probability (default: 0.5) 
SEED=42       # Random seed (default: current timestamp)
```