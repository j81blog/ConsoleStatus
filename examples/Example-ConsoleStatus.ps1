#Requires -Version 5.1
<#
    .SYNOPSIS
        Example of consuming the ConsoleStatus module from a real script.

    .DESCRIPTION
        Part 1 is a realistic run, opened with a title banner, and shows the patterns a script
        needs:
          1. Manual item where the caller decides the status (OK, WARN, FAIL, SKIP).
          2. Invoke-ConsoleStep, where the action output lands in a variable and only the
             decoration goes to the console.
          3. Progress driven by a real loop, one tick per unit of work.
          4. Set-ConsoleStepDetail for a value that is only known once the work has run.
          5. LogAction wiring the records into an existing Write-Log function.
          6. Write-ConsoleSummary and an exit code taken from the tally.

        Part 2 is a tour of the rest:
          7.  Restyling halfway through, Flow mode for long values.
          8.  Dropping the value column with ValueWidth 0.
          9.  Custom glyphs.
          10. Unicode glyphs.
          11. A pinned line width.
          12. ContinueOnError instead of try/catch.
          13. Ticks from a pipeline, TotalSteps for a proportional bar, a step returning nothing.
          14. Independent totals with Reset-ConsoleStatusLog.
          15. Interrogating the run afterwards: the style, the failures, the records.
          16. What happens when the bar runs out, and when a detail does not fit.
          17. A slow step with a real duration, and details that arrive with line breaks.
          18. -Note for text the script wants on its own line, whatever the column did.

    .PARAMETER SkipTour
        Run only part 1.

    .EXAMPLE
        .\Example-ConsoleStatus.ps1

    .EXAMPLE
        .\Example-ConsoleStatus.ps1 -Mode 'Flow'

    .EXAMPLE
        .\Example-ConsoleStatus.ps1 -SkipTour

    .NOTES
        Function  : Example-ConsoleStatus
        Author    : John Billekens
        Copyright : Copyright (c) John Billekens Consultancy
        Version   : 2026.810.1002
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('Column', 'Flow')]
    [string]$Mode,

    [Parameter(Mandatory = $false)]
    [ValidateRange(60, 250)]
    [int]$MaxWidth,

    [Parameter(Mandatory = $false)]
    [switch]$SkipTour
)

$logPath = Join-Path -Path $env:TEMP -ChildPath 'ConsoleStatus-example.log'

function Write-Log {
    <#
        .SYNOPSIS
            Stand in for whatever logging function the consuming toolkit already has.

        .DESCRIPTION
            Deliberately uses parameter names that do not match the ConsoleStatus record, to show
            that the LogAction adapter is what bridges the two. Kept to one line of text on purpose.

            See Example-ConsoleStatus-Logging.ps1 for a realistic JSONL writer with levels,
            structured data and exception blocks.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $false)]
        [string]$Severity = 'INFO'
    )

    Add-Content -Path $script:logPath -Value ("{0} [{1}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Severity, $Text)
}

# Layout and logging for this script. The LogAction scriptblock is written here, in the caller
# scope, so it can see Write-Log and adapt the record to its parameter names.
$ConsoleStatusPreference = @{
    Mode      = 'Column'
    MaxWidth  = 120
    LogAction = {
        param($Record)
        Write-Log -Text "$($Record.Section) / $($Record.Label): $($Record.Detail)" -Severity $Record.Status
    }
}

Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\ConsoleStatus\ConsoleStatus.psd1') -Force

# Forward only the parameters that were actually passed, so the preference table stays in charge
# of everything else.
$styleParams = @{}

foreach ($name in @('Mode', 'MaxWidth')) {
    if ($PSBoundParameters.ContainsKey($name)) {
        $styleParams[$name] = $PSBoundParameters[$name]
    }
}

Set-ConsoleStatusStyle @styleParams
Reset-ConsoleStatusLog
Remove-Item -Path $logPath -ErrorAction SilentlyContinue

#region Part 1: a realistic run

