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
