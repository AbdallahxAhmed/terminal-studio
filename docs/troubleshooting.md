# Troubleshooting

Every symptom here happened during development, with the error text exactly as it appeared. Some
are bugs that have been fixed; several are not bugs at all and never will be, and knowing about them
is the only cure.

---

## Install

### The one-liner prints the script instead of running it

```
#Requires -Version 5.1
<#
.SYNOPSIS
    Terminal Studio stage 0 bootstrap.
...
```

**Cause:** an older `get.ps1` declared mandatory parameters. A pipe into `Invoke-Expression` passes a
*string*, not an argument list, so there is no channel through which `-Version` could arrive.
PowerShell's response is to prompt — mid-paste, from a script the user cannot see.

**Fixed** in 0.2.0. If you still see it, you are reading a cached copy; the current script resolves
its version from `bootstrap/releases.json`. See [ADR-0005](adr/0005-argument-free-install-via-release-manifest.md).

### `Invoke-WebRequest: Not Found`

```
Invoke-WebRequest:
Line |  96 |      Invoke-WebRequest -Uri $uri -OutFile $archive -UseBasicParsing
     | Not Found
```

**Cause:** the manifest names a release that was never published, or the asset name in the manifest
does not match the file attached to the tag.

**Fix:** check that the tag exists and carries an asset called `TerminalStudio-<tag>.zip`. Recording
a release means two edits to `releases.json` — appending the entry and moving `latest` — and this is
what forgetting the first one looks like.

### The install window closes when something goes wrong

**Cause:** an `exit` on a failure path. Under `Invoke-Expression` there is no script scope to exit
from, so `exit 1` terminates the *host session*, taking the error message with it.

**Fixed** in 0.2.0. Stage 0 calls `exit` nowhere; every failure throws, and a compatibility test
asserts it.

---

## Running commands

### `The term './tools/New-TSRelease.ps1' is not recognized`

```
./tools/New-TSRelease.ps1: The term './tools/New-TSRelease.ps1' is not recognized as a name of a
cmdlet, script file, or executable program.
```

**Cause:** relative paths resolve against the current directory, and you are not in the repository.

**Fix:** `cd` into the clone first, or use the full path.

### `The '<' operator is reserved for future use`

```
ParserError:
  … -Version v0.1.0 -Sha256 <published-hash>
  | The '<' operator is reserved for future use.
```

**Cause:** an angle-bracket placeholder was pasted literally. PowerShell has no placeholder syntax;
`<` is a reserved operator.

**Fix:** substitute the real value. This documentation deliberately never puts a placeholder inside a
block meant to be run.

### Scripts will not run at all

```
... cannot be loaded because running scripts is disabled on this system.
```

**Fix, for the current window only:**

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

### `Pester 5.5.0 or later is required`

```
Exception: ...\tests\Invoke-Tests.ps1:51
Line |  51 |      throw 'Pester 5.5.0 or later is required. Install-Module -Name Pe …
```

**Cause, and this is not a bug:** the test runner refuses to run rather than silently using the
Pester 3 that ships with Windows. Pester 5 changed the test syntax, and Pester 3 does not fail on
version 5 files — it discovers nothing and reports success.

**Fix:**

```powershell
Install-Module -Name Pester -MinimumVersion 5.5.0 -Scope CurrentUser -SkipPublisherCheck -Force
```

---

## Fonts

### `doctor` says a font is missing that is installed and visibly in use

```
FAIL   Font: CaskaydiaCove Nerd Font Mono  (not registered)
```

**Cause:** Nerd Fonts does not register the verbose family name anywhere. On one machine, 48 registry
values existed for this single typeface across four naming conventions:

```
CaskaydiaCove NF Regular (TrueType)
CaskaydiaCove NFM Regular (TrueType)
CaskaydiaCove NFP Regular (TrueType)
CaskaydiaCoveNerdFontMono-Regular (TrueType)
```

The string `CaskaydiaCove Nerd Font Mono` appears in none of them. It is name ID 16, the typographic
family name; the registry and GDI both store name ID 1, the four-style-limited family name. Windows
Terminal displays the typographic name, which is why the settings UI and the registry disagree.

**Fixed** in 0.2.0. Detection expands the requested name into its abbreviated aliases (`NF`, `NFM`,
`NFP`) and tries three interfaces in order: font enumeration, the registry, then `GlyphTypeface`
inspection — the only route reachable from PowerShell that reports the verbose name. A fixed build
reports the name it actually matched:

```
DONE   Font: CaskaydiaCove Nerd Font Mono  (installed as 'CaskaydiaCove NFM', found by font enumeration)
```

**If you are running v0.1.0**, this failure is frozen into that archive. Install a newer release.

