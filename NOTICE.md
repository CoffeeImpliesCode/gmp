# NOTICE

This file is the per-file licence inventory for the GMP 6.3.0 Zig package in
this repository. A tree is not licensed by its most prominent file: the library
this package compiles is one licence, the test suite and several demonstrations
are another, the manual is a third, and the autotools scaffolding carries its
own terms. Every claim below was read out of the file it names; the anchor is
given so a reader can check it.

## Licence of the imported library

This repository contains the GNU Multiple Precision Arithmetic Library (GMP)
6.3.0. GMP is distributed by its authors under a dual licence: you may use it
under the terms of **either**

* the **GNU Lesser General Public License, version 3 or later** (LGPLv3+), whose
  text is in `COPYING.LESSERv3` (the additional permissions) together with
  `COPYINGv3` (the GPLv3 text it refers to), or
* the **GNU General Public License, version 2 or later** (GPLv2+), whose text is
  in `COPYINGv2`,

or both in parallel, as GMP's own headers say (`README:8-18`).

This is not a relicensing. The fork **selects LGPLv3** for the library it links
and builds; the GPLv2 option is left available exactly as upstream offers it.

### The four licence texts, and why all four stay

| file | what it is | SHA-256 |
| --- | --- | --- |
| `COPYING` | GPLv3 text, `Version 3, 29 June 2007`, with `http://` GNU URLs | `8ceb4b9ee5adedde47b31e975c1d90c73ad27b6b165a1dcd80c7c545eb65b903` |
| `COPYINGv3` | GPLv3 text, same version and date, with `https://` GNU URLs | `e6037104443f9a7829b2aa7c5370d0789a7bda3ca65a0b904cdc0c2e285d9195` |
| `COPYINGv2` | GPLv2 text, `Version 2, June 1991` | `8177f97513213526df2cf6184d8ff986c675afb514d4e68a404010521b880643` |
| `COPYING.LESSERv3` | LGPLv3 text, `Version 3, 29 June 2007` | `a853c2ffec17057872340eee242ae4d96cbf2b520ae27d903e1b2fef1a5f9d1c` |

`COPYING` and `COPYINGv3` are not duplicates with a different name: they are
the same GPLv3 text differing in three lines (648, 667 and 674), where
`COPYING` carries `http://www.gnu.org/licenses/` and `COPYINGv3` carries
`https://`. All four are shipped unmodified; the digests are enforced by
`tools/provenance_gate.sh`.

The import is from a private repository. That changes who can read the code; it
changes nothing about the terms. Anyone who receives or redistributes this
library, private or public, must honour the LGPLv3 obligations: the licence
texts stay with the source, recipients keep the freedom to replace the library,
and a work that links it must let users relink against a modified GMP.

## Attribution

* The GNU Multiple Precision Arithmetic Library is copyright (C) the Free
  Software Foundation and contributors; see `AUTHORS`, `ChangeLog` and the
  copyright headers of the individual files, which are preserved verbatim.
* GMP's public entry points are exported under their internal `__gmp` names:
  `mpz_mul` is declared as `#define mpz_mul __gmpz_mul` (`gmp-h.in:934-935`).
  That is upstream's naming, recorded here because the runtime loader looks
  symbols up by those names.
* This fork is not endorsed by the GMP project and does not modify GMP's
  authorship or its version string.

## Per-file inventory

This section is the licence inventory: which terms apply to which files.
`UPSTREAM.sha256` is its byte-level counterpart, one SHA-256 per file for all
2156 upstream files this tree carries, and `tools/provenance_gate.sh` checks
them, so "no upstream source file was modified" is enforced rather than
asserted.

### libgmp: the code this package compiles and links

Dual `LGPL-3.0-or-later OR GPL-2.0-or-later` — the header upstream puts on
every one of these files (`mpz/add.c:3-29`, `mpq/cmp.c`, `mpf/add.c`,
`mpn/generic/add_1.c`, `printf/doprnt.c`, `scanf/vfscanf.c`, `rand/randmt.c`,
`memory.c:3-29`, and every `mpn/<cpu>/*.asm`, for example
`mpn/x86_64/aorrlsh1_n.asm:2-29`):

* the library sources `mpz/`, `mpq/`, `mpf/`, `printf/`, `scanf/`, `rand/` and
  `mpn/generic/`, plus the root-level library sources (`assert.c`, `bootstrap.c`,
  `compat.c`, `errno.c`, `extract-dbl.c`, `invalid.c`, `memory.c`, `mp_bpl.c`,
  `mp_clz_tab.c`, `mp_dv_tab.c`, `mp_get_fns.c`, `mp_minv_tab.c`, `mp_set_fns.c`,
  `primesieve.c`, `version.c`);
* the headers `gmp-h.in`, `gmp-impl.h`, `longlong.h`, `asl.h`, `gmpxx.h`;
* the table generators `gen-bases.c`, `gen-fac.c`, `gen-fib.c`,
  `gen-jacobitab.c`, `gen-psqr.c`, `gen-sieve.c`, `gen-trialdivtab.c`, plus
  `nextprime.c`. They run at build time on the build machine, but they are
  library sources and keep the library's terms;
