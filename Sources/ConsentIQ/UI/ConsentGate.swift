import SwiftUI

public struct ConsentGate<Content: View, Placeholder: View>: View {
    @ObservedObject private var consentIQ: ConsentIQ
    private let category: String
    private let placeholder: () -> Placeholder
    private let content: () -> Content

    public init(
        category: String,
        consentIQ: ConsentIQ = .shared,
        @ViewBuilder placeholder: @escaping () -> Placeholder,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.consentIQ = consentIQ
        self.category = category
        self.placeholder = placeholder
        self.content = content
    }

    public var body: some View {
        if consentIQ.hasConsent(category) {
            content()
        } else if consentIQ.isLoading {
            placeholder()
        }
    }
}

public extension ConsentGate where Placeholder == EmptyView {
    init(category: String, consentIQ: ConsentIQ = .shared, @ViewBuilder content: @escaping () -> Content) {
        self.init(category: category, consentIQ: consentIQ, placeholder: { EmptyView() }, content: content)
    }
}
