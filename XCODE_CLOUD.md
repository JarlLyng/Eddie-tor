# Xcode Cloud

For **maintainers**. How Edwell, the Mac App Store build of Eddie, gets archived and uploaded.

## Where the configuration lives

**Workflows live in App Store Connect, not in this repo.** Nothing in git controls them. `App/ci_scripts/`
and this file are the only traces Xcode Cloud leaves here, so their presence says nothing about whether a
workflow exists or which branch it builds. Look in:

- **App Store Connect** → Xcode Cloud, to see whether the product exists at all.
- **Xcode** → Report Navigator (**⌘9**) → **Cloud**, to create or edit workflows.

## What Xcode Cloud builds

- **Project:** `App/Edwell.xcodeproj`, generated from `App/project.yml` with
  [XcodeGen](https://github.com/yonaskolb/XcodeGen) and committed, because Xcode Cloud builds what is in
  git. Run `cd App && xcodegen generate` after changing `project.yml`. Swift files go in the package
  (`Sources/EddieKit`), so adding one needs no regeneration.
- **Scheme:** `Edwell` (shared, committed in `Edwell.xcodeproj/xcshareddata`).
- **Scripts:** `App/ci_scripts/`, next to the project, which is where Xcode Cloud looks for them.
  `ci_pre_xcodebuild.sh` sets the build number from `CI_BUILD_NUMBER`.
- **Packages:** the pins are the package's own `Package.resolved` at the repository root. Xcode reads it
  for the project, also with automatic package resolution turned off, as Xcode Cloud runs it.

## Before the first workflow

- The bundle id `com.iamjarl.edwell` is registered, and the App Store Connect record
  "Edwell: Video Editor" exists.
- Signed in to Xcode with an account that can create apps (Account Holder, Admin or App Manager).
- The repository is connected to Xcode Cloud through GitHub.

## The workflow

- **Start condition:** branch changes on **`release`**, like the other IAMJARL apps. `main` is the
  development branch and never starts a release build.
- **Action:** Archive, macOS, scheme `Edwell`, deployment preparation **TestFlight and App Store**.
- **Post-action:** TestFlight internal testing.

## Cutting a release

1. Bump `MARKETING_VERSION` in `App/project.yml` and run `xcodegen generate`.
2. Merge to `main`.
3. Push `main:release`.

## Archiving by hand

To check an archive before a workflow exists, or to validate one:

```bash
xcodebuild archive -project App/Edwell.xcodeproj -scheme Edwell -archivePath build/Edwell.xcarchive
open build/Edwell.xcarchive   # Organizer → Validate App
```

**Reference:** [Xcode Cloud documentation](https://developer.apple.com/documentation/Xcode/Xcode-Cloud/)
