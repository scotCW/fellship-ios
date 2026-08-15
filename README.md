# Fellship

**Rooms for your crew, off the grid.**

Fellship is an iOS app that pairs with any radio running stock
[MeshCore](https://meshcore.co.uk) companion firmware and lets groups form
location-aware **rooms** — invite-only or public, temporary or permanent — see
each other on offline maps, message each other, and get notified when people
enter or leave defined zones.

No servers. No accounts. No subscriptions. No custom firmware. Everything
lives on members' devices and travels radio-to-radio over the LoRa mesh.

> *Fellship* — from **fell** (a high, wild hill) + the Middle English spelling
> of **fellowship**.

## Highlights

- **Geofenced rooms** — a circle (from meters to continent-scale, with a
  user-set slider ceiling), a box, or a straight-line outline placed corner by
  corner on the map; every member's device checks its own GPS against the
  shared boundary and announces entries/exits to the room.
- **Range-based rooms** — "the room is wherever the mesh reaches": perfect for
  convoys and trail groups. In-range is honest, fluctuating mesh reachability,
  not a fake geographic line.
- **Three messaging modes** — whole-room chat, zone-scoped messages that only
  reach members currently present, and direct 1:1 messages to any radio in
  range (no room needed).
- **Room-level encryption** — every room has its own 256-bit key (CryptoKit
  ChaCha20-Poly1305), stored only in members' Keychains, layered on top of
  MeshCore's transport encryption. Keys are delivered at invite acceptance
  inside a Curve25519 sealed box — or face-to-face via QR code.
- **Public rooms with automatic invites** — opt in and your radio's stock
  flood advert doubles as an "open to invite" beacon; members of an active
  public room whose zone you're standing in send you an invite automatically.
  Joining always requires your explicit accept.
- **Offline maps** — MapLibre GL rendering OpenStreetMap (via OpenFreeMap, no
  key), or your own tile provider with your own API key. Download any region +
  zoom range for full offline use.
- **Radio GPS first** — position comes from the radio's GPS over BLE, with
  the phone as an explicit, labeled fallback. One global update interval;
  one GPS read shared by everything (rooms, beacons, the map).
- **Honest backgrounding** — Significant Location Change + region monitoring
  (with rotation beyond iOS's 20-region limit). Notifications say "shortly
  after", because that's what iOS actually delivers.
- **Demo mode** — a fully simulated radio and three scripted companions, so
  you can explore every feature with no hardware.
- **Local-first** — deleting a room (or the app) destroys its data, and the
  only copy that ever exists elsewhere is a backup you explicitly export,
  encrypted with a passphrase only you know.
- **Classic MeshCore mode** — one tap at the top switches to a traditional
  companion-app workflow (channel chat, contacts, node tools) running
  alongside Fellship on the same radio.

## Building

1. Xcode 16 or newer (project uses the synchronized-folder format).
2. Open `Fellship.xcodeproj`. Swift Package Manager pulls the only dependency,
   [MapLibre Native](https://github.com/maplibre/maplibre-gl-native-distribution).
3. Run the `Fellship` scheme on an iOS 17+ device or simulator.
4. `FellshipTests` covers the protocol codec, crypto, zone math and storage.

To use a real radio, pair any board running current stock MeshCore companion
firmware (Heltec LoRa32, LilyGO T-Beam, RAK WisBlock, …) from
**Settings → MeshCore radio**. Without hardware, flip on **Demo mode**.

### Releases

Every GitHub release ships an unsigned `.ipa` alongside the source archive —
built with `Scripts/build-unsigned-ipa.sh`, which archives with code signing
disabled, verifies the result is genuinely unsigned, and zips it into the
standard `Payload/Fellship.app` IPA layout. It won't install on a device or
simulator as-is (no signing identity, no provisioning profile); it exists so
the exact build for a given tag is available without needing the signing
team's certificate.

## Architecture

```
Fellship/
├── Domain/         Value types: Room, Boundary, Member, Message, Invite
├── Geo/            Pure zone math (containment, bearings, enclosing circles)
├── Crypto/         CryptoKit room keys, sealed boxes, Keychain storage
├── Storage/        SQLite (no ORM) + settings; keys never touch the DB
├── Mesh/           MeshCore companion protocol codec, BLE + simulated
│                   transports, session orchestration, Fellship envelope
├── Location/       Radio-first GPS service, SLC/region background monitor
├── Rooms/          RoomEngine: activation rule, presence, invites, chat
├── Classic/        Clean-room classic MeshCore mode (channel, contacts, tools)
├── Notifications/  Local notifications only
├── Maps/           MapLibre canvas, tile sources, offline packs
└── UI/             SwiftUI: map, rooms, chat, nearby, settings, onboarding
```

Design constraints inherited from the spec (and enforced in code):

| Constraint | Where |
|---|---|
| Zero recurring owner cost | No backend anywhere; default tiles are keyless services |
| Stock firmware only | `Mesh/MeshCoreProtocol.swift` speaks the documented companion protocol, nothing else |
| Local-first, no recovery | `LocalStore` + Keychain; deletion is destruction |
| Per-room location visibility | Enforced at broadcast time in `RoomEngine.broadcastPresence` |
| Single GPS interval | `LocationService` owns the only timer; everything piggybacks |
| iOS background reality | `BackgroundMonitor` uses SLC + rotated regions; copy never says "instant" |

## Spec deviations & practical limits (honest notes)

- **No satellite layer** — the original spec hoped for ~10 m Sentinel-2 /
  Landsat imagery. The only *global, reliable, keyless* option (NASA GIBS's
  VIIRS daily composite) is roughly 250 m/pixel, which proved too coarse to be
  worth having, so it was removed in 1.0.2. Bring your own provider if you
  need imagery.
- **Message length** — LoRa frames are tiny. Room messages are capped at 120
  characters (the composer shows a counter), direct messages at 140. Encrypted
  room traffic is hand-packed binary specifically to fit stock MeshCore text
  frames; invite payloads are chunked across several frames.
- **Channel slots** — stock companion firmware exposes a small number of
  channel slots; Fellship maps rooms to slots 1–7 (slot 0, the public channel,
  is never touched). With more than 7 rooms, the oldest room loses its slot
  until it becomes active again.

## Hardware status

The BLE layer implements the MeshCore companion protocol as documented by the
open-source reference clients, and the frame codec is unit-tested against
those layouts. It has been **verified against physical radios**, alongside
the unit-test coverage. Everything above the transport also runs identically
in demo mode, which is how most app-logic iteration happens day to day.

## Donations

- Donations show a crypto address in-app (tap-to-copy + QR), configured via
  `AppSettings.donationCryptoAddress` / `donationCryptoCurrency`.

## Classic MeshCore mode

A switch at the top of the app flips between **Fellship** (rooms, zones, maps)
and **MeshCore** — a classic companion-app workflow: public channel chat,
contacts with favorites, direct messages with delivery status and retry,
node telemetry (Cayenne LPP), repeater login and remote CLI, and radio tools
(advert, rename, TX power). Both modes run simultaneously over the same radio
connection.

This mode is an independent, from-scratch implementation **inspired by
[MeshCore One](https://github.com/Avi0n/MeshCoreOne)** by Avi0n. No MeshCore
One code (GPLv3) is included. If you like that workflow, consider
[supporting MeshCore One's developer](https://github.com/sponsors/Avi0n).

## Backup & data persistence

App data (rooms, keys, messages) lives in Application Support and the iOS
Keychain, both of which survive app updates automatically. Settings →
Back up & restore additionally exports a passphrase-encrypted file
(PBKDF2-SHA256 + ChaCha20-Poly1305) containing rooms, room keys, members,
messages and your identity — user-initiated, user-held, no cloud involved.
This is an owner-approved amendment to the original spec's no-recovery rule.

## License

Public domain — [The Unlicense](LICENSE). Do anything you like with it.
Attribution appreciated but not required. See [PRIVACY.md](PRIVACY.md) for the
privacy policy.
