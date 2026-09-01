/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * Optional AArch64 instructions used by arm64-feature-behavior.c.
 *
 * Keep this translation unit separate from the baseline Armv8-A driver so a
 * compiler cannot introduce an advertised extension before the SIGILL
 * containment fork is active.
 */

	.text
	.arch armv8.5-a+crypto+crc+pauth
	.p2align 2

	.global feature_test_fp_add
	.type feature_test_fp_add, %function
feature_test_fp_add:
	fmov	d0, x0
	fmov	d1, x1
	fadd	d0, d0, d1
	fmov	x0, d0
	ret
	.size feature_test_fp_add, .-feature_test_fp_add

	.global feature_test_asimd_add
	.type feature_test_asimd_add, %function
feature_test_asimd_add:
	ldr	q0, [x0]
	ldr	q1, [x1]
	add	v0.4s, v0.4s, v1.4s
	str	q0, [x2]
	ret
	.size feature_test_asimd_add, .-feature_test_asimd_add

	.global feature_test_crc32c_u64
	.type feature_test_crc32c_u64, %function
feature_test_crc32c_u64:
	crc32cx	w0, w0, x1
	ret
	.size feature_test_crc32c_u64, .-feature_test_crc32c_u64

	.global feature_test_pmull_u64
	.type feature_test_pmull_u64, %function
feature_test_pmull_u64:
	fmov	d0, x0
	fmov	d1, x1
	pmull	v0.1q, v0.1d, v1.1d
	str	q0, [x2]
	ret
	.size feature_test_pmull_u64, .-feature_test_pmull_u64

	.global feature_test_lse_ldaddal
	.type feature_test_lse_ldaddal, %function
feature_test_lse_ldaddal:
	ldaddal	x0, x2, [x1]
	mov	x0, x2
	ret
	.size feature_test_lse_ldaddal, .-feature_test_lse_ldaddal

	.global feature_test_ldapr
	.type feature_test_ldapr, %function
feature_test_ldapr:
	ldapr	x0, [x0]
	ret
	.size feature_test_ldapr, .-feature_test_ldapr

	.global feature_test_ldapur
	.type feature_test_ldapur, %function
feature_test_ldapur:
	ldapur	x0, [x0]
	ret
	.size feature_test_ldapur, .-feature_test_ldapur

	.global feature_test_cfinv
	.type feature_test_cfinv, %function
feature_test_cfinv:
	mrs	x1, nzcv
	msr	nzcv, xzr
	cfinv
	mrs	x0, nzcv
	msr	nzcv, x1
	ubfx	x0, x0, #29, #1
	ret
	.size feature_test_cfinv, .-feature_test_cfinv

	.global feature_test_sb
	.type feature_test_sb, %function
feature_test_sb:
	sb
	mov	x0, #1
	ret
	.size feature_test_sb, .-feature_test_sb

	.global feature_test_dit_toggle
	.type feature_test_dit_toggle, %function
feature_test_dit_toggle:
	mrs	x1, dit
	eor	x2, x1, #(1 << 24)
	msr	dit, x2
	isb
	mrs	x0, dit
	msr	dit, x1
	isb
	eor	x0, x0, x2
	tst	x0, #(1 << 24)
	cset	x0, eq
	ret
	.size feature_test_dit_toggle, .-feature_test_dit_toggle

	.global feature_test_paca_roundtrip
	.type feature_test_paca_roundtrip, %function
feature_test_paca_roundtrip:
	mov	x3, x0
	pacia	x0, x1
	str	x0, [x2]
	autia	x0, x1
	cmp	x0, x3
	cset	x0, eq
	ret
	.size feature_test_paca_roundtrip, .-feature_test_paca_roundtrip

	.global feature_test_pacga
	.type feature_test_pacga, %function
feature_test_pacga:
	pacga	x0, x0, x1
	mov	x0, #1
	ret
	.size feature_test_pacga, .-feature_test_pacga

	.global feature_test_dc_zva
	.type feature_test_dc_zva, %function
feature_test_dc_zva:
	dc	zva, x0
	dsb	sy
	ret
	.size feature_test_dc_zva, .-feature_test_dc_zva

	.global feature_test_dc_cvap
	.type feature_test_dc_cvap, %function
feature_test_dc_cvap:
	dc	cvap, x0
	dsb	sy
	mov	x0, #1
	ret
	.size feature_test_dc_cvap, .-feature_test_dc_cvap

	.global feature_test_dc_cvadp
	.type feature_test_dc_cvadp, %function
feature_test_dc_cvadp:
	dc	cvadp, x0
	dsb	sy
	mov	x0, #1
	ret
	.size feature_test_dc_cvadp, .-feature_test_dc_cvadp

	.section .note.GNU-stack,"",%progbits
