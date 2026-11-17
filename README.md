# Gemini Desktop for macOS (Unofficial)

An **unofficial macOS desktop wrapper** for Google Gemini. It's a lightweight native app that loads the official Gemini website, and it adds the desktop features of Google's own Mac app.

> **Why this fork exists:** Google's [official Gemini Mac app](https://gemini.google/mac/) needs **Apple Silicon and macOS 15 Sequoia or later**. This fork brings the same workflow to **Intel Macs and macOS 13 Ventura and later**, and you can build it with just the free Command Line Tools. You don't need Xcode.

![Desktop](docs/desktop.png)

![Chat Bar](docs/chat_bar.png)

> **Disclaimer:**
> This project is **not affiliated with, endorsed by, or sponsored by Google**.
> "Gemini" is a trademark of **Google LLC**.
> This app does not modify, scrape, or redistribute Gemini content. It loads the official website.

---

## Features

| Official Gemini Mac app | This app |
| --- | --- |
| Quick chat from anywhere with **⌥ Space** | ✅ Floating Quick Chat panel, default **⌥ Space** (you can change it) |
| Share your window or screen with Gemini | ✅ **Ask About Active Window** / **Screen Area** / **Entire Screen**. The screenshot is attached to your prompt |
| Talk to Gemini by voice | ✅ **Talk to Gemini** starts dictation (Gemini's mic) from a global shortcut |
| Use Gemini from other apps | ✅ Select text anywhere → right-click → **Services → Ask Gemini** |
| Notifications | ✅ Get a macOS notification when a response finishes while you're in another app |
| Chats sync with web and phone | ✅ It's the real gemini.google.com, so everything syncs |
| Apple Silicon + macOS 15 only | ✅ **Intel and Apple Silicon, macOS 13+** |

### Also included
- **Global shortcuts** for every action (Quick Chat, main window, share window, share area, voice), set in Settings
- **URL scheme** for Shortcuts, Raycast and Alfred (see below)
- Menu bar icon, optional hidden Dock icon, launch at login, always-on-top
- Adjustable text size, light/dark/system theme
- Camera and microphone support for Gemini Live
- Downloads (e.g. generated images) save to `~/Downloads`
- Recovers on its own if the web content process crashes
- No tracking and no data collection. Open source.

### Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| ⌥ Space *(global, customizable)* | Toggle Quick Chat |
| ⌘ N | New chat |
| ⌥⌘ 1 / 2 / 3 | Ask about active window / screen area / entire screen |
| ⌘⇧D | Dictate (Gemini's own shortcut) |
| ⌘ [ / ⌘ ] | Back / forward |
| ⌘⇧T | Always on top |
| ⌘ + / ⌘ − / ⌘ 0 | Zoom |
| Esc | Hide Quick Chat |

### URL scheme

```
geminidesktop://open                       show the main window
geminidesktop://chat                       toggle Quick Chat
geminidesktop://new                        start a new chat
geminidesktop://ask?q=Hello%20there        put text into a new chat
geminidesktop://ask?q=Hello&send=1         …and send it
geminidesktop://share?mode=window|area|screen
geminidesktop://voice                      start voice input
```

Example: `open "geminidesktop://ask?q=Summarize%20my%20clipboard&send=1"`

---

## System Requirements

- **macOS 13 Ventura** or later
- **Intel or Apple Silicon** Mac

---

## Build & Install (no Xcode needed)

```bash
xcode-select --install          # one time: installs the free Command Line Tools
git clone https://github.com/alexcding/gemini-desktop-mac.git
cd gemini-desktop-mac
./scripts/build-app.sh --install   # builds, copies to /Applications and launches
```

Other options:

```bash
./scripts/build-app.sh               # builds build/Gemini Desktop.app
./scripts/build-app.sh --universal   # Intel + Apple Silicon binary
./scripts/build-app.sh --debug       # enables the Safari Web Inspector
./scripts/create-dmg.sh              # packages build/GeminiDesktop.dmg
swift scripts/make-icon.swift        # regenerates Resources/AppIcon.icns
```

The Xcode project (`GeminiDesktop.xcodeproj`) still works if you have Xcode. It now targets macOS 13 and has no package dependencies.

### Permissions
- **Screen Recording** is only needed for the "Ask About Window/Screen" features. Grant it in System Settings → Privacy & Security → Screen Recording, then reopen the app.
- **Microphone/Camera** are requested by Gemini when you use voice or Gemini Live.
- **Notifications** are requested the first time a background response finishes.

> Builds are ad-hoc signed, so macOS ties permissions to each build. After you rebuild, you may need to turn Screen Recording on again.

---

## What This App Is (and Isn't)

**This app is:**
- A thin desktop wrapper around `https://gemini.google.com`
- A convenience app for macOS users who can't run the official app

**This app is NOT:**
- An official Gemini client
- A modified or enhanced version of Gemini's service
- A Google-authored product

---

## Login & Security Notes

- Google handles sign-in on its own website
- This app does **not** intercept credentials
- No user data is stored or sent anywhere by this app
- By default the app identifies as the Safari version installed on your Mac, so Google serves pages your WebKit can run

> Note: Google may restrict or change login behavior for embedded browsers at any time.

---

## Changes in 0.3.0 (macOS 13 / Intel compatibility & feature-parity update)
- Supports **macOS 13+** (was 14+). Replaced the Observation framework, `SettingsLink` and the newer `onChange` APIs with versions that work on 13
- Builds with the **Command Line Tools only** (Swift 5.8+), using `scripts/build-app.sh`
- Removed the KeyboardShortcuts dependency (it needs Swift 6.1). Added a built-in global hot-key system
- New: Ask About Window/Area/Screen, Talk to Gemini, the "Ask Gemini" Service, URL scheme, background response notifications
- User agent follows the installed Safari version. Chrome option tracks the current Chrome release
- Added `<a download>` handling, ⌘-click to open in browser, crash recovery, and a classic `.icns` icon for pre-Tahoe macOS
