<!--
Thanks for contributing to Fellship! Please skim AGENTS.md for the project's
hard constraints before opening this PR. Keep the description focused.
-->

## What this changes

<!-- A short summary of the change and why. Link any related issue: Closes #NNN -->

## Type of change

- [ ] Bug fix
- [ ] New feature
- [ ] Security / CVE fix
- [ ] Dependency or toolchain update
- [ ] Docs / CI only
- [ ] Refactor (no behavior change)

## How it was tested

<!-- Commands run, simulator/hardware used, what you observed. -->

- [ ] `xcodebuild test` passes (all suites green)
- [ ] Release-configuration build succeeds
- [ ] Tested in the simulator / demo mode
- [ ] Tested against a real MeshCore radio (note board + firmware)
- [ ] Added or updated tests for new protocol/crypto/engine code

## Constraints checklist

<!-- These are non-negotiable per AGENTS.md. -->

- [ ] No backend, cloud sync, or push server introduced
- [ ] Stock MeshCore firmware only — no custom-firmware requirement
- [ ] No paid API billed to the owner; no in-app purchases
- [ ] No GPL-licensed code copied in (repo stays public-domain / Unlicense)
- [ ] No hand-rolled crypto (CryptoKit / CommonCrypto only)
- [ ] UI copy stays honest about mesh/iOS limits
- [ ] Untrusted mesh input still decodes without crashing; new collections capped

## Notes for reviewers

<!-- Anything that needs extra attention, follow-ups, or known limitations. -->
