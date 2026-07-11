# Clower

**Claude Code 세션이 나를 기다리는 순간을 놓치지 않게, macOS 메뉴바에서 상태를 보여주는 앱.**

[![Download](https://img.shields.io/github/v/release/tada-js/clower?label=download&color=D65A1E)](https://github.com/tada-js/clower/releases/latest)
[![License](https://img.shields.io/github/license/tada-js/clower)](https://github.com/tada-js/clower/blob/main/LICENSE)
[![Top Language](https://img.shields.io/github/languages/top/tada-js/clower)](https://github.com/tada-js/clower)
[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-black)](https://github.com/tada-js/clower)
[![Stars](https://img.shields.io/github/stars/tada-js/clower)](https://github.com/tada-js/clower/stargazers)

**[⬇︎ 최신 릴리스에서 Clower.dmg 받기](https://github.com/tada-js/clower/releases/latest)** — macOS 13+

<p align="left">
  <img src="app/assets/frames/working_0.png"  width="44" alt="working" />
  <img src="app/assets/frames/idle_0.png"     width="44" alt="idle" />
  <img src="app/assets/frames/waiting1_0.png" width="44" alt="waiting" />
  <img src="app/assets/frames/waiting3_0.png" width="44" alt="waiting 방치" />
</p>

긴 작업을 시켜놓고 다른 창으로 넘어가 있으면, Claude가 권한 승인을 기다리며 멈춰 있어도 모른 채 몇 분을 그대로 날리기 쉽습니다. 터미널 탭이 서너 개 열려 있으면 어느 세션이 멈췄는지 찾는 것부터가 일이고요. Clower는 세션 상태를 메뉴바의 화분 새싹으로 보여줘서 그 "놓침"을 없애 줍니다.

## 개요

Clower는 Claude Code hook이 남기는 상태 파일을 읽어, 지금 세션이 어떤 상태인지 메뉴바 아이콘 하나로 알려 줍니다.

<table>
  <tr>
    <td align="center" width="33%"><img src="app/assets/frames/working_0.png" height="56" alt="working" /></td>
    <td align="center" width="33%"><img src="app/assets/frames/idle_0.png" height="56" alt="idle" /></td>
    <td align="center" width="33%"><img src="app/assets/frames/waiting3_0.png" height="56" alt="waiting" /></td>
  </tr>
  <tr>
    <td align="center"><b>working</b><br/>Claude가 일하는 중<br/>새싹이 살랑거립니다</td>
    <td align="center"><b>idle</b><br/>턴이 끝나 쉬는 중<br/>열매가 익어 수확을 기다립니다</td>
    <td align="center"><b>waiting</b><br/>나를 기다리는 중(권한 승인 등)<br/>새싹이 목말라 시듭니다</td>
  </tr>
</table>

세션이 여러 개면 각각을 따로 추적해서, 가장 급한 상태 하나를 아이콘에 띄웁니다. 우선순위는 `waiting > working > idle`입니다.

## 핵심: 놓침 방지 에스컬레이션

비슷한 앱들은 waiting이 되는 순간 알림을 한 번 쏘고 끝이라, 그 배너를 놓치면 그걸로 끝입니다. Clower는 반응이 없으면 시간이 갈수록 티를 냅니다. 새싹이 점점 시들고 애니메이션이 빨라지며, 2분을 넘기면 소리로 한 번 알립니다. 응답하면 바로 원래 상태로 돌아옵니다.

## 요구사항

- macOS 13.0 이상 (로그인 자동 실행에 쓰는 `SMAppService` 때문)
- Claude Code

## 설치

두 단계입니다. 먼저 앱을 설치하고, 그다음 hook을 연결합니다.

### 1. 앱 설치

**Homebrew (권장)** — cask가 격리 딱지를 알아서 떼 주기 때문에 아래 Gatekeeper 절차가 필요 없습니다.

```bash
brew install --cask tada-js/tap/clower
```

**직접 다운로드** — [릴리스](https://github.com/tada-js/clower/releases/latest)에서 `Clower.dmg`를 받아 연 뒤(또는 `bash build-app.sh`로 직접 빌드), **Clower를 Applications 폴더로 드래그**합니다.

이 앱은 Apple 공증을 받지 않아서(무료 배포라 의도된 것입니다) 직접 다운로드로 설치하면 처음 실행할 때 macOS가 막습니다. 아래 방법으로 엽니다.

- **macOS 13~14**: Applications의 Clower를 **우클릭 → 열기 → 열기**
- **macOS 15+**: 한 번 실행을 시도한 뒤 **시스템 설정 → 개인정보 보호 및 보안**에서 "Clower을(를) 열도록 허용"을 클릭합니다
- 그래도 "손상됨"이라며 안 열리면 터미널에서 격리 딱지를 뗍니다: `xattr -dr com.apple.quarantine /Applications/Clower.app`

메뉴바에 화분 아이콘이 뜨면 앱이 설치된 것입니다. (아직 세션은 보이지 않습니다. hook을 연결해야 합니다.)

### 2. Hooks 연결

앱이 Claude Code 이벤트를 받으려면 hook을 등록해야 합니다. 메뉴바 아이콘을 눌러 **"Hooks 설치"**를 고르면 무엇이 바뀌는지 확인창이 뜨고, 승인하면 등록됩니다. 기존 `settings.json` 설정은 그대로 보존되고 백업됩니다.

이제 세션을 하나 열어 봅니다. 메뉴바 드롭다운에 폴더 이름과 상태가 뜹니다.

### 제거

메뉴에서 **"Hooks 제거"**를 눌러 hook을 뺍니다. 앱은 Homebrew로 설치했으면 `brew uninstall --cask tada-js/tap/clower`, 직접 설치했으면 Applications에서 지웁니다.

## 로드맵

- 공식 Homebrew cask 등재 (지금은 `tada-js/tap`, notability 기준을 충족하면 공식 `brew install --cask clower`)
- Apple 공증으로 Gatekeeper 경고 없애기 (유료라 보류)
- 터미널 점프(클릭 시 해당 세션으로 포커스)는 비목표입니다. 다른 앱이 이미 잘 풀어 놨습니다

## 개발

```bash
bash build-app.sh   # .app + .dmg 빌드
bash verify.sh      # 빌드·테스트·검증 게이트
```

## 고지

Clower는 Anthropic과 무관한 비공식 서드파티 도구입니다. "Claude"와 "Claude Code"는 Anthropic의 상표입니다.

*Clower is an unofficial, third-party tool and is not affiliated with Anthropic. "Claude" and "Claude Code" are trademarks of Anthropic.*

## 라이선스

MIT
