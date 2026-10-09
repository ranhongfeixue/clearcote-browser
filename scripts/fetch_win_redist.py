#!/usr/bin/env python3
"""從 xwin 已下載的 VS manifest 補齊 xwin splat 不足的部分。

ucrt 子命令（在 03 建立工具鏈樹之前執行）：
  - 以 Windows SDK 10.0.26100 自帶的 UCRT 標頭與函式庫取代 xwin 選用的獨立 UCRT 套件
      （10.0.26624.1）。後者的 corecrt.h 沒有 _UCRT_DISABLED_WARNINGS / _UCRT_DISABLE_CLANG_WARNINGS，
      VC 14.4x 的 threads.h 需要它們（pthreadpool 等編譯失敗）。

redist 子命令，取得 xwin splat 不包含的 Windows 可再發行檔案：

  - d3dcompiler_47.dll  （Windows SDK for Windows Store Apps Tools MSI）→ <sdk>/Redist/D3D/x64/
      ANGLE 的 copy_compiler_dll 需要它，缺了 ninja 直接停止。
  - VC++ 執行階段 DLL    （VC CRT Redist vsix）+ ucrtbase.dll（Universal CRT Redistributable MSI）
      → $WORK/vcredist/，05-package.sh 會打包進 zip，讓 chrome.exe 在乾淨的 Windows 上也能啟動。

所有下載都以 manifest 內的 sha256 驗證，並快取在 $WORK/winredist/。需要 msitools（msiinfo / msiextract）。

  用法：fetch_win_redist.py ucrt   <WORK> <xwin splat 輸出目錄>
        fetch_win_redist.py redist <WORK> <SDK 根目錄（Windows Kits/10）>
"""
import glob
import hashlib
import json
import os
import shutil
import subprocess
import sys
import urllib.request
import zipfile

VC_REDIST_PKG = "Microsoft.VC.14.44.17.14.CRT.Redist.X64.base"
SDK_PKG_PREFIX = "Win11SDK_10.0.26100"
VC_DLLS = ["concrt140.dll", "msvcp140.dll", "vcruntime140.dll", "vcruntime140_1.dll"]


def load_manifest(work):
    paths = glob.glob(os.path.join(work, ".xwin-cache", "dl", "pkg_manifest_*.vsman"))
    if not paths:
        sys.exit("FATAL: 找不到 xwin 的 pkg_manifest_*.vsman — 先執行 03 的 xwin splat")
    return json.load(open(paths[0]))["packages"]


