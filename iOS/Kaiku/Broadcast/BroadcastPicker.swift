import ReplayKit
import SwiftUI

/// The system button that starts the broadcast extension, with a note about its limits.
struct BroadcastPicker: View {
    var body: some View {
        VStack(spacing: 6) {
            Representable().frame(width: 52, height: 52)
            Text("Experimental: some call apps block audio capture")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal)
    }

    private struct Representable: UIViewRepresentable {
        func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
            let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 52, height: 52))
            picker.preferredExtension = "com.gabrielepartiti.kaiku.ios.broadcast"
            picker.showsMicrophoneButton = true
            return picker
        }

        func updateUIView(_ picker: RPSystemBroadcastPickerView, context: Context) {}
    }
}
