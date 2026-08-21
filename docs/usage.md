# Usage

Every command, what it touches, and what it returns.

The short version: `doctor` and `plan` are safe to run at any time on any machine. `apply`,
`configure -Save` and `uninstall` write, and each of them takes `-WhatIf` to show you exactly what it
would do without doing it.

---

## Install

```powershell
irm https://raw.githubusercontent.com/AbdallahxAhmed/terminal-studio/main/bootstrap/get.ps1 | iex
```

Resolves the release named `latest` in `bootstrap/releases.json`, verifies the archive against the
SHA-256 committed there, unpacks it under `%LOCALAPPDATA%\TerminalStudio\<tag>`, and runs `doctor`.
Nothing on the machine is modified.

To pin a version, or to skip the automatic `doctor` run:

```powershell
$env:TS_VERSION = 'v0.3.0'
$env:TS_NO_DOCTOR = '1'
irm https://raw.githubusercontent.com/AbdallahxAhmed/terminal-studio/main/bootstrap/get.ps1 | iex
```

A pipe into `Invoke-Expression` cannot pass arguments, which is why those are environment variables.
The scriptblock form takes real parameters instead:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/AbdallahxAhmed/terminal-studio/main/bootstrap/get.ps1))) -Version v0.3.0
```

After installing, the entry point is the unpacked copy:

```powershell
$ts = "$env:LOCALAPPDATA\TerminalStudio\v0.3.0\ts.ps1"
pwsh -File $ts doctor
```

---

## `ts doctor`

**Reads. Writes nothing.**

Capability and drift checks. Answers whether this machine *can* run the setup, and whether it
currently *matches* the desired state.

```powershell
./ts.ps1 doctor
./ts.ps1 doctor -SkipStartupMeasurement    # skip the slowest check
./ts.ps1 doctor -Json                      # result objects, for scripts
./ts.ps1 doctor -Unicode                   # symbol markers instead of words
```

Four statuses, and the distinction between them is the point:

| Status | Means |
| --- | --- |
| `PASS` | checked, and correct |
| `FAIL` | checked, and wrong. Always carries a remediation. |
| `WARN` | works, but something is off, or the check could not be completed |
| `SKIP` | **not checked.** Not a pass. |

A check that cannot run reports `WARN` or `SKIP`, never `FAIL`. Those are different claims: one says
the machine is wrong, the other says the check could not look. In 0.1.0 the font check conflated
them and reported an installed, in-use font as missing.

Managed files are compared by content hash rather than by existence, so a fragment that was deployed
and then edited in the repository reports as drifted rather than as present.

---

## `ts plan`

**Reads. Writes nothing.**

What `apply` would change, without changing it.

```powershell
./ts.ps1 plan
./ts.ps1 plan -All      # include resources already in the desired state
./ts.ps1 plan -Json
```

Status in a plan is a promise about `apply`:

| Status | Means |
| --- | --- |
| `PASS` | already in desired state; `apply` will not touch it |
| `FAIL` | `apply` will change this |
| `WARN` | genuinely drifted, but `apply` does not manage it |
| `SKIP` | this build cannot evaluate it |

`WARN` covers packages, fonts, modules, and global Windows Terminal settings — real drift that
`apply` will report and deliberately not fix. See below.

---

## `ts apply`

**Writes.**

```powershell
./ts.ps1 apply -WhatIf     # every change, nothing written. Run this first.
./ts.ps1 apply
./ts.ps1 apply -Json
```

### What it manages

Four resource kinds, all of which are a file arriving at a known path:

| Kind | Destination |
| --- | --- |
| `terminal.fragment` | `%LOCALAPPDATA%\Microsoft\Windows Terminal\Fragments\<app>\<name>.json` |
| `terminal.asset` | wherever the resource declares, typically `Backgrounds\` |
| `omp.theme` | wherever the resource declares, typically `~\.poshthemes\` |
| `shell.profile` | `$PROFILE.CurrentUserCurrentHost` |

### What it does not manage, on purpose

`winget.package`, `font`, `psmodule`, and `terminal.global` are checked and reported with the exact
command that would satisfy them, and are **not executed**.

This is a boundary, not an oversight. Installing a package means launching a process; installing a
font means downloading an archive whose declared hash is still blank in desired state; and none of
those can be undone by replaying a journal of file writes. A command whose report claims more than
it can reverse is the failure the journal exists to prevent.

Global Windows Terminal settings — `defaultProfile`, window `theme` — live in your own
`settings.json`, which this tool never writes. See [ADR-0006](adr/0006-apply-converges-files-only.md).

### Safety properties

- **Idempotent.** Source and destination are compared by SHA-256 first. Matching files are not
  rewritten, no backup is taken, and nothing is journaled. A second run is indistinguishable from
  the first.
- **Backed up.** Every replaced file is copied to `%LOCALAPPDATA%\TerminalStudio\backups` first, and
  the backup path appears in both the report and the journal.
- **Journaled.** Every change appends one JSON line to `%LOCALAPPDATA%\TerminalStudio\journal.jsonl`.
- **Reversible.** `ts uninstall` replays that journal backwards. See below.
- **Staged.** Files are written to `<destination>.tsnew` and then moved into place, so an interrupted
  write cannot leave a half-written settings fragment where Windows Terminal will try to parse it.
- **`-WhatIf` works all the way down.** The check happens at the write, not at each layer on the way
  there.

### After apply

Windows Terminal reads fragments at startup. Close **every** window, including other tabs, and
reopen — a new tab in an existing window will not pick up a new fragment.

If `apply` reports a fragment as written and the terminal looks unchanged, check the report for
`applied but overridden`. Windows Terminal layers defaults, then fragments, then your own
`settings.json`, and the last one to mention a property wins. A fragment setting `colorScheme` on a
profile whose `settings.json` entry already sets `colorScheme` is installed, correct, and invisible.
Clear the local value with the reset arrow beside it in Settings.

---

## `ts uninstall`

**Writes.** Undoes what `apply` and `configure -Save` recorded doing.

```powershell
./ts.ps1 uninstall -WhatIf              # what would be undone
./ts.ps1 uninstall                      # the most recent run
./ts.ps1 uninstall -RunId <guid>        # one named run
./ts.ps1 uninstall -All                 # every recorded change
```

It reads the journal, walks it newest first, and reverses each record: a `create` is deleted, a
`replace` or an `edit` is restored from its backup. There is no second list of things to undo — that
is the whole point, and [ADR-0008](adr/0008-uninstall-replays-the-journal.md) records why.

### What it refuses to do

- **A file whose current hash does not match what `apply` recorded writing is left alone**, reported
  as `SKIP`. If you edited a managed file afterwards, that edit is not this command's to revert.
- **A backup that no longer matches its recorded hash is not restored**, reported as `FAIL` with both
  hashes. A backup that has changed has stopped being evidence of anything.
- **A destination that is already gone is `SKIP`**, not a failure. Already absent is the state this
  command exists to produce.
- **An unreadable journal line costs a warning**, not the run. A journal is appended to by a process
  that can be killed mid-write, and one torn line must not cost you the rest of your history.

Undo records are journaled too, carrying `undoOf` and an action of `remove` or `restore`, so the
history stays complete. They are not themselves replayable — running `uninstall` twice does not put
the files back.

It cannot undo what was never recorded: packages, fonts and gallery modules are delegated by
ADR-0006, so `apply` never installed them and `uninstall` never removes them. And if you delete
`journal.jsonl`, `uninstall` becomes a no-op that reports `no recorded changes` — `apply` keeps
working, and its history is gone.

---

## `ts configure`

**Reads by default. Writes with `-Save`.**

Every knob, its current value, and whether desired state actually binds it.

```powershell
pwsh -File ./ts.ps1 configure               # terminal form, interactive
pwsh -File ./ts.ps1 configure -ReadOnly     # draws, reads no input
pwsh -STA -File ./ts.ps1 configure -Surface Wpf
pwsh -File ./ts.ps1 configure -Json         # the model itself
pwsh -File ./ts.ps1 configure -Save         # persist what you changed
pwsh -File ./ts.ps1 configure -Save -WhatIf # what it would write
```

Both surfaces render the same definition from `Data/controls.json`. Neither knows what a control
means.

Without `-Save`, nothing is written and the command exits `0` with a warning naming `-Save`. It
used to exit `3`, back when there was no save path at all.

### What `-Save` writes, and what it does not

It edits **desired state**, not the machine. The report says so, and the next step is `apply`:

```powershell
pwsh -File ./ts.ps1 configure -Save
./ts.ps1 apply -WhatIf
./ts.ps1 apply
```

Each saved control is a text splice at the exact span of the old value, so comments, key order and
formatting in the target document survive — these are files you are invited to hand-edit, and a
parse-and-reserialize would silently reformat all of them. The edited text is reparsed and compared
against the original before anything is written, and the write is refused unless exactly one path
changed and it is the one you asked for. See
[ADR-0009](adr/0009-configure-save-edits-one-value.md).

Three things it will not do:

- **Containers.** A control whose target is an object or an array is refused, because a splice of a
  container is where "replace these characters" stops being provably local.
- **Presence controls.** "Is this package in the list" is not a value to set. Those report `SKIP`.
- **Your `settings.json`.** Unchanged by this feature, for the reasons in ADR-0006.

Saves are backed up, journaled as `edit` records, and reversible with `ts uninstall`.

---

## `ts version`

```powershell
./ts.ps1 version
```

---

## Exit codes

The same convention across every command, because a tool that exits `0` whether or not the machine
matches cannot be used in a pipeline.

| Code | Meaning |
| --- | --- |
| `0` | success; nothing would change |
| `1` | unexpected error |
| `2` | `doctor` found failures, `plan` found changes, or `apply`, `configure -Save` or `uninstall` left work undone |
| `3` | reserved. It used to mean "the command exists but is not implemented", and nothing returns it now. |

`apply` returns `2` for anything left undone, including the resources it deliberately delegates.
Exiting `0` while the report immediately above lists four uninstalled packages would put the exit
code in direct contradiction with the output, and the exit code is the half a script can read.

```powershell
./ts.ps1 doctor -SkipStartupMeasurement
if ($LASTEXITCODE -eq 2) { 'this machine has drifted' }
```

---

## The change journal

`%LOCALAPPDATA%\TerminalStudio\journal.jsonl` — one JSON object per line, append-only.

```json
{
  "timestamp": "2026-08-11T05:40:12.3456789Z",
  "runId": "6f1e2c3a-...",
  "action": "replace",
  "kind": "terminal.fragment",
  "name": "Fragment: andalus",
  "source": "C:\\...\\desired-state\\fragments\\andalus.json",
  "destination": "C:\\...\\Fragments\\TerminalStudio\\andalus.json",
  "previousSha256": "9C1F...",
  "newSha256": "4B59...",
  "backup": "C:\\...\\backups\\20260811-054012-andalus.json"
}
```

`runId` is shared by every change in one run, which is what lets `uninstall` reverse a run as a unit
rather than file by file.

Five actions appear in the journal:

| Action | Written by | Reversed by |
| --- | --- | --- |
| `create` | `apply`, for a destination that did not exist | deleting it |
| `replace` | `apply`, over an existing file | restoring `backup` |
| `edit` | `configure -Save`, carrying the JSON `path` it changed | restoring `backup` |
| `remove` | `uninstall`, mirroring a reversed `create` | nothing; undo records are not replayed |
| `restore` | `uninstall`, mirroring a reversed `replace` or `edit` | nothing |

### Reading it

```powershell
$journal = "$env:LOCALAPPDATA\TerminalStudio\journal.jsonl"

