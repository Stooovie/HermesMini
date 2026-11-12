# Hermes Mini

A tiny macOS menu-bar client for [Hermes Agent](https://hermes-agent.nousresearch.com).
Press a global hotkey, a floating panel appears, talk to your agent, press Escape.
No Dock icon, no window stack, no Electron.

It is a **thin client**: all agent logic, tools, memory and sessions live on the
Hermes server. This app only renders the conversation.

- Binary: ~4 MB (`swift build -c release`)
- Server side: the **Hermes WebUI** (`hermes-webui`, default port 8787), *not* the
  admin dashboard (:9119) and not the `hermes serve`/Desktop gateway — the API
  surface is different.

## Requirements

- macOS 13 or newer
- Swift 5.9+ toolchain (Xcode Command Line Tools are enough)
- A running Hermes WebUI reachable over HTTPS or the tailnet

## Build

```sh
swift build -c release
```

The result is `.build/release/HermesMini`.

## Bundle it as a .app

The app is `LSUIElement` (menu-bar only) plus a floating `NSPanel`, so it needs a
real bundle with `Info.plist` to behave correctly:

```sh
APP="$HOME/Applications/Hermes Mini.app"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/HermesMini "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
codesign --force --sign - "$APP"
open "$APP"
```

Ad-hoc signing is intentional — see `CredentialStore.swift` for why the password
lives in `UserDefaults` instead of the Keychain.

## Usage

| Action | Key |
|---|---|
| Show / hide the panel | `⌥Space` (configurable) |
| Dismiss the panel | `Esc` |

The menu-bar item offers *Show/Hide*, *New Session*, *Preferences…*. Preferences
cover *launch at login* (installs a `LaunchAgent`), the hotkey and the panel font
size. The connection itself — server URL and password — is set on the login
screen.

First launch asks for a **Server URL** and a **password** — the same login as the
WebUI. Sessions, streaming answers, tool-call rows, approvals and clarifications
all come from the server.

## Configuration

Stored in `UserDefaults`, domain `dev.hermesmini.client`:

| Key | Meaning | Default |
|---|---|---|
| `ServerURL` | WebUI base URL | `https://hermes.example.com` |
| `StoredPassword` | WebUI password | — |
| `HotKeyCode` / `HotKeyModifiers` | Carbon hotkey | `⌥Space` (`kVK_Space` / `optionKey`) |
| `PanelFrame` | Last panel position | top-right corner |

Preset them before first launch:

```sh
defaults write dev.hermesmini.client ServerURL "http://100.x.y.z:8787"
defaults write dev.hermesmini.client StoredPassword "<password>"
```

### Plain HTTP

The client inherits a guard from Hermex: plain `http://` is only accepted when
the **host is a Tailscale IP** in `100.64.0.0/10`. A MagicDNS name
(`host.tailnet.ts.net`) is rejected even though it resolves to a tailnet address —
use the IP, or serve the WebUI over HTTPS.

## API surface used

`/api/auth/login`, `/api/auth/status`, `/api/sessions`, `/api/session`,
`/api/session/{new,rename,delete,pin,archive,branch,status}`, `/api/chat/start`,
`/api/chat/stream` (SSE), `/api/chat/{cancel,steer,stream/status}`,
`/api/approval/*`, `/api/clarify/*`, `/api/models`, `/api/profiles`, `/api/upload`.

## Debugging

Everything logs to `/tmp/hermesmini.log` (unbuffered, written immediately — the
main-thread watchdog deliberately writes from a background thread too, so a full
deadlock is still measurable). A stall is reported only after ~4.5 s (two missed
heartbeat ticks); anything below that is normal timer jitter.

## Credits & license

Endpoint catalog and behaviour ported from
[Hermex](https://github.com/uzairansaruzi/hermex) (MIT) — see
`LICENSE-HERMEX.txt`. Dependencies: [swift-eventsource](https://github.com/LaunchDarkly/swift-eventsource)
(SSE) and [swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui)
(rendering).
