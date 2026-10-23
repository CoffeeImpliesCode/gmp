#!/bin/sh
# Source licence and provenance integrity gate.
#
# This fork imports the GNU MP library, which is dual licensed under the LGPL
# and the GPL, and adds files of its own. Private hosting changes nothing about
# either, so the gate exists to make six failures impossible to merge:
#
#   * any upstream file this package carries stops matching the pinned bytes in
#     UPSTREAM.sha256 -- one changed native source, header, table input, test,
#     build file or licence text, or one of them going missing,
#   * UPSTREAM.sha256 itself goes missing, shrinks, or stops being a list of
#     digest records, so that the check above quietly stops checking,
#   * an upstream licence text is missing or edited,
#   * upstream's own README stops being preserved verbatim,
#   * the fork's licence record, its provenance record or the packaging that
#     ships those texts goes missing or drifts from the pinned inputs,
#   * a source, document or packaging file claims a permissive licence for this
#     copyleft library.
#
# The gate reads files only. It needs sha256sum, grep, sed, wc and cmp, and no
# Zig build, no compiler and no network, so CI can run it first and a developer
# can run it before anything else.
#
# Usage: tools/provenance_gate.sh [repo-root]
# Run from the repository root or pass the root explicitly. Exits non zero on the
# first problem, with a message naming it.

set -eu

root="${1:-.}"
cd "$root"

fail() {
    printf 'provenance gate: %s\n' "$1" >&2
    exit 1
}

# sha256sum is coreutils; if it is missing the gate cannot prove anything.
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is required"

check_digest() {
    file="$1"
    expected="$2"
    [ -f "$file" ] || fail "missing licence text: $file"
    actual=$(sha256sum "$file" | cut -d' ' -f1)
    if [ "$actual" != "$expected" ]; then
        fail "$file was modified (expected $expected, found $actual)"
    fi
}

check_present() {
    [ -f "$1" ] || fail "missing file: $1"
}

# 1. The per-file record: every upstream byte this package carries, against the
#    pinned GNU MP 6.3.0 release archive. This is the check that catches a
#    changed native byte; the licence checks below are a strict subset of it.
check_present UPSTREAM.sha256

# Comments are stripped here rather than left to sha256sum, which tolerates them
# only on some builds. What is left must be nothing but digest records, or a
# corrupted line would be skipped rather than failing. Everything below reads
# the record through this filter, so the gate writes nothing into the tree.
records_filter() { grep -v '^#' UPSTREAM.sha256; }

# The record states its own size in its header. Reading the count from there
# keeps one source for it, and comparing it with the number of records present
# makes a manifest that silently lost native files fail instead of pass.
declared=$(sed -n 's/^# \([0-9][0-9]*\) records, [0-9][0-9]* bytes\.$/\1/p' UPSTREAM.sha256 | head -1)
[ -n "$declared" ] ||
    fail "UPSTREAM.sha256 states no record count, so it cannot be checked for shrinkage"
records=$(records_filter | wc -l)
[ "$records" = "$declared" ] ||
    fail "UPSTREAM.sha256 declares $declared records but carries $records"
[ "$records" -ge 2156 ] ||
    fail "UPSTREAM.sha256 holds $records records; the pinned tree has 2156 files"
if records_filter | grep -qv '^[0-9a-f]\{64\}  '; then
    fail "UPSTREAM.sha256 holds a line that is not a SHA-256 record"
fi

if ! records_filter | sha256sum --quiet -c -; then
    fail "a file recorded in UPSTREAM.sha256 is missing or no longer matches the pinned archive"
fi

# The record must keep naming what it pins. A record that has quietly stopped
# describing the GMP 6.3.0 archive, or that has dropped its honesty about the
# detached signature it cannot check, is not a record of anything.
grep -q 'a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898' UPSTREAM.sha256 ||
    fail "UPSTREAM.sha256 no longer records the GMP 6.3.0 archive digest"
grep -q 'https://gmplib.org/download/gmp/gmp-6.3.0.tar.xz' UPSTREAM.sha256 ||
    fail "UPSTREAM.sha256 no longer names the archive it was derived from"
grep -q 'UNVERIFIED' UPSTREAM.sha256 ||
    fail "UPSTREAM.sha256 no longer marks the detached signature UNVERIFIED"

# Upstream's README is carried at its upstream name and is a record. The copy
# under the fork's name is the fork's own file and must not be one.
grep -q '^[0-9a-f]\{64\}  README$' UPSTREAM.sha256 ||
    fail "UPSTREAM.sha256 does not record upstream's README"
if grep -q '^[0-9a-f]\{64\}  README\.upstream\.md$' UPSTREAM.sha256; then
    fail "README.upstream.md is a fork-authored copy and must not be an upstream record"
fi

# A record may not name a fork-authored path, or a later change could record
# this fork's own bytes as upstream's and pass.
for f in build.zig build.zig.zon root.zig package.nix .gitignore NOTICE.md \
         README.md README.upstream.md CHANGELOG.md; do
    if grep -q "^[0-9a-f]\{64\}  $f\$" UPSTREAM.sha256; then
        fail "UPSTREAM.sha256 records $f, which is this fork's own file"
    fi
done

# 2. The four upstream licence texts, byte for byte.
check_digest COPYING           8ceb4b9ee5adedde47b31e975c1d90c73ad27b6b165a1dcd80c7c545eb65b903
check_digest COPYINGv2         8177f97513213526df2cf6184d8ff986c675afb514d4e68a404010521b880643
check_digest COPYINGv3         e6037104443f9a7829b2aa7c5370d0789a7bda3ca65a0b904cdc0c2e285d9195
check_digest COPYING.LESSERv3  a853c2ffec17057872340eee242ae4d96cbf2b520ae27d903e1b2fef1a5f9d1c

