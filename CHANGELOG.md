# Changelog

Every release of Maben Sweep. The newest version is at the top. `publish.sh` uses the section for the version it
releases as the GitHub release notes, the app shows it under About, and sweep.maben.gg/changelog is built from this file.

## Unreleased

- Looking at a folder can no longer make git run a program or fetch from a server, whatever the folder's own git settings say. Every question to git has a time limit, and a folder git can't answer for is left alone.
- A project that was never committed, inside an ignored folder of a repository (`scratch/old-site`), asks first. It used to be cleaned automatically.
- Folders with an everyday name (`dist`, `build`, `out`, `.cache`, `coverage`, `vendor`, `deps`, `bin`, `obj`, Maven's `target`) are only cleaned automatically when they hold what their tool makes, or the project's build files name them as output. Otherwise they ask first.
- A folder with a git repository anywhere inside it asks first. A dependency that a package manager checked out itself (Swift packages, Composer, Mix) still goes with the folder while nobody changed it.
- Review asks starts with nothing ticked.
- Clean idle looks at every project again right before cleaning it, and leaves one that was used since the scan.
- A program running in a project counts as use: the idle period starts when it was last seen running, not at the last changed file.
- Folders are kept as the disk spells them, so `~/code` and `~/Code` are one folder for "in use" and Never look in.
- If Sweep's saved list of projects that are never cleaned can't be read, automatic cleanup is switched off and Sweep says so. The unreadable file is kept.
- Updates: only a download from this app's releases on GitHub is accepted, the copy that goes in is the one that was checked, and the app is never missing after a failed update.
- With notifications off, Cleanup now says plainly that idle projects are still cleaned, without a warning.
- Apple's git is used before Homebrew's.
- The size next to a folder is the space that comes back when it is deleted. Data that a package store outside the folder also holds (pnpm, Bun) is no longer counted, and sizes measured the old way are measured again.

## 1.1.1 · 19 November 2026

- The app icon keeps its colour with the Dark icon style on macOS 26 and later (it showed as a black square): a cyan mark on black in Dark, and its own tinted and clear versions.

## 1.1 · 12 November 2026

- Review asks on Projects lists every folder that asks first, such as the ones in projects that aren't in git, with a tick each. Remove them all in one go instead of one Remove and one confirmation per folder. Folders in idle projects start ticked, Python environments don't.
- A project with only folders that ask first has a Review button instead of a greyed-out Clean.

## 1.0.1 · 10 November 2026

- The update switches are now on the Cleanup page, under Updates, where the other settings are. About keeps the version and a Check for updates link.

## 1.0 · 10 November 2026

- First version. Finds your projects and shows the folders that come back with one command: dependencies, build output and caches.
- Cleans projects you haven't used for 60 days, after a warning, once you turn automatic cleanup on.
- Only removes a folder when git ignores it, git tracks nothing inside it, and the file that proves what made it sits next to it.
- History keeps the command that brings each folder back, with a Restore button.
- Caches lists the shared caches of Xcode, npm, Homebrew and others, to clean by hand.
- Updates itself from GitHub, after checking the Maben signature and Apple's notarization. Both can be switched off under About.
