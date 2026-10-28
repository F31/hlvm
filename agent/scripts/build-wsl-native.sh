#!/usr/bin/env bash
set -euo pipefail
export PATH="$HOME/.cargo/bin:$PATH"
SRC=/mnt/e/projects/hlvm/agent
BUILD=/tmp/build/hlvm-agent
if ! command -v cargo >/dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq curl gcc
  curl --proto =https -tlsv1.2 -sSf https://sh.rustup.rs -o /tmp/rustup.sh
  sh /tmp/rustup.sh -y --profile minimal
  export PATH="$HOME/.cargo/bin:$PATH"
  rustup component add rustfmt clippy
fi
command -v cc >/dev/null 2>&1 || apt-get install -y -qq gcc
rm -rf "$BUILD"; mkdir -p "$BUILD"; cp -r "$SRC/." "$BUILD/"
cd "$BUILD"
echo "== cargo fmt =="; cargo fmt
echo "== cargo fmt --check =="; (cargo fmt --check && echo FMT_OK) || echo FMT_FAIL
echo "== cargo clippy =="; cargo clippy --all-targets 2>&1 | tail -40
echo "== cargo build --release =="; cargo build --release 2>&1 | tail -15
echo "== cargo test =="; cargo test 2>&1 | tail -50
echo "== sync fmt back to windows src =="; cp -rf "$BUILD/src/." "$SRC/src/"
echo ALL_DONE
