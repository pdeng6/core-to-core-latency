# Slot Experiments

Automated experiments for measuring CAS ping-pong latency under controlled
conditions: frequencies pinned, memory bound, and various parameters swept.

## Quick Start

```bash
# Build the benchmark first
cargo build --release

# Run all steps (0-6) with defaults (cores 2,7, ~15 min)
sudo ./scripts/slot-experiments.sh

# Preview the plan without running
DRY_RUN=1 ./scripts/slot-experiments.sh

# Show help
./scripts/slot-experiments.sh --help
```

## Steps

### Step 0: Baseline Matrix

- **What**: Run all core pairs with pause=0, slot=0. Standard latency matrix.
- **Purpose**: Establish the baseline c2c latency under controlled conditions (freq pinned, membind). This is the reference number.
- **How to read**: Compare the Mean latency to the expected/published value. Min latency (often ~20ns) is hyper-thread pairs. Max is the farthest core pair.
- **Time**: ~4 min (40 cores)

### Step 1: Page Coverage

- **What**: Sweep all 1024 slots (16 pages × 64 lines) in one pass.
- **Purpose**: Determine whether one page (64 slots) covers the full latency range, or whether multiple pages are needed.
- **How to read**: Compare per-page mean/stddev/RSD. If all pages have similar statistics (spread of means << within-page range), one page suffices for steps 2-5.
- **Time**: ~3 min

### Step 2: Per-Slot Stability

- **What**: Repeat page 0 multiple times (interleaved).
- **Purpose**: Verify that each slot's latency is reproducible across repeats.
- **How to read**: Within-slot stddev should be small (< 1ns). Repeat-to-repeat means should be flat (no drift). If within-slot stddev is large, the measurement is noisy.
- **Time**: ~1 min

### Step 3: Iteration Sensitivity

- **What**: Same as step 2 but with 4x more iterations per sample.
- **Purpose**: Confirm that measurement length doesn't change the result.
- **How to read**: Compare distribution statistics (mean, stddev, RSD, range) between step 2 and 3. They should match. If step 3 differs, the shorter setting was insufficient.
- **Time**: ~4 min

### Step 4: PAUSE Sweep

- **What**: For a fixed core pair, sweep pause=1..N after each successful CAS (N auto-calibrated from baseline/pause_ns).
- **Purpose**: Find the threshold where adding PAUSE changes the latency distribution. On platforms with contention overhead, latency drops at some N; on platforms without, it only increases.
- **How to read**: If mean stays flat for pause=1..K then drops, there is ~K×pause_ns of contention overhead. If mean increases linearly from pause=1, there is no overhead to remove.
- **Time**: ~8 min

### Step 5: Per-Slot Optimal PAUSE

- **What**: For each of 64 slots, find the pause count (N-3..N) that minimizes latency.
- **Purpose**: Quantify how much contention overhead is removable per cache line. The "auto-pause mean" is the achievable latency with optimal backoff.
- **How to read**: Compare baseline mean vs auto-pause mean. The difference is the removable contention overhead. The bar chart shows whether both distributions are separated (overhead present) or overlapping (no overhead).
- **Time**: ~1 min

### Step 6: Per-Core-Pair Optimal PAUSE

- **What**: For each core pair, find the optimal pause count at slot=0.
- **Purpose**: Same as step 5 but across core pairs instead of slots. Produces a contention-free latency matrix comparable to step 0's baseline matrix.
- **How to read**: Compare step 6 baseline mean vs step 0 mean (should match). Compare auto-pause mean to baseline — the gap is the contention overhead. Per-pair table shows which pairs benefit most.
- **Time**: ~20 min (40 cores)

## Common Usage

