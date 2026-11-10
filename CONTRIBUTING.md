# Contributing to Maben Sweep

Thanks for helping. This page explains how changes get from an idea to everyone's Mac.

## How the code flows

```
your fork / branch ──PR──▶ main ──release.sh + publish.sh──▶ tag vX.Y.Z + GitHub release ──▶ every Mac updates itself
```

- **`main`** is always releasable. Every change arrives through a pull request.
- **Branches** are short-lived and named after what they do: `fix/monorepo-lockfile`, `feature/bun-cache`,
  `docs/install-steps`. One topic per branch.
- **Releases** are tags `vX.Y.Z` on `main`, created only by the maintainer with `publish.sh`. A GitHub release is
  what installed copies update to, so nothing reaches users before it's tagged and released.

## Making a change

1. Fork the repository (or, if you have write access, create a branch).
2. Build: `swift build`. `./build.sh demo` opens the app on made-up projects without touching your files.
3. Test: `swift test` for the core, and `.build/debug/Sweep --selftest "$(mktemp -d)"` for the app end to end.
4. If people will notice the change, add a line under the top section of `CHANGELOG.md`. Don't change the version
   in `Info.plist`; that happens when releasing.
5. Open a pull request into `main` and fill in the template.

## Changes to what may be removed

Sweep deletes folders, so these get the closest look:

- A new folder goes in `Sources/SweepCore/Rules.swift`, next to the file that proves which tool made it. The
  cleaning code doesn't change.
- Every change to `Rules.swift`, `Safety.swift` or `Cleaner.swift` comes with a test in
  `Tests/SweepCoreTests` that builds the situation in a real git repository: one that shows the folder is
  removed, and one that shows what keeps it.
- When in doubt, a folder asks first (`tier: .ask`). Automatic cleanup only touches folders that are certain.

## What a pull request needs before it's merged

These are enforced by the repository rules on `main`:

- The **Build and test** check passes (GitHub Actions: debug and release build, core tests, the app self-test,
  scripts, changelog).
- One approving review from a code owner (`.github/CODEOWNERS`).
- All review conversations resolved.
- Merged with **squash**, so `main` has one commit per pull request and a straight history. The branch is deleted
  after merging.
- No force pushes to `main`, and `main` can't be deleted.

Tags matching `v*` can only be created, moved or deleted by repository admins, so only the maintainer can release.

## Releasing (maintainer)

1. Bump `CFBundleShortVersionString` in `Info.plist` (`1.0.1` for fixes, `1.1` for features) and make sure
   `CHANGELOG.md` has a section `## <version> · <date>`.
2. Merge to `main`, then on an up-to-date `main`: `./release.sh` (builds, signs, notarizes).
3. `./publish.sh`: tags `vX.Y.Z`, creates the GitHub release with `Maben-Sweep.dmg` and `Maben-Sweep.zip`, and
   updates sweep.maben.gg.

Installed copies check GitHub at start and every 6 hours, verify the Developer ID signature and Apple's
notarization, and install while no scan or cleanup is running.

## Style

- Swift: follow the code around you. Comments explain why, not what.
- User-facing text: short, plain sentences, sentence case, no jargon.
- Keep the Maben look: dark, one accent colour (`MB.accent`), see `MabenUI.swift`.

## Code of conduct

Be kind and assume good intent. Harassment isn't tolerated.
