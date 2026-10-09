#!/usr/bin/env bash
# 03 — assemble a Windows SDK + CRT sysroot on Linux (no Windows machine) with xwin,
# laid out the way Chromium's `package_from_installed` toolchain expects.
#
# The MSVC/SDK headers #include each other with inconsistent casing, so on a
# case-sensitive Linux filesystem the SDK *Include* tree must be served through a
# case-insensitive overlay (ciopfs). The *Lib* tree does not need this — xwin already
# emits per-case symlinks for libraries.
#
#   WORK   working dir (default: ~/clearcote-build)
set -euo pipefail
WORK="${WORK:-$HOME/clearcote-build}"
XWIN_VER="0.9.0"
SDK_VERSION="10.0.26100"            # pin the MS SDK payload xwin fetches
WINSDK="$WORK/winsdk"
TC="$WORK/wintoolchain"
# Synthetic version labels — just directory names in the layout below (symlinks/ciopfs make
# the xwin payload appear under them); they need only be internally consistent + match SetEnv.
VCVER="14.44.35207"
SDKVER="10.0.26100.0"

command -v ciopfs >/dev/null 2>&1 || { echo "FATAL: 'ciopfs' is required (apt-get install ciopfs)"; exit 1; }
command -v msiextract >/dev/null 2>&1 || { echo "FATAL: 'msitools' is required (apt-get install msitools)"; exit 1; }

# 1. fetch xwin + splat Microsoft's Windows SDK + CRT (license auto-accepted)
if [ ! -x "$WORK/bin/xwin" ] && ! command -v xwin >/dev/null 2>&1; then
  curl -L "https://github.com/Jake-Shadle/xwin/releases/download/${XWIN_VER}/xwin-${XWIN_VER}-x86_64-unknown-linux-musl.tar.gz" \
    | tar -xz -C "$WORK"
  install -D "$WORK/xwin-${XWIN_VER}-x86_64-unknown-linux-musl/xwin" "$WORK/bin/xwin"
fi
XWIN="$WORK/bin/xwin"; command -v xwin >/dev/null 2>&1 && XWIN="$(command -v xwin)"
# xwin 預設把快取放在 ./.xwin-cache；放到 $WORK 底下，與輸出同一個檔案系統（否則跨掛載點 rename 失敗）
# --include-atl：base/win 等處需要 ATL（atldef.h、atls.lib），xwin 會把它併入 crt/include 與 crt/lib
if [ ! -f "$WINSDK/crt/include/atldef.h" ]; then
  rm -rf "$WINSDK"
  "$XWIN" --accept-license --cache-dir "$WORK/.xwin-cache" --sdk-version "$SDK_VERSION" --include-atl splat --output "$WINSDK"
fi

# 改用 SDK 10.0.26100 自帶的 UCRT（xwin 選的獨立 UCRT 缺 VC 14.4x threads.h 需要的巨集；見 fetch_win_redist.py）
python3 "$(dirname "$0")/fetch_win_redist.py" ucrt "$WORK" "$WINSDK"

CRT="$WINSDK/crt"; SDK="$WINSDK/sdk"
for d in "$CRT/include" "$CRT/lib/x86_64" "$SDK/include/um" "$SDK/include/shared" \
         "$SDK/include/ucrt" "$SDK/include/winrt" "$SDK/include/cppwinrt" \
         "$SDK/lib/um/x86_64" "$SDK/lib/ucrt/x86_64"; do
  [ -d "$d" ] || { echo "FATAL: xwin output missing $d" >&2; exit 1; }
done

# 2. (re)build the package_from_installed-style tree
VC_DIR="$TC/VC/Tools/MSVC/$VCVER"; WK="$TC/Windows Kits/10"
INC="$WK/Include/$SDKVER"
CI="$WORK/ci"; MOUNTS="$CI/mounts.tsv"     # 每行：backing<TAB>mountpoint（docker-dev.sh 重啟容器後據此重新掛載）
# release any prior ciopfs mount before rebuild（容器內沒有 fusermount 時以 root 用 umount）
ci_umount() { fusermount -u "$1" 2>/dev/null || umount "$1" 2>/dev/null || true; }
[ -f "$MOUNTS" ] && while IFS=$'\t' read -r _ m; do ci_umount "$m"; done < "$MOUNTS"
ci_umount "$INC"
rm -rf "$TC" "$CI"
mkdir -p "$CI" "$VC_DIR/bin/HostX64/x64" "$VC_DIR/lib" "$INC" \
         "$WK/Lib/$SDKVER/um" "$WK/Lib/$SDKVER/ucrt" "$WK/bin/$SDKVER/x64" "$WK/bin" "$WK/UnionMetadata/$SDKVER"

# 大小寫不敏感目錄：在 $2 掛上 ciopfs（backing 為 $CI/$3），再把 $1 的一般檔案經由掛載點複製進去，
# 檔名以摺疊後的大小寫儲存、可用任意大小寫讀取。只複製一般檔案：xwin 產生的大小寫變體 symlink
# 經過 ciopfs 摺疊後會與原檔撞名（File exists），甚至變成指向自己的循環 symlink，而且不再需要。
ci_mount() {
  mkdir -p "$CI/$3" "$2"
  ciopfs "$CI/$3" "$2"
  printf '%s\t%s\n' "$CI/$3" "$2" >> "$MOUNTS"
  ( cd "$1" && find . -type f -print0 | xargs -0 cp -a --parents -t "$2/" )
}

