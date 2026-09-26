# mcbe-macos

Run Minecraft Bedrock Edition on Apple Silicon Macs using the iOS client.

Apple Silicon Macs run iPhone and iPad apps natively: the game's arm64 code runs directly on the CPU and draws with Metal on the GPU. There is no emulator, VM or Rosetta. [PlayCover](https://github.com/PlayCover/PlayCover) handles the iOS-on-Mac side. This repo adds the settings that work and a small dylib (`libmacfix.dylib`) that fixes what PlayCover does not.

Tested with Minecraft 1.26.50 on an M3 Pro, macOS 26.5.

## What the fix does

| Problem | Fix |
| --- | --- |
| macOS "invalid key" beep on every WASD press | Silences the beep for key presses the game reads directly |
| Game Mode stays off | Marks the app as a game, so fullscreen enables Game Mode |
| Crash on launch (keymapping) | Turns off PlayCover keymapping; the game has native mouse and keyboard support |
| Clicks do nothing | Sets the window to 1728×1080 (clicks only register at a height of 1080) |

## Known issues

- **Frame rate is capped at 60 FPS**, even on 120 Hz displays. Raising every display link to 120 Hz lifts the cap but stops clicks from registering; a targeted fix is still being worked out.
- **Clicks sometimes stop registering** after a relaunch, even with the working settings. Hovering still highlights buttons. The cause is not known yet.

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

It **cannot** check the encrypted code range itself (about 275 MB): Apple signs the encrypted pages, not the decrypted ones. PlayCover runs the game in the macOS App Sandbox, which limits what a tampered copy could reach.

## Setup

```sh
git clone https://github.com/bedrock-mc/mcbe-macos
cd mcbe-macos
scripts/setup.sh /path/to/decrypted-minecraft.ipa
```

The script:

1. Checks that the IPA is decrypted, installs it into PlayCover and waits for the install to finish.
2. Moves aside any old PlayCover keychain database (a stale one makes the game abort on launch).
3. Applies the working PlayCover settings (keymapping off, 1728×1080 at 16:10).
4. Builds `libmacfix.dylib`, adds it to the app, marks the app as a game, and re-signs it.

Then open PlayCover and launch Minecraft.

**Reinstalling or updating the IPA in PlayCover removes the patch.** Run `scripts/setup.sh --patch-only` afterwards, or run the full setup with the new IPA.

## Troubleshooting

- **Hovering highlights buttons but clicks do nothing:** the window height is not 1080. In PlayCover's settings for Minecraft, set Resolution to 1080p and Aspect Ratio to 16:10.
- **Crash right after launch:** check that you are on PlayCover nightly, and that Keymapping is off.
- **Game keeps running after closing the window:** iOS apps stay alive in the background. Quit with ⌘Q.
- **FPS counter:** set Metal HUD on in PlayCover's settings for Minecraft, or launch with `open --env MTL_HUD_ENABLED=1 ~/Library/Containers/io.playcover.PlayCover/Applications/com.mojang.minecraftpe.app`.
- **Logs:** `log stream --predicate 'process == "minecraftpe" AND eventMessage CONTAINS "macfix"'` shows what the dylib did.

## Undo

Reinstall the IPA from PlayCover. That replaces the patched app with a clean copy.
