function Write-ConsoleResult {
    <#
        .SYNOPSIS
            Closes an item line with a colored status block, and records the item.

        .DESCRIPTION
            Fills the unused part of the progress field with the fill character, so a failed item
            still shows how far it got, writes the detail right aligned in front of the status, and
            writes the status right aligned at the line width.

            Unless NoRecord is used, the item is counted in the summary, appended to the log and
            passed to LogAction.

        .PARAMETER Status
            The outcome: OK, FAIL, WARN or SKIP. Drives the color, the tally and the record.

        .PARAMETER ErrorRecord
            The exception behind a FAIL. Its message fills the detail when none was given, and is
            stored on the record as Error and repeated in the summary.

        .PARAMETER Detail
            Overrides anything set with Set-ConsoleStepDetail. On FAIL without a detail, the
            exception message from ErrorRecord is used instead.

            A detail is never truncated. If it does not fit next to the status it becomes a note,
            wrapped to the line width.

        .PARAMETER Note
            Text always written on its own line underneath, whether or not it would have fitted.
            Overrides anything set with Set-ConsoleStepNote.

        .PARAMETER ShowDuration
            Print the elapsed time for this item, whatever the ShowDuration setting says. Use
            -ShowDuration:$false to suppress it when the setting has it on globally. The duration
            travels with the detail: if the detail ends up in a note, so does the duration. A
            duration on its own never creates a note.

        .PARAMETER NoRecord
            Render the line but do not count or log it. Used by Write-ConsoleSummary so the summary
            does not appear in its own totals.

        .EXAMPLE
            Write-ConsoleResult -Status OK

        .EXAMPLE
            Write-ConsoleResult -Status OK -Detail '340 found'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('OK', 'FAIL', 'WARN', 'SKIP')]
        [string]$Status,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Detail,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Note,

        [Parameter(Mandatory = $false)]
        [switch]$ShowDuration,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [System.Management.Automation.ErrorRecord]$ErrorRecord,

        [Parameter(Mandatory = $false)]
        [switch]$NoRecord
    )

    $cfg = $script:ConsoleStatus
    $colors = @{
        OK   = 'Green'
        FAIL = 'Red'
        WARN = 'Yellow'
        SKIP = 'DarkGray'
    }

    $milliseconds = 0

    if ($null -ne $cfg.Stopwatch) {
        $cfg.Stopwatch.Stop()
        $milliseconds = [int]$cfg.Stopwatch.ElapsedMilliseconds
        $cfg.Stopwatch = $null
    }

    # Detail precedence: parameter, step, exception message.
    $detailText = ''

    if ($PSBoundParameters.ContainsKey('Detail')) {
        $detailText = Format-SingleLine -Text $Detail
    } elseif (-not [string]::IsNullOrEmpty($cfg.Detail)) {
        $detailText = $cfg.Detail
    } elseif ($Status -eq 'FAIL' -and $null -ne $ErrorRecord) {
        $detailText = Format-SingleLine -Text $ErrorRecord.Exception.Message
    }
    $noteText = ''

    if ($PSBoundParameters.ContainsKey('Note')) {
        $noteText = Format-SingleLine -Text $Note
    } elseif (-not [string]::IsNullOrEmpty($cfg.Note)) {
        $noteText = $cfg.Note
    }

    # Switch overrides the setting. Summary lines never show their own duration.
    $withDuration = $cfg.ShowDuration

    if ($PSBoundParameters.ContainsKey('ShowDuration')) {
        $withDuration = [bool]$ShowDuration
    }

    $text = $detailText

    if ($withDuration -and -not $NoRecord) {
        $duration = Format-Duration -Milliseconds $milliseconds
        $text = if ([string]::IsNullOrEmpty($text)) { $duration } else { "$text $duration" }
    }
    $room = $cfg.FieldWidth - $cfg.Ticks - 2   # one fill character in front, one space behind
    $inline = ''
    $notes = New-Object -TypeName 'System.Collections.Generic.List[string]'

    if ($room -ge 4 -and -not [string]::IsNullOrEmpty($text) -and $text.Length -le $room) {
        $inline = $text
    } elseif ($room -ge 4 -and -not [string]::IsNullOrEmpty($detailText) -and $detailText.Length -le $room) {
        # Detail fits, duration does not: drop the duration.
        $inline = $detailText
    } elseif (-not [string]::IsNullOrEmpty($detailText)) {
        # Neither fits: the detail becomes a note and takes the duration with it.
        $notes.Add($text)
    }

    if (-not [string]::IsNullOrEmpty($noteText)) {
        $notes.Add($noteText)
    }

    $fill = $cfg.FieldWidth - $cfg.Ticks

    if (-not [string]::IsNullOrEmpty($inline)) {
        Write-HostText -Text ([string]$cfg.FillChar * ($fill - $inline.Length - 1)) -NoNewline -Color 'DarkGray'
        Write-HostText -Text " $inline" -NoNewline -Color 'Gray'
    } elseif ($fill -gt 0) {
        Write-HostText -Text ([string]$cfg.FillChar * $fill) -NoNewline -Color 'DarkGray'
    }

    # Gap between the field and the status block.
    Write-HostText -Text ' ' -NoNewline

    $inner = $cfg.StatusWidth - 2
    $left = [int][Math]::Floor(($inner - $Status.Length) / 2)
    $block = $Status.PadLeft($Status.Length + $left).PadRight($inner)

    Write-HostText -Text '[' -NoNewline -Color 'DarkGray'
    Write-HostText -Text $block -NoNewline -Color $colors[$Status]
    Write-HostText -Text ']' -Color 'DarkGray'
    foreach ($entry in $notes) {
        Write-ConsoleNoteBlock -Text $entry
    }

    $cfg.Detail = ''
    $cfg.Note = ''

    if ($NoRecord) {
        return
    }

    $script:ConsoleStatusTally[$Status]++

    $record = [PSCustomObject]@{
        Timestamp  = (Get-Date).ToString('o')
        Section    = $cfg.Section
        Label      = $cfg.CurrentLabel
        Value      = $cfg.CurrentValue
        Detail     = $detailText
        Note       = $noteText
        Status     = $Status
        DurationMs = $milliseconds
        Error      = if ($null -ne $ErrorRecord) { Format-SingleLine -Text $ErrorRecord.Exception.Message } else { '' }
    }

    $script:ConsoleStatusLog.Add($record)

    if ($null -ne $cfg.LogAction) {
        try {
            $null = & $cfg.LogAction $record
        } catch {
            if (-not $script:LogActionWarned) {
                $script:LogActionWarned = $true
                Write-Warning -Message "LogAction threw an exception and will be reported only once: $($_.Exception.Message)"
            }
        }
    }
}

