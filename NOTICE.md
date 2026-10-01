# NOTICE

## Licence of the imported library

This repository contains the GNU Multiple Precision Arithmetic Library (GMP)
6.3.0. GMP is distributed by its authors under a dual licence: you may use it
under the terms of **either**

* the **GNU Lesser General Public License, version 3 or later** (LGPLv3+), whose
  texts are in `COPYING.LESSERv3` (the additional permissions) together with
  `COPYINGv3` (the GPLv3 text it refers to), or
* the **GNU General Public License, version 2 or later** (GPLv2+), whose text is
  in `COPYING` and `COPYINGv2`,

or both in parallel, as GMP's own headers say.

This is not a relicensing. The fork **selects LGPLv3** for the library it links
and builds; the GPLv2 option is left available exactly as upstream offers it.

Which parts are which:

| part | licence |
| --- | --- |
| libgmp sources (`mpz`, `mpq`, `mpf`, `mpn/generic`, `printf`, `scanf`, `rand`, the root level C sources) | LGPLv3 or later, or GPLv2 or later, at the user's option |
| `gmp.h` (generated from `gmp-h.in`) and `gmp-impl.h` | same as the library |
| the upstream test suite (`tests/`) and the demo programs (`demos/`) | GPLv2 or later, as upstream states in their headers |
| the table generators (`gen-*.c`) and `bootstrap.c` | LGPLv3 or later, or GPLv2 or later; they run at build time on the build machine |
| this fork's Zig code (`root.zig`, `build.zig`, everything under `zig/`, `include/`, `consumer/`, `tools/`) | LGPLv3 or later, chosen to match the library it links |

The import is from a private repository. That changes who can read the code; it
changes nothing about the terms. Anyone who receives or redistributes this
library, private or public, must honour the LGPLv3 obligations: the licence
texts stay with the source, recipients keep the freedom to replace the library,
and a work that links it must let users relink against a modified GMP.

## Attribution

* The GNU Multiple Precision Arithmetic Library is copyright (C) the Free
  Software Foundation and contributors; see `AUTHORS`, `ChangeLog` and the
  copyright headers of the individual files, which are preserved verbatim.
* This fork is not endorsed by the GMP project and does not modify GMP's
  authorship or its version string.

## Modifications made by this fork

No upstream source file was modified. This fork adds a build system, a Zig
package surface, tests, an example, a consumer package and documentation. Those
additions are the modifications, and they are listed in `UPSTREAM.md`.

Behavioural differences from an upstream `configure`-driven build are recorded
in `CHANGELOG.md`; the most important one is that this fork selects the portable
C backend for all targets instead of tuned assembly.

## Third party components

None. The library, the build system and every file here come from GMP 6.3.0 or
from this fork's own work. `mpn/`, `mpz/`, `mpq/`, `mpf/`, `cxx/`, `demos/`,
`tune/`, `tests/` and `mini-gmp/` contain upstream sources for configurations
this build does not select; they are kept so the import stays pristine.
