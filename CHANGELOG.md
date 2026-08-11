# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

A changelog exists from the first commit on purpose. Retrofitting one means reconstructing history
from memory, and the reconstruction is always wrong.

## [Unreleased]

Nothing yet.

## [0.2.0] - 2026-08-11

The release that makes the project do what it was named for. A version numbered 0.1.1 was prepared
earlier the same day and never published; its contents ship here.

### Added

- **`ts apply`.** Converges the four file resource kinds — Windows Terminal fragment, backdrop asset,
  Oh My Posh theme, and the shell profile. It deliberately does **not** install packages, fonts, or
  modules; it checks them and reports the exact command that would. The boundary and the condition
  for moving it are recorded in ADR-0006.
- **A change journal** at `%LOCALAPPDATA%\TerminalStudio\journal.jsonl`. One JSON line per change,
  carrying the previous and new hashes, the backup path, and a run id shared across the run. Nothing
  is appended when a file already matches, so it records changes rather than invocations. This is the
  primitive that will make uninstall a replay rather than a hand-maintained mirror of the installer.
- **Backups.** Every replaced file is copied to `%LOCALAPPDATA%\TerminalStudio\backups` before it is
  overwritten, and the path appears in both the report and the journal.
- **`-WhatIf` on `apply`**, enforced at the write itself rather than re-decided by each layer above
  it. `tests/unit/Apply.Tests.ps1` asserts that a dry run creates no file and writes no journal line.
- **Fragment effectiveness detection.** Windows Terminal layers defaults, then fragments, then the
  user's `settings.json`, and the last layer to mention a property wins. A fragment deployed onto a
  profile whose `settings.json` already sets the same properties is installed, correct, and
  invisible. `doctor` and `apply` now report that as `applied but overridden` and name the properties
  responsible, instead of showing a green check next to a change nobody can see.
- Filesystem write adapters: staged atomic copy, timestamped backup, hash comparison, and line append.
- `docs/usage.md` — every command, the exit-code contract, the journal record format, and how to undo
  a change by hand while journal-driven uninstall does not exist.
- `docs/troubleshooting.md` — real failures with their verbatim error text.
- ADR-0005: argument-free install through a committed release manifest.
- ADR-0006: `apply` converges files and delegates everything else.
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

### Changed

- **`doctor` and `plan` now model every resource kind in the document.** Both previously ended with
  four resources reported as `not modelled`, which was honest and unhelpful.
- **Managed files are compared by content hash rather than by existence.** Existence is the easier
  question and the wrong one: a fragment deployed before its source was edited exists, is stale, and
  passes an existence check while the machine no longer matches the repository. `doctor`, `plan`, and
  `apply` now use the same comparison, so they cannot disagree about the same machine.
- **Install is a single line with no arguments.** `bootstrap/get.ps1` previously required
  `-Version` and `-Sha256`, which a pipe into `Invoke-Expression` cannot supply — pasting the
  documented one-liner either printed the script or stopped to prompt in the middle of the paste.
  Version and hash are now resolved from the committed manifest.
- Stage 0 takes input through `TS_VERSION`, `TS_INSTALL_ROOT`, and `TS_NO_DOCTOR`, the only channel
  a bare pipe leaves open. The scriptblock form still accepts real parameters.
- Stage 0 no longer calls `exit`. Under `Invoke-Expression` that terminates the host session rather
  than the script, closing the window the user is standing in. Every failure path throws.
- Stage 0 no longer uses `#Requires -Version 5.1`. It is a directive for script *files*, and its
  behaviour when the script is a string handed to `Invoke-Expression` is not something to discover
  during an install. A numeric comparison against `$PSVersionTable` behaves identically in both
  execution modes.
- Stage 0 runs `doctor` on completion unless told not to.
- `ts.ps1` declares `SupportsShouldProcess`, so `-WhatIf` propagates down the call stack instead of
  being a parameter each layer has to remember to honour.
- `apply` exits `2` when anything is left undone, including the resources it delegates. Exiting `0`
  while the report immediately above lists four uninstalled packages would put the exit code in
  direct contradiction with its own output.
- Unmodelled-kind messages no longer name a specific version, so they cannot go stale in place.

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
  which is not a context available there. It belongs in `jobs.<id>.defaults.run.shell`. The fix
  cannot be pushed through the current credentials, which lack the workflow scope.
- Release archives are not byte-reproducible. Zip records modification times and `git clone` stamps
  them at checkout, so rebuilding an identical tree yields a different hash.
- `desired-state/machine.json` declares a backdrop asset that is not committed, because binaries are
  not kept in this repository. `apply` reports it as a failure with the path it expects, which is the
  correct behaviour and still an unfinished piece of setup.
- Both `font` resources carry an empty `sha256`. Until those are filled in, font installation cannot
  be adopted by `apply` without making its own integrity checking decorative.

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

[Unreleased]: https://github.com/AbdallahxAhmed/terminal-studio/compare/v0.2.0...main
[0.2.0]: https://github.com/AbdallahxAhmed/terminal-studio/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/AbdallahxAhmed/terminal-studio/releases/tag/v0.1.0
