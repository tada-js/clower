#!/bin/bash
# icon-master.png(1024) → Clower.icns. 앱 번들 아이콘 재생성 도구.
# raw/idle.png를 바꿨을 때만 다시 돌리면 된다(결과 Clower.icns는 커밋됨).
# 사용법: bash make-icon.sh   (→ app/assets/Clower.icns)
set -euo pipefail
cd "$(dirname "$0")"

python3 make-icon.py

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ICONSET="$WORK/Clower.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z "$s" "$s"       icon-master.png --out "$ICONSET/icon_${s}x${s}.png"    >/dev/null
    sips -z "$((s*2))" "$((s*2))" icon-master.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o Clower.icns
echo "→ app/assets/Clower.icns"
