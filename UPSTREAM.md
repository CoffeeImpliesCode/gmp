# Upstream provenance

## Canonical upstream

The GNU Multiple Precision Arithmetic Library is developed in a Mercurial
repository:

* canonical SCM: <https://gmplib.org/repo/gmp/>
* release announcements and manual: <https://gmplib.org/>
* GNU FTP mirror of the release tarballs: <https://ftp.gnu.org/gnu/gmp/>

There is no Git history in this repository, and none is claimed. GMP's canonical
SCM is Mercurial; this fork imports a release archive, so there is no upstream
commit SHA to record. Any GitHub mirror of GMP is a mirror, not the canonical
upstream.

## Imported source

| item | value |
| --- | --- |
| release | GNU MP 6.3.0 |
| archive | `gmp-6.3.0.tar.xz` |
| primary URL | <https://gmplib.org/download/gmp/gmp-6.3.0.tar.xz> |
| mirror URL | <https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.xz> |
| SHA256 | `a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898` |
| size | 2094196 bytes |
| detached signature | `gmp-6.3.0.tar.xz.sig`, RSA key `343C2FF0FBEE5EC2EDBEF399F3599FF828C67298` |

Both URLs were fetched on 2026-09-30 and produced byte identical archives with
the digest above, so the digest is corroborated by two independent hosts under
`gmplib.org` and `gnu.org`.

The detached signature was downloaded and inspected, but its public key is not
in this machine's keyring, so the signature is **unverified**. Treat the digest,
not the signature, as the integrity anchor, and add the GMP release key before
relying on the signature. That is still the state on 2026-10-04, when the pin
was fetched again to derive `UPSTREAM.sha256`: `gpg --list-keys` for
`343C2FF0FBEE5EC2EDBEF399F3599FF828C67298` reports no such key, so the record
names the signature UNVERIFIED as well.

## What was imported

The complete contents of `gmp-6.3.0/`, extracted at the repository root with
timestamps and permissions preserved, plus this fork's build, package, test,
documentation and CI files. The import was verified to be identical to the
extracted archive before any fork file was added:

```sh
tar -xJf gmp-6.3.0.tar.xz
diff -r --brief gmp-6.3.0 <repo-without-fork-files>
```

That one-shot comparison is kept honest by `UPSTREAM.sha256`: a per-file
SHA-256 record of **every** regular file of the pinned archive — 2156 records
covering 16998222 bytes — derived from a fresh extraction of the archive
itself and never from this working tree. `tools/provenance_gate.sh` runs
`sha256sum -c` over that record from the repository root, so an edited
source, header, table generator, upstream test, manual page, build file or
licence text fails CI. The record's header states the pin, the path set with
counts per area, what is deliberately absent from it and why, and the exact
commands to re-derive and re-check it. Re-verified on 2026-10-04: 2156
records, 2156 OK, 0 mismatches, 0 recorded paths missing, 0 upstream paths
unrecorded, and no divergence between the carried tree and the pinned bytes.

Upstream files keep their upstream paths and names. No upstream source file was
edited: `gmp-impl.h`, the `mpn/generic/*.c` sources, `Makefile.am`, `configure`
and the rest are byte identical to the release, and `UPSTREAM.sha256` is the
record that proves it for each of the 2156 files rather than asking to be
believed. Everything this fork adds lives in `build.zig`, `build.zig.zon`,
`root.zig`, `include/`, `zig/`, `tools/`, `consumer/`, `.gitignore`, `.github/`,
the Nix and devenv files, and the Markdown files at the root.

Upstream's own README has a special case. The archive ships it as `README`,
which is kept under its upstream name, and a byte-identical copy is preserved as
`README.upstream.md` so this fork can have a README of its own without
overwriting the upstream text. `README` is therefore an upstream record in
`UPSTREAM.sha256`, while `README.upstream.md` is this fork's own copy and is
deliberately not one. Both files have SHA-256
`5e9f9325fd702bc4bcda27d7a78fea88a2a09fa39b4b15ac7b9b205e0863dc7e`;
`tools/provenance_gate.sh` fails if they ever differ, if either is missing, or if
`README.upstream.md` is ever labelled as fork-authored.

## Files this fork added

