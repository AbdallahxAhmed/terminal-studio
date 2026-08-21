# Terminal Studio

**Make one person's terminal environment a reproducible, versioned, reversible artifact.**

This is a configuration-management problem with a fleet size of one. It is *not* an installer
problem. That distinction drives every decision in this repository.

> **Status: beta.** Every verb is implemented, including `uninstall`, which replays the change
> journal backwards, and a save path for `configure`. `apply` converges the file resources — terminal
> fragment, prompt theme, backdrop, shell profile — with backups, an append-only journal, and
> `-WhatIf`. It deliberately does **not** install packages, fonts, or modules; it reports them with
> the command that would. See [ADR-0006](docs/adr/0006-apply-converges-files-only.md).
>
> Three things stand between this and 1.0, and none of them is a feature:
>
> - **v0.3.0 is not published.** The install one-liner still serves **v0.1.0**, which predates
>   `apply` and carries a font-detection bug. Cutting and recording the release is what moves it.
> - **CI has never passed.** The workflow referenced `matrix` from `jobs.<id>.steps[*].shell`, which
>   is not a context available there, and failed at startup every time. The corrected workflow is
>   staged at `.github/ci.yml` and takes effect when it is moved into `.github/workflows/`.
> - **The integration suite has never run.** `tests/integration/` targets a disposable machine, and
>   nothing has verified this on a clean Windows install end to end.

---

## The model

A typical terminal setup script is a sequence of imperative steps: install this, write that, patch
the other. It works exactly once, on one machine, in one direction. You cannot ask it what it
*would* do, you cannot ask whether the machine already matches, and you cannot undo it except by
hand-maintaining a mirror-image uninstaller that inevitably drifts.

Terminal Studio inverts that. The repository holds **desired state as data**. The engine has these
verbs:

| Command | Side effects | Question it answers |
| --- | --- | --- |
| `ts doctor` | none | Is this machine capable and healthy? What is drifting? |
| `ts plan` | none | What exactly would change, and from what to what? |
| `ts configure` | only with `-Save` | What can I turn on or off, and what is currently set? |
| `ts apply` | **yes** | Make the machine match the desired state. |
| `ts uninstall` | **yes** | Undo what was actually done, from the record of doing it. |

Three properties fall out of this, none of which an imperative installer can offer:

- **Idempotence.** `apply` twice equals `apply` once. Source and destination are compared by SHA-256
  before anything is written, and `tests/unit/Apply.Tests.ps1` asserts that a second run appends
  nothing to the journal.
- **Reversibility.** Every replaced file is backed up and every change is journaled with its previous
  hash, and `uninstall` reverses those records newest first. There is no second list of things to
  undo, which is the whole point: a hand-maintained uninstaller stores the same knowledge twice and
  the copies drift on the first change. See
  [ADR-0008](docs/adr/0008-uninstall-replays-the-journal.md).
- **Auditability.** Every change is a diff in a versioned file, reviewable before it runs, and
  `apply -WhatIf` shows exactly what would happen without doing it.

## What this deliberately does not build

Roughly 70% of a hand-rolled terminal installer is work someone else already did better. This
project delegates rather than reimplements:

| Concern | Delegated to |
| --- | --- |
| Installing and pinning packages | `winget configure` / DSC v3 |
| Windows Terminal appearance | JSON **fragment extensions** (never editing `settings.json`) |
| Prompt configuration | Oh My Posh's own DSC resource |
| Font installation | Per-user install, no admin required (Win10 1809+) |

The fragment decision matters most. Owning the user's `settings.json` is the original sin of every
terminal setup script: Windows Terminal rewrites that file on its own schedule, it is JSON-with-
comments that a naive parse-and-reserialize destroys, and its path is tied to whichever channel
(Stable or Preview) happens to be installed. Fragments are additive, channel-independent, and
officially supported.

Fragments cannot express *global* settings such as `defaultProfile`, window `theme`, or keybindings.
`doctor` and `plan` report drift in those; nothing writes them.

There is a catch worth knowing before you file a bug. Windows Terminal layers **defaults, then
fragments, then your `settings.json`**, and the last layer to mention a property wins. A fragment
setting `colorScheme` on a profile whose `settings.json` entry already sets `colorScheme` is
installed, correct, and completely invisible. `doctor` and `apply` both detect this and report it as
`applied but overridden` rather than green.

## Repository layout

