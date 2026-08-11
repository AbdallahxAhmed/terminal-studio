# Usage

Every command, what it touches, and what it returns.

The short version: `doctor` and `plan` are safe to run at any time on any machine. `apply` is the
only command that writes anything, and `apply -WhatIf` shows you exactly what it would write
without writing it.

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
$env:TS_VERSION = 'v0.2.0'
$env:TS_NO_DOCTOR = '1'
irm https://raw.githubusercontent.com/AbdallahxAhmed/terminal-studio/main/bootstrap/get.ps1 | iex
```

A pipe into `Invoke-Expression` cannot pass arguments, which is why those are environment variables.
The scriptblock form takes real parameters instead:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/AbdallahxAhmed/terminal-studio/main/bootstrap/get.ps1))) -Version v0.2.0
```

After installing, the entry point is the unpacked copy:

```powershell
$ts = "$env:LOCALAPPDATA\TerminalStudio\v0.2.0\ts.ps1"
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

**Writes.** The only command that does.

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

## `ts configure`

**Reads. Writes nothing.** Currently exits `3`.

Every knob, its current value, and whether desired state actually binds it.

```powershell
pwsh -File ./ts.ps1 configure               # terminal form, interactive
pwsh -File ./ts.ps1 configure -ReadOnly     # draws, reads no input
pwsh -STA -File ./ts.ps1 configure -Surface Wpf
pwsh -File ./ts.ps1 configure -Json         # the model itself
```

Both surfaces render the same definition from `Data/controls.json`. Neither knows what a control
means. There is no save path yet: persisting choices means round-tripping a JSON document the user
hand-edits, and silently losing their comments and ordering is not an acceptable cost.

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
| `2` | `doctor` found failures, `plan` found changes, or `apply` left work undone |
| `3` | the command exists but is not implemented in this version |

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

`runId` is shared by every change in one `apply`, which is what will let uninstall reverse a run as a
unit rather than file by file.

### Undoing a change by hand

Journal-driven uninstall is not built yet. Until it is, the journal plus the backups are enough to
reverse anything `apply` did:

```powershell
$journal = "$env:LOCALAPPDATA\TerminalStudio\journal.jsonl"

# What happened, most recent last
Get-Content $journal | ForEach-Object { $_ | ConvertFrom-Json } |
    Format-Table timestamp, action, kind, destination

# Reverse the most recent change that replaced something
$last = Get-Content $journal | ForEach-Object { $_ | ConvertFrom-Json } |
    Where-Object { $_.action -eq 'replace' } | Select-Object -Last 1

Copy-Item -LiteralPath $last.backup -Destination $last.destination -Force
```

Entries with `"action": "create"` had no previous version, so reversing one means deleting the
destination rather than restoring a backup.

---

## Cutting a release

See the README section on [cutting a release](../README.md#cutting-a-release). The short form:

```powershell
$build = Join-Path $env:TEMP 'ts-build'
Remove-Item $build -Recurse -Force -ErrorAction SilentlyContinue
git clone --depth 1 https://github.com/AbdallahxAhmed/terminal-studio $build
& "$build/tools/New-TSRelease.ps1" -Version v0.2.0
```

Then publish with the printed `gh release create` command, and record the printed hash in
`bootstrap/releases.json`. Both steps are required; the second is what keeps the install line
working.

---

## When something goes wrong

See [troubleshooting](troubleshooting.md).
