# Changelog

All notable changes to the RevokeGPT React Native package. The four mobile SDKs (iOS, Android,
Flutter, React Native) share one version, and the package wraps the native SDKs of the same
version.

## [0.1.1] - Unreleased

Fixes the public mirror's CI: wraps the native iOS and Android SDKs 0.1.1. No API change.

## [0.1.0] - Unreleased

### Added

- `RevokeGPT.configure`, `execute` and `challengeAccount` over the native iOS and Android SDKs, as
  a TurboModule (New Architecture only), with `RevokeGPTError` codes, statuses, request ids and
  `Retry-After`. Arguments are checked in JavaScript before any native call.
- The iOS SDK's sources are vendored into the package's pod at pack time; the Android side depends
  on `com.revokegpt:revokegpt-android` at the same version.
- An Expo config plugin that adds the App Attest entitlement
  (`appAttestEnvironment: 'production' | 'development'`).
