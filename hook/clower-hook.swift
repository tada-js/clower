import Foundation

// Clower hook — Claude Code가 이벤트마다 호출한다.
// stdin의 JSON을 읽어 세션 상태 파일을 원자적으로 갱신하고 exit 0.
// `--install`/`--uninstall`로 자기 자신을 설치·제거한다(settings.json 안전 병합).
// 강제 규칙은 저장소 루트 CLAUDE.md 참조. 외부 의존성 0 (Foundation만).

// waiting으로 매핑하는 notification_type (CLAUDE.md 관찰 기록: permission_prompt 실측 확인).
let waitingTypes: Set<String> = ["permission_prompt", "agent_needs_input"]

// hook은 Claude Code의 환경에서 실행되므로 $HOME을 그대로 쓴다(테스트에서 override 가능).
let home = ProcessInfo.processInfo.environment["HOME"]
    ?? FileManager.default.homeDirectoryForCurrentUser.path
let dir = home + "/.claude/clower"
let settingsPath = home + "/.claude/settings.json"
let installedHookPath = dir + "/clower-hook"

// settings.json에 등록하는 6개 이벤트 (CLAUDE.md hook 매핑).
let hookEvents = ["SessionStart", "UserPromptSubmit", "PostToolUse", "Stop", "Notification", "SessionEnd"]

// 원자적 쓰기: 임시 파일에 쓰고 rename()으로 교체 (MUST 3). rename은 같은 파일시스템에서 원자적.
func atomicWrite(_ data: Data, to dest: String) -> Bool {
    let tmp = "\(dest).\(getpid()).tmp"
    guard (try? data.write(to: URL(fileURLWithPath: tmp))) != nil else { return false }
    if rename(tmp, dest) != 0 { unlink(tmp); return false }
    return true
}

// 상태 파일 스키마. 앱도 같은 구조로 디코드한다.
struct SessionState: Codable {
    let session_id: String
    let state: String
    let cwd: String
    let updated_at: Int
}

func writeState(sessionID: String, state: String, cwd: String) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let payload = SessionState(session_id: sessionID, state: state, cwd: cwd,
                               updated_at: Int(Date().timeIntervalSince1970))
    guard let data = try? encoder.encode(payload) else { return }
    _ = atomicWrite(data, to: "\(dir)/\(sessionID).json")
}

func deleteState(sessionID: String) {
    unlink("\(dir)/\(sessionID).json")
}

// ---------------------------------------------------------------------------
// 설치·제거 (settings.json 안전 병합). CLAUDE.md: 이 병합만은 사용자 설정을 날릴 수
// 있으므로 게으르게 짜지 않는다. 순수 함수(mergedInstall/removedClower)로 분리해
// test-hook.sh가 "기존 설정 보존 · 중복 방지 · 롤백"을 실제 파일로 검증한다.
// ---------------------------------------------------------------------------

// 반환 nil = "파일은 있으나 파싱 불가" → 호출자가 반드시 중단(덮으면 사용자 설정 소실).
// 파일 없음·정상 파싱은 둘 다 진행해도 안전하므로 [:] / obj를 돌려준다.
// fail-open으로 빈 설정을 돌려주면 손편집(주석·문법오류)한 settings.json을 통째로 날린다.
func loadSettings() -> [String: Any]? {
    guard let data = FileManager.default.contents(atPath: settingsPath) else {
        return [:]   // 파일 없음 → 빈 설정에서 시작해도 안전
    }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]  // 파싱 실패 시 nil
}

func saveSettings(_ settings: [String: Any]) -> Bool {
    guard let data = try? JSONSerialization.data(
        withJSONObject: settings,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return false }
    return atomicWrite(data, to: settingsPath)
}

// 쓰기 전에 원본을 .bak으로 백업(롤백용). 최초 원본만 보존한다 — 이미 .bak이 있으면 덮지
// 않는다(반복 install이 pristine 백업을 merged 결과로 덮어 원본을 영구 소실시키는 것 방지).
// 원자적으로 쓰고, 백업이 꼭 있어야 하는데 실패하면 false(호출자가 설치를 중단한다).
func backupSettings() -> Bool {
    let bak = settingsPath + ".bak"
    guard let data = FileManager.default.contents(atPath: settingsPath) else { return true }  // 원본 없음 = 백업할 것 없음
    if FileManager.default.fileExists(atPath: bak) { return true }  // 이미 원본 백업 존재 → 유지
    return atomicWrite(data, to: bak)
}

