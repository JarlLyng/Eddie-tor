# Security Policy

## Reporting a vulnerability

If you've found a security issue in Edwell, please **don't open a public issue**. Email me directly:

**jarl@iamjarl.com**

Please include:
- a description of the vulnerability,
- the steps to reproduce it,
- the affected version (the Mac App Store version, or a commit SHA),
- how you'd like to be credited when it's fixed, if at all.

I'll answer within 7 days. A confirmed issue gets a fix as quickly as development and App Store review allow.

## Scope

In scope:
- the Edwell macOS app code,
- the website at `edwell.iamjarl.com` (the source is in `website/`),
- the build and release scripts.

Out of scope:
- third-party dependencies, such as IAMJARLDesignTokens: report to those projects directly,
- vulnerabilities in Apple's platforms: report to Apple Product Security,
- issues in forks of this repo.

## What Edwell does and doesn't handle

Edwell is a small video editor with a deliberately small attack surface:

- **No backend.** No server, no database, no API of its own.
- **No accounts.** No sign-up, no authentication, no passwords.
- **Your media never leaves the Mac.** Editing and export are local, and nothing is uploaded.
- **No tracking.** No analytics or crash reporting in the app. The only network traffic is Apple's StoreKit, for the trial and the purchase. The website uses Umami for aggregate page views, with no cookies and no fingerprinting.
- **Sandboxed file access.** The app runs in the App Sandbox and reads and writes only the files and folders you pick, through security-scoped bookmarks.

If you find a way to break any of those, I want to know.

## Past advisories

None to date.
