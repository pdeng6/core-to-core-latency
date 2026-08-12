mod bench;
mod utils;

use bench::Count;
use bench::cas::SpinMode;
use bench::Bench as _;
use std::sync::Arc;
use clap::Parser;
use quanta::Clock;
use crate::bench::run_bench;

const DEFAULT_NUM_SAMPLES: Count = 300;
const DEFAULT_NUM_ITERATIONS_PER_SAMPLE: Count = 1000;

#[derive(Clone)]
#[derive(clap::Parser)]
pub struct CliArgs {
    /// The number of iterations per sample
    #[clap(default_value_t = DEFAULT_NUM_ITERATIONS_PER_SAMPLE, value_parser)]
    num_iterations: Count,

    /// The number of samples
    #[clap(default_value_t = DEFAULT_NUM_SAMPLES, value_parser)]
    num_samples: Count,

    /// Outputs the mean latencies in CSV format on stdout
    #[clap(long, value_parser)]
    csv: bool,

    /// Select which benchmark to run, in a comma delimited list, e.g., '1,3' {n}
    /// 1: CAS latency on a single shared cache line. {n}
    /// 2: Single-writer single-reader latency on two shared cache lines. {n}
    /// 3: One writer and one reader on many cache line, using the clock. {n}
    #[clap(short, long, default_value="1", require_delimiter=true, value_delimiter=',', value_parser)]
    bench: Vec<usize>,

    /// Specify the cores by id that should be used, comma delimited. By default all cores are used.
    #[clap(short, long, require_delimiter=true, value_delimiter=',', value_parser)]
    cores: Vec<usize>,

    /// Bench 1 only: how the waiting thread spins. {n}
    /// bare: retry the CAS itself (upstream behavior). {n}
    /// ttas: test-and-test-and-set, spin on a relaxed load first, then CAS.
    #[clap(long, arg_enum, default_value_t = SpinMode::Bare, value_parser)]
    spin: SpinMode,

    /// Bench 1 only: which cache line to hold the shared flag, comma delimited,
    /// one slot per 64-byte line. Which line the flag lives on can affect the
    /// result, so the slot is a variable in its own right. Pass a list to sweep
    /// in one run, e.g. --slot 0,1,2 -- only slots measured within a single run
    /// are comparable, since each process gets different physical pages. Repeat a
    /// slot to gauge the noise floor: --slot 0,1,0,1
    ///
    /// Distinct slots are not guaranteed to behave differently. Slots are page
    /// aligned, so slot N is line N%64 of page N/64, but virtual adjacency stops
    /// implying physical adjacency at each of those page boundaries: 0..63 vary
    /// only the offset within one page, while 0,64,128,... land on unrelated pages.
    #[clap(long, require_delimiter=true, value_delimiter=',', default_value="0", value_parser)]
    slot: Vec<usize>,

    /// Bench 1 only: PAUSE instructions after each successful CAS. {n}
    /// 0,1,2,...: insert exactly N PAUSEs (default 0). {n}
    /// auto: for each slot, find the pause count that minimizes latency.
    ///       Runs a calibration pass, then measures each slot at its optimal
    ///       pause count +/- 1.
    #[clap(long, default_value = "0", value_parser)]
    pause: String,
}

