# ConsentIQ iOS SDK

The native iOS SDK for [ConsentIQ](https://consent.iqworks.ai), IQWorks' consent management
platform. It fetches your property's configuration, shows a consent sheet on first launch,
records the visitor's choices against a pseudonymous subject id, and lets your app gate features
on consent. SwiftUI and UIKit are both supported.

Requires iOS 16.0 or later and Swift 5.9 or later.

## Install

### Swift Package Manager

In Xcode choose File > Add Package Dependencies, enter
`https://github.com/iqworksai/consentiq-ios`, and pick "Up to Next Major Version" from `1.1.0`.
Add the `ConsentIQ` library to your app target.

Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/iqworksai/consentiq-ios", from: "1.1.0"),
],
targets: [
    .target(name: "YourApp", dependencies: [
        .product(name: "ConsentIQ", package: "consentiq-ios"),
    ]),
]
```

A `ConsentIQ.podspec` is included for teams that vendor pods from git:

```ruby
pod 'ConsentIQ', :git => 'https://github.com/iqworksai/consentiq-ios.git', :tag => 'v1.1.0'
```

## Quick start (SwiftUI)

Configure once at launch and attach the sheet to your root view. The sheet presents itself when
the visitor has not answered yet.

```swift
import SwiftUI
import ConsentIQ

@main
struct MyApp: App {
    init() {
        ConsentIQ.shared.configure(ConsentIQConfig(propertyKey: "YOUR_IOS_PROPERTY_KEY"))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .consentSheet()
        }
    }
}
```

Gate a feature on a category, or observe the state directly:

```swift
struct ContentView: View {
    @ObservedObject private var consentIQ = ConsentIQ.shared

    var body: some View {
        VStack {
            ConsentGate(category: "analytics") {
                AnalyticsBanner()
            }
            Button("Cookie preferences") { consentIQ.showSheet() }
        }
        .onChange(of: consentIQ.consent) { consent in
            if consent["analytics"] == true { Analytics.start() }
        }
    }
}
```

## Quick start (UIKit)

Configure in your app delegate, then present the sheet from any view controller once the
configuration has loaded. `presentSheet(from:)` marks the sheet visible and fires `onOpen` if it
was not already showing.

```swift
import UIKit
import Combine
import ConsentIQ

final class HomeViewController: UIViewController {
    private var cancellables = Set<AnyCancellable>()

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        ConsentIQ.shared.$isSheetVisible
            .removeDuplicates()
            .sink { [weak self] visible in
                guard let self, visible, presentedViewController == nil else { return }
                ConsentIQ.shared.presentSheet(from: self)
            }
            .store(in: &cancellables)
    }

    @objc private func preferencesTapped() {
        ConsentIQ.shared.presentSheet(from: self)
    }
}
```

```swift
func application(_ application: UIApplication,
                 didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    ConsentIQ.shared.configure(ConsentIQConfig(propertyKey: "YOUR_IOS_PROPERTY_KEY"))
    return true
}
```

The sheet dismisses itself after Accept all, Reject all or Save, and a swipe-down reports through
`onClose`.

## One property per platform

A ConsentIQ property is one app platform. Create an iOS property in the dashboard and use its key
in this SDK. If the same product also ships on Android, create an Android property and use its key
with the Android SDK; the two keys are never shared. An app that holds both keys picks by operating
system at runtime, so the iOS key belongs in your iOS target only. iPadOS and Mac Catalyst builds
of the same app use the iOS key.

## API summary

`ConsentIQConfig`

| Field | Default | Meaning |
| --- | --- | --- |
| `propertyKey` | required | The property's public key from the dashboard |
| `apiURL` | `https://consent.iqworks.ai` | ConsentIQ base URL |
| `subjectId` | `nil` | Supply your own id instead of a generated one. It must be random and unguessable, never an account number, email address or phone number: the consent lookup needs only the property key, which ships in your app |
| `autoGenerateSubjectId` | `true` | Generate and persist a UUID when `subjectId` is nil |
| `language` | `nil` | Override the property's default language, for example `"ar-EG"` |
| `autoShow` | `true` | Show the sheet on launch when no consent exists |
| `debug` | `false` | Verbose logging under subsystem `ai.iqworks.consentiq`. Turn it on in debug builds only |
| `onError` | `nil` | Called when the SDK recovers from a failure; today, a TCF screen that could not load or answer |

`ConsentIQ` (`@MainActor`, `ObservableObject`, use `ConsentIQ.shared`)