* `mini-gmp/` — a separate, smaller implementation, dual
  `LGPL-3.0-or-later OR GPL-2.0-or-later` (`mini-gmp/mini-gmp.h:1-29`,
  `mini-gmp/README:1-29`). This package does not compile it;
* `cxx/` — the libgmpxx C++ binding, dual
  `LGPL-3.0-or-later OR GPL-2.0-or-later` (`cxx/isfuns.cc:1-29`,
  `cxx/dummy.cc:1-29`). This package does not build libgmpxx;
* `tune/` — the configuration and tuning programs, same dual terms
  (`tune/alpha.asm:3-20`);
* `doc/isa_abi_headache`, `INSTALL`, `.gdbinit`: dual terms, same headers;
* `mpn/minithres/gmp-mparam.h`: dual terms (`mpn/minithres/gmp-mparam.h:8-21`).
  This package uses `mpn/generic/gmp-mparam.h`, not this one.

### Upstream test suite and several demonstrations: GPL-3.0-or-later

These are **not** LGPL, and they are not dual. An earlier version of this file
called them "GPLv2 or later"; that was wrong, and the correction is recorded
here rather than quietly applied.

* `tests/` and `tests/cxx/`: `GPL-3.0-or-later` (`tests/misc/t-printf.c:1-13`,
  `tests/devel/README:1-13`, `tests/devel/primes.c:1-13`,
  `tests/amd64call.asm:2-13`, `tests/Makefile.am:8-12`);
* `demos/calc/`, `demos/factorize.c`, `demos/isprime.c`, `demos/primes.c`:
  `GPL-3.0-or-later` (`demos/calc/calc.y:1-18`, `demos/calc/README:1-15`,
  `demos/factorize.c:1-16`, `demos/isprime.c:1-16`, `demos/primes.c:1-16`).
  `demos/calc/calc.c:21-32` and `demos/calc/calc.h:21-32` additionally carry the
  GNU parser-generator "special exception" paragraph, which lets the Bison
  parser skeleton be redistributed as part of a larger work under terms of the
  recipient's choice. It is a condition on those two files, not a licence of its
  own;
* `demos/primes.h` carries no licence header at all: it is a table of `P(...)`
  entries included by `demos/factorize.c:27-29`, so it follows that file's
  `GPL-3.0-or-later`. A file with no header is not thereby freely licensed.

### Demonstrations that are dual, like the library

* `demos/expr/` (`demos/expr/expr.c:1-29`, `demos/expr/README:1-27`) and
  `demos/perl/` (`demos/perl/GMP.pm:1-29`, `demos/perl/INSTALL:1-24`):
  `LGPL-3.0-or-later OR GPL-2.0-or-later`.

### Documentation

* `doc/gmp.texi`, the manual this package does not build but ships:
  `GFDL-1.3-or-later`, with no Invariant Sections and with the specified
  front-cover and back-cover texts (`doc/gmp.texi:13-23`). The prebuilt
  `doc/gmp.info`, `doc/gmp.info-1` and `doc/gmp.info-2` that the release archive
  ships are generated from it and carry the same terms (`doc/gmp.info:6-14`);
* `doc/texinfo.tex`: `GPL-3.0-or-later`, the texinfo macro package's own terms
  (`doc/texinfo.tex:1-20`);
* `doc/version.texi` and `doc/stamp-vti` carry no notice: each is an automake
  version stamp of four `@set` lines.

### Autotools and helper scripts inside the imported archive

This package compiles none of these. They stay because the import stays
pristine, and each carries its own terms, which are not the library's:

