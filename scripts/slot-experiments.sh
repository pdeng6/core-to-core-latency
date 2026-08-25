#!/bin/bash
# Slot-placement experiments for bench 1.
#
# Usage:
#   sudo ./slot-experiments.sh                     # run all steps (1-6)
#   sudo STEPS=4 ./slot-experiments.sh             # run step 4 only
#   sudo STEPS=1,2 ./slot-experiments.sh           # run steps 1 and 2
#   sudo STEPS=4 PAUSE_LIST=5,6,7 ./slot-experiments.sh  # step 4 with specific pause values
#   DRY_RUN=1 ./slot-experiments.sh                # just show plan, don't run
#
# Steps:
#   0  Baseline matrix: all core pairs, pause=0, slot=0, with freq pinned
#      and membind. The standard latency matrix under controlled conditions.
#   1  Is one page enough, or do we need all 16?   (1024 slots, one pass)
#   2  Is the per-slot value stable across repeats? (page 0 x N repeats)
#   3  Does the answer hold with longer measurements? (page 0 x N, 4x iter)
#   4  How does PAUSE after CAS affect the distribution? (page 0 x N, sweep)
#      If PAUSE_LIST is set (e.g. "1,2,3"), runs exactly those pause values.
#      Otherwise, auto-calibrates: measures PAUSE latency, runs a quick baseline,
#      and sweeps pause=1..floor(baseline_mean / pause_ns).
#   5  Per-slot optimal PAUSE: for each slot, find the pause count that minimizes
#      latency (--pause auto). Shows how much contention overhead is removable.
#   6  Per-core-pair optimal PAUSE: for each pair in CORES, find the optimal
#      pause at slot=0 (--pause auto-matrix). Contention-free latency matrix.
#
# Environment variables:
#   STEPS         which steps to run, comma-separated (default: 0,1,2,3,4,5,6)
#   CORES         core pair to test (default: 2,7)
#   MEMNODE       NUMA node for memory binding (default: 0)
#   OUTDIR        output directory (default: /tmp/slot-exp-YYYYMMDD-HHMMSS)
#   PAUSE_LIST    step 4: explicit list of pause counts (e.g. "1,2,3,4,5")
#   BIN           path to the benchmark binary
#   MEASURE_PAUSE path to the measure-pause binary
#   BASE_ITER     iterations for steps 1,2,4 (default: 5000)
#   BASE_SAMPLES  samples for steps 1,2,4 (default: 300)
#   LONG_ITER     iterations for step 3 (default: 20000)
#   LONG_SAMPLES  samples for step 3 (default: 300)
#   REPS2         repeats for step 2 (default: 5)
#   REPS3         repeats for steps 3,4 (default: 5)
#   DRY_RUN       set to 1 to only print the plan
#
# Notes:
#   - Memory is bound to the local node to avoid NUMA placement noise.
#   - Core and uncore frequencies are pinned on entry and restored on exit.
#   - Repeats are interleaved (0..63, 0..63, ...) not grouped, so time drift
#     shows as a difference between repeats rather than being absorbed.
#   - Each step is self-contained: no step depends on another's output.
#   - Run as root for physical address reporting and frequency pinning.

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    sed -n '2,/^[^#]/{ /^#/s/^# \?//p }' "$0"
    exit 0
fi

set -u

BIN=${BIN:-./target/release/core-to-core-latency}
CORES=${CORES:-2,7}
MEMNODE=${MEMNODE:-0}
OUTDIR=${OUTDIR:-/tmp/slot-exp-$(date +%Y%m%d-%H%M%S)}

# Which steps to run: comma-separated, e.g. STEPS=0,1,2,3,4,5,6 (default: all).
STEPS=${STEPS:-0,1,2,3,4,5,6}
run_step_enabled() { echo ",$STEPS," | grep -q ",$1,"; }

# Step 4: explicit pause values to sweep. If set, skips auto-calibration.
# e.g. PAUSE_LIST=1,2,3,4,5 or PAUSE_LIST=5,6,7,8,9 for a targeted re-run.
PAUSE_LIST=${PAUSE_LIST:-}

# Path to the measure-pause binary (used by step 4 to calibrate PAUSE latency).
MEASURE_PAUSE=${MEASURE_PAUSE:-$(dirname "$BIN")/../../scripts/measure-pause}

# Steps 1-2: the default benchmark settings. Step 3: 4x the iterations per sample.
BASE_ITER=${BASE_ITER:-5000}
BASE_SAMPLES=${BASE_SAMPLES:-300}
LONG_ITER=${LONG_ITER:-20000}
LONG_SAMPLES=${LONG_SAMPLES:-300}

LINES_PER_PAGE=64
NUM_SLOTS=1024
REPS2=${REPS2:-5}
REPS3=${REPS3:-5}

# Throwaway measurements prepended to every slot list and dropped before
# analysis. The benchmark warms up within a measurement (it discards its own
# first sample), but the first measurement of a *process* is still unstable:
# observed at 119ns with the benchmark reporting +/-48.7 where the settled value
# was 66.2 +/-0.1. Without this the first slot in the list absorbs that and looks
# like a placement effect.
WARMUP=${WARMUP:-4}

# Observed one-way latency, used only to estimate runtimes up front.
LAT_NS=${LAT_NS:-63}

# --- runtime estimate -------------------------------------------------------
# One measurement is num_iterations x (num_samples + 1 warmup) round trips, and
# a round trip is two one-way latencies. Process startup is amortised over the
# whole slot list, so it does not show up here.
est_secs() { # iter samples count
    awk -v i="$1" -v s="$2" -v c="$3" -v l="$LAT_NS" \
        'BEGIN{ printf "%.0f", i * (s+1) * 2 * l / 1e9 * c }'
}
fmt() { awk -v s="$1" 'BEGIN{ printf "%dm%02ds", s/60, s%60 }'; }

E1=$(est_secs "$BASE_ITER" "$BASE_SAMPLES" "$NUM_SLOTS")
E2=$(est_secs "$BASE_ITER" "$BASE_SAMPLES" $((LINES_PER_PAGE * REPS2)))
E3=$(est_secs "$LONG_ITER" "$LONG_SAMPLES" $((LINES_PER_PAGE * REPS3)))
# Step 4 estimate is approximate -- actual count depends on measured pause latency.
E4_APPROX=$(est_secs "$BASE_ITER" "$BASE_SAMPLES" $((LINES_PER_PAGE * REPS3 * 8)))

print_plan() {
cat <<EOF
cores=$CORES  membind=$MEMNODE  outdir=$OUTDIR  steps=$STEPS

  step  what                            measurements  settings       est
  1     all $NUM_SLOTS slots, one pass           $NUM_SLOTS         ${BASE_ITER}x${BASE_SAMPLES}     $(fmt "$E1")
  2     page 0 x $REPS2 repeats                     $((LINES_PER_PAGE * REPS2))         ${BASE_ITER}x${BASE_SAMPLES}     $(fmt "$E2")
  3     page 0 x $REPS3 repeats, longer             $((LINES_PER_PAGE * REPS3))         ${LONG_ITER}x${LONG_SAMPLES}    $(fmt "$E3")
  4     page 0 x $REPS3, pause=1..N            ~N*$((LINES_PER_PAGE * REPS3))         ${BASE_ITER}x${BASE_SAMPLES}     ~$(fmt "$E4_APPROX")
        (N = baseline_mean / pause_ns, auto-calibrated)
  5     per-slot optimal pause (--pause auto)  $((LINES_PER_PAGE + LINES_PER_PAGE * 4))         ${BASE_ITER}x${BASE_SAMPLES}     ~$(fmt "$(est_secs "$BASE_ITER" "$BASE_SAMPLES" $((LINES_PER_PAGE + LINES_PER_PAGE * 4)))")
  6     per-pair optimal pause (auto-matrix)  ~$(echo "$CORES" | awk -F, '{n=NF; print n*(n-1)/2*5}')         ${BASE_ITER}x${BASE_SAMPLES}     ~$(fmt "$(est_secs "$BASE_ITER" "$BASE_SAMPLES" "$(echo "$CORES" | awk -F, '{n=NF; print n*(n-1)/2*5}')")")

EOF
}

