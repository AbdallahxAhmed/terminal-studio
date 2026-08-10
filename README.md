# Terminal Studio

**Make one person's terminal environment a reproducible, versioned, reversible artifact.**

This is a configuration-management problem with a fleet size of one. It is *not* an installer
problem. That distinction drives every decision in this repository.

> **Status: pre-alpha.** `doctor` is being built first, on purpose. `apply` does not exist yet and
> is not stubbed out to pretend otherwise. See [Roadmap](#roadmap).

---

## The model

A typical terminal setup script is a sequence of imperative steps: install this, write that, patch
the other. It works exactly once, on one machine, in one direction. You cannot ask it what it
*would* do, you cannot ask whether the machine already matches, and you cannot undo it except by
hand-maintaining a mirror-image uninstaller that inevitably drifts.

Terminal Studio inverts that. The repository holds **desired state as data**. The engine has three
verbs:

| Command | Side effects | Question it answers |
| --- | --- | --- |
| `ts doctor` | none | Is this machine capable and healthy? What is drifting? |
| `ts plan` | none | What exactly would change, and from what to what? |
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
bootstrap/
  get.ps1                 stage 0. 5.1-safe. Short enough to read before running.
src/TerminalStudio/
  Public/                 the API. Returns objects. Never prints.
  Private/                internal helpers. No OS contact.
  Adapters/               the ONLY code permitted to touch the OS. The mocking seam.
  UI/                     the ONLY code permitted to call Write-Host.
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

Nothing to install yet. Once the module lands:

```powershell
git clone https://github.com/AbdallahxAhmed/terminal-studio
cd terminal-studio
./ts.ps1 doctor
```

`doctor` is read-only. It will not change anything on your machine.

## Running the tests

```powershell
./tests/Invoke-Tests.ps1
```

The runner selects its suite by engine: compatibility tests run under both Windows PowerShell 5.1
and PowerShell 7, unit tests run under 7 only. CI runs both legs on every push. This matrix is the
entire reason cross-edition defects get caught before a human sees them.

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
- [ ] `ts doctor` — read-only capability and drift detection
- [ ] Desired-state schema and Windows Terminal fragment extraction
- [ ] Adapter seam with mocked unit tests
- [ ] `ts plan` — diff desired against observed
- [ ] `ts apply` — converge, journaled, idempotent
- [ ] Journal-driven uninstall (no hand-maintained mirror of the installer)
- [ ] Signed, hash-pinned releases with build provenance attestation

## Decisions

- [ADR-0001 — Technology: PowerShell 7 module](docs/adr/0001-technology-powershell-module.md)
- [ADR-0002 — Interface: CLI first, TUI as a view, no GUI](docs/adr/0002-interface-cli-first.md)
- [ADR-0003 — Distribution: GitHub with a verified bootstrap](docs/adr/0003-distribution-github-verified-bootstrap.md)
- [Architecture overview](docs/architecture.md)

## License

MIT. See [LICENSE](LICENSE).
