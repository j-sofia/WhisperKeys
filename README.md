# WhisperKeys

## Overview

WhisperKeys is a native macOS menu-bar dictation app. It transcribes your speech locally with WhisperKit, then types the result into whichever app has focus.

Unlike apps that paste a finished transcription, WhisperKeys sends individual keyboard events. That makes it particularly useful in virtual desktops and remote applications—such as Windows VMs, VNC, and enterprise remote-desktop clients—where normal text insertion or clipboard sharing may not work.

WhisperKeys requires macOS 14 or later on an Apple Silicon Mac.

## Installation

1. Open the [WhisperKeys Releases page](https://github.com/j-sofia/WhisperKeys/releases) and download the latest `WhisperKeys.zip`.
2. Double-click the ZIP, then move `WhisperKeys.app` to `/Applications`.
3. Open WhisperKeys. A signed and notarized release will open normally.
4. In the setup window, choose a local model, select a shortcut, and grant Microphone, Accessibility, and Input Monitoring permissions.

Microphone permission is required to record. Accessibility allows WhisperKeys to type into other apps. Input Monitoring is needed when the global shortcut is enabled.

If macOS has already denied microphone access, open **System Settings → Privacy & Security → Microphone**, enable WhisperKeys, then return to the app and choose **Refresh Permission Status**. If WhisperKeys is not listed under Accessibility, click **+** in **System Settings → Privacy & Security → Accessibility** and add it from `/Applications`.

If a model installation is interrupted, click **Install Selected Model** again. Completed files are retained and only stale partial-download files are cleared. Your models are stored in `~/Library/Application Support/WhisperKeys/Models`; **Show Models Folder** opens that location.

## Features

- Private, on-device transcription with a local Whisper model
- Live, low-latency transcription while you speak, followed by a final accuracy pass
- Types into the focused app as normal keyboard events instead of pasting text
- Support for the active macOS keyboard layout, including Shift and Option characters
- A configurable double-tap shortcut (Right/Left Option, Command, or Control)
- Adjustable typing speed, key timing, capitalization, and optional Return after dictation
- Optional launch at login and Dock visibility
- Model choices from Tiny through Large v3

## How it works

1. On first launch, choose and download a local Whisper model, then approve the requested macOS permissions.
2. Start dictation from the menu bar or double-tap your selected modifier key.
3. WhisperKeys records and transcribes locally. It starts typing completed text shared by consecutive live hypotheses, then completes a final accuracy pass when you stop. Revisions and long repeated tails are withheld instead of being typed.

The typed text is sent one character at a time as a key-down and key-up event, mapped for your current macOS keyboard layout. WhisperKeys does not use the clipboard, simulate Cmd-V, or insert text through an Accessibility text field. That is why it can work with remote clients that forward system keyboard input but do not expose an editable local text field.

Start a new dictation at any time to cancel the current transcription and typing. While recording, the menu also shows the current preview.

WhisperKeys sends modifier keys (including Shift) as their own down/up events before sending the dependent character. This matters for virtual desktops, which may not honor a modifier flag attached only to a character event.

### Microsoft Windows App

When Windows App (`com.microsoft.rdc.macos`) is focused, WhisperKeys automatically sends the transcript through macOS System Events instead of its normal Quartz keyboard transport. This is a separate input path that preserves text capitalization when the remote client ignores synthetic modifier keystrokes. On first use, approve the macOS prompt allowing WhisperKeys to control System Events.

Also open **Connections → Keyboard Mode** while connected and choose **Unicode**. Windows App's Unicode mode is designed to translate text based on the local keyboard, while Scancode is intended for physical-key shortcuts and non-printing keys.

Some remote clients may still choose to ignore synthetic keyboard events. The target app or client must accept system-level keyboard input.

## Architecture

```text
SwiftUI menu bar / settings
                 │
           AppViewModel (MVVM coordinator)
        ┌────────┼───────────┐
 AudioRecorder  WhisperKitSpeechRecognizer  GlobalShortcutMonitor
                       │
                  recognized String
                       │
                 TypingEngine (serial background queue)
                       │ character at a time
                 KeyboardMapper (TIS + UCKeyTranslate)
                       │ KeyStroke(keycode, modifiers)
                 KeyEventEmitter (CGEvent down/up)
```

`KeyboardMapper` looks up each supported character in the active keyboard layout and selects the needed virtual key code and Shift/Option modifiers. Characters requiring a multi-key dead-key composition are reported as unsupported rather than inserted as Unicode text. Newline, Tab, and Backspace use their documented macOS virtual keys.

The source folders are organized by responsibility:

```text
App/           application lifecycle
Views/         menu and settings
ViewModels/    UI state and debug log
Speech/        recorder, model store, WhisperKit backend
Typing/        cancellable timing queue
Permissions/   microphone, Accessibility, Input Monitoring status
Keyboard/      layout mapping, event transport, global shortcut
Settings/      persisted user configuration
Models/        shared view state and value types
```

## Development

1. Open [WhisperKeys.xcodeproj](WhisperKeys.xcodeproj) in Xcode 16 or later.
2. Let Xcode resolve the `argmax-oss-swift` package and the `WhisperKit` product.
3. Set a personal signing team and, if needed, replace `com.example.WhisperKeys` with your bundle identifier.
4. Build and run the **WhisperKeys** scheme on an Apple Silicon Mac running macOS 14 or later.

The app is intentionally not sandboxed because it posts keyboard events and monitors the global shortcut. Its Hardened Runtime target includes the `com.apple.security.device.audio-input` entitlement; keep it enabled so macOS can request microphone access.

For a development test, the setup window has a text box: keep it focused, start dictation, and verify that the recognized text is typed into it. Dictation never downloads a model while recording. To change models immediately, choose one under **Local Whisper model** and select **Install Selected Model**.

If the microphone status says **Restricted by macOS**, Screen Time or device management controls that setting. For Accessibility and Input Monitoring permission issues, **Refresh Permission Decisions** clears only WhisperKeys’ prior decisions, restarts the app, and returns to the permissions step.

See [CONTRIBUTING.md](CONTRIBUTING.md) for local development and pull-request guidance. Please report security issues according to the [security policy](SECURITY.md), rather than in a public issue.

## Distribution

### Sharing a test build

Do not send the `.app` folder directly through chat, email, or cloud storage: those services can alter the app bundle or its executable permissions. Package the complete application bundle instead:

```zsh
ditto -c -k --keepParent --sequesterRsrc "/path/to/WhisperKeys.app" "WhisperKeys.zip"
```

The recipient should extract the ZIP, move `WhisperKeys.app` to `/Applications`, and open it there. This project currently uses an Apple Development signature, so a one-off test build is not trusted by Gatekeeper on another Mac. If the recipient trusts the copy and macOS blocks it, they can Control-click the app, choose **Open**, and confirm the prompt. If that option is unavailable, they can remove the download quarantine attribute:

```zsh
xattr -dr com.apple.quarantine "/Applications/WhisperKeys.app"
open "/Applications/WhisperKeys.app"
```

Only bypass Gatekeeper for an app obtained directly from a trusted developer. Test recipients also need macOS 14 or later on Apple Silicon.

### Publishing a release

For anyone beyond a trusted one-off tester, sign the Release archive with a **Developer ID Application** certificate from an Apple Developer Program account and notarize it with Apple:

1. In Xcode, add the Developer Program account under **Xcode → Settings → Accounts** and create or download its **Developer ID Application** certificate.
2. Select the app target and set the **Release** build configuration’s **Signing Certificate** to **Developer ID Application**. This project initially uses `Apple Development` for both Debug and Release; leave Debug alone, but change Release before archiving.
3. Choose **Product → Archive**. In the Organizer, select the archive, choose **Distribute App**, then **Direct Distribution**, and complete the Developer ID signing and notarization prompts.
4. Export the notarized, stapled app, package it as `WhisperKeys.zip` with the `ditto` command above, and upload the ZIP as the GitHub Release asset.

Verify the export before uploading:

```zsh
codesign --verify --deep --strict --verbose=2 "/path/to/WhisperKeys.app"
spctl --assess --type execute --verbose=4 "/path/to/WhisperKeys.app"
xcrun stapler validate "/path/to/WhisperKeys.app"
```

Developer ID signing and notarization let a downloaded app launch normally on another Mac. An Apple Development certificate, ad-hoc signature, or unsigned build requires the recipient to bypass Gatekeeper and is not suitable for a public release.

## License

WhisperKeys is released under the [MIT License](LICENSE).
