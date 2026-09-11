/* Exercise restoration from non-default rounding and sticky exception state. */
#define main rpres_probe_main
#include "arm64-rpres-probe.c"
#undef main

int main(void)
{
#if !defined(__aarch64__)
    return 2;
#else
    const uint64_t control = UINT64_C(1) << 22; /* Round towards +infinity. */
    const uint64_t status = UINT64_C(0x11); /* IOC and IXC sticky flags. */
    uint64_t original_control = fpcr(), original_status = fpsr();
    set_state(control, status);
    if (fpcr() != control || fpsr() != status) {
        set_state(original_control, original_status);
        return 3;
    }
    int rc = rpres_probe_main();
    int preserved = fpcr() == control && fpsr() == status;
    set_state(original_control, original_status);
    return rc ? rc : (preserved ? 0 : 4);
#endif
}
