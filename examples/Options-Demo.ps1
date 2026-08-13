#Requires -Version 5.1
<#
    .SYNOPSIS
        Renders the behavioral settings side by side, so the effect of each one is visible.

    .DESCRIPTION
        Where ConsoleStatus-Demo.ps1 compares the layout modes and glyph sets, this compares the
        settings that change what is written rather than how it looks: duration display, bar
        limits, continuation style, and truncating a value against putting it in a note.

    .PARAMETER Width
        Line width to render at. Pinned so the output is reproducible.

    .EXAMPLE
        .\Options-Demo.ps1

    .EXAMPLE
        .\Options-Demo.ps1 -Width 80

    .NOTES
        Function  : Options-Demo
        Author    : John Billekens
        Copyright : Copyright (c) John Billekens Consultancy
        Version   : 2026.810.1425
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateRange(60, 250)]
    [int]$Width = 100
)

Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\ConsoleStatus\ConsoleStatus.psd1') -Force

function Write-Caption {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    Write-Host ''
    Write-Host "  $Text" -ForegroundColor Magenta
}

function Write-Heading {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    Write-Host ''
    Write-Host ('=' * ($Width - 2)) -ForegroundColor DarkGray
    Write-Host "  $Text" -ForegroundColor White
    Write-Host ('=' * ($Width - 2)) -ForegroundColor DarkGray
}

# The same four steps every time, so only the setting under test differs.
function Invoke-SampleRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$TimeTheSlowStep
    )

    Invoke-ConsoleStep -Label 'Read configuration' -Value 'app.config' -Action {
        Write-ConsoleTick -Count 12
        Set-ConsoleStepDetail -Text '18 keys'
    }

    # Only pass the switch when it is wanted. Passing -ShowDuration:$false would suppress the
    # duration rather than leave it to the setting.
    $stepParameters = @{}

    if ($TimeTheSlowStep) {
        $stepParameters.ShowDuration = $true
    }

    Invoke-ConsoleStep -Label 'Install payload' -Value 'Vendor.Product.msi' @stepParameters -Action {
        1..15 | ForEach-Object {
            Start-Sleep -Milliseconds 80
            Write-ConsoleTick
        }

        Set-ConsoleStepDetail -Text 'installed'
    }

    Write-ConsoleItem -Label 'Restart service' -Value 'VendorSvc'
    Write-ConsoleTick -Count 8
    Write-ConsoleResult -Status OK

    $null = Invoke-ConsoleStep -Label 'Import certificate' -Value 'wildcard.pfx' -ContinueOnError -Action {
        Write-ConsoleTick -Count 4
        throw 'The specified network password is not correct.'
    }
}

#region Duration

Write-Heading -Text 'ShowDuration'

Set-ConsoleStatusStyle -Width $Width
Reset-ConsoleStatusLog
Write-Caption -Text 'Off. Nothing is timed, though every duration is still in the record.'
Write-ConsoleSection -Title 'Deploy'
Invoke-SampleRun

Set-ConsoleStatusStyle -Width $Width -ShowDuration
Reset-ConsoleStatusLog
Write-Caption -Text 'On globally. Every row carries a number, and the slow one no longer stands out.'
Write-ConsoleSection -Title 'Deploy'
Invoke-SampleRun

Set-ConsoleStatusStyle -Width $Width
Reset-ConsoleStatusLog
Write-Caption -Text 'Per step with -ShowDuration. A number on a row means that row was worth timing.'
Write-ConsoleSection -Title 'Deploy'
Invoke-SampleRun -TimeTheSlowStep

Write-Caption -Text 'The summary lists what failed, so a long run does not have to be scrolled back.'
Write-ConsoleSummary

#endregion Duration

#region Truncate or note

Write-Heading -Text 'A value too long for the column'

$paths = @(
    $env:TEMP
    "$env:WINDIR\System32\drivers\etc\hosts"
    "$env:ProgramFiles\WindowsPowerShell\Modules"
)

