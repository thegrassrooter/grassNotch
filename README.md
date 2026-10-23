# grassNotch for macOS

grassNotch is a native macOS menu-bar/notch app built with Swift and SwiftUI.

## Run from source

Requirements: macOS 15 or later and Swift 6.4 or later from Xcode or Apple's Command Line Tools.

1. Unzip the project.
2. Open Terminal and change into the unzipped project folder.
3. Run:

   ```sh
   swift run
   ```

The first run compiles the app. Keep Terminal open while using it; press Control-C in that Terminal to stop it. macOS may ask for Automation or Accessibility access for features that inspect or control other apps.

When started with `swift run`, grassNotch runs as a SwiftPM executable. macOS requires a registered `.app` bundle for Notification Center delivery and usage-description-backed Focus/Bluetooth access. Gmail and WhatsApp items can still appear in the notch, but native Notification Center alerts and Focus/Bluetooth indicators require the packaged app.

## Build the packaged app

To create a local `.app` bundle with the app icon and native Notification Center support, run:

```sh
./scripts/package-app.sh
```

The app is written to `.build/out/Products/Debug/grassIsland.app`. This project ZIP is an unsigned source distribution; sharing it does not include Developer ID signing or Apple notarization. Recipients can build and run the source with `swift run` as described above.
