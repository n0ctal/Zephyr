// ZephyrPower.kext — exposes the Intel package power limit to userspace.
//
// Intel's RAPL package power limit lives in MSR_PKG_POWER_LIMIT (0x610): PL1
// is the sustained ceiling the CPU is allowed to draw, PL2 the short burst
// above it. Lowering PL1 is the honest substitute for undervolting on a Mac
// built after 2018 — the undervolt MSR is locked by the firmware's Plundervolt
// mitigation (CVE-2019-11157), and no amount of ring 0 gets around that. The
// power limit is a different register and a documented, supported mechanism.
//
// MSRs are ring 0, so the read and the write have to live here. Userspace
// reaches them through two sysctls rather than an IOUserClient: a user client
// is several hundred lines of matching, lifecycle and serialisation for what
// is genuinely a pair of 64-bit numbers.
//
// Bit 63 of 0x610 is the lock bit. When the firmware has set it, writes are
// ignored by the hardware and there is nothing to be done about it — which is
// exactly why the read is exposed too. Read before promising anything.
//
// The value moves through SYSCTL_OUT / SYSCTL_IN rather than the tidier
// sysctl_io_number: that helper exists in the kernel binary but is not in the
// symbol set exported to kexts, so a bundle calling it fails to link at load
// time with "could not find a kext which exports this symbol". The macros
// resolve to function pointers carried inside the request itself, so they
// need nothing exported at all.

#include <mach/mach_types.h>
#include <sys/sysctl.h>
#include <sys/errno.h>
#include <i386/proc_reg.h>   // rdmsr64 / wrmsr64

#define MSR_RAPL_POWER_UNIT   0x606u
// The two counters that make an effective frequency. APERF advances with the
// clock the core is actually running at; MPERF advances at the fixed base
// rate. Their ratio over an interval, times the base frequency, is what the
// CPU averaged — which is the honest answer to "how fast is it going", and
// the only one available: macOS on Intel publishes no current frequency, and
// the registry carries the P-state ladder without saying which rung is in use.
#define MSR_IA32_MPERF        0x0E7u
#define MSR_IA32_APERF        0x0E8u
#define MSR_PKG_POWER_LIMIT   0x610u
#define MSR_PKG_POWER_INFO    0x614u

