# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

A changelog exists from the first commit on purpose. Retrofitting one means reconstructing history
from memory, and the reconstruction is always wrong.

## [0.3.0] - 2026-08-22

Nothing sits above this section: everything not yet published is in it, and it carries no date
because it has not been tagged. The previous section carried a date it never earned — see below.

**Two versions were prepared before this one and never published.** A version numbered 0.1.1 was
prepared on 2026-08-11, and a version numbered 0.2.0 was written up on the same day with a release
date in its heading. Neither tag was ever cut, so `bootstrap/releases.json` still names `v0.1.0` as
latest and the documented install one-liner has been serving that build to everyone who ran it. The
contents of both ship here, which is what the 0.1.1 note in the old 0.2.0 section promised for the
next published version. This section therefore covers everything since `v0.1.0`.

The headline of the folded 0.2.0 work is `apply`, and a defect in it — `apply -WhatIf` writing three
files — was found on `main` and fixed before any tag existed. It is recorded below rather than
quietly dropped, because a changelog that only lists defects unlucky enough to reach a user is a
marketing document.

### Added

- **`ts uninstall`.** Replays the change journal backwards: newest record first, each managed file
  either removed or restored from its backup. It refuses to touch anything whose current hash does
  not match what `apply` recorded writing, so a file edited afterwards is reported and left alone
  rather than overwritten by a backup that is no longer the truth. `-RunId` undoes one run, `-All`
  undoes every recorded change, and the default undoes the most recent run. Backups are verified
  against their recorded hash before being restored, and an unreadable journal line costs a warning
  rather than the rest of the history. See ADR-0008.
- **`ts configure -Save`.** The write path the configure surface has been missing since 0.1.0. It
  edits one scalar in place — a text splice at the exact span of the old value — so comments,
  key order, and formatting in the target document survive, then reparses the result and asserts
  that exactly one path changed before anything is written. Backed up, journaled as an `edit`
  record, reversible with `uninstall`, and refused for the controls it cannot express as a single
  value. See ADR-0009.
- **A structured log, off by default.** Set `TS_LOG_PATH` to a file and every run appends JSONL
  records carrying a timestamp, level, message, and the run id that the journal records for that
  same run also carry, so a log covering several runs can be separated afterwards. Unset, nothing is
  written and no directory is created. A log path that cannot be written produces one warning and
  does not take the run down with it.
- **`ts apply`.** Converges the four file resource kinds — Windows Terminal fragment, backdrop asset,
  Oh My Posh theme, and the shell profile. It deliberately does **not** install packages, fonts, or
  modules; it checks them and reports the exact command that would. The boundary and the condition
  for moving it are recorded in ADR-0006.
- **A change journal** at `%LOCALAPPDATA%\TerminalStudio\journal.jsonl`. One JSON line per change,
  carrying the previous and new hashes, the backup path, and a run id shared across the run. Nothing
  is appended when a file already matches, so it records changes rather than invocations. This is the
  primitive that makes uninstall a replay rather than a hand-maintained mirror of the installer.
- **Backups.** Every replaced file is copied to `%LOCALAPPDATA%\TerminalStudio\backups` before it is
  overwritten, and the path appears in both the report and the journal. This was the difference
  between an incident and a recoverable one the first time `apply` misbehaved.
- **`-WhatIf` on `apply`, `configure -Save`, and `uninstall`.** The decision is made at the write
  itself and the preference is passed explicitly through every layer that reaches it.
- **Fragment effectiveness detection.** Windows Terminal layers defaults, then fragments, then the
  user's `settings.json`, and the last layer to mention a property wins. A fragment deployed onto a
  profile whose `settings.json` already sets the same properties is installed, correct, and
  invisible. `doctor` and `apply` report that as `applied but overridden` and name the properties
  responsible, instead of showing a green check next to a change nobody can see.
- **Reproducible release archives.** `tools/New-TSRelease.ps1` assembles the zip entry by entry with
  a fixed entry timestamp and an ordinal entry order, so the same commit on the same runtime produces
  the same bytes and the same hash. What it still does not promise — identical output across
  different .NET versions, whose deflate is not ours — is stated in the release notes instead of
  being implied.
- **`New-TSRelease.ps1 -UpdateManifest`.** Writes the `bootstrap/releases.json` entry and promotes
  `latest`, which was previously hand-typed. It downloads the published asset, hashes those bytes,
  and refuses to write unless they match the archive built locally — which turns the manifest's own
  rule, that a release is recorded after it is published, into a precondition rather than a comment.
  `-Note` is mandatory with it.
- **A release workflow**, staged at `.github/release.yml`: tests, then build, then
  `actions/attest-build-provenance`, then `gh release create` pinned to the built commit. The
  attestation is what makes "signed releases" real — it ties an archive to this repository, this
  workflow, and this commit, verifiable with `gh attestation verify` and no key for anyone to lose.
- **`SECURITY.md`**, including the threat model of the install one-liner it actually ships, rather
  than a form letter about supported versions.
- **`CONTRIBUTING.md`**, and a Dependabot configuration for the actions the workflows pin.
- Filesystem write adapters: staged atomic copy, timestamped backup, hash comparison, line append,
  single-file delete, and full-text write.
- Test suites for the three new features: `tests/unit/Uninstall.Tests.ps1` applies for real and then
  undoes it rather than fabricating journal records, `tests/unit/JsonEdit.Tests.ps1` asserts whole
  documents rather than parsed values so that a reformat cannot pass, and
  `tests/unit/Logging.Tests.ps1` joins the log to the journal on the run id.