def fetch(payload, dest_dir):
    """下載 payload 並以 sha256 驗證；已存在且雜湊正確時直接沿用。"""
    name = payload["fileName"].replace("\\", "/").split("/")[-1]
    dest = os.path.join(dest_dir, name)
    want = payload["sha256"].lower()

    def digest(p):
        h = hashlib.sha256()
        with open(p, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
        return h.hexdigest()

    if not (os.path.exists(dest) and digest(dest) == want):
        print("  下載", name)
        with urllib.request.urlopen(payload["url"]) as r, open(dest + ".part", "wb") as f:
            shutil.copyfileobj(r, f)
        if digest(dest + ".part") != want:
            sys.exit(f"FATAL: {name} sha256 不符")
        os.replace(dest + ".part", dest)
    return dest


def sdk_payloads(packages):
    out = {}
    for p in packages:
        if p["id"].startswith(SDK_PKG_PREFIX):
            for f in p.get("payloads", []):
                out[f["fileName"].replace("\\", "/").split("/")[-1]] = f
    return out


def extract_msi(msi_name, payloads, cache, out_dir):
    """下載 MSI 與它 Media 表中列出的外部 cab，再用 msiextract 解開。"""
    msi = fetch(payloads[msi_name], cache)
    media = subprocess.run(["msiinfo", "export", msi, "Media"], check=True,
                           capture_output=True, text=True).stdout.splitlines()
    cols = media[0].split("\t")
    ci = cols.index("Cabinet")
    for row in media[3:]:
        cab = row.split("\t")[ci] if len(row.split("\t")) > ci else ""
        if cab and not cab.startswith("#"):          # '#' 開頭表示內嵌在 MSI 裡
            fetch(payloads[cab], cache)
    shutil.rmtree(out_dir, ignore_errors=True)
    os.makedirs(out_dir)
    # msiextract 會在 MSI 所在目錄尋找外部 cab
    subprocess.run(["msiextract", "-C", out_dir, msi], check=True, stdout=subprocess.DEVNULL)


def find_one(root, *suffix):
    want = "/".join(suffix).lower()
    for d, _, files in os.walk(root):
        for f in files:
            p = os.path.join(d, f)
            if p.replace("\\", "/").lower().endswith(want):
                return p
    sys.exit(f"FATAL: 在 {root} 找不到 {want}")


def replace_tree(src, dst):
    shutil.rmtree(dst, ignore_errors=True)
    shutil.copytree(src, dst, symlinks=True)


def ucrt(work, winsdk):
    """以 SDK 自帶的 UCRT 取代 xwin splat 出來的 sdk/include/ucrt 與 sdk/lib/ucrt/x86_64。"""
    cache = os.path.join(work, "winredist")
    os.makedirs(cache, exist_ok=True)
    payloads = sdk_payloads(load_manifest(work))
    ext = os.path.join(cache, "x-ucrt-sdk")
    extract_msi("Universal CRT Headers Libraries and Sources-x86_en-us.msi", payloads, cache, ext)
    inc = os.path.dirname(find_one(ext, "Include", "10.0.26100.0", "ucrt", "corecrt.h"))
    lib = os.path.dirname(find_one(ext, "Lib", "10.0.26100.0", "ucrt", "x64", "ucrt.lib"))
    replace_tree(inc, os.path.join(winsdk, "sdk", "include", "ucrt"))
    replace_tree(lib, os.path.join(winsdk, "sdk", "lib", "ucrt", "x86_64"))
    print("OK: UCRT 10.0.26100 →", winsdk)


def redist(work, sdk_root):
    cache = os.path.join(work, "winredist")
    os.makedirs(cache, exist_ok=True)
    packages = load_manifest(work)
    payloads = sdk_payloads(packages)

    # 1. d3dcompiler_47.dll
    ext = os.path.join(cache, "x-sdk-redist")
    extract_msi("Windows SDK for Windows Store Apps Tools-x86_en-us.msi", payloads, cache, ext)
    d3d_dst = os.path.join(sdk_root, "Redist", "D3D", "x64")
    os.makedirs(d3d_dst, exist_ok=True)
    shutil.copy2(find_one(ext, "Redist", "D3D", "x64", "d3dcompiler_47.dll"), d3d_dst)
    print("OK:", os.path.join(d3d_dst, "d3dcompiler_47.dll"))

    # 2. VC++ 執行階段 DLL + ucrtbase.dll → $WORK/vcredist
    vcredist = os.path.join(work, "vcredist")
    os.makedirs(vcredist, exist_ok=True)
    pkg = next(p for p in packages if p["id"] == VC_REDIST_PKG)
    vsix = fetch(pkg["payloads"][0], cache)
    with zipfile.ZipFile(vsix) as z:
        for dll in VC_DLLS:
            member = next(n for n in z.namelist()
                          if n.lower().endswith("/x64/microsoft.vc143.crt/" + dll))
            with z.open(member) as src, open(os.path.join(vcredist, dll), "wb") as dst:
                shutil.copyfileobj(src, dst)
    ext = os.path.join(cache, "x-ucrt-redist")
    extract_msi("Universal CRT Redistributable-x86_en-us.msi", payloads, cache, ext)
    shutil.copy2(find_one(ext, "ucrt", "DLLs", "x64", "ucrtbase.dll"), vcredist)
    print("OK:", vcredist, sorted(os.listdir(vcredist)))


if __name__ == "__main__":
    cmd, work, target = sys.argv[1:4]
    {"ucrt": ucrt, "redist": redist}[cmd](work, target)
