/*
 * Integer oracle for the positive-normal FP32 cases in arm64-rpres-probe.c.
 *
 * This is deliberately QEMU-derived, not an independent architectural proof.
 * It mirrors qemu/target/arm/tcg/vfp_helper.c at QEMU revision
 * 789e3d805f9ca84e64c40fe1b99129336ce911b8:
 *   recip_estimate(), recip_estimate_incprec(),
 *   do_recip_sqrt_estimate(), do_recip_sqrt_estimate_incprec(),
 *   call_recip_estimate(), recip_sqrt_estimate(), do_recpe_f32(), and
 *   do_rsqrte_f32().  Scope is limited to the seven fixed positive-normal
 *   inputs listed in main(); this fixture is not a general FP32 implementation.
 * No host floating-point arithmetic is used.
 *
 * The mirrored QEMU source is LGPL-2.1-or-later, with the following notice:
 *
 * Copyright (c) 2003 Fabrice Bellard
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public License
 * as published by the Free Software Foundation; either version 2.1
 * of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, see
 * <http://www.gnu.org/licenses/>.
 */
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>

static unsigned recip_estimate(unsigned input)
{
    unsigned a = input * 2 + 1;
    unsigned b = (1u << 19) / a;
    return (b + 1) >> 1;
}

static unsigned recip_estimate_incprec(unsigned input)
{
    unsigned a = input * 2 + 1;
    unsigned b = (1u << 26) / a;
    return (b + 1) >> 1;
}

static unsigned rsqrt_estimate(unsigned a)
{
    uint64_t b;
    if (a < 256) {
        a = a * 2 + 1;
    } else {
        a = (a >> 1) << 1;
        a = (a + 1) * 2;
    }
    b = 512;
    while ((uint64_t)a * (b + 1) * (b + 1) < (1ULL << 28)) {
        ++b;
    }
    return (unsigned)((b + 1) / 2);
}

static unsigned rsqrt_estimate_incprec(unsigned a)
{
    uint64_t b;
    if (a < 2048) {
        a = a * 2 + 1;
    } else {
        a = (a >> 1) << 1;
        a = (a + 1) * 2;
    }
    b = 8192;
    while ((uint64_t)a * (b + 1) * (b + 1) < (1ULL << 39)) {
        ++b;
    }
    return (unsigned)((b + 1) / 2);
}

static uint32_t frecpe(uint32_t bits, int rpres)
{
    unsigned exp = (bits >> 23) & 0xff;
    uint32_t frac = bits & 0x7fffff;
    unsigned scaled, estimate;
    int result_exp;

    if (rpres) {
        scaled = (1u << 11) | ((frac >> 12) & 0x7ff);
        estimate = recip_estimate_incprec(scaled);
        result_exp = 253 - (int)exp;
        /* result_frac = estimate << 40; output keeps bits 51:29. */
        return ((uint32_t)result_exp << 23) |
               ((estimate & 0xfff) << 11);
    }

    scaled = (1u << 8) | ((frac >> 15) & 0xff);
    estimate = recip_estimate(scaled);
    result_exp = 253 - (int)exp;
    /* result_frac = estimate << 44; output keeps bits 51:29. */
    return ((uint32_t)result_exp << 23) |
           ((estimate & 0xff) << 15);
}

static uint32_t frsqrte(uint32_t bits, int rpres)
{
    unsigned exp = (bits >> 23) & 0xff;
    uint32_t frac = bits & 0x7fffff;
    unsigned scaled, estimate;
    int result_exp = (380 - (int)exp) / 2;

    if (rpres) {
        if (exp & 1) {
            scaled = (1u << 10) | ((frac >> 13) & 0x3ff);
        } else {
            scaled = (1u << 11) | ((frac >> 12) & 0x7ff);
        }
        estimate = rsqrt_estimate_incprec(scaled);
        return ((uint32_t)result_exp << 23) |
               ((estimate & 0xfff) << 11);
    }

    if (exp & 1) {
        scaled = (1u << 7) | ((frac >> 16) & 0x7f);
    } else {
        scaled = (1u << 8) | ((frac >> 15) & 0xff);
    }
    estimate = rsqrt_estimate(scaled);
    return ((uint32_t)result_exp << 23) |
           ((estimate & 0xff) << 15);
}

int main(void)
{
    static const uint32_t inputs[] = {
        0x3f800000, 0x3fa00000, 0x3fc00000, 0x3fe00000,
        0x40000000, 0x40400000, 0x41200000,
    };

    puts("{\"schema_version\":1,\"oracle\":\"qemu-vfp-helper-integer\",\"samples\":[");
    unsigned n = 0;
    for (unsigned ah = 0; ah < 2; ++ah) {
        for (unsigned op = 0; op < 2; ++op) {
            for (unsigned i = 0; i < sizeof(inputs) / sizeof(inputs[0]); ++i) {
                uint32_t result = op ? frsqrte(inputs[i], ah) : frecpe(inputs[i], ah);
                printf("%s{\"ah_requested\":%u,\"op\":\"%s\","
                       "\"input\":\"0x%08" PRIx32 "\","
                       "\"result\":\"0x%08" PRIx32 "\"}",
                       n++ ? "," : "", ah, op ? "FRSQRTE" : "FRECPE",
                       inputs[i], result);
            }
        }
    }
    puts("]}");
    return 0;
}
