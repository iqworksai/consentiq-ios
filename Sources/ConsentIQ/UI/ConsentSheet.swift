#if canImport(UIKit)
import SwiftUI

public struct ConsentSheetContent: View {
    @ObservedObject private var consentIQ: ConsentIQ
    @State private var showCategories = false
    @State private var selection: SheetSelection?

    public init(consentIQ: ConsentIQ = .shared) {
        self.consentIQ = consentIQ
    }

    public var body: some View {
        if let config = consentIQ.config {
            sheet(config)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func sheet(_ config: PropertyConfig) -> some View {
        let language = consentIQ.language
        let labels = config.labels(for: language)
        let translations = config.translations(for: language)
        let primary = Color.consentPrimary(config.banner?.primaryColor)
        let cornerRadius: CGFloat = config.banner?.cornerStyle == "square" ? 4 : 12
        let noticeURL = config.banner?.noticeURL(language: language)

        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(labels.title)
                    .font(.title3.weight(.bold))
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let blurb = translations?.bannerDescription, !blurb.isEmpty {
                    Text(blurb)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let noticeURL {
                    Link(labels.viewNotice, destination: noticeURL)
                        .font(.subheadline.weight(.medium))
                        .tint(primary)
                }

                if showCategories {
                    categoryList(config, translations: translations, primary: primary)
                    Button {
                        commitSelection(config)
                    } label: {
                        Text(labels.save).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(FilledButtonStyle(color: primary, cornerRadius: cornerRadius))
                } else {
                    HStack(spacing: 8) {
                        Button {
                            consentIQ.acceptAll()
                        } label: {
                            Text(labels.acceptAll).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(FilledButtonStyle(color: primary, cornerRadius: cornerRadius))

                        Button {
                            consentIQ.rejectAll()
                        } label: {
                            Text(labels.reject).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(OutlinedButtonStyle(color: primary, cornerRadius: cornerRadius))
                    }
                }

                Button(labels.customize) {
                    toggleCategories(config)
                }
                .font(.subheadline.weight(.medium))
                .tint(primary)
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 32)
        }
        .environment(\.layoutDirection, config.isRTL(language) ? .rightToLeft : .leftToRight)
    }

    private func categoryList(_ config: PropertyConfig, translations: TranslationSet?, primary: Color) -> some View {
        VStack(spacing: 0) {
            ForEach(config.categories.filter(\.enabled), id: \.code) { category in
                let translation = translations?.categories[category.code]
                Toggle(isOn: binding(for: category, config: config)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(translation?.title ?? category.name)
                            .font(.subheadline.weight(.medium))
                        if let description = translation?.description ?? category.description, !description.isEmpty {
                            Text(description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .tint(primary)
                .disabled(category.isRequired)
                .padding(.vertical, 12)
                Divider()
            }
        }
    }

    private func binding(for category: CategoryInfo, config: PropertyConfig) -> Binding<Bool> {
        Binding(
            get: { currentSelection(config).isOn(category) },
            set: { value in
                var next = currentSelection(config)
                next.set(category.code, value)
                selection = next
            }
        )
    }

    private func currentSelection(_ config: PropertyConfig) -> SheetSelection {
        selection ?? SheetSelection(consent: consentIQ.consent, categories: config.categories)
    }

    private func toggleCategories(_ config: PropertyConfig) {
        if !showCategories, selection == nil {
            selection = SheetSelection(consent: consentIQ.consent, categories: config.categories)
        }
        withAnimation { showCategories.toggle() }
    }

    private func commitSelection(_ config: PropertyConfig) {
        let values = currentSelection(config).values
        selection = nil
        showCategories = false
        consentIQ.savePreferences(values)
    }
}

struct FilledButtonStyle: ButtonStyle {
    let color: Color
    let cornerRadius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.vertical, 14)
            .padding(.horizontal, 12)
            .background(color.opacity(configuration.isPressed ? 0.85 : 1))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

struct OutlinedButtonStyle: ButtonStyle {
    let color: Color
    let cornerRadius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(color)
            .padding(.vertical, 14)
            .padding(.horizontal, 12)
            .background(color.opacity(configuration.isPressed ? 0.08 : 0))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(color, lineWidth: 1.5))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

public struct ConsentSheet: ViewModifier {
    @ObservedObject private var consentIQ: ConsentIQ

    public init(consentIQ: ConsentIQ = .shared) {
        self.consentIQ = consentIQ
    }

    // SwiftUI writes false through this binding only for an interactive dismissal, so that is the
    // one path that reaches onClose; a programmatic hide never re-enters the setter.
    private var isPresented: Binding<Bool> {
        Binding(
            get: { consentIQ.isSheetVisible },
            set: { presented in
                if !presented { consentIQ.dismissSheet() }
            }
        )
    }

    public func body(content: Content) -> some View {
        content.sheet(isPresented: isPresented, onDismiss: { consentIQ.dismissSheet() }) {
            ConsentSheetContent(consentIQ: consentIQ)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .interactiveDismissDisabled(false)
        }
    }
}

public extension View {
    func consentSheet(_ consentIQ: ConsentIQ = .shared) -> some View {
        modifier(ConsentSheet(consentIQ: consentIQ))
    }
}
#endif
