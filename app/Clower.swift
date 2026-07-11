import AppKit
import Foundation
import ServiceManagement

// Clower 메뉴바 앱 (MVP).
// ~/.claude/clower/<session_id>.json 들을 1초마다 읽어 아이콘과 드롭다운을 그린다.
// 강제 규칙은 저장소 루트 CLAUDE.md 참조. 외부 의존성 0 (AppKit/Foundation만).

// hook이 쓰는 상태 파일 스키마와 동일.
struct SessionState: Codable {
    let session_id: String
    let state: String
    let cwd: String
    let updated_at: Int
}

let homeDir = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
let stateDir = homeDir + "/.claude/clower"
let settingsPath = homeDir + "/.claude/settings.json"

// MUST 8: working이 이 시간(초) 넘게 안 갱신되면 크래시로 보고 정리.
// waiting·idle은 사용자를 기다리는 상태라 heartbeat가 안 오는 게 정상 → SessionEnd까지 둔다.
let staleSeconds = 180

// 놓침 방지 에스컬레이션 임계값 (튜닝 가능한 기본값 — 써보며 조정).
// waiting 세션이 이만큼 방치되면 단계가 오른다.
let wiggleAfterSeconds = 30    // 아이콘 꿈틀 + 표정 시무룩
let alarmAfterSeconds = 120    // 소리 1회 + 표정 뾰로통 + 드롭다운 "N분째 대기 중"

// 상태 우선순위 (MUST 7): waiting > working > idle
func priority(_ state: String) -> Int {
    switch state {
    case "waiting": return 3
    case "working": return 2
    default: return 1
    }
}

// waiting 방치 경과(초) → 에스컬레이션 단계 애니메이션 key. 순수 함수라 --selftest로 검증한다.
// hook은 waiting 진입 때 updated_at을 한 번만 쓰므로 now - updated_at이 곧 대기 경과다.
func waitingKey(age: Int) -> String {
    if age < wiggleAfterSeconds { return "waiting1" }   // 0~30초: 차분히 올려다봄
    return age < alarmAfterSeconds ? "waiting2" : "waiting3"  // 30초~ 안절부절, 2분~ 하악질
}

// 실행파일 옆 assets/frames 에서 {name}_{i}.png 프레임을 로드한다(번들화 전 MVP 경로).
let framesDir: String = {
    let exeDir = (Bundle.main.executablePath as NSString?)?.deletingLastPathComponent ?? "."
    return exeDir + "/assets/frames"
}()

