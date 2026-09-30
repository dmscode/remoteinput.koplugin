# RemoteInput Plugin for KOReader

Real-time remote text input for KOReader with a persistent connection and **bidirectional** sync. Type on another device and see the changes appear instantly on your e-reader — without page refreshes, and without reconnecting when you switch between input fields.

> **This project is a fork of [j-v/remotenote.koplugin](https://github.com/j-v/remotenote.koplugin).** RemoteInput keeps the original idea and much of the underlying code (TLS server, QR-code flow, Kindle firewall handling, settings menu), but reworks the interaction model from a one-shot HTML form into a real-time, two-way synchronized web app. See [Differences from RemoteNote](#differences-from-remotenote) for the full list.
>
> 中文说明请见 [README.zh-CN.md](README.zh-CN.md) · *For a Chinese version of this document, see [README.zh-CN.md](README.zh-CN.md).*

> **Security note:** by default, opening RemoteInput starts a simple web server with an **unsecured** connection on your e-reader. It may be wise to avoid use on public networks. You can enable HTTPS, but you will then be subject to the limitations of self-signed certificates. See [Configuration](#configuration) for details.

## Supported devices

Tested working on Kindle Paperwhite. Your experience may vary.

KOReader minimum version: 2025.10 — other versions may not be supported.

## Features

- **Real-time sync**: text typed on the remote device appears on KOReader instantly as you type (debounced), no submit button required.
- **Bidirectional sync**: edits made locally on the reader are also reflected back to the web page.
- **Persistent connection**: the server stays alive after a save, so there is no need to re-scan the QR code.
- **Seamless context switching**: switch between annotation editing and any input dialog without reconnecting.
- **Automatic input following**: while a session is active, any text input dialog opened on the reader silently takes over the remote context — the web page follows along within a second, no button taps needed.
- **Conflict-free two-way editing**: a `dirty`-flag state machine ensures "whoever is typing wins" and the other side never clobbers it.
- **Idle auto-stop**: the server shuts itself down after a configurable period of inactivity (Off / 5 / 15 / 30 / 60 minutes).
- **Low-power friendly**: adaptive polling backs off when idle or when the page is hidden, minimizing load on slow devices and phone batteries.
- **Remote Note**: type notes for passages you highlight within a book.
- **Remote Input**: a "Remote input" button is injected into standard KOReader text dialogs so you can fill them from a remote device.
- **RESTful JSON API** (`/api/state`, `/api/text`, `/api/submit`) with a self-contained, fully spec-compliant JSON encoder/decoder.
- **Optional HTTPS** with auto-generated self-signed TLS certificates.

## Installation

1. Download the release for your device's architecture from the [Releases](#releases) page:

   | Architecture | Devices |
   | --- | --- |
   | **armv7** | Kindle (all models), Kobo, reMarkable 2, PocketBook |
   | **arm64** | reMarkable Paper Pro |
   | **arm-legacy** | Kindle 3, Kindle DX, older 32-bit ARM devices |
   | **x86_64** | Emulator |

   > **Not sure?** Try `armv7` first. Use `arm-legacy` only if `armv7` doesn't work on older hardware.

2. Extract `remoteinput.koplugin` to your KOReader plugins directory:
   - Kindle: `/mnt/us/koreader/plugins/`
   - Kobo: `/.adds/koreader/plugins/`

3. Restart KOReader.

## Releases

Releases are produced automatically by a GitHub Actions workflow (copied and adapted from the upstream project). Pushing a tag starting with `v` (for example `v0.1.0`) triggers [`release.yml`](.github/workflows/release.yml), which:

1. Sets the version in `_meta.lua` to match the tag.
2. Cross-compiles the `certgen` Go binary (in [`certgen/`](certgen/)) for `armv7`, `arm64`, `arm-legacy`, and `x86_64`.
3. Packages one zip per architecture — each containing the plugin's Lua sources, `README.md`, `README.zh-CN.md`, `LICENSE`, and the matching `bin/certgen` — via [`build.sh`](build.sh).
4. Creates a GitHub Release (marked as a pre-release by default) and uploads the four zips as assets.

### Building locally

If you have Go installed you can reproduce the release artifacts yourself:

```bash
bash ./build.sh          # full build: compile certgen for all arches and zip them
bash ./build.sh -p       # package only: reuse existing binaries and re-zip
```

The `bin/certgen` binary present in a working tree is a local convenience for generating TLS certificates; it is **not** committed to the repository (`bin/` is git-ignored, matching the upstream model). Release zips are the supported distribution channel.

## Configuration

Settings can be accessed from the Top Menu: **Tools > Remote Input**.

### Port

By default, the server runs on port 8089. You can change it here. A new port takes effect from the next session.

### Auto-stop after inactivity

The server stops itself after the selected period without *real* activity (text edits, context switches, page loads — background polling alone does not keep it alive). Cycle through **Off / 5 / 15 / 30 / 60** minutes; the default is 15. When the timeout fires, the reader shows a notice and any open web page switches to "Session ended". Stopping manually — the device's **Stop** button or the web **Save & Close** — always works immediately.

### Enable HTTPS (Encryption)

> **NOTE:** Using HTTPS ensures content is transmitted encrypted, but it is still subject to the limitations of self-signed certificates, such as man-in-the-middle attacks. Modern browsers will show the connection as unsecured.

When enabled, the plugin automatically generates the required TLS certificates (`cert.pem` and `key.pem`) and uses a secure connection.

### Refresh TLS certificates

Forces the generation of new HTTPS certificates. (Only visible when HTTPS is enabled.)

### Allow remote input in all text input dialogs

Toggles the injection of the Remote Input functionality globally across the KOReader UI. Requires a restart to take effect after changing. Enabled by default.

### Follow newly opened input dialogs

While a session is active, opening any text input dialog on the reader and bringing up its keyboard switches the remote context to that dialog automatically — the web page follows without tapping "Remote input" again. Note dialogs are excluded: use their "Remote edit note" button to switch to annotation editing. Enabled by default.

### Render inline 'Remote input' button

Toggles how the "Remote input" button looks in dialogs. If checked, it tries to place it inline with the default KOReader buttons. If unchecked, it places it in a separate row within the dialog boundary.

## Architecture

RemoteInput embeds a small HTTP server on the reader and serves an interactive single-page web app. The browser and the reader communicate over a small JSON API:

| Endpoint | Method | Purpose |
| --- | --- | --- |
| `/` | GET | Serves the interactive web frontend |
| `/api/state` | GET | Returns current context, text, version and dirty flags (polled by the frontend) |
| `/api/text` | POST | Pushes text from the web page to KOReader in real time |
| `/api/submit` | POST | Saves the note and closes the session (annotation context) |

### Synchronization model

Both sides run a tiny state machine to avoid edit conflicts:

- A `dirty` flag marks which side is actively editing. When the browser is typing (`isDirty = true`), it owns the text and KOReader never overwrites it.
- When the browser is idle and KOReader detects a local change (`server_dirty`), the web page adopts the reader's text on the next poll. Other open tabs also pick up remote edits this way.
- A context `version` counter is bumped **only** on context switches (e.g. moving to a different input field), so the frontend can reset itself without a reload — and can never confuse an ordinary text update with a switch that would clobber the side that is typing.
- Each session has a random id (`sid`); if the reader starts a new session, older web pages detect the mismatch and end themselves instead of resurrecting stale state.
- A 10-second safety timer releases the `dirty` flag automatically so a network failure can never permanently lock out the other side.
- The polling interval adapts automatically: 600 ms right after interaction, 2 s when idle, 5 s when the page is in the background.

## Differences from RemoteNote

### What changed and improved

| Area | RemoteNote (upstream) | RemoteInput (this project) |
| --- | --- | --- |
| **Sync model** | One-shot HTML form: type, click **Save**, server closes | Real-time auto-sync as you type (250 ms debounce) |
| **Direction** | Web → reader only | **Bidirectional** (reader-side edits also appear in the browser) |
| **Connection** | Server stops after every save; re-scan QR each time | **Persistent** server; switch fields without reconnecting |
| **Conflict handling** | None (last writer wins) | `dirty`-flag state machine with a 10 s safety release |
| **Frontend** | Minimal HTML form | Styled single-page app with status indicator and hints |
| **API** | Plain `POST` form data | RESTful JSON API (`/api/state`, `/api/text`, `/api/submit`) |
| **Dependencies** | Relies on `socket.url` for decoding | Self-contained JSON encoder/decoder + URL decoding (no external deps) |
| **Session state** | None | Tracks `session_active`, `context_version`, `server_dirty` |
| **Annotation submit** | Implicit (form submit = save) | Explicit **Save & Close** button |
| **Plugin name** | `remotenote` / "Remote Note" | `remoteinput` / "Remote Input" |
| **Version** | 0.1.0 | Tag-driven automatic bumps (see Releases) |

### What was carried over unchanged

- `securetcpserver.lua` (SSL-wrapped TCP server) is identical to upstream.
- HTTPS certificate generation, the QR-code dialog, the Kindle `iptables` firewall handling, and the settings-menu structure all follow upstream.

### Behavioral changes (intentional)

- The server URL is shown as plain centered text instead of an underlined "open link" button (`Device:openLink`).
- The upstream "Content is being edited by *ip*…" status dialog was removed — real-time sync makes it redundant.
- The dialog buttons changed from a single "Cancel" to **Hide** (dismiss, keep session alive) and **Stop** (end session).

## Known issues

- When opening the "Edit note" dialog, the KOReader keyboard may occlude the bottom buttons of the dialog. As a mitigation, enable the "Render inline 'Remote input' button" option.
- HTTPS relies on self-signed certificates; browsers will flag the connection as untrusted.

## License

[GNU AGPL v3](LICENSE), inherited from the upstream project [j-v/remotenote.koplugin](https://github.com/j-v/remotenote.koplugin).

## Credits

This project is based on [j-v/remotenote.koplugin](https://github.com/j-v/remotenote.koplugin) by [j-v](https://github.com/j-v). All credit for the original RemoteNote plugin, the TLS server, and the KOReader integration work goes to the original author.
