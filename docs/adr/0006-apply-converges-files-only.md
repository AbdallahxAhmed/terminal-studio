# ADR-0006 — `apply` converges files and delegates everything else

**Status:** accepted, 2026-08-11

## Context

`apply` is the verb the project is named for and the last one implemented. Everything that makes it
safe had to exist first: a Test operation to decide what needs doing (`plan`), somewhere to put
displaced files, a record of what was done, and a way to see the whole thing without doing it.

The desired-state document describes eight kinds of resource:

| Kind | What converging it means |
| --- | --- |
| `terminal.fragment` | copy a file |
| `terminal.asset` | copy a file |
| `omp.theme` | copy a file |
| `shell.profile` | copy a file |
| `winget.package` | launch a package manager |
| `font` | download an archive, extract, register per-user |
| `psmodule` | contact a gallery and install |
| `terminal.global` | edit the user's own `settings.json` |

The obvious reading is that `apply` should handle all eight, because a Set operation covering half
its document looks unfinished. That reading is wrong, and the reason is the change journal.

Uninstall in this project is defined as *replaying the journal backwards*. That definition is the
whole argument for the journal existing — the predecessor maintained four hand-written uninstall
scopes mirroring its installer, and they drifted immediately, because the same knowledge was
represented in two places.

A journal of file writes can be replayed backwards. A package installation cannot: the reverse of
`winget install` is not `winget uninstall`, because the package may have been present beforehand,
may be a dependency of something else, and may have upgraded a component that other software now
depends on. A font registration is reversible in principle and not while any application holds the
file open. A gallery module install pulls transitive dependencies that nothing records.

So the question is not "can `apply` shell out to `winget`" — it obviously can, in one line. The
question is whether `apply`'s report may claim more than `apply` can reverse.

## Decision

**`apply` converges the four file resource kinds. It checks the other four, reports them with the
exact command that would satisfy them, and does not run it.**

The four it manages get the full set of guarantees:

- **Idempotence by hash.** Source and destination are compared by SHA-256 before anything happens.
  Matching files are not rewritten, no backup is taken, nothing is journaled.
- **Backup before replace.** Every displaced file is copied to `%LOCALAPPDATA%\TerminalStudio\backups`
  first, and the backup path appears in the report and in the journal.
- **Journaled.** One JSON line per change, with the previous and new hashes, sharing a run id.
- **Staged writes.** Content lands at `<destination>.tsnew` and is then moved, so an interrupted write
  cannot leave a half-written fragment where Windows Terminal will try to parse it.
- **`-WhatIf` enforced at the write**, not re-decided by each layer above it.

`terminal.global` is a separate case from the other three delegations. Those are deferred for want of
adapters; this one is refused on principle. Owning the user's `settings.json` is the original sin of
every terminal setup script — Windows Terminal rewrites that file on its own schedule, it is
JSON-with-comments that a naive parse-and-reserialize destroys, and avoiding it is the entire reason
the project uses fragment extensions (see the README). `doctor` and `plan` report drift in
`defaultProfile` and window `theme`; nothing writes them.

## Consequences

**A user still runs `winget install` by hand.** `apply` prints the exact command, and `doctor` prints
it again. This is a real cost and the honest one to pay.

**`apply` exits `2` on a machine where the delegated resources are unsatisfied**, because the machine
does not match its desired state. Exiting `0` while the report immediately above lists four missing
packages would put the exit code in direct contradiction with its own output.

**The report distinguishes four outcomes**, and the least intuitive one earns its place: `WARN` means
the file was written successfully and will still not be visible, because the user's `settings.json`
overrides it. Without that state, a correctly deployed fragment on a machine with local overrides
reports green while the terminal looks untouched — which is precisely the bug found on the author's
own machine.

**The boundary can move.** Each delegated kind has a stated condition for being adopted:

| Kind | Adopt when |
| --- | --- |
| `winget.package` | there is a process adapter and a test that does not install anything |
| `font` | the declared `sha256` values are filled in, so integrity checking is not decorative |
| `psmodule` | transitive dependencies are recorded in the journal, or uninstall accepts it cannot reverse them |
| `terminal.global` | never as a blind write; only as a schema-validated, journaled, backed-up merge |

## Alternatives considered

**Have `apply` shell out to `winget install` for missing packages.**

One line of code. Rejected because it puts an irreversible operation inside a command whose defining
promise is reversibility, with no adapter, no test, and no way for the journal to describe what
happened. The predecessor's failure was not that it installed things — it was that it could not say
what it had done.

**Download and register fonts.**

Rejected today for a specific and fixable reason: both `font` resources in `desired-state/machine.json`
carry `"sha256": ""`. Downloading an archive from the internet and registering it without verifying
it, inside a tool that verifies its own release archive, would be incoherent. Fill in the hashes and
this becomes a reasonable thing to build.

**Stub the delegated kinds so the report is all green.**

Rejected outright. A green check for something never attempted is the failure mode this project was
started to avoid.

**Wait until everything could be implemented before shipping `apply` at all.**

Rejected. `apply` deploys the fragment, the prompt theme, the backdrop, and the profile — which is
the entire visible outcome the project exists to produce. Withholding that until packages can be
installed automatically would trade the whole benefit for a boundary that is only cosmetic.