```
desired-state/          the product: what the machine should look like, as data
  machine.json            resources this tool owns
  winget.dsc.yaml         packages, handed verbatim to winget configure
  fragments/              Windows Terminal fragment extensions
  omp/                    Oh My Posh prompt themes
  profile/                the managed PowerShell profile
  assets/                 backdrops and other binary content
bootstrap/
  get.ps1                 stage 0. 5.1-safe. Short enough to read before running.
  releases.json           published versions and their hashes. The one-liner reads this.
src/TerminalStudio/
  Public/                 the API. Returns objects. Never prints.
  Private/                internal helpers. No OS contact.
  Adapters/               the ONLY code permitted to touch the OS. The mocking seam.
  Data/                   inert declarations. controls.json defines every knob.
  UI/                     the ONLY code permitted to call Write-Host.
tools/                  not shipped. Release building and other chores.
tests/
  compat/                 runs on BOTH 5.1 and 7. Catches cross-edition defects.
  unit/                   runs on 7. Adapters mocked.
  integration/            disposable-machine verification (Windows Sandbox)
docs/adr/               why things are the way they are
```

Two architectural rules, both **enforced by tests** rather than by good intentions:

1. **Adapters are the only code that touches the OS.** Without this seam nothing is testable.
2. **The UI is the thinnest layer and is called from above, never from within.** Features return
   plan and result objects; renderers display them. A feature that prints cannot be tested
   headlessly, and any `--non-interactive` flag it offers is a lie.

An architecture rule that is not enforced by a test is a comment.
`tests/unit/Architecture.Tests.ps1` asserts both rules mechanically.

## Documentation

| Document | What it covers |
| --- | --- |
| [Usage](docs/usage.md) | every command, exit codes, the change journal, the log, undoing a change |
| [Troubleshooting](docs/troubleshooting.md) | real failures with their verbatim error text |
| [Architecture](docs/architecture.md) | the layers, the two-stage bootstrap, what is and is not built |
| [Security](SECURITY.md) | the threat model of the install one-liner, and how to report an issue |
| [Contributing](CONTRIBUTING.md) | the seam rules, the test expectations, what a commit message is for |
| [Decisions](docs/adr/) | nine ADRs — why each significant choice was made, and what was rejected |

## Install

One line. No arguments, nothing to look up first:

```powershell
irm https://raw.githubusercontent.com/AbdallahxAhmed/terminal-studio/main/bootstrap/get.ps1 | iex
```

That resolves the release named `latest` in [`bootstrap/releases.json`](bootstrap/releases.json),
verifies the downloaded archive against the SHA-256 recorded there, unpacks it under
`%LOCALAPPDATA%\TerminalStudio\<tag>`, and runs `doctor`. Nothing on the machine is modified —
`doctor` only reads.

Reading the script before trusting it is the same command without the pipe:

```powershell
irm https://raw.githubusercontent.com/AbdallahxAhmed/terminal-studio/main/bootstrap/get.ps1
```

### Pinning a version

A pipe into `Invoke-Expression` passes no arguments, so there are two ways to say anything to it.
Environment variables, which survive the pipe:

```powershell
$env:TS_VERSION = 'v0.1.0'; irm https://raw.githubusercontent.com/AbdallahxAhmed/terminal-studio/main/bootstrap/get.ps1 | iex
```

