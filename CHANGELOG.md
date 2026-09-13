# Changelog

## 1.0.0

First release.

- `ConsentIQ` shared state with `@Published` consent, marketing consent, config, loading, sheet
  visibility, language and regulation.
- Property config, consent lookup, consent submission and verification against the ConsentIQ
  public API, with tolerant `Codable` models.
- Pseudonymous subject id and consent cache in `UserDefaults`.
- SwiftUI consent sheet (`.consentSheet()`), `ConsentGate`, and a UIKit
  `ConsentSheetViewController` with `presentSheet(from:)`.
- Server-served sheet labels for every supported language, right-to-left layout, and a cookie
  notice link.
- `FormConsent` helper for marketing channel forms.
- Swift Package Manager and CocoaPods podspec; iOS 16.0 or later.
