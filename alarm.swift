// alarm — 安靜的視覺鬧鐘（不出聲）
// build: ./build.sh  （只用系統內建的 AppKit，不需要外部套件）

import AppKit
import Darwin

// MARK: - 說明

let helpText = """
alarm — 安靜的視覺鬧鐘（不出聲）

用法
  alarm <時間> [訊息...] [選項]   設定鬧鐘（預設在背景執行）
  alarm list                      列出鬧鐘
  alarm cancel <id...|all>        取消鬧鐘
  alarm dismiss [id...]           關掉正在響的鬧鐘（不給 id = 全部）
  alarm help                      顯示這個說明

時間
  25                    25 分鐘（純數字 = 分鐘）
  90s  25m  1h30m  1.5h 倒數
  14:30  9:05pm  7:00:30
                        指定時刻（已經過了就是明天）
  now                   立刻（測試用）

選項
  -e, --effects <list>  視覺效果，逗號分隔（預設 glow）
                          glow    螢幕邊緣光暈 + 訊息標籤
                          dialog  畫面中央的大訊息卡
                          notify  系統通知
                          flash   螢幕閃一下
  -c, --color <color>   顏色：orange red pink purple blue cyan green yellow
                        或 #RRGGBB（預設 orange）
  -t, --timeout <時間>  響多久後自動消失（預設一直亮到你按掉）
  -s, --snooze <時間>   「延後」按鈕的時間（預設 5m）
      --fg              留在前景執行（Ctrl-C 取消）
  -h, --help            顯示這個說明

環境變數（改預設值）
  ALARM_EFFECTS  ALARM_COLOR  ALARM_TIMEOUT  ALARM_SNOOZE

關掉鬧鐘：點一下訊息標籤，或執行 alarm dismiss

範例
  alarm 25m 專心時間結束
  alarm 12:00 吃飯 -e glow,notify
  alarm 50m 起來走走 -c green -t 2m
"""

// MARK: - 資料

struct Alarm: Codable {
    var id: Int
    var pid: Int32
    var deadline: Double          // unix time
    var createdAt: Double
    var spec: String              // 顯示用，例如 "25m" 或 "14:30"
    var isCountdown: Bool
    var message: String
    var effects: [String]
    var color: String
    var timeout: Double?          // 響了之後幾秒自動消失；nil = 一直亮
    var snooze: Double
    var snoozed: Int = 0
}

let allEffects = ["glow", "dialog", "notify", "flash"]

/// 每個鬧鐘一個 JSON 檔，放在 $TMPDIR（重開機會被清掉）。
/// 正在響的鬧鐘另外有一個 .firing 標記檔。
enum Store {
    static let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("simple-alarm")
    static func url(_ id: Int) -> URL { dir.appendingPathComponent("\(id).json") }
    static func firingURL(_ id: Int) -> URL { dir.appendingPathComponent("\(id).firing") }

