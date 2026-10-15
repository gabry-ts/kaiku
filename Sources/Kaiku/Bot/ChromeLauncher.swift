import AppKit
import ImageIO
import KaikuCore
import UniformTypeIdentifiers

/// Starts Google Chrome headless for the meeting bot: a throwaway profile, the bot's picture
/// as the camera, a silent microphone, English pages (the join scripts read English labels)
/// and a regular user agent. Opens the meeting and connects to it over DevTools.
///
/// Nobody watches the bot's screen, so it asks for as little video as it can: a small
/// window (the sites send smaller streams to small tiles) and incoming video switched off.
final class ChromeLauncher {
    private let process = Process()
    private let profile: URL
    private var port = 0
    let devTools: CDPClient

    var pid: pid_t { process.processIdentifier }
    var isRunning: Bool { process.isRunning }

    /// How Chrome ended, for the log.
    var exitDescription: String {
        guard !process.isRunning else { return "still running" }
        return process.terminationReason == .uncaughtSignal
            ? "killed by signal \(process.terminationStatus)" : "exit code \(process.terminationStatus)"
    }

    static var chromeURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome")
    }

    static var isInstalled: Bool { chromeURL != nil }
    static let downloadURL = URL(string: "https://www.google.com/chrome/")!

    private init(profile: URL, devTools: CDPClient) {
        self.profile = profile
        self.devTools = devTools
    }

    static func launch(url: URL, photo: URL?) async throws -> ChromeLauncher {
        guard let app = chromeURL else { throw AudioCaptureError("Google Chrome is not installed") }
        let executable = app.appendingPathComponent("Contents/MacOS/Google Chrome")
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent("kaiku-bot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)

        let silence = profile.appendingPathComponent("silence.wav")
        try silentWAV().write(to: silence)
        var args = [
            "--headless=new",
            "--user-data-dir=\(profile.path)",
            "--remote-debugging-port=0",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-blink-features=AutomationControlled",
            "--autoplay-policy=no-user-gesture-required",
            "--use-fake-ui-for-media-stream",
            "--use-fake-device-for-media-stream",
            "--use-file-for-fake-audio-capture=\(silence.path)",
            "--lang=en-US",
            "--window-size=640,360",
            "--user-agent=\(userAgent(app: app))",
        ]
        if let photo, let frames = cameraFrames(photo) {
            let camera = profile.appendingPathComponent("camera.mjpeg")
            try frames.write(to: camera)
            args.append("--use-file-for-fake-video-capture=\(camera.path)")
        }
        // Opened blank first, so the video switch is in place before the meeting loads.
        args.append("about:blank")

        let launcher = ChromeLauncher(profile: profile, devTools: CDPClient())
        launcher.process.executableURL = executable
        launcher.process.arguments = args
        launcher.process.standardOutput = FileHandle.nullDevice
        launcher.process.standardError = FileHandle.nullDevice
        try launcher.process.run()
        Log.app.info("Meeting bot Chrome started (pid \(launcher.pid))")
        do {
            launcher.port = try await launcher.devToolsPort()
            try await launcher.devTools.connect(port: launcher.port)
            // Scripts for new documents only run with the Page domain on.
            try await launcher.devTools.send("Page.enable")
            try await launcher.devTools.send("Page.addScriptToEvaluateOnNewDocument", ["source": noIncomingVideo])
            try await launcher.devTools.send("Page.navigate", ["url": url.absoluteString])
        } catch {
            launcher.quit()
            throw error
        }
        return launcher
    }

    /// Chrome writes the port it picked to DevToolsActivePort in the profile.
    private func devToolsPort() async throws -> Int {
        let file = profile.appendingPathComponent("DevToolsActivePort")
        for _ in 0..<60 {
            if let text = try? String(contentsOf: file, encoding: .utf8),
               let port = text.split(separator: "\n").first.flatMap({ Int($0) }) { return port }
            guard process.isRunning else { break }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw AudioCaptureError("Google Chrome did not start")
    }

    /// Connects again to the meeting page, e.g. after the site replaced the tab.
    func reconnect() async throws {
        try await devTools.connect(port: port)
    }

    func quit() {
        devTools.close()
        if process.isRunning {
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { kill(pid, SIGKILL) }
        }
        let profile = profile
        DispatchQueue.global().asyncAfter(deadline: .now() + 4) { try? FileManager.default.removeItem(at: profile) }
    }

    /// Turns off every video track received in a call, so Chrome doesn't draw it. Audio and
    /// the bot's own camera are left alone.
    private static let noIncomingVideo = """
    (() => {
      const P = window.RTCPeerConnection;
      if (!P) return;
      window.RTCPeerConnection = new Proxy(P, {
        construct(target, args, newTarget) {
          const pc = Reflect.construct(target, args, newTarget);
          pc.addEventListener('track', e => { if (e.track.kind === 'video') e.track.enabled = false; });
          return pc;
        }
      });
    })();
    """

    /// Chrome's own user agent without "Headless", which meeting sites turn away.
    private static func userAgent(app: URL) -> String {
        let version = Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "140.0.0.0"
        let major = version.split(separator: ".").first.map(String.init) ?? "140"
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(major).0.0.0 Safari/537.36"
    }

    /// One second of 16-bit mono silence, looped by Chrome as the microphone.
    private static func silentWAV() -> Data {
        let rate: UInt32 = 48_000
        let bytes = rate * 2
        var data = Data()
        func put<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + bytes).littleEndian)
        data.append(contentsOf: Array("WAVE".utf8)); data.append(contentsOf: Array("fmt ".utf8))
        put(UInt32(16).littleEndian); put(UInt16(1).littleEndian); put(UInt16(1).littleEndian)
        put(rate.littleEndian); put((rate * 2).littleEndian); put(UInt16(2).littleEndian); put(UInt16(16).littleEndian)
        data.append(contentsOf: Array("data".utf8)); put(bytes.littleEndian)
        data.append(Data(count: Int(bytes)))
        return data
    }

    /// The picture centered on a dark 1280×720 frame, as an MJPEG stream Chrome loops as the camera.
    private static func cameraFrames(_ photo: URL) -> Data? {
        guard let source = CGImageSourceCreateWithURL(photo as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = 1280, height = 720
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 0.12, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let side = CGFloat(height) * 0.8
        let scale = min(side / CGFloat(image.width), side / CGFloat(image.height))
        let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
        context.draw(image, in: CGRect(x: (CGFloat(width) - w) / 2, y: (CGFloat(height) - h) / 2, width: w, height: h))
        guard let frame = context.makeImage() else { return nil }
        let jpeg = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, frame, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        var stream = Data()
        for _ in 0..<30 { stream.append(jpeg as Data) }
        return stream
    }
}