Or the scriptblock form, which takes real parameters:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/AbdallahxAhmed/terminal-studio/main/bootstrap/get.ps1))) -Version v0.1.0
```

`TS_INSTALL_ROOT` and `TS_NO_DOCTOR` work the same way as `TS_VERSION`. In the scriptblock form,
`-Sha256` overrides the recorded hash when you have one from elsewhere, and `-SkipHashCheck`
proceeds without integrity verification while saying plainly what was given up.

### What the one-liner does and does not guarantee

The archive comes from an immutable release tag and is checked against a hash committed to this
repository in advance. Substituting a release asset therefore also requires editing `releases.json`,
and that edit leaves a commit behind.

The manifest is fetched from `main`, which looks like the moving-reference problem it is not:
`get.ps1` is *also* fetched from `main`, so anyone able to rewrite the manifest can rewrite the
script that reads it. Piping any URL into an interpreter means trusting whoever controls that URL,
and no amount of hashing changes that. What the hash does buy is narrower and still worth having:
the payload cannot be swapped independently of the manifest, and a truncated or corrupted download
is refused rather than executed.

Releases built by the release workflow carry a **build provenance attestation**, which ties the
archive to this repository, that workflow file, and the commit it was built from:

```powershell
gh attestation verify .\TerminalStudio-v0.3.0.zip --repo AbdallahxAhmed/terminal-studio
```

`get.ps1` does not check attestations, and that is deliberate: it runs on Windows PowerShell 5.1 on a
machine that may not have the GitHub CLI, and making a bootstrap depend on a tool the bootstrap is
meant to install would trade the property that matters for the one that sounds better. Full reasoning
in [ADR-0005](docs/adr/0005-argument-free-install-via-release-manifest.md) and
[ADR-0007](docs/adr/0007-releases-are-reproducible-and-attested.md).

## Working from a clone

`doctor` is read-only and will not change anything on your machine.

```powershell
git clone https://github.com/AbdallahxAhmed/terminal-studio
cd terminal-studio
./ts.ps1 doctor
```

Every command below assumes you are in that directory. `./tools/...` and `./ts.ps1` are relative
paths, so they resolve against your current location and nothing else.

To see what would change, and then to make it happen:

```powershell
./ts.ps1 plan
./ts.ps1 apply -WhatIf     # every change, nothing written
./ts.ps1 apply
```

After `apply`, close **every** Windows Terminal window and reopen. Fragments are read at application
startup; a new tab in an existing window will not pick one up.

To undo it, from the record of what was done rather than from a guess:

```powershell
./ts.ps1 uninstall -WhatIf
./ts.ps1 uninstall
```

A managed file you edited afterwards is reported and left alone — the hash it was written with is in
the journal, and a file that no longer matches is not this command's to revert.

To see the configuration surface — every knob, its current value, and whether the desired state
actually binds it:

```powershell
pwsh -File ./ts.ps1 configure -ReadOnly     # terminal form, draws without reading input
pwsh -STA -File ./ts.ps1 configure -Surface Wpf
pwsh -File ./ts.ps1 configure -Json         # the model itself
pwsh -File ./ts.ps1 configure -Save         # persist what you changed, then run apply
```

`-Save` edits desired state, not the machine; `apply` is what converges the machine onto it. Each
saved value is a text splice at the exact span of the old one, so the comments and key order in
documents you hand-edit survive, and the result is reparsed and refused unless exactly one path
changed. Without `-Save`, `configure` writes nothing and exits 0. See
[ADR-0009](docs/adr/0009-configure-save-edits-one-value.md).

## Cutting a release

Three steps, in an order that cannot be reversed: build, publish, record.

Build from a fresh clone. The script refuses a dirty working tree, because an archive containing
uncommitted changes cannot be rebuilt from the tag that names it, and the hash would then be
authoritative for bytes that exist nowhere in history.

```powershell
$build = Join-Path $env:TEMP 'ts-build'
Remove-Item $build -Recurse -Force -ErrorAction SilentlyContinue
git clone --depth 1 https://github.com/AbdallahxAhmed/terminal-studio $build
& "$build/tools/New-TSRelease.ps1" -Version v0.3.0
```

This writes the archive with `ts.ps1` at its root, the SHA-256 beside it, and a notes file, then
prints a ready-to-paste `gh release create` command. That command carries two flags worth
understanding rather than copying blindly:

- `--repo`, because `gh` otherwise infers the repository from the git remote of your *current
  directory*, and fails with `not a git repository` anywhere else — an error about git, from a
  command about releases, naming neither.
- `--target <commit>`, pinned to the commit the archive was built from. Without it `gh` tags whatever
  the default branch points at when the command runs, which need not be that tree. The release would
  then publish a hash certifying bytes its own tag does not reproduce.

The script also refuses if the tag disagrees with `ModuleVersion` in the manifest, because an archive
that misreports its own version is a defect nothing downstream would catch.

The archive is **byte-reproducible on a given runtime**: entries are added in ordinal order with a
fixed timestamp, so the same commit built twice produces the same hash. Deflate belongs to .NET
rather than to this project, so a different PowerShell or .NET version may still compress
differently — the published hash remains the authority, and reproducibility is what lets someone
else arrive at it independently.

`-AllowDirty` overrides the clean-tree check, and produces a release that cannot be reproduced from
its tag. Use it for throwaway builds, never for a published one.

If the release workflow is active, a tag push does all of this: tests, build, attestation, publish.

### Recording the release

This last step is the one that keeps the one-liner working, and it is a command rather than a JSON
snippet to hand-copy:

```powershell
& "$build/tools/New-TSRelease.ps1" -Version v0.3.0 -Force -UpdateManifest -Note 'uninstall, configure -Save, and the structured log.'
git -C $build add bootstrap/releases.json
git -C $build commit -m 'Record v0.3.0 in the release manifest'
git -C $build push
```

`-UpdateManifest` downloads the published asset, hashes those bytes, and refuses to write the entry
unless they match the archive it just built. Recording *after* publishing is therefore not a
convention anyone has to remember: before the release exists there is nothing to download, and the
step fails. It writes the entry and moves `latest` in one pass, because a test asserts that `latest`
names an entry that exists and forgetting the second edit breaks the install line for everyone at
once.

Until the entry is pushed, `irm ... | iex` keeps installing the previous release. That is the correct
failure mode: stale beats broken. It is also exactly what happened to 0.2.0, which was written up,
never tagged, and never served to anyone.

## Running the tests

```powershell
./tests/Invoke-Tests.ps1
```

The runner selects its suite by engine: compatibility tests run under both Windows PowerShell 5.1
and PowerShell 7, unit tests run under 7 only. The CI matrix runs both legs on every push — see the
status note at the top; the corrected workflow is staged and not yet active, so no run has passed.

Lint runs the analyzer over `./src`, `./bootstrap`, `./tools` and `ts.ps1` with
`PSScriptAnalyzerSettings.psd1`, and CI fails on any finding at Error, Warning or Information.

## Definition of success

One acceptance criterion, measurable, non-negotiable:

> From a clean Windows install: one command, zero prompts, exit code 0, and a new shell opens in
> **under 1000 ms** with the expected prompt and glyphs.

The startup budget is in there because a tool whose entire product is the *feel* of a terminal must
measure the thing it is selling. A typical stack of prompt engine plus icons plus directory jumper
costs well over a second of cold start if nobody is watching. `doctor` measures it and fails the
budget out loud.

## Roadmap

- [x] Charter, ADRs, lint configuration, CI matrix
- [x] `ts doctor` — read-only capability and drift detection
- [x] Desired-state schema and Windows Terminal fragment extraction
- [x] Adapter seam with mechanically enforced architecture tests
- [x] `ts plan` — diff desired against observed
- [x] `ts configure` — one control definition, two renderers, read-only
- [x] Release builder and verified bootstrap
- [x] Single-line install with no arguments
- [x] `ts apply` — converge the file resources, journaled, idempotent, `-WhatIf`
- [x] Journal-driven uninstall (no hand-maintained mirror of the installer)
- [x] A save path for `configure`, without reformatting the documents it edits
- [x] JSONL diagnostic logging with a correlation id
- [x] Have the release builder write the `releases.json` entry itself
- [x] Byte-reproducible archives (normalised timestamps)
- [x] Build provenance attestation, verifiable without a signing key *(workflow staged)*
- [ ] A green CI run *(the fix is staged at `.github/ci.yml`)*
- [ ] Publish v0.3.0, so the one-liner stops serving v0.1.0
- [ ] Run the integration suite on a disposable machine
- [ ] Font installation, once the declared hashes are filled in
- [ ] Commit the backdrop asset, or stop declaring it

## Decisions

- [ADR-0001 — Technology: PowerShell 7 module](docs/adr/0001-technology-powershell-module.md)
- [ADR-0002 — Interface: CLI first, TUI as a view, no GUI](docs/adr/0002-interface-cli-first.md)
- [ADR-0003 — Distribution: GitHub with a verified bootstrap](docs/adr/0003-distribution-github-verified-bootstrap.md)
- [ADR-0004 — Two surfaces, one definition](docs/adr/0004-two-surfaces-one-definition.md)
- [ADR-0005 — Argument-free install through a committed release manifest](docs/adr/0005-argument-free-install-via-release-manifest.md)
- [ADR-0006 — `apply` converges files and delegates everything else](docs/adr/0006-apply-converges-files-only.md)
- [ADR-0007 — Releases are reproducible, attested, and recorded after publication](docs/adr/0007-releases-are-reproducible-and-attested.md)
- [ADR-0008 — Uninstall is a backwards replay of the change journal](docs/adr/0008-uninstall-replays-the-journal.md)
- [ADR-0009 — `configure -Save` edits one value in place and proves it](docs/adr/0009-configure-save-edits-one-value.md)
- [Architecture overview](docs/architecture.md)

## License

MIT. See [LICENSE](LICENSE).
