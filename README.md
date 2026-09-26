# mcbe-macos

Run Minecraft Bedrock Edition on Apple Silicon Macs using the iOS client.

Apple Silicon Macs run iPhone and iPad apps natively: the game's arm64 code runs directly on the CPU and draws with Metal on the GPU. There is no emulator, VM or Rosetta. [PlayCover](https://github.com/PlayCover/PlayCover) handles the iOS-on-Mac side. This repo adds the settings that work and a small dylib (`libmacfix.dylib`) that fixes what PlayCover does not.

Tested with Minecraft 1.26.50 on an M3 Pro, macOS 26.5.

## What the fix does

| Problem | Fix |
| --- | --- |
| Clicks or keys randomly do nothing for a whole session (hover still works) | Re-runs the game's own mouse and keyboard setup when it was skipped |
| Frame rate capped at 60 FPS on 120 Hz displays | Raises the game's render loop to 120 Hz |
| macOS "invalid key" beep on every WASD press | Silences the beep for key presses the game reads directly |
| Game Mode stays off | Marks the app as a game, so fullscreen enables Game Mode |
| Crash on launch (keymapping) | Turns off PlayCover keymapping; the game has native mouse and keyboard support |
| Black bars in fullscreen | Sets 1080p at 16:10, close to a MacBook's fullscreen shape |

### Why clicks and keys break

The game reads the mouse and keyboard through Apple's GameController framework. It installs its click and key handlers when it is told a mouse or keyboard has connected. On the Mac, the built-in keyboard and trackpad often connect before the game starts listening, so the game is never told and never installs the handlers. Hover still works because it comes from a different API, and whether a launch works depends on startup timing. The dylib catches the game's input handler when it starts listening, and runs the game's own setup if a device has no handler. It leaves handlers that are already installed alone.

### Why the frame rate is capped

The game drives rendering from its own display link and sets it up with an older API that pins it to 60 Hz. The dylib raises that one link to 120 Hz after the game has set it up. It does not touch other display links: PlayTools uses one to deliver input.

## Requirements

- A Mac with Apple Silicon (M1 or newer)
- Xcode Command Line Tools: `xcode-select --install`
- **PlayCover nightly** (build 1620 or newer). The last tagged release (3.1.0, 2024) crashes on launch. Download the latest `PlayCover_nightly_*.dmg` from the [nightly workflow runs](https://github.com/PlayCover/PlayCover/actions/workflows/2.nightly_release.yml) (you need to be signed in to GitHub), and drag PlayCover into `/Applications`.
- A **decrypted** Minecraft IPA for a version you own.

## Getting a decrypted IPA

App Store apps are encrypted with Apple's FairPlay DRM, and PlayCover can only run decrypted apps. You need to decrypt your own copy (for example, with a jailbroken iPhone and [ipadecrypt](https://github.com/londek/ipadecrypt)) or find a decrypted copy of a version you own.

If you did not decrypt the IPA yourself, check it against Apple's original before you run it. `scripts/verify_decrypted.py` compares a decrypted IPA to the encrypted IPA from the App Store:

```sh
brew install ipatool
ipatool auth login -e you@example.com
ipatool list-versions -b com.mojang.minecraftpe          # find the version ID
ipatool download -b com.mojang.minecraftpe --external-version-id <id> -o apple.ipa
python3 scripts/verify_decrypted.py apple.ipa decrypted.ipa
```

The versions must match exactly. The script checks every file byte for byte, and checks every page of every binary against Apple's code signature, so it catches injected libraries and changed data.

It **cannot** check the encrypted code range itself (about 275 MB): Apple signs the encrypted pages, not the decrypted ones. It also trusts the original as given, so download that from Apple yourself. PlayCover runs the game in the macOS App Sandbox, which limits what a tampered copy could reach.

## Setup

```sh
git clone https://github.com/bedrock-mc/mcbe-macos
cd mcbe-macos
scripts/setup.sh /path/to/decrypted-minecraft.ipa
```

The script:

1. Checks that the IPA is decrypted, installs it into PlayCover and waits until PlayCover has finished signing it.
2. Quits PlayCover (it would otherwise write its old settings back) and applies the working settings: keymapping off, 1080p at 16:10.
3. Builds `libmacfix.dylib`, adds it to the app, marks the app as a game, and re-signs it.

Then open PlayCover and launch Minecraft.

**Reinstalling or updating the IPA in PlayCover removes the patch.** Run `scripts/setup.sh --patch-only` afterwards, or run the full setup with the new IPA.

## Troubleshooting

- **Clicks or keys do nothing:** check the log (below). A working launch shows either the game's own setup (`game mouse setup: ready=1`) or a repair (`repaired mouse ... ready=1`). If neither appears, the patch is not loaded; run `scripts/setup.sh --patch-only`.
- **Crash on launch with "Couldn't add the Keychain Item":** a keychain database from an older PlayTools. Run `scripts/setup.sh --reset-playchain`.
- **Other crashes right after launch:** check that you are on PlayCover nightly, and that Keymapping is off.
- **Lag or FPS dips:** lower the Resolution Scaler in PlayCover's settings for Minecraft (for example, from 2.0 to 1.5). At 2.0 the game renders 3456×2160, more pixels than a MacBook screen shows.
- **Game keeps running after closing the window:** iOS apps stay alive in the background. Quit with ⌘Q.
- **Joining a server on the same Mac:** use `127.0.0.1` and the server's port. A LAN address like `192.168.x.x` needs Minecraft allowed under System Settings → Privacy & Security → Local Network.
- **FPS counter:** set Metal HUD on in PlayCover's settings for Minecraft, or launch with `open --env MTL_HUD_ENABLED=1 ~/Library/Containers/io.playcover.PlayCover/Applications/com.mojang.minecraftpe.app`.
- **Logs:** `log stream --predicate 'process == "minecraftpe" AND eventMessage CONTAINS "macfix"'` shows what the dylib did.

## Undo

Reinstall the IPA from PlayCover. That replaces the patched app with a clean copy.
