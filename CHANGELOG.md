# Changelog

## 1.1.0

- Properties with "Require CAPTCHA" turned on now work. Before each submission the SDK gets a fresh
  Cloudflare Turnstile token in a hidden web view and sends it with the consent. The web view
  loads only when a submission first needs a token.
- If the captcha check fails, times out, or needs visitor interaction, nothing is sent: local
  state is kept, `FormConsent.submit()` returns `nil`, and a warning is logged.
- `ConsentSubmission` has a new optional `captchaToken`.
- The startup warning that mobile SDKs cannot satisfy a captcha is no longer logged on iOS.
- The podspec links WebKit.

## 1.0.1

- Debug log lines are logged with private privacy, so the device log redacts them unless a
  debugger is attached.
- Debug logs no longer include the subject id or the consent id.
- The example app turns on debug logging in debug builds only.
- README: a caller-supplied `subjectId` must be random and unguessable.

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