- `docs/usage.md` — every command, the exit-code contract, and the journal record format.
- `docs/troubleshooting.md` — real failures with their verbatim error text.
- ADR-0005: argument-free install through a committed release manifest.
- ADR-0006: `apply` converges files and delegates everything else.
- ADR-0007: releases are reproducible, attested, and recorded after publication.
- ADR-0008: uninstall is a backwards replay of the change journal.
- ADR-0009: `configure -Save` edits one value in place and proves it.
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
  `apply` use the same comparison, so they cannot disagree about the same machine.
- **`ts configure` without `-Save` now exits `0`.** It previously exited `3` to mean "read-only, no
  save path exists", which was accurate when there was no save path and is now just an error code
  for a command that did exactly what it was asked. It prints the controls, warns that nothing was
  written, and names `-Save`. Exit code `3` stays reserved rather than reused, because a script
  written against the old behaviour should not silently start taking a different branch.
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
- `ts.ps1` declares `SupportsShouldProcess` and **passes `-WhatIf` explicitly** to the module
  functions it calls. An earlier revision declared the attribute and relied on the preference
  reaching them on its own; see Fixed.
- `apply` exits `2` when anything is left undone, including the resources it delegates. Exiting `0`
  while the report immediately above lists four uninstalled packages would put the exit code in
  direct contradiction with its own output.
- `terminal.global` is reported as refused by decision rather than as `not modelled`. The two are
  different claims — one says support is coming — and ADR-0006 makes the distinction, so the report
  has to as well.
- **Lint covers `./tools` and `ts.ps1`**, not just `./src` and `./bootstrap`. The release builder had
  never been analyzed, which is how a script that gates every release came to be the least checked
  file in the repository.
- `Expand-TSPath` collapses relative segments in rooted paths, so messages built from `$PSScriptRoot`
  no longer print `Public\..\..\..` in the middle of a path the user is being asked to act on.
- Unmodelled-kind messages no longer name a specific version, so they cannot go stale in place.

### Fixed

- **`apply -WhatIf` wrote files.** A dry run created a Windows Terminal fragment, created an Oh My
  Posh theme, and replaced a shell profile, under a report headed `dry run, nothing written`.

  `$WhatIfPreference` does not cross a module boundary. A function exported from a module resolves
  preference variables through the module's session state, not the caller's, so the value set by
  `SupportsShouldProcess` on `ts.ps1` was never visible inside `Invoke-TSApply`. The renderers are
  dot-sourced into the script's own scope and therefore *did* see it — which is precisely why the
  header was correct while the engine was not, and why the output was actively misleading rather
  than merely wrong.

  `-WhatIf` is now passed explicitly at the call site and again in the splat that reaches every
  write. The backups and the journal, which were designed for a different failure, are what made the
  affected machine recoverable.

  Every unit test passed throughout. They called `Invoke-TSApply -WhatIf` directly, which always
  worked; the defect lived in the join between the entry script and the module, and nothing tested
  joins. Two tests now do: one parses `ts.ps1` and asserts the call site passes the argument, using
  the AST rather than a text search because the file now contains a comment about passing `-WhatIf`
  that a regex would match while the call site was broken. The other pins the platform behaviour
  itself, so the explicit argument cannot be deleted as redundant without a test going red.
- **CI failed at startup and had done since the first workflow run.** `matrix` was referenced from
  `jobs.<id>.steps[*].shell`, which is not a context available there; it belongs in
  `jobs.<id>.defaults.run.shell`. Fixed, along with per-job timeouts and the gallery-trust and
  `-AllowClobber` guards the 5.1 leg needs to install its own dependencies.
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
- **Release archives were not byte-reproducible**, so the hash in `releases.json` could not be
  independently arrived at by anyone. Entry timestamps are now fixed and entry order is ordinal.
- `New-TSResult` declared `[CmdletBinding()]` under a `New-` verb without `SupportsShouldProcess`,
  which the analyzer flags as a state-changing function without a gate. It builds an object in
  memory and has no state to gate, so it carries a targeted suppression with that reasoning attached
  rather than a repository-wide rule exclusion.

### Known issues

- **The workflow files in this branch are staged, not active.** They sit at `.github/ci.yml` and
  `.github/release.yml` because the credentials used to write them cannot create files under
  `.github/workflows/`. Each carries the `git mv` command that activates it, and until someone runs
  it, CI is still running the old broken workflow and no release workflow exists.
- `desired-state/machine.json` declares a backdrop asset that is not committed, because binaries are
  not kept in this repository. `apply` reports it as a failure with the path it expects, which is the
  correct behaviour and still an unfinished piece of setup.
- Both `font` resources carry an empty `sha256`. Until those are filled in, font installation cannot
  be adopted by `apply` without making its own integrity checking decorative.
- After `uninstall` restores a file, a second `uninstall -All` reports that same destination as
  changed since `apply` wrote it and leaves it alone. That is the correct outcome by the shortest
  path — the file there is the user's own content again — but the wording describes the hash gate
  rather than the history.

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

[0.3.0]: https://github.com/AbdallahxAhmed/terminal-studio/compare/v0.1.0...main
[0.1.0]: https://github.com/AbdallahxAhmed/terminal-studio/releases/tag/v0.1.0