```bash
# Baseline matrix on cores 0-39 (equivalent to original benchmark)
sudo STEPS=0 CORES=$(seq -s, 0 39) BIN=./target/release/core-to-core-latency ./scripts/slot-experiments.sh

# Per-core-pair optimal pause on cores 0-39
sudo STEPS=6 CORES=$(seq -s, 0 39) BIN=./target/release/core-to-core-latency ./scripts/slot-experiments.sh

# Per-slot analysis on a specific core pair
sudo STEPS=5 CORES=24,31 BIN=./target/release/core-to-core-latency ./scripts/slot-experiments.sh

# Step 4 with explicit pause values (targeted re-run)
sudo STEPS=4 PAUSE_LIST=5,6,7,8,9 BIN=./target/release/core-to-core-latency ./scripts/slot-experiments.sh

# Run on a remote host (binary pre-deployed)
cd /path/to/deployed && STEPS=6 CORES=$(seq -s, 0 39) BIN=./core-to-core-latency ./slot-experiments.sh
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `STEPS` | `0,1,2,3,4,5,6` | Which steps to run (comma-separated) |
| `CORES` | `2,7` | Core IDs to test |
| `MEMNODE` | `0` | NUMA node for memory binding |
| `OUTDIR` | `/tmp/slot-exp-YYYYMMDD-HHMMSS` | Output directory |
| `BIN` | `./target/release/core-to-core-latency` | Path to benchmark binary |
| `MEASURE_PAUSE` | `../../scripts/measure-pause` | Path to measure-pause binary (step 4) |
| `PAUSE_LIST` | (empty) | Step 4: explicit pause values to sweep |
| `BASE_ITER` | `5000` | Iterations per sample (steps 0,1,2,4,5,6) |
| `BASE_SAMPLES` | `300` | Samples per measurement (steps 0,1,2,4,5,6) |
| `LONG_ITER` | `20000` | Iterations for step 3 |
| `LONG_SAMPLES` | `300` | Samples for step 3 |
| `REPS2` | `5` | Repeats for step 2 |
| `REPS3` | `5` | Repeats for steps 3,4 |
| `DRY_RUN` | `0` | Set to 1 to only print the plan |

## Output Files

Each run creates a timestamped directory with:

| File | Contents |
|------|----------|
| `summary.log` | Full analysis (tables, statistics, bar charts) |
| `stats.csv` | One row per step, for spreadsheets |
| `config.log` | CPU, frequency policy, uncore, THP, NUMA config |
| `step*.out` | Raw benchmark output |
| `step*.tsv` | Parsed: slot/core, latency, error, physical address |
| `step*.freq.log` | Uncore MHz sampled during that step |
| `dist-*.txt` | Per-slot means (sorted) for distribution plots |
| `step5-auto.tsv` | Per-slot: phys, baseline, best_pc, best_lat, trials |
| `step6-matrix.tsv` | Per-pair: core1, core2, baseline, best_pc, best_lat, trials |

## What the Script Controls

On entry (automatic, restored on exit):
- **Core frequency**: pins test cores to max (eliminates P-state transitions)
- **Uncore frequency**: pins all domains to max (eliminates PCU-driven variability)
- **Pre-run check**: verifies actual frequencies under load via turbostat

On every measurement:
- **Memory binding**: `numactl --membind` to the local NUMA node
- **Warmup**: 4 throwaway measurements before real data (process cold-start)

## measure-pause

Standalone tool to measure PAUSE instruction latency:

```bash
# Build
gcc -O2 -o scripts/measure-pause scripts/measure-pause.c

# Run
./scripts/measure-pause [iterations]
```

Uses a 1024-long dependent-add chain to calibrate actual core frequency
(independent of TSC), then measures PAUSE against that clock. Reports
both ns/PAUSE and core_cycles/PAUSE.

## Benchmark --pause Options

The benchmark binary supports three pause modes:

```bash
# Fixed pause count (0 = original behavior)
./core-to-core-latency 5000 300 -b 1 --cores 2,7 --pause 3

# Per-slot optimal (sweeps each slot's cache line)
./core-to-core-latency 5000 300 -b 1 --cores 2,7 --pause auto --slot 0,1,2,...,63

# Per-core-pair optimal (sweeps core pairs at slot=0)
./core-to-core-latency 5000 300 -b 1 --cores 0,1,2,3,4 --pause auto-matrix
```
