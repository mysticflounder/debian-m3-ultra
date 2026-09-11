/* Bounded EL0 observation, not a feature detector. No floating C arithmetic. */
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>

#if defined(__aarch64__)
static uint64_t fpcr(void)
{
    uint64_t v;
    __asm__ volatile("mrs %0, fpcr" : "=r"(v) :: "memory");
    return v;
}
static uint64_t fpsr(void)
{
    uint64_t v;
    __asm__ volatile("mrs %0, fpsr" : "=r"(v) :: "memory");
    return v;
}
static void set_state(uint64_t control, uint64_t status)
{
    __asm__ volatile("msr fpcr, %0\n\tmsr fpsr, %1\n\tisb"
                     :: "r"(control), "r"(status) : "memory");
}
struct sample {
    uint32_t input, result;
    unsigned mode, op;
    uint64_t control, status;
};
#endif

int main(void)
{
#if !defined(__aarch64__)
    fputs("AArch64 required\n", stderr);
    return 2;
#else
    static const uint32_t inputs[] = {
        0x3f800000, 0x3fa00000, 0x3fc00000, 0x3fe00000,
        0x40000000, 0x40400000, 0x41200000
    };
    struct sample rows[28];
    unsigned n = 0;
    uint64_t saved_control = fpcr(), saved_status = fpsr();
    for (unsigned mode = 0; mode < 2; ++mode) {
        for (unsigned op = 0; op < 2; ++op) {
            for (unsigned i = 0; i < 7; ++i) {
                struct sample *r = &rows[n++];
                r->mode = mode;
                r->op = op;
                r->input = inputs[i];
                set_state((uint64_t)mode << 1, 0);
                r->control = fpcr();
                if (op == 0) {
                    __asm__ volatile("fmov s0, %w1\n\tfrecpe s0, s0\n\tfmov %w0, s0"
                                     : "=r"(r->result) : "r"(r->input)
                                     : "v0", "memory");
                } else {
                    __asm__ volatile("fmov s0, %w1\n\tfrsqrte s0, s0\n\tfmov %w0, s0"
                                     : "=r"(r->result) : "r"(r->input)
                                     : "v0", "memory");
                }
                r->status = fpsr();
            }
        }
    }
    set_state(saved_control, saved_status);
    uint64_t restored_control = fpcr(), restored_status = fpsr();
    int restored = saved_control == restored_control && saved_status == restored_status;
    /* All libc calls occur after restoration. */
    printf("{\"schema_version\":1,\"saved_fpcr\":\"0x%016" PRIx64
           "\",\"saved_fpsr\":\"0x%016" PRIx64
           "\",\"restored_fpcr\":\"0x%016" PRIx64
           "\",\"restored_fpsr\":\"0x%016" PRIx64
           "\",\"state_restored\":%s,\"samples\":[",
           saved_control, saved_status, restored_control, restored_status,
           restored ? "true" : "false");
    for (unsigned i = 0; i < n; ++i) {
        const struct sample *r = &rows[i];
        printf("%s{\"ah_requested\":%u,\"op\":\"%s\",\"input\":\"0x%08" PRIx32
               "\",\"result\":\"0x%08" PRIx32 "\",\"fpcr\":\"0x%016" PRIx64
               "\",\"fpsr\":\"0x%016" PRIx64 "\"}",
               i ? "," : "", r->mode, r->op ? "FRSQRTE" : "FRECPE",
               r->input, r->result, r->control, r->status);
    }
    puts("]}");
    return restored ? 0 : 1;
#endif
}
