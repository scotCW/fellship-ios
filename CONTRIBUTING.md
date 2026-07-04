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
3. **Local-first, no recovery.** Room data lives on members' devices, full
   stop. Don't add backup/restore/export of room keys or history.
4. **No IAP.** Donations stay an external link.
5. **Honest background behavior.** Don't promise real-time background
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