// 이벤트 배열에 이미 clower-hook 항목이 있나? (중복 방지)
func hasClowerHook(_ eventArray: [Any]) -> Bool {
    for entry in eventArray {
        guard let e = entry as? [String: Any],
              let hooks = e["hooks"] as? [[String: Any]] else { continue }
        for h in hooks {
            if let cmd = h["command"] as? String, cmd.contains("clower-hook") { return true }
        }
    }
    return false
}

// 6개 이벤트에 clower-hook을 병합. 기존 hook·다른 키는 건드리지 않고, 이미 있으면 안 쌓는다.
// nil 반환 = hooks 또는 이벤트 값이 예상 밖 타입(객체가 아닌 hooks, 배열이 아닌 이벤트) →
// 캐스팅 실패를 빈 컨테이너로 조용히 대체하면 그 사용자 값이 소실된다. 덮지 말고 중단시킨다.
func mergedInstall(_ settings: [String: Any], command: String) -> [String: Any]? {
    var s = settings
    if let existing = s["hooks"], !(existing is [String: Any]) { return nil }
    var hooks = s["hooks"] as? [String: Any] ?? [:]
    for event in hookEvents {
        if let existing = hooks[event], !(existing is [Any]) { return nil }
        var arr = hooks[event] as? [Any] ?? []
        if !hasClowerHook(arr) {
            arr.append(["hooks": [["type": "command", "command": command]]])
        }
        hooks[event] = arr
    }
    s["hooks"] = hooks
    return s
}

// clower-hook 항목만 제거. 다른 hook과 섞인 항목은 통째로 건드리지 않는다(보수적).
// ponytail: install은 clower를 항상 단독 항목으로 넣으므로 실무상 섞일 일이 없다.
//           사용자가 손으로 한 항목에 섞어 넣었다면 그 항목은 보존한다(망치는 것보다 남기는 게 안전).
func removedClower(_ settings: [String: Any]) -> [String: Any] {
    var s = settings
    guard var hooks = s["hooks"] as? [String: Any] else { return s }
    for event in hookEvents {
        guard let arr = hooks[event] as? [Any] else { continue }
        let kept = arr.filter { entry -> Bool in
            guard let e = entry as? [String: Any],
                  let hs = e["hooks"] as? [[String: Any]] else { return true }
            let nonClower = hs.filter { !(($0["command"] as? String)?.contains("clower-hook") ?? false) }
            if nonClower.isEmpty { return false }      // clower 단독 항목 → 제거
            return true                                 // 다른 hook과 섞였으면 보존
        }
        if kept.isEmpty { hooks.removeValue(forKey: event) }
        else { hooks[event] = kept }
    }
    if hooks.isEmpty { s.removeValue(forKey: "hooks") } else { s["hooks"] = hooks }
    return s
}

// 실행 중인 자기 바이너리를 dir로 복사한다(이미 거기서 돌면 건너뜀).
func resolvedSelfPath() -> String {
    Bundle.main.executablePath ?? CommandLine.arguments[0]
}

func copySelf(to dest: String) -> Bool {
    let src = resolvedSelfPath()
    if src == dest { return true }
    let fm = FileManager.default
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try? fm.removeItem(atPath: dest)
    guard (try? fm.copyItem(atPath: src, toPath: dest)) != nil else { return false }
    chmod(dest, 0o755)
    // 격리(quarantine) 딱지 제거. copyItem은 xattr을 보존하므로, 다운로드한 .app 안의 hook을
    // 그대로 복사하면 설치된 hook도 격리된다. 그러면 Claude Code가 매 이벤트마다 이 CLI를
    // exec할 때 Gatekeeper가 죽여 상태가 조용히 안 갱신된다. 없으면 -1이라 무시해도 안전.
    removexattr(dest, "com.apple.quarantine", 0)
    return true
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8)); exit(1)
}

