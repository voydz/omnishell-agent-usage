#!/bin/bash
# Points codexbar.lock at a CodexBar release (the latest one by default) and
# records the checksums of its macOS CLI tarballs.
set -euo pipefail

UPSTREAM="steipete/CodexBar"
LOCK_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)/codexbar.lock"

TMP_DIR=""
trap '[ -z "$TMP_DIR" ] || rm -rf "$TMP_DIR"' EXIT

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

# Downloads one tarball and prints its sha256, after checking it against the
# digest GitHub recorded for the asset.
checksum() {
    local tag="$1" arch="$2" name actual published
    name="CodexBarCLI-$tag-macos-$arch.tar.gz"
    gh release download "$tag" --repo "$UPSTREAM" --pattern "$name" --dir "$TMP_DIR" >&2 \
        || die "release $tag has no asset $name"
    tar -tzf "$TMP_DIR/$name" | grep -qx 'CodexBarCLI' \
        || die "$name has no CodexBarCLI executable"
    actual="$(shasum -a 256 "$TMP_DIR/$name" | awk '{print $1}')"
    published="$(gh api "repos/$UPSTREAM/releases/tags/$tag" \
        --jq ".assets[] | select(.name == \"$name\") | .digest // \"\"")"
    if [ -n "$published" ] && [ "$published" != "sha256:$actual" ]; then
        die "$name does not match the digest GitHub published ($published)"
    fi
    printf '%s' "$actual"
}

main() {
    local tag version current arm64 x86_64
    command -v gh >/dev/null || die "this script needs the GitHub CLI (gh)"
    [ -f "$LOCK_FILE" ] || die "missing $LOCK_FILE"

    if [ $# -gt 0 ]; then
        tag="v${1#v}"
    else
        tag="$(gh api "repos/$UPSTREAM/releases/latest" --jq .tag_name)"
    fi
    version="${tag#v}"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "unexpected release tag: $tag"

    current="$(sed -n 's/^version=//p' "$LOCK_FILE")"
    if [ "$current" = "$version" ]; then
        printf 'codexbar.lock is already at %s.\n' "$version"
        return 0
    fi

    TMP_DIR="$(mktemp -d)"
    arm64="$(checksum "$tag" arm64)"
    x86_64="$(checksum "$tag" x86_64)"
    sed -e "s/^version=.*/version=$version/" \
        -e "s/^sha256_macos_arm64=.*/sha256_macos_arm64=$arm64/" \
        -e "s/^sha256_macos_x86_64=.*/sha256_macos_x86_64=$x86_64/" \
        "$LOCK_FILE" > "$TMP_DIR/codexbar.lock"
    cat "$TMP_DIR/codexbar.lock" > "$LOCK_FILE"
    printf 'codexbar.lock: %s -> %s\n' "$current" "$version"
}

main "$@"
