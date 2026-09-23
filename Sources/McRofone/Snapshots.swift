import AppKit
import SwiftUI
import McRofoneCore

/// `McRofone --render-snapshots <dir>` renders the main screens with sample data,
/// in light and dark mode, so the UI can be reviewed without clicking through it.
/// `McRofone --render-icon <dir>` writes AppIcon.iconset and AppIcon.icns.
/// Never touches real preferences, Keychain items or recordings.
@MainActor
enum Snapshots {
    static func render(to dir: URL) -> Int32 {
        setvbuf(stdout, nil, _IONBF, 0)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Isolated settings: only the in-memory registration domain is used.
        let defaults = UserDefaults(suiteName: "com.gabrielepartiti.mcrofone.snapshots")!
        AppSettings.defaults = defaults
        AppSettings.registerDefaults()
        AppSettings.displayBaseFolderOverride = "~/Documents/mc.Rofone"
        let library = dir.appendingPathComponent("fixtures/library", isDirectory: true)
        let empty = dir.appendingPathComponent("fixtures/empty", isDirectory: true)
        try? FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defaults.register(defaults: [
            Keys.baseFolder: library.path,
            Keys.onboardingDone: true,
            Keys.systemAudioVerified: true,
            Keys.webhookEnabled: true,
            Keys.webhookURL: "https://hooks.example.com/mcrofone",
            Keys.webhookHeaderKeys: ["Authorization"],
            Keys.lastTags: ["Roadmap", "Design"],
        ])
        Keychain.mock = [
            ProviderKind.openAI.rawValue: "sk-demo-1234567890abcdef",
            "webhook.headers": #"{"Authorization":"Bearer demo-token"}"#,
        ]
        let folders = Fixtures.make(in: library)
        folders[0].updateMeta {
            $0.tags = ["Roadmap", "Design"]
            $0.bookmarks = [Bookmark(time: 41, label: "Onboarding test results"), Bookmark(time: 222, label: "Billing moves to November"),
                            Bookmark(time: 1480, label: "")]
            $0.modelID = "whisper-1"
            $0.transcribedSeconds = 2100
            $0.estimatedCostUSD = 0.21
            $0.summaryModel = "gpt-5-mini"
            $0.calendarEvent = Fixtures.event(title: "Weekly sync with design team", start: $0.date)
        }
        try? Fixtures.designSummary.write(to: folders[0].summaryURL, atomically: true, encoding: .utf8)
        folders[1].updateMeta { $0.tags = ["Sales", "Acme"] }
        folders[2].updateMeta { $0.tags = ["Hiring"] }
        folders[4].updateMeta { $0.tags = ["Engineering"] }
        folders[5].updateMeta { $0.tags = ["Nova", "Roadmap"] }
        let state = AppState.shared

        func both(_ name: String, size: CGSize?, chrome: Bool = true, _ view: @escaping () -> AnyView) {
            for dark in [false, true] {
                snap(view(), name: "\(name)-\(dark ? "dark" : "light")", size: size, dark: dark, chrome: chrome, dir: dir)
            }
        }

        // Settings panes.
        for pane in SettingsPane.allCases {
            both("settings-\(pane.rawValue)", size: nil) {
                AnyView(SettingsView(pane: pane).environmentObject(state))
            }
        }
        defaults.register(defaults: [Keys.provider: ProviderKind.openAI.rawValue])
        both("settings-transcription-openai", size: nil) {
            AnyView(SettingsView(pane: .transcription).environmentObject(state))
        }
        defaults.register(defaults: [Keys.provider: ProviderKind.whisperCpp.rawValue, Keys.webhookBodyMode: "template"])
        snap(AnyView(SettingsView(pane: .webhook).environmentObject(state)), name: "settings-webhook-template-light",
             size: nil, dark: false, chrome: true, dir: dir)
        defaults.register(defaults: [Keys.webhookBodyMode: "default"])

        // Menu bar panel.
        let panel: () -> AnyView = {
            AnyView(MenuPanel(closePanel: {}).environmentObject(state).defaultAppStorage(defaults)
                .background(Color(nsColor: .windowBackgroundColor)))
        }
        state.setPreview(phase: .idle)
        both("panel-idle", size: nil, chrome: false, panel)
        state.setPreview(phase: .recording(title: "Weekly sync with design team", start: Date()), mic: 0.62, system: 0.41)
        both("panel-recording", size: nil, chrome: false, panel)
        state.setPreview(phase: .recording(title: "Weekly sync with design team", start: Date()), mic: 0, system: 0,
                         paused: true, bookmarks: [Bookmark(time: 312, label: "Pricing question"), Bookmark(time: 540)])
        both("panel-paused", size: nil, chrome: false, panel)
        state.setPreview(phase: .transcribing(title: "Pricing call with Acme"),
                         busy: [folders[1].key: "Transcribing call audio (2 of 2)…"])
        both("panel-transcribing", size: nil, chrome: false, panel)
        state.setPreview(phase: .error("Transcription failed for \"1:1 with Marco\": HTTP 401 from api.openai.com: Incorrect API key provided."),
                         error: "HTTP 401")
        snap(panel(), name: "panel-error-light", size: nil, dark: false, chrome: false, dir: dir)

        // Title prompt.
        state.setPreview(phase: .idle)
        for dark in [false, true] {
            let event = Fixtures.event(title: "Q4 roadmap review", start: Date())
            snap(AnyView(TitlePromptView(onDone: {}, initialTitle: event.title, event: event)
                    .environmentObject(state).defaultAppStorage(defaults)),
                 name: "title-prompt-\(dark ? "dark" : "light")", size: nil, dark: dark, chrome: true, dir: dir, chromeless: true)
        }

        // Library.
        state.setPreview(phase: .idle, busy: [folders[1].key: "Transcribing call audio (2 of 2)…"])
        state.librarySelection = folders[0].key
        both("library", size: CGSize(width: 1100, height: 720)) {
            AnyView(LibraryView().environmentObject(state).defaultAppStorage(defaults))
        }
        LibraryView.preferSummaryTab = true
        both("library-summary", size: CGSize(width: 1100, height: 720)) {
            AnyView(LibraryView().environmentObject(state).defaultAppStorage(defaults))
        }
        LibraryView.preferSummaryTab = false
        state.librarySelection = folders[3].key
        snap(AnyView(LibraryView().environmentObject(state).defaultAppStorage(defaults)), name: "library-error-light",
             size: CGSize(width: 1100, height: 720), dark: false, chrome: true, dir: dir)
        state.librarySelection = folders[1].key
        snap(AnyView(LibraryView().environmentObject(state).defaultAppStorage(defaults)), name: "library-transcribing-dark",
             size: CGSize(width: 1100, height: 720), dark: true, chrome: true, dir: dir)
        defaults.register(defaults: [Keys.baseFolder: empty.path])
        state.librarySelection = nil
        both("library-empty", size: CGSize(width: 1000, height: 620)) {
            AnyView(LibraryView().environmentObject(state).defaultAppStorage(defaults))
        }
        defaults.register(defaults: [Keys.baseFolder: library.path])

        // Onboarding.
        for step in 0..<4 {
            snap(AnyView(OnboardingView(step: step).environmentObject(state)), name: "onboarding-\(step + 1)-light",
                 size: nil, dark: false, chrome: true, dir: dir, chromeless: false)
        }
        snap(AnyView(OnboardingView(step: 0).environmentObject(state)), name: "onboarding-1-dark",
             size: nil, dark: true, chrome: true, dir: dir, chromeless: false)

        // Icon and glyphs.
        writePNG(renderIcon(size: 1024), to: dir.appendingPathComponent("icon-1024.png"))
        writePNG(renderIcon(size: 32), to: dir.appendingPathComponent("icon-32.png"))
        renderGlyphs(to: dir.appendingPathComponent("menubar-glyphs.png"))

        print("Snapshots written to \(dir.path)")
        return 0
    }