    static func ensureDir() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// 用 O_EXCL 搶一個最小的未使用 id
    static func reserveID() -> Int {
        ensureDir()
        var id = 1
        while true {
            let fd = open(url(id).path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
            if fd >= 0 { close(fd); return id }
            id += 1
        }
    }

    static func save(_ a: Alarm) {
        guard let data = try? JSONEncoder().encode(a) else { return }
        try? data.write(to: url(a.id), options: .atomic)
    }

    static func load(_ id: Int) -> Alarm? {
        guard let data = try? Data(contentsOf: url(id)) else { return nil }
        return try? JSONDecoder().decode(Alarm.self, from: data)
    }

    static func remove(_ id: Int) {
        try? FileManager.default.removeItem(at: url(id))
        try? FileManager.default.removeItem(at: firingURL(id))
    }

    static func isFiring(_ id: Int) -> Bool {
        FileManager.default.fileExists(atPath: firingURL(id).path)
    }

    /// 所有還活著的鬧鐘；程序已經不在的順手清掉
    static func all() -> [Alarm] {
        ensureDir()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let now = Date().timeIntervalSince1970
        var result: [Alarm] = []
        for name in names where name.hasSuffix(".json") {
            guard let id = Int(name.dropLast(5)) else { continue }
            guard let a = load(id) else {
                // 剛 reserve、還沒寫入的檔案；放太久就是殘骸
                let mtime = (try? FileManager.default.attributesOfItem(atPath: url(id).path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                if now - mtime > 30 { remove(id) }
                continue
            }
            let alive = a.pid > 0 ? (kill(a.pid, 0) == 0 || errno == EPERM) : now - a.createdAt < 10
            if alive { result.append(a) } else { remove(id) }
        }
        return result.sorted { $0.deadline < $1.deadline }
    }
}

// MARK: - 解析與格式化

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write("alarm: \(msg)\n（alarm help 看用法）\n".data(using: .utf8)!)
    exit(2)
}

/// "90s" "25m" "1h30m" "1.5h"；純數字 = 分鐘
func parseDuration(_ s: String) -> Double? {
    let s = s.lowercased()
    if let n = Double(s) { return n >= 0 ? n * 60 : nil }
    var total = 0.0, num = "", matched = false
    for ch in s {
        if ch.isASCII && (ch.isNumber || ch == ".") { num.append(ch); continue }
        guard let n = Double(num) else { return nil }
        switch ch {
        case "h": total += n * 3600
        case "m": total += n * 60
        case "s": total += n
        default: return nil
        }
        num = ""
        matched = true
    }
    return num.isEmpty && matched ? total : nil
}

/// "14:30" "9:05pm" "7:00:30"，回傳下一個符合的時刻
func parseClock(_ s: String) -> Date? {
    var s = s.lowercased().trimmingCharacters(in: .whitespaces)
    var pm: Bool? = nil
    if s.hasSuffix("am") || s.hasSuffix("pm") {
        pm = s.hasSuffix("pm")
        s = String(s.dropLast(2)).trimmingCharacters(in: .whitespaces)
    }
    let parts = s.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) }
    guard (2...3).contains(parts.count), parts.allSatisfy({ $0 != nil }) else { return nil }
    var h = parts[0]!
    let m = parts[1]!, sec = parts.count == 3 ? parts[2]! : 0
    if let pm {
        guard (1...12).contains(h) else { return nil }
        h = h % 12 + (pm ? 12 : 0)
    }
    guard (0...23).contains(h), (0...59).contains(m), (0...59).contains(sec) else { return nil }
    return Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: h, minute: m, second: sec),
                                     matchingPolicy: .nextTime)
}

func parseColor(_ s: String) -> NSColor? {
    switch s.lowercased() {
    case "orange": return .systemOrange
    case "red": return .systemRed
    case "pink": return .systemPink
    case "purple": return .systemPurple
    case "blue": return .systemBlue
    case "cyan", "teal": return .systemTeal
    case "green": return .systemGreen
    case "yellow": return .systemYellow
    default: break
    }
    var hex = s
    if hex.hasPrefix("#") { hex.removeFirst() }
    guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
    return NSColor(srgbRed: CGFloat(v >> 16 & 0xff) / 255, green: CGFloat(v >> 8 & 0xff) / 255,
                   blue: CGFloat(v & 0xff) / 255, alpha: 1)
}

/// 3725 → "1h2m5s"
func fmtDuration(_ sec: Double) -> String {
    let t = Int(sec.rounded())
    let h = t / 3600, m = t % 3600 / 60, s = t % 60
    var r = ""
    if h > 0 { r += "\(h)h" }
    if m > 0 { r += "\(m)m" }
    if s > 0 || r.isEmpty { r += "\(s)s" }
    return r
}

/// 300 → "5 分鐘"
func humanDuration(_ sec: Double) -> String {
    let t = Int(sec.rounded())
    if t >= 3600 && t % 3600 == 0 { return "\(t / 3600) 小時" }
    if t >= 60 && t % 60 == 0 { return "\(t / 60) 分鐘" }
    return "\(t) 秒"
}

func clockString(_ t: Double) -> String {
    let d = Date(timeIntervalSince1970: t)
    let f = DateFormatter()
    let cal = Calendar.current
    f.dateFormat = cal.isDateInToday(d) ? "HH:mm" : cal.isDateInTomorrow(d) ? "'明天' HH:mm" : "M/d HH:mm"
    return f.string(from: d)
}

// MARK: - 子指令

