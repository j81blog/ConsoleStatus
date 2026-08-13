#Requires -Version 5.1
<#
    .SYNOPSIS
        Renders the ConsoleStatus layouts side by side so a style can be picked.

    .DESCRIPTION
        Imports the module and runs the same set of items four times: Column mode, Flow mode, the
        Unicode glyph set, and a pass driven entirely by $ConsoleStatusPreference.

        This script contains no layout logic of its own. Everything comes from the module, so what
        is shown here is what a consuming script gets.

    .PARAMETER MaxWidth
        Upper bound on the measured line width.

    .PARAMETER MinWidth
        Lower bound on the measured line width.

    .EXAMPLE
        .\ConsoleStatus-Demo.ps1

    .EXAMPLE
        .\ConsoleStatus-Demo.ps1 -MaxWidth 80

    .NOTES
        Function  : ConsoleStatus-Demo
        Author    : John Billekens
        Copyright : Copyright (c) John Billekens Consultancy
        Version   : 2026.810.1425
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateRange(60, 250)]
    [int]$MaxWidth = 120,

    [Parameter(Mandatory = $false)]
    [ValidateRange(40, 250)]
    [int]$MinWidth = 60
)

Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\ConsoleStatus\ConsoleStatus.psd1') -Force

function Show-Demo {
    <#
        .SYNOPSIS
            Renders one full demo pass in whatever style is currently configured.

        .PARAMETER Caption
            Title for the banner above the pass. The style of the pass is written underneath it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Caption
    )

    $style = Get-ConsoleStatusStyle
    Reset-ConsoleStatusLog

    try {
        $rawWidth = $Host.UI.RawUI.WindowSize.Width
    } catch {
        $rawWidth = 'n/a'
    }

    Write-ConsoleTitle -Title $Caption -Subtitle ("mode: {0}  |  console: {1}  |  line width: {2}" -f $style.Mode, $rawWidth, $style.LineWidth)

    Write-ConsoleSection -Title 'Prerequisites'

    # Manual API: the caller decides the status.
    Write-ConsoleItem -Label 'PowerShell version' -Value $PSVersionTable.PSVersion.ToString()
    1..14 | ForEach-Object {
        Write-ConsoleTick
        Start-Sleep -Milliseconds 25
    }
    Write-ConsoleResult -Status OK

    Write-ConsoleItem -Label 'Execution policy' -Value (Get-ExecutionPolicy).ToString()
    Write-ConsoleTick -Count 6
    Write-ConsoleResult -Status WARN

    Write-ConsoleItem -Label 'License file' -Value 'C:\ProgramData\Vendor\product.lic'
    Write-ConsoleTick -Count 4
    Write-ConsoleResult -Status FAIL

    Write-ConsoleItem -Label 'Optional component' -Value 'n/a'
    Write-ConsoleResult -Status SKIP

    Write-ConsoleSection -Title 'Collect data'

    # Wrapper API: the console gets the decoration, the variable gets the objects.
    $files = Invoke-ConsoleStep -Label 'Enumerate files' -Value $env:TEMP -Action {
        $items = Get-ChildItem -Path $env:TEMP -File -ErrorAction SilentlyContinue
        1..12 | ForEach-Object {
            Write-ConsoleTick
            Start-Sleep -Milliseconds 25
        }
        Set-ConsoleStepDetail -Text "$(@($items).Count) files"
        $items
    }

    $stamp = Invoke-ConsoleStep -Label 'Read timestamp' -Value (Get-Date -Format 'HH:mm:ss') -Action {
        Write-ConsoleTick -Count 10
        Get-Date
    }

    $null = Invoke-ConsoleStep -Label 'Reach unreachable host' -Value 'srv-does-not-exist' -ContinueOnError -Action {
        Write-ConsoleTick -Count 3
        throw 'Host not found'
    }

    Write-ConsoleSummary

    Write-ConsoleSection -Title 'Proof: output landed in the variables'
    Write-Host ("  `$files count : {0}" -f $files.Count) -ForegroundColor DarkGray
    Write-Host ("  `$files type  : {0}" -f $files.GetType().Name) -ForegroundColor DarkGray
    Write-Host ("  `$stamp type  : {0} -> {1}" -f $stamp.GetType().Name, $stamp) -ForegroundColor DarkGray
    Write-Host ''
}

Set-ConsoleStatusStyle -Mode 'Column' -MaxWidth $MaxWidth -MinWidth $MinWidth
Show-Demo -Caption 'Column mode, ASCII'

Set-ConsoleStatusStyle -Mode 'Flow' -MaxWidth $MaxWidth -MinWidth $MinWidth
Show-Demo -Caption 'Flow mode, ASCII'

Set-ConsoleStatusStyle -Mode 'Column' -MaxWidth $MaxWidth -MinWidth $MinWidth -Unicode
Show-Demo -Caption 'Column mode, Unicode'

# Same module, configured entirely up front instead of through parameters.
$ConsoleStatusPreference = @{
    Mode        = 'Column'
    MaxWidth    = 90
    LabelWidth  = 30
    ValueWidth  = 0        # no value column
    StatusWidth = 10
    TickChar    = '#'
    FillChar    = ' '
    RuleChar    = '='
    TitleChar   = '#'
}

Set-ConsoleStatusStyle
Show-Demo -Caption 'Driven by $ConsoleStatusPreference'
