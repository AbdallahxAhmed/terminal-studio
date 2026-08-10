# ADR-0002 — Interface: CLI first, TUI as a view, no GUI

- **Status:** accepted
- **Date:** 2026-08-10

## Context

The predecessor was menu-driven. Every capability was reachable only by launching a splash screen
and navigating nested interactive menus. The natural next question is "should the rewrite have a
nicer TUI, or a real GUI?"

That question contains a false premise. The first decision is not which interface to build, but
which interface is *primary*.

## Decision

1. The **primary interface is a non-interactive CLI**: `ts plan`, `ts apply`, `ts doctor`, each with
   `-Json` and `-Yes`, real exit codes, and no prompts.
2. A **TUI is an optional view** layered on top, and is a consumer of the same API the CLI uses.
3. **No GUI.**

## Rationale

### Why the primary surface must be non-interactive

- **Testability.** A CI runner cannot drive a menu. If the menu is the only entry point the tool is
  permanently untestable, which is how the predecessor ended up with zero tests across 2,600 lines.
- **The core use case has no human in it.** "Clean machine, one command" is the entire premise.
- **Composition.** Exit codes, JSON output, scheduling, and piping all require a non-interactive
  surface.
- **Direct evidence.** In the predecessor, `-NonInteractive -Action Theme` still opened a menu,
  because feature code called the renderer directly. The flag was not badly implemented; the
  dependency direction made it impossible to implement. UI-first did not merely coexist with that
  defect, it caused it.

### Why TUI beats GUI for this specific product

- **The subject matter is the terminal.** A TUI previews a change in the medium being changed: real
  cells, real font, real opacity. A GUI shows a swatch and a promise.
- **Cost.** A TUI is the same text files already being shipped. A GUI adds a UI framework, a build,
  packaging, signing, an update mechanism, and roughly ten times the code for the same six
  decisions.
- **Interaction shape.** Pick from a list, toggle, confirm, review a diff. That is TUI-shaped.
- **It works where testing happens** — Windows Sandbox, remote sessions, VMs with no GPU.
- **The GUI niche is already occupied.** Windows Terminal's own settings UI does graphical color
  picking, and does it better than this project ever would.

### Implementation ladder for the TUI

| Level | Technology | Adopt when |
| --- | --- | --- |
| 1 | ANSI escapes plus `Read-Host` / `PromptForChoice` | Default. Zero dependencies. Start here. |
| 2 | PwshSpectreConsole (PowerShell wrapper over Spectre.Console) | Rendering `plan` diffs: tables, trees, multi-select, live displays. PowerShell 7 only, which is already the target. |
| 3 | Terminal.Gui via ConsoleGuiTools or the community PSTui continuation | Only if windows, panes, and focus management become genuinely necessary. Windows rough edges and real maintenance risk. |

Do not adopt level 2 before a `plan` diff exists that is actually hard to render.

## Consequences

- Every feature must be reachable and assertable without a terminal attached.
- Renderers live in `UI/` and are the only code permitted to call `Write-Host`. Enforced by
  `tests/unit/Architecture.Tests.ps1`.
- The TUI is a client of the API and stays deletable: `Get-TSPlan` produces the object,
  `Show-TSPlan` renders it. If the renderer were deleted the tool would still work.
- The TUI must degrade to ASCII until fonts are verified present. On first run the tool has not yet
  installed the Nerd Font its own output wants to use, so glyph-dependent output is broken by
  construction unless it degrades.

## Revisit if

The audience becomes non-technical Windows users. Then a GUI wins decisively and this ADR should be
superseded rather than amended.
