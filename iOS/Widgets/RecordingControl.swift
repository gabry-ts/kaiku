import AppIntents
import SwiftUI
import WidgetKit

/// Control Center toggle that starts and stops a recording.
struct RecordingControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.gabrielepartiti.kaiku.ios.recording", provider: Provider()) { isOn in
            ControlWidgetToggle(isOn: isOn, action: ToggleRecordingIntent()) {
                Label("Record", systemImage: isOn ? "stop.fill" : "mic.fill")
            } valueLabel: { isOn in
                Text(isOn ? "Recording" : "Off")
            }
        }
        .displayName("Record")
        .description("Start or stop a recording.")
    }

    struct Provider: ControlValueProvider {
        let previewValue = false

        func currentValue() async throws -> Bool {
            AppGroup.defaults.bool(forKey: AppGroup.isRecordingKey)
        }
    }
}
