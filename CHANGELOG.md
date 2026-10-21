# Changelog

## Unreleased

- IAB TCF in-app support. When a property has TCF turned on and ConsentIQ's CMP ID is issued, the
  SDK writes `IABTCF_CmpSdkID` and `IABTCF_CmpSdkVersion` at start-up and shows ConsentIQ's hosted
  TCF screens full-screen in a web view instead of the native sheet. Each decision writes the
  `IABTCF_*` keys to `UserDefaults.standard`, where vendor SDKs read them, and updates `consent`
  without a second submission. Where GDPR does not apply, `IABTCF_gdprApplies` is `0` and the
  native sheet is used.
- `showPrivacyChoices()` and `presentPrivacyChoices(from:)` reopen the TCF screens, or the native
  sheet when TCF is off. `showSheet()` and `presentSheet(from:)` route the same way.
- `isTcfActive` is published, and `PropertyConfig.tcf` exposes the config's TCF switch and CMP ID.
- `ConsentIQConfig.onError` reports a TCF screen that could not load or answer; the SDK shows the
  native sheet instead and tries the TCF screens again on the next open. A choice made in that
  native sheet removes the TCF decision keys this SDK wrote.
- Keys written by another CMP are left alone until the visitor decides in ConsentIQ's screens.
- `ConsentStorage.clearAll()` also clears the stored TCF decision (`consentiq_tcf`).
- `resetConsent()`, and consent the server reports as expired, remove the TCF decision keys this
  SDK wrote from `UserDefaults.standard`. `IABTCF_CmpSdkID`, `IABTCF_CmpSdkVersion` and
  `IABTCF_gdprApplies` stay, and keys written by another CMP are never touched.
- When a property turns TCF off, the next start-up removes every `IABTCF_*` key this SDK wrote,
  `IABTCF_CmpSdkID` included, so vendor SDKs stop reading the old consent.

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
