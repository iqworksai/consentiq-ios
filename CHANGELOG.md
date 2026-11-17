# Changelog

## Unreleased

- A decision ConsentIQ has not recorded is kept for a later resend on no answer, a `5xx`, `429` or
  an unanswered challenge, not only on `429`, and a newer decision replaces it. A `400`, `403`,
  `404`, `409` or `422`, or any failure on a property that requires a captcha on every submit, drops
  it with its local copy, calls `onError`, and the next launch asks again with nothing granted. A
  kept decision carries the notice version it was made under and is dropped when the notice or the
  categories change.
- The local copy is written before the post and belongs to its subject id; a different subject id
  shows the sheet again.
- `identityToken` is sent only with a subject id you supply. `FormConsent` takes `identityFor`, and
  sends the signed identifier when the subject is that identifier written differently.
- A restore refused with `403` drops the local copy, calls `onError` and shows the sheet.
- The in-app TCF page receives the `identityToken` for a subject id you supply.

- A subject id you supply (`ConsentIQConfig.subjectId`, `FormConsent`) is sent with
  `subjectSource: "site"` on every write, and to the in-app TCF page, so ConsentIQ stores it apart
  from the ids the SDK generates. A supplied id containing `:` is refused: `initialize` reports an
  `InvalidSubjectIdError` through `onError` and keeps consent local, and `FormConsent.submit()`
  returns `nil`. Its stored consent is restored with `POST /api/public/consent/{key}/{subjectId}` and
  the `identityToken`, which reads only records ConsentIQ verified; without a token the SDK does not
  look it up and relies on the copy on the device. Generated ids are still restored with the open
  lookup.
- When ConsentIQ answers a submission with `428 captcha_required`, which it can do on any property
  when a submission looks automated, the SDK solves one Cloudflare Turnstile challenge and sends
  the submission once more. `FormConsent.submit()` does the same.
- The captcha page is loaded with the property key, so a token is accepted only for that property.
- A challenge stays hidden unless Cloudflare asks for interaction; then it is shown over the app
  with a Cancel button. Once shown it waits up to 2 minutes. Cancelling, a failure or a
  timeout sends nothing more, keeps local state and logs the usual captcha warning.
- App Attest: once per install and property the SDK generates an App Attest key and registers it
  with ConsentIQ, then sends `X-ConsentIQ-Attest-Key` and `X-ConsentIQ-Assertion`, an assertion over
  the exact request body, with every submission. Where App Attest is unsupported, or registration
  fails, nothing is sent and ConsentIQ asks for a captcha instead; a refused key is replaced on the
  next launch. Apps add the App Attest capability. The podspec links DeviceCheck and CryptoKit.
- A submission ConsentIQ answers with `429` is kept and sent once more on the next launch, without a
  captcha; it is dropped once recorded, after three attempts, or after seven days. A `400`, `404`,
  `409` or `422` answer drops it. A `403` (an identity token that did not verify, or one the property
  requires) goes to `ConsentIQConfig.onError` and is not retried.
  It is resent only for the same subject id, property and API URL; a newer decision replaces it; a
  newer record on ConsentIQ wins over it; and a `429` that arrives after `resetConsent()` is ignored.
- App Attest keys are kept per API URL and property. A property without app identifiers (`409`)
  is retried after three days, and a key challenged on three attested submissions in a row is
  registered again.
- `ConsentIQConfig.identityToken`, `FormConsent.identityToken` and `ConsentSubmission.identityToken`
  send your server's signature for the person with each submission, unread by the SDK.
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
- The consent sheet uses the banner background and text colors set in the dashboard, when the
  server sends them, with secondary text and controls following that background's light or dark.
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