# The banner that opens the run. -StartTimer anchors the total running time here instead of on the
# module import, which matters when the import happens long before the work does. -ClearScreen is
# left off so the tour below stays readable, a real script would usually start with it.
Write-ConsoleTitle -Title 'ConsoleStatus example run' -Subtitle "$env:COMPUTERNAME, $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -StartTimer

Write-ConsoleSection -Title 'Environment checks'

# Pattern 1: value is known up front, the caller decides the status.
Write-ConsoleItem -Label 'PowerShell version' -Value $PSVersionTable.PSVersion.ToString()

if ($PSVersionTable.PSVersion.Major -ge 5) {
    Write-ConsoleResult -Status OK
} else {
    Write-ConsoleResult -Status FAIL
}

Write-ConsoleItem -Label 'Execution policy' -Value (Get-ExecutionPolicy).ToString()

if ((Get-ExecutionPolicy) -in @('Restricted', 'Undefined')) {
    Write-ConsoleResult -Status WARN -Detail 'scripts may be blocked'
} else {
    Write-ConsoleResult -Status OK
}

Write-ConsoleItem -Label 'Reboot pending' -Value 'no'
Write-ConsoleResult -Status SKIP

Write-ConsoleSection -Title 'Collect data'

# Pattern 2 and 4: the objects land in $services, the detail reports what was found.
$services = Invoke-ConsoleStep -Label 'Query services' -Value $env:COMPUTERNAME -Action {
    $result = Get-Service -ErrorAction Stop
    Write-ConsoleTick -Count 8
    Set-ConsoleStepDetail -Text "$(@($result).Count) services"
    $result
}

# Pattern 3: progress driven by the loop itself, one tick per path.
$paths = @(
    $env:TEMP
    "$env:WINDIR\System32\drivers\etc"
    "$env:ProgramFiles"
    $env:TEMP
    "$env:WINDIR\Fonts"
)

$folderSizes = Invoke-ConsoleStep -Label 'Measure folders' -Value "$($paths.Count) paths" -Action {
    $total = 0

    foreach ($path in $paths) {
        $files = Get-ChildItem -Path $path -File -ErrorAction SilentlyContinue
        $bytes = ($files | Measure-Object -Property Length -Sum).Sum
        $total += $bytes

        [PSCustomObject]@{
            Path  = $path
            Files = @($files).Count
            Bytes = [int64]$bytes
        }

        Write-ConsoleTick
    }

    Set-ConsoleStepDetail -Text "$([Math]::Round($total / 1MB, 1)) MB"
}

# A step that throws. Without -ContinueOnError the exception is rethrown, so try/catch decides what
# happens next. The FAIL is counted and logged either way, and the exception message becomes the
# on screen detail.
try {
    $null = Invoke-ConsoleStep -Label 'Contact license server' -Value 'srv-does-not-exist' -Action {
        Write-ConsoleTick -Count 3
        throw 'The RPC server is unavailable.'
    }
} catch {
    Write-Verbose -Message "License server unreachable: $($_.Exception.Message)"
}

Write-ConsoleSummary

# Part 1 owns the exit code, so take it before the tour resets the counters.
$exitCode = (Get-ConsoleStatusSummary).Fail

# The console output is decoration. These are the two things a script actually acts on.
Get-ConsoleStatusLog |
    ForEach-Object { $_ | ConvertTo-Json -Compress } |
    Set-Content -Path (Join-Path -Path $env:TEMP -ChildPath 'ConsoleStatus-example.jsonl')

#endregion Part 1

#region Part 2: a tour of the rest

