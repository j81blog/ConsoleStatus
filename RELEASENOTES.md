# Release notes

## v2026.812.2330

- ADD: `Write-ConsoleTitle`, an opening banner between two rules, with `-Subtitle`, `-ClearScreen` and `-StartTimer`.
- ADD: `TitleChar` setting for the banner rules, `=` by default and `═` in Unicode mode.
- ADD: total running time. `Get-ConsoleStatusSummary` returns `ElapsedMs` (wall clock) next to `DurationMs` (time inside the steps), and `Write-ConsoleSummary` prints a `Total time` row.
- ADD: `Get-ConsoleStatusState`, reporting whether an item is open plus its section, label, value and progress.
- ADD: `-Append` on `Set-ConsoleStepNote` and `Set-ConsoleStepDetail`, joining with `'; '` instead of letting the last call win.
- ADD: `.gitattributes` marking `*.ps1`, `*.psm1` and `*.psd1` as `-text`, so autocrlf cannot strip the CR and break the signatures.
- ADD: tests for signed file integrity (BOM, CRLF, ASCII only code, valid timestamped signature), comment based help, and the item lifecycle. 96 tests to 128.
- FIX: `Write-ConsoleResult` drew a ghost line of dots and a status block when the item was already closed. Closing is now idempotent, so a `catch` or a `finally` can close whatever was left open.
- FIX: `Write-ConsoleTick` drew loose glyphs on a fresh line when no item was open. A tick with no open item is now ignored.
- FIX: the banner collapsed runs of spaces, destroying alignment the caller built on purpose. `-Title` and `-Subtitle` keep their spaces and lose only the characters that break a line.
- FIX: most PowerShell files were stored LF normalized in git, so a fresh clone got bare LF and 13 signed files failed to verify. The blobs now hold the exact signed bytes.
- CHANGE: `Get-ConsoleStatusStyle` returns the settings and the fitted `LineWidth` only. The per item runtime fields moved to `Get-ConsoleStatusState`. Breaking for anything reading `.Stopwatch`, `.Ticks`, `.Section` or `.CurrentLabel` off it.
- CHANGE: `Write-ConsoleSummary` writes one extra row, `Total time`, under `Steps completed`.
- CHANGE: README documents that the `Invoke-ConsoleStep` action runs in a child scope, so use the manual API when the work updates the caller's variables.

## v2026.810.2100

- ADD: initial version.
