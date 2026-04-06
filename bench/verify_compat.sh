#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMPDIR_COMPAT=$(mktemp -d "${TMPDIR:-/tmp}/bcs-compat.XXXXXX")
trap 'rm -rf "$TMPDIR_COMPAT"' EXIT

run_pair() {
    name="$1"
    rust_bin="$2"
    zig_root="$3"
    rust_out="$TMPDIR_COMPAT/$name.rust"
    zig_out="$TMPDIR_COMPAT/$name.zig"

    (
        cd "$ROOT"
        RUSTFLAGS="-Awarnings" cargo run --quiet --release --manifest-path bench/Cargo.toml --bin "$rust_bin"
    ) >"$rust_out"

    (
        cd "$ROOT"
        ZIG_GLOBAL_CACHE_DIR="$TMPDIR_COMPAT/zig-cache" \
            zig run -OReleaseFast --dep bcs -Mroot="$zig_root" -Mbcs=src/bcs.zig
    ) >"$zig_out" 2>&1

    diff -u "$rust_out" "$zig_out"
}

run_pair "crossval" "crossval" "bench/crossval.zig"
run_pair "sui_crossval" "sui_crossval" "bench/sui_crossval.zig"
run_pair "deser_crossval" "deser_crossval" "bench/deser_crossval.zig"
run_pair "limit_crossval" "limit_crossval" "bench/limit_crossval.zig"
run_pair "random_crossval" "random_crossval" "bench/random_crossval.zig"
run_pair "error_crossval" "error_crossval" "bench/error_crossval.zig"
run_pair "mutation_crossval" "mutation_crossval" "bench/mutation_crossval.zig"
run_pair "reader_crossval" "reader_crossval" "bench/reader_crossval.zig"
run_pair "seed_crossval" "seed_crossval" "bench/seed_crossval.zig"
run_pair "corpus_crossval" "corpus_crossval" "bench/corpus_crossval.zig"

printf '%s\n' 'compatibility checks passed'
