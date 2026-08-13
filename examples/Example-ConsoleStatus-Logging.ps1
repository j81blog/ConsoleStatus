#Requires -Version 5.1
<#
    .SYNOPSIS
        Wires ConsoleStatus into a JSONL log writer, so one set of calls produces both the console
        output and the machine readable log.

    .DESCRIPTION
        Write-Log here is a self-contained JSONL writer, written to be replaced: one compressed JSON
        object per line, an ElapsedMs gap since the previous entry, a run correlation id, an
        optional Data dictionary merged into the entry, and a structured Error block when an
        ErrorRecord is passed. It is a fast no-op while disabled and it never throws at the caller.

        Swap it for whatever logging function you already have. Only the LogAction adapter below
        needs to change, because that is the single place the two signatures meet.

    .PARAMETER LogPath
        Where the JSONL file is written. Defaults to the temp folder.

    .PARAMETER Disabled
        Run with logging switched off, to show that the instrumentation costs nothing.

    .EXAMPLE
        .\Example-ConsoleStatus-Logging.ps1

    .EXAMPLE
        .\Example-ConsoleStatus-Logging.ps1 -Disabled

    .NOTES
        Function  : Example-ConsoleStatus-Logging
        Author    : John Billekens
        Copyright : Copyright (c) John Billekens Consultancy
        Version   : 2026.810.1425
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$LogPath = (Join-Path -Path $env:TEMP -ChildPath 'ConsoleStatus-run.jsonl'),

    [Parameter(Mandatory = $false)]
    [switch]$Disabled
)

$script:LogEnabled = -not $Disabled
$script:LogPath = $LogPath
$script:LogRunId = [guid]::NewGuid().ToString()
$script:LogLastTimestamp = $null
$script:LogScriptName = $MyInvocation.MyCommand.Name

