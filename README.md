<p align="center">
  <img src="icons/WingScreen.png" width="128" alt="WingScreen icon">
</p>

<h1 align="center">WingScreen</h1>

<p align="center">
  Turn a spare Mac or Windows PC into an extended display for another computer — over Wi‑Fi, Ethernet or a Thunderbolt cable.
</p>

<p align="center">
  <b>English</b> · <a href="README.vi.md">Tiếng Việt</a>
</p>

---


WingScreen gives your main computer a **real extra display**. The screen of a second computer shows it, and the second computer's keyboard, mouse and trackpad can control the main machine too. It works in every direction:

| | Mac (receiver) | Windows (receiver) |
|---|:---:|:---:|
| **Mac (main)** | ✅ | ✅ |
| **Windows (main)** | ✅ | ✅ |

This repository contains the **macOS app**. The Windows app lives in the companion repository **[WingScreen-Windows](https://github.com/YOUR-ACCOUNT/WingScreen-Windows)**. Both apps speak the same protocol.

## Features
- **A true extended display, not a mirror.** The main Mac gets a new virtual monitor that appears in *System Settings → Displays*. You can arrange it, drag windows onto it, run apps full-screen on it, and give it its own menu bar and Spaces.
- **Hardware video pipeline.** Capture uses ScreenCaptureKit and encoding uses VideoToolbox (H.264 or HEVC), tuned for low latency. The receiver decodes in hardware too.
- **Retina-aware.** The virtual display matches the receiver's resolution and scale, for example 1536×960 pt at 2x on a 16" MacBook Pro.
- **Remote input.** The receiver's keyboard, mouse, trackpad scrolling and clicks are sent back to the main computer. Ctrl on Windows maps to ⌘ on Mac, so copy and paste feel natural on both sides.
- **Zero configuration.** Machines find each other with Bonjour. There are no IP addresses to type.
- **Cable-aware.** The receiver starts on Wi‑Fi and switches automatically to a Thunderbolt Bridge or Ethernet link as soon as you plug one in. Unplug it and it falls back to Wi‑Fi within a few seconds.
- **Survives network hiccups.** The virtual display is kept for 15 seconds after a disconnect, so your windows don't jump back to the main screen when the link drops briefly.
- **One app, two roles.** The first time you launch WingScreen, it asks whether this machine is the main computer or the extra display.

## How it works
```
 Main computer                                                  Extra display
┌──────────────────────────────┐                              ┌──────────────────────────┐
│ virtual display              │                              │                          │
│   → ScreenCaptureKit         │      H.264 / HEVC (TCP)      │ hardware decode          │
│   → VideoToolbox encoder  ───┼─────────────────────────────▶│   → full-screen view     │
│                              │                              │                          │
│ CGEvent injection         ◀──┼──────────────────────────────┼── keyboard / mouse       │
└──────────────────────────────┘        input events          └──────────────────────────┘
```

## Requirements
- **macOS 12.3 (Monterey) or later**, on Intel or Apple Silicon. The build is universal.
- To build: **Xcode** or the **Command Line Tools** (`xcode-select --install`).
- Both computers on the same network, **or** connected with a **Thunderbolt 3/4 or USB4 cable**. An ordinary USB‑C charging cable won't create a network link.

## Build
```bash
git clone <this-repo-url> WingScreen
cd WingScreen
./build.sh            # universal app: dist/WingScreen.app + dist/WingScreen-macOS.zip
./build.sh native     # faster: only for this Mac's CPU architecture
```
To set the version at build time, run `WINGSCREEN_VERSION=2.1 ./build.sh`.

**GitHub Actions:** go to *Actions → Build WingScreen (macOS) → Run workflow* and download `WingScreen-macOS.zip` from the run's artifacts. Pushing a tag such as `v2.1` builds the app and publishes a Release automatically.

## Install
1. Copy `WingScreen.app` to **/Applications** on each Mac. To move it to another Mac, use `dist/WingScreen-macOS.zip` and unzip it on the target Mac. This preserves the code signature.
2. The app is ad-hoc signed, not notarized. On first launch, **right-click → Open**, or run:
   ```bash
   xattr -cr /Applications/WingScreen.app
   ```

## Usage
1. On the **main** Mac, open WingScreen and choose **Main computer (send)**. A ▭▭ icon appears in the menu bar.
2. Grant both permissions in *System Settings → Privacy & Security*, then quit and reopen WingScreen:
   - **Screen & System Audio Recording**, to capture the virtual display.
   - **Accessibility**, to accept keyboard and mouse input from the receiver.
3. On the **other** computer, open WingScreen and choose **Extra display (receive)**. It finds the main machine and goes full-screen.
4. On the main Mac, open *System Settings → Displays → Arrange* and drag the **"… (WingScreen)"** display to where the second computer physically sits.

### Menu bar options (main computer)
| Option | Values |
|---|---|
| Video resolution | Auto (match receiver) · 2x · 1.5x · 1x |
| Bitrate | 10 – 80 Mbps. Use about 20 on Wi‑Fi and 50–80 on a cable. |
| Frame rate | 30 / 60 fps |
| HEVC | Sharper at the same bitrate |
| Launch at login | macOS 13+ |

Changing a setting while connected reconnects automatically in about 2 seconds.

### Shortcuts (extra display)
| Shortcut | Action |
|---|---|
| ⌃⌥⌘X | Quit |
| ⌃⌥⌘I | About |
| Hold ⌥ while launching | Choose the role again |

### Command line
```bash
WingScreen.app/Contents/MacOS/WingScreen --sender
WingScreen.app/Contents/MacOS/WingScreen --receiver [--host 192.168.1.10]
WingScreen.app/Contents/MacOS/WingScreen --choose
# main computer: --fps 60 --bitrate 40 --hevc --scale 1.5 --port 52020
```

## Language
The interface is available in **English** and **Vietnamese**. By default it follows the macOS language. To change it:
- in the role picker (shown on first launch, or when you hold ⌥ while launching): **Language / Ngôn ngữ**
- on the main computer: menu-bar icon → **Language / Ngôn ngữ** → Automatic / English / Tiếng Việt

## Customization
- **About window and version:** edit [`about.json`](about.json). It holds the name, version, description, author, organization, website, email, copyright and notes. Fields ending in `_en`, such as `description_en` and `notes_en`, are shown when the app runs in English. Empty fields are hidden.
- **Icons:** replace `icons/WingScreen.png` (square, 1024×1024). You can also add `icons/MenuBarIcon.png` (black on transparent, about 44×44) for a custom menu-bar icon. See [`icons/README.txt`](icons/README.txt).

## Troubleshooting
| Symptom | Fix |
|---|---|
| Receiver keeps connecting and disconnecting | Screen Recording permission is missing on the main Mac. Grant it, then quit and reopen the app. If it still fails after a rebuild, restart the Mac. |
| "The application can't be opened" | Run `xattr -cr` on the app, then `chmod +x WingScreen.app/Contents/MacOS/WingScreen`. |
| Laggy on Wi‑Fi | Lower **Bitrate** to 20 Mbps and **Resolution** to 1.5x. Use 5 GHz Wi‑Fi, or better, a Thunderbolt cable. |
| Cable plugged in but still on Wi‑Fi | Check *Network → Thunderbolt Bridge* shows **Connected**. If it doesn't, the cable isn't Thunderbolt/USB4. |
| Two displays appear for the same Mac | You also started **AirPlay** to that Mac. Disconnect it in Control Center → Screen Mirroring. |

Logs are written to `~/Library/Logs/WingScreen.log`. On the main Mac, you can also open them from the menu bar: **Open log…**

## Limitations
- WingScreen creates the virtual display with the **private `CGVirtualDisplay` API**, the same one used by tools like DeskPad and BetterDisplay. A future macOS release may change or remove it.
- Video and input travel **unencrypted** over your local network. Use WingScreen on trusted networks only.
- Audio is not transmitted.
- Protected content, such as some streaming video, may appear black.
- The maximum stream size is 4096×2304, the H.264 level limit. Larger sizes are scaled down automatically.
- One extra display per main computer.

## Project structure
```
Sources/WingScreen/            app: role picker (main.swift), About, Sender/, Receiver/
Sources/WingScreenShared/      network protocol, framing, logging
Sources/CGVirtualDisplayKit/   Objective-C bridge to CGVirtualDisplay
about.json                     About window content + version
icons/                         app & menu-bar icons
build.sh                       universal build, signing, zip
.github/workflows/build.yml    CI build & release
```

## License
No license has been chosen yet. Add a `LICENSE` file before publishing. [choosealicense.com](https://choosealicense.com) can help you pick one.
