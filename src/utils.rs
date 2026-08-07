use std::time::Duration;
use quanta::Clock;
use crate::bench::Count;

pub fn black_box<T>(dummy: T) -> T {
    unsafe { std::ptr::read_volatile(&dummy) }
}

pub fn delay_cycles(num_iterations: usize) {
    static VALUE: usize = 0;
    for _ in 0..num_iterations {
        // unsafe { std::arch::asm!("nop"); } might not work on all platforms
        black_box(&VALUE);
    }
}

// Returns the duration of doing `num_iterations` of clock.raw()
pub fn clock_read_overhead_sum(clock: &Clock, num_iterations: Count) -> Duration {
    let start = clock.raw();
    for _ in 0..(num_iterations-1) {
        black_box(clock.raw());
    }
    let end = clock.raw();
    clock.delta(start, end)
}

// This big feature condition is on CpuId::default(), we'll use the same.
#[cfg(any(
    all(target_arch = "x86", not(target_env = "sgx"), target_feature = "sse"),
    all(target_arch = "x86_64", not(target_env = "sgx"))
))]
pub fn get_cpuid() -> Option<raw_cpuid::CpuId> {
    Some(raw_cpuid::CpuId::default())
}

#[cfg(not(any(
    all(target_arch = "x86", not(target_env = "sgx"), target_feature = "sse"),
    all(target_arch = "x86_64", not(target_env = "sgx"))
)))]
pub fn get_cpuid() -> Option<raw_cpuid::CpuId> {
    None
}

pub fn assert_rdtsc_usable(clock: &quanta::Clock) {
    let cpuid = get_cpuid().expect("This benchmark is only compatible with x86");

    assert!(cpuid.get_advanced_power_mgmt_info().expect("CPUID failed").has_invariant_tsc(),
        "This benchmark only runs with a TscInvariant=true");

    const NUM_ITERS: Count = 10_000;
    let clock_read_overhead = clock_read_overhead_sum(&clock, NUM_ITERS).as_nanos() as f64 / NUM_ITERS as f64;
    eprintln!("Reading the clock via RDTSC takes {:.2}ns", clock_read_overhead);
    assert!((0.1..1000.0).contains(&clock_read_overhead), "The timing to read the clock is either not-consistant or too slow");
}

pub fn get_cpu_brand() -> Option<String> {
    get_cpuid()
        .and_then(|c| c.get_processor_brand_string())
        .map(|c| c.as_str().to_string())
}

/// Translate a virtual address to a physical one via /proc/self/pagemap.
///
/// Where a cache line is tracked follows from its *physical* address, so this is
/// what makes a `--slot` sweep interpretable. Needs CAP_SYS_ADMIN; returns None
/// when we can't read it (non-root, non-Linux, page not present).
#[cfg(target_os = "linux")]
pub fn virt_to_phys(virt: usize) -> Option<u64> {
    use std::io::{Read, Seek, SeekFrom};

    let page_size = 4096;
    let mut f = std::fs::File::open("/proc/self/pagemap").ok()?;
    f.seek(SeekFrom::Start((virt / page_size * 8) as u64)).ok()?;
    let mut buf = [0u8; 8];
    f.read_exact(&mut buf).ok()?;
    let entry = u64::from_ne_bytes(buf);

    // Bit 63 is "page present"; bits 0..55 hold the page frame number.
    if entry & (1 << 63) == 0 {
        return None;
    }
    let pfn = entry & ((1 << 55) - 1);
    if pfn == 0 {
        return None; // Redacted, we don't have the privileges.
    }
    Some(pfn * page_size as u64 + (virt % page_size) as u64)
}

#[cfg(not(target_os = "linux"))]
pub fn virt_to_phys(_virt: usize) -> Option<u64> { None }

pub fn show_cpuid_info() {
    if let Some(brand) = get_cpu_brand() {
        eprintln!("CPU: {}", brand);
    }
}
