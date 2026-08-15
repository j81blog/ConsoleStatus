#Requires -Version 5.1
<#
    .SYNOPSIS
        Console status output: sections, labelled values, live progress and a colored result.

    .DESCRIPTION
        Writes structured status output to the console only. Every write goes to the host through
        Write-Host, which targets the information stream, so the success stream stays clean and
        the output of wrapped code can still be assigned to a variable or piped.

        The layout can be configured up front through the $ConsoleStatusPreference hashtable, so a
        consuming script does not have to pass parameters. Resolution order, lowest first:

            1. Built in defaults
            2. $ConsoleStatusPreference, looked up in the caller scope and then the global scope
            3. Explicit parameters on Set-ConsoleStatusStyle

        The preference variable is read when the module is imported and on every call to
        Set-ConsoleStatusStyle. Set it before importing, or call Set-ConsoleStatusStyle afterwards.

        Every completed item is also recorded as a structured object, retrievable with
        Get-ConsoleStatusLog and summarised by Get-ConsoleStatusSummary. Set LogAction to stream
        those records to an existing logging function.

    .EXAMPLE
        $ConsoleStatusPreference = @{
            Mode      = 'Flow'
            MaxWidth  = 100
            LogAction = { param($Record) Write-Log -Message "$($Record.Label): $($Record.Status)" }
        }
        Import-Module -Name '.\ConsoleStatus\ConsoleStatus.psd1'

    .NOTES
        Function  : ConsoleStatus
        Author    : John Billekens
        Copyright : Copyright (c) John Billekens Consultancy
        Version   : 2026.810.929
#>

# Valid $ConsoleStatusPreference keys.
$script:ConsoleStatusDefaults = @{
    Mode            = 'Column' # Column | Flow
    Indent          = 2
    LabelWidth      = 24
    ValueWidth      = 16       # 0 removes the value column entirely
    StatusWidth     = 8
    Width           = 0        # 0 measures the console, anything else pins the exact line width
    ForceWidth      = $false   # allow a pinned width wider than the console
    MinWidth        = 60
    MaxWidth        = 120
    Unicode         = $false
    NoColor         = $false
    ShowDuration    = $false   # duration is always recorded, this only prints it
    TickChar        = '*'
    FillChar        = '.'
    RuleChar        = '-'
    TitleChar       = '='      # rule above and below a title banner
    MoreChar        = '>'      # bar that ran out of cells, and the marker on a note
    BarContinuation = 'Open'   # Open leaves a continued line bare, Blank ends it with an empty block
    MaxBarLines     = 3        # lines a wrapping bar may use before it freezes, 0 for no limit
    LogAction       = $null    # scriptblock receiving one record per completed item
}

# Bounds for the settings that are plain numbers, next to the defaults they belong to and read by
# Test-ConsoleStatusSetting. Anything not listed here is validated by name instead.
$script:ConsoleStatusRanges = @{
    Indent      = @(0, 20)
    LabelWidth  = @(8, 80)
    ValueWidth  = @(0, 80)
    StatusWidth = @(6, 12)
    Width       = @(0, 250)
    MinWidth    = @(40, 250)
    MaxWidth    = @(60, 250)
    MaxBarLines = @(0, 20)
}

# Active configuration plus per item state.
$script:ConsoleStatus = @{
    LineWidth    = 80
    FieldWidth   = 0
    Ticks        = 0
    Section      = ''
    Detail       = ''
    Note         = ''
    CurrentLabel = ''
    CurrentValue = ''
    TotalSteps   = 0
    DoneSteps    = 0
    FieldStart   = 0
    BarLines     = 1
    Overflowed   = $false
    Stopwatch    = $null
    ItemOpen     = $false   # between Write-ConsoleItem and Write-ConsoleResult

    # Wall clock for the whole run, started at import. Restarted by Reset-ConsoleStatusLog and by
    # Write-ConsoleTitle -StartTimer, so a script can anchor it on its own banner.
    RunStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
}

$script:ConsoleStatusLog = New-Object -TypeName 'System.Collections.Generic.List[PSObject]'
$script:ConsoleStatusTally = @{ OK = 0; WARN = 0; FAIL = 0; SKIP = 0 }
$script:LogActionWarned = $false

# Dot-sourced so they land in module scope and can see the $script: state above. Private first,
# though order does not matter: every file is loaded before anything runs.
foreach ($folder in @('private', 'public')) {
    $path = Join-Path -Path $PSScriptRoot -ChildPath $folder

    foreach ($file in @(Get-ChildItem -Path $path -Filter '*.ps1' -ErrorAction SilentlyContinue)) {
        . $file.FullName
    }
}
# Apply defaults and any pre-import preference.
Set-ConsoleStatusStyle

