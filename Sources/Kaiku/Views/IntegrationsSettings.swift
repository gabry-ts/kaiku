import PartitiUI
import SwiftUI

/// Settings > Integrations: where what comes out of a call goes, to other apps and agents.
struct IntegrationsSettings: View {
    var body: some View {
        KaikuPane(pane: .integrations, subtitle: "Send what comes out of your calls to other apps and agents.") {
            ActionItemsSettings()
            WebhookSettings()
            AgentSettings()
        }
    }
}
