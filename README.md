# GMP 6.3.0 as a Zig package

This repository is the complete source tree of the GNU Multiple Precision
Arithmetic Library 6.3.0, imported from the official release archive and
packaged for Zig 0.16. It builds the real `libgmp` — `mpz`, `mpq`, `mpf`, the
portable `mpn` layer, `printf`, `scanf` and the random state code — with no
autotools, no CMake, no Make and no download at build time, and publishes it two
ways: as a Zig artifact with the generated public headers, and as a Zig module
that adds a typed facade over the complete translated C API.

* Upstream's own README is preserved verbatim twice: as `README`, under the
  name the archive gave it, and as the byte-identical `README.upstream.md`.
* This is a fork. It is not endorsed by the GMP project. `UPSTREAM.md` records
  where the sources came from and how to re-verify them.
* The Zig interface is documented separately, in `README.zig.md`.

## Native source deviations

**None.** No file from the GMP 6.3.0 archive has been edited. `gmp-impl.h`, the
`mpn/generic/*.c` sources, `Makefile.am`, `configure`, the `COPYING*` texts and
the rest are byte identical to the release. `UPSTREAM.sha256` records a SHA-256
for every one of the 2156 regular files of the pinned archive, and
`sha256sum --check --strict UPSTREAM.sha256` over this tree exits 0 with every
one of them `OK`
(`local://foundation-resumed-gmp-pinned-byte-integrity.json`), so the claim
above is a checked fact rather than an intention.
`tools/provenance_gate.sh` runs that record before its other checks and keeps
its own checks on the four licence texts and on upstream's README.

Everything this fork adds is new: a build system, the Zig package surface, tests,
an example, a consumer package, Nix packaging, a development environment and
documentation. `UPSTREAM.md` lists the files; `FORK-LICENSE.md` states their
licence.

Two things that are *not* source deviations, because they are build decisions
described below, so they cannot be mistaken for edits: the generated `gmp.h`,
`config.h`, `gmp-mparam.h` and table headers are build outputs written to the
build cache and never into the source tree, and 29 internal `mpn` functions with
no portable C source are not compiled, exactly as `configure` omits them for a
generic build.

## Native build deviations

The build replaces `configure` with a target-derived configuration. In short:

| decision | what this build does | what `configure` would do |
| --- | --- | --- |
| mpn backend | portable C only, `NO_ASM` defined, on every target | tuned assembly for most targets |
| limb type and width | derived from the resolved target: `unsigned long` limbs on LP64, `unsigned long long` on LLP64, native 32-bit limbs on 32-bit pointer targets | probed from the build machine |
| endianness | taken from the target's architecture, so `HAVE_LIMB_*_ENDIAN` and `HAVE_DOUBLE_IEEE_*_ENDIAN` are right for a big-endian target | probed from the build machine |
| generated headers | `gmp.h` rendered from `gmp-h.in`, `config.h` from `config.in`, both for the target being built | written by `configure` in the source tree |
| tables | GMP's own `gen-*` programs, built for the host, run with the target's limb size and nail count, outputs in the build cache | run by `make` in the source tree |
| assertions | `WANT_ASSERT` on in Debug, off otherwise, mirroring the `-DNDEBUG` default | same intent, driven by `configure` |
| linkage | `-Dlinkage=static` by default, which is this fork's existing policy and what a GMP configured `--disable-shared` produces; `-Dlinkage=dynamic` compiles every object PIC and gives the shared object libtool's own version and soname, and sets `__GMP_LIBGMP_DLL` to 1 in the generated `gmp.h` so `__GMP_DECLSPEC` exports. Static keeps that macro at 0, so only `gmp.h` differs between the two linkages; `config.h` is identical | autotools default is shared on most platforms |
| scope | `libgmp` only: no `libgmpxx`, no `mini-gmp`, no upstream test suite, no demos | upstream builds and installs all of those |
| pkg-config | `gmp.pc.in` is rendered into `lib/pkgconfig/gmp.pc` against the install prefix, so the metadata describes where the library actually landed | `configure` substitutes `gmp.pc.in` into the build tree |
| C undefined-behaviour instrumentation | in every mode but `Debug`, `-fno-sanitize=function` is added to the command line of GMP's own C sources — all three source groups: the library units, the two generated tables and the generated `mpn` template wrappers. `Module.sanitize_c` stays null, so Zig emits no `-fsanitize-c` flag at all and the compiler's own default otherwise stands | no such flag; autotools does not build GMP with clang's undefined-behaviour instrumentation |

