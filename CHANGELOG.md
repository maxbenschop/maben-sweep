# Changelog

Every release of Maben Sweep. The newest version is at the top. `publish.sh` uses the section for the version it
releases as the GitHub release notes, the app shows it under About, and sweep.maben.gg/changelog is built from this file.

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
