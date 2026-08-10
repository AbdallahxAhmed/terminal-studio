# ADR-0001 — Technology: a PowerShell 7 module, not a rewrite

- **Status:** accepted
- **Date:** 2026-08-10

## Context

The predecessor was roughly 2,600 lines of Windows PowerShell spread across dot-sourced script
files with no manifest, no tests, and no static analysis. The obvious reaction to that is "be
serious, rewrite it in a real language." That reaction deserves to be examined rather than obeyed.

The domain is Windows environment plumbing: the registry, appx package queries, `winget`, the WSL
CLI, `$PROFILE`, and Windows Terminal configuration.

## Options considered

1. **PowerShell 7 module** — keep the language, fix the structure.
2. **Go or Rust single binary** — real types, one artifact, a strong TUI ecosystem.
3. **C# / .NET single-file AOT** — real types, first-class Windows APIs, one signed artifact.

## Decision

Option 1. Keep PowerShell. Change the shape, not the language.

## Rationale

**The domain is native to the language.** Registry providers, `Get-AppxPackage`, DSC resources, and
`$PROFILE` are one-liners in PowerShell. In Go or Rust each is either FFI or a shell-out to
PowerShell — which means shipping both languages and gaining nothing.

**Auditability is a security property here, not a nicety.** This tool requests administrator rights,
writes certificate chain configuration under `HKLM`, and can add Defender exclusions. A user who
wants to know exactly what touches their machine can read plain-text scripts. A compiled binary
replaces that with "trust me," for precisely the operations where trust should be least required.

**Zero toolchain on the target.** PowerShell 7 must exist on the machine anyway; it is the thing
being configured.

**The quality tooling already exists.** Pester 5 for tests, PSScriptAnalyzer for static analysis,
and free Windows runners on GitHub Actions. The predecessor's problem was never the language — it
was that none of these were wired up.

## Consequences

Structure that a folder of scripts does not provide is now mandatory:

- A real module manifest (`.psd1`): version, explicit exports, declared dependencies, load contract.
- `Public` / `Private` / `Adapters` / `UI` separation, enforced by tests.
- Approved verbs only. `Do-*`, `Filter-*`, `Refresh-*`, and `Apply-*` are rejected by the linter.
- No `$Global:` state. The predecessor carried a global settings hashtable that every file mutated,
  which is what made its `-DryRun` switch untraceable.
- Functions return objects; rendering is somebody else's job.
- Aggressive delegation to `winget configure`, Windows Terminal fragments, and the Oh My Posh DSC
  resource, so the amount of code under our own maintenance shrinks rather than grows.

Accepted costs: weaker typing than a compiled language, and a TUI ecosystem that is adequate rather
than excellent. The first is mitigated by `Set-StrictMode` plus tests. The second is addressed in
ADR-0002 by consuming a .NET library from PowerShell instead of changing languages.

## Revisit if

- A single signed binary is needed for users who will not install PowerShell.
- Type errors become the dominant defect class despite strict mode and tests.

Neither condition holds for a fleet of one.
