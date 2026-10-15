import Foundation
import KaikuCore

/// What the bot sees on the meeting page.
struct MeetingPageState {
    enum Phase: String {
        /// Still on the join screen (or loading).
        case joining
        /// Waiting for the host to let it in.
        case lobby
        case inCall
        /// Left, removed, refused or the meeting ended.
        case ended
    }

    var phase: Phase
    /// People in the call including the bot, nil when the page doesn't show it.
    var participants: Int?
    var detail: String?
}

/// Drives the Google Meet and Microsoft Teams web pages through DevTools. The pages are
/// opened in English, and the scripts look for buttons by their English labels.
struct MeetingPlatform {
    let platform: MeetingLink.Platform

    /// The URL to open: Teams skips the "open the app?" step.
    func joinURL(_ link: MeetingLink) -> URL {
        guard platform == .teams, var parts = URLComponents(url: link.url, resolvingAgainstBaseURL: false) else { return link.url }
        var items = parts.queryItems ?? []
        for (name, value) in [("msLaunch", "false"), ("suppressPrompt", "true"), ("anon", "true")]
        where !items.contains(where: { $0.name == name }) {
            items.append(URLQueryItem(name: name, value: value))
        }
        parts.queryItems = items
        return parts.url ?? link.url
    }

    /// Reads the page, and on the join screen fills in the name, turns the microphone off,
    /// the camera on or off, and asks to join. Safe to call again and again.
    func step(_ devTools: CDPClient, name: String, camera: Bool) async throws -> MeetingPageState {
        let args = try String(decoding: JSONSerialization.data(withJSONObject: ["name": name, "camera": camera]), as: UTF8.self)
        let value = try await devTools.evaluate(Self.call(platform == .meet ? Self.meetStep : Self.teamsStep, args)) as? [String: Any] ?? [:]
        // The name field wants real typing on both sites.
        if value["typeName"] as? Bool == true {
            try await devTools.insertText(name)
        }
        let phase = MeetingPageState.Phase(rawValue: value["phase"] as? String ?? "") ?? .joining
        return MeetingPageState(phase: phase, participants: value["participants"] as? Int, detail: value["detail"] as? String)
    }

    /// Posts a message in the meeting chat. Best effort.
    func sendChat(_ devTools: CDPClient, _ message: String) async {
        do {
            guard try await devTools.evaluate(Self.call(platform == .meet ? Self.meetOpenChat : Self.teamsOpenChat)) as? Bool == true else {
                Log.app.error("Meeting bot: chat box not found")
                return
            }
            try await devTools.insertText(message)
            try await Task.sleep(nanoseconds: 300_000_000)
            try await devTools.pressEnter()
        } catch {
            Log.app.error("Meeting bot: chat message not sent: \(error.diagnosticDescription, privacy: .public)")
        }
    }

    func leave(_ devTools: CDPClient) async {
        let script = "() => { const b = button(/^(leave call|leave|hang up)$/i); if (b) b.click(); return !!b }"
        _ = try? await devTools.evaluate(Self.call(script))
    }

    // MARK: Scripts

    /// `fn` called with `args`, next to the helpers every script uses.
    static func call(_ fn: String, _ args: String = "") -> String {
        "(async () => {\n\(helpers)\nreturn await (\(fn))(\(args));\n})()"
    }

    /// Find visible buttons by label or text. `__k` keeps state between calls.
    private static let helpers = """
    window.__k = window.__k || {};
    const visible = e => !!(e && (e.offsetWidth || e.offsetHeight || e.getClientRects().length));
    const label = e => [e.getAttribute('aria-label'), e.getAttribute('data-tooltip'), e.getAttribute('title'), e.innerText]
      .filter(Boolean).join(' ').trim();
    const button = re => [...document.querySelectorAll('button, [role=button]')]
      .find(e => visible(e) && !e.disabled && re.test(label(e).split('\\n')[0].trim()));
    const buttonMatching = re => [...document.querySelectorAll('button, [role=button]')]
      .find(e => visible(e) && !e.disabled && re.test(label(e)));
    const pageText = () => document.body ? document.body.innerText : '';
    """

