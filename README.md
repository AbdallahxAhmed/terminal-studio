# Terminal Studio

**Make one person's terminal environment a reproducible, versioned, reversible artifact.**

This is a configuration-management problem with a fleet size of one. It is *not* an installer
problem. That distinction drives every decision in this repository.

> **Status: pre-alpha.** `doctor` is being built first, on purpose. `apply` does not exist yet and
> is not stubbed out to pretend otherwise. See [Roadmap](#roadmap).
>
> **CI is currently red.** The workflow fails at startup: `matrix` is referenced from
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
| `ts apply` | yes | Make the machine match the desired state. |

Three properties fall out of this for free, none of which an imperative installer can offer:

- **Idempotence.** `apply` twice equals `apply` once. That is a testable assertion, not a hope.
- **Reversibility.** Rolling back is `git checkout <tag> && ts apply`. There is no separate
  uninstaller to keep in sync.
- **Auditability.** Every change is a diff in a versioned file, reviewable before it runs.

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
Those remain a small, schema-validated, journaled merge, deliberately scoped to the ~10% that
fragments genuinely cannot cover.

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

## Quick start

Clone and run. `doctor` is read-only and will not change anything on your machine.

```powershell
git clone https://github.com/AbdallahxAhmed/terminal-studio
cd terminal-studio
./ts.ps1 doctor
```

Every command below assumes you are in that directory. `./tools/...` and `./ts.ps1` are relative
paths, so they resolve against your current location and nothing else.

To see the configuration surface — every knob, its current value, and whether the desired state
actually binds it:

```powershell
pwsh -File ./ts.ps1 configure -ReadOnly     # terminal form, draws without reading input
pwsh -STA -File ./ts.ps1 configure -Surface Wpf
pwsh -File ./ts.ps1 configure -Json         # the model itself
```

`configure` has no save path yet, by design: there is no write adapter, and a half-built save that
can leave `settings.json` in pieces is worse than no save at all. It exits 3 to say so.

## Installing from a release

Take the tag and hash from the
[Releases page](https://github.com/AbdallahxAhmed/terminal-studio/releases) — every release publishes
both, along with this line already filled in:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/AbdallahxAhmed/terminal-studio/main/bootstrap/get.ps1))) -Version v0.1.0 -Sha256 PASTE_THE_PUBLISHED_HASH
```

`PASTE_THE_PUBLISHED_HASH` is a bareword rather than the usual `<angle-bracket>` placeholder because
`<` is a reserved operator in PowerShell: an angle-bracket placeholder does not fail with "you forgot
the hash", it fails at parse time with a message about an operator you never typed.

Note the shape of the command too. The familiar `irm ... | iex` form **cannot** run this script:
piping into `Invoke-Expression` passes no arguments, and `-Version` is mandatory, so the shell would
stop and prompt for it mid-line. Fetching the script on its own is a fine way to read it before
trusting it:

```powershell
irm https://raw.githubusercontent.com/AbdallahxAhmed/terminal-studio/main/bootstrap/get.ps1
```

`-Sha256` is not optional either. TLS proves who served the bytes, not what the bytes are. Pass the
published hash, or pass `-SkipHashCheck` and accept unverified content as a deliberate choice.

## Cutting a release

Build from a fresh clone. The script refuses a dirty working tree, because an archive containing
uncommitted changes cannot be rebuilt from the tag that names it, and the hash would then be
authoritative for bytes that exist nowhere in history.

```powershell
$build = Join-Path $env:TEMP 'ts-build'
Remove-Item $build -Recurse -Force -ErrorAction SilentlyContinue
git clone --depth 1 https://github.com/AbdallahxAhmed/terminal-studio $build
& "$build/tools/New-TSRelease.ps1" -Version v0.1.0
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
- [x] `ts configure` — one control definition, two renderers, read-only
- [x] Release builder and verified bootstrap
- [ ] Green CI
- [ ] Byte-reproducible archives (normalised timestamps)
- [ ] `ts doctor` — read-only capability and drift detection
- [ ] Desired-state schema and Windows Terminal fragment extraction
- [ ] Adapter seam with mocked unit tests
- [ ] `ts plan` — diff desired against observed
- [ ] `ts apply` — converge, journaled, idempotent
- [ ] Journal-driven uninstall (no hand-maintained mirror of the installer)
- [ ] Signed releases with build provenance attestation

## Decisions

- [ADR-0001 — Technology: PowerShell 7 module](docs/adr/0001-technology-powershell-module.md)
- [ADR-0002 — Interface: CLI first, TUI as a view, no GUI](docs/adr/0002-interface-cli-first.md)
- [ADR-0003 — Distribution: GitHub with a verified bootstrap](docs/adr/0003-distribution-github-verified-bootstrap.md)
- [ADR-0004 — Two surfaces, one definition](docs/adr/0004-two-surfaces-one-definition.md)
- [Architecture overview](docs/architecture.md)

## License

MIT. See [LICENSE](LICENSE).