# VC CRT headers: plain symlink is fine (CRT headers are already consistent-case)
ln -sfn "$CRT/include"    "$VC_DIR/include"
ln -sfn "Windows Kits/10" "$TC/win_sdk"
# 函式庫：原本靠 xwin 的大小寫變體 symlink，但它只產生部分變體（例如有 CFGMGR32.lib 卻沒有
# Cfgmgr32.lib，vulkan-1.dll 連結失敗），因此 Lib 也與 Include 一樣經由 ciopfs 提供。
ci_mount "$CRT/lib/x86_64"      "$VC_DIR/lib/x64"            vc_lib_x64
ci_mount "$SDK/lib/um/x86_64"   "$WK/Lib/$SDKVER/um/x64"     sdk_lib_um_x64
ci_mount "$SDK/lib/ucrt/x86_64" "$WK/Lib/$SDKVER/ucrt/x64"   sdk_lib_ucrt_x64
# SDK Include tree: case-insensitive via ciopfs
ci_mount "$SDK/include"         "$INC"                       inc_backing
for sub in um shared winrt cppwinrt ucrt; do
  [ -d "$INC/$sub" ] || { echo "FATAL: ciopfs include tree missing $sub" >&2; exit 1; }
done
[ -f "$WK/Lib/$SDKVER/um/x64/Cfgmgr32.lib" ] || { echo "FATAL: ciopfs lib tree 無法以任意大小寫讀取" >&2; exit 1; }

# Chromium probes for cl.exe; a stub satisfies the check (we actually build with clang-cl).
for a in x64 x86; do
  mkdir -p "$VC_DIR/bin/HostX64/$a"
  printf '#!/bin/sh\nexit 0\n' > "$VC_DIR/bin/HostX64/$a/cl.exe"; chmod +x "$VC_DIR/bin/HostX64/$a/cl.exe"
done
# x86：setup_toolchain.py 要求 LIB 各目錄存在；不會真的連結 x86，放空目錄即可（見下方 SetEnv 說明）
mkdir -p "$VC_DIR/lib/x86" "$WK/Lib/$SDKVER/um/x86" "$WK/Lib/$SDKVER/ucrt/x86" "$WK/bin/$SDKVER/x86"
printf '2026\n' > "$TC/VS_VERSION"

# 3. synthesize SetEnv.<cpu>.json (INCLUDE/LIB/PATH the cross-build reads)
# Chromium 150 的 win_toolchain_data.gni 無條件評估 x86 工具鏈（setup_toolchain.py ... x86），
# 缺 SetEnv.x86.json 時 gn gen 直接失敗。x64 的 chrome 不會編譯 x86 程式，x86 版只需要能被解析
# （PATH 中有 cl.exe stub、INCLUDE/LIB 非空）；lib/x86 目錄 xwin 預設不下載，真用到時連結才會報錯。
python3 - "$TC" "$VCVER" "$SDKVER" <<'PY'
import json, collections, os, sys
tc, vc, sk = sys.argv[1], sys.argv[2], sys.argv[3]
for cpu in ("x64", "x86"):
  e = collections.OrderedDict()
  e["VSINSTALLDIR"]=[[".\\"]]; e["VCINSTALLDIR"]=[["VC\\"]]
  e["INCLUDE"]=[["Windows Kits","10","Include",sk,"um"],["Windows Kits","10","Include",sk,"shared"],
               ["Windows Kits","10","Include",sk,"winrt"],["Windows Kits","10","Include",sk,"cppwinrt"],
               ["Windows Kits","10","Include",sk,"ucrt"],["VC","Tools","MSVC",vc,"include"]]
  e["LIBPATH"]=[["VC","Tools","MSVC",vc,"lib",cpu],["Windows Kits","10","UnionMetadata",sk]]
  e["VCToolsInstallDir"]=[["VC","Tools","MSVC",vc+"\\"]]
  e["PATH"]=[["VC","Tools","MSVC",vc,"bin","HostX64",cpu],["Windows Kits","10","bin",sk,cpu]]
  e["LIB"]=[["VC","Tools","MSVC",vc,"lib",cpu],["Windows Kits","10","Lib",sk,"um",cpu],
            ["Windows Kits","10","Lib",sk,"ucrt",cpu]]
  p=os.path.join(tc,"Windows Kits","10","bin","SetEnv.%s.json" % cpu)
  json.dump({"env":e}, open(p,"w")); print("wrote", p)
PY

# 4. xwin 不包含的可再發行檔：d3dcompiler_47.dll（ANGLE 需要）+ VC++/UCRT 執行階段 DLL（05 打包用）
python3 "$(dirname "$0")/fetch_win_redist.py" redist "$WORK" "$WK"

echo "OK: Windows toolchain at $TC (SDK Include via ciopfs); GYP_MSVS_OVERRIDE_PATH=$TC"
echo "    (to release the mount later: fusermount -u \"$INC\")"
