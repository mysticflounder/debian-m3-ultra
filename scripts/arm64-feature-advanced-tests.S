/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * Optional non-cryptographic AArch64 instructions used by
 * arm64-feature-behavior.c.  These leaf wrappers are kept out of the
 * baseline translation unit so each instruction executes inside the
 * driver's SIGILL/SIGALRM containment child.
 */

	.text
	.arch armv8.6-a
	.arch_extension fp16fml
	.p2align 2

	.global feature_test_evtstrm
	.type feature_test_evtstrm, %function
feature_test_evtstrm:
	sevl
	wfe
	wfe
	mov	x0, #1
	ret
	.size feature_test_evtstrm, .-feature_test_evtstrm

	.global feature_test_fphp
	.type feature_test_fphp, %function
feature_test_fphp:
	fmov	s0, w0
	fmov	s1, w1
	fadd	h0, h0, h1
	umov	w0, v0.h[0]
	ret
	.size feature_test_fphp, .-feature_test_fphp

	.global feature_test_asimdhp
	.type feature_test_asimdhp, %function
feature_test_asimdhp:
	ldr	q0, [x0]
	ldr	q1, [x1]
	fadd	v0.8h, v0.8h, v1.8h
	str	q0, [x2]
	ret
	.size feature_test_asimdhp, .-feature_test_asimdhp

	.global feature_test_cpuid
	.type feature_test_cpuid, %function
feature_test_cpuid:
	mrs	x0, id_aa64isar0_el1
	ret
	.size feature_test_cpuid, .-feature_test_cpuid

	.global feature_test_asimdrdm
	.type feature_test_asimdrdm, %function
feature_test_asimdrdm:
	fmov	s1, w0
	fmov	s2, w1
	movi	v0.4s, #0
	sqrdmlah	s0, s1, s2
	fmov	w0, s0
	ret
	.size feature_test_asimdrdm, .-feature_test_asimdrdm

	.global feature_test_jscvt
	.type feature_test_jscvt, %function
feature_test_jscvt:
	fmov	d0, x0
	fjcvtzs	w0, d0
	ret
	.size feature_test_jscvt, .-feature_test_jscvt

	.global feature_test_fcma
	.type feature_test_fcma, %function
feature_test_fcma:
	ldr	d0, [x0]
	ldr	d1, [x1]
	fcadd	v0.2s, v0.2s, v1.2s, #90
	str	d0, [x2]
	ret
	.size feature_test_fcma, .-feature_test_fcma

	.global feature_test_asimddp
	.type feature_test_asimddp, %function
feature_test_asimddp:
	movi	v0.4s, #0
	ldr	q1, [x0]
	ldr	q2, [x1]
	udot	v0.4s, v1.16b, v2.16b
	str	q0, [x2]
	ret
	.size feature_test_asimddp, .-feature_test_asimddp

	.global feature_test_asimdfhm
	.type feature_test_asimdfhm, %function
feature_test_asimdfhm:
	movi	v0.4s, #0
	ldr	d1, [x0]
	ldr	d2, [x1]
	fmlal	v0.4s, v1.4h, v2.4h
	str	q0, [x2]
	ret
	.size feature_test_asimdfhm, .-feature_test_asimdfhm

	.global feature_test_uscat
	.type feature_test_uscat, %function
feature_test_uscat:
	ldaddal	x0, x2, [x1]
	mov	x0, x2
	ret
	.size feature_test_uscat, .-feature_test_uscat

	.global feature_test_flagm2
	.type feature_test_flagm2, %function
feature_test_flagm2:
	mrs	x3, nzcv
	mov	x0, #0x30000000
	msr	nzcv, x0
	axflag
	mrs	x1, nzcv
	msr	nzcv, x0
	xaflag
	mrs	x2, nzcv
	msr	nzcv, x3
	lsl	x2, x2, #32
	orr	x0, x2, x1
	ret
	.size feature_test_flagm2, .-feature_test_flagm2

	.global feature_test_frint
	.type feature_test_frint, %function
feature_test_frint:
	fmov	d0, x0
	frint32z	d0, d0
	fmov	x0, d0
	ret
	.size feature_test_frint, .-feature_test_frint

	.global feature_test_i8mm
	.type feature_test_i8mm, %function
feature_test_i8mm:
	movi	v0.4s, #0
	ldr	q1, [x0]
	ldr	q2, [x1]
	smmla	v0.4s, v1.16b, v2.16b
	str	q0, [x2]
	ret
	.size feature_test_i8mm, .-feature_test_i8mm

	.global feature_test_bf16
	.type feature_test_bf16, %function
feature_test_bf16:
	movi	v0.4s, #0
	ldr	q1, [x0]
	ldr	q2, [x1]
	bfdot	v0.4s, v1.8h, v2.8h
	str	q0, [x2]
	ret
	.size feature_test_bf16, .-feature_test_bf16

	.global feature_test_bti
	.type feature_test_bti, %function
feature_test_bti:
	bti	c
	mov	x0, #1
	ret
	.size feature_test_bti, .-feature_test_bti

	.global feature_test_afp
	.type feature_test_afp, %function
feature_test_afp:
	mrs	x1, fpcr
	bic	x2, x1, #2
	msr	fpcr, x2
	isb
	mrs	x3, fpcr
	orr	x2, x1, #2
	msr	fpcr, x2
	isb
	mrs	x0, fpcr
	msr	fpcr, x1
	isb
	ubfx	x3, x3, #1, #1
	eor	x3, x3, #1
	ubfx	x0, x0, #1, #1
	and	x0, x0, x3
	ret
	.size feature_test_afp, .-feature_test_afp

	.section .note.GNU-stack,"",%progbits