The last row is one authorised exception and it is narrower than it looks. It is
not a varargs ABI repair and it is not a switch for C instrumentation as a whole:
GMP's `printf` dispatch cannot satisfy clang's `function` check, and that check
is the only thing it turns off.

* The check writes an eight-byte `0xc105cafe` signature plus a hash of the
  function type in front of every function entry and verifies it at every
  indirect call. A `Debug` build carries no such signature, which is why the flag
  appears only in the other three modes.
* What it catches here is upstream's own code, unmodified. Each of the four
  slots of `struct doprnt_funs_t` is declared with a `void *` first parameter
  (`gmp-impl.h:4540-4543`) and is filled by casting a function whose first
  parameter is a concrete struct pointer. All five initializers do that —
  `printf/snprntffuns.c:152-158`, `printf/sprintffuns.c:89-94`,
  `printf/vasprintf.c:103-108`, `printf/printffuns.c:75-79` and
  `printf/obprntffuns.c:65-69`, and `printffuns.c:76` casts libc's own
  `vfprintf`. Converting between those function types is undefined behaviour in
  C, so the first indirect call through the table traps on it —
  `DOPRNT_FORMAT (last_fmt, last_ap)` at `printf/doprnt.c:612` — before a
  character is formatted. Upstream source stays byte-for-byte, so the
  exception has to live in the command line.
* Three other C translation units keep the check, because each has nothing for
  it to catch: the seven host `gen-*` table generators and the `bootstrap.c`
  they include convert no function pointer at all, and neither does the
  fork-authored `runtime/sync.c` or `zig/test/alloc_probe.c`. The generators
  are build-time host programs outside the artifact, not GMP native code for
  the target, so they are not given the target's flags or its exception.