Get-Content $journal | ForEach-Object { $_ | ConvertFrom-Json } |
    Format-Table timestamp, runId, action, kind, destination
```

To undo something, use `ts uninstall`. Earlier versions of this page recommended copying a backup
over its destination by hand, which skips the check that the destination is still the file `apply`
wrote — the one way to follow the documentation and lose your own edit.

---

## The structured log

Off unless you ask for it. Point `TS_LOG_PATH` at a file:

```powershell
$env:TS_LOG_PATH = "$env:LOCALAPPDATA\TerminalStudio\ts.log.jsonl"
./ts.ps1 apply
```

One JSON object per line, with a `timestamp`, `level`, `message`, and the same `runId` the journal
records for that run carry — so a log covering many runs can be split by joining the two on it.

```powershell
Get-Content $env:TS_LOG_PATH | ForEach-Object { $_ | ConvertFrom-Json } |
    Where-Object runId -eq '6f1e2c3a-...'
```

With the variable unset, nothing is written and no directory is created. If the path cannot be
written, you get one warning and the run continues — a logger that can abort the operation it is
describing is worse than no logger.

---

## Cutting a release

Three steps, in an order that cannot be reversed. See also
[ADR-0007](adr/0007-releases-are-reproducible-and-attested.md).

```powershell
# 1. Build from a clean clone. Refuses if the tree is dirty, or if the tag and
#    ModuleVersion disagree.
$build = Join-Path $env:TEMP 'ts-build'
Remove-Item $build -Recurse -Force -ErrorAction SilentlyContinue
git clone --depth 1 https://github.com/AbdallahxAhmed/terminal-studio $build
& "$build/tools/New-TSRelease.ps1" -Version v0.3.0

# 2. Publish with the gh command it printed.

# 3. Record it. This downloads the published asset, hashes those bytes, and
#    refuses to write unless they match what step 1 built.
& "$build/tools/New-TSRelease.ps1" -Version v0.3.0 -Force -UpdateManifest -Note '<what changed>'
git -C $build add bootstrap/releases.json
git -C $build commit -m 'Record v0.3.0 in the release manifest'
git -C $build push
```

Step 3 is what makes the install one-liner serve the new version. Skip it and everyone keeps getting
the previous release, which is exactly what happened to 0.2.0.

If the release workflow is active, steps 1 and 2 happen on a tag push, and the archive is attested
so anyone can check where it came from:

```powershell
gh attestation verify .\TerminalStudio-v0.3.0.zip --repo AbdallahxAhmed/terminal-studio
```

---

## When something goes wrong

See [troubleshooting](troubleshooting.md).
