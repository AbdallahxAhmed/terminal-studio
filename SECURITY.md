# Security policy

## Reporting

Open a private security advisory:
https://github.com/AbdallahxAhmed/terminal-studio/security/advisories/new

If that is not available to you, open a normal issue that says only that you
have found something and how to reach you. Do not put the details in a public
issue.

This is a one-person project. A realistic expectation is a first reply within a
week, not within a day.

## What is actually exposed

The module is the least interesting part of this. Two things carry real risk.

**The bootstrap one-liner.** `bootstrap/get.ps1` is fetched from `main` and
piped into `Invoke-Expression`. Anyone who can write to this repository can run
code on the machine of anyone who pastes that line. That is inherent to the
form, not a defect in the script, and it is the reason the script is short
enough to read before it is trusted.

**The release manifest.** `bootstrap/releases.json` decides which version the
one-liner installs and which SHA-256 it must match. Substituting a release
asset is not enough to compromise an install, because the hash recorded in git
would no longer match and the bootstrap refuses to continue. Substituting the
asset *and* the recorded hash is enough - and it leaves a commit in this
repository, which is the property the design is built on.

TLS proves who served the bytes. Only the hash says what they are.

## What the tool does to a machine

`apply` writes four kinds of file: a Windows Terminal fragment, an Oh My Posh
theme, a background image, and the current user's PowerShell profile. All of
them land under the user's own profile, and none of them need elevation.

The profile is the one that matters. A PowerShell profile is executable code
that runs at every shell start, so replacing it is equivalent to arbitrary code
execution at next login. This is why every write is backed up first, recorded in
an append-only journal, and reversible with `ts uninstall`, and why `apply
-WhatIf` exists and is documented before `apply` is.

`apply` deliberately does not install packages, fonts, or modules, and does not
write `settings.json`. See `docs/adr/0006-apply-converges-files-only.md`.

## Verifying a release yourself

```powershell
(Get-FileHash .\TerminalStudio-v0.3.0.zip -Algorithm SHA256).Hash
```

Compare it against the value in `bootstrap/releases.json` at the commit you
trust, and against the attestation published with the release:

```powershell
gh attestation verify .\TerminalStudio-v0.3.0.zip --repo AbdallahxAhmed/terminal-studio
```

The attestation is what ties the archive to the workflow run and the commit that
built it. A hash on its own says the bytes did not change in transit; the
attestation says where they came from.

## Supported versions

The latest published release only. There are no backports.
