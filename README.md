# ConsoleStatus

Structured console output for PowerShell scripts: sections, labeled values, live progress and a
colored result, without polluting the pipeline.

```
  Environment checks
  --------------------------------------------------------------------------------------------------
  PowerShell version      5.1.26100.8875  ................................................. [  OK  ]
  Execution policy        Bypass          ................................................. [  OK  ]
  Reboot pending          no              ................................................. [ SKIP ]

  Collect data
  --------------------------------------------------------------------------------------------------
  Query services          SRV-APP01       ********............................ 340 services [  OK  ]
  Measure folders         5 paths         *****................................. 14671.5 MB [  OK  ]
  Contact license server  srv-does-not... ***............... The RPC server is unavailable. [ FAIL ]

  Summary
  --------------------------------------------------------------------------------------------------
  Steps completed         6               ............................................ 1.2s [  OK  ]
  Skipped                 1               ................................................. [ SKIP ]
  Failed                  1               ................................................. [ FAIL ]
    > Contact license server (srv-does-not-exist)
      The RPC server is unavailable.
```

Requires PowerShell 5.1 or later. Works on Windows PowerShell and PowerShell 7.

## The point

Decoration goes to the console, data goes to your variable. Every write uses `Write-Host`, which
targets the information stream, so the success stream stays clean:

```powershell
$services = Invoke-ConsoleStep -Label 'Query services' -Value $env:COMPUTERNAME -Action {
    $result = Get-Service -ErrorAction Stop
    Write-ConsoleTick -Count 8
    Set-ConsoleStepDetail -Text "$(@($result).Count) services"
    $result
}
```

`$services` holds the service objects. The dots, the bar and the `[  OK  ]` went to the screen only.
Redirecting the script to a file or assigning the whole thing to a variable captures nothing.

## Quick start

```powershell
Import-Module .\ConsoleStatus\ConsoleStatus.psd1

Set-ConsoleStatusStyle

Write-ConsoleSection -Title 'Environment checks'

Write-ConsoleItem -Label 'Execution policy' -Value (Get-ExecutionPolicy).ToString()
Write-ConsoleResult -Status OK

Write-ConsoleSummary
exit (Get-ConsoleStatusSummary).Fail
```

## The two APIs

**Manual**, when the script decides the status:

```powershell
Write-ConsoleItem -Label 'Free disk space' -Value '148 GB' -TotalSteps 4
1..4 | ForEach-Object { Write-ConsoleTick }
Write-ConsoleResult -Status WARN -Detail 'below the 200 GB threshold'
```

**Wrapper**, when a scriptblock does the work. Output passes through, exceptions become FAIL:

```powershell
$files = Invoke-ConsoleStep -Label 'Enumerate' -Value $path -Action { Get-ChildItem -Path $path }
```

`Invoke-ConsoleStep` rethrows by default, so a plain `try`/`catch` gives you both the red status and
control of the flow. Use `-ContinueOnError` when the script does not need to branch on it.

## Progress

A tick is one character by default. Give the item a `-TotalSteps` and a tick becomes one unit of
work, drawn proportionally, so the bar spans the field exactly at any console width:

```powershell
Invoke-ConsoleStep -Label 'Process queue' -Value '200 items' -TotalSteps 200 -Action {
    foreach ($item in $queue) { Do-Work $item; Write-ConsoleTick }
}
```

Without a total the bar wraps onto further lines when it runs out of room, up to `MaxBarLines`.
Continued lines leave the label and value columns empty and carry no status block, which is what
marks them as unfinished. If the cap is reached and work carries on, the last cell becomes `>`:

```
  Unknown total           500 ticks       *************************************************
                                          *************************************************
                                          ************************************************> [  OK  ]
```

## Detail and notes

A **detail** competes for the space next to the status and becomes a note when it does not fit. A
**note** is always on its own line. Both are wrapped, and neither is ever truncated:

```powershell
Write-ConsoleResult -Status WARN -Detail '3 of 12 invalid' -Note $fullValidationMessage
```

```
  Validate configuration  12 settings     ***********.................. 3 of 12 invalid [ WARN ]
    > LicenseServer is empty, CacheSizeMb is 0 (expected at least 256), LogPath points at a
      folder that does not exist
```

On a FAIL with no detail, the exception message is used automatically.

## Configuration

Set `$ConsoleStatusPreference` before importing, or call `Set-ConsoleStatusStyle` afterwards.
Resolution order is built-in defaults, then the preference table, then explicit parameters:

```powershell
$ConsoleStatusPreference = @{
    Mode       = 'Column'
    MaxWidth   = 120
    LabelWidth = 30
    ValueWidth = 0        # drop the value column entirely
}
```

