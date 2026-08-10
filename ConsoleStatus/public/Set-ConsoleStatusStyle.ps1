function Set-ConsoleStatusStyle {
    <#
        .SYNOPSIS
            Applies defaults, $ConsoleStatusPreference and explicit parameters, then fits the columns.

        .DESCRIPTION
            Rebuilds the whole configuration on every call: built in defaults first, then the
            $ConsoleStatusPreference hashtable from the caller scope, then any parameter passed
            here. Finally the console is measured and the columns are fitted inside the resulting
            line width, shrinking the value column before the label column.

            Call once at the start of a script, or again after a deliberate window resize.

        .PARAMETER Mode
            Column aligns every value in a fixed column and truncates long values.
            Flow lets the value run at its natural length and absorbs the difference in the leader.

        .PARAMETER Indent
            Left margin in characters.

        .PARAMETER LabelWidth
            Width of the label column in Column mode.

        .PARAMETER ValueWidth
            Width of the value column in Column mode. Use 0 to drop the value column completely.

        .PARAMETER StatusWidth
            Width of the trailing status block, brackets included.

        .PARAMETER Width
            Pins the exact line width and skips measuring. MinWidth and MaxWidth are not applied,
            but the value is still clamped to the console when one is detected. Use 0 to measure.

        .PARAMETER ForceWidth
            Allow a pinned width that is wider than the detected console.

        .PARAMETER MaxWidth
            Upper bound on the measured line width. Defaults to 120, the width of a default
            PowerShell window, so a normal window is filled and only a wider one is capped.

        .PARAMETER MinWidth
            Lower bound on the measured line width, used when the window is narrow or absent.

        .PARAMETER BarContinuation
            How a bar line that continues below is closed. Open leaves it bare, Blank ends it with
            an empty status block. Either way the empty columns and the missing status mark it.

        .PARAMETER MaxBarLines
            How many lines a bar with no declared total may wrap onto before it stops being drawn.
            The last cell then becomes MoreChar to show that the work carried on. Use 0 for no
            limit, or 1 to keep every item on a single line. Bars with a TotalSteps never wrap.

        .PARAMETER Unicode
            Uses box drawing and block glyphs and sets the console output encoding to UTF-8.
            Individual glyphs can still be overridden with TickChar, FillChar and RuleChar.

        .PARAMETER TickChar
            Single character drawn for progress. Defaults to an asterisk.

        .PARAMETER FillChar
            Single character that pads the unused part of the progress field, which doubles as the
            leader between the value and the status. Defaults to a dot.

        .PARAMETER RuleChar
            Single character the section rule is drawn from. Defaults to a hyphen.

        .PARAMETER MoreChar
            Single character marking a bar that ran out of cells, and prefixing a note.
            Defaults to a greater than sign.

        .PARAMETER NoColor
            Writes everything without color. $env:NO_COLOR does the same.

        .PARAMETER ShowDuration
            Appends the elapsed time to each result. The duration is recorded either way.

        .PARAMETER LogAction
            Scriptblock invoked with one record per completed item. Exceptions from it are caught
            and warned about once, so a broken logger cannot stop the script.

        .EXAMPLE
            Set-ConsoleStatusStyle

        .EXAMPLE
            Set-ConsoleStatusStyle -Mode 'Flow' -MaxWidth 100 -Unicode

        .EXAMPLE
            Set-ConsoleStatusStyle -LabelWidth 32 -ValueWidth 0
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [ValidateSet('Column', 'Flow')]
        [string]$Mode,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 20)]
        [int]$Indent,

        [Parameter(Mandatory = $false)]
        [ValidateRange(8, 80)]
        [int]$LabelWidth,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 80)]
        [int]$ValueWidth,

        [Parameter(Mandatory = $false)]
        [ValidateRange(6, 12)]
        [int]$StatusWidth,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 250)]
        [int]$Width,

        [Parameter(Mandatory = $false)]
        [switch]$ForceWidth,

        [Parameter(Mandatory = $false)]
        [ValidateRange(60, 250)]
        [int]$MaxWidth,

        [Parameter(Mandatory = $false)]
        [ValidateRange(40, 250)]
        [int]$MinWidth,

        [Parameter(Mandatory = $false)]
        [switch]$Unicode,

        [Parameter(Mandatory = $false)]
        [switch]$NoColor,

        [Parameter(Mandatory = $false)]
        [switch]$ShowDuration,

        [Parameter(Mandatory = $false)]
        [string]$TickChar,

        [Parameter(Mandatory = $false)]
        [string]$FillChar,

        [Parameter(Mandatory = $false)]
        [string]$RuleChar,

        [Parameter(Mandatory = $false)]
        [string]$MoreChar,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Open', 'Blank')]
        [string]$BarContinuation,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 20)]
        [int]$MaxBarLines,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [scriptblock]$LogAction
    )

    $cfg = $script:ConsoleStatus
    $glyphKeys = @('TickChar', 'FillChar', 'RuleChar', 'MoreChar')
    $explicitGlyphs = @{}

    # 1. Defaults.
    foreach ($key in $script:ConsoleStatusDefaults.Keys) {
        $cfg[$key] = $script:ConsoleStatusDefaults[$key]
    }

    # 2. Preference table from the caller scope.
    $preference = Get-ConsoleStatusPreference -CallerState $PSCmdlet.SessionState

    foreach ($key in @($preference.Keys)) {
        Test-ConsoleStatusSetting -Name $key -Value $preference[$key] -Source '$ConsoleStatusPreference'
        $cfg[$key] = $preference[$key]

        if ($key -in $glyphKeys) {
            $explicitGlyphs[$key] = [string]$preference[$key]
        }
    }

    # 3. Explicit parameters win.
    foreach ($key in @($PSBoundParameters.Keys)) {
        if (-not $script:ConsoleStatusDefaults.ContainsKey($key)) {
            continue
        }

        $cfg[$key] = $PSBoundParameters[$key]

        if ($key -in $glyphKeys) {
            $explicitGlyphs[$key] = [string]$PSBoundParameters[$key]
        }
    }

    # Hashtable values can arrive as strings or switches.
    foreach ($key in @('Unicode', 'NoColor', 'ForceWidth', 'ShowDuration')) {
        $cfg[$key] = [bool]$cfg[$key]
    }

    foreach ($key in @('Indent', 'LabelWidth', 'ValueWidth', 'StatusWidth', 'Width', 'MinWidth', 'MaxWidth', 'MaxBarLines')) {
        $cfg[$key] = [int]$cfg[$key]
    }

    # NO_COLOR: any non-empty value disables color.
    if (-not [string]::IsNullOrEmpty($env:NO_COLOR)) {
        $cfg.NoColor = $true
    }

    # 4. Glyph set, then explicit glyph overrides.
    if ($cfg.Unicode) {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $cfg.TickChar = [char]0x2588   # full block
        $cfg.FillChar = [char]0x00B7   # middle dot
        $cfg.RuleChar = [char]0x2500   # box drawing horizontal
        $cfg.MoreChar = [char]0x00BB   # right pointing double angle
    }

    foreach ($key in $explicitGlyphs.Keys) {
        $cfg[$key] = $explicitGlyphs[$key]
    }

    $cfg.MinWidth = [Math]::Min($cfg.MinWidth, $cfg.MaxWidth)
    $cfg.LineWidth = Get-ConsoleLineWidth

    # 5. Fit the columns, value column shrinks first. The -1 is the status gap.
    $available = $cfg.LineWidth - $cfg.Indent - $cfg.StatusWidth - 1

    while (($cfg.LabelWidth + $cfg.ValueWidth + 6) -gt $available) {
        if ($cfg.ValueWidth -gt 8) {
            $cfg.ValueWidth--
        } elseif ($cfg.LabelWidth -gt 12) {
            $cfg.LabelWidth--
        } else {
            break
        }
    }
}