* Everything else stays on: every other C undefined-behaviour check, every Zig
  safety check, and the optimize mode itself. An isolated probe on 2026-10-04
  measured the width of the exception — the same callback that traps with the
  default instrumentation runs and prints `42` with the flag, while the *same*
  narrowed binary still traps with `SIGILL` on a signed-overflow path. See the
  [support matrix](#support-matrix) for those receipts.

The cost is arithmetic speed: the portable C backend is correct and ABI
compatible on every supported target and it is slower than GMP's own per-
architecture assembly. Speed parity is not claimed. The full numbered history of
every divergence, including the corrections made to this fork's own code, is in
[`CHANGELOG.md`](CHANGELOG.md); the reasoning behind the non-obvious ones is in
[`FORK-NOTES.md`](FORK-NOTES.md).

## Support matrix

Statuses are the workspace's own vocabulary. `observed` rows name the run that
produced them and its receipt; `PENDING-VERIFICATION` rows are work no run in
this repository has exercised. **This documentation role runs no builds, no
tests, no Nix evaluations and no devenv invocations**, so no row below is a
result of editing these three documents: every observed row is a run somebody
else performed, and every pending row is still genuinely unexercised.

### History: the 2026-10-01 wave

| what | status | date and receipt |
| --- | --- | --- |
| `zig build test smoke` (Debug, native) — install and smoke steps | observed pass, exit 0 | 2026-10-01, `local://foundation-resume-evidence.json` |
| `zig build test` (Debug, native) — 47/47 tests | observed pass, exit 0 | 2026-10-01, same receipt |
| `zig build test -Doptimize=ReleaseSafe` — 47/47 tests | observed pass, exit 0 | 2026-10-01, same receipt |
| `zig build smoke` — the example prints 20!, 2^160 mod 1000000007, 1/2+1/6, the 50-digit square root of two and identical Mersenne Twister draws | observed pass, exit 0 | 2026-10-01, same receipt |
| `cd consumer && zig build run` — 25/25 steps, 2^160 mod 1000000007 = 213932660 | observed pass, exit 0 | 2026-10-01, same receipt |
| `zig build provenance` — "licence texts and provenance record are intact" | observed pass, exit 0 | 2026-10-01, same receipt |
| `zig build check` across the six targets — five compile, `wasm32-wasi` fails | observed partial, exit 1 | 2026-10-01, same receipt |
| `zig fmt --check` — "No Zig file in this fork needs formatting" | observed pass, exit 0 | date not recorded in the ledger; `local://workspace-fmt.json` |

`wasm32-wasi` does not compile, and that is a property of the vendored source
meeting a libc without signals, not of the packaging: `invalid.c:80` reports an
invalid operation by raising `SIGFPE`, `Makefile.am:285` compiles that file
unconditionally, and wasi-libc's `signal.h` refuses to be included without
`_WASI_EMULATED_SIGNAL`. Upstream's own `configure` has no wasm branch either.
The target stays in the matrix and the failed attempt stays visible; nothing in
this package declares WebAssembly support.

`CHANGELOG.md` entry 8 (2026-10-03) states that install, Debug and ReleaseSafe
tests, smoke and the consumer passed after the API alignment. That entry cites
no receipt, and the root ledger's GMP verification block still holds the
2026-10-01 receipts above, so it is recorded here as a dated claim whose receipt
this repository does not name.

Those rows are kept as they were recorded. For the native cells they are
superseded by the wave below, which covers the same commands in all four
optimize modes and both linkages; for `check`, `provenance`, the consumer and
the formatter they are the only evidence this repository has.

### Observed 2026-10-04: this wave

Each of the eight native cells below is a run on this machine's Linux x86-64
host: one `zig build smoke test` per optimize mode and per linkage, with the
install step writing into a scratch prefix. Each of those eight receipts ends
in `Build Summary: 37/37 steps succeeded; 47/47 tests passed`, the example's own
last line `all example results verified`, and an install step that installed the
library, `lib/pkgconfig/gmp.pc`, the four upstream licence texts,
`AUTHORS`/`NEWS`/`README` and `gmp-example`.

| what | status | date and receipt |
| --- | --- | --- |
| `zig build smoke test -Doptimize=Debug -Dlinkage=static` — 47/47 | observed pass, exit 0 | 2026-10-04, `local://foundation-resumed-gmp-native-static-Debug.json` |
| `zig build smoke test -Doptimize=ReleaseSafe -Dlinkage=static` — 47/47 | observed pass, exit 0 | 2026-10-04, `local://foundation-resumed-gmp-native-static-ReleaseSafe.json` |
| `zig build smoke test -Doptimize=ReleaseFast -Dlinkage=static` — 47/47 | observed pass, exit 0 | 2026-10-04, `local://foundation-resumed-gmp-native-static-ReleaseFast.json` |
| `zig build smoke test -Doptimize=ReleaseSmall -Dlinkage=static` — 47/47 | observed pass, exit 0 | 2026-10-04, `local://foundation-resumed-gmp-native-static-ReleaseSmall.json` |
| `zig build smoke test -Doptimize=Debug -Dlinkage=dynamic` — 47/47 | observed pass, exit 0 | 2026-10-04, `local://foundation-resumed-gmp-native-dynamic-Debug.json` |
| `zig build smoke test -Doptimize=ReleaseSafe -Dlinkage=dynamic` — 47/47 | observed pass, exit 0 | 2026-10-04, `local://foundation-resumed-gmp-native-dynamic-ReleaseSafe.json` |
| `zig build smoke test -Doptimize=ReleaseFast -Dlinkage=dynamic` — 47/47 | observed pass, exit 0 | 2026-10-04, `local://foundation-resumed-gmp-native-dynamic-ReleaseFast.json` |
| `zig build smoke test -Doptimize=ReleaseSmall -Dlinkage=dynamic` — 47/47 | observed pass, exit 0 | 2026-10-04, `local://foundation-resumed-gmp-native-dynamic-ReleaseSmall.json` |
| `sha256sum --check --strict UPSTREAM.sha256` — every pinned upstream file | observed pass, exit 0 | 2026-10-04, `local://foundation-resumed-gmp-pinned-byte-integrity.json` |
| `nix eval` of the flake: the `.static`, `.shared` and `.default` drvPaths, `passthru.linkage` and the pinned nixpkgs input | observed pass, exit 0 — evaluation only; nothing was built | 2026-10-04, `local://foundation-resumed-gmp-nix-entrypoint-evaluation.json` |
| isolated C probe built `-OReleaseSafe` at Zig's own default C instrumentation, calling through a `volatile` function pointer declared `int (*)(void *)` and cast from a function whose first parameter is `struct probe *` | observed SIGILL, exit -4 | 2026-10-04, `local://foundation-resumed-native-callback-checked-run.json` |
| the same probe with `-fno-sanitize=function` added to the C flags — prints `callback=42` | observed pass, exit 0 | 2026-10-04, `local://foundation-resumed-native-callback-narrow-exception-run.json` |
| that same narrow binary, its signed-overflow path | observed SIGILL, exit -4 | 2026-10-04, `local://foundation-resumed-native-callback-narrow-exception-other-check-run.json` |

The last three rows are what authorises the single compile-time exception this
package takes, and `CHANGELOG.md`'s current entry explains it in full. They ran
against a standalone probe rather than against this tree: what they establish is
the width of the exception — the one check goes away, the others stay.

What none of those receipts covers is equally part of the record: no Nix build,
no devenv invocation, no installed-C consumer, no fetched consumer, no
cross-platform matrix, and no `-Druntime=true` run appear in any receipt above.

### Observed 2026-10-04/05: the source-bound cohort runs

Four driver gates ran after the wave above and each names its own receipt. The
53-cell cohort is the source-bound one: its receipt records
`source_stamp_before == source_stamp_after` (`8046351d…`), so the tree it measured
did not move under it, with `target_jobs 8` and `jobs_per_build 8`.

| what | status | date and receipt |
| --- | --- | --- |
| native eight cells — `-Druntime=false`, static × dynamic crossed with Debug, ReleaseSafe, ReleaseFast, ReleaseSmall | observed pass, exit 0 in all eight — `Build Summary: 41/41 steps succeeded; 49/49 tests passed` in each static cell and `42/42 steps` in each dynamic cell, each ending on the `smoke success` marker | 2026-10-04, `native-final-evidence/20261004T233628757747Z-69351/run.json` |
| own-loaded eight cells — the same eight configurations reached through `-Druntime=true` and this tree's own shared `libgmp` | observed pass, exit 0 in all eight — `Build Summary: 42/42 steps succeeded; 49/49 tests passed` in every cell | 2026-10-04, `loaded-final-evidence/20261004T232823091897Z-23133/run.json` |
| 53-cell `cross-test` cohort | **observed, exit 1** — raw `pass=19 fail=1 build_only=27 partial=6`, corrected `pass 19 / build_only 33 / build_fail 1`; every executed cell reports `tests=49`, and the one build failure is `hexagon-linux` | 2026-10-04, `20261004T224549506489Z-25324/gmp-53-target-8.json` |
| compile-only `zig build check` baseline over the six triples | observed pass, exit 0 — `Build Summary: 133/133 steps succeeded`, `declared_target_count 6`, all six named in the run's own step lines, `test_pass_lines: []` | 2026-10-05, `baselines-and-configs/20261005T014547Z-797a73f2`, row `baseline-gmp-check` |

Three things about those numbers are load-bearing and are stated rather than
rounded away.

* **`build_only` is not a pass.** A cell counted there compiled and ran nothing,
  because no executor was available for it. Six cells reported
  `reason: partial_execution` — `aarch64-maccatalyst`, `aarch64-macos`,
  `aarch64_be-netbsd`, `arm-freebsd`, `arm-netbsd`, `armeb-netbsd` — and the
  corrected audit counts each of them as `build_only`. An earlier attempt that
  scored a partial run as a pass is exactly what that correction undoes.
* **Both NetBSD targets compiled; neither was executed.**
  `aarch64-netbsd` reports `build=pass run=unavailable` and `aarch64_be-netbsd`
  reports `build=pass run=partial`, so both land in the 33. Nothing here claims a
  GMP arithmetic test ran on NetBSD.
* **The Hexagon cell is a build refusal, not a compiler failure.** GMP 6.3.0 ships
  no Hexagon port, and `vendor/gmp/zig/config_gen.zig:122-171` names the
  architectures it holds facts for and refuses the rest at `:169`.

The `check` row is compile-only by its own construction and by the receipt's own
`runtime_pass_claimed: false`: it derives no runtime result under any exit code,
and `test_pass_lines` is empty because that run printed no test count.

**The bound on the cohort.** Its source identity is its own epoch and nothing
later. Edits to this SDK's graph, helpers or normalisation that landed after
`20261004T224549506489Z-25324` are not covered by these counts, and no row above is
retroactively widened to cover them. `CHANGELOG.md` entry 28 and `FORK-NOTES.md`
note 45 carry the same 53-cell result and the NetBSD preservation comparison
beside it.

### Pending verification for this migration

| what | status |
| --- | --- |
| installed C consumer, both with `pkg-config --cflags --libs gmp` and with `-I$prefix/include -lgmp` | PENDING-VERIFICATION |
| fetched Zig consumer, filtered against `build.zig.zon` paths | PENDING-VERIFICATION |
| the runtime-loading route's limb-width refusal: a `-Druntime=true` load against a provider whose limb width does not match | PENDING-VERIFICATION — the build-and-run half of this route is observed above (eight cells at `-Druntime=true` against this tree's own shared `libgmp`, `provider.kind: "own"`), so this row is only about the unexercised refusal, not about missing code; see [Runtime loading](#runtime-loading) |
| `nix build .#static` and `nix build .#shared`, with their installed-output dependency records | PENDING-VERIFICATION — the three entry points evaluate to real drvPaths; no derivation has been built |
| the devenv shell and `devenv build outputs.static` / `outputs.shared` | PENDING-VERIFICATION |

Three rows this table used to carry are gone because the runs above replaced
them. The static install and the shared install are both covered by the eight
native cells, which install into a scratch prefix, and so are all four optimize
modes for both variants. The full 53-platform `cross-test` is now the observed
cohort row above, with its 19 runtime passes, 33 build-only cells and one Hexagon
build failure named rather than summarised. What an *observed* install does not
yet establish is the downstream C route, which is still the first row here.

The canonical commands, once the driver runs them, are:

```sh
zig build
zig build smoke test -Doptimize=Debug        -Dlinkage=static
zig build smoke test -Doptimize=ReleaseSafe   -Dlinkage=static
zig build smoke test -Doptimize=ReleaseFast   -Dlinkage=static
zig build smoke test -Doptimize=ReleaseSmall  -Dlinkage=static
zig build smoke test -Doptimize=Debug        -Dlinkage=dynamic
zig build smoke test -Doptimize=ReleaseSafe   -Dlinkage=dynamic
zig build smoke test -Doptimize=ReleaseFast   -Dlinkage=dynamic
zig build smoke test -Doptimize=ReleaseSmall  -Dlinkage=dynamic
zig build check
cd consumer && zig build run
```

with `-j2` or more, `--cache-dir` on an approved scratch mount and
`--summary all`.
`zig build check` compiles and never runs: it proves the public surface builds
for a target, not that its arithmetic agrees on that architecture. Native runs
are the behavioural evidence.

## Consumption

### As a Zig dependency

```zig
// build.zig of a dependent package
const gmp_dep = b.dependency("gmp", .{ .target = target, .optimize = optimize });
const gmp = gmp_dep.module("gmp");
module.addImport("gmp", gmp);
module.linkLibrary(gmp_dep.artifact("gmp"));
```

`dep.artifact("gmp")` is the library with the **generated** `gmp.h` in its include
tree, which is all a C or `translate-c` consumer needs. `dep.module("gmp")` adds
the typed facade and the complete translated C API as `gmp.c`. A complete
runnable consumer is in `consumer/`:

```sh
cd consumer && zig build run
```

### As a C library from an installed package

The installed package carries the library, the public headers, the
`pkg-config` metadata and the licence and authorship material. On ELF the
layout is:

```
bin/gmp-example                 this package's self-checking example
include/gmp.h                   generated for the target that was built
include/gmp-mparam.h            from mpn/generic/gmp-mparam.h
include/gmp_all.h               the aggregate header handed to translate-c
lib/libgmp.a                    static variant (the default)
lib/libgmp.so.10.5.0            shared variant, real shared object (ELF)
lib/libgmp.so.10                symlink; also the ELF SONAME
lib/libgmp.so                   symlink
lib/pkgconfig/gmp.pc            rendered from gmp.pc.in: -I${includedir},
                                -L${libdir} -lgmp
share/licenses/gmp/             COPYING, COPYINGv2, COPYINGv3,
                                COPYING.LESSERv3, NOTICE.md,
                                FORK-LICENSE.md, UPSTREAM.md,
                                README.upstream.md
share/doc/gmp/                  AUTHORS, NEWS, README
```

Two facts about that layout, and who is responsible for each. **Ownership:**
`build.zig`'s install step owns every path in it — the library, the three
public headers, `lib/pkgconfig/gmp.pc`, `gmp-example`, the four upstream licence
texts and this fork's own `NOTICE.md`, `FORK-LICENSE.md`, `UPSTREAM.md` and
`README.upstream.md` under `share/licenses/gmp/`, and `AUTHORS`, `NEWS` and
`README` under `share/doc/gmp/`. The Nix derivation installs that same tree and
writes no path of its own, so no installed file has two writers, and
`tools/provenance_gate.sh` names all eight licence-directory records against
`build.zig`, so none can be dropped quietly. **The shared-variant file names**
follow from the libtool numbers upstream's own `Makefile.am:107-109` carries
(`LIBGMP_LT_CURRENT 15`, `LIBGMP_LT_REVISION 0`, `LIBGMP_LT_AGE 5`, which give
the file `libgmp.so.10.5.0` and the soname `libgmp.so.10`) and are declared at
`build.zig:83`. The 2026-10-04 shared install did write `libgmp.so.10.5.0`
with both symlinks beside it in the prefix that run installed into; the two
non-ELF rows below are still source-confirmed and unobserved, so read the
platform table as a claim about names rather than as a list of files that run.

| platform | installed files | loader basename |
| --- | --- | --- |
| ELF (Linux) | `lib/libgmp.so.10.5.0`, symlink `libgmp.so.10` (also the SONAME), symlink `libgmp.so` | `libgmp.so.10` |
| Darwin | `lib/libgmp.10.dylib`, symlink `libgmp.dylib` | `libgmp.10.dylib` |
| Windows (mingw) | `bin/gmp.dll`, `lib/gmp.lib` — no symlinks, which is what `wantSharedLibSymLinks` means on Windows | `gmp.dll` |

The static variant is a plain `libgmp.a` on every platform: no version, no
soname.

`gmp.pc` is derived metadata, not a licence file: it reports the include and
library paths, and the obligations come from the licence texts beside it. A C
consumer may use `pkg-config --cflags --libs gmp`, and `-I$prefix/include
-lgmp` works identically without it. GMP's `config.h` is deliberately not
installed: it is private to building this tree and would shadow an
autotools-configured dependent's own `config.h`.

Neither variant is a wholly static closure. The library's external link closure
is the C runtime and nothing else — no compiled translation unit includes
`<math.h>`, and the three host table generators that do
link `libm` are build-time programs that are not part of the artifact — but a
consumer of `libgmp.a` still links its own libc and a shared `libgmp` still
resolves against the system one. No wholly static executable is promised
anywhere in this package.

`consumer/` forwards both delivery options rather than only the runtime one:
`-Dlinkage` and `-Druntime` are declared there and handed to the dependency
(`consumer/build.zig:31-50`), so the separate package can be built against the
shared artifact and against the loaded route. Their defaults are the
dependency's, static and linked, so `cd consumer && zig build run` is still the
linked static consumer.

### With Nix

```sh
nix build .#static    # libgmp.a; also .#default, this fork's linkage policy
nix build .#shared    # libgmp.so with libtool's version and soname
nix develop           # tools only; does not build the library
```

`package.nix` is one derivation taking `{ lib, stdenv, zig, linkage ? "static" }`;
the variants are the entry points, not a second convention in that file. Inside
the devenv shell the packaging route is `devenv build outputs.static` and
`devenv build outputs.shared`, which build the same derivation on demand.
`devenv` is the canonical environment; `nix develop` is for parity.

Both entry points name their input by revision rather than by channel:
`flake.nix:4` pins `github:NixOS/nixpkgs/c7def046b9a883d46974757852106483d741586f`
and `devenv.yaml` pins the devenv distribution of nixpkgs the same way. The
flake's resolution is committed beside them as `flake.lock`, so these entry
points build against the input this tree resolved rather than resolving a new
one, and `package.nix` names no input of its own beyond this directory, which
is why one derivation serves all three of them.

### Against an installed GMP instead of this tree

`zig build -fsys=gmp` links an installed GMP. In that mode the generated header
is deliberately kept off the include line, so the translated declarations come
from the installed `gmp.h` and always describe the library that is linked. The
facade uses only long-standing public GMP API, so it works against GMP 5 or
later, and the limb size then follows the installed library.

### Runtime loading

`zig build -Druntime=true` builds the module's second shape, and that shape is
in this tree: the reusable core is `runtime/loader.zig`, GMP's half of it is
`runtime/library.zig`, and `runtime/graph.zig` generates the dispatch that the
module's `c` import becomes. Nothing in that configuration links `libgmp` — the
symbols arrive through the platform loader when the program calls `gmp.load` —
and `gmp.loadedSource()` reports the request that succeeded. `README.zig.md`
documents that Zig surface under
[Runtime loading](README.zig.md#runtime-loading). What follows is what GMP
itself fixes for such a route, read from the sources, so it is not rediscovered
badly later:

* Every public entry point is exported under its internal name:
  `mpz_mul` is `#define mpz_mul __gmpz_mul` (`gmp-h.in:934-935`). A loader
  resolves `__gmpz_mul`, `__gmpq_*`, `__gmpf_*`, `__gmpn_*`, `__gmp_rand*`,
  `__gmp_printf`, `__gmp_scanf`, `__gmp_set_memory_functions` and
  `__gmp_get_memory_functions`, and not the macro names.
* Three exported data symbols state facts a candidate can be asked about rather
  than assumed: `__gmp_version` (`gmp-h.in:496-497`), `__gmp_errno`
  (`gmp-h.in:493-494`) and `__gmp_bits_per_limb` (`gmp-h.in:490-491`). The
  module reads all three through guarded accessors — `gmp.providerVersion`,
  `gmp.providerErrno`, `gmp.providerBitsPerLimb` — so a program sees the
  provider's own values rather than copies taken at build time.
* Symbol presence is not ABI proof, and neither is the version string. The limb
  width, limb type, endianness and `GMP_NAIL_BITS` are compiled into both the
  header and the library and determine the layout of `__mpz_struct`, `__mpq_struct`
  and `__mpf_struct` and the signatures of every `mpn` entry point. A candidate
  libgmp built with a different limb configuration than the header this module was
  translated from is **not** ABI compatible, and no symbol check can prove
  otherwise. This fork always builds `GMP_NAIL_BITS 0`
  (`zig/config_gen.zig:43-45`) and derives the rest per target
  (`zig/config_gen.zig:183-227`): 64-bit limbs wherever `unsigned long` or the
  pointer is 64 bits, 32-bit limbs on 32-bit pointer targets, limb endianness
  from the target's architecture.
* Of all of that, exactly one thing is checked when a provider is loaded: the
  provider's `__gmp_bits_per_limb` must equal the `GMP_LIMB_BITS` this build's
  `gmp.h` declares (`runtime/library.zig`, `Config.validate`). That is the one
  fact that decides whether the three structs the two sides share have the same
  layout, and it costs one load of a `const int` the provider has already
  initialised. A candidate that fails it is closed, nothing is published, and
  the error names both numbers.
* A provider is reached, never guessed. `.path` is a file and `.system` is a
  name for the platform loader; neither falls back to the other, there is no
  unload and no reset, and a run that was told nothing is told it was told
  nothing rather than quietly handed whatever happens to be installed.
* GMP's allocator hooks are process-global (`gmp-h.in:480-488`), so a program
  that loads a candidate must install its allocator before any GMP value exists,
  and every value allocated through one candidate must be released through that
  same one.

**Observed 2026-10-04/05.** Everything above is read out of `build.zig`,
`runtime/loader.zig`, `runtime/library.zig` and GMP's own sources; the
configuration itself was then run. The own-loaded eight-cell row of the
[support matrix](#support-matrix) is that run — the same eight configurations
reached through `-Druntime=true` and this tree's own shared `libgmp`
(`provider.kind: "own"`), exit 0 in all eight — receipt
`loaded-final-evidence/20261004T232823091897Z-23133/run.json`. What that receipt
does not reach is the [Pending verification for this
migration](#pending-verification-for-this-migration) table above; in this
section, it is the limb-width refusal and nothing else. No cell loaded a
*foreign* provider, so what is observed here is that this tree's own shared
`libgmp` is reachable through the platform loader, not that a mismatched one is
caught.

## Zig interface

`README.zig.md` documents the module: the facade types, the ownership and memory
rules that follow GMP's own allocator contract, the raw `gmp.c` escape hatch,
the `load`/`loadedSource` runtime surface and what a provider has to be, the
steps and the backend differences.

## Licence

The library this package builds is dual licensed: GNU LGPLv3 or later, or GNU
GPLv2 or later, at the user's option. This package selects **LGPLv3** and builds
and links accordingly; the GPLv2 option is left available exactly as upstream
offers it. All four upstream licence texts ship with the source:
`COPYING`, `COPYINGv2`, `COPYINGv3` and `COPYING.LESSERv3`.

`NOTICE.md` is the per-file inventory, with file and line anchors: the tree is
not one licence, because the upstream test suite and several demonstrations are
GPLv3 or later, the manual is GFDL 1.3 or later, and the autotools scaffolding
carries Free Software Foundation, GNU Libtool and X Consortium terms of its own.
`FORK-LICENSE.md` records the licence of the files this fork adds and the
owner's authorization for it. Being private changes nothing about any of this.