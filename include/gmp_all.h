/* SPDX-License-Identifier: LGPL-3.0-or-later */
/* Aggregate translation unit for Zig's `translate-c`.
 *
 * GMP's public interface is a single header, `gmp.h`, which this build
 * generates per target because it encodes the limb type and limb size. This
 * file exists so that translation has one stable entry point:
 *
 *   * In the default, vendored mode the generated include directory is on the
 *     include line, so this pulls in the freshly generated `gmp.h`.
 *   * In system library mode (`zig build -fsys=gmp`) no include directory is
 *     added, so this pulls in the *system* `gmp.h`, and the declarations always
 *     describe the library that is actually linked.
 *
 * Every public GMP declaration is reachable through `gmp.c`: mpz, mpq, mpf,
 * mpn, the random state functions, the printf and scanf families and the
 * memory function hooks. Nothing is filtered out.
 *
 * GMP's public header only declares its stdio and `va_list` functions when
 * the application has already provided those types: `gmp.h` includes only
 * `<stddef.h>` and `<limits.h>`, and gates `gmp_fprintf`, `gmp_fscanf`,
 * `mpz_out_str`, `mpz_inp_str`, `mpq_out_str`, `mpf_out_str` and the whole
 * `v`-suffixed printf and scanf family behind `FILE` being defined and behind
 * `va_start` being a macro. Translating `gmp.h` alone therefore drops all of
 * them silently. These two includes are what make the translation complete,
 * and they are what a real GMP program has already pulled in by the time it
 * calls those functions.
 *
 * Obstack declarations need a file-scope `struct obstack` and `_OBSTACK_H`
 * (`gmp-h.in:275-281`). Translation supplies these only for glibc targets
 * without parsing glibc's Aro-incompatible `<obstack.h>`.
 *
 * Upstream input: GNU MP 6.3.0, LGPLv3 or later, or GPLv2 or later.
 *
 * The declarations this pulls in follow the linkage the build was asked for:
 * `gmp.h` carries `__GMP_LIBGMP_DLL` 1 for a shared libgmp, so everything
 * here is declared `__declspec(dllimport)` for a consumer, and
 * `__declspec(dllexport)` only where `__GMP_WITHIN_GMP` is defined, which is
 * inside the library itself and never on a translation line.
 */

#include <stdarg.h>
#include <stdio.h>

/* Translation uses target-libc facts; C consumers use their real headers. */
#if defined(GMP_ZIG_TRANSLATE)
#if GMP_ZIG_HAVE_OBSTACK
struct obstack;
#define _OBSTACK_H 1
#endif
#elif defined(__has_include)
#if __has_include(<obstack.h>)
#include <obstack.h>
#endif
#endif

#include <gmp.h>

/* Pinned GMP 6.3.0 `gmp-h.in:249-250` defines `__MPN(x)` as `__gmpn_##x`, and
 * `gmp-h.in:1470-1700` spells every low-level routine as the object-like
 * alias `#define mpn_<name> __MPN(<name>)` above its own declaration; Aro
 * cannot translate that nested token-paste. Each such alias below is spelled
 * directly onto the same `__gmpn_<name>` declaration it already reached: the
 * per-entry guard leaves a routine this header does not define undefined, the
 * function-like conveniences stay as they are, and no wrapper, type,
 * declaration or ABI moves. */
