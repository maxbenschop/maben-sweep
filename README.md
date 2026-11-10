# Maben Sweep

A macOS menu bar app that frees disk space by removing folders that can be rebuilt (dependencies,
build output, caches) from projects you have stopped working on. It never touches anything that
doesn't come back with one command.

Part of [Maben](https://maben.gg). Product colour: Sweep cyan `#3CD3F0` with a black mark.
Bundle ID `gg.maben.sweep`, macOS 13+. The website lives in `../sweep-site/` (not live yet).

## Build

```sh
./build.sh            # builds build/Maben Sweep.app
./build.sh install    # also copies it to /Applications and opens it
./build.sh demo       # opens a debug copy on made-up projects; reads and changes nothing on disk
```

Needs the Xcode command line tools.

## How it decides

A folder is only removed when every check passes (`Sources/SweepCore/Safety.swift`):

1. Its name is on the list in `Rules.swift`, and the file that proves which tool made it sits next
   to it (`node_modules` beside a `package.json`, `target` beside a `Cargo.toml`).
2. It is a real folder inside the project. Symlinks are never followed.
3. In a git repository: git tracks nothing inside it, and a `.gitignore` rule covers it.
4. Dependencies have a lockfile, so a reinstall gives the same versions.

That gives three tiers. **Safe** is cleaned automatically. **Ask** (no lockfile, not in git, not
ignored, Python environments) is only removed with its own Remove button. **Never** (git tracks a
file inside it, or anything not on the list) isn't shown at all.

A project counts as idle from the newest of: the last commit on any branch, the last change to a
file outside the removable folders, git activity (checkout, pull, an editor refreshing the index),
the last Claude Code or Codex session in it, and the last install or build. A project with a
running program in it is never cleaned.

Every folder is checked again at the moment it is removed (`Cleaner.swift`), so an old scan can't
lead to removing something that changed since.

## Defaults

| Setting | Default |
|---|---|
| Clean idle projects automatically | Off (a new install only shows what could go) |
| Idle after | 60 days |
| Warn before cleaning | 3 days |
| Only while on power | On |
| Kinds removed | Dependencies, build output, caches (never Python environments) |
| Move to the Trash | Off (deleted right away) |
| Low disk space warning | On, below 20 GB |
| Open at login | Off; turned on when automatic cleanup is turned on |

Settings, the schedule, the history and the last scan are JSON files in
`~/Library/Application Support/Maben Sweep/`.

## Layout

| Path | What |
|---|---|
| `Sources/SweepCore/` | Scanner, safety checks, idle detection, planner, cleaner, storage. No UI. |
| `Sources/Sweep/` | The menu bar app. `MabenUI.swift` is the shared Maben look, taken from Maben Awake. |
| `Sources/SweepTool/` | `sweep scan <folder>`: prints what the app would find. Removes nothing. |
| `Tests/SweepCoreTests/` | Tests against real git repositories in a temporary folder. |

## Tests

```sh
swift test                                             # the core: 42 tests
.build/debug/Sweep --selftest <empty folder>           # the app's own model, end to end, on throwaway projects
.build/debug/Sweep --snapshot <folder>                 # PNGs of the menu and every page, with demo data
.build/debug/SweepTool scan ~/Documents                # read-only look at real projects
```

The self-test and the snapshots only exist in debug builds.

## Release

`./release.sh` builds `dist/Maben-Sweep.dmg` and `dist/Maben-Sweep.zip`: universal, hardened
runtime, signed with the Developer ID of team NJTYRVLSA8 and notarized by Apple, through the Apple
account in Xcode (needs [xcodegen](https://github.com/yonaskolb/XcodeGen)). For a new version, bump
`CFBundleShortVersionString` in `Info.plist` and add a `## <version> · <date>` section to
`CHANGELOG.md`.

Not built yet: updating itself (Maben Awake's updater reads public GitHub releases; this repository
is private for now).
