import PartitiUI
import SwiftUI

/// Auto / Italian / English / Other (free ISO code), bound to one string:
/// "auto", "it", "en" or any other code. Drawn as rows of a settings group.
struct LanguagePicker: View {
    @Binding var language: String
    var label = "Language"
    @State private var choice = "auto"
    @State private var custom = ""

    private static let presets = ["auto", "it", "en"]

    var body: some View {
        Group {
            SettingsRow(Text(label)) {
                Picker(label, selection: $choice) {
                    Text("Auto-detect").tag("auto")
                    Text("Italian").tag("it")
                    Text("English").tag("en")
                    Divider()
                    Text("Other…").tag("other")
                }
                .labelsHidden()
                .fixedSize()
            }
            if choice == "other" {
                SettingsRow("Language code") {
                    TextField("Language code", text: $custom, prompt: Text("e.g. de, fr, es"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: choice) { _, _ in sync() }
        .onChange(of: custom) { _, _ in sync() }
    }

    private func load() {
        let v = language.lowercased()
        if Self.presets.contains(v) { choice = v } else { choice = "other"; custom = v }
    }

    private func sync() {
        let value: String
        if choice == "other" {
            let code = custom.trimmingCharacters(in: .whitespaces).lowercased()
            value = code.isEmpty ? "auto" : code
        } else {
            value = choice
        }
        if value != language { language = value }
    }

    /// The language the system speech recognizer uses for a setting: it can't detect one,
    /// so "auto" is the Mac's language.
    static func recognizerName(_ code: String) -> String {
        guard AppSettings.normalizedLanguage(code) == "auto" else { return displayName(code) }
        let system = Locale.current.language.languageCode.flatMap { Locale.current.localizedString(forLanguageCode: $0.identifier) }
        return system.map { "Your Mac's language (\($0))" } ?? "Your Mac's language"
    }

    /// Short display name for a language setting.
    static func displayName(_ code: String) -> String {
        switch code {
        case "auto", "": return "Auto-detect"
        case "it": return "Italian"
        case "en": return "English"
        default:
            return Locale.current.localizedString(forLanguageCode: code) ?? code.uppercased()
        }
    }
}