function Write-Log {
    <#
        .SYNOPSIS
            Appends a single JSON object to the run log.

        .DESCRIPTION
            One entry per line, so the file can be read back with ConvertFrom-Json line by line and
            filtered without parsing the whole thing.

            Each entry carries the milliseconds since the previous entry, which makes a slow step
            obvious when reading the log, and the run id, so entries from one invocation can be
            grouped when several runs share a file.

            Logging must never break the caller: when disabled this returns immediately, and any
            failure while writing is swallowed onto the verbose stream.

        .PARAMETER Message
            Short, human readable description of what happened.

        .PARAMETER Function
            Name of the calling function. Defaults to the immediate caller.

        .PARAMETER Level
            Severity of the entry. Defaults to Info, or Error when an ErrorRecord is supplied
            without an explicit level.

        .PARAMETER Data
            Extra key and value pairs merged into the entry. Keys that would collide with a
            standard field are ignored. Accepts an ordered dictionary as well as a hashtable, so
            the caller can control the field order in the written line.

        .PARAMETER ErrorRecord
            Typically $_ from a catch block. Adds a structured Error block to the entry.

        .EXAMPLE
            Write-Log -Message 'Querying packages' -Data @{ Count = $rows.Count }

        .EXAMPLE
            try { ... } catch { Write-Log -Message 'Import failed' -ErrorRecord $_ }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [string]$Function = $((Get-PSCallStack)[1].Command),

        [Parameter(Mandatory = $false)]
        [ValidateSet('Info', 'Warning', 'Error', 'Timing')]
        [string]$Level = 'Info',

        [Parameter(Mandatory = $false)]
        [System.Collections.IDictionary]$Data,

        [Parameter(Mandatory = $false)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    # Fast no-op when disabled, so instrumentation left in the code is effectively free.
    if (-not $script:LogEnabled -or [string]::IsNullOrEmpty($script:LogPath)) {
        return
    }

    # The top level of a script has no command name on the call stack. Angle brackets would be
    # escaped by ConvertTo-Json, so use the script file name instead of a placeholder.
    if ([string]::IsNullOrEmpty($Function)) {
        $Function = $script:LogScriptName
    }

    # An ErrorRecord without an explicit level is an error.
    if ($PSBoundParameters.ContainsKey('ErrorRecord') -and $null -ne $ErrorRecord -and -not $PSBoundParameters.ContainsKey('Level')) {
        $Level = 'Error'
    }

    try {
        $now = [datetime]::Now
        $elapsedMs = 0

        if ($null -ne $script:LogLastTimestamp) {
            $elapsedMs = [int][Math]::Round(($now - $script:LogLastTimestamp).TotalMilliseconds)
        }

        $script:LogLastTimestamp = $now

        $entry = [ordered]@{
            Timestamp   = $now.ToString('o')
            ElapsedMs   = $elapsedMs
            Level       = $Level
            Function    = "$Function"
            Message     = $Message
            MachineName = $env:COMPUTERNAME
            ProcessId   = $PID
            RunId       = "$script:LogRunId"
        }

        if ($PSBoundParameters.ContainsKey('Data') -and $null -ne $Data) {
            foreach ($key in $Data.Keys) {
                if (-not $entry.Contains($key)) {
                    $entry[$key] = $Data[$key]
                }
            }
        }

        if ($PSBoundParameters.ContainsKey('ErrorRecord') -and $null -ne $ErrorRecord) {
            $entry['Error'] = [ordered]@{
                Message       = "$($ErrorRecord.Exception.Message)"
                ExceptionType = "$($ErrorRecord.Exception.GetType().FullName)"
                ScriptName    = "$($ErrorRecord.InvocationInfo.ScriptName)"
                LineNumber    = $ErrorRecord.InvocationInfo.ScriptLineNumber
            }
        }

        $json = [PSCustomObject]$entry | ConvertTo-Json -Compress -Depth 8
        [System.IO.File]::AppendAllText($script:LogPath, "$json`r`n", [System.Text.Encoding]::UTF8)
    } catch {
        # Never let logging break the caller.
        Write-Verbose -Message "Failed to write log entry: $($_.Exception.Message)"
    }
}

# The adapter. Written in the caller scope so it can see Write-Log, and mapping the record onto
# whatever parameter names the logger happens to use.
$ConsoleStatusPreference = @{
    Mode      = 'Column'
    MaxWidth  = 110
    LogAction = {
        param($Record)

        $level = switch ($Record.Status) {
            'FAIL' { 'Error' }
            'WARN' { 'Warning' }
            default { 'Info' }
        }

        $data = [ordered]@{
            Status     = $Record.Status
            Section    = $Record.Section
            Target     = $Record.Value
            DurationMs = $Record.DurationMs
        }

        foreach ($field in @('Detail', 'Note', 'Error')) {
            if (-not [string]::IsNullOrEmpty($Record.$field)) {
                $data[$field] = $Record.$field
            }
        }

        Write-Log -Message $Record.Label -Level $level -Function 'ConsoleStatus' -Data $data
    }
}

Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\ConsoleStatus\ConsoleStatus.psd1') -Force

Set-ConsoleStatusStyle
Reset-ConsoleStatusLog

# Start this run with a clean file, but only when there is going to be a run to write. Clearing a
# log that is then not replaced would lose the previous one for nothing.
if ($script:LogEnabled) {
    Remove-Item -Path $script:LogPath -ErrorAction SilentlyContinue
}

Write-Log -Message 'Run started' -Data @{ Script = $MyInvocation.MyCommand.Name }

Write-ConsoleTitle -Title 'Vendor.Product deployment' -Subtitle "$env:COMPUTERNAME, run $script:LogRunId" -StartTimer

Write-ConsoleSection -Title 'Deploy'

Invoke-ConsoleStep -Label 'Read configuration' -Value 'app.config' -TotalSteps 6 -Action {
    1..6 | ForEach-Object { Write-ConsoleTick }
    Set-ConsoleStepDetail -Text '18 keys'
}

Invoke-ConsoleStep -Label 'Install payload' -Value 'Vendor.Product.msi' -ShowDuration -Action {
    1..15 | ForEach-Object {
        Start-Sleep -Milliseconds 60
        Write-ConsoleTick
    }

    Set-ConsoleStepDetail -Text 'installed'
}

Write-ConsoleItem -Label 'Check signature' -Value 'Vendor.Product.msi'
Write-ConsoleTick -Count 8
Write-ConsoleResult -Status WARN -Note 'Signed by an untrusted publisher, continuing because -Force was given'

$null = Invoke-ConsoleStep -Label 'Import certificate' -Value 'wildcard.pfx' -ContinueOnError -Action {
    Write-ConsoleTick -Count 4
    throw 'The specified network password is not correct.'
}

# LogAction only ever sees the record, and the record flattens an exception to its message. When
# the type, the script name and the line number matter, log from the catch block where the real
# ErrorRecord still exists. The console line is already handled by the step.
try {
    $null = Invoke-ConsoleStep -Label 'Publish package' -Value 'repo.internal' -Action {
        Write-ConsoleTick -Count 6
        throw [System.IO.FileNotFoundException]::new('The feed manifest is missing.', 'manifest.json')
    }
} catch {
    Write-Log -Message 'Publish failed' -ErrorRecord $_ -Data @{ Target = 'repo.internal' }
}

Write-ConsoleSummary

$summary = Get-ConsoleStatusSummary

Write-Log -Message 'Run finished' -Level 'Timing' -Data @{
    Failed     = $summary.Fail
    DurationMs = $summary.DurationMs
    ElapsedMs  = $summary.ElapsedMs
}

Write-Host ''

if (-not $script:LogEnabled) {
    Write-Host '  logging disabled, nothing was written' -ForegroundColor DarkGray
    Write-Host ''
    return
}

Write-Host "  log file: $script:LogPath" -ForegroundColor DarkGray
Write-Host ''
Write-Host '  --- raw, one JSON object per line ---' -ForegroundColor DarkGray
Get-Content -Path $script:LogPath | Select-Object -First 2 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }

Write-Host ''
Write-Host '  --- read back and queried ---' -ForegroundColor DarkGray
$entries = Get-Content -Path $script:LogPath | ForEach-Object { $_ | ConvertFrom-Json }
$entries | Format-Table Level, ElapsedMs, Message, Status, DurationMs -AutoSize

Write-Host '  --- the failures. The step logged a flat message, the catch block logged the exception ---' -ForegroundColor DarkGray
$entries | Where-Object { $_.Level -eq 'Error' } | Format-List Message, Target, Error
