import PartitiUI
import SwiftUI
import KaikuCore

/// Webhook URL, method, headers (values in Keychain), body mode and a test button.
struct WebhookSettings: View {
    @AppStorage(Keys.webhookEnabled) private var enabled = false
    @AppStorage(Keys.webhookURL) private var url = ""
    @AppStorage(Keys.webhookMethod) private var method = "POST"
    @AppStorage(Keys.webhookBodyMode) private var bodyMode = "default"
    @AppStorage(Keys.webhookTemplate) private var template = ""
    @AppStorage(Keys.webhookContentType) private var contentType = "application/json"

    private struct Header: Identifiable { let id = UUID(); var name: String; var value: String }
    @State private var headers: [Header] = []
    @State private var testResult: (ok: Bool, text: String)?
    @State private var testing = false

    private var urlIsValid: Bool {
        guard let u = URL(string: url.trimmingCharacters(in: .whitespaces)), let s = u.scheme?.lowercased() else { return false }
        return (s == "http" || s == "https") && u.host != nil
    }

    private var bodyFooter: String {
        bodyMode == "template"
            ? "With a JSON content type, text values are escaped for you, so write \"{{title}}\" inside quotes. *_json and duration_seconds are inserted as raw JSON."
            : "Title, date, duration, language, provider, tags, file paths, the full transcript in Markdown, every segment with speaker and timestamps, bookmarks, the summary (if any) and the estimated cost."
    }

    var body: some View {
        KaikuPane(pane: .webhook, subtitle: "Send each transcript to another app or your own server.") {
            SettingsGroup(footer: "Pushes the transcript to Zapier, Make, n8n, your own server or anything that accepts HTTP.") {
                SwitchRow("Send a webhook when a transcript is ready", isOn: $enabled)
            }

            SettingsGroup("Request") {
                SettingsRow("URL") {
                    HStack(spacing: PUI.Space.s) {
                        TextField("URL", text: $url, prompt: Text("https://example.com/hook"))
                            .labelsHidden().textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: 320)
                        if !url.isEmpty {
                            Image(systemName: urlIsValid ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                .foregroundStyle(urlIsValid ? .green : .orange)
                                .help(urlIsValid ? "Looks good" : "Use a full http(s):// URL")
                        }
                    }
                }
                SettingsRow("Method") {
                    SegmentedPill(["POST", "PUT", "PATCH"].map { (value: $0, title: $0) }, selection: $method)
                        .fixedSize()
                }
            }
            .disabled(!enabled)

            SettingsGroup("Headers") {
                if headers.isEmpty {
                    GroupRow { Text("No custom headers").font(PUI.Font.body).foregroundStyle(.secondary) }
                }
                ForEach($headers) { $h in
                    GroupRow {
                        HStack(spacing: PUI.Space.m) {
                            TextField("Name", text: $h.name, prompt: Text("Authorization"))
                                .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 170)
                            SecureField("Value", text: $h.value, prompt: Text("Bearer …"))
                                .labelsHidden().textFieldStyle(.roundedBorder)
                            Button { withAnimation { headers.removeAll { $0.id == h.id } } } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove header")
                        }
                    }
                }
                GroupRow {
                    HStack {
                        Button { withAnimation { headers.append(Header(name: "", value: "")) } } label: {
                            Label("Add Header", systemImage: "plus").labelStyle(TightLabelStyle())
                        }
                        .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
                        Spacer()
                        Label("Values are saved in your Keychain", systemImage: "lock.fill")
                            .font(PUI.Font.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(!enabled)

            SettingsGroup(Text("Body"), footer: Text(bodyFooter)) {
                GroupRow {
                    SegmentedPill([(value: "default", title: "Default JSON"), (value: "template", title: "Custom Template")],
                                  selection: $bodyMode)
                        .fixedSize()
                }
                if bodyMode == "template" {
                    SettingsRow("Content-Type") {
                        TextField("Content-Type", text: $contentType, prompt: Text("application/json"))
                            .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 220)
                    }
                    GroupRow {
                        VStack(alignment: .leading, spacing: PUI.Space.m) {
                            EditorField(text: $template)
                            Text("Click to insert").font(PUI.Font.caption).foregroundStyle(.secondary)
                            FlowLayout(spacing: PUI.Space.s) {
                                ForEach(WebhookTemplate.placeholders, id: \.self) { name in
                                    PlaceholderChip(name: name) { template += "{{\(name)}}" }
                                }
                            }
                        }
                    }
                }
            }
            .disabled(!enabled)

            SettingsGroup {
                GroupRow {
                    HStack(spacing: PUI.Space.m) {
                        Button {
                            testing = true
                            testResult = nil
                            Task {
                                let text = await AppState.shared.testWebhook()
                                withAnimation { testResult = (text.hasPrefix("HTTP 2"), text); testing = false }
                            }
                        } label: {
                            Label("Send Test", systemImage: "paperplane").labelStyle(TightLabelStyle())
                        }
                        .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
                        .disabled(testing || !urlIsValid)
                        if testing { ProgressView().controlSize(.small) }
                        Spacer()
                        Text("Uses your last recording, or sample data.").font(PUI.Font.caption).foregroundStyle(.secondary)
                    }
                }
                if let testResult {
                    GroupRow {
                        VStack(alignment: .leading, spacing: PUI.Space.xs) {
                            StatusDot(kind: testResult.ok ? .ok : .error,
                                      text: testResult.text.components(separatedBy: "\n").first ?? "")
                            let rest = testResult.text.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
                            if !rest.isEmpty {
                                Text(rest).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                                    .lineLimit(6).textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .disabled(!enabled)
        }
        .onAppear {
            headers = AppSettings.webhookHeaders.map { Header(name: $0.name, value: $0.value) }
        }
        .onChange(of: headers.map { "\($0.name)\u{0}\($0.value)" }) { _, _ in
            AppSettings.webhookHeaders = headers.map { ($0.name, $0.value) }
        }
    }
}

/// A template placeholder that inserts itself when clicked.
private struct PlaceholderChip: View {
    let name: String
    let insert: () -> Void
    @State private var hover = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ink = Ink(scheme)
        Button(action: insert) {
            Text("{{\(name)}}")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(ink.primary)
                .padding(.horizontal, PUI.Space.s + 1).padding(.vertical, 3)
                .background(Capsule().fill(hover ? ink.strongFill : ink.fill))
        }
        .buttonStyle(.plain)
        .onHover { inside in withAnimation(PUI.Motion.hover) { hover = inside } }
    }
}

/// Simple wrapping layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
