<#
    .SYNOPSIS
        Runs PSScriptAnalyzer and Pester over the repository.

    .DESCRIPTION
        Fails on any analyzer finding and on any failed test. Writes TestResults.xml in NUnit
        format for the pipeline to pick up. Runs unchanged locally and in GitHub Actions.

    .PARAMETER SkipAnalyzer
        Run the tests only.

    .EXAMPLE
        .\ci\Tests.ps1

    .NOTES
        Function  : Tests
        Author    : John Billekens
        Copyright : Copyright (c) John Billekens Consultancy
        Version   : 2026.810.1425
#>
[CmdletBinding()]
[OutputType()]
param (
    [Parameter(Mandatory = $false)]
    [switch]$SkipAnalyzer
)

$ErrorActionPreference = 'Stop'

$projectRoot = (Resolve-Path -Path (Split-Path -Parent -Path $PSScriptRoot)).Path
$settings = Join-Path -Path $projectRoot -ChildPath 'PSScriptAnalyzerSettings.psd1'
$resultFile = Join-Path -Path $projectRoot -ChildPath 'TestResults.xml'
$failed = $false

Write-Host ''
Write-Host "Script............: $($MyInvocation.MyCommand.Name)"
Write-Host "Edition...........: $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)"
Write-Host "Project root......: $projectRoot"

if (-not $SkipAnalyzer) {
    Import-Module -Name 'PSScriptAnalyzer' -MinimumVersion '1.21.0'

    # One recursive call per folder, not one per file: each invocation reinitializes the engine,
    # which turns a few seconds into minutes over a repository this size.
    Write-Host "Analyzer..........: $(Split-Path -Path $projectRoot -Leaf) against $(Split-Path -Path $settings -Leaf)"

    # PSScriptAnalyzer occasionally fails a rule in its own runspace on Windows PowerShell, with
    # RULE_ERROR "The term 'Get-Command' is not recognized". With ErrorActionPreference Stop that
    # aborts the whole run at random, so rule errors are collected and reported instead.
    $analyzerErrors = @()
    $issues = @(
        foreach ($folder in @('ConsoleStatus', 'ci', 'tests', 'examples')) {
            $target = Join-Path -Path $projectRoot -ChildPath $folder

            if (Test-Path -Path $target) {
                Invoke-ScriptAnalyzer -Path $target -Recurse -Settings $settings -ErrorVariable +analyzerErrors -ErrorAction SilentlyContinue
            }
        }
    )

    if ($analyzerErrors.Count -gt 0) {
        Write-Host "Analyzer..........: $($analyzerErrors.Count) rule error(s), analysis may be incomplete" -ForegroundColor Yellow

        foreach ($analyzerError in $analyzerErrors) {
            Write-Host "                    $($analyzerError.Exception.Message)" -ForegroundColor DarkYellow
        }
    }

    if ($issues.Count -gt 0) {
        $issues | Format-Table -Property Severity, ScriptName, Line, RuleName, Message -AutoSize -Wrap | Out-String | Write-Host
        Write-Host "Analyzer..........: $($issues.Count) issue(s)" -ForegroundColor Red
        $failed = $true
    } else {
        Write-Host 'Analyzer..........: clean' -ForegroundColor Green
    }
}

Import-Module -Name 'Pester' -MinimumVersion '5.0.0'

$configuration = New-PesterConfiguration
$configuration.Run.Path = Join-Path -Path $projectRoot -ChildPath 'tests'
$configuration.Run.PassThru = $true
$configuration.Output.Verbosity = 'Detailed'
$configuration.TestResult.Enabled = $true
$configuration.TestResult.OutputFormat = 'NUnitXml'
$configuration.TestResult.OutputPath = $resultFile

$result = Invoke-Pester -Configuration $configuration

Write-Host ''
Write-Host "Tests.............: $($result.PassedCount) passed, $($result.FailedCount) failed, $($result.SkippedCount) skipped"
Write-Host "Results...........: $resultFile"

if ($result.FailedCount -gt 0) {
    $failed = $true
}

if ($failed) {
    exit 1
}

Write-Host 'Validation........: ok' -ForegroundColor Green
