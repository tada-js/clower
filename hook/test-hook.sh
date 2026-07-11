#!/bin/bash
# clower-hook self-check. 격리된 HOME으로 실행해 상태 파일을 검증한다.
# 사용법: bash hook/test-hook.sh
set -euo pipefail
cd "$(dirname "$0")"

BIN="./clower-hook"
swiftc clower-hook.swift -o "$BIN"

TESTHOME="$(mktemp -d)"
trap 'rm -rf "$TESTHOME"' EXIT
STATEDIR="$TESTHOME/.claude/clower"
SID="test-session-1"
STATE="$STATEDIR/$SID.json"

fire() { echo "$1" | HOME="$TESTHOME" "$BIN"; }
assert_state() { # $1=expected state
  local got
  got=$(grep -o '"state":"[^"]*"' "$STATE" | cut -d'"' -f4)
  if [ "$got" = "$1" ]; then echo "  ✅ state=$1"; else echo "  ❌ 기대 $1, 실제 '$got'"; exit 1; fi
}
assert_gone() {
  if [ ! -f "$STATE" ]; then echo "  ✅ 파일 삭제됨"; else echo "  ❌ 파일이 남아있음"; exit 1; fi
}

echo "SessionStart → idle";        fire "{\"hook_event_name\":\"SessionStart\",\"session_id\":\"$SID\",\"cwd\":\"/tmp/proj\"}"; assert_state idle
echo "UserPromptSubmit → working"; fire "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"$SID\",\"cwd\":\"/tmp/proj\"}"; assert_state working
echo "Notification permission_prompt → waiting"; fire "{\"hook_event_name\":\"Notification\",\"session_id\":\"$SID\",\"cwd\":\"/tmp/proj\",\"notification_type\":\"permission_prompt\"}"; assert_state waiting
echo "PostToolUse → working (승인 뒤 복구, MUST 5)"; fire "{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"$SID\",\"cwd\":\"/tmp/proj\"}"; assert_state working
echo "Notification idle_prompt → idle"; fire "{\"hook_event_name\":\"Notification\",\"session_id\":\"$SID\",\"cwd\":\"/tmp/proj\",\"notification_type\":\"idle_prompt\"}"; assert_state idle
echo "Notification 모르는타입 → idle (MUST 6)"; fire "{\"hook_event_name\":\"Notification\",\"session_id\":\"$SID\",\"cwd\":\"/tmp/proj\",\"notification_type\":\"auth_success\"}"; assert_state idle
echo "Stop → idle"; fire "{\"hook_event_name\":\"Stop\",\"session_id\":\"$SID\",\"cwd\":\"/tmp/proj\"}"; assert_state idle
echo "cwd 저장 확인";
grep -q '"cwd":"/tmp/proj"' "$STATE" && echo "  ✅ cwd 기록됨" || { echo "  ❌ cwd 없음"; exit 1; }
echo "session_id 없음 → 크래시 없이 통과";
echo '{"hook_event_name":"Stop","cwd":"/tmp/proj"}' | HOME="$TESTHOME" "$BIN"; echo "  ✅ exit $?"
echo "SessionEnd → 파일 삭제"; fire "{\"hook_event_name\":\"SessionEnd\",\"session_id\":\"$SID\"}"; assert_gone

# --- 설치·제거 (settings.json 안전 병합) ---
# 별도 격리 HOME에서 검증한다. jq 없이 grep으로 확인(설치도 jq 안 씀 — MUST 1).
echo
echo "=== 설치/제거 검증 ==="
IHOME="$(mktemp -d)"
trap 'rm -rf "$TESTHOME" "$IHOME"' EXIT
SETTINGS="$IHOME/.claude/settings.json"
mkdir -p "$IHOME/.claude"

# 기존 사용자 설정을 미리 둔다: 다른 hook 1개 + 무관한 키. 병합이 이걸 보존해야 한다.
cat > "$SETTINGS" <<'JSON'
{ "model": "opus", "hooks": { "SessionStart": [ { "hooks": [ { "type": "command", "command": "my-existing-hook" } ] } ] } }
JSON

count_clower() { grep -o 'clower-hook' "$SETTINGS" | wc -l | tr -d ' '; }

echo "install → 6개 이벤트에 clower-hook 등록";
HOME="$IHOME" "$BIN" --install >/dev/null
[ "$(count_clower)" = "6" ] && echo "  ✅ clower-hook 6개 등록" || { echo "  ❌ 등록 수 $(count_clower) (기대 6)"; exit 1; }

