import KaikuCore
import PartitiUI
import SwiftUI

/// The Summary tab of the live window: bullets that grow with the call.
struct LiveSummaryTab: View {
    @ObservedObject var assistant: LiveAssistant
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ink = Ink(scheme)
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: PUI.Space.l) {
                    if assistant.bullets.isEmpty {
                        if let provider = assistant.missingKeyProvider {
                            MissingKeyNote(provider: provider)
                        } else {
                            LiveEmptyState(symbol: "list.bullet.rectangle",
                                           text: assistant.isSummarizing ? "Writing the summary…" : "The summary starts after the first minute of talk.",
                                           animated: assistant.isSummarizing)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: PUI.Space.m) {
                            ForEach(Array(assistant.bullets.enumerated()), id: \.offset) { _, bullet in
                                HStack(alignment: .firstTextBaseline, spacing: PUI.Space.m) {
                                    Circle()
                                        .fill(AppAccent.kaiku.legible(scheme))
                                        .frame(width: 5, height: 5)
                                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 1 }
                                    Text((try? AttributedString(markdown: bullet)) ?? AttributedString(bullet))
                                        .lineSpacing(2)
                                        .foregroundStyle(ink.primary)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .font(PUI.Font.body)
                        .textSelection(.enabled)
                    }
                    AssistNotice(text: assistant.summaryError)
                }
                .padding(.horizontal, PUI.Space.xl)
                .padding(.vertical, PUI.Space.l)
            }
            Hairline()
            HStack(spacing: PUI.Space.s) {
                if assistant.isSummarizing {
                    ProgressView().controlSize(.mini)
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
            .padding(.horizontal, PUI.Space.l)
            .padding(.vertical, PUI.Space.m)
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
        let accent = AppAccent.kaiku.legible(scheme)
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: PUI.Space.xl) {
                        if assistant.exchanges.isEmpty {
                            if let provider = assistant.missingKeyProvider {
                                MissingKeyNote(provider: provider)
                            } else {
                                LiveEmptyState(symbol: "text.bubble",
                                               text: "Ask anything about the call so far. Answers come only from the transcript.")
                            }
                        }
                        ForEach(assistant.exchanges) { exchange in
                            VStack(alignment: .leading, spacing: PUI.Space.s) {
                                // The question as a bubble on the right, the answer under it.
                                Text(exchange.question)
                                    .font(PUI.Font.body.weight(.medium))
                                    .foregroundStyle(ink.primary)
                                    .padding(.horizontal, PUI.Space.l)
                                    .padding(.vertical, PUI.Space.s + 1)
                                    .puiSurface(radius: PUI.Radius.group, tint: accent, elevated: false)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                    .padding(.leading, PUI.Space.xxl)
                                if let answer = exchange.answer {
                                    Text(answer)
                                        .font(PUI.Font.body)
                                        .lineSpacing(2)
                                        .foregroundStyle(answer == LiveAssist.notMentioned ? ink.secondary : ink.primary)
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
                    .padding(.horizontal, PUI.Space.xl)
                    .padding(.vertical, PUI.Space.l)
                }
                .onChange(of: assistant.exchanges) { _, _ in proxy.scrollTo(Self.end, anchor: .bottom) }
            }
            Hairline()
            HStack(spacing: PUI.Space.s) {
                TextField("Ask about the call", text: $question)
                    .textFieldStyle(.plain)
                    .font(PUI.Font.body)
                    .focused($focused)
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 20))
                }
                .buttonStyle(.plain)
                .foregroundStyle(canSend ? accent : ink.quaternary)
                .disabled(!canSend)
                .help("Ask")
            }
            .padding(.leading, PUI.Space.l)
            .padding(.trailing, PUI.Space.xs)
            .frame(height: PUI.Control.regular + 4)
            .puiSurface(radius: (PUI.Control.regular + 4) / 2, elevated: false)
            .padding(PUI.Space.m)
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

    var body: some View {
        LiveEmptyState(symbol: "key", text: "Summary and Ask use \(provider.displayName). \(provider.problem ?? "")") {
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
