# grassNotch for macOS

grassNotch is a native macOS menu-bar/notch app built with Swift and SwiftUI.

## NotchOS 2.4

This release adds live camera and microphone activity indicators using the
provided camera and microphone icons. The notch widens sideways when idle, adds
the indicators beside compact YouTube status, and keeps the YouTube controls at
their existing size while placing indicators in the header. Mirrored displays
avoid redundant per-draw state copies, and pointer pass-through checks run
separately from visual synchronization to reduce external-display overhead.
YouTube skip arrows now match their back and forward actions.

## Build and launch the app

Requirements: macOS 15 or later and Swift 6.4 or later from Xcode or Apple's Command Line Tools.

1. Unzip the project and open Terminal in the project folder.
2. Build the packaged macOS app:

   ```sh
   ./scripts/package-app.sh
   ```

3. Launch the app:

   ```sh
   open .build/out/Products/Debug/grassIsland.app
   ```

The packaged app includes the bundle metadata required for Touch ID, Notification Center, Focus, and Bluetooth integration. Touch ID requires a Mac with Touch ID enabled and enrolled. Developer Mode always starts locked and uses macOS LocalAuthentication; it does not store authentication between launches.

macOS may ask for Automation or Accessibility access for features that inspect or control other apps. Running `swift run` launches an unbundled SwiftPM executable and does not provide the app-bundle integrations above.

## Distribution notes

The build script creates `.build/out/Products/Debug/grassIsland.app` and ad-hoc signs it locally. The ZIP is a source distribution, not a Developer ID signed or notarized app. On another Mac, build it there with the steps above; macOS may require the recipient to confirm opening an app downloaded from the internet.
