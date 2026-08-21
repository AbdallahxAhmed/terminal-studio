# ADR-0007 — Releases are reproducible, attested, and recorded after publication

**Status:** accepted, 2026-08-21

## Context

The install path this project documents is one line that downloads an archive and runs code out of
it. ADR-0003 accepted that trade and paid for it with a hash: `bootstrap/get.ps1` refuses a payload
whose SHA-256 does not match the one committed in `bootstrap/releases.json`.

That check was worth having and it was weaker than it looked, for three reasons that all arrived
together.

**The hash could not be independently reproduced.** `Compress-Archive` writes each file's
modification time into the zip, and `git clone` stamps every file with the moment it was checked
out. Two builds of the same commit therefore differed in every entry header. The release notes said
so out loud — a rebuild produces a different hash even from identical sources — which means the
recorded hash was only ever evidence that *the person who built it* had built it. Nobody else could
arrive at the same number, so nobody else could contradict it.

**The hash says what the bytes are and nothing about where they came from.** A hash committed in the
same repository as the script that checks it is a consistency check, not a provenance claim: whoever
can rewrite one can rewrite the other. `SECURITY.md` states this plainly.

**The manifest entry was typed by hand, from local files, before or after publishing as the moment
dictated.** The file itself carries the note that a release is recorded here after it is published,
not before — and nothing enforced it. A hand-copied hash of a local archive can describe a build that
was never uploaded, and the failure mode is not subtle: every install refuses, because the bytes
GitHub serves do not match the number in the manifest.

## Decision

**Three changes, each closing one of those gaps.**

**Archives are assembled deterministically.** `tools/New-TSRelease.ps1` no longer calls
`Compress-Archive`. It opens the zip and adds entries itself, in ordinal path order, each with a
fixed `LastWriteTime`. The same commit built twice on the same runtime produces identical bytes.

What this does not claim is stated in the release notes rather than left to be discovered: deflate
belongs to .NET, not to this project, so a different PowerShell or .NET version may compress
differently. The hash remains the authority; reproducibility only makes it checkable by someone who
is not the author.

**Releases are attested by the workflow that builds them.** The staged `release.yml` runs the test
suite, builds with the same script a human would run, and calls `actions/attest-build-provenance`
before publishing. The attestation binds the archive to this repository, this workflow file, and the
commit, and `gh attestation verify` checks it against GitHub's transparency log. This is what the
roadmap called signed releases, without a signing key for anyone to lose or leak.

**The manifest entry is written by the tool, after the fact, from the published bytes.**
`-UpdateManifest` downloads the asset from its public URL, hashes what it receives, and refuses to
write the entry unless those bytes match the archive built locally. The ordering rule the manifest
states about itself is now the mechanism: before publication there is nothing to download, so the
step fails.

`-Note` is mandatory with `-UpdateManifest`. That field is read by people deciding whether to
install, and a sentence generated from a version number would waste the one place they look.

## Consequences

**Publishing is three commands, in an order that cannot be reversed.** Build, `gh release create`,
then `-UpdateManifest`. Each step's precondition is checked by the next one, and the middle step is
the one that makes the artifact real.

**The manifest can no longer describe a release that does not exist**, which was the only failure in
this path that breaks installs for everyone simultaneously.

**A rebuild is a real verification step.** Someone who distrusts the published hash can clone the
tagged commit, run the builder, and compare — on a matching runtime, they get the same bytes. That
sentence was not true before this change.

**Provenance is available and not required.** `get.ps1` does not verify attestations: it runs on 5.1
before `gh` may exist, and adding a dependency on the GitHub CLI to a bootstrap whose entire job is
to work on a bare machine would trade the property that matters for the one that sounds better.

## Alternatives considered

**Leave archives unreproducible and keep the hash as a download-integrity check.**

This is what shipped in 0.1.0, and it is defensible. Rejected because the roadmap listed
reproducibility as an aim, and an aim that stays on a list while the notes file explains why it
cannot be met is a worse state than either doing it or dropping it.

**Sign releases with a GPG or code-signing key.**

Rejected. A key held by one person on one machine, with no rotation story and no revocation plan, is
a long-lived secret guarding a project that installs from a public repository. Build attestation
gives a stronger claim — this artifact came out of this workflow at this commit — with nothing to
steal.

**Have the release workflow update `releases.json` itself.**

Tempting, and rejected on the same ground as the manual entry. The check that makes the recorded
hash meaningful is downloading the published asset from outside the process that produced it. A step
in the same run holding the archive it just built in a local directory has no way to fail
usefully — it would confirm a file against itself, and the manifest would become a transcript rather
than a verification.

**Normalise timestamps by touching every file before compressing.**

Same outcome for the entry headers, and it rewrites the working tree to do it. Rejected: a build that
modifies the checkout it is building from cannot also be the thing that checks the checkout is clean.
