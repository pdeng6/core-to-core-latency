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

/// Lines are grouped into page-aligned pages so that slot numbering lines up with
/// the physical layout: slot N is line N%64 of page N/64, and a page boundary
/// falls exactly between slot 63 and 64. Without the alignment the allocation
/// starts partway into a page, putting the boundaries at arbitrary slots.
const PAGE_BYTES: usize = 4096;
const LINES_PER_PAGE: usize = PAGE_BYTES / LINE_BYTES;

/// How many pages to allocate. Slots span 16 pages, so both the offset within a
/// page and the page itself vary across a sweep.
///
/// At 64KiB the allocation is also far below the 2MiB a transparent hugepage
/// covers, so THP does not kick in and every page keeps its own frame -- which
/// is what spreads the slots across physical memory. Verified by reading back
/// the frames on a host with THP set to `always`: all 16 pages landed in
/// distinct 2MiB frames, none of them consecutive, identical with and without
/// MADV_NOHUGEPAGE. Growing this past 2MiB would forfeit that.
const NUM_PAGES: usize = 16;
const NUM_LINES: usize = NUM_PAGES * LINES_PER_PAGE;

/// One cache line of storage, holding the flag in its first byte.
#[repr(align(64))]
struct Line {
    flag: AtomicBool,
    _pad: [u8; LINE_BYTES - 1],
}

/// A page's worth of lines. `Vec` allocates at the element's alignment, so a
/// `Vec<Page>` is page-aligned without any unsafe code.
///
/// `repr(align(..))` takes a literal, so the 4096 here cannot be written in terms
/// of PAGE_BYTES; the assertions below tie them together instead.
#[repr(align(4096))]
struct Page {
    lines: [Line; LINES_PER_PAGE],
}

const _: () = {
    assert!(std::mem::size_of::<Line>() == LINE_BYTES);
    assert!(std::mem::align_of::<Line>() == LINE_BYTES);
    assert!(std::mem::size_of::<Page>() == PAGE_BYTES);
    assert!(std::mem::align_of::<Page>() == PAGE_BYTES);
};

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
    pages: Vec<Page>,
    slot: AtomicUsize,
    spin: SpinMode,
    pause_count: u32,
}

impl Bench {
    pub fn new(spin: SpinMode, pause_count: u32) -> Self {
        let new_page = || Page {
            lines: std::array::from_fn(|_| Line {
                flag: AtomicBool::new(PING),
                _pad: [0; LINE_BYTES - 1],
            }),
        };
        // Nothing needed here to keep THP out of the way; see NUM_PAGES.
        let pages: Vec<Page> = (0..NUM_PAGES).map(|_| new_page()).collect();

        Self {
            barrier: Barrier::new(2),
            pages,
            slot: AtomicUsize::new(0),
            spin,
            pause_count,
        }
    }

    /// Select which cache line to use as the shared flag. Wraps at NUM_LINES.
    pub fn set_slot(&self, slot: usize) {
        self.slot.store(slot % NUM_LINES, Ordering::Relaxed);
    }

    pub fn num_slots() -> usize { NUM_LINES }

    fn flag(&self) -> &AtomicBool {
        let slot = self.slot.load(Ordering::Relaxed);
        &self.pages[slot / LINES_PER_PAGE].lines[slot % LINES_PER_PAGE].flag
    }

    pub fn flag_addr(&self) -> *const AtomicBool {
        self.flag() as *const AtomicBool
    }
}

#[inline(always)]
fn do_pause(n: u32) {
    for _ in 0..n {
        unsafe { std::arch::x86_64::_mm_pause() };
    }
}

/// Spin on a load before attempting the CAS. See [`SpinMode::Ttas`].
#[inline(always)]
fn ttas_cas(flag: &AtomicBool, expected: bool, pause_count: u32) {
    loop {
        while flag.load(Ordering::Relaxed) != expected {}
        if flag.compare_exchange(expected, !expected, Ordering::Relaxed, Ordering::Relaxed).is_ok() {
            do_pause(pause_count);
            return;
        }
    }
}

/// Retry the CAS itself until it succeeds. See [`SpinMode::Bare`].
#[inline(always)]
fn bare_cas(flag: &AtomicBool, expected: bool, pause_count: u32) {
    while flag.compare_exchange(expected, !expected, Ordering::Relaxed, Ordering::Relaxed).is_err() {}
    do_pause(pause_count);
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

                let pc = state.pause_count;
                state.barrier.wait();
                match state.spin {
                    SpinMode::Bare => for _ in 0..n { bare_cas(flag, PING, pc) },
                    SpinMode::Ttas => for _ in 0..n { ttas_cas(flag, PING, pc) },
                }
            });

            let ping = s.spawn(move |_| {
                core_affinity::set_for_current(ping_core);

                let flag = state.flag();
                let mut results = Vec::with_capacity(num_samples as usize);

                state.barrier.wait();

                let pc = state.pause_count;
                for _ in 0..num_samples {
                    let start = clock.raw();
                    match state.spin {
                        SpinMode::Bare => for _ in 0..num_round_trips { bare_cas(flag, PONG, pc) },
                        SpinMode::Ttas => for _ in 0..num_round_trips { ttas_cas(flag, PONG, pc) },
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
