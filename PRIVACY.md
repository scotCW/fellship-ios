# Fellship Privacy Policy

*Effective: July 2026*

Fellship is built so that there is nothing for anyone to collect. This policy
is short because the honest answer to almost every privacy question about
Fellship is: **the data never leaves your device or your mesh.**

## What Fellship stores, and where

| Data | Where it lives | Who can see it |
|---|---|---|
| Your display name | Your device | Members of rooms you join |
| Rooms, members, message history | Your device (local database) | Only you |
| Room encryption keys, your identity key | Your device's Keychain | Only you |
| Your location | Your radio/device; broadcast only inside rooms you joined, only when that room's location sharing is on, encrypted with that room's key | Members of that room |
| Your map API key (optional, bring-your-own provider) | Your device's Keychain | Only you and your chosen map provider |
| Optional backups you export | Wherever you save them, encrypted with a passphrase you choose | Anyone with the file **and** your passphrase |

## What Fellship sends over the internet

Only map tiles. When you view or download maps, tile requests go to the map
provider you selected (OpenFreeMap, NASA GIBS, or your own provider). Those
requests necessarily reveal your IP address and the map areas you request to
that provider, governed by their privacy policies. Offline map downloads exist
precisely so you can do this once at home and never again in the field.

Everything else — presence, positions, messages, invites — travels
**radio-to-radio over the LoRa mesh**, never over the internet.

## What the developer receives

Nothing. There is no server, no account system, no analytics, no crash
reporting, no advertising SDK, and no telemetry of any kind. The developer has
no ability to see your messages, your location, your contacts, or even the
fact that you use the app.

## Mesh radio realities

LoRa is a shared radio medium. Fellship encrypts all room traffic
(ChaCha20-Poly1305, per-room keys) on top of MeshCore's transport encryption,
so message *content* is protected — but the *existence* of radio transmissions
from your location is observable by anyone with radio equipment, as with any
radio technology. Plain direct messages to non-Fellship MeshCore users are
protected by MeshCore's own contact encryption only.

## Deletion

Deleting a room, a conversation, or the app permanently destroys that data on
your device. There is no copy anywhere else, and no recovery — by design.
Backups you exported yourself are yours to keep or delete.

## Children

Fellship has no accounts, no data collection, and no social discovery beyond
radio range; no special provisions apply beyond the above.

## Changes

If this policy ever changes, the updated text ships inside the app and in the
source repository — there is no mechanism (and no desire) to notify you via
collected contact information, because none exists.

## Contact

Questions: open an issue on the project's source repository.