| Setting | Default | |
|---|---|---|
| `Mode` | `Column` | `Column` aligns and truncates, `Flow` lets the value run at natural length |
| `Indent` | `2` | Left margin |
| `LabelWidth` | `24` | Label column, Column mode only |
| `ValueWidth` | `16` | Value column, `0` removes it |
| `StatusWidth` | `8` | Status block including brackets |
| `Width` | `0` | Pin the exact line width, `0` measures the console |
| `ForceWidth` | `$false` | Allow a pinned width wider than the console |
| `MinWidth` / `MaxWidth` | `60` / `120` | Bounds on the measured width |
| `Unicode` | `$false` | Block and box drawing glyphs, sets UTF-8 output |
| `NoColor` | `$false` | Also honors `$env:NO_COLOR` |
| `ShowDuration` | `$false` | Per step with `-ShowDuration`, whatever this says |
| `TickChar` / `FillChar` / `RuleChar` / `MoreChar` | `*` `.` `-` `>` | Single character each |
| `BarContinuation` | `Open` | `Open` leaves a continued line bare, `Blank` ends it with an empty block |
| `MaxBarLines` | `3` | Lines a wrapping bar may use, `0` for no limit, `1` to stay on one line |
| `LogAction` | `$null` | Scriptblock invoked with one record per completed item |

Column widths are *preferred*, not guaranteed: on a narrow line the value column shrinks first, then
the label. `Get-ConsoleStatusStyle` reports what was actually fitted.

Width is taken from `$Host.UI.RawUI.WindowSize`, falling back to the buffer width and then to 80.
`$env:CONSOLESTATUS_WIDTH` overrides it for scheduled tasks and build agents where nothing is
detectable.

## Records and logging

Every completed item is recorded, whether or not you use a logger:

```powershell
Get-ConsoleStatusLog | ForEach-Object { $_ | ConvertTo-Json -Compress } | Set-Content run.jsonl
```

```json
{"Timestamp":"2026-08-10T13:13:00.05+02:00","Section":"Deploy","Label":"Query services","Value":"SRV-APP01","Detail":"340 services","Note":"","Status":"OK","DurationMs":47,"Error":""}
```

To stream them into logging you already have, write an adapter. It goes in your scope, so it can see
your function and map onto whatever parameter names it uses:

```powershell
$ConsoleStatusPreference = @{
    LogAction = {
        param($Record)
        Write-Log -Text "$($Record.Section) / $($Record.Label)" -Severity $Record.Status
    }
}
```

An exception thrown by the adapter is caught and warned about once, so a broken logger cannot take
down a deployment.

## Commands

| | |
|---|---|
| `Set-ConsoleStatusStyle` | Apply defaults, preferences and parameters, then fit the columns |
| `Get-ConsoleStatusStyle` | The configuration actually in effect, including fitted widths |
| `Write-ConsoleSection` | Section header with a rule |
| `Write-ConsoleItem` | Start an item line and its timer |
| `Write-ConsoleTick` | Advance the progress bar |
| `Set-ConsoleStepDetail` | Detail for the current item, from inside the work |
| `Set-ConsoleStepNote` | Note for the current item, from inside the work |
| `Write-ConsoleResult` | Close the line with a status, and record it |
| `Invoke-ConsoleStep` | Run a scriptblock as one item, passing its output through |
| `Write-ConsoleSummary` | Closing totals, with the failures listed |
| `Get-ConsoleStatusSummary` | Counts per status plus total elapsed time |
| `Get-ConsoleStatusLog` | One structured record per completed item |
| `Reset-ConsoleStatusLog` | Clear the records and the counters |

Every command has full comment based help: `Get-Help Write-ConsoleResult -Full`.

## Layout

```
ConsoleStatus/
  ConsoleStatus.psd1
  ConsoleStatus.psm1      state and the loader, no functions
  public/                 one file per exported function
  private/                one file per internal helper
tests/                    Pester suite
examples/
ci/                       Install, Tests and Build, called by the workflow
```

## Examples

| | |
|---|---|
| `examples\Example-ConsoleStatus.ps1` | A realistic run, then a tour of every feature |
| `examples\Example-ConsoleStatus-Logging.ps1` | Wiring the records into a JSONL log writer |
| `examples\ConsoleStatus-Demo.ps1` | The layout modes and glyph sets side by side |
| `examples\Options-Demo.ps1` | The behavioral settings side by side |

## Tests

```powershell
.\ci\Tests.ps1
```

Runs 96 Pester tests and writes `TestResults.xml`. The suite covers width resolution, setting
precedence and validation, the column arithmetic, bar wrapping and limits, details and notes,
duration formatting, the records and summary, the module layout, and that nothing reaches the
success stream.

Rendering is asserted by capturing the information stream with `6>&1` and rebuilding the emitted
lines, so the layout maths is tested rather than eyeballed.

## Notes

Color is never the only signal: the words OK, FAIL, WARN and SKIP carry the meaning, so the output
survives a colorblind reader, a stripped log, or `$env:NO_COLOR`.

The cursor is never moved. Everything is decided before the characters are written, which is why the
output degrades cleanly into transcripts, redirected files and CI logs. It also means progress
cannot be animated in place, and a bar cannot be redrawn once written.

## License

MIT. See [LICENSE](LICENSE).
