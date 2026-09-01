/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * Optional AArch64 crypto instructions used by arm64-feature-behavior.c.
 *
 * Keep these probes in a separate translation unit so the baseline driver
 * remains runnable before its SIGILL containment fork is active.
 */

	.text
	.p2align 2

	/* void feature_test_aes(const uint8_t *, const uint8_t *, uint8_t *); */
	.global feature_test_aes
	.type feature_test_aes, %function
feature_test_aes:
	ldr	q0, [x0]
	ldr	q1, [x1]
	.inst	0x4e284820	/* aese v0.16b, v1.16b */
	.inst	0x4e286800	/* aesmc v0.16b, v0.16b */
	str	q0, [x2]
	ret
	.size feature_test_aes, .-feature_test_aes

	/* uint32_t feature_test_sha1(uint32_t); */
	.global feature_test_sha1
	.type feature_test_sha1, %function
feature_test_sha1:
	fmov	s0, w0
	.inst	0x5e280800	/* sha1h s0, s0 */
	fmov	w0, s0
	ret
	.size feature_test_sha1, .-feature_test_sha1

	/* void feature_test_sha2(const uint32_t *, const uint32_t *, uint32_t *); */
	.global feature_test_sha2
	.type feature_test_sha2, %function
feature_test_sha2:
	ldr	q0, [x0]
	ldr	q1, [x1]
	.inst	0x5e282820	/* sha256su0 v0.4s, v1.4s */
	str	q0, [x2]
	ret
	.size feature_test_sha2, .-feature_test_sha2

	/* void feature_test_sha3(const uint64_t *, const uint64_t *,
	 *                        const uint64_t *, uint64_t *); */
	.global feature_test_sha3
	.type feature_test_sha3, %function
feature_test_sha3:
	ldr	q0, [x0]
	ldr	q1, [x1]
	ldr	q2, [x2]
	.inst	0xce010800	/* eor3 v0.16b, v0.16b, v1.16b, v2.16b */
	str	q0, [x3]
	ret
	.size feature_test_sha3, .-feature_test_sha3

	/* void feature_test_sha512(const uint64_t *, const uint64_t *,
	 *                          uint64_t *); */
	.global feature_test_sha512
	.type feature_test_sha512, %function
feature_test_sha512:
	ldr	q0, [x0]
	ldr	q1, [x1]
	.inst	0xcec08020	/* sha512su0 v0.2d, v1.2d */
	str	q0, [x2]
	ret
	.size feature_test_sha512, .-feature_test_sha512

	.section .note.GNU-stack,"",%progbits