echo "기존 설정 보존";
grep -q 'my-existing-hook' "$SETTINGS" && echo "  ✅ 기존 hook 유지" || { echo "  ❌ 기존 hook 사라짐"; exit 1; }
grep -q '"model"' "$SETTINGS" && echo "  ✅ 무관한 키(model) 유지" || { echo "  ❌ model 키 사라짐"; exit 1; }

echo "바이너리 복사 + 백업 생성";
[ -x "$IHOME/.claude/clower/clower-hook" ] && echo "  ✅ hook 바이너리 설치됨" || { echo "  ❌ 바이너리 없음"; exit 1; }
[ -f "$SETTINGS.bak" ] && echo "  ✅ settings.json.bak 백업됨" || { echo "  ❌ 백업 없음"; exit 1; }

echo "중복 방지: 두 번째 install에도 안 쌓임";
HOME="$IHOME" "$BIN" --install >/dev/null
[ "$(count_clower)" = "6" ] && echo "  ✅ 여전히 6개(중복 없음)" || { echo "  ❌ 중복 발생: $(count_clower)개"; exit 1; }

echo "uninstall → clower 제거, 기존 설정 유지";
HOME="$IHOME" "$BIN" --uninstall >/dev/null
[ "$(count_clower)" = "0" ] && echo "  ✅ clower-hook 0개" || { echo "  ❌ 잔존 $(count_clower)개"; exit 1; }
grep -q 'my-existing-hook' "$SETTINGS" && echo "  ✅ 기존 hook 유지" || { echo "  ❌ 기존 hook 사라짐"; exit 1; }
[ ! -f "$IHOME/.claude/clower/clower-hook" ] && echo "  ✅ 설치 바이너리 제거됨" || { echo "  ❌ 바이너리 남음"; exit 1; }

# --- fail-closed 회귀 (리뷰어 발견: 데이터 소실 방지) ---
echo
echo "=== fail-closed 회귀 ==="
# 치명적1: 파싱 안 되는 settings.json은 절대 덮지 않고 exit≠0로 중단해야 한다.
FHOME="$(mktemp -d)"; trap 'rm -rf "$TESTHOME" "$IHOME" "$FHOME"' EXIT
mkdir -p "$FHOME/.claude"
printf '{\n  // 손편집 주석\n  "model": "opus"\n}\n' > "$FHOME/.claude/settings.json"
ORIG="$(cat "$FHOME/.claude/settings.json")"
echo "깨진 JSON(주석) install → 중단 + 원본 보존";
if HOME="$FHOME" "$BIN" --install >/dev/null 2>&1; then echo "  ❌ 중단 안 함(exit 0)"; exit 1; else echo "  ✅ exit≠0로 중단"; fi
[ "$(cat "$FHOME/.claude/settings.json")" = "$ORIG" ] && echo "  ✅ settings.json 원본 그대로" || { echo "  ❌ 원본이 변형됨(데이터 소실)"; exit 1; }

# 중간3: 이벤트 값이 배열이 아니면(객체) 중단하고 사용자 값을 보존해야 한다.
printf '{"hooks":{"Stop":{"hooks":[{"type":"command","command":"my-stop-hook"}]}}}' > "$FHOME/.claude/settings.json"
ORIG2="$(cat "$FHOME/.claude/settings.json")"
echo "이벤트가 객체(배열 아님) install → 중단 + 원본 보존";
if HOME="$FHOME" "$BIN" --install >/dev/null 2>&1; then echo "  ❌ 중단 안 함"; exit 1; else echo "  ✅ 중단"; fi
[ "$(cat "$FHOME/.claude/settings.json")" = "$ORIG2" ] && echo "  ✅ my-stop-hook 보존" || { echo "  ❌ 사용자 값 소실"; exit 1; }

# 치명적2: 반복 install해도 .bak은 최초 원본을 유지해야 한다(merged로 덮이면 안 됨).
BHOME="$(mktemp -d)"; trap 'rm -rf "$TESTHOME" "$IHOME" "$FHOME" "$BHOME"' EXIT
mkdir -p "$BHOME/.claude"
printf '{"model":"opus","hooks":{}}' > "$BHOME/.claude/settings.json"
PRISTINE="$(cat "$BHOME/.claude/settings.json")"
HOME="$BHOME" "$BIN" --install >/dev/null   # 1차
HOME="$BHOME" "$BIN" --install >/dev/null   # 2차
echo "반복 install → .bak 최초 원본 유지";
grep -q 'clower-hook' "$BHOME/.claude/settings.json.bak" && { echo "  ❌ .bak이 merged로 덮임"; exit 1; } || echo "  ✅ .bak에 clower 없음(원본 보존)"

echo
echo "🎉 모든 체크 통과"
