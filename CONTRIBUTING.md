# Contributing to WhisperKeys

Thanks for considering a contribution. Before opening a pull request, please
check existing issues and keep each change focused on one concern.

## Development

- Use macOS 14 or later on Apple Silicon with Xcode 16 or later.
- Set your own signing team and bundle identifier in Xcode before running the app.
- Run `swift test --package-path WhisperKeys` from the repository root.
- Verify the app target with an unsigned Xcode build:
  `xcodebuild -project WhisperKeys/WhisperKeys.xcodeproj -scheme WhisperKeys
  -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`.
- Do not commit build products, Xcode user data, local models, recordings, or signing material.

## Pull requests

- Explain what changed and why.
- Include manual testing notes for behavior that depends on macOS privacy permissions or keyboard layouts.
- Add or update tests when the project contains coverage for the behavior you change.
- Keep user-facing copy clear and accurate about the app's microphone, Accessibility, and Input Monitoring permissions.
- Make sure the unit-test, Xcode-build, dependency-review, and CodeQL checks pass.

By contributing, you agree that your contributions may be distributed under the [MIT License](LICENSE).