func runInstall() {
    let settingsExisted = FileManager.default.fileExists(atPath: settingsPath)
    guard copySelf(to: installedHookPath) else { fail("설치 실패: 바이너리 복사 오류") }
    guard let settings = loadSettings() else {
        fail("설치 중단: \(settingsPath)을 파싱할 수 없습니다(손상 또는 주석 등). 설정을 건드리지 않았습니다. 파일을 고친 뒤 다시 시도하세요.")
    }
    guard backupSettings() else { fail("설치 중단: settings.json 백업 실패. 설정을 건드리지 않았습니다.") }
    guard let merged = mergedInstall(settings, command: installedHookPath) else {
        fail("설치 중단: settings.json의 hooks 구조가 예상과 다릅니다(hooks가 객체가 아니거나 이벤트가 배열이 아님). 설정을 건드리지 않았습니다.")
    }
    guard saveSettings(merged) else { fail("설치 실패: settings.json 쓰기 오류") }
    print("✅ 설치 완료")
    print("   hook 바이너리: \(installedHookPath)")
    if settingsExisted { print("   settings.json 백업: \(settingsPath).bak") }
    print("   Claude Code에서 /hooks로 등록을 확인하세요.")
    exit(0)
}

func runUninstall() {
    guard FileManager.default.fileExists(atPath: settingsPath) else {
        unlink(installedHookPath)   // 설정 파일이 없으면 뺄 것도 없음. 바이너리만 정리.
        print("✅ 제거 완료 (settings.json 없음)")
        exit(0)
    }
    guard let settings = loadSettings() else {
        fail("제거 중단: \(settingsPath)을 파싱할 수 없습니다. 설정을 건드리지 않았습니다.")
    }
    guard backupSettings() else { fail("제거 중단: settings.json 백업 실패. 설정을 건드리지 않았습니다.") }
    guard saveSettings(removedClower(settings)) else { fail("제거 실패: settings.json 쓰기 오류") }
    unlink(installedHookPath)   // 설치한 바이너리 제거. 상태 파일은 남겨 둠(SessionEnd가 정리).
    print("✅ 제거 완료")
    print("   settings.json에서 clower-hook 항목을 뺐습니다(백업: \(settingsPath).bak).")
    print("   상태 파일까지 지우려면: rm -rf \(dir)")
    exit(0)
}

// --- 인자 처리: 설치/제거는 stdin을 읽기 전에 갈라진다 ---
if CommandLine.arguments.contains("--install")   { runInstall() }
if CommandLine.arguments.contains("--uninstall") { runUninstall() }

// --- stdin 파싱 (hook 이벤트) ---
let input = FileHandle.standardInput.readDataToEndOfFile()
guard let obj = try? JSONSerialization.jsonObject(with: input) as? [String: Any] else {
    exit(0)  // 파싱 실패해도 Claude Code를 막지 않는다.
}
// 파일 키는 언제나 session_id (MUST 2). 없으면 아무것도 못 한다.
guard let sessionID = obj["session_id"] as? String, !sessionID.isEmpty else {
    exit(0)
}
let event = obj["hook_event_name"] as? String ?? ""
let cwd = obj["cwd"] as? String ?? ""

switch event {
case "SessionStart":
    writeState(sessionID: sessionID, state: "idle", cwd: cwd)
case "UserPromptSubmit", "PostToolUse":
    // PostToolUse는 승인 뒤 working 복구 신호 (MUST 5).
    writeState(sessionID: sessionID, state: "working", cwd: cwd)
case "Stop":
    writeState(sessionID: sessionID, state: "idle", cwd: cwd)
case "Notification":
    // 구조화된 notification_type로 판정. 모르는 타입은 idle로 안전 강등 (MUST 6).
    let type = obj["notification_type"] as? String ?? ""
    writeState(sessionID: sessionID, state: waitingTypes.contains(type) ? "waiting" : "idle", cwd: cwd)
case "SessionEnd":
    deleteState(sessionID: sessionID)
default:
    break
}
exit(0)
