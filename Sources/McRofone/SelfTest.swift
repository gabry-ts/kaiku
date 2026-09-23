import AppKit
import AVFoundation
import McRofoneCore

/// `McRofone --selftest-audio [seconds]`: records mic + system audio for a few seconds
/// into a temp folder and prints what happened. For diagnosing capture problems from a terminal.
enum SelfTest {
    static func runAudio(seconds: Double) -> Int32 {
        setvbuf(stdout, nil, _IONBF, 0)
        AppSettings.registerDefaults()
        print("mc.Rofone audio self-test")
        print("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("Mic permission: \(describe(AVCaptureDevice.authorizationStatus(for: .audio)))")
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            let sem = DispatchSemaphore(value: 0)
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                print("Mic permission request: \(granted ? "granted" : "denied")")
                sem.signal()
            }
            sem.wait()
        }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcrofone-selftest-\(Int(Date().timeIntervalSince1970))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let micRaw = dir.appendingPathComponent("mic.caf")
        let systemRaw = dir.appendingPathComponent("system.caf")
        let mic = dir.appendingPathComponent("mic.m4a")
        let system = dir.appendingPathComponent("system.m4a")
        print("Output folder: \(dir.path)")

        print("\nInput devices:")
        AudioDevices.inputs().forEach { print("  - \($0.summary)") }
        let before = snapshot()
        print("\nBEFORE capture:\n\(before)")
        let micDevice = AudioDevices.resolveMicrophone(setting: AppSettings.microphone)
        print("Microphone setting: \(AppSettings.microphone) -> \(micDevice?.summary ?? "none (system audio only)")")

        let recorder = CallRecorder()
        do {
            try recorder.start(micURL: micRaw, systemURL: systemRaw, micDevice: micDevice)
        } catch {
            print("FAILED to start: \(error.diagnosticDescription)")
            return 1
        }
        print(recorder.warnings.isEmpty ? "Capture started (mic + system)" : "Warnings:\n  " + recorder.warnings.joined(separator: "\n  "))
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let during = snapshot()
        print("\nDURING capture:\n\(during)")
        print("Recording \(Int(seconds)) s (playing a system sound so the system track has content)...")
        NSSound(named: "Glass")?.play()
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        recorder.stop()
        print("\nDefaults and sample rates unchanged during capture: \(before.stable == during.stable ? "YES" : "NO")")
        for (raw, final) in [(micRaw, mic), (systemRaw, system)] where FileManager.default.fileExists(atPath: raw.path) {
            do {
                let d = try AudioFiles.convertToM4A(raw, output: final)
                print("\(raw.lastPathComponent) -> \(final.lastPathComponent): \(String(format: "%.1f", d)) s")
            } catch {
                print("Conversion of \(raw.lastPathComponent) FAILED: \(error.diagnosticDescription)")
            }
        }