func cmdNew(_ args: [String]) {
    let env = ProcessInfo.processInfo.environment
    var effectsArg = env["ALARM_EFFECTS"] ?? "glow"
    var colorArg = env["ALARM_COLOR"] ?? "orange"
    var timeoutArg = env["ALARM_TIMEOUT"]
    var snoozeArg = env["ALARM_SNOOZE"] ?? "5m"
    var foreground = false
    var positional: [String] = []

    var i = 0
    while i < args.count {
        var a = args[i]
        var inlineValue: String? = nil
        if a.hasPrefix("--"), let eq = a.firstIndex(of: "=") {
            inlineValue = String(a[a.index(after: eq)...])
            a = String(a[..<eq])
        }
        func value() -> String {
            if let inlineValue { return inlineValue }
            i += 1
            guard i < args.count else { fail("\(a) 需要一個值") }
            return args[i]
        }
        switch a {
        case "-e", "--effects": effectsArg = value()
        case "-c", "--color": colorArg = value()
        case "-t", "--timeout": timeoutArg = value()
        case "-s", "--snooze": snoozeArg = value()
        case "--fg": foreground = true
        case "-h", "--help": print(helpText); exit(0)
        case "--": positional += args[(i + 1)...]; i = args.count; continue
        default:
            if a.hasPrefix("-") && a.count > 1 { fail("不認識的選項 \(a)") }
            positional.append(a)
        }
        i += 1
    }

    guard let spec = positional.first else { fail("缺少時間") }
    let message = positional.dropFirst().joined(separator: " ")

    let now = Date()
    let deadline: Date
    let isCountdown: Bool
    let displaySpec: String
    if spec.lowercased() == "now" {
        (deadline, isCountdown, displaySpec) = (now, false, "now")
    } else if spec.contains(":") {
        guard let d = parseClock(spec) else { fail("看不懂的時刻 \(spec)") }
        (deadline, isCountdown, displaySpec) = (d, false, spec)
    } else {
        guard let sec = parseDuration(spec) else { fail("看不懂的時間 \(spec)") }
        (deadline, isCountdown, displaySpec) = (now.addingTimeInterval(sec), true, fmtDuration(sec))
    }

    let effects = effectsArg.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    guard !effects.isEmpty else { fail("至少要一個效果") }
    for e in effects where !allEffects.contains(e) { fail("不認識的效果 \(e)（可用：\(allEffects.joined(separator: ", "))）") }
    guard parseColor(colorArg) != nil else { fail("看不懂的顏色 \(colorArg)") }
    var timeout: Double? = nil
    if let timeoutArg, !timeoutArg.isEmpty {
        guard let t = parseDuration(timeoutArg), t > 0 else { fail("看不懂的 timeout \(timeoutArg)") }
        timeout = t
    }
    guard let snooze = parseDuration(snoozeArg), snooze > 0 else { fail("看不懂的 snooze \(snoozeArg)") }

    var alarm = Alarm(id: Store.reserveID(), pid: 0, deadline: deadline.timeIntervalSince1970,
                      createdAt: now.timeIntervalSince1970, spec: displaySpec, isCountdown: isCountdown,
                      message: message, effects: effects, color: colorArg, timeout: timeout, snooze: snooze)

    let remain = isCountdown || spec.lowercased() == "now" ? "" : "（\(fmtDuration(deadline.timeIntervalSince(now)))後）"
    let line = "⏰ #\(alarm.id)  \(clockString(alarm.deadline)) 響\(remain)\(message.isEmpty ? "" : "  \(message)")"

    if foreground {
        alarm.pid = getpid()
        Store.save(alarm)
        print(line + "  — 前景執行中，Ctrl-C 取消")
        runAlarm(alarm)
    }

    Store.save(alarm)
    guard let pid = spawnDetached(["__run", String(alarm.id)]) else {
        Store.remove(alarm.id)
        fail("無法啟動背景程序")
    }
    alarm.pid = pid
    Store.save(alarm)
    print(line)
}

func cmdList() {
    let alarms = Store.all()
    if alarms.isEmpty { print("沒有鬧鐘"); return }
    let now = Date().timeIntervalSince1970
    for a in alarms {
        let state = Store.isFiring(a.id) ? "響鈴中" : "剩 " + fmtDuration(max(0, (a.deadline - now).rounded(.up)))
        let msg = a.message.isEmpty ? "" : "  \(a.message)"
        print("#\(a.id)  \(clockString(a.deadline))  \(state)\(msg)")
    }
}

func stop(_ a: Alarm) {
    if a.pid > 0 { kill(a.pid, SIGTERM) }
    Store.remove(a.id)
}

func cmdCancel(_ args: [String]) {
    guard !args.isEmpty else { fail("要取消哪個？給 id 或 all") }
    let alarms = Store.all()
    if args == ["all"] {
        alarms.forEach(stop)
        print("取消了 \(alarms.count) 個鬧鐘")
        return
    }
    for arg in args {
        let id = Int(arg.hasPrefix("#") ? String(arg.dropFirst()) : arg)
        guard let a = alarms.first(where: { $0.id == id }) else { print("找不到 #\(arg)"); continue }
        stop(a)
        print("取消 #\(a.id)")
    }
}

