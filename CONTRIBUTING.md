# Contributing to Fellship

Thanks for helping! A few ground rules keep the project true to its spec.

## Hard constraints (not up for debate)

These come from the project's founding spec and are treated as invariants:

1. **No backend.** No servers, no cloud sync, no push infrastructure, no paid
   APIs billed to the project. If a feature seems to need one, open an issue
   to discuss — don't quietly add one.
2. **Stock MeshCore firmware only.** Nothing may require flashing modified
   firmware. Only use companion-protocol features that ship in current stock
   releases.
3. **Local-first.** Room data lives on members' devices, full stop. The only
   sanctioned copy is the explicit, passphrase-encrypted, user-held backup in
   Settings — never anything automatic, and never a cloud.
4. **No IAP.** Donations stay a plain crypto address / external link.
5. **Themes are free.** All of them, forever.
6. **No GPL code.** The repo is public-domain (Unlicense); code from GPL
   projects (including MeshCore One) cannot be copied in. Clean-room
   reimplementation only.
7. **Honest background behavior.** Don't promise real-time background
   detection; iOS doesn't offer it and neither do we.

## Practical notes

- Build with current Xcode; the only dependency is MapLibre Native via SPM.
- `FellshipTests` must pass (`⌘U`, or `xcodebuild test`). New protocol or
  crypto code needs tests.
- The frame codec in `Mesh/MeshCoreProtocol.swift` mirrors the layouts used by
  the open-source MeshCore reference clients. If firmware behavior diverges
  from these layouts on real hardware, a fix + a note about the board and
  firmware version is gold.
- UI copy: plain language, honest about mesh/background limitations, never
  marketing-speak.
- Demo mode (`Mesh/SimulatedTransport.swift`) should keep working — it's how
  contributors without radios exercise the app.

## Reporting hardware results

The BLE path needs real-device validation. When testing on hardware, please
include: board, firmware version, what worked, and hex dumps of any frames
that failed to parse (Xcode console logs them).