if (-not $SkipTour) {

    # 14. Reset gives the tour its own totals, as if it were a separate run.
    Reset-ConsoleStatusLog

    # 7. Restyling halfway through. Flow lets long values run at their natural length instead of
    #    being truncated into a fixed column.
    Set-ConsoleStatusStyle @styleParams -Mode 'Flow'
    Write-ConsoleSection -Title '7. Flow mode, long values are not truncated'

    foreach ($path in @("$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe", "$env:ProgramFiles\WindowsPowerShell\Modules", 'C:\Temp')) {
        Write-ConsoleItem -Label 'Path' -Value $path
        Write-ConsoleTick -Count 4

        if (Test-Path -Path $path) {
            Write-ConsoleResult -Status OK
        } else {
            Write-ConsoleResult -Status FAIL
        }
    }

    # 8. Some sections have nothing useful to put in a value column, so drop it and give the space
    #    to the progress field.
    Set-ConsoleStatusStyle @styleParams -ValueWidth 0
    Write-ConsoleSection -Title '8. No value column'

    foreach ($task in @('Stopping services', 'Copying payload', 'Registering components')) {
        Write-ConsoleItem -Label $task
        1..8 | ForEach-Object { Write-ConsoleTick; Start-Sleep -Milliseconds 15 }
        Write-ConsoleResult -Status OK
    }

    # 9. Any single character works for the three glyphs.
    Set-ConsoleStatusStyle @styleParams -TickChar '#' -FillChar ' ' -RuleChar '='
    Write-ConsoleSection -Title '9. Custom glyphs'
    Write-ConsoleItem -Label 'Hash ticks' -Value 'blank fill'
    Write-ConsoleTick -Count 12
    Write-ConsoleResult -Status OK -Detail 'no dot leader'

    # 10. Unicode sets the console to UTF-8 and swaps in block and box drawing glyphs.
    Set-ConsoleStatusStyle @styleParams -Unicode
    Write-ConsoleSection -Title '10. Unicode glyphs'
    Write-ConsoleItem -Label 'Block ticks' -Value 'middle dot fill'
    Write-ConsoleTick -Count 12
    Write-ConsoleResult -Status OK

    # 11. A pinned width ignores the console measurement, but is still clamped to what the window
    #     can actually show unless ForceWidth is set.
    Set-ConsoleStatusStyle @styleParams -Width 70
    Write-ConsoleSection -Title '11. Pinned to 70 columns'
    Write-ConsoleItem -Label 'Fixed width' -Value '70'
    Write-ConsoleTick -Count 6
    Write-ConsoleResult -Status OK -Detail "line=$((Get-ConsoleStatusStyle).LineWidth)"

    Set-ConsoleStatusStyle @styleParams
    Write-ConsoleSection -Title '12. Failure handling and odd shapes'

    # 12. ContinueOnError swallows the exception. The FAIL is still counted, logged and shown, so
    #     this is the shorter form when the script does not need to branch on the failure.
    $null = Invoke-ConsoleStep -Label 'Optional cleanup' -Value 'scratch share' -ContinueOnError -Action {
        Write-ConsoleTick -Count 5
        throw 'Access to the path is denied.'
    }

    # 13. Ticks can come straight out of a pipeline, and a step that returns nothing is fine.
    #     TotalSteps makes a tick one unit of work instead of one character, so the bar spans the
    #     field exactly whatever the console width and however many units there are.
    Invoke-ConsoleStep -Label 'Process queue' -Value '20 items' -TotalSteps 20 -Action {
        1..20 | ForEach-Object {
            Write-ConsoleTick
            Start-Sleep -Milliseconds 10
        }

        Set-ConsoleStepDetail -Text 'queue drained'
    }

    # A value too long for the column. Truncation is the default, and the script decides whether
    # that is acceptable or whether the full text is worth a note of its own.
    $deepPath = 'C:\Program Files\Vendor\Product\Very\Deep\Path\config.xml'

    Write-ConsoleItem -Label 'Truncated, and fine' -Value $deepPath
    Write-ConsoleResult -Status OK

    Write-ConsoleItem -Label 'Truncated, needs the rest' -Value $deepPath
    Write-ConsoleResult -Status WARN -Note $deepPath

    Write-ConsoleSection -Title '16. When the bar runs out and when the detail does not fit'

    # Without a declared total the bar wraps, but only as far as MaxBarLines. On the last allowed
    # line the final cell becomes the more marker, so a bar that stopped being drawn is
    # distinguishable from work that stopped. Compare with the TotalSteps items, which always fit
    # on one line and where the bar actually means something.
    Write-ConsoleItem -Label 'Unknown total' -Value 'ticks 500x'
    1..750 | ForEach-Object { Write-ConsoleTick }
    Write-ConsoleResult -Status OK

    # A detail is never truncated. When it does not fit next to the status it spills onto its own
    # line, wrapped to the line width. Long error messages stay readable in full.
    Write-ConsoleItem -Label 'Install package' -Value 'Vendor.Product'
    Write-ConsoleTick -Count 10
    Write-ConsoleResult -Status FAIL -Detail 'The installer returned exit code 1603. A fatal error occurred during installation and the transaction was rolled back. See the MSI log for the full transcript.'

    Write-ConsoleSection -Title '17. A slow step, and details that arrive with line breaks'

    # Slow enough to produce a real duration instead of a few milliseconds. The switch asks for the
    # timing on this step alone, which keeps it off the rows where it would be noise. Anything past
    # a minute reads as '4m 12s' rather than as a large number of seconds.
    Invoke-ConsoleStep -Label 'Install payload' -Value 'Vendor.Product.msi' -TotalSteps 25 -ShowDuration -Action {
        1..25 | ForEach-Object {
            Start-Sleep -Milliseconds 100
            Write-ConsoleTick
        }

        Set-ConsoleStepDetail -Text 'installed'
    }

    # A detail that arrives as multiple lines. The line breaks are collapsed so the columns survive
    # and the record stays one line of JSON, then the text is rewrapped underneath the item.
    $validation = @(
        'Validation failed for 3 of 12 settings:'
        '- LicenseServer is empty'
        '- CacheSizeMb is 0, expected at least 256'
        '- LogPath points at a folder that does not exist'
    ) -join [Environment]::NewLine

    Write-ConsoleItem -Label 'Validate configuration' -Value '12 settings' -TotalSteps 12
    1..12 | ForEach-Object { Write-ConsoleTick }
    Write-ConsoleResult -Status WARN -Detail $validation

    # The same thing from a multiline exception message, picked up automatically on FAIL.
    $null = Invoke-ConsoleStep -Label 'Import certificate' -Value 'wildcard.pfx' -ContinueOnError -Action {
        Write-ConsoleTick -Count 4
        throw ("The certificate could not be imported.{0}The specified network password is not correct.{0}Verify the PFX password and try again." -f [Environment]::NewLine)
    }

    Write-ConsoleSummary -Title '14. Tour totals, counted separately'

    # 15. Everything is queryable after the fact.
    Write-ConsoleSection -Title '15. Interrogating the run'

    $style = Get-ConsoleStatusStyle
    Write-Host ("  line width {0}, label {1}, value {2}, status {3}, mode {4}" -f $style.LineWidth, $style.LabelWidth, $style.ValueWidth, $style.StatusWidth, $style.Mode) -ForegroundColor DarkGray

    $failures = @(Get-ConsoleStatusLog | Where-Object { $_.Status -eq 'FAIL' })
    Write-Host ("  {0} failure(s) in the tour:" -f $failures.Count) -ForegroundColor DarkGray

    foreach ($failure in $failures) {
        Write-Host ("    {0} -> {1}" -f $failure.Label, $failure.Error) -ForegroundColor DarkGray
    }

    $slowest = Get-ConsoleStatusLog | Sort-Object -Property DurationMs -Descending | Select-Object -First 1
    Write-Host ("  slowest step: {0} at {1}ms" -f $slowest.Label, $slowest.DurationMs) -ForegroundColor DarkGray
}

#endregion Part 2

Write-Host ''
Write-Host ("  services captured : {0}" -f @($services).Count) -ForegroundColor DarkGray
Write-Host ("  folders measured  : {0}" -f @($folderSizes).Count) -ForegroundColor DarkGray
Write-Host ("  text log          : {0}" -f $logPath) -ForegroundColor DarkGray
Write-Host ("  jsonl records     : {0}" -f (Join-Path -Path $env:TEMP -ChildPath 'ConsoleStatus-example.jsonl')) -ForegroundColor DarkGray
Write-Host ''

exit $exitCode
