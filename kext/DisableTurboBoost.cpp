// DisableTurboBoost.kext — minimal generic kernel extension.
//
// Intel Turbo Boost is controlled by bit 38 ("Turbo Mode Disable") of the
// IA32_MISC_ENABLE MSR (0x1A0). Writing MSRs is a ring-0 operation, so this
// must live in the kernel. The bit must be set consistently on every logical
// CPU, which we do via mp_rendezvous_no_intrs (runs an action on all cores).
//
// Model (same as Turbo Boost Switcher's kext): loading the kext disables
// Turbo Boost; unloading re-enables it. The privileged helper toggles by
// loading / unloading this bundle.

#include <mach/mach_types.h>
#include <i386/proc_reg.h>   // rdmsr64 / wrmsr64

#define IA32_MISC_ENABLE   0x1A0u
#define TURBO_DISABLE_BIT  (1ULL << 38)

extern "C" {

// Exported by the kernel (com.apple.kpi.unsupported); not in public headers.
void mp_rendezvous_no_intrs(void (*action_func)(void *), void *arg);

// Per-core actions.
static void apply_turbo_disable(void *)
{
    uint64_t value = rdmsr64(IA32_MISC_ENABLE);
    value |= TURBO_DISABLE_BIT;
    wrmsr64(IA32_MISC_ENABLE, value);
}

static void apply_turbo_enable(void *)
{
    uint64_t value = rdmsr64(IA32_MISC_ENABLE);
    value &= ~TURBO_DISABLE_BIT;
    wrmsr64(IA32_MISC_ENABLE, value);
}

static kern_return_t turbo_start(kmod_info_t *, void *)
{
    mp_rendezvous_no_intrs(apply_turbo_disable, nullptr);
    return KERN_SUCCESS;
}

static kern_return_t turbo_stop(kmod_info_t *, void *)
{
    mp_rendezvous_no_intrs(apply_turbo_enable, nullptr);
    return KERN_SUCCESS;
}

// kmod_info structure (name + version must match Info.plist exactly).
KMOD_EXPLICIT_DECL(com.n0ctal.DisableTurboBoost, "1.0.0", turbo_start, turbo_stop)

// libkmod.a's _start/_stop entry points dereference these.
__private_extern__ kmod_start_func_t *_realmain = turbo_start;
__private_extern__ kmod_stop_func_t  *_antimain = turbo_stop;

} // extern "C"
