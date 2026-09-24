import SwiftUI
import KaikuCore

/// Small capsule showing one tag, with an optional remove button.
struct TagCapsule: View {
    let tag: String
    var compact = false
    var remove: (() -> Void)?

    var body: some View {
        HStack(spacing: 3) {
            Text(tag).lineLimit(1)
            if let remove {
                Button(action: remove) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Remove tag \(tag)")
            }
        }
        .font(compact ? .caption2.weight(.medium) : .caption.weight(.medium))
        .padding(.horizontal, compact ? 6 : 8)
        .padding(.vertical, compact ? 1 : 3)
        .background(.quaternary, in: Capsule())
        .foregroundStyle(.primary.opacity(0.85))
    }
}

/// Token-style tag input: type, then Enter or Tab to add. Suggestions come from tags
/// used before (most recent first); arrow keys pick one, Backspace in the empty field
/// removes the last tag. Enter on an empty field calls `onSubmitEmpty`.
struct TagField: View {
    @Binding var tags: [String]
    let known: [String]
    /// Offered as a one-click chip when no tag is set yet.
    var lastUsed: [String] = []
    var placeholder = "Add tag"
    var onSubmitEmpty: (() -> Void)?

    @State private var text = ""
    @State private var highlight = -1
    @FocusState private var focused: Bool

    private var suggestions: [String] {
        Tags.suggestions(for: text, known: known, excluding: tags, limit: 6)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FlowLayout(spacing: 5) {
                ForEach(tags, id: \.self) { tag in
                    TagCapsule(tag: tag) { tags.removeAll { $0 == tag } }
                }
                TextField(placeholder, text: $text, prompt: Text(tags.isEmpty ? placeholder : ""))
                    .textFieldStyle(.plain)
                    .frame(minWidth: 90)
                    .focused($focused)
                    .onSubmit {
                        if text.trimmingCharacters(in: .whitespaces).isEmpty && highlight < 0 {
                            onSubmitEmpty?()
                        } else {
                            accept()
                        }
                    }
                    .onKeyPress(.tab) {
                        guard !text.trimmingCharacters(in: .whitespaces).isEmpty || highlight >= 0 else { return .ignored }
                        accept()
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        guard !suggestions.isEmpty else { return .ignored }
                        highlight = min(highlight + 1, suggestions.count - 1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        guard highlight >= 0 else { return .ignored }
                        highlight -= 1
                        return .handled
                    }
                    .onKeyPress(.delete) {
                        guard text.isEmpty, !tags.isEmpty else { return .ignored }
                        tags.removeLast()
                        return .handled
                    }
                    .onChange(of: text) { _, v in
                        highlight = -1
                        if v.hasSuffix(",") { text = String(v.dropLast()); accept() }
                    }
                    .accessibilityLabel("Tags")
            }

            if focused && !suggestions.isEmpty && !(text.isEmpty && tags.isEmpty && !lastUsed.isEmpty) {
                HStack(spacing: 5) {
                    Image(systemName: "tag").font(.caption2).foregroundStyle(.tertiary)
                    ForEach(Array(suggestions.enumerated()), id: \.element) { i, tag in
                        Button { add(tag) } label: {
                            Text(tag)
                                .font(.caption)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(i == highlight ? AnyShapeStyle(Brand.accent.opacity(0.2)) : AnyShapeStyle(.quaternary.opacity(0.6)),
                                            in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else if tags.isEmpty && text.isEmpty && !lastUsed.isEmpty {
                HStack(spacing: 5) {
                    Text("Last used:").font(.caption).foregroundStyle(.secondary)
                    Button { tags = Tags.normalize(lastUsed) } label: {
                        Text(lastUsed.joined(separator: ", "))
                            .font(.caption)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(.quaternary.opacity(0.6), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Use the same tags as last time")
                }
            }
        }
    }

    private func accept() {
        if highlight >= 0, highlight < suggestions.count {
            add(suggestions[highlight])
        } else {
            add(text)
        }
    }

    private func add(_ tag: String) {
        tags = Tags.normalize(tags + [tag])
        text = ""
        highlight = -1
        focused = true
    }
}
