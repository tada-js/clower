#!/bin/bash
# Clower 완료 게이트 (결정론 게이트). 이게 초록이 아니면 "완료"라고 선언하지 않는다.
# 자연어로 "통과했다"고 말하는 대신 기계가 확인한다 — 자체 판단으로 완료 선언 금지.
# 사용법: bash verify.sh   (저장소 루트 어디서 호출해도 됨)
set -euo pipefail
cd "$(dirname "$0")"

fail() { echo "❌ $1"; exit 1; }

echo "== 1/5 hook 빌드 =="
swiftc hook/clower-hook.swift -o hook/clower-hook || fail "hook 빌드 실패 (MUST: 빌드 통과)"
echo "  ✅ hook 빌드"

echo "== 2/5 app 빌드 =="
swiftc app/Clower.swift -o app/Clower || fail "app 빌드 실패 (MUST: 빌드 통과)"
echo "  ✅ app 빌드"

echo "== 3/5 의존성 0 게이트 (MUST 1) =="
# Apple 시스템 프레임워크(SDK 내장)만 허용. 외부 패키지(SPM 등)가 들어오면 잡는다.
# ServiceManagement = SMAppService(로그인 자동 실행), CLAUDE.md가 최소 macOS 13의 근거로 명시.
allowed='Foundation|AppKit|ServiceManagement'
badimports=$(grep -hE '^import ' hook/clower-hook.swift app/Clower.swift | grep -vE "^import ($allowed)$" || true)
[ -z "$badimports" ] || fail "허용 안 된 import 발견 (Apple 프레임워크만 허용: $allowed):\n$badimports"
# hook은 jq 등 외부 도구를 부르지 않는다(macOS 미탑재로 조용히 실패). 주석 제외하고 검사.
jqhits=$(grep -nE '\bjq\b' hook/clower-hook.swift | grep -v '//' || true)
[ -z "$jqhits" ] || fail "hook에서 jq 참조 발견 (MUST 1 위반):\n$jqhits"
echo "  ✅ import는 Apple 프레임워크뿐($allowed), jq 미사용"

echo "== 4/5 hook 셀프테스트 (상태 전이 + install/uninstall + fail-closed) =="
bash hook/test-hook.sh >/dev/null 2>&1 || fail "test-hook.sh 실패 — 개별 실행: bash hook/test-hook.sh"
echo "  ✅ test-hook.sh 통과"

echo "== 5/5 앱 순수 로직 셀프테스트 =="
./app/Clower --selftest >/dev/null 2>&1 || fail "Clower --selftest 실패 (에스컬레이션 매핑)"
./app/Clower --check >/dev/null 2>&1 || fail "Clower --check 실패 (프레임 로드 경로)"
echo "  ✅ --selftest / --check 통과"

echo
echo "🎉 verify 초록 — 완료 선언 가능"
