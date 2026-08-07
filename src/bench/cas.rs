use core_affinity::CoreId;
use std::fmt;
use std::sync::Barrier;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use quanta::Clock;
use super::Count;

const PING: bool = false;
const PONG: bool = true;

/// The coherence granularity: one line is tracked as a unit.
///
/// Deliberately not `CachePadded`, which aligns to 128 bytes on x86_64 to defeat
/// the adjacent-line prefetcher. Using it as the stride would step two lines at
/// a time, holding physical address bit 6 at zero across every slot and leaving
/// half the lines unreachable. There is no false sharing to pad against here:
/// only one slot is ever touched, and nothing else lives in this allocation.
const LINE_BYTES: usize = 64;

/// How many lines we allocate to pick the shared flag from. 1024 lines is 64KiB,
/// i.e. 16 pages -- enough that both the within-page and the page-crossing
/// address bits vary.
const NUM_LINES: usize = 1024;

/// One cache line of storage, holding the flag in its first byte.
#[repr(align(64))]
struct Line {
    flag: AtomicBool,
    _pad: [u8; LINE_BYTES - 1],
}

/// How the waiting thread spins.
#[derive(Clone, Copy, PartialEq, Eq, Debug, clap::ArgEnum)]
pub enum SpinMode {
    /// Retry the CAS itself. Every attempt is a locked read-modify-write, so on
    /// x86 a failing attempt costs about as much as a successful one and takes
    /// the line away from the other core while it is trying to flip the flag.
    Bare,
    /// Test-and-test-and-set: spin on a relaxed load and only attempt the CAS
    /// once the flag reads the expected value. The load hits locally in the
    /// Shared state and generates no interconnect traffic, which removes that
    /// interference.
    Ttas,
}

impl fmt::Display for SpinMode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            SpinMode::Bare => f.write_str("bare"),
            SpinMode::Ttas => f.write_str("ttas"),
        }
    }
}

pub struct Bench {
    barrier: Barrier,
    lines: Vec<Line>,
    slot: AtomicUsize,
    spin: SpinMode,
}

impl Bench {
    pub fn new(spin: SpinMode) -> Self {
        Self {
            barrier: Barrier::new(2),
            lines: (0..NUM_LINES)
                .map(|_| Line { flag: AtomicBool::new(PING), _pad: [0; LINE_BYTES - 1] })
                .collect(),
            slot: AtomicUsize::new(0),
            spin,
        }
    }

    /// Select which cache line to use as the shared flag. Wraps at NUM_LINES.
    pub fn set_slot(&self, slot: usize) {
        self.slot.store(slot % NUM_LINES, Ordering::Relaxed);
    }

    pub fn num_slots() -> usize { NUM_LINES }

    fn flag(&self) -> &AtomicBool {
        &self.lines[self.slot.load(Ordering::Relaxed)].flag
    }

    pub fn flag_addr(&self) -> *const AtomicBool {
        self.flag() as *const AtomicBool
    }
}

/// Spin on a load before attempting the CAS. See [`SpinMode::Ttas`].
#[inline(always)]
fn ttas_cas(flag: &AtomicBool, expected: bool) {
    loop {
        while flag.load(Ordering::Relaxed) != expected {}
        if flag.compare_exchange(expected, !expected, Ordering::Relaxed, Ordering::Relaxed).is_ok() {
            return;
        }
    }
}

/// Retry the CAS itself until it succeeds. See [`SpinMode::Bare`].
#[inline(always)]
fn bare_cas(flag: &AtomicBool, expected: bool) {
    while flag.compare_exchange(expected, !expected, Ordering::Relaxed, Ordering::Relaxed).is_err() {}
}

impl super::Bench for Bench {
    // The two threads modify the same cacheline.
    // This is useful to benchmark spinlock performance.
    fn run(
        &self,
        (ping_core, pong_core): (CoreId, CoreId),
        clock: &Clock,
        num_round_trips: Count,
        num_samples: Count,
    ) -> Vec<f64> {
        let state = self;

        crossbeam_utils::thread::scope(|s| {
            let pong = s.spawn(move |_| {
                core_affinity::set_for_current(pong_core);

                // Resolve the slot and the spin mode before the barrier so the
                // measured loop stays as tight as the original one.
                let flag = state.flag();
                let n = num_round_trips as u64 * num_samples as u64;

                state.barrier.wait();
                match state.spin {
                    SpinMode::Bare => for _ in 0..n { bare_cas(flag, PING) },
                    SpinMode::Ttas => for _ in 0..n { ttas_cas(flag, PING) },
                }
            });

            let ping = s.spawn(move |_| {
                core_affinity::set_for_current(ping_core);

                let flag = state.flag();
                let mut results = Vec::with_capacity(num_samples as usize);

                state.barrier.wait();

                for _ in 0..num_samples {
                    let start = clock.raw();
                    // The match is outside the inner loop, so the branch is
                    // amortized over num_round_trips.
                    match state.spin {
                        SpinMode::Bare => for _ in 0..num_round_trips { bare_cas(flag, PONG) },
                        SpinMode::Ttas => for _ in 0..num_round_trips { ttas_cas(flag, PONG) },
                    }
                    let end = clock.raw();
                    let duration = clock.delta(start, end).as_nanos();
                    results.push(duration as f64 / num_round_trips as f64 / 2.0);
                }

                results
            });

            pong.join().unwrap();
            ping.join().unwrap()
        }).unwrap()
    }
}
