# Contributing

Thanks for helping! Mirador is a small Swift package; no Xcode project needed.

1. Xcode 16+ (Swift 6 toolchain), macOS 14+, `gh auth login`.
2. `swift build && swift test` — keep the suite green and add a test for any new rule in `MiradorCore`.
3. `./scripts/install.sh` to try the app (it replaces `~/Applications/Mirador.app`).
4. Read [AGENTS.md](AGENTS.md) for conventions (they apply to humans too): logic in Core, never block the main actor,
   backward-compatible store fields, no outward action without an explicit click.

Pull requests: one topic each, describe what changed and how you tested it (screenshots for UI changes).
Releases: push a `vX.Y.Z` tag and GitHub Actions builds and publishes the DMG — see [docs/RELEASING.md](docs/RELEASING.md).
