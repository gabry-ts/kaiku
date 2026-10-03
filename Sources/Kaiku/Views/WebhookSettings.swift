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
            ? "Text values are escaped for JSON, so write \"{{title}}\" inside quotes."
            : "Title, date, tags, transcript, segments, bookmarks, summary and cost."
    }

    @State private var showOptions = false
    @ObservedObject private var nav = AppNavigation.shared
    private static let optionAnchors: Set<String> = ["requestOptions", "headers"]

    var body: some View {
        SettingsGroup("Webhook", footer: "Works with Zapier, Make, n8n or your own server.") {
            SwitchRow("Send a webhook when a transcript is ready", isOn: $enabled)
            if enabled {
                SettingsRow("URL") {
                    HStack(spacing: PUI.Space.s) {
                        TextField("URL", text: $url, prompt: Text("https://example.com/hook"))
                            .labelsHidden().textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: 320)
                        if !url.isEmpty {
                            Image(systemName: urlIsValid ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                .foregroundStyle(urlIsValid ? .green : .orange)
                                .help(urlIsValid ? "Looks good" : "Enter a full https:// address")
                        }
                    }
                }
                GroupRow {
                    VStack(alignment: .leading, spacing: PUI.Space.xs) {
                        HStack(spacing: PUI.Space.m) {
                            Button {
                                testing = true
                                testResult = nil
                                Task {
                                    let text = await AppState.shared.testWebhook()
                                    testResult = (text.hasPrefix("HTTP 2"), text)
                                    testing = false
                                }
                            } label: {
                                Label("Send Test", systemImage: "paperplane").labelStyle(TightLabelStyle())
                            }
                            .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
                            .disabled(testing || !urlIsValid)
                            if testing { ProgressView().controlSize(.small) }
                            Spacer()
                            Text(urlIsValid ? "Uses your last call, or sample data." : "Enter a full https:// address")
                                .font(PUI.Font.caption).foregroundStyle(.secondary)
                        }
                        if let testResult {
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
                DisclosureRow(title: "Request Options", detail: "\(method) · \(bodyMode == "template" ? "Custom template" : "Default JSON")",
                              isOpen: $showOptions)
                    .help(bodyFooter)
                    .settingsAnchor("requestOptions")
                if showOptions {
                    SettingsRow("Method") {
                        SegmentedPill(["POST", "PUT", "PATCH"].map { (value: $0, title: $0) }, selection: $method)
                            .fixedSize()
                    }
                    ForEach($headers) { $h in
                        GroupRow {
                            HStack(spacing: PUI.Space.m) {
                                TextField("Name", text: $h.name, prompt: Text("Authorization"))
                                    .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 170)
                                SecureField("Value", text: $h.value, prompt: Text("Bearer …"))
                                    .labelsHidden().textFieldStyle(.roundedBorder)
                                Button { headers.removeAll { $0.id == h.id } } label: {
                                    Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove header")
                            }
                        }
                    }
                    GroupRow {
                        HStack {
                            Button { headers.append(Header(name: "", value: "")) } label: {
                                Label("Add Header", systemImage: "plus").labelStyle(TightLabelStyle())
                            }
                            .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
                            Spacer()
                            Label("Header values are saved in your Keychain", systemImage: "lock.fill")
                                .font(PUI.Font.caption).foregroundStyle(.secondary)
                        }
                    }
                    .settingsAnchor("headers")
                    SettingsRow(Text("Body"), subtitle: Text(bodyFooter)) {
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
            }
        }
        .settingsAnchor("webhook")
        .onAppear {
            headers = AppSettings.webhookHeaders.map { Header(name: $0.name, value: $0.value) }
            if nav.wants(Self.optionAnchors, in: .integrations) { showOptions = true }
        }
        .onChange(of: nav.request) { _, _ in if nav.wants(Self.optionAnchors, in: .integrations) { showOptions = true } }
        .onChange(of: headers.map { "\($0.name)\u{0}\($0.value)" }) { _, _ in
            AppSettings.webhookHeaders = headers.map { ($0.name, $0.value) }
        }
    }
}

/// A row that shows or hides the rows after it, with a short summary of what they hold.
struct DisclosureRow: View {
    let title: String
    var detail: String?
    @Binding var isOpen: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ink = Ink(scheme)
        Button { isOpen.toggle() } label: {
            HStack(spacing: PUI.Space.s) {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(ink.tertiary)
                    .frame(width: 12)
                Text(title).font(PUI.Font.body).foregroundStyle(ink.primary)
                Spacer()
                if let detail { Text(detail).font(PUI.Font.callout).foregroundStyle(ink.secondary) }
            }
            .padding(.horizontal, PUI.Space.l)
            .frame(minHeight: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOpen ? "Shown" : "Hidden")
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
        .onHover { hover = $0 }
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
