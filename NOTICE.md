# NOTICE

GMP 6.3.0 is copyright the Free Software Foundation and its contributors. GMP offers the library under either `LGPL-3.0-or-later` or `GPL-2.0-or-later`. This fork uses the LGPL option and does not relicense GMP.

| Licence file | Text |
| --- | --- |
| `COPYING.LESSERv3` | LGPLv3, used with `COPYINGv3` |
| `COPYINGv3` | GPLv3 text referenced by the LGPLv3 |
| `COPYINGv2` | GPLv2 |
| `COPYING` | GPLv3 text with GNU URLs using `http` |

`COPYING` and `COPYINGv3` differ in three URL lines. All four licence files are shipped unmodified. GMP's copyright notices remain in the source headers. GMP does not endorse this fork.

## Upstream file licences

| Files | Terms and scope |
| --- | --- |
| `mpz/`, `mpq/`, `mpf/`, `printf/`, `scanf/`, `rand/`, `mpn/generic/`, `mpn/<cpu>/*.asm` | `LGPL-3.0-or-later OR GPL-2.0-or-later` |
| Root library sources: `assert.c`, `bootstrap.c`, `compat.c`, `errno.c`, `extract-dbl.c`, `invalid.c`, `memory.c`, `mp_bpl.c`, `mp_clz_tab.c`, `mp_dv_tab.c`, `mp_get_fns.c`, `mp_minv_tab.c`, `mp_set_fns.c`, `primesieve.c`, `version.c` | `LGPL-3.0-or-later OR GPL-2.0-or-later` |
| Headers `gmp-h.in`, `gmp-impl.h`, `longlong.h`, `asl.h`, `gmpxx.h`; generators `gen-bases.c`, `gen-fac.c`, `gen-fib.c`, `gen-jacobitab.c`, `gen-psqr.c`, `gen-sieve.c`, `gen-trialdivtab.c`, `nextprime.c` | `LGPL-3.0-or-later OR GPL-2.0-or-later` |
| `mini-gmp/`, `cxx/`, `tune/`, `mpn/minithres/gmp-mparam.h`, `doc/isa_abi_headache`, `INSTALL`, `.gdbinit` | `LGPL-3.0-or-later OR GPL-2.0-or-later`; not built by this package |
| `tests/`, `tests/cxx/` | `GPL-3.0-or-later` |
| `demos/calc/`, `demos/factorize.c`, `demos/isprime.c`, `demos/primes.c` | `GPL-3.0-or-later` |
| `demos/primes.h` | No licence header; follows `demos/factorize.c` under `GPL-3.0-or-later` |
| `demos/expr/`, `demos/perl/` | `LGPL-3.0-or-later OR GPL-2.0-or-later` |
| `doc/gmp.texi`, `doc/gmp.info`, `doc/gmp.info-1`, `doc/gmp.info-2` | `GFDL-1.3-or-later`, with no Invariant Sections and with the specified front-cover and back-cover texts |
| `doc/texinfo.tex` | `GPL-3.0-or-later` |
| `doc/version.texi`, `doc/stamp-vti` | No licence notice; automake version stamps |
| `install-sh` | X Consortium permission notice; copies must retain its notice and permission text |
| `ltmain.sh` | GNU Libtool 2.4.6, `GPL-2.0-or-later` with the Libtool linking exception |
| `aclocal.m4`, `configure` | Embed the GNU Libtool `GPL-2.0-or-later` notice |
| `config.guess`, `config.sub` | `LGPL-3.0-or-later OR GPL-2.0-or-later` |
| `configfsf.guess`, `configfsf.sub` | `GPL-3.0-or-later` |
| `Makefile.am`, `Makefile.in`, `configure.ac`, `config.in`, `acinclude.m4` | Dual library terms in their notices |
| Generated `*/Makefile.in` | Automake grant, source `.am` notice, and embedded upstream notices |
| `compile`, `missing`, `test-driver`, `ylwrap` | `GPL-2.0-or-later` |
| `gmp.pc.in`, `gmpxx.pc.in` | No licence header; build templates under the library's terms. `gmpxx.pc.in` is unused. |

The Bison skeleton exception in `demos/calc/calc.c` and `demos/calc/calc.h` permits redistribution of that skeleton in a larger work under the recipient's chosen terms. It applies to those files only.

## Fork-authored files

The repository owner grants `LGPL-3.0-or-later` for these fork-authored additions. Copyright belongs to the repository owner. No upstream author is credited for these additions.

`build.zig`, `build.zig.zon`, `root.zig`, `include/`, `runtime/`, `zig/`, `consumer/`, `tools/`, `.gitignore`, `package.nix`, `flake.nix`, `flake.lock`, `devenv.nix`, `devenv.yaml`, `.envrc`, `README.md`, `README.zig.md`, `CHANGELOG.md`, `FORK-NOTES.md`, `NOTICE.md`, `UPSTREAM.md`, and `FORK-LICENSE.md`.

`README.upstream.md` is excluded from this grant. It is a byte-identical copy of upstream's `README` and retains upstream's terms.
