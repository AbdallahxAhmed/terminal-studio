# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

A changelog exists from the first commit on purpose. Retrofitting one means reconstructing history
from memory, and the reconstruction is always wrong.

## [Unreleased]

Nothing yet.

## [0.1.1] - 2026-08-11

### Changed

- **Install is now a single line with no arguments.** `bootstrap/get.ps1` previously required
  `-Version` and `-Sha256`, which a pipe into `Invoke-Expression` cannot supply — pasting the
  documented one-liner either printed the script or stopped to prompt in the middle of the paste.
  Version and hash are now resolved from a committed manifest.
- Stage 0 takes input through `TS_VERSION`, `TS_INSTALL_ROOT`, and `TS_NO_DOCTOR`, the only channel
  a bare pipe leaves open. The scriptblock form still accepts real parameters.
- Stage 0 no longer calls `exit`. Under `Invoke-Expression` that terminates the host session rather
  than the script, closing the window the user is standing in. Every failure path throws.
- Stage 0 no longer uses `#Requires -Version 5.1`. It is a directive for script *files*, and its
  behaviour when the script is a string handed to `Invoke-Expression` is not something to discover
  during an install. A numeric comparison against `$PSVersionTable` behaves identically in both
  execution modes.
- Stage 0 runs `doctor` on completion unless told not to.

### Added

- `bootstrap/releases.json`: published versions, their SHA-256 hashes, and the commit each tag
  points at. Fetching it from `main` concedes nothing, because `get.ps1` is fetched from `main` too
  — anyone able to rewrite one can rewrite the other. What the hash buys is narrower and still
  worth having: the payload cannot be swapped independently of the manifest, and a truncated
  download is refused rather than executed.
- Compatibility tests for the manifest, including one asserting that `latest` names a release that
  exists. Promoting a release means editing two fields, and forgetting the second breaks the install
  line for everyone at once.
- `Test-TSFontNameMatch`, a pure predicate for matching a desired font family against a registered
  name. Extracted from inside an enumeration loop, where it could not be tested.
- Font detection reports which interfaces were consulted (`Searched`) separately from which one
  produced the match (`Method`).

### Fixed

- **An installed font was reported as missing.** `CaskaydiaCove Nerd Font Mono` is registered and in
  daily use on the author's machine, and doctor said it was absent. Nerd Fonts registers abbreviated
  families — `CaskaydiaCove NF`, `NFM`, `NFP` — plus filename-shaped values such as
  `CaskaydiaCoveNerdFontMono-Regular`. The verbose name appears in the registry not at all. Detection
  now expands the desired name into its abbreviated aliases and tries three interfaces in order:
  font enumeration, the registry, and typeface inspection via `GlyphTypeface.FamilyNames`, which is
  the only interface reachable from PowerShell that reports the verbose name.
- **The font check answered a three-valued question with a boolean.** A font whose presence cannot be
  determined — no enumeration assembly, no readable registry — now reports `Unknown` with the reason,
  instead of `Missing`. The previous behaviour was capable of being wrong in both directions.
- **The release builder's clean-tree guard had never once run.** Two `git.exe` on `PATH` made
  `Get-Command` return an array, `$git.Path` was then an array, the call threw, and the catch left
  the guard silently disabled. It now reads `.git/HEAD` directly and reports `clean`, `dirty`, or
  `unknown`, so a guard that cannot determine the answer says so rather than passing.

### Known issues

- CI is red. The workflow fails at startup: `matrix` is referenced from `jobs.<id>.steps[*].shell`,
  which is not a context available there. It belongs in `jobs.<id>.defaults.run.shell`.
- Release archives are not byte-reproducible. Zip records modification times and `git clone` stamps
  them at checkout, so rebuilding an identical tree yields a different hash.

## [0.1.0] - 2026-08-10

First tagged build. Read-only commands only.

### Added

- Project charter and the desired-state model (`README.md`).
- ADR-0001: technology choice — PowerShell 7 module rather than a rewrite in a compiled language.
- ADR-0002: interface choice — non-interactive CLI as the primary surface, TUI as an optional view,
  no GUI.
- ADR-0003: distribution — GitHub with a tiered, integrity-verified install path.
- ADR-0004: two surfaces, one definition — the terminal form and the WPF window render the same
  control definitions rather than each hard-coding a list.
- `PSScriptAnalyzerSettings.psd1` with approved-verb and unused-parameter enforcement.
- CI workflow running lint plus a test matrix across Windows PowerShell 5.1 and PowerShell 7.
- Module skeleton with the `Public` / `Private` / `Adapters` / `UI` seam.
- `Invoke-TSDoctor`: read-only capability and drift checks, including a measured shell-startup
  budget. A tool whose product is the feel of a terminal has to measure the thing it is selling.
- `Get-TSPlan`: reads desired state and reports drift; unmodelled resource kinds are reported as
  skipped-and-unverified rather than silently treated as healthy.
- `Get-TSControl` and `ts configure`: every knob, its current value, and whether desired state
  actually binds it. Two renderers over one definition in `Data/controls.json`. No save path — there
  is no write adapter yet, and a half-built save that can leave `settings.json` in pieces is worse
  than none.
- `bootstrap/get.ps1`: 5.1-safe stage 0 with SHA-256 verification.
- `tools/New-TSRelease.ps1`: builds a release archive from a clean tree, refuses when the tag and
  `ModuleVersion` disagree, and prints a `gh release create` command pinned to the built commit.
- Desired state for the Andalus theme: Windows Terminal fragment, Oh My Posh prompt, managed
  PowerShell profile, and package and font declarations.
- Test suites: cross-edition compatibility, mocked unit tests, and mechanical architecture checks
  that enforce the adapter seam and the print-only-in-UI rule.

### Notes

There is no `apply` command, and none is stubbed. Shipping a command that looks implemented but is
not is worse than shipping nothing.

[Unreleased]: https://github.com/AbdallahxAhmed/terminal-studio/compare/v0.1.1...main
[0.1.1]: https://github.com/AbdallahxAhmed/terminal-studio/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/AbdallahxAhmed/terminal-studio/releases/tag/v0.1.0
