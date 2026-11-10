# Changelog

Every release of Maben Sweep. The newest version is at the top. The app shows the section for its own version under About.

## 1.0 · 10 November 2026

- First version. Finds your projects and shows the folders that come back with one command: dependencies, build output and caches.
- Cleans projects you haven't used for 60 days, after a warning, once you turn automatic cleanup on.
- Only removes a folder when git ignores it, git tracks nothing inside it, and the file that proves what made it sits next to it.
- History keeps the command that brings each folder back, with a Restore button.
- Caches lists the shared caches of Xcode, npm, Homebrew and others, to clean by hand.
