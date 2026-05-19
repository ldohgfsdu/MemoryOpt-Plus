#!/bin/bash
set -euo pipefail

TARGET="${1:-aarch64-unknown-linux-musl}"
OUT_DIR="out"
BIN_NAME="memoptd"

echo "==> Installing target: ${TARGET}"
rustup target add "${TARGET}" 2>/dev/null || true

echo "==> Building ${BIN_NAME} for ${TARGET}"
RUSTFLAGS="-C target-feature=+crt-static" cargo build --release --target "${TARGET}"

mkdir -p "${OUT_DIR}"
cp "target/${TARGET}/release/${BIN_NAME}" "${OUT_DIR}/"

command -v upx >/dev/null 2>&1 && upx --best --lzma "${OUT_DIR}/${BIN_NAME}" 2>/dev/null || true

echo "==> Done:"
ls -lh "${OUT_DIR}/${BIN_NAME}"
file "${OUT_DIR}/${BIN_NAME}"