        for url in [mic, system] {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
            print("\(url.lastPathComponent): \(size.map { "\($0) bytes" } ?? "missing")\(peak(url).map { ", max volume \($0)" } ?? "")")
        }
        return 0
    }

    /// `McRofone --selftest-recovery`: a child process writes a CAF track the same way a
    /// recording does and is killed with SIGKILL mid-write; then the recovery code converts
    /// it and the result is checked. No microphone or system audio is used.
    static func runRecovery() -> Int32 {
        setvbuf(stdout, nil, _IONBF, 0)
        AppSettings.registerDefaults()
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("mcrofone-recovery-\(Int(Date().timeIntervalSince1970))")
        let folder = RecordingFolder(url: base.appendingPathComponent("2026-01-01_1000_crash-test", isDirectory: true))
        try? FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        let start = Date()
        var meta = RecordingMeta(title: "Crash test", date: start, durationSeconds: 0, language: "auto", status: .recording)
        meta.bookmarks = [Bookmark(time: 1, label: "Before crash")]
        try? folder.saveMeta(meta)
        print("Folder: \(folder.url.path)")

        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--selftest-write-caf", folder.micRawURL.path, folder.systemRawURL.path]
        do { try child.run() } catch { print("FAILED to start writer: \(error)"); return 1 }
        Thread.sleep(forTimeInterval: 3)
        kill(child.processIdentifier, SIGKILL)
        child.waitUntilExit()
        print("Writer killed with SIGKILL (reason \(child.terminationReason == .uncaughtSignal ? "signal" : "exit"))")
        for url in [folder.micRawURL, folder.systemRawURL] {
            print("  \(url.lastPathComponent): \(RecordingFolder.fileSize(url)) bytes")
        }

        let outcomes = Recovery.recoverAll(base: base, skip: nil)
        let after = folder.loadMeta()
        let micD = AudioFiles.duration(folder.micURL) ?? 0
        let sysD = AudioFiles.duration(folder.systemURL) ?? 0
        print("Recovered: \(outcomes.map(\.recovered)), status: \(after?.status.rawValue ?? "?"), duration: \(String(format: "%.2f", after?.durationSeconds ?? 0)) s")
        print("mic.m4a \(String(format: "%.2f", micD)) s, system.m4a \(String(format: "%.2f", sysD)) s, CAFs left: \(FileManager.default.fileExists(atPath: folder.micRawURL.path) || FileManager.default.fileExists(atPath: folder.systemRawURL.path))")
        print("Bookmarks kept: \(after?.bookmarks?.count ?? 0)")
        let ok = outcomes.first?.recovered == true && after?.status == .recovered && micD > 1.5 && sysD > 1.5
            && abs(micD - sysD) < 0.3 && after?.bookmarks?.count == 1
        print(ok ? "PASS" : "FAIL")
        return ok ? 0 : 1
    }

    /// Child side of the recovery test: writes a 440 Hz tone to both tracks through
    /// TrackWriter (like a real recording, 10 ms buffers) until it is killed.
    static func writeCAFForever(mic: URL, system: URL) -> Int32 {
        let gate = PauseGate()
        let writers = [TrackWriter(url: mic, gate: gate), TrackWriter(url: system, gate: gate)]
        let formats = [AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!,
                       AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!]
        var n = 0
        while true {
            for (w, f) in zip(writers, formats) {
                let b = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: 480)!
                b.frameLength = 480
                for c in 0..<Int(f.channelCount) {
                    for i in 0..<480 { b.floatChannelData![c][i] = 0.3 * sin(Float(n * 480 + i) * 2 * .pi * 440 / 48_000) }
                }
                w.write(b)
            }
            n += 1
            usleep(10_000)
        }
    }

    /// `McRofone --selftest-devicechange`: checks that tracks stay aligned when a source changes.
    /// Part 1 is synthetic (no devices): the "system" track drops out for 0.4 s and comes back
    /// at 44.1 kHz mono while the "mic" track continues, with a pause in between.
    /// Part 2 uses the real capture path: the system tap is rebuilt and the mic reopened
    /// mid-recording. Nothing is played; the microphone is opened for about 5 seconds.
    static func runDeviceChange() -> Int32 {
        setvbuf(stdout, nil, _IONBF, 0)
        AppSettings.registerDefaults()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcrofone-devices-\(Int(Date().timeIntervalSince1970))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        print("Folder: \(dir.path)")

        // Part 1: synthetic.
        let gate = PauseGate()
        let mic = TrackWriter(url: dir.appendingPathComponent("synthetic-mic.caf"), gate: gate)
        let sys = TrackWriter(url: dir.appendingPathComponent("synthetic-system.caf"), gate: gate)
        let micFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let sysA = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let sysB = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let t0 = ProcessInfo.processInfo.systemUptime
        var micDone = 0.0, sysDone = 0.0, armed = false
        func feed(_ w: TrackWriter, _ f: AVAudioFormat, _ done: inout Double) {
            let due = gate.activeSeconds() - (t0 - 0) // seconds the source has produced
            let frames = Int((due - done) * f.sampleRate)
            guard frames > 0, let b = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(frames)) else { return }
            b.frameLength = AVAudioFrameCount(frames)
            for c in 0..<Int(f.channelCount) { for i in 0..<frames { b.floatChannelData![c][i] = 0.2 } }
            w.write(b)
            done += Double(frames) / f.sampleRate
        }
        let activeStart = gate.activeSeconds()
        micDone = activeStart - t0
        sysDone = micDone
        while ProcessInfo.processInfo.systemUptime - t0 < 3.0 {
            let t = ProcessInfo.processInfo.systemUptime - t0
            gate.set(t >= 2.0 && t < 2.3)
            if !gate.isPaused {
                feed(mic, micFormat, &micDone)
                if t < 1.0 {
                    feed(sys, sysA, &sysDone)
                } else if t < 1.4 {
                    if !armed { sys.expectGap(); armed = true }
                    sysDone = gate.activeSeconds() - t0 // the old device is gone: its audio is lost
                } else {
                    feed(sys, sysB, &sysDone)
                }
            } else {
                micDone = gate.activeSeconds() - t0
                sysDone = micDone
            }
            usleep(10_000)
        }
        mic.close()
        sys.close()
        let micD = AudioFiles.duration(mic.url) ?? 0
        let sysD = AudioFiles.duration(sys.url) ?? 0
        let sysFormat = (try? AVAudioFile(forReading: sys.url))?.fileFormat
        let part1 = abs(micD - sysD) < 0.05 && sysFormat?.sampleRate == 48_000 && sysFormat?.channelCount == 2
        print(String(format: "Synthetic: mic %.3f s, system %.3f s (gap padded %.3f s), difference %.0f ms, system format %@ -> %@",
                     micD, sysD, sys.paddedSeconds, abs(micD - sysD) * 1000,
                     sysFormat.map { "\(Int($0.sampleRate)) Hz \($0.channelCount) ch" } ?? "?", part1 ? "PASS" : "FAIL"))

        // Part 2: real devices.
        let recorder = CallRecorder()
        let micDevice = AudioDevices.resolveMicrophone(setting: AppSettings.microphone)
        print("Microphone: \(micDevice?.summary ?? "none")")
        let before = (AudioDevices.defaultInput?.uid, AudioDevices.defaultOutput?.uid, AudioDevices.defaultOutput?.nominalSampleRate)
        do {
            try recorder.start(micURL: dir.appendingPathComponent("mic.caf"), systemURL: dir.appendingPathComponent("system.caf"), micDevice: micDevice)
        } catch {
            print("FAILED to start capture: \(error.diagnosticDescription)")
            return 1
        }
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        let offsetBefore = recorder.trackSeconds.count == 2 ? recorder.trackSeconds[0] - recorder.trackSeconds[1] : 0
        recorder.rebuildSystemTap()
        do { try recorder.reopenMicrophone() } catch { print("Mic reopen failed: \(error.diagnosticDescription)") }
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        recorder.setPaused(true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        recorder.setPaused(false)
        recorder.rebuildSystemTap()
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        let offsetAfter = recorder.trackSeconds.count == 2 ? recorder.trackSeconds[0] - recorder.trackSeconds[1] : 0
        recorder.stop()
        let after = (AudioDevices.defaultInput?.uid, AudioDevices.defaultOutput?.uid, AudioDevices.defaultOutput?.nominalSampleRate)
        let m = AudioFiles.duration(dir.appendingPathComponent("mic.caf")) ?? 0
        let s = AudioFiles.duration(dir.appendingPathComponent("system.caf")) ?? 0
        let drift = abs(offsetAfter - offsetBefore)
        let unchanged = before == after
        let part2 = micDevice == nil ? s > 4 : (drift < 0.05 && m > 4 && s > 4)
        print(String(format: "Real: mic %.3f s, system %.3f s; mic-system offset %.0f ms before the changes, %.0f ms after (moved %.0f ms)",
                     m, s, offsetBefore * 1000, offsetAfter * 1000, drift * 1000))
        print("Default devices and sample rate unchanged: \(unchanged ? "YES" : "NO")")
        print(part2 && unchanged ? "Real devices: PASS" : "Real devices: FAIL")
        return part1 && part2 && unchanged ? 0 : 1
    }

    /// `McRofone --selftest-mute [--force]`: mutes every microphone, checks it, simulates an
    /// app raising the volume, unmutes and checks every device is exactly as before.
    /// The original state is always restored (defer). Refuses to run while another app
    /// uses a microphone (you may be in a call) unless --force.
    @MainActor
    static func runMute(force: Bool) -> Int32 {
        setvbuf(stdout, nil, _IONBF, 0)
        AppSettings.registerDefaults()
        let others = MeetingMonitor.inputProcessBundleIDs().filter { $0 != Bundle.main.bundleIdentifier }
        if !others.isEmpty && !force {
            print("Skipped: \(others.joined(separator: ", ")) is using a microphone. Run again with --force to mute anyway.")
            return 2
        }
        struct Snap: Equatable { let mute: UInt32?; let volumes: [UInt32: Float]; let running: Bool }
        func snapshot() -> [String: Snap] {
            Dictionary(uniqueKeysWithValues: MicMuter.inputDevices().map {
                ($0.uid, Snap(mute: MicMuter.muteValue($0.id), volumes: MicMuter.volumes($0), running: $0.isRunningSomewhere))
            })
        }
        let devices = MicMuter.inputDevices()
        let before = snapshot()
        let muter = MicMuter.shared
        var ok = true
        defer {
            if muter.isMuted { muter.unmute() }
            muter.restoreAfterCrash()
        }
        for d in devices {
            let method = MutePlanner.method(MicMuter.capabilities(d))
            let how: String
            switch method {
            case .mute: how = "mute switch"
            case .volume(let e): how = "volume to 0 on \(e == [0] ? "master" : "channels \(e.map(String.init).joined(separator: ","))")"
            case .unsupported: how = "NOT SUPPORTED"
            }
            print("\(d.name) [\(d.transportName)]: \(how); before: mute \(before[d.uid]?.mute.map(String.init) ?? "-"), volumes \(before[d.uid]?.volumes.sorted { $0.key < $1.key }.map { "\($0.key)=\(String(format: "%.2f", $0.value))" }.joined(separator: " ") ?? "-")")
        }

        muter.mute()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        for d in devices where !muter.unsupported.contains(d.name) {
            let method = muter.method(for: d.uid) ?? .unsupported
            let now = MicMuter.volumes(d)
            if MutePlanner.needsReapply(method, mute: MicMuter.muteValue(d.id), volumes: now) {
                print("FAIL: \(d.name) is not silent")
                ok = false
            }
            if case .volume = method, MutePlanner.method(MicMuter.capabilities(d)) == .mute {
                print("\(d.name): mute switch ignored, used volume 0 instead")
            }
            if d.isBluetooth && d.isRunningSomewhere && before[d.uid]?.running == false {
                print("FAIL: \(d.name) started running")
                ok = false
            }
        }
        // An app raising the mic back up gets muted again.
        if let d = devices.first(where: { muter.method(for: $0.uid) != nil }) {
            switch muter.method(for: d.uid) ?? .unsupported {
            case .mute: MicMuter.setUInt32(d.id, kAudioDevicePropertyMute, 0, 0)
            case .volume(let e): MicMuter.setFloat(d.id, kAudioDevicePropertyVolumeScalar, e[0], 0.8)
            case .unsupported: break
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let reapplied = !MutePlanner.needsReapply(muter.method(for: d.uid) ?? .unsupported,
                                                      mute: MicMuter.muteValue(d.id), volumes: MicMuter.volumes(d))
            print("Raised by \"another app\" on \(d.name), muted again: \(reapplied ? "YES" : "NO")")
            ok = ok && reapplied
        }
        print("Unsupported: \(muter.unsupported.isEmpty ? "none" : muter.unsupported.joined(separator: ", "))")

        muter.unmute()
        let after = snapshot()
        for d in devices {
            guard let b = before[d.uid], let a = after[d.uid] else { continue }
            let same = b.mute == a.mute && b.volumes.keys.sorted() == a.volumes.keys.sorted()
                && b.volumes.allSatisfy { abs($0.value - (a.volumes[$0.key] ?? -1)) < 0.001 }
            if !same { print("FAIL: \(d.name) not restored: \(b) -> \(a)"); ok = false }
        }
        print(ok ? "Restored exactly: YES\nPASS" : "FAIL")
        return ok ? 0 : 1
    }

    /// `McRofone --selftest-detect`: prints the processes using audio input right now and
    /// the meeting apps recognized among them. Reads Core Audio properties only.
    static func runDetect() -> Int32 {
        setvbuf(stdout, nil, _IONBF, 0)
        let all = MeetingMonitor.inputProcessBundleIDs()
        print("Processes using audio input: \(all.isEmpty ? "none" : all.joined(separator: ", "))")
        let apps = MeetingMonitor.appsUsingMicrophone(excluding: getpid())
        print("Meeting apps detected: \(apps.isEmpty ? "none" : apps.map(\.name).joined(separator: ", "))")
        return 0
    }

    /// `McRofone --selftest-trim`: builds 4 s tone, 10 s silence, 4 s tone, trims it the
    /// way transcription does and checks the time mapping. Offline, no devices used.
    static func runTrim() -> Int32 {
        setvbuf(stdout, nil, _IONBF, 0)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcrofone-trim-\(Int(Date().timeIntervalSince1970))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let caf = dir.appendingPathComponent("source.caf")
        let m4a = dir.appendingPathComponent("source.m4a")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        do {
            let writer = TrackWriter(url: caf, gate: PauseGate())
            for second in 0..<18 {
                let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
                b.frameLength = 48_000
                let loud = second < 4 || second >= 14
                for i in 0..<48_000 { b.floatChannelData![0][i] = loud ? 0.3 * sin(Float(i) * 2 * .pi * 440 / 48_000) : 0 }
                writer.write(b)
            }
            writer.close()
            try AudioFiles.convertToM4A(caf, output: m4a)
        } catch {
            print("FAILED to build test audio: \(error.diagnosticDescription)")
            return 1
        }
        let sem = DispatchSemaphore(value: 0)
        var input: TranscriptionJob.Input?
        Task.detached {
            input = await TranscriptionJob.prepare(m4a, trim: true, options: SilenceTrimmer.Options(), dir: dir)
            sem.signal()
        }
        sem.wait()
        guard let input, let map = input.map else { print("FAIL: nothing trimmed"); return 1 }
        let trimmed = AudioFiles.duration(input.url) ?? 0
        print("Original 18.0 s, keep ranges: \(map.keep.map { String(format: "%.2f-%.2f", $0.start, $0.end) })")
        print(String(format: "Trimmed file %.2f s (expected %.2f s)", trimmed, map.trimmedDuration))
        let seg = map.remap([Segment(start: 4.5, end: 5.5, text: "second tone")])[0]
        print(String(format: "A word at 4.5 s in the trimmed file maps to %.2f s in the original", seg.start))
        let ok = abs(trimmed - map.trimmedDuration) < 0.2 && map.trimmedDuration < 10 && abs(seg.start - 13.7) < 0.1
        print(ok ? "PASS" : "FAIL")
        return ok ? 0 : 1
    }

    /// `McRofone --selftest-audiotools`: checks the offline conversions used by the providers
    /// (mix, 16 kHz WAV, compression, chunking) on generated audio. No devices used.
    static func runAudioTools() -> Int32 {
        setvbuf(stdout, nil, _IONBF, 0)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcrofone-tools-\(Int(Date().timeIntervalSince1970))")
        defer { try? FileManager.default.removeItem(at: dir) }
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            print("\(ok ? "ok  " : "FAIL") \(what)")
            if !ok { failures += 1 }
        }
        func info(_ url: URL) -> (duration: Double, rate: Double, channels: AVAudioChannelCount, formatID: AudioFormatID)? {
            guard let f = try? AVAudioFile(forReading: url) else { return nil }
            let d = Double(f.length) / f.processingFormat.sampleRate
            return (d, f.fileFormat.sampleRate, f.fileFormat.channelCount, f.fileFormat.streamDescription.pointee.mFormatID)
        }
        let sem = DispatchSemaphore(value: 0)
        var error: Error?
        Task.detached {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let mic = dir.appendingPathComponent("mic.m4a")
                let system = dir.appendingPathComponent("system.m4a")
                let long = dir.appendingPathComponent("long.m4a")
                try AudioTools.writeTone(mic, seconds: 3, frequency: 440, sampleRate: 16_000, channels: 1)
                try AudioTools.writeTone(system, seconds: 5, frequency: 660, sampleRate: 48_000, channels: 2)
                try AudioTools.writeTone(long, seconds: 130, frequency: 330, sampleRate: 48_000, channels: 1)

                let mixed = dir.appendingPathComponent("mixed.m4a")
                try await AudioTools.mix(mic: mic, system: system, output: mixed)
                let m = info(mixed)
                check(m.map { abs($0.duration - 5) < 0.1 && $0.rate == 48_000 && $0.channels == 2 && $0.formatID == kAudioFormatMPEG4AAC } ?? false,
                      String(format: "mix: %.2f s, %.0f Hz, %d ch AAC (expected 5 s, 48000 Hz, 2 ch)", m?.duration ?? 0, m?.rate ?? 0, m?.channels ?? 0))
                let peak = try AudioFiles.peaks(mixed, window: 1).peaks
                check(peak.count == 5 && peak[0] > 0.4 && peak[4] > 0.2 && peak[4] < 0.4,
                      "mix: both tracks summed for 3 s, then only the system track (peaks \(peak.map { String(format: "%.2f", $0) }))")

                let wav = dir.appendingPathComponent("input.wav")
                try await AudioTools.toWhisperWav(system, output: wav)
                let w = info(wav)
                let bits = (try? AVAudioFile(forReading: wav))?.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int ?? 0
                check(w.map { abs($0.duration - 5) < 0.05 && $0.rate == 16_000 && $0.channels == 1 && $0.formatID == kAudioFormatLinearPCM && bits == 16 } ?? false,
                      String(format: "wav: %.2f s, %.0f Hz, %d ch, %d bit PCM (expected 5 s, 16000 Hz, 1 ch, 16 bit)", w?.duration ?? 0, w?.rate ?? 0, w?.channels ?? 0, bits))

                let small = dir.appendingPathComponent("audio.m4a")
                try await AudioTools.compress(long, output: small)
                let c = info(small)
                let size = ((try? FileManager.default.attributesOfItem(atPath: small.path)[.size]) as? Int) ?? 0
                check(c.map { abs($0.duration - 130) < 0.1 && $0.rate == 16_000 && $0.channels == 1 } ?? false && size < 130 * 5_000,
                      String(format: "compress: %.2f s, %.0f Hz, %d ch, %d KB", c?.duration ?? 0, c?.rate ?? 0, c?.channels ?? 0, size / 1024))

                let chunkDir = dir.appendingPathComponent("chunks")
                try FileManager.default.createDirectory(at: chunkDir, withIntermediateDirectories: true)
                let chunks = try await AudioTools.chunks(long, seconds: 60, dir: chunkDir)
                let expected: [(Double, Double)] = [(0, 60), (60, 60), (120, 10)]
                check(chunks.count == 3, "chunks: \(chunks.count) files (expected 3)")
                for (chunk, e) in zip(chunks, expected) {
                    let measured = info(chunk.url)?.duration ?? 0
                    check(abs(chunk.offset - e.0) < 0.01 && abs(chunk.duration - e.1) < 0.01 && abs(measured - e.1) < 0.1,
                          String(format: "%@: offset %.2f s, duration %.2f s, file %.2f s", chunk.url.lastPathComponent, chunk.offset, chunk.duration, measured))
                }
            } catch let e {
                error = e
            }
            sem.signal()
        }
        sem.wait()
        if let error {
            print("FAIL: \(error.diagnosticDescription)")
            return 1
        }
        print(failures == 0 ? "PASS" : "FAIL")
        return failures == 0 ? 0 : 1
    }

    private struct Snapshot: CustomStringConvertible {
        let input: AudioDevice?
        let output: AudioDevice?
        /// Fields that must not change because of our capture.
        var stable: String {
            [input, output].map { d in d.map { "\($0.uid)@\(Int($0.nominalSampleRate))" } ?? "-" }.joined(separator: "|")
        }
        var description: String {
            "  default input:  \(input?.summary ?? "none")\n  default output: \(output?.summary ?? "none")"
        }
    }

    private static func snapshot() -> Snapshot {
        Snapshot(input: AudioDevices.defaultInput, output: AudioDevices.defaultOutput)
    }

    /// Max volume in dB of a file.
    private static func peak(_ url: URL) -> String? {
        guard let (peaks, _) = try? AudioFiles.peaks(url, window: 1), let top = peaks.max() else { return nil }
        return top > 0 ? String(format: "%.1f dB", 20 * log10(top)) : "-inf dB"
    }

    private static func describe(_ s: AVAuthorizationStatus) -> String {
        switch s {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not determined"
        @unknown default: return "unknown"
        }
    }
}
