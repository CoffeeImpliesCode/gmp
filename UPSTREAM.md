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
relying on the signature.

## What was imported

The complete contents of `gmp-6.3.0/`, extracted at the repository root with
timestamps and permissions preserved, plus this fork's build, package, test,
documentation and CI files. The import was verified to be identical to the
extracted archive before any fork file was added:

```sh
tar -xJf gmp-6.3.0.tar.xz
diff -r --brief gmp-6.3.0 <repo-without-fork-files>
```

Upstream files keep their upstream paths and names. No upstream source file was
edited: `gmp-impl.h`, the `mpn/generic/*.c` sources, `Makefile.am`, `configure`
and the rest are byte identical to the release. Everything this fork adds lives
in `build.zig`, `build.zig.zon`, `root.zig`, `include/`, `zig/`, `tools/`,
`consumer/`, `.gitignore`, `.github/`, and the Markdown files at the root.

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
| `tools/provenance_gate.sh` | licence and provenance integrity gate |
| `.github/workflows/ci.yml` | native tests, smoke, cross target check, provenance gate |

## Synchronising with a new upstream release

1. Fetch the new release archive from the primary URL, record its SHA256, and
   verify the detached signature with the GMP release key.
2. Extract it and replace the upstream files in place. Do not touch
   `build.zig`, `root.zig` or anything under `zig/`, `include/`, `tools/`,
   `consumer/`, unless the change requires it.
3. Re-check the lists in `zig/sources.zig` against the new `Makefile.am` and
   `mpn/generic/` contents, and the function signatures in `zig/*.zig` against
   the new `gmp-h.in`.
4. Update the digest table above and add a numbered entry to `CHANGELOG.md`.

## Generated files are not upstream files

`gmp.h`, `config.h`, `gmp-mparam.h`, the table headers and `mpn/fib_table.c` and
`mpn/mp_bases.c` are produced during the build, from templates that are upstream
files (`gmp-h.in`, `config.in`, `gen-*.c`). They are written to the Zig cache
directory, never into the source tree, and `.gitignore` excludes them.