if [ "${DRY_RUN:-0}" = 1 ]; then
    print_plan
    echo "DRY_RUN=1, estimates only."
    exit 0
fi

if [ ! -x "$BIN" ]; then
    echo "error: $BIN not found or not executable (cargo build --release?)" >&2
    exit 1
fi

mkdir -p "$OUTDIR"

# Everything from here on is written to the terminal AND to summary.log, so the
# statistics survive the session. Raw benchmark output, the per-step .tsv files
# and the frequency logs are separate files; this one is the analysis.
exec > >(tee "$OUTDIR/summary.log") 2>&1

print_plan

# Caveats go into the log rather than only to a terminal nobody kept, since both
# change how the numbers should be read.
if [ "$(id -u)" -ne 0 ]; then
    echo "NOTE: not root -- the phys= column reads 'unavailable' and turbostat"
    echo "      cannot sample core frequency."
fi
SYSFS_UNCORE=/sys/devices/system/cpu/intel_uncore_frequency

if [ -d /var/tmp/uncore_save ]; then
    echo "NOTE: uncore was already pinned externally (uncore-pin.sh). This script"
    echo "      will pin again on top (no-op if already at max) and NOT restore on"
    echo "      exit -- the external pin takes precedence. Use uncore-restore.sh."
fi

# --- pin frequencies --------------------------------------------------------
# Lock both core and uncore frequencies for the duration of the run, so that
# neither frequency transitions nor the PCU's load-based scaling contribute to
# the measured spread. Both are restored on exit (including kill).
#
# Core: raise scaling_min_freq to scaling_max_freq for the test cores only.
# Core 0 on Linux handles softirqs, timer ticks, etc., so the default CORES
# avoids it. Pinning the test cores eliminates P-state transitions as noise.
#
# Uncore: raise min_freq_khz to max_freq_khz on every uncore domain. The PCU
# only ramps uncore when it sees mesh traffic, and a two-thread c2c benchmark
# doesn't generate enough, so without pinning the uncore sits well below its
# ceiling and inflates latency.

CORE_FREQ_SAVED=""
UNCORE_FREQ_SAVED=""