| path | purpose |
| --- | --- |
| `build.zig` | Zig build: target configuration, generated headers, table generators, the library, tests, example, check, provenance gate |
| `build.zig.zon` | package manifest and path list |
| `root.zig` | module root: `gmp.c`, `BigInt`, `Rational`, `Float`, `Rand`, version and limb width |
| `include/gmp_all.h` | aggregate header for `translate-c` |
| `zig/config_gen.zig` | derives GMP's configuration from the resolved target |
| `zig/sources.zig` | the exact list of libgmp translation units |
| `zig/memory.zig` | GMP allocator helpers shared by the facade |
| `zig/BigInt.zig` | owned integers over `mpz_t` |
| `zig/Rational.zig` | owned rationals over `mpq_t` |
| `zig/Float.zig` | owned binary floats over `mpf_t` |
| `zig/Rand.zig` | owned random state over `gmp_randstate_t` |
| `zig/api_exercise.zig` | calls every public facade method, used by `check` and by `test` |
| `zig/test/root.zig` | test binary root |
| `zig/test/known_answers.zig` | independent known answers for integers |
| `zig/test/division.zig` | the three GMP division rules |
| `zig/test/parsing.zig` | accepted and rejected inputs, formatting into caller storage |
| `zig/test/ownership.zig` | GMP allocation accounting, moves, owning strings |
| `zig/test/rational_float_random.zig` | rationals, floats, seeded generators |
| `zig/test/alloc_probe.c` | test only allocation accounting shim |
| `zig/example/main.zig` | runnable example used by `smoke`, `run` and `check` |
| `consumer/` | separate package consuming this one through `b.dependency` |
| `tools/provenance_gate.sh` | the per-file record, licence and provenance integrity gate |
| `UPSTREAM.sha256` | SHA-256 of every upstream file this tree carries, against the pinned archive |
| `.github/workflows/ci.yml` | native tests, smoke, cross target check, provenance gate |
| `README.md` | this fork's README: deviations, build and support matrix, consumption |
| `README.upstream.md` | byte-identical copy of upstream's `README`, preserved separately |
| `FORK-LICENSE.md` | licence of the fork's own files, the owner's authorization and what it covers |
| `package.nix` | source-only Nix derivation, static and shared variants |
| `flake.nix` | flake exposing the two package variants and a dev shell |
| `devenv.nix`, `devenv.yaml`, `.envrc` | the canonical development environment |

## Licence texts and the per-file inventory

The four upstream licence texts are shipped unmodified and their digests are
enforced by `tools/provenance_gate.sh`:

| file | SHA-256 |
| --- | --- |
| `COPYING` | `8ceb4b9ee5adedde47b31e975c1d90c73ad27b6b165a1dcd80c7c545eb65b903` |
| `COPYINGv2` | `8177f97513213526df2cf6184d8ff986c675afb514d4e68a404010521b880643` |
| `COPYINGv3` | `e6037104443f9a7829b2aa7c5370d0789a7bda3ca65a0b904cdc0c2e285d9195` |
| `COPYING.LESSERv3` | `a853c2ffec17057872340eee242ae4d96cbf2b520ae27d903e1b2fef1a5f9d1c` |

The tree is not one licence. libgmp and the bulk of the tree are dual
`LGPL-3.0-or-later OR GPL-2.0-or-later`; the upstream test suite and several
demonstrations are `GPL-3.0-or-later`; the manual is `GFDL-1.3-or-later`; the
autotools scaffolding carries the terms of the Free Software Foundation, of GNU
Libtool and of the X Consortium individually. `NOTICE.md` is the per-file
inventory, with file and line anchors, and `FORK-LICENSE.md` records the terms
this fork applies to its own additions.

The byte-level counterpart of that inventory is `UPSTREAM.sha256`: the same
tree, listed file by file with a digest for each one, so "no upstream source
file was modified" is a check CI runs rather than a claim this record asks to
be believed.

## What this fork does not take from upstream

* `gmpxx.pc`: `gmpxx.pc.in` is unused, because libgmpxx is not built. `gmp.pc.in`
  **is** used: it is the upstream template for the installed
  `lib/pkgconfig/gmp.pc`, rendered against the install prefix, so the installed
  metadata describes where the library actually landed instead of being written
  into the build tree by `configure`.
* Tuned assembly: `mpn/<cpu>/` and `tune/` are imported but never compiled. The
  portable C backend is used on every target (`NO_ASM`).
* `libgmpxx` in `cxx/`, `mini-gmp/`, the upstream test suite, the demos and the
  tuning programs: imported, not built.

## Synchronising with a new upstream release

1. Fetch the new release archive from the primary URL, record its SHA256, and
   verify the detached signature with the GMP release key.
2. Extract it and replace the upstream files in place. Do not touch
   `build.zig`, `root.zig` or anything under `zig/`, `include/`, `tools/`,
   `consumer/`, unless the change requires it.
3. Re-check the lists in `zig/sources.zig` against the new `Makefile.am` and
   `mpn/generic/` contents, and the function signatures in `zig/*.zig` against
   the new `gmp-h.in`.
4. Regenerate `UPSTREAM.sha256` from the new archive — re-extract, re-derive
   every digest from the extracted tree, and rewrite the record's declared
   counts and per-area tables to match. Its current counts are 2156 records and
   16998222 bytes; `tools/provenance_gate.sh` refuses a smaller record, so the
   gate constant has to move with the record.
5. Update the digest table above and add a numbered entry to `CHANGELOG.md`.

## Generated files are not upstream files

`gmp.h`, `config.h`, `gmp-mparam.h`, the table headers and `mpn/fib_table.c` and
`mpn/mp_bases.c` are produced during the build, from templates that are upstream
files (`gmp-h.in`, `config.in`, `gen-*.c`). They are written to the Zig cache
directory, never into the source tree, and `.gitignore` excludes them.

`gmp.pc` and `gmpxx.pc` are in `.gitignore` for the same reason: they are what
`configure` would generate *in the source tree*. This build generates its
`gmp.pc` in the build cache and installs it; nothing is ever written into the
working tree.
