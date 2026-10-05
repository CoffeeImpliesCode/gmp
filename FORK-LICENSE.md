# Licence of the fork's own files

## The authorization and the grant

The repository owner authorized a per-project licence for the files **this fork
adds**. For this project the grant is the **GNU Lesser General Public License,
version 3 or later** (`LGPL-3.0-or-later`), matching the LGPLv3 option GMP
itself offers for libgmp and the option this package selects. The copyright in
these additions is held by the owner of this repository; no individual holder is
named, because naming one would be a claim this repository cannot support from
its own records.

This is not a relicensing of GMP and does not narrow or widen any upstream term.
Upstream files keep the terms printed in their own headers, byte for byte;
`NOTICE.md` is the per-file inventory. The LGPLv3 text is
`COPYING.LESSERv3` with the GPLv3 text it refers to in `COPYINGv3`, both shipped
unmodified, and the GPLv2 option upstream offers stays available through
`COPYINGv2` and `COPYING`.

## Files this grant covers

Everything below was written for this fork. None of it exists in the GMP 6.3.0
release archive.

| path | what it is |
| --- | --- |
| `build.zig` | Zig build: target configuration, generated headers, table generators, library, tests, example, check, provenance step |
| `build.zig.zon` | package manifest |
| `root.zig` | module root and re-exports |
| `include/gmp_all.h` | aggregate header handed to `translate-c` |
| `zig/config_gen.zig` | derives GMP's configuration from the resolved target |
| `zig/sources.zig` | the exact list of libgmp translation units |
| `zig/memory.zig` | GMP allocator access shared by the facade |
| `zig/base.zig`, `zig/BigInt.zig`, `zig/Rational.zig`, `zig/Float.zig`, `zig/Rand.zig` | the typed facade |
| `zig/api_exercise.zig` | compile-time and run-time exercise of every public facade method |
| `zig/provider.zig` | the one place a run's provider request is read: `--provider`, then `GMP_TEST_PROVIDER`, and `NoProviderConfigured` when a run was told nothing |
| `zig/example/main.zig` | runnable, self-checking example |
| `zig/test/**` | this fork's tests and the test-only allocation probe |
| `consumer/**` | separate package consuming this one |
| `runtime/loader.zig`, `runtime/library.zig`, `runtime/graph.zig`, `runtime/generate.zig`, `runtime/sync.h`, `runtime/sync.c` | the runtime-loading route: the reusable loader core, this SDK's half of it, the wiring that builds them into the module, the generator that writes the dispatch, and the synchronization binding the dispatch compiles |
| `tools/provenance_gate.sh` | licence and provenance integrity gate |
| `.github/workflows/ci.yml` | CI wiring for this repository's own steps |
| `.gitignore` | build-output exclusions |
| `README.md`, `README.zig.md`, `CHANGELOG.md`, `FORK-NOTES.md`, `NOTICE.md`, `UPSTREAM.md`, `FORK-LICENSE.md` | this fork's documentation |
| `package.nix`, `flake.nix`, `flake.lock`, `devenv.nix`, `devenv.yaml`, `.envrc` | Nix packaging and the development environment; `flake.lock` is the resolved input of the revision `flake.nix` pins |

`README.upstream.md` is **not** in this list: it is a byte-identical copy of
upstream's own `README`, preserved so the upstream text survives this fork's
README. Its terms are upstream's, and its digest is checked by
`tools/provenance_gate.sh`.

## What the LGPLv3 asks of a recipient

* **Keep the licence texts.** `COPYING.LESSERv3` and `COPYINGv3` accompany every
  redistribution of the built library; this package's install closure carries
  them under `share/licenses/gmp/` alongside `COPYING` and `COPYINGv2`.
* **Convey the source.** LGPLv3 §4 requires that recipients of the library get
  its complete corresponding source. For this package that source is this
  repository: the build compiles the vendored GMP 6.3.0 tree from it and adds
  the files in the table above. Nothing is downloaded at build time, so the
  source a recipient needs is the source that produced the artifact. That
  includes the whole of the runtime-loading route — `runtime/`, `zig/provider.zig`
  and `-Druntime=true` in `build.zig` — so a recipient can rebuild the loaded
  configuration and modify it, not only the linked one.
* **Let users relink.** LGPLv3 §5 requires that a work distributed in object or
  linkable form let users modify this library and relink. A statically linked
  binary can satisfy this with the relinking object files the linker keeps, or
  by rebuilding against this package; a shared `libgmp` satisfies it directly,
  because the recipient can substitute their own build.
* **Do not claim upstream authorship for the additions.** The GMP library is
  copyright the Free Software Foundation and its contributors (`AUTHORS`,
  `ChangeLog`, and the per-file headers). The files above are this fork's own.
* **Fork changes to upstream files would need conveying.** This fork modifies no
  upstream file; the record is in `UPSTREAM.md` and the digests in
  `tools/provenance_gate.sh`. If that ever changes, the modified file leaves the
  "verbatim upstream" set and its new source must be conveyed with it.