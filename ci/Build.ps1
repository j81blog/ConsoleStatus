<#
    .SYNOPSIS
        Publishes the module to the PowerShell Gallery.

    .DESCRIPTION
        Validates the manifest, then publishes when the branch maps to a gallery and the version is
        not already there. A version that already exists is reported and skipped rather than
        treated as an error, so pushes between version bumps do not fail the pipeline.

        main publishes to PSGallery, dev to PSTestGallery. Any other branch validates and stops.

    .PARAMETER WhatIfPublish
        Do everything except the Publish-Module call.

    .EXAMPLE
        .\ci\Build.ps1 -WhatIfPublish

    .NOTES
        Function  : Build
        Author    : John Billekens
        Copyright : Copyright (c) John Billekens Consultancy
        Version   : 2026.810.1425
#>
[CmdletBinding()]
[OutputType()]
param (
    [Parameter(Mandatory = $false)]
    [switch]$WhatIfPublish
)

$ErrorActionPreference = 'Stop'

$moduleName = 'ConsoleStatus'
$projectRoot = (Resolve-Path -Path (Split-Path -Parent -Path $PSScriptRoot)).Path
$moduleRoot = Join-Path -Path $projectRoot -ChildPath $moduleName
$branch = if ([string]::IsNullOrEmpty(${env:GITHUB_REF_NAME})) { 'local' } else { ${env:GITHUB_REF_NAME} }

$psTestGalleryUri = 'https://www.poshtestgallery.com/api/v2/'

# Branch to gallery. Add entries here to publish from another branch.
$galleries = @{
    main = @{
        Repository  = 'PSGallery'
        NuGetApiKey = ${env:NugetApiKey}
    }
    dev  = @{
        Repository  = 'PSTestGallery'
        NuGetApiKey = ${env:NugetApiKeyDev}
    }
}

Write-Host ''
Write-Host "Script............: $($MyInvocation.MyCommand.Name)"
Write-Host "Edition...........: $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)"
Write-Host "Branch............: $branch"
Write-Host "Module root.......: $moduleRoot"

$manifest = Test-ModuleManifest -Path (Join-Path -Path $moduleRoot -ChildPath "$moduleName.psd1")
Write-Host "Module version....: $($manifest.Version)"
Write-Host "Exported..........: $($manifest.ExportedFunctions.Count) functions"

if (-not $galleries.ContainsKey($branch)) {
    Write-Host "Publish...........: skipped, $branch does not map to a gallery"
    exit 0
}

$repository = $galleries[$branch].Repository

if ([string]::IsNullOrEmpty($galleries[$branch].NuGetApiKey)) {
    Write-Host "Publish...........: no API key in the environment for $repository" -ForegroundColor Red
    exit 1
}

try {
    if ($repository -eq 'PSTestGallery') {
        Write-Host "Repository........: registering $repository"
        Register-PackageSource -Trusted -ProviderName 'PowerShellGet' -Name $repository -Location $psTestGalleryUri -Force -ErrorAction SilentlyContinue | Out-Null
    }

    $existing = Find-Module -Name $moduleName -Repository $repository -AllVersions -ErrorAction SilentlyContinue

    if ($existing | Where-Object { [System.Version]$_.Version -eq $manifest.Version }) {
        Write-Host "Publish...........: $($manifest.Version) already in $repository, nothing to do"
        exit 0
    }

    if ($WhatIfPublish) {
        Write-Host "Publish...........: would publish $($manifest.Version) to $repository"
        exit 0
    }

    Write-Host "Publish...........: $($manifest.Version) to $repository"

    $parameters = @{
        Path        = $moduleRoot
        Repository  = $repository
        NuGetApiKey = $galleries[$branch].NuGetApiKey
        Force       = $true
    }

    Publish-Module @parameters

    Write-Host "Publish...........: done" -ForegroundColor Green
} finally {
    if ($repository -eq 'PSTestGallery') {
        Unregister-PSRepository -Name $repository -ErrorAction SilentlyContinue
    }
}
