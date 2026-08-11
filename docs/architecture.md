# Architecture

## One sentence

The repository is the desired state; the module is an engine that reports on, plans, and converges a
machine toward it.

## Layers

```
              ts.ps1                  thin argument parsing, exit codes
                |
         UI/  (renderers)             the only place Write-Host is allowed
                |   ^
                v   |  objects flow up, calls flow down
         Public/  (the API)           returns plan/result objects, never prints
                |
         Private/ (helpers)           no OS contact whatsoever
                |
         Adapters/                    the ONLY code that touches the OS
                |
        registry, winget, filesystem, fonts, Windows Terminal, WSL
```

### Rule 1 — Adapters are the only OS contact

Every registry read, file read, process launch, and package query lives in `Adapters/`. Nothing
else may touch the operating system.

This is not tidiness. It is the difference between a testable system and an untestable one. With
the seam, a unit test mocks `Test-TSWingetPresent` and asserts that `doctor` reports the right
remediation on a machine without winget — in milliseconds, with no real machine involved. Without
the seam, that test needs a real Windows box held in a known-bad state, so in practice it is never
written.

### Rule 2 — The UI is called from above, never from within

`Public/` functions return objects. `UI/` functions render them. A feature function must never
print.

The predecessor project violated this and paid for it precisely: because feature code called the
menu renderer directly, `-NonInteractive -Action Theme` still opened an interactive menu. The flag
was not badly implemented, it was *unimplementable* given the dependency direction. Nothing could
be exercised headlessly, so nothing was tested.

Both rules are asserted mechanically in `tests/unit/Architecture.Tests.ps1`. An architecture rule
that lives only in a document is a suggestion.

## Two-stage bootstrap

A single-file installer that targets PowerShell 7 has an unavoidable contradiction: it must run
before PowerShell 7 exists. Any modern syntax anywhere in the file is a latent crash on a clean
machine, because the parser reads the whole file before executing a line of it.

So the entry point is split, and the split is load-bearing:

| Stage | Constraint | Responsibility |
| --- | --- | --- |
| 0 — `bootstrap/get.ps1` | 5.1-safe, no 7-only syntax, ~50 lines | verify the engine, resolve the release, verify artifact integrity, unpack, hand off |
| 1 — `src/TerminalStudio` | `#Requires -Version 7.4` | everything else, free to use modern syntax |

Stage 0 is kept short for a second reason: it is the file a user is asked to execute from a URL.
Fifty readable lines can actually be audited in thirty seconds. Four hundred cannot, and a
bootstrap nobody can audit makes the convenience one-liner indefensible.

Stage 0 carries no `#Requires` directive and calls `exit` nowhere, because it is executed as a
*string* through `Invoke-Expression` rather than as a file. Both of those are consequences of the
delivery mechanism rather than style choices — see
[ADR-0005](adr/0005-argument-free-install-via-release-manifest.md).

`tests/compat/` runs under both engines and fails if stage 0 drifts out of 5.1 compatibility.

## Resource model

Each kind of managed thing implements the same three operations. This mirrors DSC deliberately, so
resources can be handed off to `winget configure` or a real DSC resource later without reshaping
the engine.

| Operation | Contract |
| --- | --- |
| `Get` | observe current state; no side effects |
| `Test` | compare observed against desired; return match plus the differing properties |
| `Set` | converge; must be safe to run when already converged |

`doctor` is `Get` plus capability checks. `plan` is `Test` across all resources. `apply` is `Set`
over whatever `Test` reported as differing. Building `Test` first is why `doctor` comes before
`apply`: it is genuinely half of every future resource, and it ships value while being harmless.

All three answer the file-comparison question with the same arithmetic — a SHA-256 of the managed
copy against the deployed one. Three implementations of one idea is how `plan` and `apply` end up
disagreeing about the same machine.

`Set` is implemented for the four resource kinds that are a file arriving at a known path. Packages,
fonts, modules, and global terminal settings are reported and delegated, for reasons recorded in
[ADR-0006](adr/0006-apply-converges-files-only.md).

## Change journal

Every `apply` appends a record of what changed, including the previous hash and the path of the
backed-up file, to an append-only journal at `%LOCALAPPDATA%\TerminalStudio\journal.jsonl`. This is
the primitive that makes uninstall mechanical rather than guessed.

```json
{"timestamp":"...","runId":"...","action":"replace","kind":"terminal.fragment",
 "name":"...","source":"...","destination":"...",
 "previousSha256":"...","newSha256":"...","backup":"..."}
```

`runId` is shared by every change in one run, so a run can be reversed as a unit rather than file by
file. Nothing is appended when a file already matches, which keeps the journal a record of *changes*
rather than of invocations.

The predecessor maintained four hand-written uninstall scopes mirroring the installer, and they
drifted immediately: modules it installed were never removed, the stable Windows Terminal it removed
was never restored, and timestamped backup files accumulated forever. None of that is a coding
mistake. It is the inevitable result of representing the same knowledge in two places and hoping
they stay in sync.

With a journal there is only one place: uninstall replays the journal backwards. That command is not
built yet; the record it will read is.

## Observability

Colored console output is a user interface, not a log. It cannot be piped, filtered, correlated, or
attached to a bug report.

- Human output: `UI/` renderers, on the host stream.
- Machine output: structured JSONL with a per-run correlation id, on an explicit path.
- `--json` on every command, for composition.
- Exit codes are part of the contract, not an afterthought.
- Errors are classified as retryable, fatal, or partial. Without that distinction a runner cannot
  retry, resume, or roll back — it can only stop.

Diagnostic bundles are redacted before they are written. The predecessor's shareable log embedded
the machine name and username on every line.

## Current status against this document

This document describes the target design. Where the implementation has caught up:

| Described | Status |
| --- | --- |
| Layering and the adapter seam | built, and enforced by `tests/unit/Architecture.Tests.ps1` |
| Two-stage bootstrap | built, verified in production, cross-engine tests in `tests/compat/` |
| `Get` — `doctor` | built, all eight resource kinds modelled |
| `Test` — `plan` | built, agrees with `doctor` by construction |
| `Set` — `apply` | built for the four file kinds; the rest delegated (ADR-0006) |
| Change journal | built; written by `apply`, not yet read by anything |
| `--json` on every command | built |
| Exit codes as contract | built |

Still unbuilt, and not stubbed:

- **Journal-driven uninstall.** The record exists; the replay does not.
- **JSONL diagnostic logging.** `Write-TSLog` still writes only to PowerShell streams. The change
  journal is structured and on disk; the *diagnostic* log is not.
- **Error classification** into retryable, fatal, and partial.
- **Redacted diagnostic bundles.**
- **Convergence of packages, fonts, modules, and global terminal settings.** Deliberate, with a
  stated condition for adopting each one (ADR-0006).
- **A save path for `configure`.** It exits `3` rather than pretending.

The gap is tracked in the README roadmap rather than hidden behind stubs. A command that looks
implemented and is not costs more than one that is absent.
