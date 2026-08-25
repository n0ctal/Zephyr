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

#include <mach/mach_types.h>
#include <sys/sysctl.h>
#include <i386/proc_reg.h>   // rdmsr64 / wrmsr64

#define MSR_RAPL_POWER_UNIT   0x606u
#define MSR_PKG_POWER_LIMIT   0x610u
#define MSR_PKG_POWER_INFO    0x614u

extern "C" {

void mp_rendezvous_no_intrs(void (*action_func)(void *), void *arg);

static uint64_t pending_limit = 0;

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
    int changed = 0;
    uint64_t requested = current;

    int error = sysctl_io_number(req, (long long)current, sizeof(current), &requested, &changed);
    if (error != 0 || changed == 0) {
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
    return sysctl_io_number(req, (long long)value, sizeof(value), nullptr, nullptr);
}

static int power_info_sysctl(__unused struct sysctl_oid *oidp, __unused void *arg1,
                             __unused int arg2, struct sysctl_req *req)
{
    uint64_t value = rdmsr64(MSR_PKG_POWER_INFO);
    return sysctl_io_number(req, (long long)value, sizeof(value), nullptr, nullptr);
}

SYSCTL_PROC(_kern, OID_AUTO, zephyr_power_limit,
            CTLTYPE_QUAD | CTLFLAG_RW | CTLFLAG_LOCKED | CTLFLAG_ANYBODY,
            nullptr, 0, power_limit_sysctl, "Q", "Intel MSR_PKG_POWER_LIMIT (0x610)");

SYSCTL_PROC(_kern, OID_AUTO, zephyr_power_unit,
            CTLTYPE_QUAD | CTLFLAG_RD | CTLFLAG_LOCKED | CTLFLAG_ANYBODY,
            nullptr, 0, power_unit_sysctl, "Q", "Intel MSR_RAPL_POWER_UNIT (0x606)");

SYSCTL_PROC(_kern, OID_AUTO, zephyr_power_info,
            CTLTYPE_QUAD | CTLFLAG_RD | CTLFLAG_LOCKED | CTLFLAG_ANYBODY,
            nullptr, 0, power_info_sysctl, "Q", "Intel MSR_PKG_POWER_INFO (0x614)");

static kern_return_t power_start(kmod_info_t *, void *)
{
    sysctl_register_oid(&sysctl__kern_zephyr_power_limit);
    sysctl_register_oid(&sysctl__kern_zephyr_power_unit);
    sysctl_register_oid(&sysctl__kern_zephyr_power_info);
    return KERN_SUCCESS;
}

static kern_return_t power_stop(kmod_info_t *, void *)
{
    sysctl_unregister_oid(&sysctl__kern_zephyr_power_info);
    sysctl_unregister_oid(&sysctl__kern_zephyr_power_unit);
    sysctl_unregister_oid(&sysctl__kern_zephyr_power_limit);
    return KERN_SUCCESS;
}

KMOD_EXPLICIT_DECL(com.n0ctal.ZephyrPower, "1.0.0", power_start, power_stop)

__private_extern__ kmod_start_func_t *_realmain = power_start;
__private_extern__ kmod_stop_func_t  *_antimain = power_stop;

} // extern "C"