### Verifying it yourself

```powershell
# What the registry actually holds
Get-ItemProperty 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts' |
    Get-Member -MemberType NoteProperty |
    Where-Object Name -like '*Caskaydia*' |
    Select-Object -ExpandProperty Name

# What WPF reports as families (name ID 1)
Add-Type -AssemblyName PresentationCore
[Windows.Media.Fonts]::SystemFontFamilies |
    Where-Object { $_.Source -like '*Caskaydia*' } |
    Select-Object -ExpandProperty Source
```

### Glyphs render as boxes

The font is installed but the terminal is not using it, or is using the proportional cut. `NF`, `NFM`
and `NFP` are proportional, monospaced and semi-proportional versions of the same typeface, and all
three are usually installed together. A terminal needs the **NFM** (Mono) cut.

---

## Windows Terminal

### `apply` says the fragment was written, and nothing changed

Look for this in the report:

```
WARN   Fragment effect: andalus  (settings.json overrides and wins: colorScheme, font)
```

**Cause, and this is not a bug:** Windows Terminal composes each profile from three layers, in order:

```
profile defaults  ->  installed fragments  ->  your settings.json
```

The last layer to mention a property wins. A fragment setting `colorScheme` on a profile whose
`settings.json` entry already sets `colorScheme` is installed, correct, and completely invisible.

Note that `font` is a single object in the Windows Terminal schema. One override named `font` covers
the face, the size, the line height and the cell width together, so a report naming two overrides
can correspond to five values you set in the UI.

**Fix:** open Settings, select the profile, and click the reset arrow (`↺`) beside each overridden
property. That arrow only appears next to values you have set explicitly, so it is also the fastest
way to see which ones they are.

To list them without clicking:

```powershell
$settings = "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json"
$json = Get-Content -LiteralPath $settings -Raw | ConvertFrom-Json
$json.profiles.list | Where-Object { $_.name -match 'PowerShell' } | ForEach-Object {
    [pscustomobject] @{
        Name      = $_.name
        Guid      = $_.guid
        Overrides = (($_.PSObject.Properties.Name |
            Where-Object { $_ -notin @('guid', 'name', 'source', 'hidden', 'commandline', 'startingDirectory') }) -join ', ')
    }
} | Format-List
```

### The fragment is deployed and the terminal still looks the same after restarting a tab

Fragments are read at application startup. Close **every** Windows Terminal window, not just the tab,
and reopen.

### Which settings file is the real one

Stable and Preview keep separate settings, in different package directories. `doctor` prints the path
it found. If you have both channels installed, confirm you are looking at the one you are running.

---

## `apply`

### `-WhatIf` said nothing would be written, and wrote three files

```
  Terminal Studio apply  (dry run, nothing written)
  -------------------------------------------------
  DONE   Fragment: andalus  (created ...\Fragments\TerminalStudio\andalus.json)
  DONE   Prompt theme: andalus  (created ...\.poshthemes\andalus.omp.json)
  DONE   Shell profile  (replaced; previous version kept at ...\backups\20260811-085743-Microsoft.PowerShell_profile.ps1)
```

**How to recognise it:** the header claims a dry run and the lines underneath say `created` and
`replaced`. A genuine dry run marks every file `SKIP` and says `would create` and `would replace`,
and it prints no journal or backup paths in the footer. If you see `DONE` next to a file during a
dry run, the file was written.

**Cause:** `$WhatIfPreference` does not cross a module boundary. A function exported from a module
resolves preference variables through the module's session state rather than the caller's, so
`SupportsShouldProcess` on `ts.ps1` set a value that `Invoke-TSApply` could not see. The report
renderers are dot-sourced into the script's own scope and *did* see it — which is why the heading was
right while the engine was wrong. The two halves of one run disagreed, and only the printed half was
telling the truth.

**Fixed** on `main`, above the v0.1.0 tag. `-WhatIf` is now passed as an explicit argument, and
`tests/unit/Apply.Tests.ps1` parses `ts.ps1` and asserts the call site still passes it.

**If this already happened to you**, nothing is lost. Every replaced file was backed up before it was
overwritten and every change was journaled. Start by reading what was done:

```powershell
Get-Content "$env:LOCALAPPDATA\TerminalStudio\journal.jsonl" |
    ConvertFrom-Json |
    Format-Table timestamp, action, kind, destination, backup
```

To put your previous shell profile back:

```powershell
Get-ChildItem "$env:LOCALAPPDATA\TerminalStudio\backups\*-Microsoft.PowerShell_profile.ps1" |
    Sort-Object LastWriteTime |
    Select-Object -Last 1 |
    Copy-Item -Destination $PROFILE.CurrentUserCurrentHost -Force
```

