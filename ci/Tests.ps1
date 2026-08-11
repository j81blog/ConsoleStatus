<#
    .SYNOPSIS
        Runs the Pester suite over the repository.

    .DESCRIPTION
        Fails on any failed test. Writes TestResults.xml in NUnit format for the pipeline to pick
        up. Runs unchanged locally and in GitHub Actions.

    .EXAMPLE
        .\ci\Tests.ps1

    .NOTES
        Function  : Tests
        Author    : John Billekens
        Copyright : Copyright (c) John Billekens Consultancy
        Version   : 2026.811.0830
#>
[CmdletBinding()]
[OutputType()]
param ()

$ErrorActionPreference = 'Stop'

$projectRoot = (Resolve-Path -Path (Split-Path -Parent -Path $PSScriptRoot)).Path
$resultFile = Join-Path -Path $projectRoot -ChildPath 'TestResults.xml'

Write-Host ''
Write-Host "Script............: $($MyInvocation.MyCommand.Name)"
Write-Host "Edition...........: $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)"
Write-Host "Project root......: $projectRoot"

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
    exit 1
}

Write-Host 'Validation........: ok' -ForegroundColor Green