# SIG # Begin signature block
# MII6AQYJKoZIhvcNAQcCoII58jCCOe4CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCD+9BPUgoUzJzK/
# 8GUPmmy2fTX059+DoY+67B3COhoo0KCCIiYwggXMMIIDtKADAgECAhBUmNLR1FsZ
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
# ADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAvBgkqhkiG9w0BCQQxIgQg1ybi
# wl/gRSxdBaA8NZ+ZdfMdHQZOePQ/zYiMOkMnKzkwDQYJKoZIhvcNAQEBBQAEggGA
# R5dooFWUtqOncKLfvIf10CO9hwSCPGTJbe+GoiOASTJCmJMPDmrtutYhkrgdluh9
# h188YSQAbALarWiqd1WtqqQbe/ujAnpEVumlyjOijSQPvQ7izO+qqzoufOyTe3Ap
# OFLRbLFyHY54e6Q6Ymt6YJ0cCmM9WrkQ64PD7bnOT/nhzte6JB1mk9d3j4woShm5
# bstTQ74xCXoHluamfFvI808sxMP9QLj79uRMdwby0E6hbOhnwRlOET+uLyZRK14s
# lQNTywrRtQXTNXmyJqS68nRWqVitsz0HUtqDEh1Qryz9MrRN26ZIpHdC21z2yl54
# AENIZayF0WRhMTPT8BfeDsdUobDbrX2ySM+n5+XuwNU4rGfX0pzNajT3cP30Dkk7
# PZUnX6jiarnXRFcYRyCnYCLyLKBkG9g0FNKz6AH1pXuYtQ1IeF75SkXXTuG+JgST
# aas1wKVwhdsmFQaGzNQfCPK0WYSyzqpZZpKTUREv5wJa9I7Uhnzzg9Om0qjhHsCH
# oYIUsTCCFK0GCisGAQQBgjcDAwExghSdMIIUmQYJKoZIhvcNAQcCoIIUijCCFIYC
# AQMxDzANBglghkgBZQMEAgEFADCCAWkGCyqGSIb3DQEJEAEEoIIBWASCAVQwggFQ
# AgEBBgorBgEEAYRZCgMBMDEwDQYJYIZIAWUDBAIBBQAEIHn/enDKcARDWpZmENnl
# IteczJ+LFlQMxJI3wlw6rxLuAgZqdgnSP0sYEjIwMjYwODEwMjA0ODAxLjI4WjAE
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
# BCA1/HqdlY4V0UsOpAfWLBx8890zQ8q4RKyI9at3A9U2ozCB3QYLKoZIhvcNAQkQ
# Ai8xgc0wgcowgccwgaAEIMtFurHbhumxxcQn4eOP3GtxRXDtHw7LIx9IHZgYrf68
# MHwwZaRjMGExCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9y
# YXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWVzdGFtcGlu
# ZyBDQSAyMDIwAhMzAAAAWXzacemNXvXAAAAAAABZMCIEIKWikEUszKtmTq3PJAc9
# JqdssuZn61mlGBpRDAiJpv2lMA0GCSqGSIb3DQEBCwUABIICAGm4ez/lIoNPXrsj
# SqduZ7GgWth4ng5j/8i//h+arjQTiEdfqI1dt77jgULam8eEeSZZChtRkduHsJDm
# teE+Jlim88JC2z6hLKxwVYpNrC1PVhiP2lam1nrn0EuR6ipHG7hdr08sJAqPlFVD
# jNsFe/ocZk+yvzrXO+Un08I1RrbNe07PC/dA5rEX5iBNUHbg9s1hBq1g2WPQwsDy
# YiVO2mP+euX6r6GvI7bJHyjM9fZRL2qjPUiivuG2nRtOBvr9NmJxEZar7lp/M6Ol
# UNU3RnhlnCdOCinZ6GDvIqeJtZV/TEStAOcIuc3VWy8A0nKXVqZmSE0xqtPXafrU
# EVLjjt6vGk8B4qyLmzdLBqt5D+anrosaVz2kIJ+trE+n1TTpoUQ1JsY9qELE9c2X
# AkWiV+0BuqUEXgiqd99W9hafU6f1zfhzUqwGPRnyJ7CM7iUQEdOgSwf6rYf9hfTR
# 3K7xKUFC4Ae0JB4u6iY9tCT+TZFgOECdMUgTOLgd1FxfJ6Fc3lGzj8OcTMOvvSZL
# b1AX9NaOFn7DCwqpI1NtaeeTLBtGSI8Dh7edpys8l6KGPBe1g141kVyQ/WY/CS0w
# 9s+W8OuciVuMdKGJ8UvIpIHa21BRFd2bC9P+/PbX+Z/QU7MPJzSylNafB/te+gjQ
# omLFUhuiqsYfrhT4UdsuAhYpnmoy
# SIG # End signature block
