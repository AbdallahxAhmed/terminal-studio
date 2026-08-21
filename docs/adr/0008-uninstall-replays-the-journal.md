# ADR-0008 — Uninstall is a backwards replay of the change journal

**Status:** accepted, 2026-08-21

## Context

The project's predecessor maintained four hand-written uninstall scopes mirroring its installer.
They drifted immediately, because the same knowledge was written down twice: once as the list of
things the installer did, and once as the list of things the uninstaller undid. Every change to the
first list was a silent bug in the second.

ADR-0006 already committed to the alternative. The change journal exists specifically so uninstall
can be a replay, and it records more than `apply` needs for its own purposes: the previous hash, the
new hash, the backup path, and a run id. `apply` uses none of those to decide anything. They are
there for the reverse direction.

What was left was the question of what a replay is allowed to do when the machine has moved on. A
journal record describes the world at the moment of a write. By the time anyone runs `uninstall`,
the file may have been edited by hand, replaced by another tool, deleted, or moved along with the
whole profile onto a new machine. An uninstaller that treats its record as current fact will
cheerfully overwrite work it never made.

## Decision

**`uninstall` reads the journal, walks it newest first, and reverses each forward record. It changes
nothing whose current hash disagrees with what the journal says was written.**

The reversal rules are one line each:

| Forward record | Reverse |
| --- | --- |
| `create` | delete the destination |
| `replace` | restore the recorded backup over the destination |
| `edit` | restore the recorded backup over the edited document |

And the guards, each of which exists because of a specific way this can go wrong:

- **The destination is hashed before it is touched.** If it does not match `newSha256`, the file has
  changed since `apply` wrote it, and the result is `SKIP` with the reason. Someone else's edit is
  not this command's to revert.
- **A missing destination is a `SKIP`, not a failure.** Already gone is the state uninstall exists to
  produce.
- **The backup is hashed before it is restored.** A backup that no longer matches `previousSha256`
  has stopped being evidence of anything, and restoring it would be a guess dressed as a safety
  feature. That is a `FAIL` with both hashes printed.
- **Backups are also looked up by leaf name under the backup root.** Journalled paths are absolute,
  so they stop resolving after a profile move or a restore onto another machine — while the backup
  directory is the one part of that path still known to be right.
- **An unparsable line costs a warning, not the run.** A journal is appended to by a process that can
  be killed mid-write; one torn line must not cost the user the rest of their history.
- **Undo records are journalled, and are not themselves reversible.** Only `create`, `replace` and
  `edit` are forward actions. The mirror records carry `undoOf` and the action `remove` or `restore`,
  so the history stays complete without a second `uninstall` putting the files back.
- **`-WhatIf` reports what would be undone and writes nothing** — including nothing to the journal.

Scope is selected explicitly: the most recent run by default, `-RunId` for one named run, `-All` for
every recorded change. An empty or absent journal is `PASS` with `no recorded changes`, so a script
can run `uninstall` unconditionally.

## Consequences

**Uninstall cannot undo anything that was not journalled.** Packages, fonts and gallery modules are
delegated by ADR-0006 and never recorded, so they are never reversed. This is the boundary working
as designed rather than a gap in it.

**The journal is now load bearing.** Deleting `%LOCALAPPDATA%\TerminalStudio\journal.jsonl` does not
break `apply`, and it does silently reduce `uninstall` to a no-op. `docs/usage.md` says so where
someone about to clean up a directory will read it.

**A restore leaves the destination not matching the journal**, so a second `uninstall -All` reports
it as changed and leaves it alone. Correct outcome, imprecise sentence; recorded in the changelog's
known issues rather than papered over with a special case that would have to distinguish *our*
restore from *your* edit using the same single hash.

**Every record format change is now a two-sided change.** `configure -Save` writes `edit` records
that `uninstall` replays, and `tests/unit/JsonEdit.Tests.ps1` ends by undoing a save, so the seam has
a test that fails when either half moves.

## Alternatives considered

**Hand-written uninstall logic mirroring `apply`.**

The predecessor's approach, and the reason this project exists. Rejected: it stores the same
knowledge twice and the copies drift on the first change.

**Restore backups unconditionally, without the hash gate.**

Simpler, and it turns a cleanup command into a data-loss command the first time someone edits a
managed file after applying. Rejected outright; this is the property the whole design is arranged
around.

**Reverse by re-reading desired state and removing whatever it declares.**

Rejected: it undoes what the *current* document describes, not what was actually done. Edit the
document between apply and uninstall and files quietly become orphans that nothing will ever clean
up. The journal describes events; the document describes intentions.

**Delete the backups after a successful restore.**

Rejected for now. Disk is cheap and a second chance is not, and a restore that turns out to be the
wrong call should still be recoverable.
