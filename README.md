# grassNotch for macOS

grassNotch is a native macOS menu-bar/notch app built with Swift and SwiftUI.

## NotchOS 2.5

This release improves source builds on Macs with multiple installed Swift
toolchains. Use Apple's toolchain that matches the selected Xcode or Command
Line Tools SDK; mixing a separately installed Swift 6.4.1 toolchain with a
different SDK can fail while scanning system modules such as CoreMIDI, XPC,
and IOKit. The app reports version 2.5 in its packaged bundle and startup view.

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
   selects Apple's Xcode-default toolchain explicitly, avoiding a separately
   selected toolchain that may not match the active SDK. If you run `swift run`
   yourself, confirm `swift --version` and `xcode-select -p` refer to a matching
   Apple toolchain and SDK. Xcode 26 builds can also work around explicit-module
   scanner errors by setting `SWIFT_ENABLE_EXPLICIT_MODULES=NO` for the affected
   target, as documented in Apple's Xcode release notes.

3. Launch the app:

   ```sh
   open .build/out/Products/Debug/grassIsland.app
   ```

The packaged app includes the bundle metadata required for Touch ID, Notification Center, Focus, and Bluetooth integration. Touch ID requires a Mac with Touch ID enabled and enrolled. Developer Mode always starts locked and uses macOS LocalAuthentication; it does not store authentication between launches.

macOS may ask for Automation or Accessibility access for features that inspect or control other apps. Running `swift run` launches an unbundled SwiftPM executable and does not provide the app-bundle integrations above.

## Distribution notes

The build script creates `.build/out/Products/Debug/grassIsland.app` and ad-hoc signs it locally. The ZIP is a source distribution, not a Developer ID signed or notarized app. On another Mac, build it there with the steps above; macOS may require the recipient to confirm opening an app downloaded from the internet.