func cmdDismiss(_ args: [String]) {
    if !args.isEmpty { cmdCancel(args); return }
    let firing = Store.all().filter { Store.isFiring($0.id) }
    if firing.isEmpty { print("沒有正在響的鬧鐘"); return }
    firing.forEach(stop)
    print("關掉 \(firing.count) 個鬧鐘")
}

/// 用 setsid 開一個脫離 terminal 的子程序
func spawnDetached(_ arguments: [String]) -> pid_t? {
    let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
    var attr: posix_spawnattr_t? = nil
    posix_spawnattr_init(&attr)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
    var actions: posix_spawn_file_actions_t? = nil
    posix_spawn_file_actions_init(&actions)
    for fd: Int32 in 0...2 {
        posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0)
    }
    let argv: [UnsafeMutablePointer<CChar>?] = ([exe] + arguments).map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    var pid: pid_t = 0
    let rc = posix_spawn(&pid, exe, &actions, &attr, argv, environ)
    posix_spawnattr_destroy(&attr)
    posix_spawn_file_actions_destroy(&actions)
    return rc == 0 ? pid : nil
}

// MARK: - 響鈴

var signalSources: [DispatchSourceSignal] = []

func runAlarm(_ alarm: Alarm) -> Never {
    for sig in [SIGINT, SIGTERM, SIGHUP] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler { Store.remove(alarm.id); exit(0) }
        src.resume()
        signalSources.append(src)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)   // 不出現在 Dock、不搶焦點
    let controller = AlarmController(alarm: alarm)
    controller.start()
    app.run()
    exit(0)
}

/// 蓋在所有東西（包含全螢幕 app）上面、每個 Space 都看得到
let overlayBehavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
let glowLevel = NSWindow.Level.screenSaver
let panelLevel = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)

func makeOverlayWindow(_ screen: NSScreen) -> NSWindow {
    let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
    w.setFrame(screen.frame, display: false)
    w.isOpaque = false
    w.backgroundColor = .clear
    w.hasShadow = false
    w.ignoresMouseEvents = true
    w.level = glowLevel
    w.collectionBehavior = overlayBehavior
    w.isReleasedWhenClosed = false
    return w
}

final class AlarmController: NSObject {
    var alarm: Alarm
    let color: NSColor
    var timer: DispatchSourceTimer?
    var activity: NSObjectProtocol?
    var windows: [NSWindow] = []
    var eyebrow: NSTextField?
    var ticker: Timer?
    var firedAt: Date?
    var generation = 0

    init(alarm: Alarm) {
        self.alarm = alarm
        self.color = parseColor(alarm.color) ?? .systemOrange
    }