    private static let meetStep = """
    ({ name, camera }) => {
      const text = pageText();
      if (/you left the meeting|you've been removed|you have been removed|the call has ended|meeting has ended|return to home screen|you can't join this video call|denied your request|no one responded to your request/i.test(text))
        return { phase: 'ended', detail: text.split('\\n').find(l => /left|removed|ended|can't join|denied|responded/i.test(l)) };
      if (buttonMatching(/leave call/i)) {
        const ids = new Set([...document.querySelectorAll('[data-participant-id]')].map(e => e.getAttribute('data-participant-id')));
        return { phase: 'inCall', participants: ids.size || null };
      }
      if (/asking to be let in|please wait until a meeting host|someone will let you in soon/i.test(text)) return { phase: 'lobby' };
      const ok = button(/^(got it|dismiss|accept all|continue without microphone and camera)$/i);
      if (ok) { ok.click(); return { phase: 'joining' }; }
      const field = [...document.querySelectorAll('input')].find(e => /name/i.test((e.getAttribute('aria-label') || '') + (e.placeholder || '')));
      if (field && !field.value) { field.focus(); return { phase: 'joining', typeName: true }; }
      const mic = buttonMatching(/turn off microphone/i);
      if (mic) mic.click();
      const cam = buttonMatching(camera ? /turn on camera/i : /turn off camera/i);
      if (cam) cam.click();
      if (!window.__k.joined) {
        const join = button(/^(ask to join|join now|join anyway|switch here)$/i);
        if (join) { window.__k.joined = true; join.click(); }
      }
      return { phase: 'joining' };
    }
    """

    private static let teamsStep = """
    ({ name, camera }) => {
      const text = pageText();
      if (/you left the meeting|you've been removed|you were removed|the meeting has ended|meeting ended|denied your request|nobody let you in|sorry, but you were denied access/i.test(text))
        return { phase: 'ended', detail: text.split('\\n').find(l => /left|removed|ended|denied|let you in/i.test(l)) };
      const hangup = document.querySelector('#hangup-button, [data-tid="hangup-main-btn"], [data-tid="call-hangup"]') || button(/^(leave|hang up)$/i);
      if (hangup) {
        const roster = document.querySelector('[data-tid="roster-button"], #roster-button');
        const count = roster ? parseInt((roster.innerText.match(/\\d+/) || [])[0], 10) : NaN;
        const tiles = document.querySelectorAll('[data-tid="video-tile"], [data-cid="calling-participant-stream"]').length;
        return { phase: 'inCall', participants: Number.isFinite(count) ? count : (tiles || null) };
      }
      if (/someone in the meeting should let you in soon|we've let people in the meeting know you're waiting|waiting for someone to let you in|when the meeting starts, we'll let people know/i.test(text))
        return { phase: 'lobby' };
      const browser = button(/continue on this browser|join on the web instead|use the web app instead/i);
      if (browser) { browser.click(); return { phase: 'joining' }; }
      const ok = button(/^(accept|accept all|got it|dismiss|continue without audio or video)$/i);
      if (ok) { ok.click(); return { phase: 'joining' }; }
      const field = document.querySelector('[data-tid="prejoin-display-name-input"]')
        || [...document.querySelectorAll('input')].find(e => /name/i.test((e.getAttribute('aria-label') || '') + (e.placeholder || '')));
      if (field && !field.value) { field.focus(); return { phase: 'joining', typeName: true }; }
      const mic = document.querySelector('[data-tid="toggle-mute"]');
      if (mic && /true/i.test(mic.getAttribute('aria-checked') || mic.getAttribute('aria-pressed') || '')) mic.click();
      const video = document.querySelector('[data-tid="toggle-video"]');
      if (video) {
        const on = /true/i.test(video.getAttribute('aria-checked') || video.getAttribute('aria-pressed') || '');
        if (on !== camera) video.click();
      }
      if (!window.__k.joined) {
        const join = document.querySelector('[data-tid="prejoin-join-button"]') || button(/^(join now|join)$/i);
        if (join && !join.disabled) { window.__k.joined = true; join.click(); }
      }
      return { phase: 'joining' };
    }
    """

    private static let meetOpenChat = """
    async () => {
      const find = () => document.querySelector('textarea[aria-label*="message" i], textarea[aria-label*="chat" i]');
      if (!find()) { const b = buttonMatching(/chat with everyone|open chat|chat/i); if (b) b.click(); }
      for (let i = 0; i < 20 && !find(); i++) await new Promise(r => setTimeout(r, 150));
      const box = find();
      if (box) box.focus();
      return !!box;
    }
    """

    private static let teamsOpenChat = """
    async () => {
      const find = () => document.querySelector('[data-tid="ckeditor"], div[role="textbox"][contenteditable="true"]');
      if (!find()) { const b = document.querySelector('#chat-button, [data-tid="chat-button"]') || buttonMatching(/^chat/i); if (b) b.click(); }
      for (let i = 0; i < 20 && !find(); i++) await new Promise(r => setTimeout(r, 150));
      const box = find();
      if (box) box.focus();
      return !!box;
    }
    """
}
