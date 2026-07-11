#!/bin/bash
# Clower.app 번들 + Clower.dmg 를 만든다. Xcode 프로젝트 없이 swiftc 결과물을 조립.
# 서명·공증 안 함(무료 배포). 받는 사람은 처음 한 번 우클릭 → 열기로 Gatekeeper를 통과한다.
# 사용법: bash build-app.sh
set -euo pipefail
cd "$(dirname "$0")"

VERSION="0.1.0"
BUNDLE_ID="io.github.tada-js.clower"
DIST="dist"
APP="$DIST/Clower.app"
MACOS="$APP/Contents/MacOS"

echo "== 바이너리 빌드 =="
swiftc app/Clower.swift -o app/Clower
swiftc hook/clower-hook.swift -o hook/clower-hook

echo "== .app 조립 =="
rm -rf "$APP"
mkdir -p "$MACOS"
# 앱은 실행파일 옆에서 프레임·hook을 찾는다(코드 무수정). 그래서 MacOS/ 안에 나란히 둔다.
cp app/Clower "$MACOS/Clower"
cp hook/clower-hook "$MACOS/clower-hook"   # "Hooks 설치" 버튼이 /Applications에서도 찾도록 동봉
mkdir -p "$MACOS/assets"
cp -R app/assets/frames "$MACOS/assets/frames"
# Finder·dmg용 앱 아이콘(메뉴바 아이콘은 런타임에 따로 그림). make-icon.sh로 재생성.
mkdir -p "$APP/Contents/Resources"
cp app/assets/Clower.icns "$APP/Contents/Resources/Clower.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>Clower</string>
    <key>CFBundleDisplayName</key>       <string>Clower</string>
    <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>           <string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleExecutable</key>        <string>Clower</string>
    <key>CFBundleIconFile</key>          <string>Clower</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>LSMinimumSystemVersion</key>    <string>13.0</string>
    <key>LSUIElement</key>               <true/>
    <key>NSHighResolutionCapable</key>   <true/>
</dict>
</plist>
PLIST

# Info.plist가 유효한지 확인(깨진 plist는 앱이 조용히 안 뜬다).
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# ad-hoc 서명(무료). swiftc가 실행파일에 박은 linker 서명은 "리소스가 있다"고 주장하는데
# 번들엔 _CodeSignature가 없어 서명이 모순 상태다 → 다운로더에게 "손상됨"으로 아예 안 열릴 수
# 있다(우클릭→열기로도 못 뚫음). 번들 전체를 ad-hoc으로 다시 서명하면 서명이 정합해지고,
# 남는 건 "미확인 개발자"라는 뚫을 수 있는 정상 경로뿐이다(공증은 유료라 안 함).
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"   # 서명이 정합한지 확인(실패 시 set -e로 중단)

echo "== .dmg 생성 =="
# 스테이징에 앱 + /Applications 심볼릭을 넣어 "드래그해서 설치" dmg를 만든다.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT   # hdiutil 실패로 중단돼도 temp 정리
cp -R "$APP" "$STAGE/Clower.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DIST/Clower.dmg"
hdiutil create -volname "Clower" -srcfolder "$STAGE" -ov -format UDZO "$DIST/Clower.dmg" >/dev/null
rm -rf "$STAGE"

echo
echo "🎉 완성"
echo "   앱: $APP"
echo "   dmg: $DIST/Clower.dmg"