    func start() {
        // 避免 App Nap 延遲計時，但不阻止系統睡眠
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "alarm")
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(checkDue),
                                                          name: NSWorkspace.didWakeNotification, object: nil)
        schedule()
    }

    func schedule() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        // walltime：Mac 睡眠期間也照實際時間算，醒來時若已過期會馬上觸發
        t.schedule(wallDeadline: .now() + max(0, alarm.deadline - Date().timeIntervalSince1970),
                   leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.checkDue() }
        t.resume()
        timer = t
    }

    @objc func checkDue() {
        guard firedAt == nil else { return }
        if Date().timeIntervalSince1970 >= alarm.deadline { fire() } else { schedule() }
    }

    func fire() {
        timer?.cancel()
        firedAt = Date()
        generation += 1
        FileManager.default.createFile(atPath: Store.firingURL(alarm.id).path, contents: nil)

        let fx = Set(alarm.effects)
        if fx.contains("flash") { flash() }
        if fx.contains("notify") { notify() }
        if fx.contains("glow") { showGlow() }
        if fx.contains("dialog") { showPanel(dialog: true) } else if fx.contains("glow") { showPanel(dialog: false) }

        if !fx.contains("glow") && !fx.contains("dialog") {
            // 沒有常駐的畫面，閃完就結束
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.finish() }
            return
        }
        ticker = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.updateEyebrow() }
        if let timeout = alarm.timeout {
            let gen = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, self.generation == gen, self.firedAt != nil else { return }
                self.finish()
            }
        }
    }

    @objc func finish() {
        Store.remove(alarm.id)
        exit(0)
    }

    @objc func snooze() {
        ticker?.invalidate()
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        firedAt = nil
        alarm.pid = getpid()
        alarm.deadline = Date().timeIntervalSince1970 + alarm.snooze
        alarm.snoozed += 1
        Store.save(alarm)
        try? FileManager.default.removeItem(at: Store.firingURL(alarm.id))
        schedule()
    }

    // MARK: 效果

    func showGlow() {
        for screen in NSScreen.screens {
            let w = makeOverlayWindow(screen)
            w.contentView = GlowView(frame: NSRect(origin: .zero, size: screen.frame.size), color: color)
            w.alphaValue = 0
            w.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.6; w.animator().alphaValue = 1 }
            windows.append(w)
        }
    }

    func flash() {
        let tint = color.blended(withFraction: 0.6, of: .white) ?? .white
        for screen in NSScreen.screens {
            let w = makeOverlayWindow(screen)
            w.backgroundColor = tint
            w.alphaValue = 0
            w.orderFrontRegardless()
            func pulse(_ n: Int) {
                guard n > 0 else { w.orderOut(nil); return }
                NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; w.animator().alphaValue = 0.75 }) {
                    NSAnimationContext.runAnimationGroup({ $0.duration = 0.35; w.animator().alphaValue = 0 }) { pulse(n - 1) }
                }
            }
            pulse(2)
        }
    }

    func notify() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        // 訊息從 argv 傳，避免跳脫問題；不指定 sound name 就不會出聲
        p.arguments = ["-e", "on run argv", "-e", "display notification (item 2 of argv) with title (item 1 of argv)",
                       "-e", "end run", "⏰ 鬧鐘", alarm.message.isEmpty ? "時間到" : alarm.message]
        try? p.run()
    }

    func updateEyebrow() {
        var parts = [clockString(alarm.deadline)]
        if alarm.isCountdown { parts.append("\(alarm.spec) 倒數") }
        if alarm.snoozed > 0 { parts.append("延後 \(alarm.snoozed) 次") }
        if let f = firedAt, Date().timeIntervalSince(f) >= 60 {
            parts.append("已過 \(Int(Date().timeIntervalSince(f)) / 60) 分鐘")
        }
        eyebrow?.stringValue = parts.joined(separator: " · ")
    }

    /// dialog = 畫面中央的大卡片；否則是光暈上方的訊息標籤
    func showPanel(dialog: Bool) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
                ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let accent = color.blended(withFraction: 0.4, of: .white) ?? color

        let icon = NSImageView(image: NSImage(systemSymbolName: "alarm.fill", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        icon.contentTintColor = accent
        let eyebrow = NSTextField(labelWithString: "")
        eyebrow.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        eyebrow.textColor = accent
        eyebrow.lineBreakMode = .byTruncatingTail
        eyebrow.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        self.eyebrow = eyebrow
        updateEyebrow()
        let header = NSStackView(views: [icon, eyebrow])
        header.spacing = 5

        let text = alarm.message.isEmpty ? "時間到" : alarm.message
        let font = NSFont.systemFont(ofSize: dialog ? 36 : 28, weight: .semibold)
        let maxWidth = min(dialog ? 720 : 640, screen.frame.width - 160)
        let measured = (text as NSString).boundingRect(with: NSSize(width: maxWidth, height: 10_000),
                                                       options: .usesLineFragmentOrigin, attributes: [.font: font])
        let title = NSTextField(wrappingLabelWithString: text)
        title.font = font
        title.textColor = .white
        title.alignment = .center
        title.isSelectable = false
        title.maximumNumberOfLines = 6
        let titleWidth = ceil(measured.width) + 4
        title.preferredMaxLayoutWidth = titleWidth
        title.widthAnchor.constraint(equalToConstant: titleWidth).isActive = true

        let snoozeButton = FirstClickButton(title: "延後 \(humanDuration(alarm.snooze))", target: self, action: #selector(snooze))
        let closeButton = FirstClickButton(title: "關閉", target: self, action: #selector(finish))
        closeButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [snoozeButton, closeButton])
        buttons.spacing = 10

        let stack = NSStackView(views: [header, title, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(18, after: title)
        stack.edgeInsets = NSEdgeInsets(top: dialog ? 26 : 18, left: 36, bottom: dialog ? 22 : 16, right: 36)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let radius: CGFloat = dialog ? 26 : 22
        let card = CardView()
        card.material = .hudWindow
        card.blendingMode = .behindWindow
        card.state = .active
        card.appearance = NSAppearance(named: .darkAqua)
        card.maskImage = roundedMask(radius)
        card.buttonRow = buttons
        card.idleAlpha = dialog ? 1 : 0.4
        buttons.alphaValue = card.idleAlpha
        card.onClick = { [weak self] in self?.finish() }
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        let width = max(titleWidth + 80, dialog ? 420 : 340)
        stack.widthAnchor.constraint(equalToConstant: width).isActive = true
        let size = NSSize(width: width, height: stack.fittingSize.height)
        card.setFrameSize(size)

        let border = BorderView(frame: NSRect(origin: .zero, size: size))
        border.autoresizingMask = [.width, .height]
        border.wantsLayer = true
        border.layer?.cornerRadius = radius
        border.layer?.cornerCurve = .continuous
        border.layer?.borderWidth = 1.5
        border.layer?.borderColor = color.withAlphaComponent(0.85).cgColor
        card.addSubview(border)

        let f = screen.frame
        let origin = dialog
            ? NSPoint(x: f.midX - size.width / 2, y: f.midY - size.height / 2 + f.height * 0.08)
            : NSPoint(x: f.midX - size.width / 2, y: f.maxY - f.height * 0.12 - size.height)

        let panel = NonKeyPanel(contentRect: NSRect(origin: origin, size: size),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = panelLevel
        panel.collectionBehavior = overlayBehavior
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = card
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.35; panel.animator().alphaValue = 1 }
        windows.append(panel)
    }
}

func roundedMask(_ r: CGFloat) -> NSImage {
    let edge = r * 2 + 1
    let img = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
        return true
    }
    img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
    img.resizingMode = .stretch
    return img
}

// MARK: - 視圖

/// 螢幕四周的內光暈：在畫面外畫一圈實心框，只讓它的陰影滲進畫面裡
final class GlowView: NSView {
    let color: NSColor

    init(frame: NSRect, color: NSColor) {
        self.color = color
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { build() }
    }

    func build() {
        guard let root = layer else { return }
        root.sublayers?.forEach { $0.removeFromSuperlayer() }

        let b = bounds, o = bounds.insetBy(dx: -400, dy: -400)
        let path = CGMutablePath()
        // 外框與內框方向相反，non-zero 規則下中間是空的
        path.addLines(between: [CGPoint(x: o.minX, y: o.minY), CGPoint(x: o.maxX, y: o.minY),
                                CGPoint(x: o.maxX, y: o.maxY), CGPoint(x: o.minX, y: o.maxY)])
        path.closeSubpath()
        path.addLines(between: [CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.minX, y: b.maxY),
                                CGPoint(x: b.maxX, y: b.maxY), CGPoint(x: b.maxX, y: b.minY)])
        path.closeSubpath()

        let cg = color.cgColor
        for (radius, opacity) in [(110.0, 0.85), (40.0, 0.9), (10.0, 1.0)] as [(CGFloat, Float)] {
            let l = CAShapeLayer()
            l.frame = b
            l.path = path
            l.fillColor = cg
            l.shadowPath = path
            l.shadowColor = cg
            l.shadowOffset = .zero
            l.shadowRadius = radius
            l.shadowOpacity = opacity
            root.addSublayer(l)
        }

        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.35
        pulse.duration = 1.4
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        root.add(pulse, forKey: "pulse")
    }
}

/// 訊息卡：點按鈕以外的地方就關閉；滑鼠移上去時按鈕變清楚
final class CardView: NSVisualEffectView {
    var onClick: () -> Void = {}
    weak var buttonRow: NSView?
    var idleAlpha: CGFloat = 1

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let v = super.hitTest(point) else { return nil }
        return v is NSButton ? v : self
    }

    override func mouseDown(with event: NSEvent) { onClick() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { fadeButtons(to: 1) }
    override func mouseExited(with event: NSEvent) { fadeButtons(to: idleAlpha) }

    private func fadeButtons(to alpha: CGFloat) {
        guard let row = buttonRow else { return }
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; row.animator().alphaValue = alpha }
    }
}

final class BorderView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class FirstClickButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 不搶 key window，打字不會被打斷
final class NonKeyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - main

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case nil, "help", "-h", "--help":
    print(helpText)
case "list", "ls":
    cmdList()
case "cancel", "rm":
    cmdCancel(Array(args.dropFirst()))
case "dismiss":
    cmdDismiss(Array(args.dropFirst()))
case "__run":
    guard args.count > 1, let id = Int(args[1]), var alarm = Store.load(id) else { exit(1) }
    alarm.pid = getpid()
    runAlarm(alarm)
default:
    cmdNew(args)
}