# 3. Upstream's README survives under both names, and this fork's README is
#    not upstream's text.
upstream_readme_digest=5e9f9325fd702bc4bcda27d7a78fea88a2a09fa39b4b15ac7b9b205e0863dc7e
check_digest README           "$upstream_readme_digest"
check_digest README.upstream.md "$upstream_readme_digest"
check_present README.md
if cmp -s README.md README.upstream.md; then
    fail "README.md is upstream's text; the fork README must be its own"
fi

# 4. The provenance record still names the archive, the digest and the canonical
#    (Mercurial) upstream.
check_present UPSTREAM.md
grep -q 'a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898' UPSTREAM.md ||
    fail "UPSTREAM.md no longer records the GMP 6.3.0 archive digest"
grep -q 'gmplib.org/repo/gmp' UPSTREAM.md ||
    fail "UPSTREAM.md no longer names the canonical Mercurial upstream"

# 5. The licence record: the fork's own terms, the owner's authorization, and the
#    per-file inventory with the terms that are easy to get wrong.
check_present NOTICE.md
grep -qi 'LGPL' NOTICE.md || fail "NOTICE.md does not record the LGPL terms"
grep -qi 'GPL' NOTICE.md || fail "NOTICE.md does not record the GPL terms"
grep -q 'GPL-3.0-or-later' NOTICE.md ||
    fail "NOTICE.md does not record the GPL-3.0-or-later terms of tests/ and demos/"
grep -q 'GFDL-1.3-or-later' NOTICE.md ||
    fail "NOTICE.md does not record the GFDL terms of the manual"
grep -q 'Libtool' NOTICE.md ||
    fail "NOTICE.md does not record the terms of ltmain.sh and the libtool notices"
grep -q 'X Consortium' NOTICE.md ||
    fail "NOTICE.md does not record the terms of install-sh"
grep -q 'README.upstream.md' NOTICE.md ||
    fail "NOTICE.md no longer distinguishes the preserved upstream README"

check_present FORK-LICENSE.md
grep -q 'LGPL-3.0-or-later' FORK-LICENSE.md ||
    fail "FORK-LICENSE.md does not record the LGPL-3.0-or-later grant for this fork's files"
grep -qi 'owner' FORK-LICENSE.md ||
    fail "FORK-LICENSE.md does not record the owner's authorization"
grep -q 'README.upstream.md' FORK-LICENSE.md ||
    fail "FORK-LICENSE.md must exclude the preserved upstream README from the fork grant"

# 6. The packaging files exist, pin the agreed inputs, and stay portable.
for f in package.nix flake.nix devenv.nix devenv.yaml .envrc; do
    check_present "$f"
done
grep -q 'github:NixOS/nixpkgs/02c087f3fe673c9e317f206a627cb6b910336dbe' flake.nix ||
    fail "flake.nix does not pin the agreed nixpkgs revision"
grep -q 'github:cachix/devenv-nixpkgs/760b85220489f69855e6df78a6d1dad5873f8bf6' devenv.yaml ||
    fail "devenv.yaml does not pin the agreed devenv nixpkgs revision"
# Both entry points inject the same pinned compiler into the one derivation.
grep -q 'zig = pkgs\.zig_0_17' flake.nix ||
    fail "flake.nix does not inject zig = pkgs.zig_0_17"
grep -q 'zig = pkgs\.zig_0_17\|inherit.*zig' devenv.nix ||
    fail "devenv.nix does not inject the pinned zig into package.nix"
grep -q 'callPackage \./package\.nix' flake.nix ||
    fail "flake.nix does not build the variants from package.nix"
grep -q 'callPackage \./package\.nix' devenv.nix ||
    fail "devenv.nix does not build its outputs from package.nix"

# A package that only works from one checkout is a portability bug: no sibling
# import, no host path, no build-time download. Scratch locations come from the
# caller's environment, so none may be written into these files.
for f in package.nix flake.nix devenv.nix; do
    if grep -n '\.\./' "$f" >/dev/null 2>&1; then
        fail "$f imports a sibling directory"
    fi
    if grep -n '/nix/store\|gertullj\|/home/\|/vol/tmp\|getEnv\|builtins\.currentSystem' "$f" >/dev/null 2>&1; then
        fail "$f names a host path or reads host state"
    fi
    if grep -ni 'fetchurl\|fetchgit\|fetchFromGitHub\|builtins\.fetch' "$f" >/dev/null 2>&1; then
        fail "$f downloads something at build time"
    fi
done

# Licence material must reach the installed library, and one build step owns all
# of it: `build.zig`'s install step writes the four upstream grants and this
# fork's own four records into `share/licenses/gmp`, and `package.nix` writes no
# installed path, so a native prefix and a Nix package carry the same records.
# All eight are named against that one owner here, so none can be dropped
# quietly.
check_present build.zig
for f in COPYING COPYINGv2 COPYINGv3 COPYING.LESSERv3 \
         NOTICE.md FORK-LICENSE.md UPSTREAM.md README.upstream.md; do
    grep -q "\"$f\"" build.zig || fail "the build does not install $f"
done

# 7. No file may claim that this copyleft library is under a permissive licence.
if grep -rIl -e 'MIT License' -e 'SPDX-License-Identifier: MIT' \
        -e 'Apache License' -e 'BSD 3-Clause' \
        --include='*.zig' --include='*.zon' --include='*.md' --include='*.c' \
        --include='*.h' --include='*.nix' --include='.envrc' \
        . >/dev/null 2>&1; then
    fail "a source, document or packaging file claims a permissive licence for a LGPL/GPL library"
fi

printf 'provenance gate: %s recorded upstream files match the pinned archive\n' "$records"
printf 'provenance gate: licence texts, upstream README, provenance record and packaging are intact\n'