#!/usr/bin/env bash
# 02 — install host build deps, fetch Chromium's toolchain (clang/lld, rust, sysroot, node)
# and build `gn`. The same clang/lld is also the cross-compiler for the Windows target.
# Run AFTER patches are applied. Idempotent.
#
#   WORK   working dir (default: ~/clearcote-build)
set -euo pipefail
WORK="${WORK:-$HOME/clearcote-build}"
SRC="$WORK/build/src"
UG="$WORK/ungoogled-chromium"
cd "$SRC"

# System packages Chromium needs (Debian/Ubuntu). On other distros install the equivalents.
# Run with sudo if you are not root.
python3 build/install-build-deps.py --no-prompt \
  || sudo python3 build/install-build-deps.py --no-prompt \
  || echo "warn: install-build-deps did not complete — ensure host build packages are present"

# If the patch stage applied ungoogled "domain substitution", REVERT it before any network
# fetch: it rewrites the toolchain download URLs (e.g. commondatastorage.googleapis.com) and
# breaks clang/rust fetching. Safe to run even if it was never applied.
CACHE="$WORK/build/domsubcache.tar.gz"
if [ -f "$CACHE" ]; then
  echo "reverting domain substitution before toolchain fetch"
  python3 "$UG/utils/domain_substitution.py" revert -c "$CACHE" "$SRC" || echo "warn: domsub revert"
fi

# Chromium clang/lld (host + Windows cross)
# update.py 只有在 src 上層的 .gclient 宣告 target_os=['win'] 時，才會另外下載 Windows 的 clang
# runtime（clang_rt.builtins-x86_64.lib 等，連結時必需）。我們不跑 gclient，所以自己寫一個最小的。
if [ "${TARGET:-windows}" = "windows" ] && [ ! -f "$WORK/build/.gclient" ]; then
  echo "target_os = ['win']" > "$WORK/build/.gclient"
fi
python3 tools/clang/scripts/update.py

# Rust — args.gn sets rust_sysroot_absolute="" so std is built from source; prebuilt rustc/std
# are still fetched here.
python3 tools/rust/update_rust.py || echo "warn: rust fetch (continuing)"

# amd64 sysroot for host-side tooling
python3 build/linux/sysroot_scripts/install-sysroot.py --arch=amd64 || echo "warn: sysroot (continuing)"

# Host node (normally pulled by gclient runhooks; we don't run gclient, so fetch it directly).
# NB: update_node_binaries is a SHELL script, not python — invoke it directly.
chmod +x third_party/node/update_node_binaries 2>/dev/null || true
third_party/node/update_node_binaries

# esbuild（DevTools 前端打包用）是 CIPD 預編譯檔，被 prune_binaries 刪掉了；windows overlay 的
# downloads.ini 只補 Windows 主機版，Linux 主機要自己抓 npm 上的官方 linux-x64 套件（版本同 overlay）。
ESBUILD_VER="0.25.1"
ESBUILD_DIR="third_party/devtools-frontend/src/third_party/esbuild"
if [ ! -x "$ESBUILD_DIR/esbuild" ]; then
  mkdir -p "$ESBUILD_DIR"
  curl -fsSL "https://registry.npmjs.org/@esbuild/linux-x64/-/linux-x64-${ESBUILD_VER}.tgz" \
    | tar -xz -C "$ESBUILD_DIR" --strip-components=2 package/bin/esbuild
fi
"$ESBUILD_DIR/esbuild" --version

# rc（Chromium 的跨平台 Windows 資源編譯器）：對應 DEPS 的 rc_linux hook（checkout_win 且 host
# 為 linux），平常由 gclient 依 rc.sha1 從 GCS 下載；我們不跑 gclient，自己抓並驗證 sha1。
if [ "${TARGET:-windows}" = "windows" ]; then
  RC_DIR="build/toolchain/win/rc/linux64"; RC_SHA1="$(cat "$RC_DIR/rc.sha1")"
  if [ ! -x "$RC_DIR/rc" ] || [ "$(sha1sum < "$RC_DIR/rc" | cut -d' ' -f1)" != "$RC_SHA1" ]; then
    curl -fsSL -o "$RC_DIR/rc" "https://storage.googleapis.com/chromium-browser-clang/rc/$RC_SHA1"
    [ "$(sha1sum < "$RC_DIR/rc" | cut -d' ' -f1)" = "$RC_SHA1" ] || { echo "FATAL: rc sha1 不符" >&2; exit 1; }
    chmod +x "$RC_DIR/rc"
  fi
fi

# gperf：非 Windows 主機上 blink 使用 CIPD 版的 //third_party/gperf/cipd/bin/gperf（同樣被 prune 掉），
# 改連到 install-build-deps 裝好的系統 gperf。
mkdir -p third_party/gperf/cipd/bin
ln -sfn "$(command -v gperf)" third_party/gperf/cipd/bin/gperf

# depot_tools' prebuilt `gn` refuses to bootstrap its Python as root, so build gn from the
# in-tree source using the toolchain clang we just fetched.
TC="$SRC/third_party/llvm-build/Release+Asserts/bin"
export PATH="$TC:$PATH" CC="$TC/clang" CXX="$TC/clang++" AR="$TC/llvm-ar"
# ungoogled-chromium-windows 的 windows-fix-building-gn.patch 把 bootstrap 的目標寫死成 gn.exe，
# 150 起 overlay 兩個 TARGET 都會套，Linux 主機上 ninja 找不到 gn.exe 目標。gen.py 已經產生好
# build.ninja，直接建 Linux 的 gn 目標即可（不改動原始碼樹，patch 完整性檢查不受影響）。
python3 tools/gn/bootstrap/bootstrap.py --skip-generate-buildfiles \
  || { echo "bootstrap 失敗（overlay 的 gn.exe 目標）；改為直接建置 gn"; ninja -C out/Release/gn_build gn; }
# bootstrap writes the gn binary under out/<dir>/gn_build/gn — locate it rather than assume.
GN_BIN="$(find out -type f -name gn -perm -u+x 2>/dev/null | head -1)"
[ -n "$GN_BIN" ] || { echo "FATAL: gn bootstrap produced no binary" >&2; exit 1; }
install -D "$GN_BIN" "$WORK/bin/gn"

echo "OK: host toolchain ready; gn -> $WORK/bin/gn ($("$WORK/bin/gn" --version))"
