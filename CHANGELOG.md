# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

A changelog exists from the first commit on purpose. Retrofitting one means reconstructing history
from memory, and the reconstruction is always wrong.

## [Unreleased]

### Added

- Project charter and the desired-state model (`README.md`).
- ADR-0001: technology choice — PowerShell 7 module rather than a rewrite in a compiled language.
- ADR-0002: interface choice — non-interactive CLI as the primary surface, TUI as an optional view,
  no GUI.
- ADR-0003: distribution — GitHub with a tiered, integrity-verified install path.
- `PSScriptAnalyzerSettings.psd1` with approved-verb and unused-parameter enforcement.
- CI workflow running lint plus a test matrix across Windows PowerShell 5.1 and PowerShell 7.
- Module skeleton with the `Public` / `Private` / `Adapters` / `UI` seam.
- `Invoke-TSDoctor`: read-only capability and drift checks.
- `Get-TSPlan`: reads desired state and reports drift; unmodelled resource kinds are reported as
  `Unsupported` rather than silently skipped.
- `bootstrap/get.ps1`: 5.1-safe stage 0 with SHA-256 verification.
- Test suites: cross-edition compatibility, mocked unit tests, and mechanical architecture checks.

### Notes

Nothing is released yet. There is no `apply` command, and none is stubbed. Shipping a command that
looks implemented but is not is worse than shipping nothing.

[Unreleased]: https://github.com/AbdallahxAhmed/terminal-studio/commits/main
