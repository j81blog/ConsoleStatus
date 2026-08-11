<#
    .SYNOPSIS
        Installs the modules the pipeline needs.

    .DESCRIPTION
        Runs once per shell, because Windows PowerShell and PowerShell 7 have separate module
        paths. Existing versions that are new enough are left alone.

    .NOTES
        Function  : Install
        Author    : John Billekens
        Copyright : Copyright (c) John Billekens Consultancy
        Version   : 2026.810.1425
#>
[CmdletBinding()]
[OutputType()]
param ()

$ErrorActionPreference = 'Stop'

$required = @(
    @{ Name = 'Pester'; MinimumVersion = '5.0.0' }
)

Write-Host ''
Write-Host "Script............: $($MyInvocation.MyCommand.Name)"
Write-Host "Edition...........: $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)"
Write-Host "Branch............: ${env:GITHUB_REF_NAME}"

# Optional bootstrap. Install-Module below reports a real failure.
try {
    if (-not (Get-PackageProvider -ListAvailable | Where-Object { $_.Name -eq 'NuGet' -and $_.Version -ge [System.Version]'2.8.5.208' })) {
        Write-Host 'Provider..........: installing NuGet'
        $null = Install-PackageProvider -Name 'NuGet' -MinimumVersion '2.8.5.208' -Force
    }
} catch {
    Write-Host "Provider..........: NuGet bootstrap skipped, $($_.Exception.Message)" -ForegroundColor Yellow
}

try {
    if (Get-PSRepository -Name 'PSGallery' -ErrorAction Stop | Where-Object { $_.InstallationPolicy -ne 'Trusted' }) {
        Write-Host 'Repository........: trusting PSGallery'
        Set-PSRepository -Name 'PSGallery' -InstallationPolicy 'Trusted'
    }
} catch {
    Write-Host "Repository........: PSGallery not registered, $($_.Exception.Message)" -ForegroundColor Yellow
}

foreach ($module in $required) {
    $installed = Get-Module -Name $module.Name -ListAvailable |
        Sort-Object -Property Version -Descending |
        Select-Object -First 1

    if ($null -ne $installed -and $installed.Version -ge [System.Version]$module.MinimumVersion) {
        Write-Host "Module............: $($module.Name) $($installed.Version) already present"
        continue
    }

    Write-Host "Module............: installing $($module.Name) $($module.MinimumVersion) or newer"
    Install-Module -Name $module.Name -MinimumVersion $module.MinimumVersion -Scope 'CurrentUser' -SkipPublisherCheck -Force -AllowClobber
}

Write-Host 'Install...........: done'