| file | terms |
| --- | --- |
| `install-sh` | X Consortium permission notice carried from X11R5/X11R6 `install.sh`, `install-sh:7-25`: permissive, with the notice and permission text required in copies |
| `ltmain.sh` | GNU Libtool 2.4.6, `GPL-2.0-or-later` with the Libtool linking exception, `ltmain.sh:8-26` |
| `aclocal.m4`, `configure` | carry the GNU Libtool `GPL-2.0-or-later` notice inside their embedded text, `aclocal.m4:37-50`, `configure:29837-29850` |
| `config.guess`, `config.sub` | dual `LGPL-3.0-or-later OR GPL-2.0-or-later`, `config.guess:19-22`, `config.sub:19-22` |
| `configfsf.guess`, `configfsf.sub` | `GPL-3.0-or-later`, `configfsf.guess:9-12`, `configfsf.sub:9-12` |
| `Makefile.am`, `Makefile.in`, `configure.ac`, `config.in`, `acinclude.m4` | dual library terms in their own notices |
| generated `*/Makefile.in` | three notices each: the automake grant for the generated file (`Makefile.in:3-13`, `tests/Makefile.in:3-13`), the notice of the `.am` it was generated from (`tests/Makefile.in:15-25` is the test suite's `GPL-3.0-or-later`), and the embedded upstream notices below that |
| `compile`, `missing`, `test-driver`, `ylwrap` | `GPL-2.0-or-later`, `compile:9-20` |

### Files with no licence header at all

`gmp.pc.in` and `gmpxx.pc.in` are `pkg-config` templates with no notice. They are
build inputs under the library's terms. The build renders `gmp.pc.in` into the
installed `lib/pkgconfig/gmp.pc`; `gmpxx.pc.in` is left unused, because
libgmpxx is not built. See "Where the licence material is installed".

## Fork-authored files

Everything this fork adds — `build.zig`, `build.zig.zon`, `root.zig`,
`include/`, `runtime/`, `zig/` (including `zig/provider.zig`), `consumer/`,
`tools/`, `.github/`, `.gitignore`, `package.nix`, `flake.nix`, `flake.lock`,
`devenv.nix`, `devenv.yaml`, `.envrc`, and this documentation (`README.md`,
`README.zig.md`, `CHANGELOG.md`, `FORK-NOTES.md`, `NOTICE.md`, `UPSTREAM.md`,
`FORK-LICENSE.md`) — is licensed **`LGPL-3.0-or-later`**, under the repository
owner's direct authorization for fork-authored additions and chosen to match
the primary upstream terms of the library it links. The copyright in those
files is held by the owner of this repository; no upstream author is credited
for them and no individual is named. `FORK-LICENSE.md` records the
authorization, the full file list, and what an LGPL recipient must do.

The runtime-loading half is part of that set rather than an exception to it,
because §4 bookkeeping that stops at the linked half describes only half of
what this tree ships. Each of the six files in `runtime/` states the same
grant in its own first line — `runtime/loader.zig:1`, `runtime/library.zig:1`,
`runtime/graph.zig:1`, `runtime/generate.zig:1`, `runtime/sync.h:1` and
`runtime/sync.c:1` — as does `zig/provider.zig:1`, the file that names the
provider a run must be told before it can call anything. A recipient given
only the loaded configuration therefore still receives the source of the parts
that produce it: the loader core, GMP's binding to it, the dispatch generator,
the build wiring and the synchronization binding the dispatch compiles.

`README.upstream.md` is not a fork-authored file: it is a byte-identical copy of
upstream's `README` (SHA-256
`5e9f9325fd702bc4bcda27d7a78fea88a2a09fa39b4b15ac7b9b205e0863dc7e`), kept so
upstream's own words survive this fork's `README.md`. Its terms are upstream's.

## Modifications made by this fork

**No upstream source file was modified.** The build system, the Zig package
surface, the tests, the example, the consumer package, the Nix packaging and the
documentation are the additions, and they are listed in `UPSTREAM.md`.

Behavioural differences from an upstream `configure`-driven build are recorded
in `CHANGELOG.md`; the most important one is that this fork selects the portable
C backend for all targets instead of tuned assembly. The generated `gmp.h`,
`config.h`, `gmp-mparam.h`, table headers and the two generated table sources
are build outputs of upstream templates, not upstream files, and they are never
written into the source tree.

## Third party components

No third-party library code was added by this fork. Everything else in the tree
is either GMP 6.3.0 or a helper program the GMP archive itself ships, listed in
the tables above with its own terms.

## Where the licence material is installed

An installed package must let a recipient read the terms of what they received.
There is one owner for that material and it is the build graph: `zig build
install` writes all eight licence-directory records, and `package.nix` installs
nothing of its own, so a native prefix and a Nix package carry the same grant
records.

| installed path | installed by |
| --- | --- |
| `share/licenses/gmp/COPYING`, `COPYINGv2`, `COPYINGv3`, `COPYING.LESSERv3` | `zig build install` |
| `share/licenses/gmp/NOTICE.md`, `FORK-LICENSE.md`, `UPSTREAM.md`, `README.upstream.md` | `zig build install` — this fork's own records, in the same directory as the upstream grants because they are terms of the same redistribution |
| `share/doc/gmp/AUTHORS`, `NEWS`, `README` | `zig build install` — upstream's authorship and release records, which are not licence texts and so do not belong in the licence directory |
| `lib/pkgconfig/gmp.pc` | `zig build install`, rendered from `gmp.pc.in` against the install prefix |

Two limits are stated rather than glossed over:

* The `gmp.pc` is **derived metadata, not a licence file**. It reports
  `Cflags: -I${includedir}` and `Libs: -L${libdir} -lgmp` for the installed
  library; the obligations above are discharged by the licence texts beside it,
  not by the `.pc` file. A C consumer can use `pkg-config --cflags --libs gmp`
  once the package is on the search path, and the same flags work without it.
* The `libgmp` this package installs is the real library and it is **not** a
  wholly static closure. Its external link closure is the C runtime and nothing
  else — no compiled translation unit includes `<math.h>`, and the three host
  table generators that do link `libm` are build-time programs that are not part
  of the artifact — but a shared `libgmp` still resolves against the system
  libc, and a consumer of `libgmp.a` still links its own.