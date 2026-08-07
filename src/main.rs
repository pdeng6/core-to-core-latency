mod bench;
mod utils;

use bench::Count;
use bench::cas::SpinMode;
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
    /// Distinct slots are not guaranteed to behave differently. Virtual adjacency
    /// also stops implying physical adjacency at every page boundary, and since
    /// the allocation is not page-aligned, the printed addresses are the only way
    /// to tell where those boundaries fall.
    #[clap(long, require_delimiter=true, value_delimiter=',', default_value="0", value_parser)]
    slot: Vec<usize>,
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
                // One instance for all slots: switching slots must be the only
                // thing that changes between the sub-runs.
                let cas = bench::cas::Bench::new(args.spin);
                for slot in &args.slot {
                    cas.set_slot(*slot);
                    let addr = cas.flag_addr() as usize;
                    let phys = match utils::virt_to_phys(addr) {
                        Some(p) => format!("{:#x}", p),
                        None => "unavailable (needs root)".to_string(),
                    };
                    eprintln!();
                    eprintln!("1) CAS latency on a single shared cache line \
                               [spin={} slot={}/{} virt={:#x} phys={}]",
                              args.spin, slot % bench::cas::Bench::num_slots(),
                              bench::cas::Bench::num_slots(), addr, phys);
                    eprintln!();
                    run_bench(&cores, &clock, &args, &cas);
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