// 애니메이션별 프레임 유지 틱 수(작을수록 빠름). anim 타이머 0.08초 기준.
// 방치가 길수록 waiting이 빨라진다 = RunCat이 CPU를 속도로 보여주듯, 경과를 속도로 보여준다.
func holdTicks(for key: String) -> Int {
    switch key {
    case "working": return 2      // 종종걸음
    case "idle": return 16        // 느린 숨쉬기
    case "waiting1": return 5     // 차분히 올려다봄
    case "waiting2": return 3     // 안절부절
    case "waiting3": return 1     // 하악질(가장 빠름)
    default: return 8
    }
}

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var pollTimer: Timer?
    var animTimer: Timer?
    var frames: [String: [NSImage]] = [:]     // 애니메이션 key → 프레임들
    var alarmedSessions: Set<String> = []     // 2분 소리를 이미 울린 세션 (세션당 1회)

    // poll()이 정한 현재 표시 상태. render()가 이걸 그린다.
    var currentKey = ""                        // 현재 애니메이션 key ("" = 프레임 없음)
    var currentEmoji = "🐱"                    // 프레임 없을 때 폴백 이모지
    var animCounter = 0                        // render 틱 카운터(프레임 진행용)

    func applicationDidFinishLaunching(_ notification: Notification) {
        loadAllFrames()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        poll()
        render()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
        animTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            self?.render()
        }
    }

    // 컬러 아이콘 (MUST 9 갱신: 고양이 단색 실루엣 → 화분 새싹 컬러 일러스트).
    // isTemplate 안 씀 — 원색을 그대로 보여준다. 라이트·다크 양쪽에서 색이 죽지
    // 않도록 slice.py가 흰 배경만 투명 처리하고 원색은 완전 불투명 유지.
    let iconHeight: CGFloat = 22   // 메뉴바 아이콘 높이(시스템 아이콘 눈대중 기준).

    // 시작 시 모든 애니메이션 프레임을 로드. {name}_0.png 부터 끊길 때까지.
    // 없는 애니메이션은 빈 배열 → poll()이 이모지로 폴백한다.
    //
    // 2단계로 로드한다: 새싹은 상태마다 폭이 다르다(working은 세로로 길쭉, waiting3는
    // 더 좁고, neutral은 빈 화분이라 옆으로 넓다). 프레임마다 원래 비율로만 스케일하면
    // 상태·프레임이 바뀔 때마다 아이콘 박스 너비가 늘었다 줄었다 해서 옆 시스템 아이콘들이
    // 밀렸다 당겨졌다 한다. 그래서 실제로 자주 보이는 활성 상태(working/idle/waiting)의
    // 최대 폭으로 고정 캔버스를 만들어 그 중앙에 배치한다. neutral(세션 없을 때, 구조가
    // 아예 다른 빈 화분)은 이 기준보다 넓으면 그냥 자기 폭 그대로 둔다 — 억지로 줄이면
    // 찌그러진다. 이 폭이 옆 정사각형 시스템 아이콘보다 작지 않도록 최소 폭도 둔다.
    let minCanvasWidth: CGFloat = 20
    func loadAllFrames() {
        var rawByKey: [String: [NSImage]] = [:]
        var canonicalWidth: CGFloat = 0
        for key in ["working", "idle", "waiting1", "waiting2", "waiting3", "neutral"] {
            var imgs: [NSImage] = []
            var i = 0
            while let img = NSImage(contentsOfFile: "\(framesDir)/\(key)_\(i).png") {
                let scaledW = img.size.width * iconHeight / max(img.size.height, 1)
                img.size = NSSize(width: scaledW, height: iconHeight)
                if key != "neutral" { canonicalWidth = max(canonicalWidth, scaledW) }
                imgs.append(img)
                i += 1
            }
            rawByKey[key] = imgs
        }
        canonicalWidth = max(canonicalWidth, minCanvasWidth)
        for (key, imgs) in rawByKey {
            frames[key] = imgs.map {
                let w = max(canonicalWidth, $0.size.width)  // neutral처럼 더 넓으면 안 줄임
                return center($0, in: NSSize(width: w, height: iconHeight))
            }
        }
    }

    // image를 canvas 크기의 투명 캔버스 중앙에 그려 고정 폭 아이콘을 만든다.
    func center(_ image: NSImage, in canvas: NSSize) -> NSImage {
        let out = NSImage(size: canvas)
        out.lockFocus()
        let origin = NSPoint(x: (canvas.width - image.size.width) / 2,
                              y: (canvas.height - image.size.height) / 2)
        image.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1.0)
        out.unlockFocus()
        return out
    }

    // 상태 파일 로드 + stale 정리 (MUST 8).
    func loadSessions() -> [SessionState] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: stateDir) else { return [] }
        let now = Int(Date().timeIntervalSince1970)
        var sessions: [SessionState] = []
        for file in files where file.hasSuffix(".json") {
            let path = stateDir + "/" + file
            guard let data = fm.contents(atPath: path),
                  let s = try? JSONDecoder().decode(SessionState.self, from: data) else { continue }
            // waiting은 stale로 지우지 않는다: 사용자가 자리를 비운 사이 삭제되면
            // 놓침 방지 알림이 정작 필요한 순간에 사라진다. crash로 남은 waiting은
            // idle과 마찬가지로 SessionEnd/재시작 때까지 남는다.
            // ponytail: waiting에 상한 없음. 유령 waiting이 문제되면 아주 긴 상한(예: 30분) 추가.
            if s.state == "working" && now - s.updated_at > staleSeconds {
                try? fm.removeItem(atPath: path)  // 크래시로 멈춘 세션 정리
                continue
            }
            sessions.append(s)
        }
        // waiting 먼저
        return sessions.sorted { priority($0.state) > priority($1.state) }
    }

    // 프레임 로드 실패 시에만 쓰이는 최후 폴백 (평소엔 애니메이션 프레임이 항상 우선).
    func emoji(for state: String?) -> String {
        switch state {
        case "waiting": return "🌱"  // 나를 기다림
        case "working": return "🌿"  // 자라는 중
        case "idle": return "🍓"     // 수확 준비
        default: return "🪴"          // 세션 없음(빈 화분)
        }
    }

    // 1초마다: 상태를 읽어 어떤 애니메이션을 틀지 정하고, 소리를 울린다. 그림은 render()가.
    func poll() {
        let sessions = loadSessions()
        let top = sessions.first  // 이미 우선순위 정렬됨

        var key = "neutral"
        if let top = top {
            if top.state == "waiting" {
                let age = Int(Date().timeIntervalSince1970) - top.updated_at
                key = waitingKey(age: age)
                // 2분 넘게 방치된 waiting에 소리 1회 (세션당 한 번, 재진입 시 다시).
                if age >= alarmAfterSeconds && !alarmedSessions.contains(top.session_id) {
                    alarmedSessions.insert(top.session_id)
                    NSSound(named: "Funk")?.play()
                }
            } else {
                key = top.state  // "working" / "idle"
            }
        }

        // 프레임이 있으면 애니메이션, 없으면 이모지 폴백(waiting 그림 도착 전까지).
        if frames[key]?.isEmpty ?? true {
            currentKey = ""
            currentEmoji = fallbackEmoji(key: key, top: top)
        } else if key != currentKey {
            currentKey = key
            animCounter = 0  // 애니메이션 바뀌면 첫 프레임부터
        }

        // 더 이상 waiting이 아닌 세션은 알람 기록에서 뺀다 → 다음 waiting 진입 때 다시 울린다.
        let waitingIDs = Set(sessions.filter { $0.state == "waiting" }.map { $0.session_id })
        alarmedSessions.formIntersection(waitingIDs)
    }

    // 프레임 없는 상태의 이모지 폴백. waiting은 방치 단계별로 점점 시듦.
    func fallbackEmoji(key: String, top: SessionState?) -> String {
        switch key {
        case "waiting1": return "🌱"
        case "waiting2": return "🥀"
        case "waiting3": return "🥀"
        default: return emoji(for: top?.state)
        }
    }

    // 0.08초마다: 현재 애니메이션 프레임을 넘겨 그린다. 프레임 없으면 이모지.
    func render() {
        guard let button = statusItem.button else { return }
        animCounter &+= 1
        if let imgs = frames[currentKey], !imgs.isEmpty {
            let hold = holdTicks(for: currentKey)
            let idx = (animCounter / hold) % imgs.count
            button.image = imgs[idx]
            button.title = ""
        } else {
            button.image = nil
            button.title = currentEmoji
        }
    }

    func hooksInstalled() -> Bool {
        guard let data = FileManager.default.contents(atPath: settingsPath),
              let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains("clower-hook")
    }

    func stateMark(_ state: String) -> String {
        switch state {
        case "waiting": return "🔴"
        case "working": return "🟢"
        default: return "⚪️"
        }
    }

    // 메뉴가 열릴 때만 세션 목록을 다시 그린다(1초마다 갈아끼우면 열려있는 메뉴가 깜빡임).
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let sessions = loadSessions()
        if sessions.isEmpty {
            let msg = hooksInstalled() ? "활성 세션 없음" : "Hooks 미설치 — 설치 필요"
            let item = NSMenuItem(title: msg, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for s in sessions {
                let folder = (s.cwd as NSString).lastPathComponent
                var title = "\(stateMark(s.state))  \(folder)"
                if s.state == "waiting" {
                    let mins = (Int(Date().timeIntervalSince1970) - s.updated_at) / 60
                    title += mins >= 1 ? "  — \(mins)분째 대기 중" : "  — 대기 중"
                }
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        // Hooks 설치/제거: clower-hook 바이너리를 찾을 수 있을 때만 노출한다.
        if hookBinaryPath() != nil {
            let installed = hooksInstalled()
            let item = NSMenuItem(
                title: installed ? "Hooks 제거" : "Hooks 설치",
                action: installed ? #selector(uninstallHooks) : #selector(installHooks),
                keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        // 로그인 자동 실행: 반드시 안정 위치(/Applications)에서만 노출한다. DMG 마운트·
        // App Translocation 같은 휘발성 경로도 bundlePath가 .app으로 끝나므로, 거기서
        // register하면 status는 enabled인데 다음 로그인 땐 없는 경로를 가리키는 유령 항목이 된다.
        if inApplicationsFolder() {
            let item = NSMenuItem(title: "로그인 시 자동 실행", action: #selector(toggleLoginItem), keyEquivalent: "")
            item.target = self
            switch SMAppService.mainApp.status {
            case .enabled: item.state = .on            // 켜짐
            case .requiresApproval: item.state = .mixed // 등록됐으나 시스템 설정에서 승인 필요(대시)
            default: item.state = .off                  // notRegistered / notFound
            }
            menu.addItem(item)
        } else if Bundle.main.bundlePath.hasSuffix(".app") {
            let hint = NSMenuItem(title: "로그인 자동 실행: Applications에서 실행해야 켤 수 있음", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }
        let quit = NSMenuItem(title: "Clower 종료", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // clower-hook 바이너리 위치: 앱 실행파일 옆(번들) → 개발용 ../hook → 이미 설치된 경로 순.
    func hookBinaryPath() -> String? {
        let exeDir = (Bundle.main.executablePath as NSString?)?.deletingLastPathComponent ?? "."
        let candidates = [
            exeDir + "/clower-hook",
            exeDir + "/../hook/clower-hook",
            stateDir + "/clower-hook",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    @objc func installHooks() {
        runHookSetup(arg: "--install", verb: "설치",
                     detail: "~/.claude/settings.json에 Clower hook 6개를 추가합니다.\n기존 설정은 settings.json.bak으로 백업됩니다.")
    }

    @objc func uninstallHooks() {
        runHookSetup(arg: "--uninstall", verb: "제거",
                     detail: "settings.json에서 Clower hook만 제거합니다.\n다른 hook과 설정은 유지됩니다.")
    }

    // 병합 로직은 앱에 복붙하지 않는다. 검증된 clower-hook 바이너리를 그대로 실행한다(단일 출처).
    func runHookSetup(arg: String, verb: String, detail: String) {
        guard let bin = hookBinaryPath() else {
            alert(title: "clower-hook을 찾을 수 없음",
                  text: "hook 바이너리를 먼저 빌드하세요:\nswiftc hook/clower-hook.swift -o hook/clower-hook")
            return
        }
        let confirm = NSAlert()
        confirm.messageText = "Clower Hooks \(verb)"
        confirm.informativeText = detail
        confirm.addButton(withTitle: verb)
        confirm.addButton(withTitle: "취소")
        NSApp.activate(ignoringOtherApps: true)
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = [arg]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
            proc.waitUntilExit()  // 출력이 몇 줄뿐이라 파이프 버퍼가 안 찬다(먼저 wait 후 read 안전).
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let ok = proc.terminationStatus == 0
            alert(title: ok ? "\(verb) 완료" : "\(verb) 실패",
                  text: out.isEmpty ? "종료코드 \(proc.terminationStatus)" : out)
        } catch {
            alert(title: "실행 실패", text: error.localizedDescription)
        }
    }

    func alert(title: String, text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: "확인")
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    // 앱이 /Applications(또는 ~/Applications)에 정착했나. DMG·App Translocation 같은
    // 휘발성 경로를 걸러낸다 — 거기서 등록한 로그인 항목은 다음 로그인 때 조용히 죽는다.
    func inApplicationsFolder() -> Bool {
        let p = Bundle.main.bundlePath
        return p.hasPrefix("/Applications/") || p.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    // 로그인 항목 토글. 4개 status를 각각 다룬다 — requiresApproval(사용자가 설정에서 끔)을
    // 미등록과 뭉치면 재등록 루프에 갇혀 켜지도 끄지도 못한다.
    @objc func toggleLoginItem() {
        let svc = SMAppService.mainApp
        do {
            switch svc.status {
            case .enabled:
                try svc.unregister()
            case .requiresApproval:
                // 이미 등록됨. 재등록하지 말고 설정으로 유도한다.
                SMAppService.openSystemSettingsLoginItems()
                alert(title: "승인 필요", text: "시스템 설정 → 일반 → 로그인 항목에서 Clower를 켜 주세요.")
            default:  // notRegistered / notFound
                try svc.register()
                if svc.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                    alert(title: "승인 필요", text: "시스템 설정 → 일반 → 로그인 항목에서 Clower를 켜 주세요.")
                }
            }
        } catch {
            alert(title: "로그인 항목 변경 실패", text: error.localizedDescription)
        }
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

// 셀프테스트: 에스컬레이션 표정 매핑 검증 후 종료 (`Clower --selftest`). GUI 안 띄운다.
if CommandLine.arguments.contains("--selftest") {
    assert(waitingKey(age: 0) == "waiting1")
    assert(waitingKey(age: 29) == "waiting1")     // 30초 전: 차분
    assert(waitingKey(age: 30) == "waiting2")     // 30초~: 안절부절
    assert(waitingKey(age: 119) == "waiting2")
    assert(waitingKey(age: 120) == "waiting3")    // 2분~: 하악질
    assert(waitingKey(age: 600) == "waiting3")
    assert(priority("waiting") > priority("working") && priority("working") > priority("idle"))
    print("selftest OK")
    exit(0)
}

// 프레임 로드 경로 점검: 앱과 같은 framesDir에서 몇 장 찾는지, iconHeight로 스케일했을 때
// 폭이 얼마나 되는지(캔버스 고정폭 계산 검증) 출력 후 종료. GUI 안 띄운다.
if CommandLine.arguments.contains("--check") {
    print("framesDir:", framesDir)
    var canonicalWidth: CGFloat = 20  // minCanvasWidth와 동일값
    var byKey: [String: [String]] = [:]
    for key in ["working", "idle", "waiting1", "waiting2", "waiting3", "neutral"] {
        var i = 0
        var widths: [String] = []
        while FileManager.default.fileExists(atPath: "\(framesDir)/\(key)_\(i).png") {
            if let img = NSImage(contentsOfFile: "\(framesDir)/\(key)_\(i).png") {
                let w = img.size.width * 22 / max(img.size.height, 1)  // iconHeight와 동일값
                widths.append(String(format: "%.1f", w))
                if key != "neutral" { canonicalWidth = max(canonicalWidth, w) }
            }
            i += 1
        }
        byKey[key] = widths
        print("  \(key): \(i)프레임, 폭=\(widths.joined(separator: ","))")
    }
    print("활성 상태 기준 고정 캔버스 폭: \(String(format: "%.1f", canonicalWidth))pt (neutral은 자기 폭 유지)")
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // Dock 아이콘 숨김 (LSUIElement 상당)
let controller = AppController()
app.delegate = controller
app.run()
