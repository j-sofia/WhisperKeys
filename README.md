# WhisperKeys

WhisperKeys is a native SwiftUI macOS menu-bar dictation app. It starts local WhisperKit transcription while you speak, performs a final accuracy pass when you stop, and sends the result to the focused application as a sequence of individual CoreGraphics keyboard events.

The typewriter path is deliberately a key-event path, not a text-insertion path. That distinction is especially useful with virtual-desktop and remote-application interfaces, such as a Windows VM, VNC session, or enterprise remote-desktop client. Those interfaces often receive keyboard activity through the system input stream, but may not expose a local macOS text field that another app can modify through Accessibility APIs.

## Requirements

- macOS 14 or later on Apple Silicon
- Xcode 16 or later recommended
- Microphone permission
- Accessibility permission for emitted keyboard events
- Input Monitoring permission when the global Right Option shortcut is enabled

The app is intentionally not sandboxed: macOS keyboard-event posting and the global shortcut need the privacy permissions above.

Because the app uses the Hardened Runtime, its signed target includes the `com.apple.security.device.audio-input` entitlement. Keep that entitlement enabled; without it macOS denies microphone capture before presenting the normal privacy prompt.

## Installation

1. Open the [WhisperKeys Releases page](https://github.com/J-S-O-F/Transcription-App/releases) and download the latest `WhisperKeys.zip` file.
2. Double-click the ZIP file, then move `WhisperKeys.app` to `/Applications`.
3. Open the app. A signed and notarized release opens normally.
4. On first launch, follow the setup window to download a local model and grant the required Microphone, Accessibility, and Input Monitoring permissions.

## Sharing a test build

Do not send the `.app` folder directly through chat, email, or cloud storage: those services can alter the app bundle or its executable permissions. Build the app, then package the **entire** application bundle on your Mac:

```zsh
ditto -c -k --keepParent --sequesterRsrc "/path/to/WhisperKeys.app" "WhisperKeys.zip"
```

The recipient should extract the ZIP, move `WhisperKeys.app` to `/Applications`, and open it from there. This project currently uses an Apple Development signature, so a one-off test build is not trusted by Gatekeeper on another Mac. If the recipient trusts the copy and macOS blocks it, they can Control-click the app, choose **Open**, and confirm the prompt. If that option is unavailable, they can remove the download quarantine attribute and open it:

```zsh
xattr -dr com.apple.quarantine "/Applications/WhisperKeys.app"
open "/Applications/WhisperKeys.app"
```

Only do this for an app obtained directly from a trusted developer. The recipient must use macOS 14 or later on Apple Silicon; an Intel Mac is unsupported.

## Publishing a release

For anyone beyond a trusted one-off tester, sign the Release archive with a **Developer ID Application** certificate from an Apple Developer Program account and notarize it with Apple:

1. In Xcode, add the Developer Program account under **Xcode → Settings → Accounts** and create or download its **Developer ID Application** certificate.
2. Select the app target and set its **Release** build configuration's **Signing Certificate** to **Developer ID Application**. This project initially uses `Apple Development` for both Debug and Release; leave Debug alone, but change Release before archiving.
3. Choose **Product → Archive**. In the Organizer, select the new archive, choose **Distribute App**, then choose **Direct Distribution**. Complete the Developer ID signing and notarization prompts.
4. Export the notarized, stapled app, package it as `WhisperKeys.zip` with the `ditto` command above, and upload that ZIP as the GitHub Release asset.

Before uploading, verify the export:

```zsh
codesign --verify --deep --strict --verbose=2 "/path/to/WhisperKeys.app"
spctl --assess --type execute --verbose=4 "/path/to/WhisperKeys.app"
xcrun stapler validate "/path/to/WhisperKeys.app"
```

Developer ID signing and notarization are what allow a downloaded app to launch normally on another Mac. An Apple Development certificate, ad-hoc signature, or an unsigned app requires the recipient to explicitly bypass Gatekeeper and is not appropriate for a public release.

## Build and run

1. Open [WhisperKeys.xcodeproj](WhisperKeys.xcodeproj) in Xcode.
2. Let Xcode resolve the `argmax-oss-swift` package and the `WhisperKit` product.
3. Set a personal signing team and replace `com.example.WhisperKeys` with your bundle identifier if needed.
4. Build and run the **WhisperKeys** scheme.
5. On first launch, WhisperKeys opens its setup window. Choose and download a local model, select a double-tap shortcut, decide whether it starts at login or shows in the Dock, and approve the permissions it needs.
6. The setup window includes a text box for a first dictation. Leave that field focused, start dictation, and the recognized text is typed into it just as it will be in your other apps.
7. WhisperKeys installs the model selected during the previous run when it opens. To change models immediately, choose one in **Local Whisper model** and click **Install Selected Model**. Dictation itself always initializes WhisperKit with downloads disabled, so recorded audio never causes a model/network download.

If installation is interrupted, click **Install Selected Model** once more. WhisperKeys keeps completed files, clears only stale partial-download artifacts, and retries the missing file. Do not repeatedly click the button while an installation is active.

If the Microphone button reads **Open Settings**, macOS has already denied the consent prompt. Turn on WhisperKeys in **System Settings → Privacy & Security → Microphone**, then return to the app and use **Refresh Permission Status**.

If it reads **Restricted by macOS**, the setting is controlled by Screen Time or device management and cannot be changed from WhisperKeys. Check **System Settings → Screen Time → Content & Privacy** or contact your device administrator.

For **Accessibility** (the typing permission), macOS may not list WhisperKeys automatically. In **System Settings → Privacy & Security → Accessibility**, click **+** and add WhisperKeys from the Applications folder. The setup window’s **Refresh Permission Decisions** action clears only WhisperKeys’ Accessibility and Input Monitoring decisions, restarts the app, and returns directly to the permissions step.

WhisperKit stores the selected local model beneath `~/Library/Application Support/WhisperKeys/Models`. The **Show Models Folder** button opens that location.

## Using it

- Choose **Start Dictation** to begin microphone recording and live local transcription. A low-latency rough hypothesis begins typing while you speak, then later hypotheses and the final pass refine the text. Partial text is also visible in **Show Typing Debug**.
- The global trigger is a double-tap of the selected modifier key (Right/Left Option, Command, or Control by default). You can disable it and use the menu bar instead.
- Beginning another dictation immediately cancels any in-progress typing/transcription before recording again.

## Important keyboard behavior

`KeyboardMapper` uses `TISCopyCurrentKeyboardLayoutInputSource` and `UCKeyTranslate` to search the active macOS layout for each character. It selects the layout-appropriate virtual key code and Shift/Option modifiers; it does not assume a US keyboard layout.

For every supported character, `TypingEngine` performs:

```text
CGEvent keyboard keyDown (one virtual key)
short configurable delay
CGEvent keyboard keyUp   (that same virtual key)
```

`CGEventKeyEmitter` posts the two events at `.cghidEventTap`. It does **not** call any of these APIs or techniques:

- `AXUIElement`/Accessibility text insertion
- `NSText` insertion
- `NSPasteboard` or clipboard writes
- Cmd-V simulation
- `CGEvent.keyboardSetUnicodeString` or any equivalent full-string event

### Why this works better in virtual desktops

Many dictation or “Whisper typing” tools deliver a completed transcription by inserting a string into the current text control, or by copying it to the clipboard and simulating Cmd-V. That is convenient for ordinary native apps, but it can break down when the focused surface is a remote desktop: the local app may only be displaying a streamed window, the remote client may not provide an editable Accessibility element, and clipboard synchronization may be disabled, delayed, or intentionally isolated.

WhisperKeys instead emits the same basic **key down** and **key up** sequence a physical keyboard produces, one mapped character at a time. A remote-desktop client that forwards macOS keyboard events can therefore forward the dictation to the guest OS as normal keystrokes. The text is typed into whichever remote control has focus without requiring a shared clipboard or direct access to that control's text API.

This per-key design is the key differentiator: transcription is not delivered as one privileged text-insertion operation or pasted as a buffer. Each character is mapped for the active macOS keyboard layout, then sent with its own virtual key code and any required Shift or Option modifier. That makes the behavior closer to normal typing and avoids assuming a US keyboard layout.

Characters that the active layout can only produce through a multi-key dead-key composition are stopped and reported as unsupported rather than being inserted as Unicode text. Newline, tab, and backspace use their documented macOS virtual keys.

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

Source folders are organized by responsibility:

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

## Settings

- Whisper model: Tiny, Base, Small, or Large v3
- Typing speed: Fastest (no intentional delay) or 1–200 WPM
- Key-down to key-up delay
- Extra character and word delays
- A selectable double-tap modifier shortcut: Right/Left Option, Command, Control, or disabled
- Auto-capitalization
- Optional Return after transcription
- Optional start at login, managed through macOS Login Items
- Optional Dock visibility, with the standard Dock Quit action
- A six-step first-run onboarding flow. Once completed it stays out of the way; use **Settings → Advanced → Reset Onboarding** to run it again.

## Known macOS limitation

CGEvent is the lowest broadly available public API for this kind of injection. A remote client can still choose to ignore synthetic events; the target app/client must accept system-level keyboard events. WhisperKeys never falls back to clipboard or text insertion because that would change the intended behavior.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for local development and pull-request guidance. Please report security issues according to the [security policy](SECURITY.md), rather than in a public issue.

## License

WhisperKeys is released under the [MIT License](LICENSE).
