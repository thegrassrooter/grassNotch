# grassNotch for macOS

grassNotch is a native macOS menu-bar/notch app built with Swift and SwiftUI.

Explore the release story at [grassNotch — NotchOS](https://thegrassrooter.github.io/grassNotch-site/). The site's source lives in the companion [grassNotch-site repository](https://github.com/thegrassrooter/grassNotch-site).

## NotchOS 4

NotchOS 4 introduces grassMenu. Option-click the notch to open its compact,
scrollable icon grid; Notch Settings is the first item. Settings are organized
in the existing protected panel and remain Touch ID authenticated. Closing
settings returns to grassMenu. The startup screen and settings show NotchOS 4.
Clicks on the notch are handled by grassNotch instead of passing through to
the app behind it.

NotchOS 3 added grassAI inside the existing notch. Double-tap the Command key
to open the compact assistant without clicking. The notch prompt is available
immediately without a grassAI account sign-in; prompts and follow-ups use the
server-side `grassNotchChat` action and the existing grass1 model. Keep the
Groq API key in Apps Script Script Properties; never put it in this app. The
updated Apps Script source is in `grassAI-backend/Code.gs` and must be deployed
to the existing web app before this client action is available. System-wide
key monitoring requires Accessibility access; without it, the shortcut works
while grassNotch is active. The assistant keeps its conversation in memory
while the app is running. Click the top grabber or press Escape to close
grassAI; the notch returns to its current live state. Notch Settings stays
separate and blocks grassAI while it is open.

This release improves source builds on Macs with multiple installed Swift
toolchains. Use Apple's toolchain that matches the selected Xcode or Command
Line Tools SDK; mixing a separately installed Swift 6.4.1 toolchain with a
different SDK can fail while scanning system modules such as CoreMIDI, XPC,
and IOKit. The app reports version 4.0 in its packaged bundle and NotchOS 4 in
its startup view and Notch Settings.
Notch Settings includes a persistent switch for hiding
or showing the orange moving bars in the compact YouTube status without
disabling playback, the YouTube logo, or its controls.

The previous release added live camera and microphone activity indicators,
lower-overhead mirrored displays, and corrected YouTube skip arrows.

## Build and launch the app

Requirements: macOS 15 or later and Swift 6.4 or later from the same Xcode or
Command Line Tools installation that provides the macOS SDK. Do not mix an
independently installed Swift toolchain with a different Apple SDK.

1. Unzip the project and open Terminal in the project folder.
2. Build the packaged macOS app with the Xcode-selected Swift toolchain:

   ```sh
   ./scripts/package-app.sh
   ```

   To run the SwiftPM executable directly, use `./scripts/swift.sh run`. This
   selects Apple's Xcode-default toolchain explicitly and SwiftPM's native build
   engine, avoiding a separately selected compiler and Xcode's explicit-module
   scanner. If you run `swift run` yourself, use Apple's matching Swift and SDK;
   Xcode-based builds can work around explicit-module scanner errors with
   `SWIFT_ENABLE_EXPLICIT_MODULES=NO` for the affected target.

3. Launch the app:

   ```sh
   open .build/out/Products/Debug/grassIsland.app
   ```

The packaged app includes the bundle metadata required for Touch ID, Notification Center, Focus, and Bluetooth integration. Touch ID requires a Mac with Touch ID enabled and enrolled. Notch Settings always starts locked and uses macOS LocalAuthentication; it does not store authentication between launches.

macOS may ask for Automation or Accessibility access for features that inspect or control other apps. Running `swift run` launches an unbundled SwiftPM executable and does not provide the app-bundle integrations above.

## Distribution notes

The build script creates `.build/out/Products/Debug/grassIsland.app` and ad-hoc signs it locally. The ZIP is a source distribution, not a Developer ID signed or notarized app. On another Mac, build it there with the steps above; macOS may require the recipient to confirm opening an app downloaded from the internet.