Set-ConsoleStatusStyle -Width $Width
Reset-ConsoleStatusLog
Write-Caption -Text 'Truncated, the default. Straight edges, and the tail of the value is lost.'
Write-ConsoleSection -Title 'Check paths'

foreach ($path in $paths) {
    Write-ConsoleItem -Label 'Path exists' -Value $path -TotalSteps 3
    1..3 | ForEach-Object { Write-ConsoleTick }
    Write-ConsoleResult -Status OK
}

Write-Caption -Text 'Same values in Flow mode. Nothing is lost, but the columns no longer line up.'
Set-ConsoleStatusStyle -Width $Width -Mode 'Flow'
Write-ConsoleSection -Title 'Check paths'

foreach ($path in $paths) {
    Write-ConsoleItem -Label 'Path exists' -Value $path -TotalSteps 3
    1..3 | ForEach-Object { Write-ConsoleTick }
    Write-ConsoleResult -Status OK
}

Write-Caption -Text 'Column mode with -Note, where the script decides the full value is worth a line.'
Set-ConsoleStatusStyle -Width $Width
Write-ConsoleSection -Title 'Check paths'

foreach ($path in $paths) {
    Write-ConsoleItem -Label 'Path exists' -Value $path -TotalSteps 3
    1..3 | ForEach-Object { Write-ConsoleTick }

    if ($path.Length -gt ((Get-ConsoleStatusStyle).ValueWidth - 1)) {
        Write-ConsoleResult -Status OK -Note $path
    } else {
        Write-ConsoleResult -Status OK
    }
}

#endregion Truncate or note

#region Bar limits

Write-Heading -Text 'MaxBarLines and BarContinuation'

Set-ConsoleStatusStyle -Width $Width -MaxBarLines 0
Reset-ConsoleStatusLog
Write-Caption -Text 'MaxBarLines 0. No limit, so 500 ticks with no declared total take as many lines as they need.'
Write-ConsoleSection -Title 'Long running work'
Write-ConsoleItem -Label 'Unknown total' -Value '500 ticks'
1..500 | ForEach-Object { Write-ConsoleTick }
Write-ConsoleResult -Status OK -Detail 'finished'

Set-ConsoleStatusStyle -Width $Width
Write-Caption -Text 'MaxBarLines 3, the default. The rest are dropped, and the last cell says so.'
Write-ConsoleSection -Title 'Long running work'
Write-ConsoleItem -Label 'Unknown total' -Value '500 ticks'
1..500 | ForEach-Object { Write-ConsoleTick }
Write-ConsoleResult -Status OK -Detail 'finished'

Set-ConsoleStatusStyle -Width $Width -MaxBarLines 1
Write-Caption -Text 'MaxBarLines 1. One item is always one line.'
Write-ConsoleSection -Title 'Long running work'
Write-ConsoleItem -Label 'Unknown total' -Value '500 ticks'
1..500 | ForEach-Object { Write-ConsoleTick }
Write-ConsoleResult -Status OK -Detail 'finished'

Set-ConsoleStatusStyle -Width $Width -BarContinuation 'Blank'
Write-Caption -Text 'BarContinuation Blank. Continued lines close with an empty status block instead of a marker.'
Write-ConsoleSection -Title 'Long running work'
Write-ConsoleItem -Label 'Unknown total' -Value '150 ticks'
1..150 | ForEach-Object { Write-ConsoleTick }
Write-ConsoleResult -Status OK -Detail 'finished'

Set-ConsoleStatusStyle -Width $Width
Write-Caption -Text 'A declared total never wraps: the same work, one line, and the bar means something.'
Write-ConsoleSection -Title 'Long running work'
Write-ConsoleItem -Label 'Known total' -Value '500 items' -TotalSteps 500
1..500 | ForEach-Object { Write-ConsoleTick }
Write-ConsoleResult -Status OK -Detail 'finished'

#endregion Bar limits

Write-Host ''
