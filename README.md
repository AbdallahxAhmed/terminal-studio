# Terminal Studio

**Make one person's terminal environment a reproducible, versioned, reversible artifact.**

This is a configuration-management problem with a fleet size of one. It is *not* an installer
problem. That distinction drives every decision in this repository.

> **Status: alpha.** All four verbs are implemented. `apply` converges the file resources — terminal
> fragment, prompt theme, backdrop, shell profile — with backups, an append-only journal, and
> `-WhatIf`. It deliberately does **not** install packages, fonts, or modules; it reports them with
> the command that would. See [ADR-0006](docs/adr/0006-apply-converges-files-only.md).
>
> **0.2.0 is on `main` and not yet published.** The install one-liner currently serves **v0.1.0**,
> which predates `apply` and carries a font-detection bug. Cut a release to move it.
>
> **CI is red.** The workflow fails at startup: `matrix` is referenced from
> `jobs.<id>.steps[*].shell`, which is not one of the contexts available there. The fix is to move
> it to `jobs.<id>.defaults.run.shell`, where `matrix` *is* available.

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
| `ts configure` | none yet | What can I turn on or off, and what is currently set? |
| `ts apply` | **yes** | Make the machine match the desired state. |

Three properties fall out of this, none of which an imperative installer can offer:

- **Idempotence.** `apply` twice equals `apply` once. Source and destination are compared by SHA-256
  before anything is written, and `tests/unit/Apply.Tests.ps1` asserts that a second run appends
  nothing to the journal.
- **Reversibility.** Every replaced file is backed up and every change is journaled with its previous
  hash. There is no separate uninstaller to keep in sync.
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
| [Usage](docs/usage.md) | every command, exit codes, the change journal, undoing a change |
| [Troubleshooting](docs/troubleshooting.md) | real failures with their verbatim error text |
| [Architecture](docs/architecture.md) | the layers, the two-stage bootstrap, what is and is not built |
| [Decisions](docs/adr/) | six ADRs — why each significant choice was made, and what was rejected |

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

Not claimed yet: signed releases and build provenance attestation. Both are on the roadmap. Until
they exist, the trust boundary is this repository's commit history. Full reasoning in
[ADR-0005](docs/adr/0005-argument-free-install-via-release-manifest.md).

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

To see the configuration surface — every knob, its current value, and whether the desired state
actually binds it:

```powershell
pwsh -File ./ts.ps1 configure -ReadOnly     # terminal form, draws without reading input
pwsh -STA -File ./ts.ps1 configure -Surface Wpf
pwsh -File ./ts.ps1 configure -Json         # the model itself
```

`configure` has no save path yet, by design: persisting choices means round-tripping a JSON document
the user hand-edits, and silently losing their comments and ordering is not an acceptable cost. It
exits 3 to say so.

## Cutting a release

Build from a fresh clone. The script refuses a dirty working tree, because an archive containing
uncommitted changes cannot be rebuilt from the tag that names it, and the hash would then be
authoritative for bytes that exist nowhere in history.

```powershell
$build = Join-Path $env:TEMP 'ts-build'
Remove-Item $build -Recurse -Force -ErrorAction SilentlyContinue
git clone --depth 1 https://github.com/AbdallahxAhmed/terminal-studio $build
& "$build/tools/New-TSRelease.ps1" -Version v0.2.0
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

**The archive is not byte-reproducible.** Zip stores file modification times, and `git clone` stamps
those at checkout, so rebuilding from identical sources yields a different hash. Publish the archive
you built; do not rebuild afterwards and expect the published hash to match. Normalising those
timestamps is on the roadmap and is a prerequisite for meaningful build provenance.

`-AllowDirty` overrides the clean-tree check, and produces a release that cannot be reproduced from
its tag. Use it for throwaway builds, never for a published one.

### Recording the release

This last step is the one that keeps the one-liner working. After the release is published, add it
to `bootstrap/releases.json` and push:

```json
{
  "version": "v0.2.0",
  "asset": "TerminalStudio-v0.2.0.zip",
  "sha256": "the hash the builder printed",
  "tagCommit": "the commit the tag points at",
  "published": "2026-08-11"
}
```

Then move `latest` to the new tag. Both edits are needed; a test asserts that `latest` names an entry
that actually exists, because forgetting the second edit breaks the install line for everyone at once.

Recording *after* publishing is deliberate. The hash describes the bytes actually uploaded, and since
archives are not byte-reproducible, a rebuild of the same commit will not match. Never edit a recorded
hash to make a rebuild agree — publish a new version instead.

Until the entry is pushed, `irm ... | iex` keeps installing the previous release. That is the correct
failure mode: stale beats broken.

## Running the tests

```powershell
./tests/Invoke-Tests.ps1
```

The runner selects its suite by engine: compatibility tests run under both Windows PowerShell 5.1
and PowerShell 7, unit tests run under 7 only. The CI matrix runs both legs on every push — see the
status note at the top; it is not passing yet.

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
- [ ] Green CI
- [ ] Journal-driven uninstall (no hand-maintained mirror of the installer)
- [ ] A save path for `configure`
- [ ] JSONL diagnostic logging with a correlation id
- [ ] Have the release builder write the `releases.json` entry itself
- [ ] Byte-reproducible archives (normalised timestamps)
- [ ] Font installation, once the declared hashes are filled in
- [ ] Signed releases with build provenance attestation

## Decisions

- [ADR-0001 — Technology: PowerShell 7 module](docs/adr/0001-technology-powershell-module.md)
- [ADR-0002 — Interface: CLI first, TUI as a view, no GUI](docs/adr/0002-interface-cli-first.md)
- [ADR-0003 — Distribution: GitHub with a verified bootstrap](docs/adr/0003-distribution-github-verified-bootstrap.md)
- [ADR-0004 — Two surfaces, one definition](docs/adr/0004-two-surfaces-one-definition.md)
- [ADR-0005 — Argument-free install through a committed release manifest](docs/adr/0005-argument-free-install-via-release-manifest.md)
- [ADR-0006 — `apply` converges files and delegates everything else](docs/adr/0006-apply-converges-files-only.md)
- [Architecture overview](docs/architecture.md)

## License

MIT. See [LICENSE](LICENSE).