extern "C" {

void mp_rendezvous_no_intrs(void (*action_func)(void *), void *arg);
int cpu_number(void);

static uint64_t pending_limit = 0;

// Summed across every core, because a single core's ratio is whatever that
// core happened to be doing — read a parked one under load and the machine
// looks idle. Sixty-four is more logical processors than any Intel Mac has;
// the array costs half a kilobyte and removes a bound to get wrong.
#define ZEPHYR_MAX_CPUS 64
struct zephyr_perf_counters { uint64_t aperf; uint64_t mperf; };
static struct zephyr_perf_counters perf_per_cpu[ZEPHYR_MAX_CPUS];

static void read_perf_counters(void *)
{
    unsigned int cpu = cpu_number();
    if (cpu >= ZEPHYR_MAX_CPUS) { return; }
    // Back to back, on one core, with interrupts off: the pair is only
    // meaningful read together, and a gap between them is a gap in which the
    // core changes speed.
    perf_per_cpu[cpu].aperf = rdmsr64(MSR_IA32_APERF);
    perf_per_cpu[cpu].mperf = rdmsr64(MSR_IA32_MPERF);
}

// Package-scope registers only need one write, but the turbo bit next door is
// per-core and the two are easy to confuse later. Writing everywhere costs a
// rendezvous and removes the question.
static void write_limit_everywhere(void *)
{
    wrmsr64(MSR_PKG_POWER_LIMIT, pending_limit);
}

static int power_limit_sysctl(__unused struct sysctl_oid *oidp, __unused void *arg1,
                              __unused int arg2, struct sysctl_req *req)
{
    uint64_t current = rdmsr64(MSR_PKG_POWER_LIMIT);
    int error = SYSCTL_OUT(req, &current, sizeof(current));
    if (error != 0) {
        return error;
    }
    // A plain read carries no new value; nothing further to do.
    if (req->newptr == 0 || req->newlen == 0) {
        return 0;
    }
    if (req->newlen != sizeof(uint64_t)) {
        return EINVAL;
    }

    uint64_t requested = 0;
    error = SYSCTL_IN(req, &requested, sizeof(requested));
    if (error != 0) {
        return error;
    }

    // Refuse to touch the lock bit. Setting it is irreversible until the next
    // power cycle, and a userspace mistake must not be able to brick the
    // register for everything else on the machine.
    if (requested & (1ULL << 63)) {
        return EPERM;
    }
    if (current & (1ULL << 63)) {
        return EROFS;   // firmware already locked it; the write would be ignored
    }

    pending_limit = requested;
    mp_rendezvous_no_intrs(write_limit_everywhere, nullptr);
    return 0;
}

static int power_unit_sysctl(__unused struct sysctl_oid *oidp, __unused void *arg1,
                             __unused int arg2, struct sysctl_req *req)
{
    uint64_t value = rdmsr64(MSR_RAPL_POWER_UNIT);
    return SYSCTL_OUT(req, &value, sizeof(value));
}

static int power_info_sysctl(__unused struct sysctl_oid *oidp, __unused void *arg1,
                             __unused int arg2, struct sysctl_req *req)
{
    uint64_t value = rdmsr64(MSR_PKG_POWER_INFO);
    return SYSCTL_OUT(req, &value, sizeof(value));
}

// The summed counters, in one read.
//
// Two sysctls would mean two trips into the kernel with the cores running in
// between, so the ratio would be built from counters taken at different
// moments. The deltas are left to userspace: holding the previous sample here
// would make this a stateful register that answers differently depending on
// who read it last.
static int perf_counters_sysctl(__unused struct sysctl_oid *oidp, __unused void *arg1,
                                __unused int arg2, struct sysctl_req *req)
{
    for (int i = 0; i < ZEPHYR_MAX_CPUS; i++) {
        perf_per_cpu[i].aperf = 0;
        perf_per_cpu[i].mperf = 0;
    }
    mp_rendezvous_no_intrs(read_perf_counters, nullptr);

    struct zephyr_perf_counters total = { 0, 0 };
    for (int i = 0; i < ZEPHYR_MAX_CPUS; i++) {
        total.aperf += perf_per_cpu[i].aperf;
        total.mperf += perf_per_cpu[i].mperf;
    }
    return SYSCTL_OUT(req, &total, sizeof(total));
}

// Readable by anyone, writable only by root. Any local process being able to
// re-cap the CPU is not privilege escalation, but it is a lever that should
// not be lying around: the app reaches the write through its existing
// privileged helper instead.
SYSCTL_PROC(_kern, OID_AUTO, zephyr_power_limit,
            CTLTYPE_QUAD | CTLFLAG_RW | CTLFLAG_LOCKED,
            nullptr, 0, power_limit_sysctl, "Q", "Intel MSR_PKG_POWER_LIMIT (0x610)");

SYSCTL_PROC(_kern, OID_AUTO, zephyr_power_unit,
            CTLTYPE_QUAD | CTLFLAG_RD | CTLFLAG_LOCKED | CTLFLAG_ANYBODY,
            nullptr, 0, power_unit_sysctl, "Q", "Intel MSR_RAPL_POWER_UNIT (0x606)");

SYSCTL_PROC(_kern, OID_AUTO, zephyr_power_info,
            CTLTYPE_QUAD | CTLFLAG_RD | CTLFLAG_LOCKED | CTLFLAG_ANYBODY,
            nullptr, 0, power_info_sysctl, "Q", "Intel MSR_PKG_POWER_INFO (0x614)");

SYSCTL_PROC(_kern, OID_AUTO, zephyr_perf_counters,
            CTLTYPE_OPAQUE | CTLFLAG_RD | CTLFLAG_LOCKED | CTLFLAG_ANYBODY,
            nullptr, 0, perf_counters_sysctl, "S,zephyr_perf_counters",
            "Summed IA32_APERF and IA32_MPERF across every core");

static kern_return_t power_start(kmod_info_t *, void *)
{
    sysctl_register_oid(&sysctl__kern_zephyr_power_limit);
    sysctl_register_oid(&sysctl__kern_zephyr_power_unit);
    sysctl_register_oid(&sysctl__kern_zephyr_power_info);
    sysctl_register_oid(&sysctl__kern_zephyr_perf_counters);
    return KERN_SUCCESS;
}

static kern_return_t power_stop(kmod_info_t *, void *)
{
    sysctl_unregister_oid(&sysctl__kern_zephyr_perf_counters);
    sysctl_unregister_oid(&sysctl__kern_zephyr_power_info);
    sysctl_unregister_oid(&sysctl__kern_zephyr_power_unit);
    sysctl_unregister_oid(&sysctl__kern_zephyr_power_limit);
    return KERN_SUCCESS;
}

KMOD_EXPLICIT_DECL(com.n0ctal.ZephyrPower, "1.0.0", power_start, power_stop)

__private_extern__ kmod_start_func_t *_realmain = power_start;
__private_extern__ kmod_stop_func_t  *_antimain = power_stop;

} // extern "C"
