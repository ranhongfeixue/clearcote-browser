#!/usr/bin/env bash
# Clearcote — 本機「持久化」Docker 建置（Windows x64 交叉編譯），方便反覆修改後增量編譯。
#
# 與官方 `docker run --rm ...` 的差別：
#   - 整個 $WORK（Chromium 原始碼、工具鏈、out/Default 編譯產物、dist）掛載到主機目錄，
#     容器刪掉也不會遺失，改完程式碼只需增量 ninja，不必從頭再編幾個小時。
#   - 倉庫本身掛載到 /clearcote，修改 patches/、config/、scripts/ 不需要重建映像。
#   - 長駐的具名容器，install-build-deps 裝過的套件會保留。
#   - 提供 ciopfs 需要的 FUSE 權限（官方指令沒加，stage 03 會失敗）。
#
# 用法：
#   ./docker-dev.sh full          # 第一次：依序跑 00→05，已完成的階段會跳過（可中斷後續跑）
#   ./docker-dev.sh build         # 改完 build/src 後：增量編譯 (04) + 打包 (05)
#   ./docker-dev.sh stage 03      # 強制重跑單一階段
#   ./docker-dev.sh reset-src     # 刪掉 build/src，重新解壓 + 套 patch（改了 patches/ 時用；之後是全量編譯）
#   ./docker-dev.sh shell         # 進容器
#   ./docker-dev.sh chown         # 把 $WORK 的檔案擁有者改回目前使用者（方便在主機直接編輯 build/src）
#   ./docker-dev.sh stop | rm     # 停止 / 刪除容器（資料仍在 $WORK_HOST）
#
# build/src 是一個 git 倉庫（基準 tag：baseline-<版本>），在主機上以目前使用者執行：
#   ./docker-dev.sh src-status          # 目前相對上次存檔改了哪些檔案
#   ./docker-dev.sh src-save "說明"     # 把目前的修改存成一個提交
#   ./docker-dev.sh src-restore [存檔]  # 丟棄未存檔的修改，回到該存檔（預設目前這個存檔）
#   ./docker-dev.sh src-log             # 列出所有存檔（save-<時間> 與 baseline-<版本> 標籤）
#
# 環境變數：
#   WORK_HOST  主機上的工作目錄（預設 ~/clearcote-build，需要約 150 GB）
#   JOBS         ninja 並行數（預設 16；27 GB RAM 實測全量編譯峰值約 17 GB）
#   NINJA_FLAGS  額外的 ninja 參數，例如 NINJA_FLAGS="-k 0" 遇到失敗仍繼續編其他目標
set -euo pipefail
REPO="$(cd "$(dirname "$0")" && pwd)"
WORK_HOST="${WORK_HOST:-$HOME/clearcote-build}"
JOBS="${JOBS:-16}"
IMAGE=clearcote-build
NAME=clearcote-dev
W=/clearcote-build                       # 容器內的 $WORK

ensure_container() {
  docker image inspect "$IMAGE" >/dev/null 2>&1 || docker build -t "$IMAGE" "$REPO"
  if ! docker container inspect "$NAME" >/dev/null 2>&1; then
    mkdir -p "$WORK_HOST"
    docker create --name "$NAME" \
      -v "$REPO:/clearcote" -v "$WORK_HOST:$W" \
      -e WORK="$W" -e REPO=/clearcote -e TARGET=windows -e PYTHONDONTWRITEBYTECODE=1 \
      --device /dev/fuse --cap-add SYS_ADMIN --security-opt apparmor=unconfined \
      --ulimit nofile=1048576:1048576 \
      --entrypoint sleep "$IMAGE" infinity >/dev/null
  fi
  [ "$(docker inspect -f '{{.State.Running}}' "$NAME")" = true ] || docker start "$NAME" >/dev/null
  # 容器內一次性設定：倉庫屬主是主機使用者，git 需要 safe.directory；
  # 04 直接呼叫 ninja 不帶 -j，用 /usr/local/bin 的包裝限制並行數以免 OOM。
  docker exec "$NAME" bash -c '
    git config --global --get-all safe.directory | grep -qx "*" || git config --global --add safe.directory "*"
    printf "#!/bin/sh\nexec /usr/bin/ninja -j \"\${JOBS:-16}\" \${NINJA_FLAGS:-} \"\$@\"\n" > /usr/local/bin/ninja
    chmod +x /usr/local/bin/ninja'
}

# 在容器內執行指令（-t 只在有終端機時加）
cexec() {
  local tty=(); [ -t 0 ] && [ -t 1 ] && tty=(-t)
  docker exec -i "${tty[@]}" -w "$W" -e JOBS="$JOBS" -e NINJA_FLAGS="${NINJA_FLAGS:-}" "$NAME" bash -c "$1"
}

