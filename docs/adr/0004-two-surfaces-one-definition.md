# ADR-004: Two surfaces, one definition

- Status: Accepted
- Date: 2026-08-10
- Amends: ADR-002 (Interface: CLI first)

## Context

ADR-002 concluded "CLI first, TUI as a view, GUI never". A configurator with
checkboxes and dropdown menus was then requested explicitly, in both a terminal
form and a window, in the style of Chris Titus Tech's WinUtil.

Rather than quietly break ADR-002 or refuse a reasonable request, it is worth
being precise about what that decision was actually protecting.

It was not protecting against a window existing. The predecessor's failure was
that **the menu was the program**. Logic lived inside interactive prompts, and
everything followed from that: `-NonInteractive -Action WSL` still opened a
menu, `-Force` on `Install-Apps` was unreachable because nothing could call it
without a human, `Save-WTSettingsSafely` was written and never wired up, and
none of it could be tested without a console. The interface owned the logic, so
the logic could only be reached through the interface.

WinUtil, at 60k stars, is not arranged that way. Its WPF window is generated
from JSON definitions and calls into ordinary public and private PowerShell
functions underneath. The window is a client of the logic, not its container.
That layering is the part worth taking. The window is incidental.

## Decision

Ship both surfaces, on one condition: **the definition is the deliverable and
the renderers are thin.**

1. `src/TerminalStudio/Data/controls.json` is the single definition of every
   checkbox and dropdown. It lives under `Data/` because the module loader
   dot-sources only `Private`, `Adapters`, `UI` and `Public`, and the
   architecture suite inspects only those four folders. A JSON file there is
   inert by construction.

2. `Get-TSControl` is the model. It is a Public function that reads through the
   filesystem adapter, resolves each control's current value out of desired
   state, and returns objects. It prints nothing and writes nothing.

3. Renderers are pure consumers. `Show-TSControlForm` and `Show-TSControlWindow`
   receive control objects and render them. They are not exported from the
   module; `ts.ps1` dot-sources them into its own scope, which means a renderer
   *cannot reach module-private functions even if someone tries*. The layering
   is enforced by scope rather than by discipline.

4. Controls target desired state, never the machine. Toggling a box changes what
   the environment should be. `plan` and `apply` remain the only things that
   touch Windows, so the UI cannot become a second source of truth competing
   with `machine.json`.

The rule that replaces "GUI never" is falsifiable:

> **No surface may own logic, and no renderer may know what any individual
> control means. If adding a knob requires editing a `.ps1`, the split has
> failed.**

`tests/unit/Controls.Tests.ps1` checks the half of that a test can reach: every
control binds to a path that exists in the document it points at, ids are
unique, and every declared type is one both surfaces implement.

## Consequences

### Good

- Adding a setting is a JSON edit. Both surfaces gain it, in step, for free.
- `-Json` makes a third client free. Anything that reads JSON is a peer of the
  two renderers, which is what keeps the tool automatable.
- Binding drift becomes a test failure rather than a disabled row nobody
  notices. Two renderers agreeing with each other is not correctness; agreeing
  with the documents is.
- The unbound state is reported separately from the off state. A control whose
  target has been renamed is a defect, not an unchecked box.

### Bad, and accepted

- **The window cannot be verified by CI.** The model and the terminal form are
  testable; WPF needs a desktop and an STA thread. The window's correctness
  rests on review, and that is a real reduction in coverage, not a technicality.
- **The STA requirement is now user-facing.** PowerShell 7 starts MTA, so the
  window needs `pwsh -STA`. This is guarded with an instruction rather than a
  stack trace, but it is still a sharp edge the TUI does not have.
- **Two surfaces are two chances to get presentation wrong** even when the logic
  is shared. Shared data prevents behavioural drift, not visual drift.
- **The window is styled, not frosted.** Acrylic in WPF requires DWM interop.
  Drawing a flat window and calling it frosted would repeat exactly the
  requested-versus-effective confusion `doctor` exists to expose.

## Not decided here

Writing desired state back. Both surfaces return edited objects and print them;
neither saves. Persisting requires a writer adapter and the change journal, and
until `apply` exists a configurator that edits the source of truth for an engine
that cannot act on it is a half-connected loop pretending to be a whole one.
Saving therefore exits 3 - the same code `apply` uses - so no caller can mistake
it for success.
