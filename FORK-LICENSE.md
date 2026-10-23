# Licence of the fork's own files

## The authorization and the grant

The repository owner authorized a per-project licence for the files **this fork
adds**. For this project the grant is the **GNU Lesser General Public License,
version 3 or later** (`LGPL-3.0-or-later`), matching the LGPLv3 option GMP
itself offers for libgmp and the option this package selects. The copyright in
these additions is held by the owner of this repository; no individual holder is
named, because naming one would be a claim this repository cannot support from
its own records.

This is not a relicensing of GMP and does not narrow or widen any upstream
term. Upstream files keep the terms printed in their own headers, byte for byte;
`NOTICE.md` is the per-file inventory. The LGPLv3 text is
`COPYING.LESSERv3` with the GPLv3 text it refers to in `COPYINGv3`, both shipped
unmodified, and the GPLv2 option upstream offers stays available through
`COPYINGv2` and `COPYING`.

## Files this grant covers

Everything below was written for this fork. None of it exists in the GMP 6.3.0
release archive.

| path | what it is |
| --- | --- |
| `build.zig`, `build.zig.zon`, `root.zig`, `include/gmp_all.h` | Build, manifest, module root, and translation header. |
| `zig/config_gen.zig`, `zig/sources.zig`, `zig/memory.zig` | Configuration, source list, and allocator access. |
| `zig/base.zig`, `zig/BigInt.zig`, `zig/Rational.zig`, `zig/Float.zig`, `zig/Rand.zig` | Typed facade. |
| `zig/api_exercise.zig`, `zig/provider.zig`, `zig/example/main.zig` | API exercise, provider selection, and example. |
| `zig/test/**`, `consumer/**` | Fork tests and consumer package. |
| `runtime/loader.zig`, `runtime/library.zig`, `runtime/graph.zig`, `runtime/generate.zig`, `runtime/sync.h`, `runtime/sync.c` | Runtime-loading route and synchronization binding. |
| `tools/provenance_gate.sh`, `.gitignore` | Provenance gate and build-output exclusions. |
| `README.md`, `README.zig.md`, `CHANGELOG.md`, `FORK-NOTES.md`, `NOTICE.md`, `UPSTREAM.md`, `FORK-LICENSE.md` | Fork documentation. |
| `package.nix`, `flake.nix`, `flake.lock`, `devenv.nix`, `devenv.yaml`, `.envrc` | Nix packaging and development environment. |

`README.upstream.md` is **not** in this list: it is a byte-identical copy of
upstream's own `README`. Its terms are upstream's, and its digest is checked by
`tools/provenance_gate.sh`.

This fork modifies no upstream file; see `UPSTREAM.md` for the source record.