# SIG # Begin signature block
# MII6AQYJKoZIhvcNAQcCoII58jCCOe4CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBU3PxOmUJt8U+T
# 7RzNKE5FP5Q26jgac37KPkAjba8pzaCCIiYwggXMMIIDtKADAgECAhBUmNLR1FsZ
# lUgTecgRwIeZMA0GCSqGSIb3DQEBDAUAMHcxCzAJBgNVBAYTAlVTMR4wHAYDVQQK
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xSDBGBgNVBAMTP01pY3Jvc29mdCBJZGVu
# dGl0eSBWZXJpZmljYXRpb24gUm9vdCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkgMjAy
# MDAeFw0yMDA0MTYxODM2MTZaFw00NTA0MTYxODQ0NDBaMHcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xSDBGBgNVBAMTP01pY3Jv
# c29mdCBJZGVudGl0eSBWZXJpZmljYXRpb24gUm9vdCBDZXJ0aWZpY2F0ZSBBdXRo
# b3JpdHkgMjAyMDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALORKgeD
# Bmf9np3gx8C3pOZCBH8Ppttf+9Va10Wg+3cL8IDzpm1aTXlT2KCGhFdFIMeiVPvH
# or+Kx24186IVxC9O40qFlkkN/76Z2BT2vCcH7kKbK/ULkgbk/WkTZaiRcvKYhOuD
# PQ7k13ESSCHLDe32R0m3m/nJxxe2hE//uKya13NnSYXjhr03QNAlhtTetcJtYmrV
# qXi8LW9J+eVsFBT9FMfTZRY33stuvF4pjf1imxUs1gXmuYkyM6Nix9fWUmcIxC70
# ViueC4fM7Ke0pqrrBc0ZV6U6CwQnHJFnni1iLS8evtrAIMsEGcoz+4m+mOJyoHI1
# vnnhnINv5G0Xb5DzPQCGdTiO0OBJmrvb0/gwytVXiGhNctO/bX9x2P29Da6SZEi3
# W295JrXNm5UhhNHvDzI9e1eM80UHTHzgXhgONXaLbZ7LNnSrBfjgc10yVpRnlyUK
# xjU9lJfnwUSLgP3B+PR0GeUw9gb7IVc+BhyLaxWGJ0l7gpPKWeh1R+g/OPTHU3mg
# trTiXFHvvV84wRPmeAyVWi7FQFkozA8kwOy6CXcjmTimthzax7ogttc32H83rwjj
# O3HbbnMbfZlysOSGM1l0tRYAe1BtxoYT2v3EOYI9JACaYNq6lMAFUSw0rFCZE4e7
# swWAsk0wAly4JoNdtGNz764jlU9gKL431VulAgMBAAGjVDBSMA4GA1UdDwEB/wQE
# AwIBhjAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBTIftJqhSobyhmYBAcnz1AQ
# T2ioojAQBgkrBgEEAYI3FQEEAwIBADANBgkqhkiG9w0BAQwFAAOCAgEAr2rd5hnn
# LZRDGU7L6VCVZKUDkQKL4jaAOxWiUsIWGbZqWl10QzD0m/9gdAmxIR6QFm3FJI9c
# Zohj9E/MffISTEAQiwGf2qnIrvKVG8+dBetJPnSgaFvlVixlHIJ+U9pW2UYXeZJF
# xBA2CFIpF8svpvJ+1Gkkih6PsHMNzBxKq7Kq7aeRYwFkIqgyuH4yKLNncy2RtNwx
# AQv3Rwqm8ddK7VZgxCwIo3tAsLx0J1KH1r6I3TeKiW5niB31yV2g/rarOoDXGpc8
# FzYiQR6sTdWD5jw4vU8w6VSp07YEwzJ2YbuwGMUrGLPAgNW3lbBeUU0i/OxYqujY
# lLSlLu2S3ucYfCFX3VVj979tzR/SpncocMfiWzpbCNJbTsgAlrPhgzavhgplXHT2
# 6ux6anSg8Evu75SjrFDyh+3XOjCDyft9V77l4/hByuVkrrOj7FjshZrM77nq81YY
# uVxzmq/FdxeDWds3GhhyVKVB0rYjdaNDmuV3fJZ5t0GNv+zcgKCf0Xd1WF81E+Al
# GmcLfc4l+gcK5GEh2NQc5QfGNpn0ltDGFf5Ozdeui53bFv0ExpK91IjmqaOqu/dk
# ODtfzAzQNb50GQOmxapMomE2gj4d8yu8l13bS3g7LfU772Aj6PXsCyM2la+YZr9T
# 03u4aUoqlmZpxJTG9F9urJh4iIAGXKKy7aIwggbAMIIEqKADAgECAhMzAASEcyHl
# BrFHvfbiAAAABIRzMA0GCSqGSIb3DQEBDAUAMFoxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJ
# RCBWZXJpZmllZCBDUyBBT0MgQ0EgMDMwHhcNMjYwODA5MjAwNTA1WhcNMjYwODEy
# MjAwNTA1WjCBgzELMAkGA1UEBhMCTkwxFjAUBgNVBAgTDU5vb3JkLUJyYWJhbnQx
# EjAQBgNVBAcTCVNjaGlqbmRlbDEjMCEGA1UEChMaSm9obiBCaWxsZWtlbnMgQ29u
# c3VsdGFuY3kxIzAhBgNVBAMTGkpvaG4gQmlsbGVrZW5zIENvbnN1bHRhbmN5MIIB
# ojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEAoJVbXNHcOxeKJNv9uV0n3ud6
# 97XLrPiYdcB/pxzUVIjIbS7R5n2OmhvM1Nduczk2vtkZU9I3ied3Yoqo7EjTRQmz
# 4oy3wVWxbS2F1qfBdWN+YLvNKAXBlaoNcf+N7Uqi1NSTVok4pQYxUIIfJHootufa
# Tg8y652umBXzVuMltBNmNCkMGxGSILCDVjdyXh4BLUXipKQk9HxUxXPadIL8yD3c
# 3AaK8IVLFuORcW8eadiLwVdWKeVmfyNAFXLWcqrAbcPviZSuIVXA5MNf53mCXWIb
# 7koZxzB/ZZUjE6QfGQc98cnVaPH+4M1r7MxaUEQF65bql9Kl1Yy5PzERRHF63dY5
# D41frBrR/d9iDluDfnsMtVS1O0CK/F6Xck/+wD2MgLtQaCyQ9NkNmd8Wzf1IXTKx
# PGJAyNe1/3izzgDn0R0voMNu0e9wO6SdYdCczdsP4odmYKfou5IxCWJLnceNeTsR
# UI0mvbKNkIwpuz2B2dmZvJcLaXqQXKwnIqpnLtC1AgMBAAGjggHTMIIBzzAMBgNV
# HRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDA6BgNVHSUEMzAxBgorBgEEAYI3YQEA
# BggrBgEFBQcDAwYZKwYBBAGCN2HK9PELgrHSgxH33KNOluu6MTAdBgNVHQ4EFgQU
# cd4egluyMl6K3XLaDaM9PbyocNYwHwYDVR0jBBgwFoAUpEMMf3ZapYXnPo0oDwwX
# okVpcMYwZwYDVR0fBGAwXjBcoFqgWIZWaHR0cDovL3d3dy5taWNyb3NvZnQuY29t
# L3BraW9wcy9jcmwvTWljcm9zb2Z0JTIwSUQlMjBWZXJpZmllZCUyMENTJTIwQU9D
# JTIwQ0ElMjAwMy5jcmwwdAYIKwYBBQUHAQEEaDBmMGQGCCsGAQUFBzAChlhodHRw
# Oi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01pY3Jvc29mdCUyMElE
# JTIwVmVyaWZpZWQlMjBDUyUyMEFPQyUyMENBJTIwMDMuY3J0MFQGA1UdIARNMEsw
# SQYEVR0gADBBMD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20v
# cGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5odG0wDQYJKoZIhvcNAQEMBQADggIBABdO
# peVUHsDdz1ojFSvgmwM3tQoPaZxErogBaEiCBHL8xW3h4tMyoaTAIWPBe6JULu22
# xUYtm0i+Q+g/zhd6qnt4CLE8tOucCnOD8W3Yweup1F+0WpYxO0HfqB55zWzBoYyI
# CMTrKdVGVRN9p0+Pz3uVvTRJmfXN41sy2+kDxTf/TqcdA7+zsaw20lt31K84yZGf
# uCk7osPtbhLppeqpxri4bWKYAdDk0/JatrWakIJRg9Fpdarn8Wu0JqjY0BWhc5Ys
# Xh3joN7LsXYZtxXCtDgsOiwHmn0Pmdcd7d/prJ+K9D7aLoNhTkTK0URsBvIJCMLF
# Fg9UqVFxNLE/OKHnha8Eay4/R1HGEeL2SljhkIZGj/tlNOjEhLFIQaGhDrP8yCoe
# Tp7jmk08qL4KK/vdcdBi4EE3mWqNhbMCIYIRSjyZMV2+R9evf7e6H/5QWaRJVi9y
# uOEzcD39AWGuXGnfRZkTVR7Gk43HPggmc96yXdk9RWSgFRCdUJxCYfIHBDDawsx8
# NfwFXjvnUubpnxezuqkjqgCRZeegn453l7pQfj3FT29ESX/Cfp+eMrQWSgmO0asQ
# Cm8jxMFNBRkQDJvnHvLXIFSjCZ/8mZPzVJ65fk0O2sAu95prVTYC6NuuMvSKjO1G
# EL7BBM5hLxhdziEJ6tgz0th7lLsrGYeT5ZhfGxfGMIIGwDCCBKigAwIBAgITMwAE
# hHMh5QaxR7324gAAAASEczANBgkqhkiG9w0BAQwFADBaMQswCQYDVQQGEwJVUzEe
# MBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSswKQYDVQQDEyJNaWNyb3Nv
# ZnQgSUQgVmVyaWZpZWQgQ1MgQU9DIENBIDAzMB4XDTI2MDgwOTIwMDUwNVoXDTI2
# MDgxMjIwMDUwNVowgYMxCzAJBgNVBAYTAk5MMRYwFAYDVQQIEw1Ob29yZC1CcmFi
# YW50MRIwEAYDVQQHEwlTY2hpam5kZWwxIzAhBgNVBAoTGkpvaG4gQmlsbGVrZW5z
# IENvbnN1bHRhbmN5MSMwIQYDVQQDExpKb2huIEJpbGxla2VucyBDb25zdWx0YW5j
# eTCCAaIwDQYJKoZIhvcNAQEBBQADggGPADCCAYoCggGBAKCVW1zR3DsXiiTb/bld
# J97neve1y6z4mHXAf6cc1FSIyG0u0eZ9jpobzNTXbnM5Nr7ZGVPSN4nnd2KKqOxI
# 00UJs+KMt8FVsW0thdanwXVjfmC7zSgFwZWqDXH/je1KotTUk1aJOKUGMVCCHyR6
# KLbn2k4PMuudrpgV81bjJbQTZjQpDBsRkiCwg1Y3cl4eAS1F4qSkJPR8VMVz2nSC
# /Mg93NwGivCFSxbjkXFvHmnYi8FXVinlZn8jQBVy1nKqwG3D74mUriFVwOTDX+d5
# gl1iG+5KGccwf2WVIxOkHxkHPfHJ1Wjx/uDNa+zMWlBEBeuW6pfSpdWMuT8xEURx
# et3WOQ+NX6wa0f3fYg5bg357DLVUtTtAivxel3JP/sA9jIC7UGgskPTZDZnfFs39
# SF0ysTxiQMjXtf94s84A59EdL6DDbtHvcDuknWHQnM3bD+KHZmCn6LuSMQliS53H
# jXk7EVCNJr2yjZCMKbs9gdnZmbyXC2l6kFysJyKqZy7QtQIDAQABo4IB0zCCAc8w
# DAYDVR0TAQH/BAIwADAOBgNVHQ8BAf8EBAMCB4AwOgYDVR0lBDMwMQYKKwYBBAGC
# N2EBAAYIKwYBBQUHAwMGGSsGAQQBgjdhyvTxC4Kx0oMR99yjTpbrujEwHQYDVR0O
# BBYEFHHeHoJbsjJeit1y2g2jPT28qHDWMB8GA1UdIwQYMBaAFKRDDH92WqWF5z6N
# KA8MF6JFaXDGMGcGA1UdHwRgMF4wXKBaoFiGVmh0dHA6Ly93d3cubWljcm9zb2Z0
# LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMElEJTIwVmVyaWZpZWQlMjBDUyUy
# MEFPQyUyMENBJTIwMDMuY3JsMHQGCCsGAQUFBwEBBGgwZjBkBggrBgEFBQcwAoZY
# aHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jZXJ0cy9NaWNyb3NvZnQl
# MjBJRCUyMFZlcmlmaWVkJTIwQ1MlMjBBT0MlMjBDQSUyMDAzLmNydDBUBgNVHSAE
# TTBLMEkGBFUdIAAwQTA/BggrBgEFBQcCARYzaHR0cDovL3d3dy5taWNyb3NvZnQu
# Y29tL3BraW9wcy9Eb2NzL1JlcG9zaXRvcnkuaHRtMA0GCSqGSIb3DQEBDAUAA4IC
# AQAXTqXlVB7A3c9aIxUr4JsDN7UKD2mcRK6IAWhIggRy/MVt4eLTMqGkwCFjwXui
# VC7ttsVGLZtIvkPoP84Xeqp7eAixPLTrnApzg/Ft2MHrqdRftFqWMTtB36geec1s
# waGMiAjE6ynVRlUTfadPj897lb00SZn1zeNbMtvpA8U3/06nHQO/s7GsNtJbd9Sv
# OMmRn7gpO6LD7W4S6aXqqca4uG1imAHQ5NPyWra1mpCCUYPRaXWq5/FrtCao2NAV
# oXOWLF4d46Dey7F2GbcVwrQ4LDosB5p9D5nXHe3f6ayfivQ+2i6DYU5EytFEbAby
# CQjCxRYPVKlRcTSxPzih54WvBGsuP0dRxhHi9kpY4ZCGRo/7ZTToxISxSEGhoQ6z
# /MgqHk6e45pNPKi+Civ73XHQYuBBN5lqjYWzAiGCEUo8mTFdvkfXr3+3uh/+UFmk
# SVYvcrjhM3A9/QFhrlxp30WZE1UexpONxz4IJnPesl3ZPUVkoBUQnVCcQmHyBwQw
# 2sLMfDX8BV4751Lm6Z8Xs7qpI6oAkWXnoJ+Od5e6UH49xU9vREl/wn6fnjK0FkoJ
# jtGrEApvI8TBTQUZEAyb5x7y1yBUowmf/JmT81SeuX5NDtrALveaa1U2AujbrjL0
# ioztRhC+wQTOYS8YXc4hCerYM9LYe5S7KxmHk+WYXxsXxjCCBygwggUQoAMCAQIC
# EzMAAAAYDeuRVamKAJgAAAAAABgwDQYJKoZIhvcNAQEMBQAwYzELMAkGA1UEBhMC
# VVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjE0MDIGA1UEAxMrTWlj
# cm9zb2Z0IElEIFZlcmlmaWVkIENvZGUgU2lnbmluZyBQQ0EgMjAyMTAeFw0yNjAz
# MjYxODExMzJaFw0zMTAzMjYxODExMzJaMFoxCzAJBgNVBAYTAlVTMR4wHAYDVQQK
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJRCBW
# ZXJpZmllZCBDUyBBT0MgQ0EgMDMwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIK
# AoICAQDIgNpgNFaiif2VWeWP5I6PnFXxJ/lB37fJR55GCvR7GLZBMkBijbiKVwgp
# BI3xM5nf484znH/qncJ+OCq6y3jgnQW+R8Zd7U+7LjlrmcskalzSQ0ghMxEpnBW8
# /HHs2V8ZJzQk6HP+SDsbvsL7LdlH/eO2l4mknhDBwr0Z/Q966TvEth5b8kCxj1vq
# iV4YNthLGRqZR9u2fK/yBMWu83p6O4uo2Edg++gEew5IL7vnnnKFqmSh/R9vPJy3
# WF1YcZewAUx8sXZNUnx3ZhVg59l2LpitPiwzE6FMqIsqaEvVe3MzuFd2a/uWDZH6
# VbDyUiRK78mIg1DQYA9zDEyyBFcNI+nxVSzglvL6u7PRuNqgcV3sf6ELxw89ysQM
# /Z4R1hRFWXRpyOWKKAKtfBHTk0UnNiPcxmLMMYs8jeUjOidfVPjTIry/UVwnwxdl
# kK85cZfBEMYZ/DBNOwdomP459Y1n8izKkbhsa+p4lw+cQVxATBFx9ggR79HhryT7
# HDmpPLvkJvBZ4wW4CW32UT2SMyDe28nIOU3m+hfHlVeKcLBQcym5VoRDjIcCVI7u
# qgGW2PNME0cfei8zCwCy6HCsssJWFS7eg/YbFhnATJcyWfMrkNuAbMfMN8Npg8cr
# S6jVVowyD0GG5zdgi+uQVcSK/638mA1xEYK3pnIoQgO09uuDBwIDAQABo4IB3DCC
# AdgwDgYDVR0PAQH/BAQDAgGGMBAGCSsGAQQBgjcVAQQDAgEAMB0GA1UdDgQWBBSk
# Qwx/dlqlhec+jSgPDBeiRWlwxjBUBgNVHSAETTBLMEkGBFUdIAAwQTA/BggrBgEF
# BQcCARYzaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9Eb2NzL1JlcG9z
# aXRvcnkuaHRtMBkGCSsGAQQBgjcUAgQMHgoAUwB1AGIAQwBBMBIGA1UdEwEB/wQI
# MAYBAf8CAQAwHwYDVR0jBBgwFoAU2UEpsA8PY2zvadf1zSmepEhqMOYwcAYDVR0f
# BGkwZzBloGOgYYZfaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jcmwv
# TWljcm9zb2Z0JTIwSUQlMjBWZXJpZmllZCUyMENvZGUlMjBTaWduaW5nJTIwUENB
# JTIwMjAyMS5jcmwwfQYIKwYBBQUHAQEEcTBvMG0GCCsGAQUFBzAChmFodHRwOi8v
# d3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01pY3Jvc29mdCUyMElEJTIw
# VmVyaWZpZWQlMjBDb2RlJTIwU2lnbmluZyUyMFBDQSUyMDIwMjEuY3J0MA0GCSqG
# SIb3DQEBDAUAA4ICAQBxxyBW+X6mhdRiSwD9PMMWcGUAnx5/QUwnNvZdFGEX+4DR
# DIr9WCh4C87wHtw+lg1D3uzK10DstPX0LFLBFAC3vWMYX4ImXwoLhoR0xlN8mUdo
# rJ3bgnpCJWuI1531Z1rCwPuUrSkBxfOIGDk3p2ECb3Ho/xHi5PRSR/OUrWuQHwXi
# aXMTuXu3IRLezwVkZpFmNwYRD57R9Nx2F/yM7tzOY0Hh0hGCaYEK38/6FrS0SXad
# XWyDUCfn5XOGACRjUCnHx+JQUG0f4SHD+iblpAI0gl+ZHnVmdXXxHTZeTa0CYCIh
# FxKP2922s0g6zLmeiV13LWUmtt/UF7TrWXpMi2/0UNniaDoH7rnPGRV5xVX8uXy4
# sZii4aswzqPM7Y7+mzcranqZ8EjZk5gjLhQ3A2sZaprlOu8CaRmyfcIiVH7zVfgA
# vm81MWXFziAf7my7QOvnyEFPGddq8MSfPtfRyw/Uq3uH6KpoaJNIfPYH6fceZSi5
# 3Rat1A9grExq3ROjhhSpTcchuBItAMNVPxoKNbUm+iR/X3XkL+9WQginjyHe+hXL
# clY8vAGXFD1p40PqMIpAYsmEJBFKW9df4//1N5oQDr/FY9IBJl/oSS979i5rtT7N
# Zz9KvYraCPRBGs0QCy+sWvgQa0coM70QJVLeVwmSxUO/0od0w9Qry7bSLrxGoDCC
# B54wggWGoAMCAQICEzMAAAAHh6M0o3uljhwAAAAAAAcwDQYJKoZIhvcNAQEMBQAw
# dzELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjFI
# MEYGA1UEAxM/TWljcm9zb2Z0IElkZW50aXR5IFZlcmlmaWNhdGlvbiBSb290IENl
# cnRpZmljYXRlIEF1dGhvcml0eSAyMDIwMB4XDTIxMDQwMTIwMDUyMFoXDTM2MDQw
# MTIwMTUyMFowYzELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjE0MDIGA1UEAxMrTWljcm9zb2Z0IElEIFZlcmlmaWVkIENvZGUgU2ln
# bmluZyBQQ0EgMjAyMTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALLw
# wK8ZiCji3VR6TElsaQhVCbRS/3pK+MHrJSj3Zxd3KU3rlfL3qrZilYKJNqztA9OQ
# acr1AwoNcHbKBLbsQAhBnIB34zxf52bDpIO3NJlfIaTE/xrweLoQ71lzCHkD7A4A
# s1Bs076Iu+mA6cQzsYYH/Cbl1icwQ6C65rU4V9NQhNUwgrx9rGQ//h890Q8JdjLL
# w0nV+ayQ2Fbkd242o9kH82RZsH3HEyqjAB5a8+Ae2nPIPc8sZU6ZE7iRrRZywRmr
# KDp5+TcmJX9MRff241UaOBs4NmHOyke8oU1TYrkxh+YeHgfWo5tTgkoSMoayqoDp
# HOLJs+qG8Tvh8SnifW2Jj3+ii11TS8/FGngEaNAWrbyfNrC69oKpRQXY9bGH6jn9
# NEJv9weFxhTwyvx9OJLXmRGbAUXN1U9nf4lXezky6Uh/cgjkVd6CGUAf0K+Jw+GE
# /5VpIVbcNr9rNE50Sbmy/4RTCEGvOq3GhjITbCa4crCzTTHgYYjHs1NbOc6brH+e
# KpWLtr+bGecy9CrwQyx7S/BfYJ+ozst7+yZtG2wR461uckFu0t+gCwLdN0A6cFtS
# RtR8bvxVFyWwTtgMMFRuBa3vmUOTnfKLsLefRaQcVTgRnzeLzdpt32cdYKp+dhr2
# ogc+qM6K4CBI5/j4VFyC4QFeUP2YAidLtvpXRRo3AgMBAAGjggI1MIICMTAOBgNV
# HQ8BAf8EBAMCAYYwEAYJKwYBBAGCNxUBBAMCAQAwHQYDVR0OBBYEFNlBKbAPD2Ns
# 72nX9c0pnqRIajDmMFQGA1UdIARNMEswSQYEVR0gADBBMD8GCCsGAQUFBwIBFjNo
# dHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5o
# dG0wGQYJKwYBBAGCNxQCBAweCgBTAHUAYgBDAEEwDwYDVR0TAQH/BAUwAwEB/zAf
# BgNVHSMEGDAWgBTIftJqhSobyhmYBAcnz1AQT2ioojCBhAYDVR0fBH0wezB5oHeg
# dYZzaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0
# JTIwSWRlbnRpdHklMjBWZXJpZmljYXRpb24lMjBSb290JTIwQ2VydGlmaWNhdGUl
# MjBBdXRob3JpdHklMjAyMDIwLmNybDCBwwYIKwYBBQUHAQEEgbYwgbMwgYEGCCsG
# AQUFBzAChnVodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01p
# Y3Jvc29mdCUyMElkZW50aXR5JTIwVmVyaWZpY2F0aW9uJTIwUm9vdCUyMENlcnRp
# ZmljYXRlJTIwQXV0aG9yaXR5JTIwMjAyMC5jcnQwLQYIKwYBBQUHMAGGIWh0dHA6
# Ly9vbmVvY3NwLm1pY3Jvc29mdC5jb20vb2NzcDANBgkqhkiG9w0BAQwFAAOCAgEA
# fyUqnv7Uq+rdZgrbVyNMul5skONbhls5fccPlmIbzi+OwVdPQ4H55v7VOInnmezQ
# EeW4LqK0wja+fBznANbXLB0KrdMCbHQpbLvG6UA/Xv2pfpVIE1CRFfNF4XKO8XYE
# a3oW8oVH+KZHgIQRIwAbyFKQ9iyj4aOWeAzwk+f9E5StNp5T8FG7/VEURIVWArbA
# zPt9ThVN3w1fAZkF7+YU9kbq1bCR2YD+MtunSQ1Rft6XG7b4e0ejRA7mB2IoX5hN
# h3UEauY0byxNRG+fT2MCEhQl9g2i2fs6VOG19CNep7SquKaBjhWmirYyANb0RJSL
# WjinMLXNOAga10n8i9jqeprzSMU5ODmrMCJE12xS/NWShg/tuLjAsKP6SzYZ+1Ry
# 358ZTFcx0FS/mx2vSoU8s8HRvy+rnXqyUJ9HBqS0DErVLjQwK8VtsBdekBmdTbQV
# oCgPCqr+PDPB3xajYnzevs7eidBsM71PINK2BoE2UfMwxCCX3mccFgx6UsQeRSdV
# VVNSyALQe6PT12418xon2iDGE81OGCreLzDcMAZnrUAx4XQLUz6ZTl65yPUiOh3k
# 7Yww94lDf+8oG2oZmDh5O1Qe38E+M3vhKwmzIeoB1dVLlz4i3IpaDcR+iuGjH2Td
# aC1ZOmBXiCRKJLj4DT2uhJ04ji+tHD6n58vhavFIrmcxghcxMIIXLQIBATBxMFox
# CzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzAp
# BgNVBAMTIk1pY3Jvc29mdCBJRCBWZXJpZmllZCBDUyBBT0MgQ0EgMDMCEzMABIRz
# IeUGsUe99uIAAAAEhHMwDQYJYIZIAWUDBAIBBQCgXjAQBgorBgEEAYI3AgEMMQIw
# ADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAvBgkqhkiG9w0BCQQxIgQgc/m0
# IvsCz21gAW/V0e5DWzUWQKe0/tHvh/nsTuKQlXYwDQYJKoZIhvcNAQEBBQAEggGA
# jFWu5l+Vxe1WvT9nM+rDLP4vWtpQUqjTYjfpcI/SdwKWqVBJ8Suk+Hjs8oBZ/9Sy
# gbPAkQizbdJAvkQxF5BNgWSREtIuv95XUn0eYVVzxxoroMdwRPkbv3HpgSV7x89Z
# rRPGEKmxL6XelL0ZUpgPDKmfGZeBJD1HNcrmZmH2ADqLnbE6ssiI1eElmsMSzX3/
# I9n/D647Aify470RIik1caTi+3020sWct1yiETpg8BkYLoMWsUFqqQ6bhLC7/Z7S
# lD2MyrwJwlzNSmD/2IIifdEj3Qbjw3nSG7Lmj5cJC9ygAJuliYapIVjmeYrCSAxP
# Q0xGDbvgB4O80/ZaoRuiH0Rfas5byRrd4mGwFFK14d+s6zUSDNIcLFxipYt54sDP
# 8lIwNHuSInbmxkzAlrPBqMYp+o+d0xsdTcoiFs244DeQPCBPupMsv4iT7+u7hjwn
# m155nRDViLEgQJSEe5pB+1mPysqcyO/Lr3xZlF8OxGHGPuGQy+RppNJ3P1s9LBxY
# oYIUsTCCFK0GCisGAQQBgjcDAwExghSdMIIUmQYJKoZIhvcNAQcCoIIUijCCFIYC
# AQMxDzANBglghkgBZQMEAgEFADCCAWkGCyqGSIb3DQEJEAEEoIIBWASCAVQwggFQ
# AgEBBgorBgEEAYRZCgMBMDEwDQYJYIZIAWUDBAIBBQAEIHtUZe4l+2DHK/eyxmaw
# BAgVLUa4FjePKq1LePkOTc6aAgZqdgnSPygYEjIwMjYwODEwMjA0NzUzLjM1WjAE
# gAIB9KCB6aSB5jCB4zELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24x
# EDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlv
# bjEtMCsGA1UECxMkTWljcm9zb2Z0IElyZWxhbmQgT3BlcmF0aW9ucyBMaW1pdGVk
# MScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046N0IxQS0wNUUwLUQ5NDcxNTAzBgNV
# BAMTLE1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWUgU3RhbXBpbmcgQXV0aG9yaXR5
# oIIPKTCCB4IwggVqoAMCAQICEzMAAAAF5c8P/2YuyYcAAAAAAAUwDQYJKoZIhvcN
# AQEMBQAwdzELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjFIMEYGA1UEAxM/TWljcm9zb2Z0IElkZW50aXR5IFZlcmlmaWNhdGlvbiBS
# b290IENlcnRpZmljYXRlIEF1dGhvcml0eSAyMDIwMB4XDTIwMTExOTIwMzIzMVoX
# DTM1MTExOTIwNDIzMVowYTELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29m
# dCBDb3Jwb3JhdGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGlt
# ZXN0YW1waW5nIENBIDIwMjAwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoIC
# AQCefOdSY/3gxZ8FfWO1BiKjHB7X55cz0RMFvWVGR3eRwV1wb3+yq0OXDEqhUhxq
# oNv6iYWKjkMcLhEFxvJAeNcLAyT+XdM5i2CgGPGcb95WJLiw7HzLiBKrxmDj1EQB
# /mG5eEiRBEp7dDGzxKCnTYocDOcRr9KxqHydajmEkzXHOeRGwU+7qt8Md5l4bVZr
# XAhK+WSk5CihNQsWbzT1nRliVDwunuLkX1hyIWXIArCfrKM3+RHh+Sq5RZ8aYyik
# 2r8HxT+l2hmRllBvE2Wok6IEaAJanHr24qoqFM9WLeBUSudz+qL51HwDYyIDPSQ3
# SeHtKog0ZubDk4hELQSxnfVYXdTGncaBnB60QrEuazvcob9n4yR65pUNBCF5qeA4
# QwYnilBkfnmeAjRN3LVuLr0g0FXkqfYdUmj1fFFhH8k8YBozrEaXnsSL3kdTD01X
# +4LfIWOuFzTzuoslBrBILfHNj8RfOxPgjuwNvE6YzauXi4orp4Sm6tF245DaFOSY
# bWFK5ZgG6cUY2/bUq3g3bQAqZt65KcaewEJ3ZyNEobv35Nf6xN6FrA6jF9447+NH
# vCjeWLCQZ3M8lgeCcnnhTFtyQX3XgCoc6IRXvFOcPVrr3D9RPHCMS6Ckg8wggTrt
# IVnY8yjbvGOUsAdZbeXUIQAWMs0d3cRDv09SvwVRd61evQIDAQABo4ICGzCCAhcw
# DgYDVR0PAQH/BAQDAgGGMBAGCSsGAQQBgjcVAQQDAgEAMB0GA1UdDgQWBBRraSg6
# NS9IY0DPe9ivSek+2T3bITBUBgNVHSAETTBLMEkGBFUdIAAwQTA/BggrBgEFBQcC
# ARYzaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9Eb2NzL1JlcG9zaXRv
# cnkuaHRtMBMGA1UdJQQMMAoGCCsGAQUFBwMIMBkGCSsGAQQBgjcUAgQMHgoAUwB1
# AGIAQwBBMA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAUyH7SaoUqG8oZmAQH
# J89QEE9oqKIwgYQGA1UdHwR9MHsweaB3oHWGc2h0dHA6Ly93d3cubWljcm9zb2Z0
# LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMElkZW50aXR5JTIwVmVyaWZpY2F0
# aW9uJTIwUm9vdCUyMENlcnRpZmljYXRlJTIwQXV0aG9yaXR5JTIwMjAyMC5jcmww
# gZQGCCsGAQUFBwEBBIGHMIGEMIGBBggrBgEFBQcwAoZ1aHR0cDovL3d3dy5taWNy
# b3NvZnQuY29tL3BraW9wcy9jZXJ0cy9NaWNyb3NvZnQlMjBJZGVudGl0eSUyMFZl
# cmlmaWNhdGlvbiUyMFJvb3QlMjBDZXJ0aWZpY2F0ZSUyMEF1dGhvcml0eSUyMDIw
# MjAuY3J0MA0GCSqGSIb3DQEBDAUAA4ICAQBfiHbHfm21WhV150x4aPpO4dhEmSUV
# pbixNDmv6TvuIHv1xIs174bNGO/ilWMm+Jx5boAXrJxagRhHQtiFprSjMktTliL4
# sKZyt2i+SXncM23gRezzsoOiBhv14YSd1Klnlkzvgs29XNjT+c8hIfPRe9rvVCMP
# iH7zPZcw5nNjthDQ+zD563I1nUJ6y59TbXWsuyUsqw7wXZoGzZwijWT5oc6GvD3H
# DokJY401uhnj3ubBhbkR83RbfMvmzdp3he2bvIUztSOuFzRqrLfEvsPkVHYnvH1w
# tYyrt5vShiKheGpXa2AWpsod4OJyT4/y0dggWi8g/tgbhmQlZqDUf3UqUQsZaLdI
# u/XSjgoZqDjamzCPJtOLi2hBwL+KsCh0Nbwc21f5xvPSwym0Ukr4o5sCcMUcSy6T
# EP7uMV8RX0eH/4JLEpGyae6Ki8JYg5v4fsNGif1OXHJ2IWG+7zyjTDfkmQ1snFOT
# gyEX8qBpefQbF0fx6URrYiarjmBprwP6ZObwtZXJ23jK3Fg/9uqM3j0P01nzVygT
# ppBabzxPAh/hHhhls6kwo3QLJ6No803jUsZcd4JQxiYHHc+Q/wAMcPUnYKv/q2O4
# 44LO1+n6j01z5mggCSlRwD9faBIySAcA9S8h22hIAcRQqIGEjolCK9F6nK9ZyX4l
# hthsGHumaABdWzCCB58wggWHoAMCAQICEzMAAABZfNpx6Y1e9cAAAAAAAFkwDQYJ
# KoZIhvcNAQEMBQAwYTELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBD
# b3Jwb3JhdGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGltZXN0
# YW1waW5nIENBIDIwMjAwHhcNMjYwMTA4MTg1OTAxWhcNMjcwMTA3MTg1OTAxWjCB
# 4zELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1Jl
# ZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEtMCsGA1UECxMk
# TWljcm9zb2Z0IElyZWxhbmQgT3BlcmF0aW9ucyBMaW1pdGVkMScwJQYDVQQLEx5u
# U2hpZWxkIFRTUyBFU046N0IxQS0wNUUwLUQ5NDcxNTAzBgNVBAMTLE1pY3Jvc29m
# dCBQdWJsaWMgUlNBIFRpbWUgU3RhbXBpbmcgQXV0aG9yaXR5MIICIjANBgkqhkiG
# 9w0BAQEFAAOCAg8AMIICCgKCAgEApi7n/jR4Rf6FP7mMVrXjpuJ3d0Dguddie2+Q
# /cIbDgsYBEWGe8sxIn9W2y5vMNp4WebvJvYpIzvRaYdCmt0JWqm9QfuXS4HiM3Du
# 6sugBH2QocsTRWUyUNK0NLFQEjerCx2uO92a9XST73+eO4MSJKXMlN/sOjB3Urds
# 7ht5HJoWFH5jy3KYQI6qU4B99isbbBl1UznX5BIFJ748TKSvwLo6eepKKm4Xx9m8
# Jvr+G6TRmbpnCxqLFIcgBPYgQa9LtzrcibyNXdrxHQrqLbKLDQ02WdNKnDL9l+/u
# LCwsHCF9uMFOf5c6XqY/MNdBDdX5JE/3FdsYo6wFPHMaJ3tooAfDejgCGX1QZYsf
# 2Q0/dVSiQToliSOV+m5QZnqBDKoN7B/EPhWhgiWim3gdnTFC+pqO4nH5yvwtH8hn
# nqAsubDIzN17n6+2MGiKWvL+BJnBUbCCS+QiCko8FAcaxIHTLezOvtjvARvq/TJl
# qXVdS9aefPeKdNpJawIWss9XBWZfLedxjn93blWk6SG36br3sZY1u+w06EA4dFp+
# 0T2P+GGSgzpGzIl8EueGoxwD/Bxq9/miPk17JFB0Zl4spyWz1ywpLewFTM+J3HHa
# KI0f0I9oOr9sskQ5dqxiiFcydGKe759STzWzxU7sNBIXp9+fmipIehXyV/UDHq76
# R1KFvwECAwEAAaOCAcswggHHMB0GA1UdDgQWBBSPlucLXwPS+WdJGEI6I4MYa5c2
# djAfBgNVHSMEGDAWgBRraSg6NS9IY0DPe9ivSek+2T3bITBsBgNVHR8EZTBjMGGg
# X6BdhltodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3Nv
# ZnQlMjBQdWJsaWMlMjBSU0ElMjBUaW1lc3RhbXBpbmclMjBDQSUyMDIwMjAuY3Js
# MHkGCCsGAQUFBwEBBG0wazBpBggrBgEFBQcwAoZdaHR0cDovL3d3dy5taWNyb3Nv
# ZnQuY29tL3BraW9wcy9jZXJ0cy9NaWNyb3NvZnQlMjBQdWJsaWMlMjBSU0ElMjBU
# aW1lc3RhbXBpbmclMjBDQSUyMDIwMjAuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0l
# AQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeAMGYGA1UdIARfMF0wUQYM
# KwYBBAGCN0yDfQEBMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0
# LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTAIBgZngQwBBAIwDQYJKoZI
# hvcNAQEMBQADggIBAEQyHML9lyOkb/NRETvPZinm+tTFSOwTldre3/ZEa8RLC9ua
# yTdsseFIUBqOCjZdDzGgYM/exSEoIs94gJJuRW/pXyxKnx8nwmizrKtrB/ZhWKzy
# 1xX447tT1LokY9DOmY+dx/NBzid7V+pnj4eIppsgMSgV111BPYSCST1/PEJj8Rnn
# Zq8nbt1J+sj8gObKf1XXQ7eJCmDYX4L281OuTudWCgOgdr35DelivQgcadKa3mKu
# AZPjfrOjladc/wXEyGzAfVqLKJJmJXOGivXQL0LnZw/cLz88SgwpRey0uOg87RMy
# R5b/UWvXzopcPjlBGAGjTEiaC1ZN3NYWeUP6nv6IMEi5Ks1xFcNFi6r9phloOFZI
# jRJh08hZWHle9e5YDfVryhDRI76g9rc2TzSTTzrjCKLInUqxtKdpp5+D2+yl6CGu
# ljyWMLDF8JS3HkdBE2AAk4jwgoAIrh3TXgyTSGVE7SVBVEd6CoiDb0rpeqRzfrRb
# ZkkZRyy2UqiSRWPooAeMbKstE/N6lh+JlQmriBfLFum8pvVcnYU3brzZpSg1ej1H
# JErVyHR/rqTr7KPzyTO+4Lv68la00Oz9SkgzoeGbSRTrglQnswwRBwBzuSl+3sab
# th5Er6gqCpSBhcJ+bNtfyclclmc9rwANZWwiqy40DEIjQJleRQuh+qjkF7rPMYID
# 1DCCA9ACAQEweDBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENv
# cnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3Rh
# bXBpbmcgQ0EgMjAyMAITMwAAAFl82nHpjV71wAAAAAAAWTANBglghkgBZQMEAgEF
# AKCCAS0wGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEi
# BCC1QbjFCKS67ReVM5fSiy7+ZWPKLseNWLkhk+KWFi54ojCB3QYLKoZIhvcNAQkQ
# Ai8xgc0wgcowgccwgaAEIMtFurHbhumxxcQn4eOP3GtxRXDtHw7LIx9IHZgYrf68
# MHwwZaRjMGExCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9y
# YXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWVzdGFtcGlu
# ZyBDQSAyMDIwAhMzAAAAWXzacemNXvXAAAAAAABZMCIEIKWikEUszKtmTq3PJAc9
# JqdssuZn61mlGBpRDAiJpv2lMA0GCSqGSIb3DQEBCwUABIICAEuNWJkS72cM1amI
# HO6IN1fzcyyKCcZ9XFAGM4LO4y8xAeLJ3wtZyree9sZViSzDRb5bVh0lO4pXLEKM
# RpPNcbfo0jSWODDA/j6RhFxLNlxXzAZKcVBu7hHW8fWVZ08cvlGPbsHMkysWuUiD
# A/BLscOJ6YIDF3sB8r4rX6v23WJDsZRnyAXFDLoQ2dbPEWXkuszumF7BGcXRqS3k
# vsINV0BpagMxgKtq3iAUmMlP2P5pmrWia+zxzAseKTyN1GRo/LcwU0EVl+KFcgIJ
# JLFEkFwIE9SfxSviN8az/TYXWpoVAYVp5N+hS+Etu0x96PkOKscvihRqQWEir00h
# CaVrTogLPef6fe2MXlKfWgf34Dvk9DIcGyDf2A1t99AyWsPZz7BsGkAwMAedXz3v
# rJSy3WGuglUfkXzQDkAWmVNM4quh7ytiRstarZurPfEedKlb3J/30+qKqMN/U2fp
# lXRHlntCK+g4/kZJb6NgUkWOujFAJkpFsVnn4jxc28tD3sF2yW7Yq0dWA9Qsf3yD
# fL4yYdXy/BC7DDsSCcINg73hXGpFtmW31uLRrEgEsk0bqcpEU3Hgu2Mtr2qEqy9+
# rrD7J4k6FjJy+QWout6HwfGf6ZGTEb1Xv2UY5vyIYFh0fofM3S2kcpKy5PbT7cPE
# Dq7a+C2ikR0M/lGZB+M5JpiwvuSX
# SIG # End signature block