Export-ModuleMember -Function @(
    'Set-ConsoleStatusStyle',
    'Get-ConsoleStatusStyle',
    'Get-ConsoleStatusState',
    'Write-ConsoleTitle',
    'Write-ConsoleSection',
    'Write-ConsoleItem',
    'Write-ConsoleTick',
    'Set-ConsoleStepDetail',
    'Set-ConsoleStepNote',
    'Write-ConsoleResult',
    'Invoke-ConsoleStep',
    'Get-ConsoleStatusLog',
    'Get-ConsoleStatusSummary',
    'Reset-ConsoleStatusLog',
    'Write-ConsoleSummary'
)

# SIG # Begin signature block
# MII6AgYJKoZIhvcNAQcCoII58zCCOe8CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCD1B/sWEfqI9lLq
# mRCBqJ8zM33buuaHcF7+78P4TCkEK6CCIiYwggXMMIIDtKADAgECAhBUmNLR1FsZ
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
# 03u4aUoqlmZpxJTG9F9urJh4iIAGXKKy7aIwggbAMIIEqKADAgECAhMzAATFa8Wf
# B2BtDnwaAAAABMVrMA0GCSqGSIb3DQEBDAUAMFoxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJ
# RCBWZXJpZmllZCBDUyBBT0MgQ0EgMDQwHhcNMjYwODEzMjAxMTI4WhcNMjYwODE2
# MjAxMTI4WjCBgzELMAkGA1UEBhMCTkwxFjAUBgNVBAgTDU5vb3JkLUJyYWJhbnQx
# EjAQBgNVBAcTCVNjaGlqbmRlbDEjMCEGA1UEChMaSm9obiBCaWxsZWtlbnMgQ29u
# c3VsdGFuY3kxIzAhBgNVBAMTGkpvaG4gQmlsbGVrZW5zIENvbnN1bHRhbmN5MIIB
# ojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEAhb0wHM8uLjbNbqMwpuKlHeDl
# tRJaSnIjEy3So9uOe44DNrkzk0DtUDVV/El9SWLwgRR8IpORy87Uuk9UTisAsDHg
# rNUpvfKg2ExxPswmuv3pDte4/olN77omCeUJAxRbUk3qQaVDNU2MEC8n0FTXqhss
# lTIP8hZ1oVka5cuDgadiOYxgaVOHsyvy0CT5bPtnddwlhnFpejg4duOr3ICflmsP
# e/42wcLObNfW+mXtv74l++3IwbrAENdCW72DxTjZI13FMYZM0a6D99P82ezUC6ap
# AtKJnOx5ydCJ/MqCcXFoLz5fSmVkI+kMBAfX9+fcMEZ4PlmjDrDgsQQMivcUzU4u
# q31jv5+2IFcmpmKeUA+0PTRjm+rvsyS/jF14WCvMHOxkUapOoFtdfbJe98zqokSF
# WPVOaRZFtiRVm6443BJbwQ/bl+oBb0HSxCOdJZ+Lx0ThvTGZ8EWOtUFS8gK9CgD9
# gNSy8mqRH6gHYLv9I3Jdpys74WRMGk1qoQiKn0ARAgMBAAGjggHTMIIBzzAMBgNV
# HRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDA6BgNVHSUEMzAxBgorBgEEAYI3YQEA
# BggrBgEFBQcDAwYZKwYBBAGCN2HK9PELgrHSgxH33KNOluu6MTAdBgNVHQ4EFgQU
# 4htPnn20iy7JO+OaQ32jWyMG/7swHwYDVR0jBBgwFoAUayVB3vtrfP0YgAotf492
# XapzPbgwZwYDVR0fBGAwXjBcoFqgWIZWaHR0cDovL3d3dy5taWNyb3NvZnQuY29t
# L3BraW9wcy9jcmwvTWljcm9zb2Z0JTIwSUQlMjBWZXJpZmllZCUyMENTJTIwQU9D
# JTIwQ0ElMjAwNC5jcmwwdAYIKwYBBQUHAQEEaDBmMGQGCCsGAQUFBzAChlhodHRw
# Oi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01pY3Jvc29mdCUyMElE
# JTIwVmVyaWZpZWQlMjBDUyUyMEFPQyUyMENBJTIwMDQuY3J0MFQGA1UdIARNMEsw
# SQYEVR0gADBBMD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20v
# cGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5odG0wDQYJKoZIhvcNAQEMBQADggIBAHwJ
# I9j3530t4XGq/i2cT4Z1Sp1qY10mYojS7m/Df0JemAlkhkB7BSYb7KfFseYkY/Ty
# A1PCRFIzdQLloPmwyJyixxiv/q/CcDi2h77izh8BBNLVjmABeYllTpxpsI2U0fV2
# zHnggFEaIGZvLkdOVTxcYusCGlIaD+irgZpGPDMzyEXAy91tOYhQeAXDymUXsXlj
# 6ihEF5koTI/oyPxxkgPW3jeZSG6vgIEfu1zrfKrSI/ezqdppPKGJJc8uMUkll/WA
# XqrLJzh/8gb0FkwxGPdjJ7OKVuAbDJ5BCL4rmozcn0k0hV25KTjHeZeBAMTl7i4q
# dLIfRhjpwY6J1KwYVzjoR0cok2T8FfAGQp99XazEiyUI4r+5CWEq9xvczmP0RVRW
# wp3FBd1IQj0wRp83jEMpBUwRN2h9KDEcw4bCnsskRlfxNXvTQ9aglv4BlqB5myNC
# BXXvcVs2H8fQMh0+BnRqn0dADBWNF9YyUlcIBoZuXCI/rdYHHxwWiOQvpWOZORk8
# bj3/uKLilH7zwaKETWDZwuhbTY7rmlRMAowVt59ph3ayOJ6NZLiSKbaTch0J0i2g
# NGe3TC+2MWxX8TG0IBDrMjnQqRtzeeuQr78XjyNrpV6Drbc+pFWZo4Sz/2fc2RfK
# P8NhSvx2LC9I/MGomUE9Y1G3z9ArP7wkwbNeA7eCMIIGwDCCBKigAwIBAgITMwAE
# xWvFnwdgbQ58GgAAAATFazANBgkqhkiG9w0BAQwFADBaMQswCQYDVQQGEwJVUzEe
# MBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSswKQYDVQQDEyJNaWNyb3Nv
# ZnQgSUQgVmVyaWZpZWQgQ1MgQU9DIENBIDA0MB4XDTI2MDgxMzIwMTEyOFoXDTI2
# MDgxNjIwMTEyOFowgYMxCzAJBgNVBAYTAk5MMRYwFAYDVQQIEw1Ob29yZC1CcmFi
# YW50MRIwEAYDVQQHEwlTY2hpam5kZWwxIzAhBgNVBAoTGkpvaG4gQmlsbGVrZW5z
# IENvbnN1bHRhbmN5MSMwIQYDVQQDExpKb2huIEJpbGxla2VucyBDb25zdWx0YW5j
# eTCCAaIwDQYJKoZIhvcNAQEBBQADggGPADCCAYoCggGBAIW9MBzPLi42zW6jMKbi
# pR3g5bUSWkpyIxMt0qPbjnuOAza5M5NA7VA1VfxJfUli8IEUfCKTkcvO1LpPVE4r
# ALAx4KzVKb3yoNhMcT7MJrr96Q7XuP6JTe+6JgnlCQMUW1JN6kGlQzVNjBAvJ9BU
# 16obLJUyD/IWdaFZGuXLg4GnYjmMYGlTh7Mr8tAk+Wz7Z3XcJYZxaXo4OHbjq9yA
# n5ZrD3v+NsHCzmzX1vpl7b++JfvtyMG6wBDXQlu9g8U42SNdxTGGTNGug/fT/Nns
# 1AumqQLSiZzsecnQifzKgnFxaC8+X0plZCPpDAQH1/fn3DBGeD5Zow6w4LEEDIr3
# FM1OLqt9Y7+ftiBXJqZinlAPtD00Y5vq77Mkv4xdeFgrzBzsZFGqTqBbXX2yXvfM
# 6qJEhVj1TmkWRbYkVZuuONwSW8EP25fqAW9B0sQjnSWfi8dE4b0xmfBFjrVBUvIC
# vQoA/YDUsvJqkR+oB2C7/SNyXacrO+FkTBpNaqEIip9AEQIDAQABo4IB0zCCAc8w
# DAYDVR0TAQH/BAIwADAOBgNVHQ8BAf8EBAMCB4AwOgYDVR0lBDMwMQYKKwYBBAGC
# N2EBAAYIKwYBBQUHAwMGGSsGAQQBgjdhyvTxC4Kx0oMR99yjTpbrujEwHQYDVR0O
# BBYEFOIbT559tIsuyTvjmkN9o1sjBv+7MB8GA1UdIwQYMBaAFGslQd77a3z9GIAK
# LX+Pdl2qcz24MGcGA1UdHwRgMF4wXKBaoFiGVmh0dHA6Ly93d3cubWljcm9zb2Z0
# LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMElEJTIwVmVyaWZpZWQlMjBDUyUy
# MEFPQyUyMENBJTIwMDQuY3JsMHQGCCsGAQUFBwEBBGgwZjBkBggrBgEFBQcwAoZY
# aHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jZXJ0cy9NaWNyb3NvZnQl
# MjBJRCUyMFZlcmlmaWVkJTIwQ1MlMjBBT0MlMjBDQSUyMDA0LmNydDBUBgNVHSAE
# TTBLMEkGBFUdIAAwQTA/BggrBgEFBQcCARYzaHR0cDovL3d3dy5taWNyb3NvZnQu
# Y29tL3BraW9wcy9Eb2NzL1JlcG9zaXRvcnkuaHRtMA0GCSqGSIb3DQEBDAUAA4IC
# AQB8CSPY9+d9LeFxqv4tnE+GdUqdamNdJmKI0u5vw39CXpgJZIZAewUmG+ynxbHm
# JGP08gNTwkRSM3UC5aD5sMicoscYr/6vwnA4toe+4s4fAQTS1Y5gAXmJZU6cabCN
# lNH1dsx54IBRGiBmby5HTlU8XGLrAhpSGg/oq4GaRjwzM8hFwMvdbTmIUHgFw8pl
# F7F5Y+ooRBeZKEyP6Mj8cZID1t43mUhur4CBH7tc63yq0iP3s6naaTyhiSXPLjFJ
# JZf1gF6qyyc4f/IG9BZMMRj3YyezilbgGwyeQQi+K5qM3J9JNIVduSk4x3mXgQDE
# 5e4uKnSyH0YY6cGOidSsGFc46EdHKJNk/BXwBkKffV2sxIslCOK/uQlhKvcb3M5j
# 9EVUVsKdxQXdSEI9MEafN4xDKQVMETdofSgxHMOGwp7LJEZX8TV700PWoJb+AZag
# eZsjQgV173FbNh/H0DIdPgZ0ap9HQAwVjRfWMlJXCAaGblwiP63WBx8cFojkL6Vj
# mTkZPG49/7ii4pR+88GihE1g2cLoW02O65pUTAKMFbefaYd2sjiejWS4kim2k3Id
# CdItoDRnt0wvtjFsV/ExtCAQ6zI50Kkbc3nrkK+/F48ja6Veg623PqRVmaOEs/9n
# 3NkXyj/DYUr8diwvSPzBqJlBPWNRt8/QKz+8JMGzXgO3gjCCBygwggUQoAMCAQIC
# EzMAAAAWMZKNkgJle5oAAAAAABYwDQYJKoZIhvcNAQEMBQAwYzELMAkGA1UEBhMC
# VVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjE0MDIGA1UEAxMrTWlj
# cm9zb2Z0IElEIFZlcmlmaWVkIENvZGUgU2lnbmluZyBQQ0EgMjAyMTAeFw0yNjAz
# MjYxODExMjlaFw0zMTAzMjYxODExMjlaMFoxCzAJBgNVBAYTAlVTMR4wHAYDVQQK
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJRCBW
# ZXJpZmllZCBDUyBBT0MgQ0EgMDQwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIK
# AoICAQDKVfrI2+gJMM/0bQ5OVKNdvOASzLbUUMvXuf+Vl7YGuofPaZHVo3gMHF5i
# nT+GMSpIcfIZ9qtXU1UG68ry8vNbQtOL4Nm30ifXpqI1+ByiAWLO1YT0WnzG7XPO
# uoTeeWsNZv5FmjxCsReBZvyzyzCyXZbu1EQfJxWTH4ebUwtAiW9rqMf9eDj/wYhi
# EfNteJV3ZFeibD2ztCHr9JhFdd97XbnCHgQoTIqc02X5xlRKtUGBa++OtHBBjiJ/
# uwBnzTkqu4FjpZjQeJtrmda+ur1CT2jflWIB/ypn7u7V9tvW9wJbJYt/H2EtJ0GO
# NWxJZ7TEu8jWPindOO3lzPP7UtzS/mVDV94HucWaltmsra6zSG8BoEJ87IM8QSb7
# vfm/O41FhYkUv89WIj5ES2O4kxyiMSfe95CMivCuYrRP2hKvx7egPMrWgDDBkxML
# grKZO9hRNUMm8vk3w5b9SogHOyJVhxyFm8aFXfIxgqDF4S0g4bhbhnzljmSlCLlu
# mMZcXFGDjpF2tNoAu3VGFGYtHtTSNVKvZpgB3b4ynaoDkbPf+Wg4523jt4VneasB
# gZhC1srZI2NCnCBBfgjLq04pqEKAWEohyW2K29KSkkHvt5VaE1ac3Yt+oyiOzMS5
# 7tXwQDJLGvLg/OXFO0VNvczDndfIfXYExB/ab2PuMSwd5VIBOwIDAQABo4IB3DCC
# AdgwDgYDVR0PAQH/BAQDAgGGMBAGCSsGAQQBgjcVAQQDAgEAMB0GA1UdDgQWBBRr
# JUHe+2t8/RiACi1/j3ZdqnM9uDBUBgNVHSAETTBLMEkGBFUdIAAwQTA/BggrBgEF
# BQcCARYzaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9Eb2NzL1JlcG9z
# aXRvcnkuaHRtMBkGCSsGAQQBgjcUAgQMHgoAUwB1AGIAQwBBMBIGA1UdEwEB/wQI
# MAYBAf8CAQAwHwYDVR0jBBgwFoAU2UEpsA8PY2zvadf1zSmepEhqMOYwcAYDVR0f
# BGkwZzBloGOgYYZfaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jcmwv
# TWljcm9zb2Z0JTIwSUQlMjBWZXJpZmllZCUyMENvZGUlMjBTaWduaW5nJTIwUENB
# JTIwMjAyMS5jcmwwfQYIKwYBBQUHAQEEcTBvMG0GCCsGAQUFBzAChmFodHRwOi8v
# d3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01pY3Jvc29mdCUyMElEJTIw
# VmVyaWZpZWQlMjBDb2RlJTIwU2lnbmluZyUyMFBDQSUyMDIwMjEuY3J0MA0GCSqG
# SIb3DQEBDAUAA4ICAQAG1VBeVHTVRBljlcZD3IiMxwPyMjQyLNaEnVu5mODm2hRB
# JfH8GsBLATmrHAc8F47jmk5CnpUPiIguCbw6Z/KVj4Dsoiq228NSLMLewFfGMri7
# uwNGLISC5ccp8vUdADDEIsS2dE+QI9OwkDpv3XuUD7d+hAgcLVcMOl1AsfEZtsZe
# nhGvSYUrm/FuLq0BqEGL9GXM5c+Ho9q8o+Vn/S+GWQN2y+gkRO15s0kI05nUpq/d
# OD4ri9rgVs6tipEd0YZqGgD+CZNiaZWrDTOQbNPncd2F9qOsUa20miYruoT5PwJA
# aI+QQiTE2ZJeMJOkOpzhTUgqVMZwZidEUZKCqudaeQA08WwnkQMfKyHzaU8j48UL
# cU4hUwvMsv7fSurOe9GAdRQCPvF8WcSK5oDHe8VVJM4tv6KKCm91HqLx9JamBgRI
# 6R2SfY3nu26EGznu0rCg/769z8xWm4PVcC2ZaL6VlKVqFp1NsN8YqMyf5t+bbGVb
# 09noFKcJG/UwyGlxRmQBlfeBUQx5/ytlzZzsEnhrJF9fTAfje8j3OdX5lEnePTFQ
# LRlvzZFBqUXnIeQKv3fHQjC9m2fo/Z01DII/qp3d8LhGVUW0BCG04fRwHJNH8iqq
# CG/qofMv+kym2AxBDnHzNgRjL60JOFiBgiurvLhYQNhB95KWojFA6shQnggkMTCC
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
# aC1ZOmBXiCRKJLj4DT2uhJ04ji+tHD6n58vhavFIrmcxghcyMIIXLgIBATBxMFox
# CzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzAp
# BgNVBAMTIk1pY3Jvc29mdCBJRCBWZXJpZmllZCBDUyBBT0MgQ0EgMDQCEzMABMVr
# xZ8HYG0OfBoAAAAExWswDQYJYIZIAWUDBAIBBQCgXjAQBgorBgEEAYI3AgEMMQIw
# ADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAvBgkqhkiG9w0BCQQxIgQgej+x
# G9/i0bwAX7xjJAaynMTNOmOKcXjD8QMI/mZcGoQwDQYJKoZIhvcNAQEBBQAEggGA
# WpC7EYLCtBjEFjHH8XMNXs2zZAjCak5x5f+8HqqSjnZrh8+937Jn0xh4aB3MX1x5
# es9sEB8KKPkV9sjKSwdLfaRlvG1CnYGu3yC/pv9/0eD09HFFhQktRnJkrz7kb4+Y
# WtZNwFGoZ4UbZgFDSpEtXtiOkYKrD2hlU67QZVj6peMLEC+/MRGBvr1NDN41Vb0i
# HP6qJzMeFDA6E9JqlWBthRtPLhs4xumbO9OFlTywwo88ZP3qmAfR11LhtLwFlnqc
# Gi2ogXvuHL9pelxYXm6GAJNm2hDbjb55ZZHzHDzN/BwTArAL+loSHfWOKjdvp0NC
# 4dYfFVyjYMxIuLmqqEZ2kgGLwSh4FK2zxZZCCtHPia66k+SIzMaHaMlIFvyeFpGA
# BYggau0fG22bRDSTs06dBiWZlEp/FUqHamI061Y7uey7jW8IqvUSSvNbrAR3FDS/
# j2NpgSdMuNZQxWOYPoA2MNL4R6DNqlHSBErPX4dzOk6ECbg/Ws7sOmaj8AFLGuWW
# oYIUsjCCFK4GCisGAQQBgjcDAwExghSeMIIUmgYJKoZIhvcNAQcCoIIUizCCFIcC
# AQMxDzANBglghkgBZQMEAgEFADCCAWoGCyqGSIb3DQEJEAEEoIIBWQSCAVUwggFR
# AgEBBgorBgEEAYRZCgMBMDEwDQYJYIZIAWUDBAIBBQAEICQgvem0Kkk9TnUBD+Fs
# BzpVnNQwLkF+6g7plA78HMMiAgZqddIw8toYEzIwMjYwODE1MTExNTEwLjM2NFow
# BIACAfSggemkgeYwgeMxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9u
# MRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRp
# b24xLTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlvbnMgTGltaXRl
# ZDEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjdBMUEtMDVFMC1EOTQ3MTUwMwYD
# VQQDEyxNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lIFN0YW1waW5nIEF1dGhvcml0
# eaCCDykwggeCMIIFaqADAgECAhMzAAAABeXPD/9mLsmHAAAAAAAFMA0GCSqGSIb3
# DQEBDAUAMHcxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9y
# YXRpb24xSDBGBgNVBAMTP01pY3Jvc29mdCBJZGVudGl0eSBWZXJpZmljYXRpb24g
# Um9vdCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkgMjAyMDAeFw0yMDExMTkyMDMyMzFa
# Fw0zNTExMTkyMDQyMzFaMGExCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBQdWJsaWMgUlNBIFRp
# bWVzdGFtcGluZyBDQSAyMDIwMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKC
# AgEAnnznUmP94MWfBX1jtQYioxwe1+eXM9ETBb1lRkd3kcFdcG9/sqtDlwxKoVIc
# aqDb+omFio5DHC4RBcbyQHjXCwMk/l3TOYtgoBjxnG/eViS4sOx8y4gSq8Zg49RE
# Af5huXhIkQRKe3Qxs8Sgp02KHAznEa/Ssah8nWo5hJM1xznkRsFPu6rfDHeZeG1W
# a1wISvlkpOQooTULFm809Z0ZYlQ8Lp7i5F9YciFlyAKwn6yjN/kR4fkquUWfGmMo
# pNq/B8U/pdoZkZZQbxNlqJOiBGgCWpx69uKqKhTPVi3gVErnc/qi+dR8A2MiAz0k
# N0nh7SqINGbmw5OIRC0EsZ31WF3Uxp3GgZwetEKxLms73KG/Z+MkeuaVDQQheang
# OEMGJ4pQZH55ngI0Tdy1bi69INBV5Kn2HVJo9XxRYR/JPGAaM6xGl57Ei95HUw9N
# V/uC3yFjrhc087qLJQawSC3xzY/EXzsT4I7sDbxOmM2rl4uKK6eEpurRduOQ2hTk
# mG1hSuWYBunFGNv21Kt4N20AKmbeuSnGnsBCd2cjRKG79+TX+sTehawOoxfeOO/j
# R7wo3liwkGdzPJYHgnJ54UxbckF914AqHOiEV7xTnD1a69w/UTxwjEugpIPMIIE6
# 7SFZ2PMo27xjlLAHWW3l1CEAFjLNHd3EQ79PUr8FUXetXr0CAwEAAaOCAhswggIX
# MA4GA1UdDwEB/wQEAwIBhjAQBgkrBgEEAYI3FQEEAwIBADAdBgNVHQ4EFgQUa2ko
# OjUvSGNAz3vYr0npPtk92yEwVAYDVR0gBE0wSzBJBgRVHSAAMEEwPwYIKwYBBQUH
# AgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0
# b3J5Lmh0bTATBgNVHSUEDDAKBggrBgEFBQcDCDAZBgkrBgEEAYI3FAIEDB4KAFMA
# dQBiAEMAQTAPBgNVHRMBAf8EBTADAQH/MB8GA1UdIwQYMBaAFMh+0mqFKhvKGZgE
# ByfPUBBPaKiiMIGEBgNVHR8EfTB7MHmgd6B1hnNodHRwOi8vd3d3Lm1pY3Jvc29m
# dC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBJZGVudGl0eSUyMFZlcmlmaWNh
# dGlvbiUyMFJvb3QlMjBDZXJ0aWZpY2F0ZSUyMEF1dGhvcml0eSUyMDIwMjAuY3Js
# MIGUBggrBgEFBQcBAQSBhzCBhDCBgQYIKwYBBQUHMAKGdWh0dHA6Ly93d3cubWlj
# cm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwSWRlbnRpdHklMjBW
# ZXJpZmljYXRpb24lMjBSb290JTIwQ2VydGlmaWNhdGUlMjBBdXRob3JpdHklMjAy
# MDIwLmNydDANBgkqhkiG9w0BAQwFAAOCAgEAX4h2x35ttVoVdedMeGj6TuHYRJkl
# FaW4sTQ5r+k77iB79cSLNe+GzRjv4pVjJviceW6AF6ycWoEYR0LYhaa0ozJLU5Yi
# +LCmcrdovkl53DNt4EXs87KDogYb9eGEndSpZ5ZM74LNvVzY0/nPISHz0Xva71Qj
# D4h+8z2XMOZzY7YQ0Psw+etyNZ1CesufU211rLslLKsO8F2aBs2cIo1k+aHOhrw9
# xw6JCWONNboZ497mwYW5EfN0W3zL5s3ad4Xtm7yFM7Ujrhc0aqy3xL7D5FR2J7x9
# cLWMq7eb0oYioXhqV2tgFqbKHeDick+P8tHYIFovIP7YG4ZkJWag1H91KlELGWi3
# SLv10o4KGag42pswjybTi4toQcC/irAodDW8HNtX+cbz0sMptFJK+KObAnDFHEsu
# kxD+7jFfEV9Hh/+CSxKRsmnuiovCWIOb+H7DRon9TlxydiFhvu88o0w35JkNbJxT
# k4MhF/KgaXn0GxdH8elEa2Imq45gaa8D+mTm8LWVydt4ytxYP/bqjN49D9NZ81co
# E6aQWm88TwIf4R4YZbOpMKN0CyejaPNN41LGXHeCUMYmBx3PkP8ADHD1J2Cr/6tj
# uOOCztfp+o9Nc+ZoIAkpUcA/X2gSMkgHAPUvIdtoSAHEUKiBhI6JQivRepyvWcl+
# JYbYbBh7pmgAXVswggefMIIFh6ADAgECAhMzAAAAW0q1jUEybdx0AAAAAABbMA0G
# CSqGSIb3DQEBDAUAMGExCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQg
# Q29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWVz
# dGFtcGluZyBDQSAyMDIwMB4XDTI2MDEwODE4NTkwNVoXDTI3MDEwNzE4NTkwNVow
# geMxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdS
# ZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xLTArBgNVBAsT
# JE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlvbnMgTGltaXRlZDEnMCUGA1UECxMe
# blNoaWVsZCBUU1MgRVNOOjdBMUEtMDVFMC1EOTQ3MTUwMwYDVQQDEyxNaWNyb3Nv
# ZnQgUHVibGljIFJTQSBUaW1lIFN0YW1waW5nIEF1dGhvcml0eTCCAiIwDQYJKoZI
# hvcNAQEBBQADggIPADCCAgoCggIBAJBUzBbbnlDXee0B0KD5G4/475thFyfctCyu
# ESTWQXvlLi4Wx/td2qUdeq4ideeg6VWhiOHfu3wJV4TUGSRtqh9Ccr1BmiBKv9iu
# FpgHyIBu5Qx38ZsxwlFeXVS+ZqJJKnXRbDNQdcYSoC/6c0hQJ/PH50DBRDQkPXVw
# yFizLrRH9AlrJeUg7BKeT23zftS8/KOJLvEEbHOF6pSOY3ZVprZUWbWjWwRTmoHa
# Q/E8vrWtLNyEJ+b089VW1Ikra3t4GTB5Wby3CL1K2zYnAxBIvafsKMFyj9OuXHcT
# PKMDoFSMeamG9MKOMb6uoG1PjdnDgsLP6EOMRSzrLL7jED1mbB9RSd9fhty+HQr6
# vZgsBn6oUy+YTpNVLskwdtUM82WYAkPztlOt3AiL0qyV7/U3j/uq3vHMjPM0w034
# 0M57Nei0g4BCcMt0dbqoc91VgCb3/36sHQANontn1HOF2oLk8190QRS43isHVra8
# H8sf5+GlqIYsYiCKX04HZiOzZW826nVI6d++8lyTeWmpj90Ua9uPbJhVjwE3oh6t
# O510ySqmSMSLEN07p3Ibe3E6BAb2w93rWzb26+dpSthbKF4kApofqBsWPX4MEtHK
# SOftPmVTCQ47tghrVuHia9jY+Hsj01m4KW4WtkmVm3L6hMZECMa4sjMxAXz+bX/A
# JhWTe6TZAgMBAAGjggHLMIIBxzAdBgNVHQ4EFgQU7/LqUlWWYhXJdXwgYKx4b8Gv
# 0rYwHwYDVR0jBBgwFoAUa2koOjUvSGNAz3vYr0npPtk92yEwbAYDVR0fBGUwYzBh
# oF+gXYZbaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9z
# b2Z0JTIwUHVibGljJTIwUlNBJTIwVGltZXN0YW1waW5nJTIwQ0ElMjAyMDIwLmNy
# bDB5BggrBgEFBQcBAQRtMGswaQYIKwYBBQUHMAKGXWh0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwUHVibGljJTIwUlNBJTIw
# VGltZXN0YW1waW5nJTIwQ0ElMjAyMDIwLmNydDAMBgNVHRMBAf8EAjAAMBYGA1Ud
# JQEB/wQMMAoGCCsGAQUFBwMIMA4GA1UdDwEB/wQEAwIHgDBmBgNVHSAEXzBdMFEG
# DCsGAQQBgjdMg30BATBBMD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jvc29m
# dC5jb20vcGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5odG0wCAYGZ4EMAQQCMA0GCSqG
# SIb3DQEBDAUAA4ICAQAAH+zd+XKh4OxXYMWFmtgilXAQGctOjCUB1w/uBiC/OXcH
# 3Ia4/XbdUhKzFbaiTbIE6vYZKd1p4u7nKOLkawymAMVyuO7LSl6rLKttZIyLhWjT
# K0zXOz0u4xLq9+bRtBEKJvA6sD5nJwH1IO6z1YizyuIRoalMCnbrUixfWxQn4TAm
# N7t9uk+X2FUThEa3ewzRwhtG+xwaAbLMkxRmR24JnfXd1VxKo90+m7Wzuov96Uug
# x5wZdewiIIm1ZWTj4lCJHup679LcOa7tAxJMipVaSltQH9fm9TOKczlfxtWuBcLU
# 4duZfqwgsILsH7PMkcX1zwQzQD0yAtPhnYz9KNG125bX+iilOe1S8RHqv2bbBpMp
# ao4kcUvQI6dMgKRvFmm1eLbhSNOQplDMTGD1tNVdNGkI96jUu+troUjWMMi46TQf
# BAHxtDTpRhIu/87vAVQ8Z6RHhFxesz4Ed5JThaIQRAy6GcO/Jk+QzDzoZ0arRIkI
# sGJ7rZgOVAjx9ctfw8lH9RfjcwB3wdGBYNMNVJqQpUai2Taddf5pXzTZEHIqLEF5
# 3SrBjIeInoQrP7U5VlXiMQsxewLdINrAE2l2TR3KBikb+RQRygbTp8jj2yiC0NCU
# wG+K+ndglN5RMbXjFW6aKa59Xq+b8XzK/DK+AJtgOpHgJv8Qrk62A+twOVLOpjGC
# A9QwggPQAgEBMHgwYTELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBD
# b3Jwb3JhdGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGltZXN0
# YW1waW5nIENBIDIwMjACEzMAAABbSrWNQTJt3HQAAAAAAFswDQYJYIZIAWUDBAIB
# BQCgggEtMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0BCRABBDAvBgkqhkiG9w0BCQQx
# IgQgCJ7OxJ1iV7Tr9QEnaM3dSxtMf6SG4uLudas3BoB+fDgwgd0GCyqGSIb3DQEJ
# EAIvMYHNMIHKMIHHMIGgBCAvMQNVXZ0b0xxlGw8X/3IEybObuT6a5W1d61CW+cGD
# 7zB8MGWkYzBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3RhbXBp
# bmcgQ0EgMjAyMAITMwAAAFtKtY1BMm3cdAAAAAAAWzAiBCB+Y9xAwaoinwH5ajUB
# TD3/obnvfxa3c579e9gxeXlcGzANBgkqhkiG9w0BAQsFAASCAgBgUFQwrHPzR2+t
# ozL4ZVPJBEkbkb8L13HD+DPHSWhDCjf/fAU+TpirIsrJkPLUMFriCpyS7p6XCNmq
# CYpNqWkgAOG7WiZlNHkZ4FHTtVoFS0ElVUEKm5WIK10pBtWrLVK/lcQ1quavjlKK
# gmVujjGiih7LsT8PDmiQROkcT0cZUz6E/ZQUt4y1kh7062BOU9y19CYVzxLLKK41
# Z58M/I1SH7wTcHFsNGMKTkhLOx58nYJstaLrn4Z88yD0R/qDVu33EpqDNrVRv6ML
# +V1q3qWelPzQSlLMl1gVDV+VByIgrsibUdpr4PcuouIXzzsJOGJQxNhGMabjkw44
# 8H248QfFVNIrLES8UYFcVq9b5NYT134Lb2gmK1ccy3tAqz6sIIkMQlpO5xTjraUM
# 6DPv2vfWgb4qYS+H+ZqCAjwZM4hRSX7Qdvn114Ck3HfZwbXc9K0STk9/oboa1Nup
# zy3zWwN1E90+I8iQaG9T3wg/luoRkGTHbB6++4+/UkUuejuGaw8LTNJJ20zqguDF
# SlRcG//nnF2InEoie9Ge/F5cGlRw3JLxQTjs63AxPeTU3Rxh4u1XdA/tReLeB4I5
# +NzUDpf1OiHaAY7gruy62g1FxOpsjfjrgOLCyBVOR97PonLn6P5oriR/ri49xmLA
# JMHTrqBf+O6uJMtfk1CEwL/B2JJjKA==
# SIG # End signature block