| Member | Meaning |
| --- | --- |
| `consent`, `marketingConsent` | Published maps of category and channel to `Bool`; `necessary` is always `true` |
| `config` | Published `PropertyConfig` once loaded |
| `isLoading`, `isSheetVisible`, `language`, `regulation` | Published state; `regulation` is the server-resolved regime or `nil` |
| `isTcfActive` | Published; `true` while the property's IAB TCF screens replace the native sheet |
| `configure(_:)` | Starts initialization in a task; `initialize(_:)` is the awaitable form |
| `hasConsent(_:)`, `hasMarketingConsent(_:)` | Query a category or channel |
| `acceptAll()`, `rejectAll()`, `savePreferences(_:)` | The sheet's three outcomes; each also has an `async` form |
| `updateConsent(_:)`, `updateMarketingConsent(_:)` | Merge a partial map and record it |
| `showSheet()`, `hideSheet()`, `dismissSheet()` | Open, close silently, or close as a visitor back-out |
| `showPrivacyChoices()` | Open the visitor's choices: the TCF screens when TCF is active, otherwise the sheet |
| `resetConsent()` | Clear the local cache and subject id and return to defaults |
| `presentSheet(from:)`, `presentPrivacyChoices(from:)` | UIKit presentation of the same choices |

Every write updates local state first, posts to ConsentIQ, persists the cache, then calls
`onConsentChange`. A failed post is logged and local state is kept.

`FormConsent` mirrors the marketing consent form helper: `toggle(_:)`, `set(_:_:)`, `submit()`
(posts `marketingConsents` with `subjectType: user` and `consentMethod: form`) and `reset()`.
Build one with `FormConsent(consentIQ: .shared)` after initialization, or with an explicit
`propertyKey` and `subjectId`.

`ConsentSheetContent` is the sheet body if you want to host it yourself; `ConsentGate` renders
its content only when a category is granted and can show a placeholder while loading.

## Callbacks

All callbacks are optional fields on `ConsentIQConfig` and run on the main actor.

| Callback | When |
| --- | --- |
| `onConsentChange(consent, marketing)` | After a successful write |
| `onOpen()` | The sheet opened, at launch or via `showSheet()` |
| `onAccept(outcome)` | Accept all; `outcome.scope` is `.all` |
| `onReject(outcome)` | Reject all |
| `onSave(outcome)` | Save from the category list |
| `onClose()` | The visitor swiped the sheet away without choosing; never after accept, reject, save or `hideSheet()` |
| `onError(error)` | A TCF screen failed (`TcfError`, with a `code`); the native sheet is used instead |

## IAB TCF

When a property has IAB TCF turned on in the dashboard, the SDK follows the IAB in-app spec:

- At start-up it writes `IABTCF_CmpSdkID` and `IABTCF_CmpSdkVersion` to `UserDefaults.standard`.
  Where GDPR does not apply to the visitor it writes `IABTCF_gdprApplies = 0` and uses the native
  sheet as usual.
- Otherwise it loads ConsentIQ's TCF screens from consent.iqworks.ai in a hidden web view. If the
  stored decision still stands, nothing is shown. If the visitor must choose, the screens are
  presented full-screen over your app; you do not need to present anything yourself.
- A decision writes every `IABTCF_*` key to `UserDefaults.standard`, removes publisher restriction
  keys that no longer apply, updates `consent` and calls `onAccept`, `onReject` or `onSave`, then
  `onConsentChange`. ConsentIQ has already recorded the consent, so it is not sent again.
- Call `showPrivacyChoices()` (or `presentPrivacyChoices(from:)` in UIKit) from your privacy
  settings to reopen the screens. A reopened screen has its own close button, which reports
  `onClose`.
- With `autoShow: false` the screens open only when you call `showPrivacyChoices()`.
- If the screens cannot load within 15 seconds, or answer within 45 seconds of starting, the SDK
  calls `onError` and shows the native sheet. The next `showPrivacyChoices()` tries the TCF screens
  again. A choice made in that native sheet removes the TCF decision keys the SDK wrote, so an older
  TC string never outlives it.
- If another CMP's `IABTCF_CmpSdkID` is already on the device, the SDK leaves its keys alone until
  the visitor makes a choice in ConsentIQ's screens.

`resetConsent()`, or consent the server reports as expired, removes the TCF decision keys the SDK
wrote, so vendor SDKs stop reading the old choices. `IABTCF_CmpSdkID`, `IABTCF_CmpSdkVersion` and
`IABTCF_gdprApplies` stay, and keys another CMP wrote are left alone. If the property later turns
TCF off, the next start-up removes every `IABTCF_*` key the SDK wrote, `IABTCF_CmpSdkID` included.

The `IABTCF_*` keys always go to `UserDefaults.standard`, even when you pass `ConsentStorage` a
different suite, because that is where vendor SDKs read them.

## Limitations

**Captcha.** If "Require CAPTCHA" is turned on for the property, the SDK runs Cloudflare
Turnstile invisibly before each submission, in a hidden web view that loads from
consent.iqworks.ai and challenges.cloudflare.com. Nothing is loaded until the first submission
that needs it. If the check fails, times out, or needs the visitor to interact, the submission is
not sent, local state is kept (`FormConsent.submit()` returns `nil`), and the SDK logs:

```
[ConsentIQ] Captcha check failed; consent not submitted
```

With the setting on, list Cloudflare Turnstile in your app's privacy disclosures.

**Geo.** The applicable regulation is resolved on the server from the request's network location.
The SDK does not send device location.

## License

MIT. See [LICENSE](LICENSE).
