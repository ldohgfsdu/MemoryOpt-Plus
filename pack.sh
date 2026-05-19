#!/bin/bash
set -euo pipefail

MODULE_NAME="MemoryOpt_Plus"
VERSION=$(grep "^version=" module.prop 2>/dev/null | head -n1 | cut -d'=' -f2- | sed 's/^[[:space:]]*//')
[ -z "$VERSION" ] && VERSION="v4.1.0"
OUTPUT="${MODULE_NAME}_${VERSION}.zip"

echo "==> Building memoptd (if source exists)..."
if [ -f "memoptd/Cargo.toml" ]; then
    ( cd memoptd && bash build.sh )
    cp -f memoptd/out/memoptd bin/ 2>/dev/null || true
else
    echo "  (Rust source not found, skipping)"
fi

echo "==> Assembling module..."

rm -f "${OUTPUT}"
rm -rf _pack
mkdir -p _pack/bin _pack/META-INF/com/google/android

# 复制所有模块文件
for f in module.prop customize.sh service.sh post-fs-data.sh uninstall.sh common.sh memory.sh swap.ini README.md; do
    [ -f "$f" ] && cp "$f" _pack/
done

# 复制二进制
cp -f bin/* _pack/bin/ 2>/dev/null || true

# 复制 META-INF
cp -f META-INF/com/google/android/update-binary META-INF/com/google/android/updater-script _pack/META-INF/com/google/android/

# 打包
cd _pack
zip -r9 "../${OUTPUT}" . >/dev/null
cd ..

rm -rf _pack
echo "==> Done: ${OUTPUT}"
ls -lh "${OUTPUT}"
