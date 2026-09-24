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

    var body: some View {
        Form {
            Section {
                Toggle("Send a webhook when a transcript is ready", isOn: $enabled)
            } footer: {
                Text("Pushes the transcript to Zapier, Make, n8n, your own server or anything that accepts HTTP.")
            }

            Section("Request") {
                LabeledContent("URL") {
                    HStack(spacing: 6) {
                        TextField("URL", text: $url, prompt: Text("https://example.com/hook"))
                            .labelsHidden().textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.leading)
                        if !url.isEmpty {
                            Image(systemName: urlIsValid ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                .foregroundStyle(urlIsValid ? .green : .orange)
                                .help(urlIsValid ? "Looks good" : "Use a full http(s):// URL")
                        }
                    }
                }
                Picker("Method", selection: $method) {
                    ForEach(["POST", "PUT", "PATCH"], id: \.self) { Text($0) }
                }
                .pickerStyle(.segmented)
            }
            .disabled(!enabled)

            Section {
                if headers.isEmpty {
                    Text("No custom headers").foregroundStyle(.secondary)
                }
                ForEach($headers) { $h in
                    HStack(spacing: 8) {
                        TextField("Name", text: $h.name, prompt: Text("Authorization"))
                            .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 170)
                        SecureField("Value", text: $h.value, prompt: Text("Bearer …"))
                            .labelsHidden().textFieldStyle(.roundedBorder)
                        Button { withAnimation { headers.removeAll { $0.id == h.id } } } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove header")
                    }
                }
                HStack {
                    Button { withAnimation { headers.append(Header(name: "", value: "")) } } label: {
                        Label("Add Header", systemImage: "plus")
                    }
                    Spacer()
                    Label("Values are saved in your Keychain", systemImage: "lock.fill")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Headers")
            }
            .disabled(!enabled)

            Section {
                Picker("Body", selection: $bodyMode) {
                    Text("Default JSON").tag("default")
                    Text("Custom Template").tag("template")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if bodyMode == "template" {
                    TextField("Content-Type", text: $contentType, prompt: Text("application/json"))
                    TextEditor(text: $template)
                        .font(.system(.callout, design: .monospaced))
                        .frame(minHeight: 130)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(.background, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Click to insert").font(.caption).foregroundStyle(.secondary)
                        FlowLayout(spacing: 6) {
                            ForEach(WebhookTemplate.placeholders, id: \.self) { name in
                                Button { template += "{{\(name)}}" } label: {
                                    Text("{{\(name)}}").font(.caption.monospaced())
                                        .padding(.horizontal, 7).padding(.vertical, 3)
                                        .background(.quaternary, in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            } header: {
                Text("Body")
            } footer: {
                if bodyMode == "template" {
                    Text("With a JSON content type, text values are escaped for you, so write \"{{title}}\" inside quotes. *_json and duration_seconds are inserted as raw JSON.")
                } else {
                    Text("Title, date, duration, language, provider, tags, file paths, the full transcript in Markdown, every segment with speaker and timestamps, bookmarks, the summary (if any) and the estimated cost.")
                }
            }
            .disabled(!enabled)

            Section {
                HStack(spacing: 10) {
                    Button {
                        testing = true
                        testResult = nil
                        Task {
                            let text = await AppState.shared.testWebhook()
                            withAnimation { testResult = (text.hasPrefix("HTTP 2"), text); testing = false }
                        }
                    } label: {
                        Label("Send Test", systemImage: "paperplane")
                    }
                    .disabled(testing || !urlIsValid)
                    if testing { ProgressView().controlSize(.small) }
                    Spacer()
                    Text("Uses your last recording, or sample data.").font(.caption).foregroundStyle(.secondary)
                }
                if let testResult {
                    VStack(alignment: .leading, spacing: 4) {
                        StatusDot(kind: testResult.ok ? .ok : .error,
                                  text: testResult.text.components(separatedBy: "\n").first ?? "")
                        let rest = testResult.text.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
                        if !rest.isEmpty {
                            Text(rest).font(.caption.monospaced()).foregroundStyle(.secondary)
                                .lineLimit(6).textSelection(.enabled)
                        }
                    }
                }
            }
            .disabled(!enabled)
        }
        .formStyle(.grouped)
        .onAppear {
            headers = AppSettings.webhookHeaders.map { Header(name: $0.name, value: $0.value) }
        }
        .onChange(of: headers.map { "\($0.name)\u{0}\($0.value)" }) { _, _ in
            AppSettings.webhookHeaders = headers.map { ($0.name, $0.value) }
        }
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