    // MARK: Rendering

    private static func snap(_ view: AnyView, name: String, size: CGSize?, dark: Bool, chrome: Bool, dir: URL,
                             chromeless: Bool? = nil) {
        let hosting = NSHostingController(rootView: view)
        hosting.sceneBridgingOptions = chrome ? [.toolbars, .title] : []
        let style: NSWindow.StyleMask = chrome ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView] : [.borderless]
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size ?? CGSize(width: 400, height: 300)),
                              styleMask: style, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentViewController = hosting
        if chrome { window.toolbarStyle = .unified }
        if let hide = chromeless { WindowManager.makeChromeless(window, hideButtons: hide) }
        if let size { window.setContentSize(size) } else { window.setContentSize(hosting.view.fittingSize) }
        window.alphaValue = CGFloat(Double(ProcessInfo.processInfo.environment["SNAP_ALPHA"] ?? "1") ?? 1)
        window.setFrameOrigin(NSPoint(x: 40, y: 40))
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        if size == nil { window.setContentSize(hosting.view.fittingSize) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))

        if let image = windowImage(window) {
            let rep = NSBitmapImageRep(cgImage: image)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: dir.appendingPathComponent("\(name).png"))
                print("  \(name).png (window server)")
            }
            window.orderOut(nil)
            window.close()
            return
        }
        let target = chrome ? (window.contentView?.superview ?? hosting.view) : hosting.view
        if let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds) {
            target.cacheDisplay(in: target.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: dir.appendingPathComponent("\(name).png"))
                print("  \(name).png")
            }
        }
        window.orderOut(nil)
        window.close()
    }

    /// Captures one of our own windows through the window server, so AppKit-backed
    /// SwiftUI controls render exactly as on screen. Looked up at runtime because the
    /// symbol is no longer exposed in the SDK; capturing your own windows needs no permission.
    private static func windowImage(_ window: NSWindow) -> CGImage? {
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
              let sym = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        let fn = unsafeBitCast(sym, to: Fn.self)
        // kCGWindowListOptionIncludingWindow = 8, boundsIgnoreFraming = 1, bestResolution = 8
        return fn(.null, 8, UInt32(window.windowNumber), 1 | 8)?.takeRetainedValue()
    }

    static func renderIcon(size: CGFloat) -> CGImage? {
        let renderer = ImageRenderer(content: AppIconView().frame(width: size, height: size))
        renderer.scale = 1
        return renderer.cgImage
    }

    private static func writePNG(_ image: CGImage?, to url: URL) {
        guard let image else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func renderGlyphs(to url: URL) {
        let scale: CGFloat = 4
        let glyphs: [NSImage] = [
            MenuBarGlyph.idle(), MenuBarGlyph.idle(frame: 0), MenuBarGlyph.idle(frame: 2),
            MenuBarGlyph.recording(elapsed: "12:34"), MenuBarGlyph.error(),
            MenuBarGlyph.muted(), MenuBarGlyph.recording(elapsed: "12:34", muted: true),
            MenuBarGlyph.paused(elapsed: "12:34", muted: true),
        ]
        let width = glyphs.reduce(CGFloat(16)) { $0 + $1.size.width + 16 } * scale
        let height = 2 * 30 * scale
        let image = NSImage(size: NSSize(width: width / scale, height: height / scale), flipped: false) { _ in
            for (row, dark) in [(0, true), (1, false)] {
                let y = CGFloat(row) * 30
                (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
                NSRect(x: 0, y: y, width: width / scale, height: 30).fill()
                var x: CGFloat = 16
                for glyph in glyphs {
                    let rect = NSRect(x: x, y: y + (30 - glyph.size.height) / 2, width: glyph.size.width, height: glyph.size.height)
                    if glyph.isTemplate {
                        let tinted = NSImage(size: glyph.size, flipped: false) { r in
                            glyph.draw(in: r)
                            (dark ? NSColor.white : NSColor.black).set()
                            r.fill(using: .sourceAtop)
                            return true
                        }
                        tinted.draw(in: rect)
                    } else {
                        glyph.draw(in: rect)
                    }
                    x += glyph.size.width + 16
                }
            }
            return true
        }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Writes AppIcon.iconset and converts it with iconutil.
    static func renderIconSet(to dir: URL) -> Int32 {
        let iconset = dir.appendingPathComponent("AppIcon.iconset", isDirectory: true)
        try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            writePNG(renderIcon(size: CGFloat(base)), to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
            writePNG(renderIcon(size: CGFloat(base * 2)), to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        p.arguments = ["-c", "icns", iconset.path, "-o", dir.appendingPathComponent("AppIcon.icns").path]
        try? p.run()
        p.waitUntilExit()
        print(p.terminationStatus == 0 ? "Wrote \(dir.appendingPathComponent("AppIcon.icns").path)" : "iconutil failed")
        return p.terminationStatus
    }
}

// MARK: - Sample data

private enum Fixtures {
    static func make(in base: URL) -> [RecordingFolder] {
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let now = Date()
        let day: TimeInterval = 86_400
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: now)
        // Keep "today" items in the past, whatever time it is.
        let todayAt = { (h: Int, m: Int) -> Date in
            let d = cal.date(bySettingHour: h, minute: m, second: 0, of: now) ?? now
            return d < now ? d : max(startOfDay, now - Double(h) * 600)
        }

        return [
            folder(base, title: "Weekly sync with design team", date: todayAt(10, 30), duration: 2532,
                   model: "OpenAI (whisper-1)", detected: "english", status: .done, segments: designSync, audio: true,
                   names: ["Speaker 1": "Giulia", "Speaker 2": "Tom"]),
            folder(base, title: "Pricing call with Acme", date: todayAt(9, 5), duration: 1810,
                   model: nil, detected: nil, status: .transcribing, segments: [], audio: true),
            folder(base, title: "Candidate interview: Luca Bianchi", date: cal.date(bySettingHour: 16, minute: 0, second: 0, of: now - day)!, duration: 3120,
                   model: "ElevenLabs (scribe_v2)", detected: "ita", status: .done, segments: interview, audio: true),
            folder(base, title: "1:1 with Marco", date: cal.date(bySettingHour: 11, minute: 30, second: 0, of: now - 3 * day)!, duration: 1506,
                   model: nil, detected: nil, status: .error, segments: [], audio: true,
                   error: "HTTP 401 from api.openai.com: {\"error\":{\"message\":\"Incorrect API key provided.\"}}"),
            folder(base, title: "Daily standup", date: cal.date(bySettingHour: 9, minute: 15, second: 0, of: now - 12 * day)!, duration: 845,
                   model: "whisper.cpp (ggml-large-v3-turbo.bin)", detected: "en", status: .done, segments: standup,
                   audio: false),
            folder(base, title: "Kickoff Progetto Nova", date: cal.date(bySettingHour: 14, minute: 0, second: 0, of: now - 40 * day)!, duration: 4210,
                   model: "Groq (whisper-large-v3-turbo)", detected: "italian", status: .done, segments: kickoff,
                   audio: false),
        ]
    }

    private static func folder(_ base: URL, title: String, date: Date, duration: Double, model: String?,
                               detected: String?, status: RecordingStatus, segments: [Segment], audio: Bool,
                               names: [String: String]? = nil, error: String? = nil) -> RecordingFolder {
        let f = RecordingFolder(url: base.appendingPathComponent(Naming.folderName(date: date, title: title), isDirectory: true))
        try? FileManager.default.createDirectory(at: f.url, withIntermediateDirectories: true)
        let meta = RecordingMeta(title: title, date: date, durationSeconds: duration, language: "auto",
                                 detectedLanguage: detected, provider: nil, model: model, status: status, error: error,
                                 audioDeleted: audio ? nil : true, speakerNames: names)
        try? f.saveMeta(meta)
        if !segments.isEmpty {
            try? f.saveSegments(segments)
            _ = try? TranscriptWriter.write(folder: f, meta: meta, rawSegments: segments)
        }
        if audio && !FileManager.default.fileExists(atPath: f.mixedURL.path) {
            try? AudioTools.writeTone(f.mixedURL, seconds: Double(Int(duration)), amplitude: 0, sampleRate: 8_000)
        }
        return f
    }

    private static func seg(_ t: Double, _ who: String, _ text: String) -> Segment {
        Segment(start: t, end: t + 4, speaker: who, text: text)
    }

    static let designSync: [Segment] = [
        seg(3, "Me", "Morning everyone. Today I'd like to lock the Q4 roadmap."),
        seg(9, "Speaker 1", "Ready when you are. I updated the file with the latest onboarding screens."),
        seg(18, "Speaker 2", "Same here. I pulled the numbers from the billing dashboard too."),
        seg(24, "Me", "Great. Three big items: onboarding, billing and the new library."),
        seg(41, "Speaker 1", "Onboarding is basically ready. We tested it with five users last week and four finished without help."),
        seg(58, "Me", "Nice. What tripped up the fifth one?"),
        seg(63, "Speaker 1", "The permissions step. I'll add a short explainer before the system prompt."),
        seg(96, "Speaker 2", "Billing is the risky one. The Stripe migration needs at least two sprints."),
        seg(222, "Me", "Then let's move billing to November and ship the library first."),
        seg(230, "Speaker 2", "Works for me. I'll write the migration plan by Friday."),
        seg(241, "Speaker 1", "Makes sense. I'll share the updated roadmap after the call."),
    ]

    static let kickoff: [Segment] = [
        seg(4, "Me", "Benvenuti al kickoff di Nova. Partiamo dagli obiettivi del trimestre."),
        seg(12, "Speaker 1", "Il primo è chiaro: la beta chiusa entro fine ottobre."),
        seg(25, "Speaker 2", "Per arrivarci ci serve il design system pronto in tre settimane."),
    ]

    static let designSummary = """
    ## Summary
    Weekly design sync to lock the Q4 roadmap. Onboarding is ready after a five-person test, billing carries the most risk because of the Stripe migration, and the team agreed to ship the new library first.

    ## Decisions
    - Ship the new library before billing.
    - Move the billing migration to November.

    ## Action items
    - Giulia: add a short explainer before the permissions prompt in onboarding.
    - Tom: write the Stripe migration plan by Friday.
    - Giulia: share the updated roadmap after the call.
    """

    static func event(title: String, start: Date) -> CalendarEventInfo {
        CalendarEventInfo(title: title, calendar: "Work", start: start, end: start.addingTimeInterval(3600), attendees: [
            .init(name: "Giulia Rossi", email: "giulia@example.com"),
            .init(name: "Tom Becker", email: "tom@example.com"),
            .init(name: "Sara Conti", email: "sara@example.com"),
        ])
    }

    static let interview: [Segment] = [
        seg(2, "Me", "Grazie per essere qui, Luca. Partiamo dal tuo ultimo progetto."),
        seg(8, "Speaker 1", "Certo. Ho guidato la riscrittura dell'app iOS in SwiftUI, un team di quattro persone."),
        seg(21, "Me", "Qual è stata la difficoltà più grande?"),
        seg(25, "Speaker 1", "Convincere il business che valeva la pena. Abbiamo misurato i crash prima e dopo: meno 60%."),
    ]

    static let standup: [Segment] = [
        seg(1, "Me", "Quick round, what's blocking you?"),
        seg(5, "Others", "Nothing on my side, the release branch is green."),
    ]
}