#ifdef mpn_add
#undef mpn_add
#define mpn_add __gmpn_add
#endif
#ifdef mpn_add_1
#undef mpn_add_1
#define mpn_add_1 __gmpn_add_1
#endif
#ifdef mpn_add_n
#undef mpn_add_n
#define mpn_add_n __gmpn_add_n
#endif
#ifdef mpn_addmul_1
#undef mpn_addmul_1
#define mpn_addmul_1 __gmpn_addmul_1
#endif
#ifdef mpn_cmp
#undef mpn_cmp
#define mpn_cmp __gmpn_cmp
#endif
#ifdef mpn_zero_p
#undef mpn_zero_p
#define mpn_zero_p __gmpn_zero_p
#endif
#ifdef mpn_divexact_1
#undef mpn_divexact_1
#define mpn_divexact_1 __gmpn_divexact_1
#endif
#ifdef mpn_divexact_by3c
#undef mpn_divexact_by3c
#define mpn_divexact_by3c __gmpn_divexact_by3c
#endif
#ifdef mpn_divrem
#undef mpn_divrem
#define mpn_divrem __gmpn_divrem
#endif
#ifdef mpn_divrem_1
#undef mpn_divrem_1
#define mpn_divrem_1 __gmpn_divrem_1
#endif
#ifdef mpn_divrem_2
#undef mpn_divrem_2
#define mpn_divrem_2 __gmpn_divrem_2
#endif
#ifdef mpn_div_qr_1
#undef mpn_div_qr_1
#define mpn_div_qr_1 __gmpn_div_qr_1
#endif
#ifdef mpn_div_qr_2
#undef mpn_div_qr_2
#define mpn_div_qr_2 __gmpn_div_qr_2
#endif
#ifdef mpn_gcd
#undef mpn_gcd
#define mpn_gcd __gmpn_gcd
#endif
#ifdef mpn_gcd_11
#undef mpn_gcd_11
#define mpn_gcd_11 __gmpn_gcd_11
#endif
#ifdef mpn_gcd_1
#undef mpn_gcd_1
#define mpn_gcd_1 __gmpn_gcd_1
#endif
#ifdef mpn_gcdext_1
#undef mpn_gcdext_1
#define mpn_gcdext_1 __gmpn_gcdext_1
#endif
#ifdef mpn_gcdext
#undef mpn_gcdext
#define mpn_gcdext __gmpn_gcdext
#endif
#ifdef mpn_get_str
#undef mpn_get_str
#define mpn_get_str __gmpn_get_str
#endif
#ifdef mpn_hamdist
#undef mpn_hamdist
#define mpn_hamdist __gmpn_hamdist
#endif
#ifdef mpn_lshift
#undef mpn_lshift
#define mpn_lshift __gmpn_lshift
#endif
#ifdef mpn_mod_1
#undef mpn_mod_1
#define mpn_mod_1 __gmpn_mod_1
#endif
#ifdef mpn_mul
#undef mpn_mul
#define mpn_mul __gmpn_mul
#endif
#ifdef mpn_mul_1
#undef mpn_mul_1
#define mpn_mul_1 __gmpn_mul_1
#endif
#ifdef mpn_mul_n
#undef mpn_mul_n
#define mpn_mul_n __gmpn_mul_n
#endif
#ifdef mpn_sqr
#undef mpn_sqr
#define mpn_sqr __gmpn_sqr
#endif
#ifdef mpn_neg
#undef mpn_neg
#define mpn_neg __gmpn_neg
#endif
#ifdef mpn_com
#undef mpn_com
#define mpn_com __gmpn_com
#endif
#ifdef mpn_perfect_square_p
#undef mpn_perfect_square_p
#define mpn_perfect_square_p __gmpn_perfect_square_p
#endif
#ifdef mpn_perfect_power_p
#undef mpn_perfect_power_p
#define mpn_perfect_power_p __gmpn_perfect_power_p
#endif
#ifdef mpn_popcount
#undef mpn_popcount
#define mpn_popcount __gmpn_popcount
#endif
#ifdef mpn_pow_1
#undef mpn_pow_1
#define mpn_pow_1 __gmpn_pow_1
#endif
#ifdef mpn_preinv_mod_1
#undef mpn_preinv_mod_1
#define mpn_preinv_mod_1 __gmpn_preinv_mod_1
#endif
#ifdef mpn_random
#undef mpn_random
#define mpn_random __gmpn_random
#endif
#ifdef mpn_random2
#undef mpn_random2
#define mpn_random2 __gmpn_random2
#endif
#ifdef mpn_rshift
#undef mpn_rshift
#define mpn_rshift __gmpn_rshift
#endif
#ifdef mpn_scan0
#undef mpn_scan0
#define mpn_scan0 __gmpn_scan0
#endif
#ifdef mpn_scan1
#undef mpn_scan1
#define mpn_scan1 __gmpn_scan1
#endif
#ifdef mpn_set_str
#undef mpn_set_str
#define mpn_set_str __gmpn_set_str
#endif
#ifdef mpn_sizeinbase
#undef mpn_sizeinbase
#define mpn_sizeinbase __gmpn_sizeinbase
#endif
#ifdef mpn_sqrtrem
#undef mpn_sqrtrem
#define mpn_sqrtrem __gmpn_sqrtrem
#endif
#ifdef mpn_sub
#undef mpn_sub
#define mpn_sub __gmpn_sub
#endif
#ifdef mpn_sub_1
#undef mpn_sub_1
#define mpn_sub_1 __gmpn_sub_1
#endif
#ifdef mpn_sub_n
#undef mpn_sub_n
#define mpn_sub_n __gmpn_sub_n
#endif
#ifdef mpn_submul_1
#undef mpn_submul_1
#define mpn_submul_1 __gmpn_submul_1
#endif
#ifdef mpn_tdiv_qr
#undef mpn_tdiv_qr
#define mpn_tdiv_qr __gmpn_tdiv_qr
#endif
#ifdef mpn_and_n
#undef mpn_and_n
#define mpn_and_n __gmpn_and_n
#endif
#ifdef mpn_andn_n
#undef mpn_andn_n
#define mpn_andn_n __gmpn_andn_n
#endif
#ifdef mpn_nand_n
#undef mpn_nand_n
#define mpn_nand_n __gmpn_nand_n
#endif
#ifdef mpn_ior_n
#undef mpn_ior_n
#define mpn_ior_n __gmpn_ior_n
#endif
#ifdef mpn_iorn_n
#undef mpn_iorn_n
#define mpn_iorn_n __gmpn_iorn_n
#endif
#ifdef mpn_nior_n
#undef mpn_nior_n
#define mpn_nior_n __gmpn_nior_n
#endif
#ifdef mpn_xor_n
#undef mpn_xor_n
#define mpn_xor_n __gmpn_xor_n
#endif
#ifdef mpn_xnor_n
#undef mpn_xnor_n
#define mpn_xnor_n __gmpn_xnor_n
#endif
#ifdef mpn_copyi
#undef mpn_copyi
#define mpn_copyi __gmpn_copyi
#endif
#ifdef mpn_copyd
#undef mpn_copyd
#define mpn_copyd __gmpn_copyd
#endif
#ifdef mpn_zero
#undef mpn_zero
#define mpn_zero __gmpn_zero
#endif
#ifdef mpn_cnd_add_n
#undef mpn_cnd_add_n
#define mpn_cnd_add_n __gmpn_cnd_add_n
#endif
#ifdef mpn_cnd_sub_n
#undef mpn_cnd_sub_n
#define mpn_cnd_sub_n __gmpn_cnd_sub_n
#endif
#ifdef mpn_sec_add_1
#undef mpn_sec_add_1
#define mpn_sec_add_1 __gmpn_sec_add_1
#endif
#ifdef mpn_sec_add_1_itch
#undef mpn_sec_add_1_itch
#define mpn_sec_add_1_itch __gmpn_sec_add_1_itch
#endif
#ifdef mpn_sec_sub_1
#undef mpn_sec_sub_1
#define mpn_sec_sub_1 __gmpn_sec_sub_1
#endif
#ifdef mpn_sec_sub_1_itch
#undef mpn_sec_sub_1_itch
#define mpn_sec_sub_1_itch __gmpn_sec_sub_1_itch
#endif
#ifdef mpn_cnd_swap
#undef mpn_cnd_swap
#define mpn_cnd_swap __gmpn_cnd_swap
#endif
#ifdef mpn_sec_mul
#undef mpn_sec_mul
#define mpn_sec_mul __gmpn_sec_mul
#endif
#ifdef mpn_sec_mul_itch
#undef mpn_sec_mul_itch
#define mpn_sec_mul_itch __gmpn_sec_mul_itch
#endif
#ifdef mpn_sec_sqr
#undef mpn_sec_sqr
#define mpn_sec_sqr __gmpn_sec_sqr
#endif
#ifdef mpn_sec_sqr_itch
#undef mpn_sec_sqr_itch
#define mpn_sec_sqr_itch __gmpn_sec_sqr_itch
#endif
#ifdef mpn_sec_powm
#undef mpn_sec_powm
#define mpn_sec_powm __gmpn_sec_powm
#endif
#ifdef mpn_sec_powm_itch
#undef mpn_sec_powm_itch
#define mpn_sec_powm_itch __gmpn_sec_powm_itch
#endif
#ifdef mpn_sec_tabselect
#undef mpn_sec_tabselect
#define mpn_sec_tabselect __gmpn_sec_tabselect
#endif
#ifdef mpn_sec_div_qr
#undef mpn_sec_div_qr
#define mpn_sec_div_qr __gmpn_sec_div_qr
#endif
#ifdef mpn_sec_div_qr_itch
#undef mpn_sec_div_qr_itch
#define mpn_sec_div_qr_itch __gmpn_sec_div_qr_itch
#endif
#ifdef mpn_sec_div_r
#undef mpn_sec_div_r
#define mpn_sec_div_r __gmpn_sec_div_r
#endif
#ifdef mpn_sec_div_r_itch
#undef mpn_sec_div_r_itch
#define mpn_sec_div_r_itch __gmpn_sec_div_r_itch
#endif
#ifdef mpn_sec_invert
#undef mpn_sec_invert
#define mpn_sec_invert __gmpn_sec_invert
#endif
#ifdef mpn_sec_invert_itch
#undef mpn_sec_invert_itch
#define mpn_sec_invert_itch __gmpn_sec_invert_itch
#endif

/* NetBSD's AAPCS64 `__ALIGNBYTES` names the implicit compiler typedef
 * `__int128_t`. This OS-internal macro is unused by GMP; remove it after all
 * includes, without touching GMP declarations or macros. */
#if defined(__NetBSD__)
#undef __ALIGNBYTES
#endif
