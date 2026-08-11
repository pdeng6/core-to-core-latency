#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static inline uint64_t rdtsc(void)
{
	unsigned int lo, hi;
	__asm__ volatile ("rdtsc" : "=a"(lo), "=d"(hi));
	return ((uint64_t)hi << 32) | lo;
}

static inline void do_pause(void)
{
	__asm__ volatile ("pause");
}

/* 1024 dependent adds: each "add $1,%eax" is 1 cycle with a true data
 * dependency on the previous one, so the whole block is exactly 1024 core
 * cycles regardless of frequency. By measuring the wall time (via rdtsc) we
 * can derive the actual core frequency without needing rdpmc or perf.
 *
 * Using "add $1" rather than "add %eax,%eax" to avoid any zero-idiom
 * elimination the microarchitecture might apply when the register is zero. */
#define DEP_ADD_8 \
	"add $1, %%eax\n\t" "add $1, %%eax\n\t" \
	"add $1, %%eax\n\t" "add $1, %%eax\n\t" \
	"add $1, %%eax\n\t" "add $1, %%eax\n\t" \
	"add $1, %%eax\n\t" "add $1, %%eax\n\t"

#define DEP_ADD_64  DEP_ADD_8 DEP_ADD_8 DEP_ADD_8 DEP_ADD_8 \
                    DEP_ADD_8 DEP_ADD_8 DEP_ADD_8 DEP_ADD_8

#define DEP_ADD_256 DEP_ADD_64 DEP_ADD_64 DEP_ADD_64 DEP_ADD_64

#define DEP_ADD_1024 DEP_ADD_256 DEP_ADD_256 DEP_ADD_256 DEP_ADD_256

/* Measure actual core frequency by timing the known-cycle dep-add block.
 * The asm block runs 1024 dependent adds inside a loop, with the dependency
 * chain carried across iterations via %eax. The loop counter uses a separate
 * register so sub+jne execute in parallel with the adds and contribute zero
 * extra cycles to the critical path. */
static double measure_core_freq_hz(long loops)
{
	register long i;

	/* warmup */
	__asm__ volatile (
		"xor %%eax, %%eax\n\t"
		"mov %1, %0\n\t"
		"1:\n\t"
		DEP_ADD_1024
		"dec %0\n\t"
		"jnz 1b\n\t"
		: "=&r"(i)
		: "r"((long)100)
		: "eax", "cc"
	);

	uint64_t start = rdtsc();
	__asm__ volatile (
		"xor %%eax, %%eax\n\t"
		"mov %1, %0\n\t"
		"1:\n\t"
		DEP_ADD_1024
		"dec %0\n\t"
		"jnz 1b\n\t"
		: "=&r"(i)
		: "r"(loops)
		: "eax", "cc"
	);
	uint64_t end = rdtsc();

	return (double)(end - start) / loops;  /* tsc cycles per 1024 core-cycles */
}

/* Get the TSC frequency from sysfs/dmesg. */
static double get_tsc_freq_hz(void)
{
	FILE *f;
	char buf[256];
	double val;

	f = fopen("/sys/devices/system/cpu/cpu0/tsc_freq_khz", "r");
	if (f) {
		if (fscanf(f, "%lf", &val) == 1 && val > 0) {
			fclose(f);
			return val * 1000.0;
		}
		fclose(f);
	}

	f = popen("dmesg 2>/dev/null", "r");
	if (f) {
		double found = 0;
		while (fgets(buf, sizeof(buf), f)) {
			char *p = strstr(buf, "tsc: Detected");
			if (p && sscanf(p, "tsc: Detected %lf MHz", &val) == 1)
				found = val;
		}
		pclose(f);
		if (found > 0)
			return found * 1e6;
	}

	f = fopen("/sys/devices/system/cpu/cpu0/cpufreq/base_frequency", "r");
	if (f) {
		if (fscanf(f, "%lf", &val) == 1 && val > 0) {
			fclose(f);
			return val * 1000.0;
		}
		fclose(f);
	}

	f = fopen("/proc/cpuinfo", "r");
	if (f) {
		while (fgets(buf, sizeof(buf), f)) {
			if (sscanf(buf, "cpu MHz : %lf", &val) == 1) {
				fclose(f);
				fprintf(stderr, "warning: using cpuinfo MHz (%.0f) as TSC freq "
						"-- may be inaccurate\n", val);
				return val * 1e6;
			}
		}
		fclose(f);
	}
	return 0;
}

int main(int argc, char **argv)
{
	long n = 10000000;
	if (argc > 1)
		n = atol(argv[1]);
	if (n <= 0) {
		fprintf(stderr, "usage: %s [iterations]\n", argv[0]);
		return 1;
	}

	double tsc_hz = get_tsc_freq_hz();
	if (tsc_hz <= 0) {
		fprintf(stderr, "error: could not determine TSC frequency\n");
		return 1;
	}

	/* Step 1: measure core frequency via dependent adds */
	long freq_loops = 100000;
	double tsc_per_1024 = measure_core_freq_hz(freq_loops);
	double core_freq_hz = 1024.0 / (tsc_per_1024 / tsc_hz);
	printf("--- frequency calibration (1024 dependent adds = 1024 core cycles) ---\n");
	printf("tsc_freq:    %.0f Hz\n", tsc_hz);
	printf("core_freq:   %.0f Hz (measured)\n", core_freq_hz);
	printf("core/tsc:    %.4f\n", core_freq_hz / tsc_hz);
	printf("\n");

	/* Step 2: measure PAUSE */
	/* warmup */
	for (long i = 0; i < 1000; i++)
		do_pause();

	uint64_t start = rdtsc();
	for (long i = 0; i < n; i++)
		do_pause();
	uint64_t end = rdtsc();

	double tsc_per_pause = (double)(end - start) / n;
	double ns_per_pause = tsc_per_pause / tsc_hz * 1e9;
	double core_cycles_per_pause = tsc_per_pause * (core_freq_hz / tsc_hz);

	printf("--- PAUSE latency ---\n");
	printf("iterations:        %ld\n", n);
	printf("ns/PAUSE:          %.2f\n", ns_per_pause);
	printf("core_cycles/PAUSE: %.2f\n", core_cycles_per_pause);

	return 0;
}

