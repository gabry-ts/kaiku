import KaikuCore
import PartitiUI
import SwiftUI

/// The Summary tab of the live window: bullets that grow with the call.
struct LiveSummaryTab: View {
    @ObservedObject var assistant: LiveAssistant
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ink = Ink(scheme)
        ScrollView {
            VStack(alignment: .leading, spacing: PUI.Space.l) {
                if assistant.bullets.isEmpty {
                    if let provider = assistant.missingKeyProvider {
                        MissingKeyNote(provider: provider)
                    } else {
                        Text(assistant.isSummarizing ? "Writing the summary…" : "The summary starts after the first minute of talk.")
                            .font(PUI.Font.callout).foregroundStyle(ink.tertiary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: PUI.Space.s) {
                        ForEach(Array(assistant.bullets.enumerated()), id: \.offset) { _, bullet in
                            HStack(alignment: .firstTextBaseline, spacing: PUI.Space.s) {
                                Text("•").foregroundStyle(ink.secondary)
                                Text((try? AttributedString(markdown: bullet)) ?? AttributedString(bullet))
                                    .foregroundStyle(ink.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .font(PUI.Font.callout)
                    .textSelection(.enabled)
                }
                AssistNotice(text: assistant.summaryError)
                HStack(spacing: PUI.Space.s) {
                    if assistant.isSummarizing {
                        ProgressView().controlSize(.small)
                        Text("Updating…")
                    } else if let updated = assistant.summaryUpdated {
                        Text("Updated \(updated, style: .relative) ago")
                    }
                    Spacer()
                    Button("Update Now") { assistant.summarize() }
                        .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
                        .disabled(assistant.isSummarizing)
                        .help("Add what was said since the last update")
                }
                .font(PUI.Font.caption)
                .foregroundStyle(ink.tertiary)
            }
            .padding(PUI.Space.xl)
        }
    }
}

/// The Ask tab of the live window: questions answered from the transcript so far.
struct LiveAskTab: View {
    @ObservedObject var assistant: LiveAssistant
    @State private var question = ""
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var scheme

    private static let end = "end"

    var body: some View {
        let ink = Ink(scheme)
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: PUI.Space.l) {
                        if assistant.exchanges.isEmpty {
                            if let provider = assistant.missingKeyProvider {
                                MissingKeyNote(provider: provider)
                            } else {
                                Text("Ask anything about the call so far. Answers come only from the transcript.")
                                    .font(PUI.Font.callout).foregroundStyle(ink.tertiary)
                            }
                        }
                        ForEach(assistant.exchanges) { exchange in
                            VStack(alignment: .leading, spacing: PUI.Space.xs) {
                                Text(exchange.question)
                                    .font(PUI.Font.headline)
                                    .foregroundStyle(AppAccent.kaiku.legible(scheme))
                                if let answer = exchange.answer {
                                    Text(answer).font(PUI.Font.callout).foregroundStyle(ink.primary)
                                } else {
                                    ProgressView().controlSize(.small)
                                }
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                        }
                        AssistNotice(text: assistant.askError)
                        Color.clear.frame(height: 1).id(Self.end)
                    }
                    .padding(PUI.Space.xl)
                }
                .onChange(of: assistant.exchanges) { _, _ in proxy.scrollTo(Self.end, anchor: .bottom) }
            }
            Divider()
            HStack(spacing: PUI.Space.s) {
                TextField("Ask about the call", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppAccent.kaiku.legible(scheme))
                .disabled(!canSend)
                .help("Ask")
            }
            .padding(PUI.Space.l)
        }
        .onAppear { focused = true }
    }

    private var canSend: Bool {
        !assistant.isAsking && !question.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func send() {
        guard canSend else { return }
        assistant.ask(question)
        question = ""
    }
}

/// What the live tabs' provider still needs, with a way to set it up.
private struct MissingKeyNote: View {
    let provider: SummaryProviderKind
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: PUI.Space.m) {
            Text("Summary and Ask use \(provider.displayName). \(provider.problem ?? "")")
                .font(PUI.Font.callout).foregroundStyle(Ink(scheme).secondary)
            Button("Open Settings") { WindowManager.shared.showSettings(.live) }
                .buttonStyle(SecondaryButtonStyle(height: PUI.Control.small))
        }
    }
}

/// Why the last request failed; what was there stays.
private struct AssistNotice: View {
    let text: String?

    var body: some View {
        if let text {
            Inked { ink in
                HStack(alignment: .firstTextBaseline, spacing: PUI.Space.s) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(ink.orange)
                    Text(text).foregroundStyle(ink.secondary).lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(PUI.Font.caption)
            }
            .help(text)
        }
    }
}
