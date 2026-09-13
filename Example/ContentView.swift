import SwiftUI
import ConsentIQ

struct ContentView: View {
    @ObservedObject private var consentIQ = ConsentIQ.shared

    var body: some View {
        NavigationStack {
            List {
                Section("Status") {
                    LabeledContent("Loading", value: consentIQ.isLoading ? "Yes" : "No")
                    LabeledContent("Regulation", value: consentIQ.regulation ?? "None")
                    LabeledContent("Language", value: consentIQ.language)
                    LabeledContent("Property", value: consentIQ.config?.property.name ?? "Not loaded")
                }

                Section("Consent") {
                    ForEach(consentIQ.consent.keys.sorted(), id: \.self) { category in
                        LabeledContent(category, value: consentIQ.hasConsent(category) ? "Granted" : "Denied")
                    }
                }

                Section("Gated feature") {
                    ConsentGate(category: ConsentCategory.analytics, placeholder: { ProgressView() }) {
                        Label("Analytics tracker running", systemImage: "chart.bar")
                    }
                    if !consentIQ.isLoading, !consentIQ.hasConsent(ConsentCategory.analytics) {
                        Text("Analytics is off. Open preferences to change it.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Actions") {
                    Button("Open consent preferences") { consentIQ.showSheet() }
                    Button("Grant marketing") { consentIQ.updateConsent([ConsentCategory.marketing: true]) }
                    Button("Reset consent", role: .destructive) { consentIQ.resetConsent() }
                }
            }
            .navigationTitle("ConsentIQ Example")
        }
    }
}

#Preview {
    ContentView()
}
