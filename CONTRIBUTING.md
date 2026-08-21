# Contributing

This is a small project with strong opinions, and most of them are written down
as tests. Reading `tests/unit/Architecture.Tests.ps1` will tell you more about
what is acceptable here than this file can.

## Running the tests

```powershell
Install-Module -Name Pester -MinimumVersion 5.5.0 -Scope CurrentUser -SkipPublisherCheck -Force
./tests/Invoke-Tests.ps1
```

Run it under `pwsh` and under `powershell` at least once before opening a pull
request. The two engines run different suites on purpose:

- `tests/compat` runs everywhere. It parses `bootstrap/get.ps1` with whichever
  parser is hosting it, which is the only honest way to prove stage 0 works on a
  machine that does not have PowerShell 7 yet.
- `tests/unit` runs on Core only, because it imports a module that declares
  `#Requires -Version 7.4`.

CI runs both legs on `windows-latest`, plus PSScriptAnalyzer over `./src`,
`./bootstrap`, `./tools` and `./ts.ps1` with the settings file in the repository
root.

## The four rules the tests enforce

1. **Presentation lives in `src/TerminalStudio/UI` and nowhere else.** Nothing
   outside that folder may call `Write-Host` or a `Show-*` function. This is what
   makes `-Json` and a rendered report equal clients of the same function, and it
   is why a non-interactive path is possible at all.
2. **The operating system is reached only through `Adapters`.** Code in `Public`
   or `Private` may not call `Get-Content`, `Set-Content`, `Get-ItemProperty`,
   `Start-Process`, `winget`, and friends. Add an adapter function instead.
3. **Public commands are one approved `Verb-Noun` pair**, declare
   `[CmdletBinding()]`, and define a function whose name matches the file name.
   The manifest's `FunctionsToExport` must list exactly the files in `Public`.
4. **No global mutable state.** No `$Global:` anywhere.

A rule with a failing build attached is a rule; a rule in a document is a
suggestion. If you disagree with one of them, change the test in the same pull
request and say why in the message.

## Commit messages

Subject line in the imperative, then a body that explains *why*, including what
the alternative was and what it would have cost. `git log` in this repository is
part of the documentation, and it is read.

A commit message that only restates the diff is a message that will be read once
and never again.

## Decisions

Anything that changes the shape of the project - a new resource kind, a new
writer, a change to what `apply` is allowed to touch - gets an ADR in
`docs/adr/`, numbered in sequence, in the same pull request. ADR-0006 is the one
to read first: it fixes the boundary of `apply`, and a pull request that widens
that boundary needs to argue with it rather than around it.

Two things will be refused on sight, because they are the failures this project
exists to avoid:

- Writing the user's `settings.json`. Windows Terminal owns that file, rewrites
  it on its own schedule, and permits comments in it that a parse-and-reserialize
  destroys. Fragments exist so that no tool has to touch it.
- Any change to the machine that the journal cannot reverse. If `ts uninstall`
  cannot undo it by replaying a record, `apply` does not do it - it reports it
  with the command that would.

## Adding a control to the configurator

Edit `src/TerminalStudio/Data/controls.json`. Both surfaces - the terminal form
and the WPF window - render whatever the definition describes, so a new checkbox
is a data change and not a code change in two places.

## Cutting a release

```powershell
./tools/New-TSRelease.ps1 -Version v0.3.0
```

It refuses to build from a dirty tree, refuses when the tag and the manifest's
`ModuleVersion` disagree, writes the archive, its SHA-256 and its release notes,
and prints the `gh release create` command with the tag pinned to the commit the
archive was built from. Pass `-UpdateManifest` after the release is published to
record it in `bootstrap/releases.json`, which is what the install one-liner
reads.

Record a release in the manifest *after* publishing it, never before. The hash
in that file describes bytes that actually exist at a URL.
