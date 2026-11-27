# Fount for Android

Fount for Android shows the latest export from the Mac app. On the Mac, open GitHub Sync, sync, and copy the Gist URL. On Android, open the Settings tab, paste the URL, and save. Pull down on a list to check for a newer export. Tap an article to open its original page in the device's browser.

It is an Expo app (Expo Router, SDK 58) with four tabs: Articles, Feeds (each feed opens its own article list), Activity and Settings.

## Develop

Install Expo Go on the Android device, then run on the Mac:

```sh
npm install
npx expo start
```

Scan the QR code with Expo Go while both are on the same network. Edits reload on the device without a build.

## Build an APK

```sh
npm run build:android
```

It first draws the launcher icons into `assets/` with `../scripts/make-icon.swift` (the Mac app's artwork, shrunk into the adaptive icon's safe zone, plus a monochrome version for themed icons), then builds on EAS with the `preview` profile. It uploads this directory without Git (`EAS_NO_VCS=1`), filtered by `.easignore`, because `.gitignore` keeps the drawn icons out of Git and a Git-based upload would leave them out. The APK holds native code for arm64-v8a only (`reactNativeArchitectures` in `eas.json`), which every current Android phone uses, so it is a fraction of a universal APK's size. EAS builds are limited each month, so build only when native code changes.

## Ship a JavaScript change

```sh
npm run update -- --message "What changed"
```

Builds made since EAS Update was added check the `preview` channel when they start and apply the update on the next launch. The runtime version is the project's fingerprint, so an update only reaches builds with the same native code; after adding a module with native code, build again instead.