fn run_auto_pause(cores: &[core_affinity::CoreId], clock: &Arc<Clock>, args: &CliArgs) {
    let cas = bench::cas::Bench::new(args.spin, 0);
    let num_slots = bench::cas::Bench::num_slots();

    // 1. Measure PAUSE latency
    let pause_ns = bench::cas::measure_pause_ns(clock);

    // 2. Calibration pass: measure each slot with pause=0
    eprintln!("auto-pause: calibration pass (pause=0, all {} slots)...", args.slot.len());
    cas.set_pause_count(0);
    let mut baselines: Vec<(usize, f64)> = Vec::new();
    for &slot in &args.slot {
        cas.set_slot(slot);
        let results = cas.run(
            (cores[0], cores[1]), clock,
            args.num_iterations, args.num_samples,
        );
        let mean = results.iter().sum::<f64>() / results.len() as f64;
        baselines.push((slot % num_slots, mean));
    }

    // 3. For each slot, compute target pause N = floor(baseline/pause_ns),
    //    then measure at N-3, N-2, N-1, N to find the minimum.
    eprintln!("auto-pause: measurement pass (per-slot, pause = N-3..N)...");
    eprintln!();
    eprintln!("{:>5} {:>18} {:>10} {:>8} {:>8} {:>8} {:>8} {:>8} {:>10}",
              "slot", "phys", "baseline", "N", "N-3", "N-2", "N-1", "N", "best_lat");

    let mut sum_base = 0.0;
    let mut sum_best = 0.0;

    for &(slot, baseline) in &baselines {
        let n = (baseline / pause_ns).floor() as u32;
        let candidates: Vec<u32> = (n.saturating_sub(3)..=n).collect();

        let mut best_lat = f64::MAX;
        let mut best_pc = 0u32;
        let mut lats: Vec<(u32, f64)> = Vec::new();

        cas.set_slot(slot);
        for &pc in &candidates {
            cas.set_pause_count(pc);
            let results = cas.run(
                (cores[0], cores[1]), clock,
                args.num_iterations, args.num_samples,
            );
            let mean = results.iter().sum::<f64>() / results.len() as f64;
            lats.push((pc, mean));
            if mean < best_lat {
                best_lat = mean;
                best_pc = pc;
            }
        }

        let addr = cas.flag_addr() as usize;
        let phys = match crate::utils::virt_to_phys(addr) {
            Some(p) => format!("{:#x}", p),
            None => "-".to_string(),
        };

        // Format each candidate's latency, mark the best with *
        let lat_strs: Vec<String> = lats.iter()
            .map(|&(pc, lat)| {
                if pc == best_pc { format!("*{:.1}", lat) } else { format!("{:.1}", lat) }
            })
            .collect();

        // Pad to always show 4 columns (in case N < 3, fewer candidates)
        let empty = "-".to_string();
        let padded: Vec<&str> = {
            let pad_count = 4 - lat_strs.len();
            let mut v: Vec<&str> = (0..pad_count).map(|_| empty.as_str()).collect();
            v.extend(lat_strs.iter().map(|s| s.as_str()));
            v
        };

        eprintln!("{:>5} {:>18} {:>10.1} {:>8} {:>8} {:>8} {:>8} {:>8} {:>10.1}",
                  slot, phys, baseline, n,
                  padded[0], padded[1], padded[2], padded[3], best_lat);

        sum_base += baseline;
        sum_best += best_lat;
    }

    let cnt = baselines.len() as f64;
    eprintln!();
    eprintln!("mean: baseline={:.1}ns  auto-pause={:.1}ns  improvement={:.1}ns ({:.1}%)",
              sum_base / cnt, sum_best / cnt,
              sum_base / cnt - sum_best / cnt,
              (sum_base / cnt - sum_best / cnt) / (sum_base / cnt) * 100.0);
}

fn main() {
    let args = CliArgs::parse();

    let cores = core_affinity::get_core_ids().expect("get_core_ids() failed");

    let cores = if !args.cores.is_empty() {
        args.cores.iter().copied()
            .map(|cid| *cores.iter().find(|c| c.id == cid)
                .unwrap_or_else(||panic!("Core {} not found. Available: {:?}", cid, &cores)))
            .collect()
    } else {
        cores
    };

    utils::show_cpuid_info();
    eprintln!("Num cores: {}", cores.len());
    eprintln!("Num iterations per samples: {}", args.num_iterations);
    eprintln!("Num samples: {}", args.num_samples);
    #[cfg(target_os = "macos")]
    eprintln!("{}", ansi_term::Color::Red.bold().paint("WARN macOS may ignore thread-CPU affinity (we can't select a CPU to run on). Results may be inaccurate"));

    let clock = Arc::new(Clock::new());

    for b in &args.bench {
        match b {
            1 => {
                if args.pause == "auto" {
                    run_auto_pause(&cores, &clock, &args);
                } else {
                    let pause_count: u32 = args.pause.parse()
                        .expect("--pause must be a number or 'auto'");
                    let cas = bench::cas::Bench::new(args.spin, pause_count);
                    for slot in &args.slot {
                        cas.set_slot(*slot);
                        let addr = cas.flag_addr() as usize;
                        let phys = match utils::virt_to_phys(addr) {
                            Some(p) => format!("{:#x}", p),
                            None => "unavailable (needs root)".to_string(),
                        };
                        eprintln!();
                        eprintln!("1) CAS latency on a single shared cache line \
                                   [spin={} pause={} slot={}/{} virt={:#x} phys={}]",
                                  args.spin, pause_count,
                                  slot % bench::cas::Bench::num_slots(),
                                  bench::cas::Bench::num_slots(), addr, phys);
                        eprintln!();
                        run_bench(&cores, &clock, &args, &cas);
                    }
                }
            }
            2 => {
                eprintln!();
                eprintln!("2) Single-writer single-reader latency on two shared cache lines");
                eprintln!();
                run_bench(&cores, &clock, &args, &bench::read_write::Bench::new());
            }
            3 => {
                utils::assert_rdtsc_usable(&clock);
                eprintln!();
                eprintln!("3) Message passing. One writer and one reader on many cache line");
                eprintln!();
                run_bench(&cores, &clock, &args, &bench::msg_passing::Bench::new(args.num_iterations));
            }
            _ => panic!("--bench should be 1, 2 or 3"),
        }
    }
}