A replaced profile takes effect in the next tab you open, not in the session you are typing into, so
a wrong profile is never as urgent as it looks.

The fragment and the theme were created rather than replaced, so there is no backup to restore and
nothing was destroyed. They are also both files `apply` is meant to write. Remove them only if you
want a clean slate before testing again:

```powershell
Remove-Item "$env:LOCALAPPDATA\Microsoft\Windows Terminal\Fragments\TerminalStudio\andalus.json",
            "$HOME\.poshthemes\andalus.omp.json" -Force -ErrorAction SilentlyContinue
```

### `source file is missing`

```
FAIL   Asset: andalus-backdrop  (source file is missing: ...\desired-state\assets\andalus-backdrop.png)
```

**Cause:** binary files are not committed to this repository. The backdrop is declared in desired
state and has to be placed by hand.

**Fix:**

```powershell
Copy-Item "$HOME\Downloads\andalus-final-kufi.png" `
    (Join-Path $PWD 'desired-state\assets\andalus-backdrop.png')
```

### `hash does not match the declared sha256`

The resource declares a specific file and the bytes disagree. Either the wrong file is in place, or
it changed and the declaration was not updated. Recompute and update `desired-state/machine.json`:

```powershell
(Get-FileHash -LiteralPath 'desired-state\assets\andalus-backdrop.png' -Algorithm SHA256).Hash
```

### `Resource kind: terminal.global` is skipped

**This is a decision, not a gap.** `apply` does not write `settings.json`. It is a large hand-edited
file with comments, and a converger that rewrites it can destroy work no backup was asked to protect.
The `terminal.global` resource records intent so `doctor` can report drift against it; the change is
yours to make in the Settings UI. See [ADR-0006](adr/0006-apply-converges-files-only.md).

### Undoing what `apply` did

Every replaced file is backed up first and every change is journaled. See
[usage](usage.md#the-change-journal) for the record format and a manual restore.

---

## Releases

### `gh` fails with a git error

```
failed to run git: fatal: not a git repository (or any of the parent directories): .git
```

**Cause:** `gh release create` infers the repository from the git remote of your *current directory*.
Run it anywhere else and it fails with an error about git, from a command about releases, naming
neither.

**Fix:** pass `--repo AbdallahxAhmed/terminal-studio`. The release builder now prints the command
with that flag already included.

### The published hash does not match a rebuild

**Cause, and this is expected:** zip archives store file modification times, and `git clone` stamps
those at checkout. Three builds of one tree produced three different hashes.

**Fix:** publish the archive you built. Never rebuild afterwards and expect the recorded hash to
match, and never edit a recorded hash to make a rebuild agree — publish a new version instead.
Normalising timestamps is on the roadmap and is a prerequisite for build provenance.

### `Could not resolve the commit`

```
WARNING: Could not resolve the commit, so the tag will point at whatever the default branch holds
when you publish. Verify that is the tree this archive was built from.
```

**Cause:** the builder could not read the repository head. This warning is itself the fix for an
earlier defect where two `git.exe` on `PATH` made the clean-tree guard fail silently — it had never
run once.

**Fix:** build from a fresh, clean clone. If the warning persists, pass `--target` with the commit
hash explicitly when publishing.

---

## CI

### The workflow fails before any step runs

```
Invalid workflow file: .github/workflows/ci.yml#L1
(Line: 92, Col: 16): Unrecognized named-value: 'matrix'.
```

**Cause:** `matrix` is not one of the contexts available to `jobs.<id>.steps[*].shell`. Workflow files
are validated before scheduling, so an expression referencing an unavailable context is a *startup*
failure rather than a step failure — which is why no logs appear.

**Fix:** move it to `jobs.<id>.defaults.run.shell`, where `matrix` *is* available:

```yaml
    runs-on: windows-latest
    defaults:
      run:
        shell: ${{ matrix.shell }}
```

and delete the per-step `shell:` lines that referenced it.

---

## Windows PowerShell 5.1

### `A parameter cannot be found that matches parameter name 'Depth'`

```
PS>TerminatingError(ConvertFrom-Json): "A parameter cannot be found that matches parameter name 'Depth'."
```

**Cause:** `ConvertTo-Json` has `-Depth` on every engine. `ConvertFrom-Json` did not gain it until
PowerShell 6. The asymmetry is easy to miss and fatal on 5.1.

This is the defect that motivated this project: it appeared five times in one log from the
predecessor script, and no test would have caught it, because nothing ran under 5.1.

**Fix:** `tests/compat/` runs stage 0 under both engines and fails on this pattern specifically.
Anything that must work on 5.1 belongs in `bootstrap/`, which is 5.1-safe by contract.
