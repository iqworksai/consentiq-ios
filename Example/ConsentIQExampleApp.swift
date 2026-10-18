import SwiftUI
import ConsentIQ

#if DEBUG
private let debugLogging = true
#else
private let debugLogging = false
#endif

@main
struct ConsentIQExampleApp: App {
    init() {
        ConsentIQ.shared.configure(ConsentIQConfig(
            propertyKey: "YOUR_IOS_PROPERTY_KEY",
            debug: debugLogging,
            onConsentChange: { consent, marketing in
                print("Consent changed:", consent, marketing)
            },
            onAccept: { outcome in print("Accepted:", outcome.consent) },
            onReject: { outcome in print("Rejected:", outcome.consent) },
            onSave: { outcome in print("Saved:", outcome.consent) },
            onClose: { print("Sheet dismissed without a choice") }
        ))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .consentSheet()
        }
    }
}
