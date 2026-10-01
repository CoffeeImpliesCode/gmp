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
 * Upstream input: GNU MP 6.3.0, LGPLv3 or later, or GPLv2 or later.
 */

#include <stdarg.h>
#include <stdio.h>

#include <gmp.h>
