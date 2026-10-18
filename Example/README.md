# ConsentIQ example app

A minimal SwiftUI app wired to the SDK. The Xcode project is not checked in (and is gitignored);
create it once locally and drop these two files in.

1. In Xcode choose File > New > Project, pick iOS > App, name it `ConsentIQExample`, choose
   SwiftUI for the interface and Swift for the language, and save it inside this `Example`
   folder. Set the target's minimum deployment to iOS 16.0.
2. Delete the generated `ConsentIQExampleApp.swift` and `ContentView.swift` from the new project,
   then drag this folder's `ConsentIQExampleApp.swift` and `ContentView.swift` into the app
   target (leave "Copy items if needed" unticked to edit the files in place).
3. Add the SDK: File > Add Package Dependencies, click "Add Local", and choose the repository
   root, which is the local path `..` relative to the project. Add the `ConsentIQ` library to the
   app target.
4. Replace `YOUR_IOS_PROPERTY_KEY` in `ConsentIQExampleApp.swift` with the public key of an iOS
   property from the ConsentIQ dashboard. Leave `apiURL` at its default.
5. Run on a simulator. The consent sheet appears on first launch; tap "Reset consent" to see it
   again.

To point the example at the published package instead of the local checkout, use
File > Add Package Dependencies with `https://github.com/iqworksai/consentiq-ios` and the
`1.0.1` version rule.
