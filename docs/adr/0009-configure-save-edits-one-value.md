# ADR-0009 — `configure -Save` edits one value in place and proves it

**Status:** accepted, 2026-08-21

## Context

`ts configure` has rendered every control, its current value, and whether desired state binds it
since 0.1.0, and it has never been able to save. The 0.1.0 changelog gave the reason: there was no
write adapter, and a half-built save that can leave a JSON document in pieces is worse than none.

The write adapters exist now. What remained was the harder half of the question: *how* to write a
single value into a document a human maintains.

The obvious implementation is three lines — `ConvertFrom-Json`, set the property, `ConvertTo-Json`
back. Every one of the documents this feature targets makes that a destructive operation:

- `desired-state/fragments/andalus.json` and the Oh My Posh theme are hand-maintained and commented.
  `ConvertFrom-Json` discards comments, and `ConvertTo-Json` cannot put them back.
- Key order is meaningful to the person reading the file next, and a round trip reorders freely.
- `ConvertTo-Json` reformats every line, so a one-value change produces a diff covering the whole
  file, in a repository where these documents are reviewed as text.
- Depth defaults truncate nested structures into the string `System.Object[]`, silently.

This is not a hypothetical objection. ADR-0006 refuses to touch the user's `settings.json` for
exactly this reason, and it would be incoherent to protect that file from a parse-and-reserialize
while doing it to our own.

## Decision

**`configure -Save` performs a text splice: it locates the exact span of the existing value and
replaces those characters. Everything else in the file is returned byte for byte.**

The implementation is a hand-written scanner (`Private/Edit-TSJsonText.ps1`) that walks the document
tracking object and array frames, staying escape-aware inside strings so that a brace or a quote in
a value cannot be mistaken for structure. It resolves a dotted path — `profiles.0.font.face` — and
returns the offsets of the value it names. `System.Text.Json`'s reader was the first choice and is
not available: `Utf8JsonReader` is a `ref struct` and cannot be instantiated from PowerShell.

Three refusals are part of the decision, not omissions:

- **Scalars only.** If the path names an object or an array, it throws. A splice of a container is
  where "replace these characters" stops being provably local.
- **A path that does not exist throws.** Inventing a member means deciding where in the document it
  belongs, which is a formatting decision this design has no basis for making.
- **Presence controls are `SKIP`.** A control that means "is this package in the list" is not a value
  to set; honouring it would mean adding or removing array elements, which is the container case
  again.

**The result is verified before it is written.** The edited text is reparsed, compared against the
original parse with `Compare-TSJsonDocument`, and the write is refused unless exactly one path
changed and it is the requested one. A splice is a sharp instrument, and this is the check that
catches it cutting in the wrong place — including the case where the document was valid before and
is not after.

Beyond that it behaves like every other write in this project: backup first, journal an `edit`
record with the previous and new hashes and the path that changed, honour `-WhatIf` at the write, and
report `already set` without touching the file when the value is already correct.

**It edits desired state, not the machine.** The report says so, and the remediation line names
`apply` as the command that converges the machine onto the change. Two steps, because one command
that both records an intention and performs it cannot report on them separately when the second half
fails.

## Consequences

**Comments and formatting survive**, which is what makes this safe to point at a document a human
owns. The tests assert whole-document equality rather than parsed values, because a reformatting
implementation passes every value-level assertion.

**Saving is two commands.** `configure -Save` then `apply`. The alternative reads better in a demo
and hides which half failed.

**`settings.json` remains untouched.** This feature does not change ADR-0006. The two clicks that
remove a `colorScheme` and `font` override are still the user's to make, and the tool names them.

**Reversible.** `edit` records replay under ADR-0008, so a save can be undone by `uninstall` like
any other managed write.

**A scanner is code that has to be maintained.** It is about a hundred lines with a test file
covering the cases that break naive implementations — a brace inside a string, an escaped quote,
array indexing, boolean literals emitted as `true` rather than PowerShell's `True`.

## Alternatives considered

**`ConvertFrom-Json`, set, `ConvertTo-Json`.**

Three lines, and it destroys comments, key order and formatting in files that have all three.
Rejected for the same reason ADR-0006 refuses to rewrite `settings.json`.

**A JSONC-preserving third-party library.**

Rejected. It would be the project's first runtime dependency, in a tool whose install story is one
file fetched from the internet onto a machine that may not have a package manager configured yet.

**Write a sibling override file instead of editing in place.**

This is exactly the right answer for Windows Terminal, and it is what fragments already are. It does
not generalise: an Oh My Posh theme has no fragment mechanism, and layering our own would mean
reimplementing the merge semantics for every format the tool touches.

**Regenerate the whole document from desired state on every save.**

Rejected. It makes the repository the only permitted author of files that people are invited to edit
by hand, and the first time someone's comment vanished they would stop trusting the tool.
