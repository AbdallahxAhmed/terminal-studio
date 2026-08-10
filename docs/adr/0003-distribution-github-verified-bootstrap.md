# ADR-0003 — Distribution: GitHub, with a verified bootstrap

- **Status:** accepted
- **Date:** 2026-08-10

## Context

The project needs a home and an install path. On Windows the conventional install path is a
one-liner that downloads a script and executes it immediately — `irm <url> | iex`. Scoop, Oh My
Posh, and Chocolatey all publish one. It is convenient, conventional, and routinely criticized.

Both the convention and the criticism deserve precision rather than a reflex.

## Decision

**GitHub is the home**, without reservation.

**A one-liner is offered, but it is pinned, minimal, and verifies before it executes.** Distribution
is tiered:

| Tier | Path | What enforces integrity |
| --- | --- | --- |
| A | `Install-PSResource TerminalStudio` | PowerShell Gallery versioning; the natural path for a module |
| B | Versioned GitHub release asset | published SHA-256, Authenticode signature with timestamp, build provenance attestation |
| C | `irm .../releases/download/vX.Y.Z/get.ps1 \| iex` | tag-pinned; its only job is fetch tier B, verify the hash, then run |
| D | `winget install` | winget verifies the hash from a reviewed manifest |

Tiers A, B, and C ship first. Tier D is deferred — see Constraints discovered.

## Why GitHub is more than hosting

- **git is the versioned desired state.** The entire reversibility model of this project is
  `git checkout <tag> && ts apply`. Version control is not incidental infrastructure here, it is the
  substrate the product is built on.
- **Actions is the missing feedback loop**, including free Windows runners for the 5.1 / 7 matrix.
  The predecessor's defining defect survived to production because no machine ever ran the code.
- **Releases** give versioned, hashable artifacts.
- **Issues** is the defect journal.
- **Artifact attestations** bind a release asset to signed SLSA build provenance via Sigstore,
  verifiable with `gh attestation verify`. Roughly eight lines of workflow YAML, free on public
  repositories.
- **A public repository makes the code that writes to `HKLM` auditable**, which is the only honest
  justification for a tool that asks for administrator rights.

## On `irm | iex`, precisely

Ranked by actual risk rather than by how often each is repeated:

1. **Mutable reference — the dominant risk.** A URL pointing at a branch means what users execute
   changes silently whenever anyone with push access, or a stolen token, changes it. This is a
   bigger practical risk than any exotic attack in the genre. **Never reference a branch. Pin to a
   tag or a release asset.**
2. **Truncation causes partial execution.** A dropped connection can execute half a script and do
   half the work. Mitigation: the entire body is defined as a function and invoked on the final
   line, so a truncated download defines functions and does nothing.
3. **No artifact integrity.** TLS protects the transport, not the payload. If the repository or the
   account is compromised, TLS is perfectly satisfied. Only a hash or a signature helps.
4. **"Read it in your browser first" is not a real defense.** A server can serve different content
   to a pipe than to a browser. Not the practical risk on a raw GitHub URL, but it must not be the
   security story.
5. **It trains the wrong reflex on the worst possible tool.** This one asks for administrator
   rights, writes certificate chain configuration, and can add Defender exclusions. Maximum blast
   radius is the worst candidate for unread remote execution.
6. **`Set-ExecutionPolicy Bypass` in install documentation** normalizes disabling the guard and
   undercuts ever shipping signed scripts. Process scope at most; signing is better.

The mitigation that makes the one-liner defensible is not a disclaimer. It is keeping stage 0 short
enough to actually read, and making it verify a hash before it runs anything. Fifty lines is
auditable. Four hundred is theatre.

## Constraints discovered

The winget community repository accepts MSIX, MSI, APPX, MSIXBundle, APPXBundle, and `.exe`
installers, plus font files. **Script-based installers are not accepted.** Tier D therefore requires
packaging this project into a real installer artifact first, which is meaningful work with no
immediate benefit for a single user. It is deliberately deferred rather than planned around.

## Consequences

- Releases are tagged, hashed, signed, and attested. No exceptions, including the first one.
- `bootstrap/get.ps1` stays around fifty lines and remains 5.1-compatible forever. Both properties
  are asserted by `tests/compat/Bootstrap.Compat.Tests.ps1`.
- Documentation never instructs a user to bypass execution policy machine-wide.
- The repository starts private and becomes public deliberately, once there is something worth
  auditing. Public is the target state: it is required for free artifact attestations, and it is
  what makes the administrator-rights request defensible.
