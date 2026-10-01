#!/bin/sh
# Source licence and provenance integrity gate.
#
# This fork imports the GNU MP library, which is dual licensed under the LGPL
# and the GPL. Private hosting changes nothing about that, so the gate exists to
# make a silent relicensing or a corrupted licence text impossible to merge:
#
#   * the four upstream licence texts must be present and byte identical to the
#     ones in the GMP 6.3.0 release archive,
#   * the provenance record must still carry the archive digest,
#   * the library licence selection must still say LGPLv3 or later, or GPLv2 or
#     later, and no file may claim a permissive licence for libgmp.
#
# Usage: tools/provenance_gate.sh [repo-root]
# Run from the repository root or pass the root explicitly. Exits non zero on
# the first problem, with a message naming it.

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

check_digest COPYING           8ceb4b9ee5adedde47b31e975c1d90c73ad27b6b165a1dcd80c7c545eb65b903
check_digest COPYINGv2         8177f97513213526df2cf6184d8ff986c675afb514d4e68a404010521b880643
check_digest COPYINGv3         e6037104443f9a7829b2aa7c5370d0789a7bda3ca65a0b904cdc0c2e285d9195
check_digest COPYING.LESSERv3  a853c2ffec17057872340eee242ae4d96cbf2b520ae27d903e1b2fef1a5f9d1c

[ -f UPSTREAM.md ] || fail "missing provenance record: UPSTREAM.md"
grep -q 'a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898' UPSTREAM.md ||
    fail "UPSTREAM.md no longer records the GMP 6.3.0 archive digest"
grep -q 'gmplib.org/repo/gmp' UPSTREAM.md ||
    fail "UPSTREAM.md no longer names the canonical Mercurial upstream"

[ -f NOTICE.md ] || fail "missing NOTICE.md"
grep -qi 'LGPL' NOTICE.md || fail "NOTICE.md does not record the LGPL terms"
grep -qi 'GPL' NOTICE.md || fail "NOTICE.md does not record the GPL terms"

# No file may claim that libgmp is under a permissive licence.
if grep -rIl -e 'MIT License' -e 'SPDX-License-Identifier: MIT' \
        -e 'Apache License' -e 'BSD 3-Clause' \
        --include='*.zig' --include='*.zon' --include='*.md' --include='*.c' --include='*.h' \
        . >/dev/null 2>&1; then
    fail "a source or document file claims a permissive licence for a LGPL/GPL library"
fi

printf 'provenance gate: licence texts and provenance record are intact\n'
