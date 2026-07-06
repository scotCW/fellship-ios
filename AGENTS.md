# AGENTS.md

Guidance for AI coding agents (and humans) working on Fellship. Read this
before making changes.

## What this project is

Fellship is an iOS app (Swift/SwiftUI) that pairs with stock **MeshCore**
companion-firmware LoRa radios to run location-aware mesh "rooms," plus a
classic MeshCore companion mode. There is **no backend** — everything is
on-device or travels radio-to-radio.

## Build, test, run

```sh
# Full unit-test suite (the release gate). Uses an iOS 26.x simulator.
xcodebuild test -project Fellship.xcodeproj -scheme Fellship \
  -destination "platform=iOS Simulator,name=iPhone 17 Pro"

# Release-configuration build check
xcodebuild build -project Fellship.xcodeproj -scheme Fellship \
  -configuration Release -destination "generic/platform=iOS Simulator" \
  CODE_SIGNING_ALLOWED=NO
```

The only dependency is MapLibre Native, pulled via Swift Package Manager.
Minimum deployment target is iOS 17.

### Running the UI without hardware
Launch args drive demo mode and deep-linking for screenshots/automation:
```
-onboardingComplete YES -demoMode YES -activeMode {fellship|classic}
-launchTab N -classicTab N -launchRoomFirst YES
```
Demo mode uses `SimulatedTransport`, a full in-memory MeshCore radio + scripted
peers + a demo repeater, so the entire stack runs unchanged with no radio.

### Executable smoke harnesses
`xcodebuild` is the source of truth, but the platform-neutral core can be run
directly on macOS by compiling the relevant `Fellship/*` sources with
`swiftc` into a small `main.swift` (see prior smoke tests). Useful for fast
crypto/protocol/engine checks without the simulator.

## Non-negotiable constraints

These come from the founding spec and must not be violated:

1. **No backend.** No servers, cloud sync, push (APNs), analytics, or paid APIs
   billed to the owner. Notifications are local only.
2. **Stock MeshCore firmware only.** Use only documented companion-protocol
   features (see `Mesh/MeshCoreProtocol.swift`). Never require custom firmware.
3. **Local-first.** Room data lives on-device; the only off-device copy is the
   user-initiated, passphrase-encrypted backup. No automatic cloud anything.
4. **No GPL code.** The repo is public domain (Unlicense). The MeshCore classic
   mode is a clean-room reimplementation — never copy from MeshCore One (GPLv3)
   or other GPL projects.
5. **No IAP.** Donations stay an in-app crypto address / external link.
6. **Honest UI copy.** Never claim real-time background detection or per-sender
   message authentication; be truthful about mesh/iOS limits.
7. **No hand-rolled crypto.** CryptoKit + CommonCrypto (PBKDF2) only.

## Architecture map

```
Fellship/
  App/          AppState composition root, SwiftUI entry, connection lifecycle
  Domain/       Value types: Room, Boundary, Member, Message, Invite, Coordinate
  Geo/          Pure zone math (containment, bearings, coarsening)
  Crypto/       CryptoKit room keys, sealed boxes, Keychain
  Storage/      SQLite (parameterized, no ORM), settings, encrypted backup
  Mesh/         MeshCore protocol codec, BLE + simulated transports, session,
                Fellship envelope (binary room payloads + chunked invites), LPP
  Location/     Radio-first GPS service, SLC/region background monitor
  Rooms/        RoomEngine: activation rule, presence, invites, chat, zones
  Classic/      Clean-room MeshCore mode: channel, nodes, map, tools, store
  Notifications/ Local notifications
  Maps/         MapLibre canvas, tile sources, offline packs, side controls
  Support/      Formatters, theme, QR, log scale
  UI/           SwiftUI screens
```

Two `ObservableObject` brains both subscribe to one `MeshSession` event stream
and cooperate over one radio: `RoomEngine` (Fellship rooms) and `ClassicStore`
(classic mode). They separate traffic by channel/prefix — see
`RoomEngine.handleChannelText` vs `ClassicStore.handle`.

## Conventions

- Tests live in `FellshipTests/`; new protocol/crypto/engine code needs tests.
- Wire formats are LoRa-tiny: room payloads are hand-packed little-endian
  binary sized to fit one stock MeshCore text frame; invite payloads chunk.
  Any change here needs a round-trip test and a size assertion.
- All untrusted mesh input must decode without crashing (`try?` / guarded
  `BinaryReader`) and growth-prone collections must be capped.
- Keep UI copy plain and honest.

## Working with the GitHub repo

- Repo: **scotCW/fellship-ios** (private). Default branch: **master**.
- Commit author: `scotSW <299917302+scotCW@users.noreply.github.com>` — use this
  exact identity so no personal email is exposed.
- Versioning: SemVer. Bump `MARKETING_VERSION` (and `CURRENT_PROJECT_VERSION`
  for App Store uploads), update `CHANGELOG.md`, tag `vX.Y.Z`, cut a Release.
- Maintenance credential lives in the macOS Keychain, never in a file. Never
  write tokens to `.git/config`; use them inline in the push URL and keep them
  out of command output.
