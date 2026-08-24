[CmdletBinding()]
param (
    [string]$ModuleName = 'ConsoleStatus'
)

function Get-DateTimeVersionString {
    param (
        [datetime]$DateTime = [DateTime]::Now
    )
    $Hour = [Int]$DateTime.ToString("HH")
    if ($DateTime.Minute -eq 0) {
        $Minutes = 0
    } elseif ($DateTime.Minute -gt 0 -and $DateTime.Minute -le 15) {
        $Minutes = 15
    } elseif ($DateTime.Minute -le 30) {
        $Minutes = 30
    } elseif ($DateTime.Minute -le 45) {
        $Minutes = 45
    } else {
        $Minutes = 0
        if ($Hour -lt 23) {
            $Hour++
        } else {
            $DateTime = $DateTime.AddHours(1)
            $Hour = 0
        }
    }
    return '{0}{1}{2:d2}' -f $DateTime.ToString("yyyy.Mdd."), $Hour, $Minutes
}

$NewVersion = Get-DateTimeVersionString
$manifestPath = Join-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath $ModuleName) -ChildPath "$ModuleName.psd1"

Write-Host "Updating module manifest at $manifestPath to version $NewVersion..." -ForegroundColor Cyan
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Module manifest not found: $manifestPath"
}

$content = Get-Content -LiteralPath $manifestPath -Raw
$pattern = "(?m)^(\s*ModuleVersion\s*=\s*)['""][^'""]+['""]"
if (-not [regex]::IsMatch($content, $pattern)) {
    throw "ModuleVersion entry not found in manifest: $manifestPath"
}

$replacement = "`${1}'$NewVersion'"
$updated = [regex]::Replace($content, $pattern, $replacement, 1)

if ($updated -ne $content) {
    Set-Content -LiteralPath $manifestPath -Value $updated -Encoding UTF8
}
Test-ModuleManifest -Path $manifestPath -ErrorAction Stop | Out-Null

if (Get-Module J81FunctionLibrary) {
    Write-Host "Signing all module files with a valid code signing certificate..." -ForegroundColor Cyan
    Get-ChildItem -Path "$PSScriptRoot\$ModuleName\*" -Recurse -Include *.ps1, *.psd1, *.psm1 | Set-Signature -ValidatePS -UseAzureSigning -ArtifactProfile JOBICO
    Write-Host "Module manifest and scripts have been updated and signed. You can now commit the changes to GitHub." -ForegroundColor Green
}
Write-Host "`r`nUpdated $ModuleName module manifests to version $NewVersion.`r`n" -ForegroundColor Green
