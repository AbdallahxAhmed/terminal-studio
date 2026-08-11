# ADR-0005 — Argument-free install through a committed release manifest

**Status:** accepted, 2026-08-11

## Context

The README documented this install line:

```powershell
irm https://.../bootstrap/get.ps1 | iex
```

It did not work. Pasting it printed the source of `get.ps1` and returned to the prompt.

The cause was structural rather than a bug. `Invoke-Expression` receives a *string*, not a file and
not an argument list, so there is no channel through which `-Version` or `-Sha256` could arrive.
Stage 0 declared both as mandatory parameters, and PowerShell's response to a mandatory parameter
with no value is to prompt — mid-paste, from a script the user cannot see, on a machine where they
were expecting an install.

Three further properties of `iex` execution turned out to matter, each discovered the hard way:

1. **`exit` terminates the host session.** Under `Invoke-Expression` there is no separate script
   scope to exit from, so a failure path calling `exit 1` closes the window the user is standing in,
   taking the error message with it.
2. **`#Requires` is a directive for script *files*.** Its behaviour when the script arrives as a
   string is not something to discover during someone's first install.
3. **The pipe is the only interface.** Whatever configuration exists has to travel through something
   that survives it.

The deeper problem: an install line that requires the user to first look up a version number and a
SHA-256 is not a one-liner. It is a two-step process with a copy-paste step in the middle, and the
middle step is exactly where people give up.

## Decision

Published versions and their hashes live in **`bootstrap/releases.json`, committed to the
repository**. Stage 0 fetches that manifest, resolves the release named `latest`, and verifies the
downloaded archive against the hash recorded there.

Concretely:

- No mandatory parameters anywhere in stage 0.
- Input arrives through `TS_VERSION`, `TS_INSTALL_ROOT`, and `TS_NO_DOCTOR` — environment variables
  survive a pipe. The scriptblock form still accepts real parameters for anyone who wants them.
- No `exit` on any path. Failures throw.
- No `#Requires`. A numeric comparison against `$PSVersionTable` behaves identically whether the
  script is executed as a file or as a string.
- Recording a release is two edits: append the entry, move `latest`. A compatibility test asserts
  that `latest` names an entry that actually exists.

## Consequences

**The install line is genuinely one line.** No version to look up, no hash to paste.

**The manifest is fetched from `main`, a moving reference.** This looks like a weakness and mostly
is not, because `get.ps1` is fetched from `main` too: anyone able to rewrite the manifest can rewrite
the script that reads it. Piping any URL into an interpreter means trusting whoever controls that
URL, and no amount of hashing changes that.

What the hash does buy is narrower and still worth having:

- The release asset cannot be swapped independently of the manifest. Substituting a payload requires
  a commit to this repository, which leaves a record.
- A truncated or corrupted download is refused rather than executed.

**Forgetting to record a release is now a failure mode.** Its consequence is that `irm ... | iex`
keeps installing the *previous* release, which is the correct direction to fail in: stale beats
broken. The test on `latest` catches the other half — a manifest pointing at a release that was
never published.

**Hash verification can be waived, loudly.** `-SkipHashCheck` exists for local builds and says
plainly what was given up.

## Alternatives considered

**Keep the parameters and document the scriptblock form as the primary install.**

```powershell
& ([scriptblock]::Create((irm ...))) -Version v0.1.0 -Sha256 4B59...
```

This works and remains supported. It was rejected as the *primary* path because it is unreadable,
unmemorable, and still requires looking up two values first. The form exists for pinning, which is
the case where deliberately typing a version is the entire point.

**Resolve `latest` from the GitHub releases API instead of a committed file.**

Tempting — no second edit to forget. Rejected because it makes the install path depend on an
authenticated-by-default API with rate limits that a corporate NAT can exhaust, and because the
response is not something a reviewer can read in a diff. A hash in a commit is auditable; a hash
returned by an API at install time is not.

**Embed the hash in `get.ps1` itself.**

Rejected: it couples every release to a rewrite of the bootstrap, so the file users are asked to read
before running changes on every publish. A stable script and a moving manifest is the better split.

**Skip integrity verification entirely.**

Rejected. It costs four lines. The `-SkipHashCheck` escape hatch covers the local-build case without
making the default weaker.

## Verification

`tests/compat/Bootstrap.Compat.Tests.ps1` asserts, under both PowerShell engines, that stage 0 has no
mandatory parameters, calls `exit` nowhere, carries no `#Requires`, retains a runtime engine guard,
downloads from `/releases/download/`, verifies with `Get-FileHash`, and that `latest` names a release
present in the list.

Confirmed working in production on 2026-08-11: the bare pipe, the pinned environment-variable form,
and the scriptblock form all install and run `doctor`.
