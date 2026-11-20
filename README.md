# PSX32

**PlayStation** emulator made for an **old iPad with iOS 8**. Tested on an iPad 3 (A5X, armv7) running iOS 8.4.1 with a jailbreak.

It is the sibling of [MD16](https://github.com/douugr/md16) and [SNES16](https://github.com/douugr/snes16): the same libretro frontend in Objective-C/UIKit, this time with the [PCSX ReARMed](https://github.com/libretro/pcsx_rearmed) core built into the app, including its **ARM dynamic recompiler** (JIT). That is what makes 3D games run at full speed on a 2012 processor.

## Install

Add the Cydia repository **https://douugr.github.io/repo/** (Cydia or Melder → Sources → Edit → Add) and install **PSX32**. The BTstack package is installed with it.

## Features

- Dynamic recompiler (JIT) on jailbroken iOS 8 (see below), with the PS1 video and sound on their own threads to use both A5X cores
- OpenGL ES 2 video (RGB565, every PS1 resolution up to 640×480), smooth or sharp
- **CRT TV filter** (game menu → "Image…"): scanlines that widen on bright colors, a phosphor mask, composite-video blending (color bleeds more than brightness, so dithering turns into the smooth gradients and transparencies artists drew for TVs) and an optional gently curved screen that still fills the display. Runs at 60 fps on an iPad 3
- On-screen controls with the four geometric face buttons, L1/L2/R1/R2, Select and Start
- **Bluetooth controller** (tested with the 8BitDo Pro 2) via BTstack, with a button setup assistant for every PS1 button, including L2/R2 and L3/R3
- **DualShock mode** (game menu → "Controller: DualShock") with both analog sticks
- **Disc formats:** `.cue` + `.bin`, `.chd`, `.pbp`, `.iso`, `.ccd`/`.img`, and `.m3u` playlists for multi-disc games ("Change disc" in the game menu)
- **Upload games from a browser:** the "Upload games" screen shows an address (`http://psx32.local:8732/<code>/`, with the IP version below it and a QR code to upload from a phone). The code at the end is random and changes every time the screen opens, so nobody else on the network can reach the page;; on your computer, drag the files in. Files are written straight to disk (up to 4 GB each) and the page shows the free space
- **BIOS (optional):** without a BIOS file PSX32 uses the core's built-in HLE BIOS, which runs most games. With your own console's BIOS (e.g. `scph1001.bin`, sent through the same upload page) games boot through the console's startup animation, which can be turned off in the game menu
- **Memory cards:** each game gets its own card, or put the shared card in the slot to use one card for every game, like on the console. Saves are written to the iPad a moment after the game saves. The "Memory cards" screen in the game menu shows both cards side by side with the animated save icons, and copies or deletes saves between them
- 3 manual save-state slots, autosave on exit and "Continue where you left off?"
- A watchdog: if a game ever freezes, PSX32 closes itself instead of leaving the iPad unresponsive, and tells you on the next launch

No games or BIOS files are included: use dumps of discs and of a console you own.

## Performance (iPad 3)

Tekken 3, with the on-screen performance meter during fights: about 11 ms of emulation per frame (out of 16.7 ms), a steady 60 fps on screen, and around 7 ms from a button press to the frame that uses it.

## The JIT on iOS 8

The recompiler writes ARM code into a 16 MB translation cache and jumps into it with `B`/`BL` instructions, which only reach ±32 MB. Two things needed solving on a jailbroken iOS 8:

1. The core's default on Apple platforms (toggling `.bss` pages between writable and executable) is refused; anonymous RWX memory is allowed.
2. A running app rarely has a free 16 MB hole within 32 MB of its code.

So the translation cache is a **zero-fill section in its own `rwx` segment of the app** (`-Wl,-segprot,__JIT,rwx,rwx`): it always sits right after the code and takes no space in the executable file. The change is a small patch in [`core-patches/`](core-patches/), applied by `build.sh`.

## Build

You need a Mac with **Xcode 13.4.1** (the last one that builds armv7), `ldid` and the iPad reachable over SSH.

```bash
./build.sh            # downloads PCSX ReARMed at a pinned commit, applies the patches, builds core + app
./build.sh install    # builds and installs to /Applications on the iPad
```

The app lives in `/Applications` (outside the sandbox) so it can talk to BTstack. Data is in `/var/mobile/Documents/PSX32/{games,bios,saves,states}`.

## Licenses

- The code in this repository is released under the **MIT License** (see [LICENSE](LICENSE)). The icon is original, made for the project.
- **PCSX ReARMed** is licensed under the **GNU GPL v2**. It is not included here: it is downloaded at build time (commit pinned in `build.sh`) and patched with the files in `core-patches/`. Because the packaged app links it statically, **the app as a whole is distributed under the GPL v2**; this repository plus that commit is its complete source.
- The headers in `vendor/btstack` are from BTstack (© BlueKitchen GmbH / Matthias Ringwald) and follow the BTstack license.
- PlayStation is a trademark of Sony Interactive Entertainment. This project is not affiliated with or endorsed by Sony.
