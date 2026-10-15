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

/// Drives the Google Meet, Microsoft Teams, Webex and FaceTime web pages through DevTools. The pages are
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
        let value = try await devTools.evaluate(Self.call(stepScript, args)) as? [String: Any] ?? [:]
        // Name fields want real typing on every site.
        if let text = value["type"] as? String {
            try await devTools.insertText(text)
        } else if value["typeName"] as? Bool == true {
            try await devTools.insertText(name)
        }
        let phase = MeetingPageState.Phase(rawValue: value["phase"] as? String ?? "") ?? .joining
        return MeetingPageState(phase: phase, participants: value["participants"] as? Int, detail: value["detail"] as? String)
    }

    private var stepScript: String {
        switch platform {
        case .meet: return Self.meetStep
        case .teams: return Self.teamsStep
        case .webex: return Self.webexStep
        case .faceTime: return Self.faceTimeStep
        }
    }

    var hasChat: Bool { platform != .faceTime }

    /// Posts a message in the meeting chat. True once the box emptied, i.e. it was sent.
    func sendChat(_ devTools: CDPClient, _ message: String) async -> Bool {
        let open: String
        switch platform {
        case .meet: open = Self.meetOpenChat
        case .teams: open = Self.teamsOpenChat
        case .webex: open = Self.webexOpenChat
        case .faceTime: return false
        }
        do {
            guard try await devTools.evaluate(Self.call(open)) as? Bool == true else {
                Log.app.error("Meeting bot: chat box not found")
                return false
            }
            try await devTools.insertText(message)
            try await Task.sleep(nanoseconds: 300_000_000)
            // The send button where there is one: Enter doesn't send in every editor.
            if try await devTools.evaluate(Self.call(Self.clickSend)) as? Bool != true {
                try await devTools.pressEnter()
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let left = try await devTools.evaluate(Self.call(Self.chatBoxText)) as? String ?? ""
            if left.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
            // Emptied, so a retry doesn't type the message twice.
            _ = try? await devTools.evaluate(Self.call(Self.clearChatBox))
            Log.app.error("Meeting bot: chat message typed but not sent")
        } catch {
            Log.app.error("Meeting bot: chat message not sent: \(error.diagnosticDescription, privacy: .public)")
        }
        return false
    }

    func leave(_ devTools: CDPClient) async {
        let script = "() => { const b = button(/^(leave call|leave meeting|leave|hang up|end)$/i); if (b) b.click(); return !!b }"
        _ = try? await devTools.evaluate(Self.call(script))
    }

    // MARK: Scripts

    /// `fn` called with `args`, next to the helpers every script uses.
    static func call(_ fn: String, _ args: String = "") -> String {
        "(async () => {\n\(helpers)\nreturn await (\(fn))(\(args));\n})()"
    }

    /// Find visible buttons by label or text, in the page and its same-site frames (Webex
    /// runs in one). `__k` keeps state between calls.
    private static let helpers = """
    window.__k = window.__k || {};
    const docs = () => [document, ...[...document.querySelectorAll('iframe')]
      .map(f => { try { return f.contentDocument } catch (e) { return null } }).filter(Boolean)];
    const q = sel => docs().map(d => d.querySelector(sel)).find(Boolean);
    const qa = sel => docs().flatMap(d => [...d.querySelectorAll(sel)]);
    const visible = e => !!(e && (e.offsetWidth || e.offsetHeight || e.getClientRects().length));
    const label = e => [e.getAttribute('aria-label'), e.getAttribute('data-tooltip'), e.getAttribute('title'), e.innerText]
      .filter(Boolean).join(' ').trim();
    const button = re => qa('button, [role=button], a')
      .find(e => visible(e) && !e.disabled && re.test(label(e).split('\\n')[0].trim()));
    const buttonMatching = re => qa('button, [role=button]')
      .find(e => visible(e) && !e.disabled && re.test(label(e)));
    const pageText = () => docs().map(d => d.body ? d.body.innerText : '').join('\\n');
    const chatBox = () => q('textarea[aria-label*="message" i], textarea[placeholder*="message" i], textarea[aria-label*="chat" i], [data-tid="ckeditor"], div[role="textbox"][contenteditable="true"]');
    const field = re => qa('input').find(e => visible(e) && re.test((e.getAttribute('aria-label') || '') + ' ' + (e.placeholder || '') + ' ' + (e.name || '')));
    """

    private static let meetStep = """
    ({ name, camera }) => {
      const text = pageText();
      if (/you left the meeting|you've been removed|you have been removed|the call has ended|meeting has ended|return to home screen|you can't join this video call|denied your request|no one responded to your request/i.test(text))
        return { phase: 'ended', detail: text.split('\\n').find(l => /left|removed|ended|can't join|denied|responded/i.test(l)) };
      if (buttonMatching(/leave call/i)) {
        // The number on the People button counts everyone; the tiles only who fits on screen.
        const people = buttonMatching(/show everyone|^people|participants/i);
        const count = people ? parseInt(((people.innerText || '').match(/\\d+/) || [])[0], 10) : NaN;
        const ids = new Set([...document.querySelectorAll('[data-participant-id]')].map(e => e.getAttribute('data-participant-id')));
        return { phase: 'inCall', participants: count > 0 ? count : (ids.size || null) };
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

    private static let webexStep = """
    ({ name, camera }) => {
      const text = pageText();
      if (/the meeting has ended|meeting has ended|you've left the meeting|you have left the meeting|you've been removed|you were removed|the host has removed you|denied your request|the host has locked/i.test(text))
        return { phase: 'ended', detail: text.split('\\n').find(l => /ended|left|removed|denied|locked/i.test(l)) };
      if (buttonMatching(/leave meeting|^leave$/i)) {
        const people = buttonMatching(/participants/i);
        const count = people ? parseInt((label(people).match(/\\d+/) || [])[0], 10) : NaN;
        return { phase: 'inCall', participants: Number.isFinite(count) ? count : null };
      }
      if (/the host will let you in soon|waiting for the host|you're in the lobby|you are in the lobby|the meeting hasn't started|the meeting has not started/i.test(text)) return { phase: 'lobby' };
      const browser = button(/join from (your |this )?browser|join from browser|use the web app/i);
      if (browser) { browser.click(); return { phase: 'joining' }; }
      const ok = button(/^(accept|accept all|got it|ok|dismiss)$/i);
      if (ok) { ok.click(); return { phase: 'joining' }; }
      const nameField = field(/name/i);
      if (nameField && !nameField.value) { nameField.focus(); return { phase: 'joining', typeName: true }; }
      // Webex asks guests for an email; a reserved address keeps yours private.
      const mail = field(/mail/i);
      if (mail && !mail.value) { mail.focus(); return { phase: 'joining', type: 'notetaker@example.com' }; }
      const next = button(/^(next|continue)$/i);
      if (next) { next.click(); return { phase: 'joining' }; }
      const mic = buttonMatching(/^mute\\b|mute audio|mute microphone/i);
      if (mic && !/unmute/i.test(label(mic))) mic.click();
      const cam = buttonMatching(camera ? /start video|turn on video/i : /stop video|turn off video/i);
      if (cam) cam.click();
      if (!window.__k.joined) {
        const join = button(/^(join meeting|join now|join)$/i);
        if (join) { window.__k.joined = true; join.click(); }
      }
      return { phase: 'joining' };
    }
    """

    private static let faceTimeStep = """
    ({ name, camera }) => {
      const text = pageText();
      if (/you left the call|call ended|the call has ended|your request to join was declined|you were removed|link is no longer valid/i.test(text))
        return { phase: 'ended', detail: text.split('\\n').find(l => /left|ended|declined|removed|no longer/i.test(l)) };
      if (/waiting to be let in|waiting for someone to let you in|waiting to join|asking to join/i.test(text)) return { phase: 'lobby' };
      if (buttonMatching(/^leave$|leave call|end call/i)) return { phase: 'inCall', participants: null };
      const nameField = field(/name/i);
      if (nameField && !nameField.value) { nameField.focus(); return { phase: 'joining', typeName: true }; }
      const next = button(/^(continue|next)$/i);
      if (next) { next.click(); return { phase: 'joining' }; }
      const mic = buttonMatching(/^mute$|turn microphone off|microphone off/i);
      if (mic) mic.click();
      const cam = buttonMatching(camera ? /turn camera on|camera on/i : /turn camera off|camera off/i);
      if (cam) cam.click();
      if (!window.__k.joined) {
        const join = button(/^(join|join call|join now)$/i);
        if (join) { window.__k.joined = true; join.click(); }
      }
      return { phase: 'joining' };
    }
    """

    private static let webexOpenChat = """
    async () => {
      const find = () => q('textarea[aria-label*="message" i], textarea[placeholder*="message" i], div[role="textbox"][contenteditable="true"]');
      if (!find()) { const b = buttonMatching(/^chat|open chat|show chat/i); if (b) b.click(); }
      for (let i = 0; i < 20 && !find(); i++) await new Promise(r => setTimeout(r, 150));
      const box = find();
      if (box) box.focus();
      return !!box;
    }
    """

    private static let clickSend = """
    () => {
      const b = q('[data-tid="newMessageCommands-send"]') || buttonMatching(/^send( a)? message|^send$/i);
      if (b && !b.disabled && b.getAttribute('aria-disabled') !== 'true') { b.click(); return true; }
      return false;
    }
    """

    private static let chatBoxText = """
    () => { const b = chatBox(); return b ? (b.tagName === 'TEXTAREA' ? b.value : b.innerText) : ''; }
    """

    private static let clearChatBox = """
    () => {
      const b = chatBox();
      if (!b) return false;
      b.focus();
      if (b.tagName === 'TEXTAREA') {
        Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value').set.call(b, '');
        b.dispatchEvent(new Event('input', { bubbles: true }));
      } else {
        b.ownerDocument.execCommand('selectAll');
        b.ownerDocument.execCommand('delete');
      }
      return true;
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