# ciopfs 掛載跟著容器行程，容器重啟後就沒了；stage 03 跑過的話依 mounts.tsv 重新掛上即可，不必重建 SDK 樹
ensure_mount() {
  cexec "
    [ -f '$W/ci/mounts.tsv' ] || exit 0
    while IFS=\$'\\t' read -r b m; do
      mountpoint -q \"\$m\" || { echo \"重新掛載 ciopfs: \$m\"; ciopfs \"\$b\" \"\$m\"; }
    done < '$W/ci/mounts.tsv'"
}

run_stage() { # NN
  local n="$1" s; s="$(cd "$REPO/scripts" && ls "$n"-*.sh)"
  [ "$n" = 04 ] && ensure_mount
  echo; echo "==== $s ===="
  cexec "mkdir -p $W/logs && set -o pipefail && bash /clearcote/scripts/$s 2>&1 | tee $W/logs/$s.log && touch $W/.done-$n"
}

# build/src 的 git 快照：不追蹤編譯輸出、下載的工具鏈與自帶 .git 的外部相依（同 .git/info/exclude）
srcgit() { git -C "$WORK_HOST/build/src" "$@"; }
SRC_EXCLUDES=(
  ':(exclude)out' ':(exclude)third_party/llvm-build' ':(exclude)third_party/rust-toolchain'
  ':(exclude)build/linux/debian_bullseye_amd64-sysroot' ':(exclude)third_party/node/linux'
  ':(exclude)third_party/node/win' ':(exclude)third_party/gperf/cipd'
  ':(exclude)third_party/devtools-frontend/src/third_party/esbuild/esbuild'
  ':(exclude)build/toolchain/win/rc/linux64/rc' ':(exclude)third_party/microsoft_webauthn/src'
  ':(exclude)third_party/microsoft_dxheaders/src' ':(exclude,glob)**/__pycache__/**' ':(exclude,glob)**/*.pyc'
)

cmd="${1:-}"; shift || true
case "$cmd" in
  full)
    ensure_container
    for n in 00 01 02 03 04 05; do
      if [ -e "$WORK_HOST/.done-$n" ]; then echo "略過 $n（已完成；用 stage $n 強制重跑）"; else run_stage "$n"; fi
    done
    echo "完成 → $WORK_HOST/dist" ;;
  build)
    ensure_container; run_stage 04; run_stage 05
    echo "完成 → $WORK_HOST/dist" ;;
  stage)
    [ -n "${1:-}" ] || { echo "用法：$0 stage NN"; exit 2; }
    ensure_container; run_stage "$1" ;;
  reset-src)
    ensure_container
    cexec "rm -rf $W/build/src $W/.done-00 $W/.done-01 $W/.done-02 $W/.done-04 $W/.done-05"
    echo "已刪除 build/src；接著執行 $0 full（下載快取還在，不會重新下載 tarball）" ;;
  shell)  ensure_container; ensure_mount; docker exec -it -e JOBS="$JOBS" -w "$W" "$NAME" bash ;;
  chown)  ensure_container; cexec "chown -R $(id -u):$(id -g) $W" ;;
  src-status)  srcgit status --short | head -200; srcgit diff --stat HEAD | tail -1 ;;
  src-save)
    [ -n "${1:-}" ] || { echo "用法：$0 src-save \"說明\""; exit 2; }
    # -f：Chromium 的 .gitignore 會忽略各 DEPS 子目錄（實為原始碼），排除項見 SRC_EXCLUDES
    srcgit add -A -f -- . "${SRC_EXCLUDES[@]}"
    # 每個存檔都打 save-<時間> 標籤：還原到較早的存檔後，之後的存檔仍保留、可再回去
    srcgit commit -q -m "$1" && srcgit tag "save-$(date +%Y%m%d-%H%M%S)" && srcgit log --oneline --decorate -1 ;;
  src-restore)
    ref="${1:-HEAD}"
    srcgit rev-parse -q --verify "$ref^{commit}" >/dev/null || { echo "找不到 $ref（見 $0 src-log）"; exit 2; }
    # 只動到有差異的檔案，之後 build 仍是增量編譯；out/ 與工具鏈在 info/exclude 中，git clean 不會碰
    srcgit reset -q --hard "$ref" && srcgit clean -fdq && echo "已回到 $(srcgit log --oneline -1 "$ref")" ;;
  src-log)     srcgit log --oneline --decorate --no-walk --tags='baseline-*' --tags='save-*' ;;
  stop)   docker stop "$NAME" ;;
  rm)     docker rm -f "$NAME" ;;
  *) sed -n '2,29p' "$0"; exit 2 ;;
esac
