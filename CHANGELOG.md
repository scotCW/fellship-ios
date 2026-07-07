# Changelog

All notable changes to Fellship are recorded here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- MeshCore (classic) mode: full contact management matching the MeshCore One
  workflow — add/import a contact and save it to the radio's persistent list,
  share a node or your own contact card as a QR code, reset a contact's
  routing path, and share a contact over the mesh. Contacts continue to live
  in the radio's own memory and sync across both modes.

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

[Unreleased]: https://github.com/scotCW/fellship-ios/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/scotCW/fellship-ios/releases/tag/v1.0.0
