#!/bin/bash
# 用 App 同一套代码试读账单模板（BKCore 的 StatementCheck，在 Docker 里跑）。
#
#   check.sh <模板.json 或放模板的文件夹> [<账单>…] [--rows N] [--now yyyy-MM-dd] [--ledger 账户.json]
#
# 账单：.csv .xlsx .xls，PDF 先用 extract_pdf.py 读成 .json。文件可以在任何地方：所在的文件夹挂进容器，只读。
# 要先有镜像 bk-swift（ios-swift/README.md「本地（Windows）运行核心测试」）。第一次要编译，一两分钟。
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
package="$(cd "$here/../../../../ios-swift/Packages/BKCore" && pwd)"

# Git Bash 上 docker 要 Windows 路径
host() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

mounts=(-v "$(host "$package"):/pkg")
args=()
index=0
for arg in "$@"; do
  if [ -e "$arg" ]; then
    full="$(cd "$(dirname "$arg")" && pwd)/$(basename "$arg")"
    mounts+=(-v "$(host "$(dirname "$full")"):/in/$index:ro")
    args+=("/in/$index/$(basename "$full")")
    index=$((index + 1))
  else
    args+=("$arg")
  fi
done

MSYS_NO_PATHCONV=1 docker run --rm "${mounts[@]}" -w /pkg bk-swift bash -c '
  swift build --product StatementCheck 2>&1 | grep -E "error:" | sed "s/\x1b\[[0-9;]*m//g" | sort -u
  exec .build/debug/StatementCheck "$@"
' check "${args[@]}"
