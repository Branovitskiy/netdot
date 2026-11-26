import AppKit
import Foundation

enum NetState: String {
    case alive
    case dead
    case vpnOff
    case blocked
    case offline
}

// What the person sees. Colour answers one question: is the real IP visible?
// green/orange = hidden, red = visible, grey = no network at all.
enum Look: CaseIterable {
    case protected, fixing, waiting, open, offline
}

final class NetDot: NSObject, NSApplicationDelegate {
    private var look: Look = .offline
    private var shieldMark = "on"
    private var popover: NSPopover?
    private let statusItem = NSStatusBar.system.statusItem(withLength: 22)
    private let home = FileManager.default.homeDirectoryForCurrentUser.path
    private var state: NetState = .offline
    private var busy = false
    private var detail = ""
    private var lastSocketText = ""
    private var ticks = 0
    private var refreshing = false

    private var stateFile: String {
        "\(home)/Library/Application Support/amnezia-manual-ks/internet-state"
    }
    private var internetOn: String { "\(home)/bin/internet-on" }
    private var internetOff: String { "\(home)/bin/internet-off" }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.target = self
        statusItem.button?.action = #selector(handleClick)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.length = NSStatusItem.variableLength
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
        apply(.offline, detail: "проверяю…")
        Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.refresh()
            self.ticks += 1
            if self.ticks % 20 == 0 {
                self.refreshShieldRules()
            }
        }
        note("запуск NetDot")
        refresh()
        restoreSavedMode()
    }

    private func restoreSavedMode() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let mark = (try? String(contentsOfFile: self.stateFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "on"
            let command: String
            if mark == "shield" {
                command = "shield"
            } else if mark == "off" {
                command = "off"
            } else {
                return
            }
            for _ in 0..<20 {
                if self.helperIsCurrent() && self.socketSend(command) == 0 {
                    DispatchQueue.main.async { self.refresh() }
                    return
                }
                Thread.sleep(forTimeInterval: 1)
            }
        }
    }

    // Every two minutes: if the shield is on, let the helper rebuild it when
    // a VPN server moved to a new address or the Wi-Fi changed. Never asks
    // for a password: an outdated helper is simply skipped.
    private func refreshShieldRules() {
        guard !busy, !refreshing else { return }
        let mark = (try? String(contentsOfFile: stateFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "on"
        guard mark == "shield" else { return }
        refreshing = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            if self.helperIsCurrent() {
                let code = self.socketSend("refresh")
                if code != 0 { self.note("плановое обновление правил защиты не прошло, код \(code)") }
            }
            DispatchQueue.main.async { self.refreshing = false }
        }
    }

    @objc private func handleClick() {
        showMenu()
    }

    // Journal (netdot.log next to config.env): one line per change, one per
    // minute while all is well, every check while something is wrong. It
    // exists to answer "why was there no internet" after the fact: on 27.11
    // Happ sat "connected" for 12 minutes with nothing going through, and
    // nothing had recorded where the traffic went or when the rules changed.
    private var journalKey = ""
    private var journalAt = Date.distantPast
    private var probeFacts = ""
    private let journalQueue = DispatchQueue(label: "netdot.journal")
    private var journalFile: String {
        "\(home)/Library/Application Support/amnezia-manual-ks/netdot.log"
    }

    private func note(_ text: String) {
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "\(format.string(from: Date())) \(text)\n"
        let path = journalFile
        journalQueue.async {
            let manager = FileManager.default
            if let size = (try? manager.attributesOfItem(atPath: path))?[.size] as? Int, size > 2_000_000 {
                try? manager.removeItem(atPath: path + ".1")
                try? manager.moveItem(atPath: path, toPath: path + ".1")
            }
            if !manager.fileExists(atPath: path) {
                manager.createFile(atPath: path, contents: nil)
            }
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8) ?? Data())
                handle.closeFile()
            }
        }
    }

    private func firstLine(_ text: String) -> String {
        text.split(separator: "\n").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? "-"
    }

    private func journal(_ next: NetState, _ text: String) {
        let mark = (try? String(contentsOfFile: stateFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "on"
        let route = run("/sbin/route", ["-n", "get", "1.1.1.1"])
            .split(separator: "\n").first { $0.contains("interface:") }?
            .split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "-"
        let address = firstLine(run("/usr/sbin/ipconfig", ["getifaddr", "en0"]))
        let key = "\(next.rawValue)|\(mark)|\(route)|\(address)"
        let wrong = next != .alive
        guard key != journalKey || wrong || Date().timeIntervalSince(journalAt) > 60 else { return }
        let changed = key != journalKey
        journalKey = key
        journalAt = Date()
        var line = "состояние=\(next.rawValue) защита=\(mark) маршрут=\(route) en0=\(address) \(probeFacts)"
        if changed || wrong {
            let router = firstLine(run("/usr/sbin/ipconfig", ["getoption", "en0", "router"]))
            let tunnels = run("/sbin/ifconfig", ["-l"]).split(whereSeparator: { $0 == " " || $0 == "\n" }).filter { $0.hasPrefix("utun") }
                .joined(separator: ",")
            let rules = "\(home)/Library/Application Support/amnezia-manual-ks/manual-ks.block.conf"
            let age = ((try? FileManager.default.attributesOfItem(atPath: rules))?[.modificationDate] as? Date)
                .map { String(Int(Date().timeIntervalSince($0))) } ?? "-"
            line += " шлюз=\(router) happ=\(firstLine(run("/usr/sbin/scutil", ["--nc", "status", "Happ"])))"
            line += " forti=\(firstLine(run("/usr/sbin/scutil", ["--nc", "status", "VPN"])))"
            line += " redshield=\(redShieldIsUp() ? "да" : "нет") туннели=\(tunnels) правилам_сек=\(age)"
            if wrong, address != "-", !address.isEmpty {
                // Can the VPN server be reached past the tunnel at all?
                let config = (try? String(contentsOfFile:
                    "\(home)/Library/Application Support/amnezia-manual-ks/config.env", encoding: .utf8)) ?? ""
                let server = config.split(separator: "\n").first { $0.hasPrefix("AMNEZIA_SERVER_IP=") }?
                    .split(separator: "=").last.map(String.init) ?? ""
                if isPublicIPv4(server) {
                    let code = runCode("/usr/bin/curl", ["-s", "-o", "/dev/null", "-k", "--interface", "en0",
                                                         "--connect-timeout", "2", "--max-time", "3",
                                                         "https://\(server)/"])
                    // 7 and 28 mean no connection; anything else got through to the server.
                    line += " сервер_напрямую=\(code == 7 || code == 28 ? "нет" : "да")(\(code))"
                }
            }
            line += " | \(text)"
        }
        note(line)
    }

    private func refresh() {
        guard !busy else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let (next, text) = self.probe()
            self.journal(next, text)
            let happStuck = next == .dead && self.tunnelRoute() && self.happIsUp()
            DispatchQueue.main.async {
                guard !self.busy else { return }
                self.apply(next, detail: text)
                self.healHappIfStuck(happStuck)
            }
        }
    }

    // Happ sometimes keeps a dead connection after Wi-Fi changes or sleep:
    // connected on paper, nothing loads. After ~25 seconds of that, do what
    // helped by hand: stop and start it. At most once in 3 minutes.
    private var stuckChecks = 0
    private var lastHeal = Date.distantPast

    private func healHappIfStuck(_ stuck: Bool) {
        stuckChecks = stuck ? stuckChecks + 1 : 0
        guard stuckChecks >= 4, Date().timeIntervalSince(lastHeal) > 180 else { return }
        stuckChecks = 0
        lastHeal = Date()
        note("действие: автолечение — Happ подключён, но ничего не грузится, перезапускаю")
        reconnectHapp()
    }

    private func probe() -> (NetState, String) {
        let mark = (try? String(contentsOfFile: stateFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "on"
        let shielded = mark == "shield"
        if mark == "off" {
            return (.blocked, "Интернет выключен командой. Включить обратно — в меню точки.")
        }
        let route = run("/sbin/route", ["-n", "get", "1.1.1.1"])
        let iface = route
            .split(separator: "\n")
            .first { $0.contains("interface:") }?
            .split(separator: ":")
            .last?
            .trimmingCharacters(in: .whitespaces) ?? ""
        let address = run("/usr/bin/nc", ["-z", "-G", "3", "1.1.1.1", "443"])
        // A real page, not just a TCP connect: Happ's tunnel answers every
        // connect itself, so a dead server used to look alive.
        let page = run("/usr/bin/curl", ["-s", "-o", "/dev/null", "-w", "%{http_code}",
                                         "--max-time", "5", "https://www.gstatic.com/generate_204"])
        let addressOK = address.contains("succeeded")
        let nameOK = page.trimmingCharacters(in: .whitespacesAndNewlines) == "204"
        let ok = addressOK && nameOK
        probeFacts = "tcp=\(addressOK ? "да" : "нет") страница=\(page.trimmingCharacters(in: .whitespacesAndNewlines))"
        if iface.hasPrefix("utun") {
            if ok {
                return (.alive, shielded
                    ? "Туннель живой, прямой IP для зарубежных сайтов закрыт."
                    : "Туннель живой. Защита от мигания IP ещё не включена.")
            }
            if addressOK && !nameOK {
                return (.dead, "Туннель есть, но имена сайтов через него не открываются. Так Happ ломал Claude.")
            }
            return (.dead, shielded
                ? "Туннель заснул. Прямой IP закрыт, зарубежные сайты не откроются, пока VPN не поднимется."
                : "Туннель заснул. Переподключение в меню сначала закроет прямой IP.")
        }
        if shielded && !ok {
            return (.dead, "VPN выключен, прямой IP закрыт. В меню можно переподключить VPN.")
        }
        if ok {
            return (.vpnOff, "VPN выключен, интернет идёт напрямую с обычным IP.")
        }
        return (.offline, "Сети нет. Это не блокировка скриптом.")
    }

    private func apply(_ next: NetState, detail: String) {
        state = next
        self.detail = detail
        shieldMark = (try? String(contentsOfFile: stateFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "on"
        look = currentLook(next)
        statusItem.button?.image = icon(look, point: 15)
        let word = lookWord(look)
        statusItem.button?.title = word.isEmpty ? "" : " " + word
        statusItem.button?.toolTip = nil
        if popover?.isShown == true {
            popover?.contentViewController = hoverController()
        }
    }

    private var barrierClosed: Bool { shieldMark == "shield" || shieldMark == "off" }

    private func currentLook(_ s: NetState) -> Look {
        if busy { return .fixing }
        switch s {
        case .offline: return .offline
        case .blocked: return .waiting
        case .alive: return barrierClosed ? .protected : .open
        case .dead: return barrierClosed ? .waiting : .open
        case .vpnOff: return .open
        }
    }

    private func lookSymbol(_ look: Look) -> (String, NSColor) {
        switch look {
        case .protected: return ("checkmark.shield.fill", .systemGreen)
        case .fixing: return ("arrow.triangle.2.circlepath", .systemOrange)
        case .waiting: return ("pause.circle.fill", .systemOrange)
        case .open: return ("lock.open.fill", .systemRed)
        case .offline: return ("wifi.slash", .systemGray)
        }
    }

    private func lookWord(_ look: Look) -> String {
        switch look {
        case .protected, .offline: return ""
        case .fixing: return "чиню"
        case .waiting: return "жду тебя"
        case .open: return "открыто"
        }
    }

    private func lookTitle(_ look: Look) -> String {
        switch look {
        case .protected: return "Защищён"
        case .fixing: return "Чиню VPN"
        case .waiting: return "Интернет закрыт"
        case .open: return "Открыто: виден твой адрес"
        case .offline: return "Сети нет"
        }
    }

    private func lookHint(_ look: Look) -> String {
        switch look {
        case .protected: return "VPN работает, мимо него выхода нет."
        case .fixing: return "VPN упал, точка его перезапускает. Адрес скрыт."
        case .waiting: return "VPN не работает. Включи его руками. Адрес скрыт."
        case .open: return "Защита снята. Сайты видят настоящий адрес или увидят при обрыве VPN."
        case .offline: return "Нет Wi-Fi или кабеля. К защите отношения не имеет."
        }
    }

    private func icon(_ look: Look, point: CGFloat) -> NSImage {
        let (name, color) = lookSymbol(look)
        // Two-layer symbols: white mark inside a coloured shape.
        let layered = look == .protected || look == .waiting
        let config = NSImage.SymbolConfiguration(pointSize: point, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: layered ? [.white, color] : [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: lookTitle(look))?
            .withSymbolConfiguration(config) else { return dot(state) }
        image.isTemplate = false
        return image
    }

    // Hover card: what is true right now, then a legend of all five icons.
    @objc(mouseEntered:) func mouseEntered(with event: NSEvent) {
        guard popover == nil, let button = statusItem.button else { return }
        let card = NSPopover()
        card.behavior = .applicationDefined
        card.animates = false
        card.contentViewController = hoverController()
        card.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover = card
    }

    @objc(mouseExited:) func mouseExited(with event: NSEvent) { closeHover() }

    // `NetDot --snapshot <dir>`: draw every icon and hover card into PNG files
    // without touching the VPN. Used for the pictures in the README.
    func snapshot(to dir: String) {
        let cases: [(String, Look, NetState, String, String)] = [
            ("protected", .protected, .alive, "shield", "Туннель живой, прямой IP для зарубежных сайтов закрыт."),
            ("fixing", .fixing, .dead, "shield", "Прямой IP закрыт. Переподключаю Happ…"),
            ("waiting", .waiting, .dead, "shield", "VPN выключен, прямой IP закрыт. В меню можно переподключить VPN."),
            ("open", .open, .vpnOff, "on", "VPN выключен, интернет идёт напрямую с обычным IP."),
            ("offline", .offline, .offline, "on", "Сети нет. Это не блокировка скриптом."),
        ]
        for (name, nextLook, nextState, mark, text) in cases {
            look = nextLook
            state = nextState
            shieldMark = mark
            busy = nextLook == .fixing
            detail = text
            let card = hoverController().view
            let box = NSBox()
            box.boxType = .custom
            box.borderWidth = 0
            box.cornerRadius = 12
            box.fillColor = .windowBackgroundColor
            box.contentViewMargins = .zero
            box.contentView = card
            box.frame = NSRect(origin: .zero, size: card.fittingSize)
            write(box, to: "\(dir)/card-\(name).png")

            let word = lookWord(nextLook)
            let picture = NSImageView(image: icon(nextLook, point: 15))
            let line = NSStackView(views: word.isEmpty ? [picture] : [picture, label(word, size: 13)])
            line.spacing = 4
            line.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
            line.frame = NSRect(origin: .zero, size: line.fittingSize)
            write(line, to: "\(dir)/icon-\(name).png")
        }
    }

    private func write(_ view: NSView, to path: String) {
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = .clear
        window.contentView?.addSubview(view)
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    private func closeHover() {
        popover?.close()
        popover = nil
    }

    private func label(_ text: String, size: CGFloat = 13, bold: Bool = false,
                       color: NSColor = .labelColor, width: CGFloat = 0) -> NSTextField {
        let field = width > 0 ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
        field.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
        field.textColor = color
        if width > 0 { field.preferredMaxLayoutWidth = width }
        return field
    }

    private func row(_ image: NSImage, _ views: [NSView]) -> NSStackView {
        let picture = NSImageView(image: image)
        picture.setContentHuggingPriority(.required, for: .horizontal)
        picture.widthAnchor.constraint(equalToConstant: 26).isActive = true
        let text = NSStackView(views: views)
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let line = NSStackView(views: [picture, text])
        line.orientation = .horizontal
        line.alignment = .top
        line.spacing = 8
        return line
    }

    private func fact(_ name: String, _ value: String, good: Bool?) -> NSStackView {
        let color: NSColor = good == nil ? .secondaryLabelColor : (good! ? .systemGreen : .systemRed)
        let line = NSStackView(views: [label(name, color: .secondaryLabelColor), label(value, bold: true, color: color)])
        line.orientation = .horizontal
        line.spacing = 6
        return line
    }

    private func hoverController() -> NSViewController {
        let width: CGFloat = 300
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)

        stack.addArrangedSubview(row(icon(look, point: 22), [label(lookTitle(look), size: 15, bold: true)]))
        let vpnUp = state == .alive
        stack.addArrangedSubview(fact("Интернет мимо VPN:", barrierClosed ? "перекрыт" : "НЕ перекрыт", good: barrierClosed))
        stack.addArrangedSubview(fact("VPN:", busy ? "перезапускается" : (vpnUp ? "работает" : "не работает"),
                                      good: busy ? nil : vpnUp))
        let hidden = look != .open
        let addressText = hidden ? "скрыт" : (vpnUp ? "мигнёт при обрыве VPN" : "виден сайтам")
        stack.addArrangedSubview(fact("Настоящий адрес:", look == .offline ? "никуда не уходит" : addressText,
                                      good: hidden))
        if !detail.isEmpty {
            stack.addArrangedSubview(label(detail, size: 12, color: .secondaryLabelColor, width: width))
        }

        let line = NSBox()
        line.boxType = .separator
        stack.addArrangedSubview(line)
        line.widthAnchor.constraint(equalToConstant: width).isActive = true
        stack.addArrangedSubview(label("Что значат значки", size: 11, color: .tertiaryLabelColor))
        for other in Look.allCases {
            let now = other == look
            let title = lookTitle(other) + (now ? "  ← сейчас" : "")
            stack.addArrangedSubview(row(icon(other, point: 15), [
                label(title, size: 12, bold: now),
                label(lookHint(other), size: 11, color: .secondaryLabelColor, width: width - 34),
            ]))
        }
        stack.addArrangedSubview(label("Зелёный и оранжевый: адрес скрыт. Красный: адрес виден.",
                                       size: 11, color: .tertiaryLabelColor, width: width))

        let controller = NSViewController()
        controller.view = stack
        return controller
    }

    private func showMenu() {
        closeHover()
        let menu = NSMenu()
        let title = NSMenuItem(title: menuTitle(), action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        menu.addItem(item("Переподключить Red Shield", #selector(reconnectAction)))
        menu.addItem(item("Переподключить Happ", #selector(reconnectHappAction)))
        menu.addItem(item("Переподключить Amnezia", #selector(reconnectAmneziaAction)))
        let hint = NSMenuItem(title: "Сначала закроет прямой IP, он не мигнёт", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())
        menu.addItem(item("Включить интернет", #selector(onAction)))
        let onHint = NSMenuItem(title: "Снимет защиту: снова будет обычный IP", action: nil, keyEquivalent: "")
        onHint.isEnabled = false
        menu.addItem(onHint)
        menu.addItem(item("Выключить интернет", #selector(offAction)))
        menu.addItem(.separator())
        menu.addItem(item("Выйти из точки", #selector(quitAction)))
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func menuTitle() -> String {
        let address = look == .open ? "адрес виден" : (look == .offline ? "сети нет" : "адрес скрыт")
        return "\(lookTitle(look)) — \(address)"
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func reconnectAction() { reconnectRedShield() }
    @objc private func reconnectHappAction() { reconnectHapp() }
    @objc private func reconnectAmneziaAction() { reconnectAmnezia() }
    @objc private func onAction() { runScript(internetOn, title: "Включаю интернет…") }
    @objc private func offAction() { runScript(internetOff, title: "Выключаю интернет…") }
    @objc private func quitAction() { NSApp.terminate(nil) }

    private func reconnectRedShield() {
        guardedReconnect(label: "Red Shield") {
            let wasUp = self.redShieldIsUp()
            self.clickRedShield()
            if wasUp {
                for _ in 0..<10 {
                    Thread.sleep(forTimeInterval: 0.5)
                    if !self.redShieldIsUp() { break }
                }
                Thread.sleep(forTimeInterval: 0.4)
                self.clickRedShield()
            }
            for _ in 0..<20 {
                Thread.sleep(forTimeInterval: 0.5)
                if self.redShieldIsUp() { break }
            }
        }
    }

    private func reconnectHapp() {
        guardedReconnect(label: "Happ") {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Happ.app"))
            let wasUp = self.happIsUp()
            if wasUp {
                _ = self.run("/usr/sbin/scutil", ["--nc", "stop", "Happ"])
                for _ in 0..<12 {
                    Thread.sleep(forTimeInterval: 0.4)
                    if !self.happIsUp() { break }
                }
            }
            // One start is not enough: right after a network change macOS
            // answers "No network available" and drops it (14.11, 15:38 —
            // Happ then stayed off for an hour). Keep trying for ~1.5 minutes.
            attempts: for _ in 0..<10 {
                _ = self.run("/usr/sbin/scutil", ["--nc", "start", "Happ"])
                for _ in 0..<12 {
                    Thread.sleep(forTimeInterval: 0.5)
                    if self.happIsUp() { break attempts }
                }
                Thread.sleep(forTimeInterval: 3)
            }
        }
    }

    private func reconnectAmnezia() {
        guardedReconnect(label: "Amnezia") {
            let wasUp = self.amneziaIsUp()
            self.clickAmnezia()
            if wasUp {
                for _ in 0..<12 {
                    Thread.sleep(forTimeInterval: 0.5)
                    if !self.amneziaIsUp() { break }
                }
                Thread.sleep(forTimeInterval: 0.4)
                self.clickAmnezia()
            }
            for _ in 0..<24 {
                Thread.sleep(forTimeInterval: 0.5)
                if self.amneziaIsUp() { break }
            }
        }
    }

    private func guardedReconnect(label: String, body: @escaping () -> Void) {
        guard !busy else { return }
        busy = true
        note("действие: переподключение \(label) — начало")
        apply(.dead, detail: "Запоминаю адрес сервера и закрываю прямой IP…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            self.rememberEndpoints()
            // If the shield was already on, its old rules still guard the
            // real IP: a failed refresh of them is no reason to leave the VPN broken.
            let mark = (try? String(contentsOfFile: self.stateFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "on"
            let shieldCode = self.privileged("shield")
            self.note("действие: переподключение \(label) — правила защиты обновлены, код \(shieldCode)")
            if shieldCode != 0 && mark != "shield" {
                DispatchQueue.main.async {
                    self.busy = false
                    self.apply(.dead, detail: "Защиту не включили, \(label) не трогал. Обычный IP не открывался.")
                }
                return
            }
            DispatchQueue.main.async {
                self.apply(.dead, detail: "Прямой IP закрыт. Переподключаю \(label)…")
            }
            body()
            // The VPN may have picked a server with a new address: allow it.
            _ = self.socketSend("refresh")
            self.note("действие: переподключение \(label) — конец")
            DispatchQueue.main.async {
                self.busy = false
                self.refresh()
            }
        }
    }

    private func rememberEndpoints() {
        var ips = Set(savedEndpoints())
        let routes = run("/usr/sbin/netstat", ["-rn", "-f", "inet"])
        for line in routes.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let dest = parts.first, dest.hasSuffix("/32") else { continue }
            let ip = String(dest.dropLast(3))
            if isPublicIPv4(ip) { ips.insert(ip) }
        }
        let redlink = run("/bin/cat", ["\(home)/Library/Application Support/redshieldvpn/Red Shield VPN/redlink.conf"])
        if let line = redlink.split(separator: "\n").first(where: { $0.hasPrefix("Endpoint") }) {
            let ip = line.split(separator: "=").last?
                .trimmingCharacters(in: .whitespaces)
                .split(separator: ":").first.map(String.init) ?? ""
            if isPublicIPv4(ip) { ips.insert(ip) }
        }
        let list = ips.sorted()
        try? (list.joined(separator: "\n") + "\n").write(toFile: endpointsFile, atomically: true, encoding: .utf8)
        updateExtraAllowList(list)
    }

    private var endpointsFile: String {
        "\(home)/Library/Application Support/amnezia-manual-ks/endpoints.txt"
    }

    private func savedEndpoints() -> [String] {
        let text = (try? String(contentsOfFile: endpointsFile, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map { String($0) }.filter(isPublicIPv4)
    }

    private func updateExtraAllowList(_ ips: [String]) {
        let path = "\(home)/Library/Application Support/amnezia-manual-ks/config.env"
        guard var text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let body = ips.map { "  \"\($0)/32\"" }.joined(separator: "\n")
        let block = "EXTRA_VPN_ALLOW_CIDRS=(\n\(body)\n)"
        if let range = text.range(of: #"EXTRA_VPN_ALLOW_CIDRS=\([\s\S]*?\)"#, options: .regularExpression) {
            text.replaceSubrange(range, with: block)
        } else {
            text += "\n\(block)\n"
        }
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func isPublicIPv4(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        let a = parts[0], b = parts[1]
        if a == 0 || a == 10 || a == 127 { return false }
        if a == 169 && b == 254 { return false }
        if a == 172 && (16...31).contains(b) { return false }
        if a == 192 && b == 168 { return false }
        if a == 100 && (64...127).contains(b) { return false }
        if a >= 224 { return false }
        return true
    }

    private func clickRedShield() {
        let script = """
        tell application "Red Shield VPN" to activate
        delay 0.4
        tell application "System Events"
          tell process "Red Shield VPN"
            set frontmost to true
            click radio button 1 of window 1
          end tell
        end tell
        """
        _ = run("/usr/bin/osascript", ["-e", script])
    }

    private func clickAmnezia() {
        let script = """
        tell application "AmneziaVPN" to activate
        delay 0.6
        tell application "System Events"
          tell process "AmneziaVPN"
            set frontmost to true
            click button 1 of group 1 of window 1
          end tell
        end tell
        """
        _ = run("/usr/bin/osascript", ["-e", script])
    }

    private func redShieldIsUp() -> Bool {
        !run("/usr/bin/pgrep", ["-f", "darwin.bash up"]).isEmpty
    }

    private func amneziaIsUp() -> Bool {
        !run("/usr/bin/pgrep", ["-f", "tun2socks"]).isEmpty
    }

    private func happIsUp() -> Bool {
        let text = run("/usr/sbin/scutil", ["--nc", "status", "Happ"])
        let first = text.split(separator: "\n").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        return first == "Connected"
    }

    private func runScript(_ path: String, title: String) {
        guard !busy else { return }
        busy = true
        apply(state, detail: title)
        let command = path.hasSuffix("internet-off") ? "off" : "on"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let code = self.privileged(command)
            self.note("действие: команда «\(command)» из меню, код \(code)")
            DispatchQueue.main.async {
                self.busy = false
                self.refresh()
            }
        }
    }

    private func tunnelRoute() -> Bool {
        let route = run("/sbin/route", ["-n", "get", "1.1.1.1"])
        return route.contains("utun")
    }

    @discardableResult
    private func run(_ launch: String, _ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func privileged(_ command: String) -> Int32 {
        if command != "shield" && command != "on" && command != "off" {
            return 1
        }
        if helperIsCurrent() {
            // The helper is fine, the command just failed this time: retry,
            // but never pop up a password prompt for that.
            if socketSend(command) == 0 {
                return 0
            }
            Thread.sleep(forTimeInterval: 2)
            return socketSend(command)
        }
        let install = "do shell script quoted form of \"\(home)/bin/install-netdot-helper\" with administrator privileges"
        if runCode("/usr/bin/osascript", ["-e", install]) != 0 {
            return 1
        }
        _ = socketSend("version")
        return socketSend(command)
    }

    private func helperIsCurrent() -> Bool {
        socketSend("version") == 0 && lastSocketText.contains("5")
    }

    private func socketSend(_ command: String) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-lc", "printf '%s\\n' '\(command)' | /usr/bin/nc -U -w 30 /var/run/netdot.sock"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return 1
        }
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        lastSocketText = text
        if process.terminationStatus == 0 && text.contains("ok") {
            return 0
        }
        return 1
    }

    private func runCode(_ launch: String, _ args: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch)
        process.arguments = args
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return 1
        }
        return process.terminationStatus
    }

    private func dot(_ state: NetState) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        let rect = NSRect(x: 3, y: 3, width: 12, height: 12)
        let color: NSColor
        switch state {
        case .alive: color = .systemGreen
        case .dead: color = .systemRed
        case .vpnOff: color = .systemGray
        case .blocked: color = .systemOrange
        case .offline: color = .clear
        }
        if state == .offline {
            NSColor.systemGray.setStroke()
            let path = NSBezierPath(ovalIn: rect)
            path.lineWidth = 1.6
            path.stroke()
        } else {
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
        }
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.4, dy: 0.4))
        ring.lineWidth = 0.8
        ring.stroke()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}

@main
struct Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = NetDot()
        let args = CommandLine.arguments
        if let flag = args.firstIndex(of: "--snapshot"), flag + 1 < args.count {
            delegate.snapshot(to: args[flag + 1])
            return
        }
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
