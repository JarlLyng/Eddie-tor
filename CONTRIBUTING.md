# Contributing to Edwell

Bug reports, ideas and pull requests are welcome. For a bigger change, open an issue first so we can talk it through: Edwell stays small on purpose, and a feature that makes it harder to use for its everyday jobs probably won't go in.

## Getting started

1. Fork the repo and clone your fork.
2. Build and run the self test; this needs only the Xcode Command Line Tools:

   ```bash
   swift build && .build/debug/Eddie --selftest /tmp/eddie-test
   ```

   It must end with `SELFTEST OK`.
3. For the app itself, open `App/Edwell.xcodeproj` in Xcode, or run `./build.sh --open`. A build you make yourself is unlocked.

[`AGENTS.md`](AGENTS.md) explains how the app fits together and the gotchas (the App Sandbox, the deployment target, `@ViewState`).

## Before you send a pull request

- **The self test passes, and it covers your change.** It's the only test suite, so a new feature gets a check in `Sources/EddieKit/SelfTest.swift`.
- **Every string in the interface goes through `App/Edwell/Localizable.xcstrings`**, in English, with a Danish translation. `scripts/sync-strings.sh` (needs Xcode) updates the catalog and lists what's missing. If you don't speak Danish, say so in the pull request and it will be translated.
- **No hard-coded colours, radii, spacing or type sizes.** The UI uses the [IAMJARL design system](https://github.com/JarlLyng/iamjarl-design) tokens.
- **Old projects keep opening.** A new field in a project file needs a default in the hand-written `init(from:)` in `Model.swift`.
- **macOS 14 stays the floor.** Anything newer goes behind `#available`.
- **No new entitlements, network code, analytics or accounts.**
- Link the issue your change closes.

## Reporting bugs

Open an [issue](https://github.com/JarlLyng/Eddie-tor/issues/new) with:

- your macOS version and Edwell's version (Edwell › About Edwell),
- the steps to reproduce it,
- what you expected and what happened,
- a sample project or clip, if it's not private.

**Help › Send Feedback…** in the app, or [support@iamjarl.com](mailto:support@iamjarl.com), works too.

## Security

Report a vulnerability by email, not in an issue; see [`SECURITY.md`](SECURITY.md).
