# Changelog

All notable changes to Fellship are recorded here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.1.1] — 2026-08-15

### Fixed
- **Room presence and messaging with a GPS-less radio.** Connecting a radio
  stopped the phone's CoreLocation entirely, so a radio with no GPS module
  (most MeshCore boards) left the app with no position at all. That kept
  `myInside` false forever, which reports you as outside every room and drops
  zone-scoped messages on arrival — the likely cause of "messages send with a
  checkmark but nobody receives them". Phone GPS now runs whenever the radio
  isn't returning a usable fix, and a stationary phone (which never trips the
  distance filter) still counts as having a position.
- **Contacts not syncing from the radio.** Contacts were read exactly once at
  connect with no retry, so a single early or failed read left Nodes
  permanently empty. Now retried with backoff on connect, re-read
  periodically, and pull-to-refresh.
- Public/group messages no longer print the sender twice ("Colin: Colin: hi")
  — the `Name:` prefix is stripped from the body now that the name is drawn
  above the bubble.
- Repeater login no longer requires a password, so repeaters configured for
  open guest access can be used.
- MeshCore public channel: some firmware acknowledges a channel send with a
  plain OK instead of echoing a SendResult. The app treated that as a failure
  and silently dropped the message you'd just typed (which had already gone
  out over the mesh) from your own history.
- Archive builds no longer trip App Store Connect's "missing dSYM for
  MapLibre.framework" warning — an archive-only step fetches the matching
  dSYM from MapLibre's release, verifies its UUID against the linked binary,
  and installs it. Fails soft if offline or mismatched.
- Line of sight terrain data was mislabeled as SRTM; it's Copernicus DEM
  GLO-90 via Open-Meteo. Added the CC BY 4.0 and Copernicus attribution both
  licenses require, on the terrain screen and in About → Built on.
- Messages stored by earlier versions still decode after the reactions field
  was added — Swift's synthesized decoder throws on missing keys rather than
  using defaults, which would otherwise have wiped chat history on upgrade.

### Added
- **Message reactions** — long-press a room message to react; reactions
  travel as their own tiny mesh frame and show as tappable pills.
- **#channels in MeshCore mode** — join group channels by name (everyone
  using the same name derives the same key) or with a shared key, each with
  its own thread. Rooms and channels now allocate radio slots from opposite
  ends of the same range so they can't overwrite each other.
- **Room area on a map in room settings**, visible to every member, showing
  the boundary and whether you're currently inside it.
- **Telemetry gets its own page**, presented as soon as you request it, plus
  a "Share my telemetry with" setting (see its note about what the app can
  and cannot enforce).
- Contact import/export now has real destinations: copy, share sheet, the raw
  code beside the QR, bulk "Export all contacts", and pasting a whole list.
- Tools → Line of sight fetches a real elevation profile between you and the
  selected node (Copernicus DEM GLO-90 via open-meteo.com), with editable
  antenna heights and a terrain chart showing whether the path clears the
  ground plus 60% Fresnel-zone clearance. User-triggered only.

### Changed
- Geofenced rooms are inside-only for sending. An unknown position warns
  rather than muting you.
- Removed the NASA GIBS satellite layer (~250 m/px, not worth keeping);
  anyone using it moves back to OpenStreetMap.
- New Monero donation address.

## [1.0.1] — 2026-07-07

### Added
- MeshCore (classic) mode: full contact management matching the MeshCore One
  workflow — add/import a contact and save it to the radio's persistent list,
  share a node or your own contact card as a QR code, reset a contact's
  routing path, and share a contact over the mesh. Contacts continue to live
  in the radio's own memory and sync across both modes.

### Fixed
- Nodes screen: the "add contact" toolbar action could be dropped by SwiftUI
  when combined with search; consolidated node actions into a single reliable
  menu and added Add/Share buttons to the empty state.

## [1.0.0] — 2026-07-06

First release.

### Added
- **Fellship mode** — location-aware mesh rooms over stock MeshCore radios:
  - Geofenced rooms: circle (radius up to 10,000 mi via a log-scale slider
    with a user-set ceiling in Settings → Zones), box, or a tap-to-place
    straight-line outline you close explicitly.
  - Range-based rooms ("wherever the mesh reaches") for convoys and trail
    groups.
  - Invite-only and public rooms, with proximity auto-invites for public
    rooms (you still accept).
  - Per-room location visibility, enforced at the broadcast level.
  - Three messaging modes: whole-room, zone-scoped, and direct 1:1.
  - Enter/exit and presence notifications (local only, no push server).
- **MeshCore mode** — a classic companion workflow running alongside Fellship
  on the same radio: public channel + direct chat; Nodes with search, type
  filters, sort and favorites; a node map; and Tools with radio controls
  (advert, rename, TX power) and network diagnostics (radio statistics, live
  packet monitor, trace path with per-hop SNR, line-of-sight estimate, remote
  CLI terminal). Independent clean-room implementation inspired by MeshCore
  One; contains no GPL-licensed code.
- Per-room ChaCha20-Poly1305 encryption; keys held in the Keychain and
  delivered via a Curve25519 sealed box at invite acceptance, or face-to-face
  by QR code.
- MapLibre offline maps with three keyless-or-BYO tile sources (OpenStreetMap,
  NASA GIBS satellite, custom provider), downloadable offline regions, and
  shared side controls (base-layer picker, north-up, recenter) on both maps.
- Radio GPS as the source of truth with an explicit, labeled phone fallback;
  a single global update interval shared across all rooms.
- Passphrase-encrypted backup and restore (PBKDF2-SHA256 + ChaCha20-Poly1305)
  of rooms, keys, members and messages.
- Six free accent themes plus a light/dark/system override.
- In-app privacy policy and a "not a safety device" disclaimer; donations via
  an in-app crypto address (tap-to-copy + QR), no in-app purchases.

### Security
- Location-sharing audit: presence omits coordinate bytes entirely when a
  room's sharing is off; the public-room discovery beacon is coarsened to
  ~250 m and its mesh-wide, unencrypted nature is disclosed in-app and in the
  privacy policy.
- Hostile-member hardening: membership and presence are capped, display names
  and messages length-clamped, and the room trust model (shared symmetric key)
  is documented rather than over-claimed.
- SQL is fully parameterized; all untrusted mesh input is decoded without
  crashing; the Keychain uses device-only, after-first-unlock storage.

### Known limitations
- The BLE layer implements the documented MeshCore companion protocol and is
  unit-tested against those frame layouts, but has **not been verified against
  physical radios**. Everything above the transport runs in demo mode.
- More than 7 rooms oversubscribe the radio's channel slots; the oldest room
  loses its slot until active again.
- Room messages are capped at 120 characters (LoRa frame budget).

[Unreleased]: https://github.com/scotCW/fellship-ios/compare/v1.1.1...HEAD
[1.1.1]: https://github.com/scotCW/fellship-ios/compare/v1.0.1...v1.1.1
[1.0.1]: https://github.com/scotCW/fellship-ios/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/scotCW/fellship-ios/releases/tag/v1.0.0