pin_core_freq() {
    if [ "$(id -u)" -ne 0 ]; then return; fi
    for c in ${CORES//,/ }; do
        local f=/sys/devices/system/cpu/cpu$c/cpufreq
        local orig=$(cat "$f/scaling_min_freq" 2>/dev/null)
        local max=$(cat "$f/scaling_max_freq" 2>/dev/null)
        if [ -n "$orig" ] && [ -n "$max" ] && [ "$orig" != "$max" ]; then
            echo "$max" > "$f/scaling_min_freq" 2>/dev/null && \
                CORE_FREQ_SAVED="$CORE_FREQ_SAVED $c:$orig"
        fi
    done
    if [ -n "$CORE_FREQ_SAVED" ]; then
        echo "core frequency pinned: min raised to max for cores ${CORES}"
    else
        echo "core frequency: already pinned or could not write"
    fi
}

restore_core_freq() {
    for entry in $CORE_FREQ_SAVED; do
        local c=${entry%%:*}
        local orig=${entry##*:}
        echo "$orig" > "/sys/devices/system/cpu/cpu$c/cpufreq/scaling_min_freq" 2>/dev/null
    done
    [ -n "$CORE_FREQ_SAVED" ] && echo "core frequency restored for cores ${CORES}"
}

pin_uncore_freq() {
    if [ "$(id -u)" -ne 0 ]; then return; fi
    [ -d "$SYSFS_UNCORE" ] || return
    # If an external pin (uncore-pin.sh) is active, don't save/restore -- the
    # external script owns the state and uncore-restore.sh will put it back.
    if [ -d /var/tmp/uncore_save ]; then
        echo "uncore frequency: externally pinned, skipping (use uncore-restore.sh)"
        return
    fi
    for d in "$SYSFS_UNCORE"/uncore*/; do
        [ -d "$d" ] || continue
        local n=$(basename "$d")
        local orig=$(cat "$d/min_freq_khz" 2>/dev/null)
        local max=$(cat "$d/max_freq_khz" 2>/dev/null)
        if [ -n "$orig" ] && [ -n "$max" ] && [ "$orig" != "$max" ]; then
            echo "$max" > "$d/min_freq_khz" 2>/dev/null && \
                UNCORE_FREQ_SAVED="$UNCORE_FREQ_SAVED $n:$orig"
        fi
    done
    if [ -n "$UNCORE_FREQ_SAVED" ]; then
        echo "uncore frequency pinned: min raised to max on all domains"
    else
        echo "uncore frequency: already pinned or could not write"
    fi
}

restore_uncore_freq() {
    for entry in $UNCORE_FREQ_SAVED; do
        local n=${entry%%:*}
        local orig=${entry##*:}
        echo "$orig" > "$SYSFS_UNCORE/$n/min_freq_khz" 2>/dev/null
    done
    [ -n "$UNCORE_FREQ_SAVED" ] && echo "uncore frequency restored"
}

pin_core_freq
pin_uncore_freq
trap 'restore_core_freq; restore_uncore_freq; kill "$FREQ_PID" 2>/dev/null' EXIT

# --- configuration log ------------------------------------------------------
# Everything needed to tell later whether two runs are comparable.
CONFIG_LOG="$OUTDIR/config.log"
FIRST_CORE=${CORES%%,*}

{
    echo "=== run ==="
    echo "date:      $(date -Is)"
    echo "host:      $(uname -n)"
    echo "kernel:    $(uname -r)"
    echo "cmdline:   $0 $*"
    echo "cores:     $CORES"
    echo "membind:   $MEMNODE"
    echo "settings:  step1/2 ${BASE_ITER}x${BASE_SAMPLES}, step3 ${LONG_ITER}x${LONG_SAMPLES}"
    echo "repeats:   step2 $REPS2, step3 $REPS3"
    echo "binary:    $BIN"
    echo "git:       $(git -C "$(dirname "$BIN")/../.." rev-parse --short HEAD 2>/dev/null || echo n/a)"

    echo
    echo "=== cpu ==="
    grep -m1 "model name" /proc/cpuinfo
    lscpu | grep -E "^(Socket|Core|Thread|NUMA node\(s\)|CPU max|CPU min)"
    lscpu | grep -E "^NUMA node[0-9]"

    echo
    echo "=== core frequency policy (after pinning) ==="
    for c in ${CORES//,/ }; do
        printf "  cpu%s: " "$c"
        for k in scaling_driver scaling_governor scaling_min_freq scaling_max_freq; do
            printf "%s=%s " "$k" "$(cat /sys/devices/system/cpu/cpu$c/cpufreq/$k 2>/dev/null || echo -)"
        done
        echo
    done
    printf '%-34s %s\n' "no_turbo:" "$(cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || echo n/a)"

    echo
    echo "=== uncore frequency (after pinning) ==="
    printf '%-12s %10s %10s %10s %10s %8s\n' domain min max init_min init_max cluster
    for d in "$SYSFS_UNCORE"/uncore*/; do
        [ -d "$d" ] || continue
        printf '%-12s %10s %10s %10s %10s %8s\n' "$(basename "$d")" \
            "$(cat "$d/min_freq_khz" 2>/dev/null || echo -)" \
            "$(cat "$d/max_freq_khz" 2>/dev/null || echo -)" \
            "$(cat "$d/initial_min_freq_khz" 2>/dev/null || echo -)" \
            "$(cat "$d/initial_max_freq_khz" 2>/dev/null || echo -)" \
            "$(cat "$d/fabric_cluster_id" 2>/dev/null || echo -)"
    done

    echo
    echo "=== memory ==="
    echo "THP: $(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo n/a)"
    numactl --hardware | grep -E "^node [0-9]+ (size|free)"

    echo
    echo "=== other load at start ==="
    ps -eo pcpu,pid,user,comm --sort=-pcpu | head -5
} > "$CONFIG_LOG" 2>&1

echo "config -> $CONFIG_LOG"
sed -n '/=== core frequency policy/,/^$/p' "$CONFIG_LOG" | sed 's/^/  /'

# One row per step, for pasting into a spreadsheet or diffing between hosts.
STATS_CSV="$OUTDIR/stats.csv"
echo "step,iter,samples,repeats,n,mean_ns,stddev_ns,rsd_pct,min_ns,max_ns,range_ns" > "$STATS_CSV"
append_stats() { # step iter samples repeats tsv
    awk -v step="$1" -v it="$2" -v sa="$3" -v rp="$4" "$STDDEV_AWK"'
        { n++; a[n] = $2; s += $2; if (n==1 || $2<mn) mn=$2; if ($2>mx) mx=$2 }
        END { if (!n) exit
              m = s/n; sd = stddev(a, n)
              printf "%s,%s,%s,%s,%d,%.3f,%.3f,%.3f,%.2f,%.2f,%.2f\n",
                     step, it, sa, rp, n, m, sd, rsd(sd, m), mn, mx, mx-mn }' "$5" >> "$STATS_CSV"
}

# --- frequency verification (pre-run) ---------------------------------------
# A short pre-run with turbostat confirms that the actual core and uncore
# frequencies under load match the pinned configuration. This runs once before
# the real measurements, so turbostat's MSR reads (which send IPIs to the test
# cores and add ~3-5ns / 5% overhead) do not disturb the actual data.
#
# The three measurement steps then run WITHOUT turbostat -- the pin is a hard
# guarantee (scaling_min == scaling_max), so runtime sampling adds cost without
# information. Only uncore sysfs (which doesn't IPI) is sampled during steps.
pre_run_freq_check() {
    local log="$OUTDIR/pre-run-freq.log"
    echo "== pre-run: frequency verification under load =="

    # Start turbostat
    local tlog="$OUTDIR/pre-run-turbostat.log"
    if [ -x "$(command -v turbostat)" ] && [ "$(id -u)" -eq 0 ]; then
        turbostat --quiet --cpu "$CORES" --show CPU,Bzy_MHz,Avg_MHz \
                  --interval 1 > "$tlog" 2>/dev/null &
        local tpid=$!
    fi

    # Run a short benchmark on just the first two cores, long enough for turbostat
    # to see at least 2 full intervals of busy-state. At ~63ns/round-trip and
    # 1s turbostat interval, we need ~3s of load: 5000 iter x 5000 samples ≈ 3s.
    # Only two cores are needed to generate load; using the full CORES list would
    # run the entire N×N matrix which is far too slow.
    local prerun_cores
    prerun_cores=$(echo "$CORES" | awk -F, '{print $1","$2}')
    numactl --membind="$MEMNODE" "$BIN" 5000 5000 -b 1 \
            --cores "$prerun_cores" --slot 0 > /dev/null 2>&1

    # Sample uncore during the tail end (benchmark is done but turbostat has
    # one more interval to report)
    {
        printf "%-12s" "domain"
        printf "%12s" "current_MHz"
        printf "%12s" "min_MHz"
        printf "%12s\n" "max_MHz"
        for d in "$SYSFS_UNCORE"/uncore*/; do
            [ -d "$d" ] || continue
            printf "%-12s%12s%12s%12s\n" "$(basename "$d")" \
                "$(($(cat "$d/current_freq_khz" 2>/dev/null || echo 0) / 1000))" \
                "$(($(cat "$d/min_freq_khz" 2>/dev/null || echo 0) / 1000))" \
                "$(($(cat "$d/max_freq_khz" 2>/dev/null || echo 0) / 1000))"
        done
    } > "$log"

    # Stop turbostat and summarise
    if [ -n "${tpid:-}" ]; then
        sleep 2  # let it emit at least 2 intervals
        kill "$tpid" 2>/dev/null; wait "$tpid" 2>/dev/null

        echo "   core MHz (turbostat Bzy_MHz under load):"
        # turbostat outputs: CPU Avg_MHz Bzy_MHz — we want column 3 (Bzy_MHz).
        # Skip header lines (CPU=...) and summary lines (CPU="-").
        awk '$1 ~ /^[0-9]+$/ && NF >= 3 && $3+0 > 0 { n[$1]++; s[$1]+=$3
                 if (!mn[$1] || $3<mn[$1]) mn[$1]=$3
                 if ($3>mx[$1]) mx[$1]=$3 }
             END { for (c in n) printf "     cpu%-4s Bzy_MHz: mean=%4.0f min=%4.0f max=%4.0f (n=%d)\n",
                          c, s[c]/n[c], mn[c], mx[c], n[c] }' "$tlog" | sort
    else
        echo "   (turbostat not available)"
    fi

    echo "   uncore MHz (sysfs current_freq during load):"
    awk 'NR>1 { printf "     %s\n", $0 }' "$log"

    # Sanity check: flag if any core wasn't at max
    if [ -n "${tpid:-}" ]; then
        local bad
        bad=$(awk '$1 ~ /^[0-9]+$/ && NF >= 3 && $3+0 > 0 { if ($3 < 2690) print "cpu" $1, $3 "MHz" }' "$tlog")
        if [ -n "$bad" ]; then
            echo "   WARNING: some core samples below expected 2700 MHz:"
            echo "$bad" | sed 's/^/     /'
        else
            echo "   OK: all core samples at expected frequency"
        fi
    fi
    echo "   freq logs -> $tlog, $log"
}

# --- uncore sampling during steps (lightweight, no IPI) ---------------------
# Only sysfs current_freq_khz is read -- this is a register read on the uncore
# PMU, not an MSR on a core, so it does not interrupt the test threads.
FREQ_PID=""
TURBOSTAT_PID=""
start_freq_sampler() { # name
    local log="$OUTDIR/$1.freq.log"
    {
        printf '%-10s' "elapsed_s"
        for d in "$SYSFS_UNCORE"/uncore*/; do
            [ -d "$d" ] && printf ' %-9s' "$(basename "$d")"
        done
        echo
    } > "$log"
    (
        t0=$SECONDS
        while :; do
            printf '%-10s' "$((SECONDS - t0))"
            for d in "$SYSFS_UNCORE"/uncore*/; do
                [ -d "$d" ] || continue
                v=$(cat "$d/current_freq_khz" 2>/dev/null || echo 0)
                printf ' %-9s' "$((v / 1000))"
            done
            echo
            sleep 2
        done
    ) >> "$log" 2>/dev/null &
    FREQ_PID=$!
}

stop_freq_sampler() { # name
    local log="$OUTDIR/$1.freq.log"

    [ -n "$FREQ_PID" ] && { kill "$FREQ_PID" 2>/dev/null; wait "$FREQ_PID" 2>/dev/null; }
    FREQ_PID=""

    # Uncore summary: one line per domain with mean/min/max over the step.
    printf "   %-11s %8s %8s %8s\n" "uncore_MHz" "mean" "min" "max"
    awk 'NR==1 { for (i=1; i<=NF; i++) h[i]=$i; nf=NF; next }
        { for (i=2; i<=nf; i++) if ($i+0 > 0) { n[i]++; s[i]+=$i
              if (n[i]==1 || $i<mn[i]) mn[i]=$i; if ($i>mx[i]) mx[i]=$i } }
        END { for (i=2; i<=nf; i++) if (n[i])
                  printf "   %-11s %8.0f %8.0f %8.0f\n",
                         h[i], s[i]/n[i], mn[i], mx[i] }' "$log"
    echo "   uncore log -> $log"
}

# --- helpers ----------------------------------------------------------------

# Columns: slot, latency, the benchmark's own reported error, phys address.
# The benchmark prints "Min latency: 67.0ns ±0.1" -- that ± is the standard
# error over its num_samples, i.e. noise WITHIN one measurement. The stddev we
# compute in steps 2/3 is ACROSS repeated measurements. Both are reported: the
# first says whether a single measurement is self-consistent, the second whether
# it is reproducible, and they can differ.
extract() { # infile outfile [skip]
    local skip=${3:-0}
    sed 's/\x1b\[[0-9;]*m//g' "$1" | awk -v skip="$skip" '
        /slot=/ { if (match($0, /slot=([0-9]+)/, m)) slot = m[1]
                  if (match($0, /phys=(0x[0-9a-f]+)/, p)) phys = p[1]; else phys = "-" }
        /Min  latency/ { if (match($0, /\xc2\xb1([0-9.]+)/, e)) err = e[1]
                         else if (match($0, /±([0-9.]+)/, e)) err = e[1]
                         else err = "-" }
        /Mean latency/ { if (++seen <= skip) next          # drop the warmups
                         gsub(/ns/, ""); print slot, $3, err, phys }' > "$2"
}

# Sample standard deviation, computed in two passes. The one-pass
# sqrt(E[x^2]-E[x]^2) form cancels catastrophically when the spread is tiny
# relative to the mean -- which is the normal case here, ~0.05ns against ~60ns --
# and returns nan from a slightly negative variance.
STDDEV_AWK='
function stddev(arr, n,    i, m, s, v) {
    if (n < 2) return 0
    for (i = 1; i <= n; i++) m += arr[i]
    m /= n
    for (i = 1; i <= n; i++) { v = arr[i] - m; s += v * v }
    return sqrt(s / (n - 1))
}
# Relative standard deviation (coefficient of variation), as a percentage.
# Reported alongside the absolute stddev because the two answer different
# questions: RSD is what makes spread comparable between platforms running at
# different absolute latencies, while the absolute value is what tells you
# whether an effect is larger than the noise floor in ns.
function rsd(sd, m) { return (m > 0 ? sd / m * 100 : 0) }'

# mean / stddev / min / max of a column, as a one-line summary.
summarise() { # file column label
    awk -v c="$2" -v lbl="$3" "$STDDEV_AWK"'
        { n++; a[n] = $c; s += $c; if (n==1 || $c<mn) mn=$c; if ($c>mx) mx=$c }
        END { if (!n) { printf "  %s: no data\n", lbl; exit }
              m = s/n; sd = stddev(a, n)
              printf "  %-22s n=%-5d mean=%6.2f  stddev=%5.2f  RSD=%5.2f%%  min=%6.2f  max=%6.2f\n",
                     lbl, n, m, sd, rsd(sd, m), mn, mx }' "$1"
}

run_step() { # name iter samples slotlist [pause]
    local name=$1 iter=$2 samples=$3 slots=$4 pause=${5:-0}
    local out="$OUTDIR/$name.out"
    # Warmups are measured and then discarded, so they cost time but keep the
    # first real slot from absorbing the process's cold start.
    local warm=""
    if [ "$WARMUP" -gt 0 ]; then
        warm="$(for _ in $(seq 1 "$WARMUP"); do echo 0; done | paste -sd,),"
    fi
    local pause_label=""
    [ "$pause" -gt 0 ] && pause_label=" pause=$pause"
    echo "== $name: $iter x $samples${pause_label} (+$WARMUP warmup) =="
    local t0=$SECONDS
    start_freq_sampler "$name"
    numactl --membind="$MEMNODE" "$BIN" "$iter" "$samples" -b 1 \
            --cores "$CORES" --slot "${warm}${slots}" --pause "$pause" > "$out" 2>&1
    local rc=$?
    stop_freq_sampler "$name"
    echo "   $((SECONDS - t0))s, rc=$rc -> $out"
    [ "$rc" -eq 0 ] || { echo "   FAILED, see $out" >&2; return 1; }
    extract "$out" "$OUTDIR/$name.tsv" "$WARMUP"
    echo "   $(wc -l < "$OUTDIR/$name.tsv") rows -> $OUTDIR/$name.tsv"
    summarise "$OUTDIR/$name.tsv" 2 "latency over all rows"
    # The benchmark's own +/- (column 3) is not summarised statistically -- its
    # mean and RSD say nothing useful. It is only worth checking as a tripwire:
    # a measurement whose internal error is large did not settle, which is how
    # the process's cold start was found. Kept in the .tsv either way.
    awk -v w="$WARMUP" '$3+0 > 2 { n++; if ($3+0 > worst) { worst = $3; ws = $1 } }
        END { if (n) printf "   WARN %d measurement(s) with internal error > 2ns, worst %.1fns at slot %s\n", n, worst, ws
              else print "   all measurements settled internally (error <= 2ns)" }' \
        "$OUTDIR/$name.tsv"
}

# --- pre-run: verify frequencies under load ---------------------------------
pre_run_freq_check

# --- step 0: baseline matrix (all core pairs, pause=0, slot=0) ---------------
# Standard latency matrix with frequencies pinned and memory bound.
if run_step_enabled 0; then

echo
echo "== step0: baseline matrix (all core pairs, pause=0) =="
numactl --membind="$MEMNODE" "$BIN" "$BASE_ITER" "$BASE_SAMPLES" -b 1 \
        --cores "$CORES" --pause 0 > "$OUTDIR/step0-baseline.out" 2>&1
echo "   rc=$? -> $OUTDIR/step0-baseline.out"

# Show the output (it's the standard matrix format)
sed 's/\x1b\[[0-9;]*m//g' "$OUTDIR/step0-baseline.out"

# Extract mean from the output
STEP0_MEAN=$(sed 's/\x1b\[[0-9;]*m//g' "$OUTDIR/step0-baseline.out" | awk '/Mean latency/{gsub(/ns/,""); print $3}')
echo
echo "   step0 mean: ${STEP0_MEAN}ns"

# Append to stats.csv
echo "step0-baseline,$BASE_ITER,$BASE_SAMPLES,1,1,$STEP0_MEAN,-,-,-,-,-" >> "$STATS_CSV"

fi # step 0

# --- step 1: does one page stand in for all 16? -----------------------------
if run_step_enabled 1; then
run_step step1-allslots "$BASE_ITER" "$BASE_SAMPLES" "$(seq -s, 0 $((NUM_SLOTS - 1)))" || exit 1
append_stats step1-allslots "$BASE_ITER" "$BASE_SAMPLES" 1 "$OUTDIR/step1-allslots.tsv"

echo
echo "-- step 1: per-page statistics --"
awk -v lpp=$LINES_PER_PAGE "$STDDEV_AWK"'{
        p = int($1 / lpp); n[p]++; v[p, n[p]] = $2; s[p] += $2
        if (n[p] == 1 || $2 < mn[p]) mn[p] = $2
        if ($2 > mx[p]) mx[p] = $2
    }
    END {
        printf "  %-5s %6s %7s %7s %6s %6s %6s\n",
               "page", "mean", "stddev", "RSD%", "min", "max", "range"
        for (p = 0; p in n; p++) {
            delete col
            for (i = 1; i <= n[p]; i++) col[i] = v[p, i]
            m = s[p]/n[p]; sd = stddev(col, n[p])
            printf "  %-5d %6.2f %7.2f %7.2f %6.2f %6.2f %6.2f\n",
                   p, m, sd, rsd(sd, m), mn[p], mx[p], mx[p]-mn[p]
            gn++; means[gn] = m; if (gn==1 || m<gmn) gmn=m; if (m>gmx) gmx=m
            gsd += sd; grsd += rsd(sd, m)
            if (gn==1 || mn[p]<amn) amn=mn[p]; if (mx[p]>amx) amx=mx[p]
        }
        gm = 0; for (i = 1; i <= gn; i++) gm += means[i]; gm /= gn
        msd = stddev(means, gn)
        printf "\n  per-page mean:   %.2f .. %.2f ns  (spread %.2f ns, stddev %.2f ns, RSD %.3f%%)\n",
               gmn, gmx, gmx-gmn, msd, rsd(msd, gm)
        printf "  per-page spread: avg stddev %.2f ns, avg RSD %.2f%%\n", gsd/gn, grsd/gn
        printf "  within-page range: %.2f .. %.2f ns overall\n", amn, amx
        printf "  -> pages are interchangeable as distributions when the per-page\n"
        printf "     mean RSD is far below the within-page RSD: the first is how much\n"
        printf "     the pages differ, the second how much a page spans internally.\n"
    }' "$OUTDIR/step1-allslots.tsv"

# Per-page quantiles. This is the real test of "is one page enough": if every
# page draws from the same population of lines, their quantiles coincide even
# though no individual slot agrees.
echo
echo "-- step 1a: per-page quantiles (each page's slots sorted independently) --"
awk -v lpp=$LINES_PER_PAGE '{ print int($1/lpp), $2 }' "$OUTDIR/step1-allslots.tsv" \
  | sort -k1,1n -k2,2n \
  | awk -v lpp=$LINES_PER_PAGE '
    { p = $1; n[p]++; v[p, n[p]] = $2 }
    END {
        split("0 25 50 75 100", q, " ")
        printf "  %-5s", "page"
        for (i = 1; i <= 5; i++) printf " %8s", "p" q[i]
        print ""
        for (p = 0; p in n; p++) {
            printf "  %-5d", p
            for (i = 1; i <= 5; i++) {
                k = int(q[i]/100 * (n[p]-1)) + 1
                x = v[p, k]; printf " %8.2f", x
                if (!(i in mn) || x < mn[i]) mn[i] = x
                if (x > mx[i]) mx[i] = x
            }
            print ""
        }
        printf "  %-5s", "spread"
        for (i = 1; i <= 5; i++) printf " %8.2f", mx[i]-mn[i]
        print "   <- max-min of each quantile across pages"
        printf "\n  -> small spreads mean the pages are drawn from the same\n"
        printf "     distribution, so one page suffices for steps 2 and 3.\n"
    }'

# Same offset across pages: expected to DISAGREE, since the value follows the
# full physical address. Reported so the distinction is on the record.
echo
echo "-- step 1b: same offset, different page (offsets 0-4) --"
awk -v lpp=$LINES_PER_PAGE -v npg=$((NUM_SLOTS / LINES_PER_PAGE)) "$STDDEV_AWK"'
    { v[int($1/lpp) "," ($1 % lpp)] = $2 }
    END {
        printf "  %-5s", "off"; for (p = 0; p < 6; p++) printf " page%-2d", p
        printf "   %6s %6s %6s\n", "mean", "stddev", "RSD%"
        for (o = 0; o < 5; o++) {
            printf "  %-5d", o
            delete col; n = 0; s = 0
            for (p = 0; p < npg; p++) { x = v[p "," o]; col[++n] = x; s += x }
            for (p = 0; p < 6; p++) printf " %5.1f", v[p "," o]
            m = s/n; sd = stddev(col, n)
            printf "   %6.2f %6.2f %6.2f\n", m, sd, rsd(sd, m)
        }
        printf "\n  -> a large stddev/RSD in the last columns means the slot number alone\n"
        printf "     does not fix the latency: the page it sits in matters too.\n"
    }' "$OUTDIR/step1-allslots.tsv"

fi # step 1

# --- steps 2 and 3: repeat page 0 -------------------------------------------
page0_x() { local r=$1; for _ in $(seq 1 "$r"); do seq 0 $((LINES_PER_PAGE - 1)); done | paste -sd,; }

analyse_reps() { # name reps
    local f="$OUTDIR/$1.tsv" reps=$2
    echo
    echo "-- $1: per-slot mean/stddev over $reps repeats --"
    # Full per-slot table, sorted by mean, so the shape of the distribution and
    # the reproducibility of each point are both visible.
    awk "$STDDEV_AWK"'{ n[$1]++; v[$1, n[$1]] = $2; s[$1] += $2 }
        END { for (k in n) {
                 delete col
                 for (i = 1; i <= n[k]; i++) col[i] = v[k, i]
                 m = s[k]/n[k]; sd = stddev(col, n[k])
                 printf "%s %.2f %.2f %.3f %d\n", k, m, sd, rsd(sd, m), n[k] } }' "$f" \
      | sort -k2 -n \
      | awk "$STDDEV_AWK"'BEGIN { printf "  %-5s %7s %7s %7s %4s\n", "slot", "mean", "stddev", "RSD%", "n" }
             { printf "  %-5s %7s %7s %7s %4s\n", $1, $2, $3, $4, $5
               nn++; means[nn] = $2; sm += $2; tsd += $3; trsd += $4
               if (nn==1 || $2<mn) mn=$2; if ($2>mx) mx=$2
               if (nn==1 || $3>wsd) { wsd=$3; wk=$1 } }
             END { avsd = tsd/nn; m = sm/nn; sd = stddev(means, nn)
                   printf "\n  across slots : mean=%.2f  stddev=%.2f  RSD=%.2f%%  min=%.2f  max=%.2f  range=%.2f ns\n",
                          m, sd, rsd(sd, m), mn, mx, mx-mn
                   printf "  within slot  : avg stddev=%.2f ns, avg RSD=%.3f%%, worst stddev=%.2f ns (slot %s)\n",
                          avsd, trsd/nn, wsd, wk
                   if (avsd > 0.005)
                       printf "  signal/noise : %.0f:1  (across-slot range / avg within-slot stddev)\n",
                              (mx-mn)/avsd
                   else
                       printf "  signal/noise : >1000:1 (within-slot noise below resolution)\n"
                   printf "  -> across-slot RSD is the placement effect; within-slot RSD is\n"
                   printf "     the measurement noise. The first should dwarf the second.\n" }'
    # Drift check: mean and stddev of each repeat, in run order. Repeats are
    # interleaved, so a trend here is time drift rather than a slot effect.
    echo
    awk -v lpp=$LINES_PER_PAGE "$STDDEV_AWK"'
        { r = int((NR-1)/lpp); n[r]++; v[r, n[r]] = $2; s[r] += $2 }
        END { printf "  %-8s %7s %7s %7s\n", "repeat", "mean", "stddev", "RSD%"
              for (r = 0; r in n; r++) {
                  delete col
                  for (i = 1; i <= n[r]; i++) col[i] = v[r, i]
                  m = s[r]/n[r]; sd = stddev(col, n[r])
                  rm[r+1] = m
                  printf "  %-8d %7.2f %7.2f %7.2f\n", r+1, m, sd, rsd(sd, m) }
              nr = 0; sm = 0
              for (r in rm) { nr++; sm += rm[r] }
              rsdm = stddev(rm, nr)
              printf "  repeat-to-repeat: stddev of the means = %.3f ns (RSD %.3f%%)\n",
                     rsdm, rsd(rsdm, sm/nr)
              printf "  -> a trend down this column would be time drift, not placement.\n" }' "$f"
}

if run_step_enabled 2; then
run_step step2-page0 "$BASE_ITER" "$BASE_SAMPLES" "$(page0_x "$REPS2")" || exit 1
append_stats step2-page0 "$BASE_ITER" "$BASE_SAMPLES" "$REPS2" "$OUTDIR/step2-page0.tsv"
analyse_reps step2-page0 "$REPS2"
fi # step 2

if run_step_enabled 3; then
run_step step3-page0-long "$LONG_ITER" "$LONG_SAMPLES" "$(page0_x "$REPS3")" || exit 1
append_stats step3-page0-long "$LONG_ITER" "$LONG_SAMPLES" "$REPS3" "$OUTDIR/step3-page0-long.tsv"
analyse_reps step3-page0-long "$REPS3"
fi # step 3

# --- step 4: PAUSE sweep after each successful CAS --------------------------
# If PAUSE_LIST is set, runs exactly those values. Otherwise, auto-calibrates:
# measures PAUSE latency, runs a quick baseline, sweeps 1..floor(mean/pause_ns).
if run_step_enabled 4; then

if [ -n "$PAUSE_LIST" ]; then
    # Explicit list: skip calibration, just run what the user asked for.
    PAUSE_VALUES=$(echo "$PAUSE_LIST" | tr ',' ' ')
    echo "step 4: using explicit PAUSE_LIST=$PAUSE_LIST"
    # Still run a baseline for the summary table
    echo "step 4: running baseline (page 0, single pass)..."
    run_step step4-baseline "$BASE_ITER" "$BASE_SAMPLES" "$(seq -s, 0 $((LINES_PER_PAGE - 1)))" || exit 1
    BASELINE_NS=$(awk '{ s += $2; n++ } END { printf "%.1f", s/n }' "$OUTDIR/step4-baseline.tsv")
    echo "step 4: baseline mean = ${BASELINE_NS}ns"
else
    # Auto-calibrate the sweep range.
    # 4a. Measure PAUSE latency
    if [ -x "$MEASURE_PAUSE" ]; then
        PAUSE_NS=$(${MEASURE_PAUSE} 2>/dev/null | awk '/^ns\/PAUSE:/{print $2}')
        echo "step 4: measured PAUSE latency = ${PAUSE_NS}ns (from $MEASURE_PAUSE)"
    else
        PAUSE_NS=14
        echo "step 4: measure-pause not found at $MEASURE_PAUSE, using default ${PAUSE_NS}ns"
    fi

    # 4b. Quick baseline: one page, no repeats, to get the mean c2c latency
    echo "step 4: running baseline (page 0, single pass)..."
    run_step step4-baseline "$BASE_ITER" "$BASE_SAMPLES" "$(seq -s, 0 $((LINES_PER_PAGE - 1)))" || exit 1
    BASELINE_NS=$(awk '{ s += $2; n++ } END { printf "%.1f", s/n }' "$OUTDIR/step4-baseline.tsv")
    echo "step 4: baseline mean = ${BASELINE_NS}ns"

    # 4c. Compute max pause count: floor(baseline / pause_ns)
    MAX_PAUSE=$(awk -v base="$BASELINE_NS" -v pns="$PAUSE_NS" 'BEGIN { printf "%d", int(base / pns) }')
    [ "$MAX_PAUSE" -lt 1 ] && MAX_PAUSE=1
    PAUSE_VALUES=$(seq 1 "$MAX_PAUSE")
    echo "step 4: sweeping pause=1..${MAX_PAUSE} (${BASELINE_NS}ns / ${PAUSE_NS}ns)"
fi
echo

# 4d. Run the sweep
for pc in $PAUSE_VALUES; do
    run_step "step4-pause${pc}" "$BASE_ITER" "$BASE_SAMPLES" "$(page0_x "$REPS3")" "$pc" || exit 1
    append_stats "step4-pause${pc}" "$BASE_ITER" "$BASE_SAMPLES" "$REPS3" "$OUTDIR/step4-pause${pc}.tsv"
    analyse_reps "step4-pause${pc}" "$REPS3"
done

echo
echo "-- step4: effect of PAUSE after CAS --"
printf "  %-16s %8s %8s %8s %8s %8s\n" "step" "mean" "stddev" "RSD%" "min" "max"
printf "  %-16s %8.2f %8s %8s %8s %8s\n" "baseline" "$BASELINE_NS" "-" "-" "-" "-"
for pc in $PAUSE_VALUES; do
    awk -v name="step4-pause${pc}" "$STDDEV_AWK"'
        { n++; a[n] = $2; s += $2; if (n==1 || $2<mn) mn=$2; if ($2>mx) mx=$2 }
        END { m = s/n; sd = stddev(a, n)
              printf "  %-16s %8.2f %8.2f %8.2f %8.2f %8.2f\n",
                     name, m, sd, rsd(sd, m), mn, mx }' "$OUTDIR/step4-pause${pc}.tsv"
done

fi # step 4

# --- step 5: per-slot optimal PAUSE (--pause auto) --------------------------
if run_step_enabled 5; then

echo
echo "== step5: per-slot optimal pause (--pause auto) =="
numactl --membind="$MEMNODE" "$BIN" "$BASE_ITER" "$BASE_SAMPLES" -b 1 \
        --cores "$CORES" --slot "$(seq -s, 0 $((LINES_PER_PAGE - 1)))" \
        --pause auto > "$OUTDIR/step5-auto.out" 2>&1
echo "   rc=$? -> $OUTDIR/step5-auto.out"

# Parse the output. The benchmark prints lines like:
#   0  0x183b5a5000  108.3  11  *97.3  101.5  103.7  107.1  97.3
# Fields: slot, phys, baseline, N, lat_N-3, lat_N-2, lat_N-1, lat_N, best_lat
# The * prefix marks the best. We extract: slot phys baseline best_pc best_lat trials
# where trials is e.g. "8:97.3,9:101.5,10:103.7,11:107.1"
sed 's/\x1b\[[0-9;]*m//g' "$OUTDIR/step5-auto.out" | awk '
    /^ *[0-9]+ +0x/ || /^ *[0-9]+ +-/ {
        slot = $1; phys = $2; base = $3; n_val = $4
        best_lat = $NF
        best_pc = ""
        trials = ""
        for (i = 5; i < NF; i++) {
            pc = n_val - (NF - 1 - i)
            lat = $i
            gsub(/\*/, "", lat)
            if ($i ~ /^\*/) best_pc = pc
            trials = trials (trials == "" ? "" : ",") pc ":" lat
        }
        print slot, phys, base, best_pc, best_lat, trials
    }
' > "$OUTDIR/step5-auto.tsv"
echo "   $(wc -l < "$OUTDIR/step5-auto.tsv") slots -> $OUTDIR/step5-auto.tsv"

# Extract the summary line
sed 's/\x1b\[[0-9;]*m//g' "$OUTDIR/step5-auto.out" | grep "^mean:" | sed 's/^/   /'

echo
echo "-- step5: per-slot results --"
printf "  %-5s %-18s %10s %8s %10s  %s\n" "slot" "phys" "baseline" "best_pc" "best_lat" "trials"
awk '{ printf "  %-5s %-18s %10s %8s %10s  %s\n", $1, $2, $3, $4, $5, $6 }' "$OUTDIR/step5-auto.tsv"

echo
echo "-- step5: summary statistics --"
awk "$STDDEV_AWK"'
    { n++; base[n]=$3; best[n]=$5; sb+=$3; sbt+=$5
      if(n==1||$3<bmin)bmin=$3; if($3>bmax)bmax=$3
      if(n==1||$5<tmin)tmin=$5; if($5>tmax)tmax=$5 }
    END {
        bm=sb/n; tm=sbt/n; bsd=stddev(base,n); tsd=stddev(best,n)
        printf "  %-14s %10s %10s %10s %10s %10s %10s\n", "", "mean", "stddev", "RSD%", "min", "max", "range"
        printf "  %-14s %10.2f %10.2f %10.2f %10.2f %10.2f %10.2f\n", "baseline", bm, bsd, rsd(bsd,bm), bmin, bmax, bmax-bmin
        printf "  %-14s %10.2f %10.2f %10.2f %10.2f %10.2f %10.2f\n", "auto-pause", tm, tsd, rsd(tsd,tm), tmin, tmax, tmax-tmin
        printf "  %-14s %10.2f %10s %10s %10s %10s %10s\n", "improvement", bm-tm, "-", "-", "-", "-", "-"
        printf "  %-14s %10.1f%% %9s %10s %10s %10s %10s\n", "improvement%", (bm-tm)/bm*100, "-", "-", "-", "-", "-"
    }' "$OUTDIR/step5-auto.tsv"

# Bar chart: baseline vs auto-pause, side by side
echo
echo "-- step5: latency distribution, baseline vs auto-pause (2ns bins) --"
awk '{ print $3 }' "$OUTDIR/step5-auto.tsv" | sort -n > "$OUTDIR/dist-step5-baseline.txt"
awk '{ print $5 }' "$OUTDIR/step5-auto.tsv" | sort -n > "$OUTDIR/dist-step5-autopause.txt"

awk -v f1="$OUTDIR/dist-step5-baseline.txt" -v f2="$OUTDIR/dist-step5-autopause.txt" '
    BEGIN {
        bin = 2; scale = 3
        while ((getline v < f1) > 0) { h1[int(v/bin)]++; if(!lo||v<lo)lo=v; if(v>hi)hi=v }
        close(f1)
        while ((getline v < f2) > 0) { h2[int(v/bin)]++; if(!lo||v<lo)lo=v; if(v>hi)hi=v }
        close(f2)
        printf "  %-9s %-20s %-20s\n", "bin(ns)", "baseline", "auto-pause"
        for (b = int(lo/bin); b <= int(hi/bin); b++) {
            if (h1[b]+0 == 0 && h2[b]+0 == 0) continue
            printf "  %3.0f-%-5.0f", b*bin, (b+1)*bin
            bar1 = ""; cnt = int((h1[b]+0+scale-1)/scale)
            for (j = 0; j < cnt; j++) bar1 = bar1 "#"
            bar2 = ""; cnt = int((h2[b]+0+scale-1)/scale)
            for (j = 0; j < cnt; j++) bar2 = bar2 "#"
            printf " %-20s %-20s\n", bar1, bar2
        }
    }' /dev/null

# Also append to stats.csv
awk "$STDDEV_AWK"'
    { n++; base[n]=$3; best[n]=$5; sb+=$3; sbt+=$5
      if(n==1||$3<bmin)bmin=$3; if($3>bmax)bmax=$3
      if(n==1||$5<tmin)tmin=$5; if($5>tmax)tmax=$5 }
    END {
        bm=sb/n; tm=sbt/n; bsd=stddev(base,n); tsd=stddev(best,n)
        printf "step5-baseline,%s,%s,1,%d,%.3f,%.3f,%.3f,%.2f,%.2f,%.2f\n",
               "'"$BASE_ITER"'","'"$BASE_SAMPLES"'",n,bm,bsd,rsd(bsd,bm),bmin,bmax,bmax-bmin
        printf "step5-autopause,%s,%s,1,%d,%.3f,%.3f,%.3f,%.2f,%.2f,%.2f\n",
               "'"$BASE_ITER"'","'"$BASE_SAMPLES"'",n,tm,tsd,rsd(tsd,tm),tmin,tmax,tmax-tmin
    }' "$OUTDIR/step5-auto.tsv" >> "$STATS_CSV"

fi # step 5

# --- step 6: per-core-pair optimal PAUSE (--pause auto-matrix) ---------------
if run_step_enabled 6; then

echo
echo "== step6: per-core-pair optimal pause (--pause auto-matrix) =="
numactl --membind="$MEMNODE" "$BIN" "$BASE_ITER" "$BASE_SAMPLES" -b 1 \
        --cores "$CORES" --pause auto-matrix > "$OUTDIR/step6-matrix.out" 2>&1
echo "   rc=$? -> $OUTDIR/step6-matrix.out"

# Parse output: lines like "    7     2       63.7        4     66.4     69.7    *65.2     73.0       65.2"
sed 's/\x1b\[[0-9;]*m//g' "$OUTDIR/step6-matrix.out" | awk '
    /^slot=0 phys=/ { phys = $0; sub(/.*phys=/, "", phys) }
    /^ *[0-9]+ +[0-9]+ +[0-9]/ && NF >= 9 {
        c1 = $1; c2 = $2; base = $3; n_val = $4
        best_lat = $NF
        best_pc = ""
        trials = ""
        for (i = 5; i < NF; i++) {
            pc = n_val - (NF - 1 - i)
            lat = $i
            gsub(/\*/, "", lat)
            if ($i ~ /^\*/) best_pc = pc
            trials = trials (trials == "" ? "" : ",") pc ":" lat
        }
        print c1, c2, base, best_pc, best_lat, trials
    }
    END { if (phys != "") print "# phys=" phys }
' > "$OUTDIR/step6-matrix.tsv"

# Count pairs (excluding the comment line)
NPAIRS=$(grep -v "^#" "$OUTDIR/step6-matrix.tsv" | wc -l)
PHYS=$(grep "^# phys=" "$OUTDIR/step6-matrix.tsv" | sed 's/# phys=//')
echo "   ${NPAIRS} pairs, slot=0 phys=${PHYS:-unavailable} -> $OUTDIR/step6-matrix.tsv"

# Extract the summary line from benchmark output
sed 's/\x1b\[[0-9;]*m//g' "$OUTDIR/step6-matrix.out" | grep "^mean:" | sed 's/^/   /'

echo
echo "-- step6: per-core-pair results --"
printf "  %-5s %-5s %10s %8s %10s  %s\n" "core1" "core2" "baseline" "best_pc" "best_lat" "trials"
grep -v "^#" "$OUTDIR/step6-matrix.tsv" | \
    awk '{ printf "  %-5s %-5s %10s %8s %10s  %s\n", $1, $2, $3, $4, $5, $6 }'

echo
echo "-- step6: summary statistics --"
grep -v "^#" "$OUTDIR/step6-matrix.tsv" | awk "$STDDEV_AWK"'
    { n++; base[n]=$3; best[n]=$5; sb+=$3; sbt+=$5
      if(n==1||$3<bmin)bmin=$3; if($3>bmax)bmax=$3
      if(n==1||$5<tmin)tmin=$5; if($5>tmax)tmax=$5 }
    END {
        bm=sb/n; tm=sbt/n; bsd=stddev(base,n); tsd=stddev(best,n)
        printf "  %-14s %10s %10s %10s %10s %10s %10s\n", "", "mean", "stddev", "RSD%", "min", "max", "range"
        printf "  %-14s %10.2f %10.2f %10.2f %10.2f %10.2f %10.2f\n", "baseline", bm, bsd, rsd(bsd,bm), bmin, bmax, bmax-bmin
        printf "  %-14s %10.2f %10.2f %10.2f %10.2f %10.2f %10.2f\n", "auto-pause", tm, tsd, rsd(tsd,tm), tmin, tmax, tmax-tmin
        printf "  %-14s %10.2f %10s %10s %10s %10s %10s\n", "improvement", bm-tm, "-", "-", "-", "-", "-"
        printf "  %-14s %10.1f%% %9s %10s %10s %10s %10s\n", "improvement%", (bm-tm)/bm*100, "-", "-", "-", "-", "-"
    }'

# Bar chart: baseline vs auto-pause
echo
echo "-- step6: latency distribution, baseline vs auto-pause (2ns bins) --"
grep -v "^#" "$OUTDIR/step6-matrix.tsv" | awk '{ print $3 }' | sort -n > "$OUTDIR/dist-step6-baseline.txt"
grep -v "^#" "$OUTDIR/step6-matrix.tsv" | awk '{ print $5 }' | sort -n > "$OUTDIR/dist-step6-autopause.txt"

awk -v f1="$OUTDIR/dist-step6-baseline.txt" -v f2="$OUTDIR/dist-step6-autopause.txt" '
    BEGIN {
        bin = 2; scale = 3
        while ((getline v < f1) > 0) { h1[int(v/bin)]++; if(!lo||v<lo)lo=v; if(v>hi)hi=v }
        close(f1)
        while ((getline v < f2) > 0) { h2[int(v/bin)]++; if(!lo||v<lo)lo=v; if(v>hi)hi=v }
        close(f2)
        printf "  %-9s %-20s %-20s\n", "bin(ns)", "baseline", "auto-pause"
        for (b = int(lo/bin); b <= int(hi/bin); b++) {
            if (h1[b]+0 == 0 && h2[b]+0 == 0) continue
            printf "  %3.0f-%-5.0f", b*bin, (b+1)*bin
            bar1 = ""; cnt = int((h1[b]+0+scale-1)/scale)
            for (j = 0; j < cnt; j++) bar1 = bar1 "#"
            bar2 = ""; cnt = int((h2[b]+0+scale-1)/scale)
            for (j = 0; j < cnt; j++) bar2 = bar2 "#"
            printf " %-20s %-20s\n", bar1, bar2
        }
    }' /dev/null

# Append to stats.csv
grep -v "^#" "$OUTDIR/step6-matrix.tsv" | awk "$STDDEV_AWK"'
    { n++; base[n]=$3; best[n]=$5; sb+=$3; sbt+=$5
      if(n==1||$3<bmin)bmin=$3; if($3>bmax)bmax=$3
      if(n==1||$5<tmin)tmin=$5; if($5>tmax)tmax=$5 }
    END {
        bm=sb/n; tm=sbt/n; bsd=stddev(base,n); tsd=stddev(best,n)
        printf "step6-baseline,%s,%s,1,%d,%.3f,%.3f,%.3f,%.2f,%.2f,%.2f\n",
               "'"$BASE_ITER"'","'"$BASE_SAMPLES"'",n,bm,bsd,rsd(bsd,bm),bmin,bmax,bmax-bmin
        printf "step6-autopause,%s,%s,1,%d,%.3f,%.3f,%.3f,%.2f,%.2f,%.2f\n",
               "'"$BASE_ITER"'","'"$BASE_SAMPLES"'",n,tm,tsd,rsd(tsd,tm),tmin,tmax,tmax-tmin
    }' >> "$STATS_CSV"

fi # step 6

# --- distribution comparison (runs if step 2 and 3 both ran) ----------------
per_slot_means() { # tsv
    awk '{ s[$1] += $2; n[$1]++ } END { for (k in s) printf "%.3f\n", s[k]/n[k] }' "$1" | sort -n
}

if [ -f "$OUTDIR/step2-page0.tsv" ] && [ -f "$OUTDIR/step3-page0-long.tsv" ]; then
echo
echo "-- step2 vs step3: does the longer run change the distribution? --"
per_slot_means "$OUTDIR/step2-page0.tsv"      > "$OUTDIR/dist-step2.txt"
per_slot_means "$OUTDIR/step3-page0-long.tsv" > "$OUTDIR/dist-step3.txt"

paste "$OUTDIR/dist-step2.txt" "$OUTDIR/dist-step3.txt" \
  | awk "$STDDEV_AWK"'
    { n++; a[n] = $1; b[n] = $2 }
    END {
        split("0 10 25 50 75 90 100", q, " ")
        printf "  %-8s %10s %10s %8s\n", "quantile", "step2", "step3", "diff"
        for (i = 1; i <= 7; i++) {
            k = int(q[i]/100 * (n-1)) + 1
            printf "  p%-7s %10.2f %10.2f %+8.2f\n", q[i], a[k], b[k], b[k]-a[k]
        }
        for (i = 1; i <= n; i++) { sa += a[i]; sb += b[i]
            d = b[i] - a[i]; ad = (d<0?-d:d); if (ad > mxq) mxq = ad }
        ma = sa/n; mb = sb/n; sda = stddev(a, n); sdb = stddev(b, n)
        printf "\n  %-14s %10s %10s %10s\n", "", "step2", "step3", "diff"
        printf "  %-14s %10.2f %10.2f %+10.2f\n", "mean", ma, mb, mb-ma
        printf "  %-14s %10.2f %10.2f %+10.2f\n", "stddev", sda, sdb, sdb-sda
        printf "  %-14s %10.2f %10.2f %+10.2f\n", "RSD%", rsd(sda,ma), rsd(sdb,mb),
               rsd(sdb,mb)-rsd(sda,ma)
        printf "  %-14s %10.2f %10.2f %+10.2f\n", "min", a[1], b[1], b[1]-a[1]
        printf "  %-14s %10.2f %10.2f %+10.2f\n", "max", a[n], b[n], b[n]-a[n]
        printf "  %-14s %10.2f %10.2f %+10.2f\n", "range", a[n]-a[1], b[n]-b[1],
               (b[n]-b[1])-(a[n]-a[1])
        printf "\n  largest gap between matching quantiles: %.2f ns\n", mxq
        printf "  -> the two distributions agree, and the shorter setting is\n"
        printf "     sufficient, when that gap is small next to the range and the\n"
        printf "     two RSDs match.\n"
    }'
fi

# --- latency distribution histograms ----------------------------------------
# Collect all available dist files (step2, step3, and whatever pause values ran).
echo
echo "-- latency distribution, all steps (per-slot means, shared 2ns bins) --"

# Generate dist files for all step4 pause runs that produced a tsv
ALL_DIST_NAMES="step2 step3"
ALL_DIST_FILES="$OUTDIR/dist-step2.txt $OUTDIR/dist-step3.txt"
[ -f "$OUTDIR/step2-page0.tsv" ] && per_slot_means "$OUTDIR/step2-page0.tsv" > "$OUTDIR/dist-step2.txt"
[ -f "$OUTDIR/step3-page0-long.tsv" ] && per_slot_means "$OUTDIR/step3-page0-long.tsv" > "$OUTDIR/dist-step3.txt"

pc=1
while [ -f "$OUTDIR/step4-pause${pc}.tsv" ]; do
    per_slot_means "$OUTDIR/step4-pause${pc}.tsv" > "$OUTDIR/dist-step4-pause${pc}.txt"
    ALL_DIST_NAMES="$ALL_DIST_NAMES p${pc}"
    ALL_DIST_FILES="$ALL_DIST_FILES $OUTDIR/dist-step4-pause${pc}.txt"
    pc=$((pc + 1))
done
NUM_DIST=$((pc - 1 + 2))  # +2 for step2 and step3

# Numeric table
awk -v names="$ALL_DIST_NAMES" -v flist="$ALL_DIST_FILES" '
    BEGIN {
        bin = 2
        n = split(names, nm, " ")
        split(flist, files, " ")
        for (i = 1; i <= n; i++) {
            while ((getline v < files[i]) > 0) {
                h[i, int(v/bin)]++
                if (!lo || v < lo) lo = v
                if (v > hi) hi = v
            }
            close(files[i])
        }
        printf "  %-9s", "bin(ns)"
        for (i = 1; i <= n; i++) printf " %5s", nm[i]
        print ""
        for (b = int(lo/bin); b <= int(hi/bin); b++) {
            any = 0
            for (i = 1; i <= n; i++) if (h[i,b]+0 > 0) any = 1
            if (!any) continue
            printf "  %3.0f-%-5.0f", b*bin, (b+1)*bin
            for (i = 1; i <= n; i++) printf " %5d", h[i,b]+0
            printf "\n"
        }
        printf "\n  -> the pause columns should shift right (higher latency) while\n"
        printf "     maintaining a similar shape if the effect is purely additive.\n"
    }' /dev/null

# Bar chart (scaled: each # = ceil(count/scale))
echo
echo "-- latency distribution, bar chart (2ns bins, each # = ~3 slots) --"
awk -v names="$ALL_DIST_NAMES" -v flist="$ALL_DIST_FILES" '
    BEGIN {
        bin = 2; scale = 3
        n = split(names, nm, " ")
        split(flist, files, " ")
        for (i = 1; i <= n; i++) {
            while ((getline v < files[i]) > 0) {
                h[i, int(v/bin)]++
                if (!lo || v < lo) lo = v
                if (v > hi) hi = v
            }
            close(files[i])
        }
        printf "  %-9s", "bin(ns)"
        for (i = 1; i <= n; i++) printf " %-13s", nm[i]
        print ""
        for (b = int(lo/bin); b <= int(hi/bin); b++) {
            any = 0
            for (i = 1; i <= n; i++) if (h[i,b]+0 > 0) any = 1
            if (!any) continue
            printf "  %3.0f-%-5.0f", b*bin, (b+1)*bin
            for (i = 1; i <= n; i++) {
                bar = ""
                cnt = int((h[i,b]+0+scale-1)/scale)
                for (j = 0; j < cnt; j++) bar = bar "#"
                printf " %-13s", bar
            }
            printf "\n"
        }
    }' /dev/null

echo
echo "-- headline numbers (also in stats.csv) --"
column -t -s, "$STATS_CSV" | sed 's/^/  /'

echo
echo "all steps done. files in $OUTDIR:"
echo "  summary.log      this entire analysis"
echo "  stats.csv        one row per step, for spreadsheets or host-to-host diffs"
echo "  config.log       cpu, frequency policy, uncore limits, THP, NUMA, load"
echo "  <step>.out       raw benchmark output"
echo "  <step>.tsv       slot, latency, internal error, physical address"
echo "  <step>.freq.log  uncore MHz sampled during that step"
echo "  dist-*.txt            per-slot means, sorted, for distribution comparisons"
