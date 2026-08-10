#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    .SYNOPSIS
        Pester tests for the ConsoleStatus module.

    .DESCRIPTION
        The rendering is tested by capturing the information stream with 6>&1 and joining the
        records back into the lines that were written, so the column arithmetic is asserted
        directly instead of by eye.

    .NOTES
        Function  : ConsoleStatus.Tests
        Author    : John Billekens
        Copyright : Copyright (c) John Billekens Consultancy
        Version   : 2026.810.1425
#>

BeforeAll {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\ConsoleStatus\ConsoleStatus.psd1') -Force

    # The rendered output, reconstructed from the information stream. Write-Host records carry a
    # NoNewLine flag, so the original line breaks can be rebuilt exactly.
    function Get-RenderedLines {
        [CmdletBinding()]
        [OutputType([String[]])]
        param(
            [Parameter(Mandatory = $true)]
            [scriptblock]$Script
        )

        $records = & $Script 6>&1
        $lines = New-Object -TypeName 'System.Collections.Generic.List[string]'
        $current = ''

        foreach ($record in $records) {
            $current += $record.ToString()

            if (-not $record.MessageData.NoNewLine) {
                $lines.Add($current)
                $current = ''
            }
        }

        if ($current.Length -gt 0) {
            $lines.Add($current)
        }

        return $lines.ToArray()
    }

    # Reassembles the text of a wrapped item: strips the status block, the continuation marker,
    # the bar and the fill runs, then collapses the whitespace. A run of two or more dots is fill,
    # a single dot is punctuation and survives.
    function Get-SpilledText {
        [CmdletBinding()]
        [OutputType([String])]
        param(
            [Parameter(Mandatory = $true)]
            [string[]]$Lines
        )

        $parts = foreach ($line in $Lines) {
            $text = $line -replace '\[[^\]]*\]\s*$', ''
            $text = $text -replace '>\s*$', ''
            $text = $text -replace '\.{2,}', ' '
            $text -replace '\*+', ' '
        }

        return ((($parts -join ' ') -replace '\s+', ' ').Trim())
    }

    # Convenience for the common case of asserting on a single rendered line.
    function Get-RenderedLine {
        [CmdletBinding()]
        [OutputType([String])]
        param(
            [Parameter(Mandatory = $true)]
            [scriptblock]$Script
        )

        return @(Get-RenderedLines -Script $Script)[0]
    }

    function Get-DetectedWidth {
        [CmdletBinding()]
        param()

        try {
            return [int]$Host.UI.RawUI.WindowSize.Width
        } catch {
            return 0
        }
    }

    # Pester 5 does not allow a BeforeEach in the root of the container, so each Describe calls this.
    function Reset-TestState {
        [CmdletBinding()]
        param()

        Remove-Item -Path 'env:CONSOLESTATUS_WIDTH' -ErrorAction SilentlyContinue
        Remove-Item -Path 'env:NO_COLOR' -ErrorAction SilentlyContinue
        Reset-ConsoleStatusLog
        Set-ConsoleStatusStyle -Width 100
    }
}

Describe 'Module layout' {

    BeforeAll {
        $script:moduleRoot = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..\ConsoleStatus')).Path
        $script:repoRoot = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..')).Path

        function Get-FunctionAst {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory = $true)]
                [string]$Path
            )

            $tokens = $null
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)

            return [PSCustomObject]@{
                Errors    = @($errors)
                Functions = @($ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
            }
        }
    }

    It 'parses every PowerShell file in the repository without errors' {
        $files = @(Get-ChildItem -Path $script:repoRoot -Recurse -Include '*.ps1', '*.psm1', '*.psd1' |
                Where-Object { $_.FullName -notlike '*\.git\*' })

        $files.Count | Should -BeGreaterThan 0

        foreach ($file in $files) {
            $parsed = Get-FunctionAst -Path $file.FullName
            $message = "$($file.Name): $(($parsed.Errors | ForEach-Object { $_.Message }) -join '; ')"
            $parsed.Errors.Count | Should -Be 0 -Because $message
        }
    }

    It 'defines no functions in the psm1' {
        $parsed = Get-FunctionAst -Path (Join-Path -Path $script:moduleRoot -ChildPath 'ConsoleStatus.psm1')
        $names = ($parsed.Functions | ForEach-Object { $_.Name }) -join ', '

        $parsed.Functions.Count | Should -Be 0 -Because "the psm1 should only hold state and the loader, found: $names"
    }

    It 'keeps every exported function in public and every other one in private' {
        $exported = @(Get-Command -Module 'ConsoleStatus' | Select-Object -ExpandProperty Name | Sort-Object)
        $public = @(Get-ChildItem -Path (Join-Path -Path $script:moduleRoot -ChildPath 'public') -Filter '*.ps1' |
                Select-Object -ExpandProperty BaseName | Sort-Object)
        $private = @(Get-ChildItem -Path (Join-Path -Path $script:moduleRoot -ChildPath 'private') -Filter '*.ps1' |
                Select-Object -ExpandProperty BaseName | Sort-Object)

        $public -join ',' | Should -Be ($exported -join ',')
        @($private | Where-Object { $_ -in $exported }).Count | Should -Be 0
    }

    It 'exports exactly what the manifest lists' {
        $manifest = Test-ModuleManifest -Path (Join-Path -Path $script:moduleRoot -ChildPath 'ConsoleStatus.psd1')
        $exported = @(Get-Command -Module 'ConsoleStatus' | Select-Object -ExpandProperty Name | Sort-Object)

        (@($manifest.ExportedFunctions.Keys) | Sort-Object) -join ',' | Should -Be ($exported -join ',')
    }

    It 'defines exactly one function per file in <Folder>' -ForEach @(
        @{ Folder = 'private' }
        @{ Folder = 'public' }
    ) {
        $files = @(Get-ChildItem -Path (Join-Path -Path $script:moduleRoot -ChildPath $Folder) -Filter '*.ps1')
        $files.Count | Should -BeGreaterThan 0

        foreach ($file in $files) {
            $parsed = Get-FunctionAst -Path $file.FullName
            $names = ($parsed.Functions | ForEach-Object { $_.Name }) -join ', '

            $parsed.Functions.Count | Should -Be 1 -Because "$Folder\$($file.Name) holds: $names"
            $parsed.Functions[0].Name | Should -Be $file.BaseName
        }
    }
}

Describe 'Width resolution' {
    BeforeEach { Reset-TestState }

    It 'uses a pinned width exactly, with no margin subtracted' {
        Set-ConsoleStatusStyle -Width 70
        (Get-ConsoleStatusStyle).LineWidth | Should -Be 70
    }

    It 'ignores MinWidth and MaxWidth for a pinned width' {
        Set-ConsoleStatusStyle -Width 100 -MaxWidth 60 -MinWidth 90
        (Get-ConsoleStatusStyle).LineWidth | Should -Be 100
    }

    It 'clamps a pinned width that does not fit the console, and warns' {
        $detected = Get-DetectedWidth

        if ($detected -lt 1) {
            Set-ItResult -Skipped -Because 'no console width could be detected'
            return
        }

        $warnings = @()
        Set-ConsoleStatusStyle -Width 250 -WarningVariable warnings -WarningAction SilentlyContinue

        (Get-ConsoleStatusStyle).LineWidth | Should -Be ($detected - 1)
        $warnings.Count | Should -BeGreaterThan 0
        [string]$warnings[0] | Should -BeLike '*does not fit the console*'
    }

    It 'honors a pinned width wider than the console when ForceWidth is set' {
        $warnings = @()
        Set-ConsoleStatusStyle -Width 250 -ForceWidth -WarningVariable warnings -WarningAction SilentlyContinue

        (Get-ConsoleStatusStyle).LineWidth | Should -Be 250
        $warnings.Count | Should -Be 0
    }

    It 'treats CONSOLESTATUS_WIDTH as a terminal width and subtracts the margin' {
        $env:CONSOLESTATUS_WIDTH = '85'
        Set-ConsoleStatusStyle
        (Get-ConsoleStatusStyle).LineWidth | Should -Be 84
    }

    It 'still caps CONSOLESTATUS_WIDTH with MaxWidth' {
        $env:CONSOLESTATUS_WIDTH = '200'
        Set-ConsoleStatusStyle -MaxWidth 90 -WarningAction SilentlyContinue
        (Get-ConsoleStatusStyle).LineWidth | Should -Be 90
    }

    It 'warns and falls through on an unparsable CONSOLESTATUS_WIDTH' {
        $env:CONSOLESTATUS_WIDTH = 'wide'
        $warnings = @()
        Set-ConsoleStatusStyle -WarningVariable warnings -WarningAction SilentlyContinue

        $warnings.Count | Should -BeGreaterThan 0
        (Get-ConsoleStatusStyle).LineWidth | Should -BeGreaterThan 0
    }

    It 'applies MinWidth to a measured width' {
        Set-ConsoleStatusStyle -MinWidth 200 -MaxWidth 250
        (Get-ConsoleStatusStyle).LineWidth | Should -Be 200
    }
}

Describe 'Setting precedence' {
    BeforeEach { Reset-TestState }

    It 'falls back to the built in default' {
        Set-ConsoleStatusStyle
        (Get-ConsoleStatusStyle).LabelWidth | Should -Be 24
    }

    It 'takes the value from $ConsoleStatusPreference in the caller scope' {
        $ConsoleStatusPreference = @{ LabelWidth = 30; Width = 100 }
        Set-ConsoleStatusStyle
        (Get-ConsoleStatusStyle).LabelWidth | Should -Be 30
    }

    It 'lets an explicit parameter beat the preference' {
        $ConsoleStatusPreference = @{ LabelWidth = 30; Width = 100 }
        Set-ConsoleStatusStyle -LabelWidth 40
        (Get-ConsoleStatusStyle).LabelWidth | Should -Be 40
    }

    It 'does not carry a preference over to the next call' {
        $ConsoleStatusPreference = @{ LabelWidth = 30; Width = 100 }
        Set-ConsoleStatusStyle
        $ConsoleStatusPreference = @{ Width = 100 }
        Set-ConsoleStatusStyle
        (Get-ConsoleStatusStyle).LabelWidth | Should -Be 24
    }

    It 'keeps an explicit glyph when Unicode is also set' {
        Set-ConsoleStatusStyle -Unicode -TickChar '@' -Width 100
        (Get-ConsoleStatusStyle).TickChar | Should -Be '@'
    }
}

Describe 'Setting validation' {
    BeforeEach { Reset-TestState }

    It 'throws on an unknown key' {
        $ConsoleStatusPreference = @{ LableWidth = 30 }
        { Set-ConsoleStatusStyle } | Should -Throw '*unknown setting ''LableWidth''*'
    }

    It 'throws on an invalid Mode' {
        $ConsoleStatusPreference = @{ Mode = 'Sideways' }
        { Set-ConsoleStatusStyle } | Should -Throw '*Mode must be*'
    }

    It 'throws on a Width below the minimum' {
        $ConsoleStatusPreference = @{ Width = 20 }
        { Set-ConsoleStatusStyle } | Should -Throw '*Width must be 0*'
    }

    It 'throws on a ValueWidth between 1 and 5' {
        $ConsoleStatusPreference = @{ ValueWidth = 3 }
        { Set-ConsoleStatusStyle } | Should -Throw '*ValueWidth must be 0*'
    }

    It 'throws when the preference is not a hashtable' {
        $ConsoleStatusPreference = 'nope'
        { Set-ConsoleStatusStyle } | Should -Throw '*must be a hashtable*'
    }

    It 'throws when LogAction is not a scriptblock' {
        $ConsoleStatusPreference = @{ LogAction = 'Write-Log' }
        { Set-ConsoleStatusStyle } | Should -Throw '*LogAction must be a scriptblock*'
    }

    It 'throws on a multi character glyph' {
        $ConsoleStatusPreference = @{ TickChar = '**' }
        { Set-ConsoleStatusStyle } | Should -Throw '*exactly one character*'
    }
}

Describe 'Rendering' {
    BeforeEach { Reset-TestState }

    It 'writes a line of exactly LineWidth characters in Column mode' {
        Set-ConsoleStatusStyle -Mode 'Column' -Width 100
        $line = Get-RenderedLine -Script {
            Write-ConsoleItem -Label 'Label' -Value 'Value'
            Write-ConsoleTick -Count 5
            Write-ConsoleResult -Status OK
        }

        $line.Length | Should -Be 100
    }

    It 'writes a line of exactly LineWidth characters in Flow mode' {
        Set-ConsoleStatusStyle -Mode 'Flow' -Width 100
        $line = Get-RenderedLine -Script {
            Write-ConsoleItem -Label 'A much longer label here' -Value 'C:\some\path\value.txt'
            Write-ConsoleTick -Count 5
            Write-ConsoleResult -Status OK
        }

        $line.Length | Should -Be 100
    }

    It 'right aligns the status block' {
        $line = Get-RenderedLine -Script {
            Write-ConsoleItem -Label 'Label' -Value 'Value'
            Write-ConsoleResult -Status FAIL
        }

        # Square brackets are a character class to -BeLike, so the status block is matched as regex.
        $line | Should -Match ([regex]::Escape('[ FAIL ]') + '$')
    }

    It 'never lets a line grow past the width, however many ticks arrive at once' {
        $lines = @(Get-RenderedLines -Script {
                Write-ConsoleItem -Label 'Label' -Value 'Value'
                Write-ConsoleTick -Count 500
                Write-ConsoleResult -Status OK
            })

        $lines[-1].Length | Should -Be 100

        foreach ($line in $lines) {
            $line.Length | Should -BeLessOrEqual 100
        }
    }

    It 'drops the value column when ValueWidth is 0' {
        Set-ConsoleStatusStyle -ValueWidth 0 -Width 100
        $line = Get-RenderedLine -Script {
            Write-ConsoleItem -Label 'Label' -Value 'ShouldNotAppear'
            Write-ConsoleResult -Status OK
        }

        $line | Should -Not -BeLike '*ShouldNotAppear*'
        $line.Length | Should -Be 100
    }

    It 'shows the detail in front of the status' {
        $line = Get-RenderedLine -Script {
            Write-ConsoleItem -Label 'Label' -Value 'Value'
            Write-ConsoleResult -Status OK -Detail '340 found'
        }

        $line | Should -Match ([regex]::Escape('340 found [  OK  ]') + '$')
        $line.Length | Should -Be 100
    }

    It 'spills a detail that does not fit onto continuation lines instead of truncating it' {
        $detail = (1..60 | ForEach-Object { 'word' }) -join ' '
        $lines = @(Get-RenderedLines -Script {
                Write-ConsoleItem -Label 'Label' -Value 'Value'
                Write-ConsoleTick -Count 40
                Write-ConsoleResult -Status OK -Detail $detail
            })

        $lines.Count | Should -BeGreaterThan 1

        # The item line is finished and full width, the text follows as a note underneath.
        $lines[0].Length | Should -Be 100
        $lines[0] | Should -Match ([regex]::Escape('[  OK  ]') + '$')

        foreach ($line in $lines) {
            $line.Length | Should -BeLessOrEqual 100
        }

        Get-SpilledText -Lines $lines | Should -BeLike "*$detail*"
    }

    It 'never gives a bare duration a continuation line' {
        Set-ConsoleStatusStyle -ShowDuration -Width 100
        $lines = @(Get-RenderedLines -Script {
                # TotalSteps fills the field exactly, so there is no room left for the duration.
                Write-ConsoleItem -Label 'Label' -Value 'Value' -TotalSteps 10
                1..10 | ForEach-Object { Write-ConsoleTick }
                Write-ConsoleResult -Status OK
            })

        $lines.Count | Should -Be 1
        $lines[0].Length | Should -Be 100
    }

    It 'drops the duration rather than the detail when only one of them fits' {
        Set-ConsoleStatusStyle -ShowDuration -Width 100
        $lines = @(Get-RenderedLines -Script {
                # Leaves room for the detail but not for the detail plus a duration.
                Write-ConsoleItem -Label 'Label' -Value 'Value'
                Write-ConsoleTick -Count 34
                Write-ConsoleResult -Status OK -Detail 'twelve chars'
            })

        $lines.Count | Should -Be 1
        $lines[0] | Should -BeLike '*twelve chars*'
        $lines[0] | Should -Not -Match '\dms'
    }

    It 'takes the duration with the detail when the detail becomes a note' {
        Set-ConsoleStatusStyle -ShowDuration -Width 100
        $lines = @(Get-RenderedLines -Script {
                Write-ConsoleItem -Label 'Label' -Value 'Value'
                Write-ConsoleTick -Count 45
                Write-ConsoleResult -Status FAIL -Detail 'a detail that is far too long to fit in the space that is left'
            })

        $lines.Count | Should -BeGreaterThan 1
        ($lines[1..($lines.Count - 1)] -join ' ') | Should -Match '\d+ms'
    }

    It 'shows the duration for one step when the switch is used and the setting is off' {
        $line = Get-RenderedLine -Script {
            Write-ConsoleItem -Label 'Label' -Value 'Value'
            Write-ConsoleTick -Count 10
            Write-ConsoleResult -Status OK -Detail 'done' -ShowDuration
        }

        $line | Should -Match '\d+ms'
    }

    It 'suppresses the duration for one step when the setting is on' {
        Set-ConsoleStatusStyle -ShowDuration -Width 100
        $line = Get-RenderedLine -Script {
            Write-ConsoleItem -Label 'Label' -Value 'Value'
            Write-ConsoleTick -Count 10
            Write-ConsoleResult -Status OK -Detail 'done' -ShowDuration:$false
        }

        $line | Should -Not -Match '\d+ms'
        $line | Should -BeLike '*done*'
    }

    It 'passes the duration switch through Invoke-ConsoleStep' {
        $line = Get-RenderedLine -Script {
            Invoke-ConsoleStep -Label 'Label' -Value 'Value' -ShowDuration -Action {
                Write-ConsoleTick -Count 10
                Set-ConsoleStepDetail -Text 'done'
            }
        }

        $line | Should -Match '\d+ms'
    }

    It 'writes an overflowing detail as a marked note under a finished item' {
        $lines = @(Get-RenderedLines -Script {
                Write-ConsoleItem -Label 'Label' -Value 'Value'
                Write-ConsoleTick -Count 45
                Write-ConsoleResult -Status FAIL -Detail 'a detail that is far too long to fit in the space that is left'
            })

        $lines.Count | Should -Be 2

        # The item line is complete on its own, the note is indented and marked.
        $lines[0] | Should -Match ([regex]::Escape('[ FAIL ]') + '$')
        $lines[1] | Should -Match '^ {4}> \S'
        $lines[1] | Should -Not -Match ([regex]::Escape('['))
    }

    It 'indents a note the same way in Flow mode, whatever the value did to the field' {
        Set-ConsoleStatusStyle -Mode 'Flow' -Width 100
        $lines = @(Get-RenderedLines -Script {
                Write-ConsoleItem -Label 'A label' -Value ('x' * 70)
                Write-ConsoleResult -Status FAIL -Detail 'a detail that has to go somewhere sensible even though the value ate the line'
            })

        $lines.Count | Should -BeGreaterThan 1
        $lines[1] | Should -Match '^ {4}> \S'

        foreach ($line in $lines) {
            $line.Length | Should -BeLessOrEqual 100
        }
    }

    It 'wraps a long note under the marker rather than under the field' {
        $lines = @(Get-RenderedLines -Script {
                Write-ConsoleItem -Label 'Label' -Value 'Value'
                Write-ConsoleResult -Status WARN -Detail ((1..40 | ForEach-Object { 'word' }) -join ' ')
            })

        $lines.Count | Should -BeGreaterThan 2
        $lines[1] | Should -Match '^ {4}> \S'
        $lines[2] | Should -Match '^ {6}\S'
    }

    It 'hard splits a spilled token that is longer than the line' {
        $lines = @(Get-RenderedLines -Script {
                Write-ConsoleItem -Label 'Label' -Value 'Value'
                Write-ConsoleTick -Count 45
                Write-ConsoleResult -Status WARN -Detail ('z' * 250)
            })

        $lines.Count | Should -BeGreaterThan 2

        foreach ($line in $lines) {
            $line.Length | Should -BeLessOrEqual 100
        }
    }

    It 'collapses whitespace in a value so the columns survive' {
        $line = Get-RenderedLine -Script {
            Write-ConsoleItem -Label 'Label' -Value "one`r`ntwo`tthree"
            Write-ConsoleResult -Status OK
        }

        $line.Length | Should -Be 100
        $line | Should -BeLike '*one two three*'
    }

    It 'takes the detail from Set-ConsoleStepDetail' {
        $line = Get-RenderedLine -Script {
            Write-ConsoleItem -Label 'Label' -Value 'Value'
            Set-ConsoleStepDetail -Text 'from the step'
            Write-ConsoleResult -Status OK
        }

        $line | Should -Match ([regex]::Escape('from the step [  OK  ]') + '$')
    }

    It 'uses the exception message as the detail on FAIL' {
        $record = try { throw 'boom happened' } catch { $_ }
        $line = Get-RenderedLine -Script {
            Write-ConsoleItem -Label 'Label' -Value 'Value'
            Write-ConsoleResult -Status FAIL -ErrorRecord $record
        }

        $line | Should -Match ([regex]::Escape('boom happened [ FAIL ]') + '$')
    }

    It 'renders the same text with NO_COLOR set' {
        $withColor = Get-RenderedLine -Script {
            Write-ConsoleItem -Label 'Label' -Value 'Value'
            Write-ConsoleResult -Status OK
        }

        $env:NO_COLOR = '1'
        Set-ConsoleStatusStyle -Width 100
        (Get-ConsoleStatusStyle).NoColor | Should -BeTrue

        $withoutColor = Get-RenderedLine -Script {
            Write-ConsoleItem -Label 'Label' -Value 'Value'
            Write-ConsoleResult -Status OK
        }

        $withoutColor | Should -Be $withColor
    }
}

Describe 'Progress bar limits' {
    BeforeEach { Reset-TestState }

    It 'continues the bar on a new line when the total is unknown' {
        $lines = @(Get-RenderedLines -Script {
                Write-ConsoleItem -Label 'Label' -Value 'Value'
                1..120 | ForEach-Object { Write-ConsoleTick }
                Write-ConsoleResult -Status OK
            })

        $lines.Count | Should -Be 3

        # Only the last line carries a status block. The earlier ones end bare, which together
        # with the empty columns is what marks them as continued.
        $lines[0] | Should -Match '\*$'
        $lines[1] | Should -Match '\*$'
        $lines[0] | Should -Not -Match ([regex]::Escape('['))
        $lines[2] | Should -Match ([regex]::Escape('[  OK  ]') + '$')
        $lines[2].Length | Should -Be 100

        # Continuation lines leave the label and value columns empty.
        $lines[1] | Should -Match '^ {42}\*'
    }

    It 'ends a continued line with an empty status block in Blank mode' {
        Set-ConsoleStatusStyle -Width 100 -BarContinuation 'Blank'
        $lines = @(Get-RenderedLines -Script {
                Write-ConsoleItem -Label 'Label' -Value 'Value'
                1..120 | ForEach-Object { Write-ConsoleTick }
                Write-ConsoleResult -Status OK
            })

        $lines[0] | Should -Match ([regex]::Escape('[      ]') + '$')
        $lines[0].Length | Should -Be 100
        $lines[-1] | Should -Match ([regex]::Escape('[  OK  ]') + '$')
    }

    It 'stays on one line when the ticks fit' {
        $lines = @(Get-RenderedLines -Script {
                Write-ConsoleItem -Label 'Label' -Value 'Value'
                Write-ConsoleTick -Count 5
                Write-ConsoleResult -Status OK
            })

        $lines.Count | Should -Be 1
        $lines[0] | Should -Not -Match ([regex]::Escape('>'))
    }

    It 'stops the bar after MaxBarLines and marks the overflow' {
        $lines = @(Get-RenderedLines -Script {
                Write-ConsoleItem -Label 'Label' -Value 'Value'
                1..500 | ForEach-Object { Write-ConsoleTick }
                Write-ConsoleResult -Status OK
            })

        # Three by default, and the last one says the work carried on past the bar.
        $lines.Count | Should -Be 3
        $lines[2] | Should -Match ([regex]::Escape('> [  OK  ]') + '$')
        $lines[2].Length | Should -Be 100
    }

    It 'does not mark an overflow when the bar finished inside the cap' {
        $lines = @(Get-RenderedLines -Script {
                Write-ConsoleItem -Label 'Label' -Value 'Value'
                1..60 | ForEach-Object { Write-ConsoleTick }
                Write-ConsoleResult -Status OK
            })

        $lines.Count | Should -Be 2
        $lines[1] | Should -Not -Match ([regex]::Escape('> ['))
    }

    It 'keeps every item on one line when MaxBarLines is 1' {
        Set-ConsoleStatusStyle -Width 100 -MaxBarLines 1
        $lines = @(Get-RenderedLines -Script {
                Write-ConsoleItem -Label 'Label' -Value 'Value'
                1..500 | ForEach-Object { Write-ConsoleTick }
                Write-ConsoleResult -Status OK
            })

        $lines.Count | Should -Be 1
        $lines[0] | Should -Match ([regex]::Escape('> [  OK  ]') + '$')
    }

    It 'wraps without limit when MaxBarLines is 0' {
        Set-ConsoleStatusStyle -Width 100 -MaxBarLines 0
        $lines = @(Get-RenderedLines -Script {
                Write-ConsoleItem -Label 'Label' -Value 'Value'
                1..500 | ForEach-Object { Write-ConsoleTick }
                Write-ConsoleResult -Status OK
            })

        $field = 100 - 2 - 24 - 16 - 8 - 1   # the trailing 1 is the status gap
        $lines.Count | Should -Be ([int][Math]::Ceiling(500 / $field))
    }

    It 'resets the line count between items' {
        $lines = @(Get-RenderedLines -Script {
                Write-ConsoleItem -Label 'First' -Value 'Value'
                1..500 | ForEach-Object { Write-ConsoleTick }
                Write-ConsoleResult -Status OK

                Write-ConsoleItem -Label 'Second' -Value 'Value'
                1..500 | ForEach-Object { Write-ConsoleTick }
                Write-ConsoleResult -Status OK
            })

        $lines.Count | Should -Be 6
    }

    It 'rejects a MaxBarLines outside the allowed range' {
        $ConsoleStatusPreference = @{ MaxBarLines = 50 }
        { Set-ConsoleStatusStyle } | Should -Throw '*MaxBarLines must be between 0 and 20*'
    }

    It 'rejects an invalid BarContinuation' {
        $ConsoleStatusPreference = @{ BarContinuation = 'Wrapped' }
        { Set-ConsoleStatusStyle } | Should -Throw '*BarContinuation must be*'
    }

    It 'spans the field exactly when TotalSteps is reached' {
        $line = Get-RenderedLine -Script {
            Write-ConsoleItem -Label 'Label' -Value 'Value' -TotalSteps 200
            1..200 | ForEach-Object { Write-ConsoleTick }
            Write-ConsoleResult -Status OK
        }

        $field = 100 - 2 - 24 - 16 - 8 - 1
        $line.Length | Should -Be 100
        # The whole field is ticks, so the status follows them directly with no fill.
        $line | Should -Match ([regex]::Escape(('*' * $field) + ' [  OK  ]') + '$')
    }

    It 'draws a proportional bar when TotalSteps is only partly done' {
        $line = Get-RenderedLine -Script {
            Write-ConsoleItem -Label 'Label' -Value 'Value' -TotalSteps 200
            1..100 | ForEach-Object { Write-ConsoleTick }
            Write-ConsoleResult -Status OK
        }

        $ticks = ([regex]::Matches($line, '\*')).Count
        $field = 100 - 2 - 24 - 16 - 8 - 1   # the trailing 1 is the status gap
        $ticks | Should -Be ([int][Math]::Floor($field / 2))
        $line.Length | Should -Be 100
    }

    It 'never overruns the field when more ticks arrive than TotalSteps declared' {
        $line = Get-RenderedLine -Script {
            Write-ConsoleItem -Label 'Label' -Value 'Value' -TotalSteps 10
            1..400 | ForEach-Object { Write-ConsoleTick }
            Write-ConsoleResult -Status OK
        }

        $line.Length | Should -Be 100
    }

    It 'fills the bar for a TotalSteps smaller than the field' {
        $line = Get-RenderedLine -Script {
            Write-ConsoleItem -Label 'Label' -Value 'Value' -TotalSteps 3
            1..3 | ForEach-Object { Write-ConsoleTick }
            Write-ConsoleResult -Status OK
        }

        $line.Length | Should -Be 100
        $line | Should -Match ([regex]::Escape('* [  OK  ]') + '$')
    }

    It 'passes TotalSteps through from Invoke-ConsoleStep' {
        $line = Get-RenderedLine -Script {
            Invoke-ConsoleStep -Label 'Label' -Value 'Value' -TotalSteps 4 -Action {
                1..4 | ForEach-Object { Write-ConsoleTick }
            }
        }

        $line.Length | Should -Be 100
        $line | Should -Match ([regex]::Escape('* [  OK  ]') + '$')
    }
}

Describe 'Duration formatting' {

    It 'formats <Ms>ms as <Expected>' -ForEach @(
        @{ Ms = 0; Expected = '0ms' }
        @{ Ms = 999; Expected = '999ms' }
        @{ Ms = 1000; Expected = '1s' }
        @{ Ms = 2540; Expected = '2.5s' }
        @{ Ms = 59900; Expected = '59.9s' }
        @{ Ms = 60000; Expected = '1m 0s' }
        @{ Ms = 252000; Expected = '4m 12s' }
        @{ Ms = 3600000; Expected = '1h 0m' }
        @{ Ms = 5460000; Expected = '1h 31m' }
    ) {
        InModuleScope -ModuleName 'ConsoleStatus' -Parameters @{ Ms = $Ms; Expected = $Expected } -ScriptBlock {
            Format-Duration -Milliseconds $Ms | Should -Be $Expected
        }
    }
}

Describe 'Multiline detail' {
    BeforeEach { Reset-TestState }

    It 'collapses line breaks so the item line survives' {
        $detail = "first line`r`nsecond line`tand a tab"
        $lines = @(Get-RenderedLines -Script {
                Write-ConsoleItem -Label 'Label' -Value 'Value'
                Write-ConsoleTick -Count 5
                Write-ConsoleResult -Status WARN -Detail $detail
            })

        $lines[0].Length | Should -Be 100

        foreach ($line in $lines) {
            $line | Should -Not -Match "[`r`n`t]"
        }
    }

    It 'records a multiline detail as a single line' {
        Write-ConsoleItem -Label 'Label' -Value 'Value' 6>$null
        Write-ConsoleResult -Status WARN -Detail "one`r`ntwo" 6>$null

        @(Get-ConsoleStatusLog)[0].Detail | Should -Be 'one two'
    }

    It 'records a multiline exception message as a single line' {
        $errorRecord = try { throw "one`r`ntwo`r`nthree" } catch { $_ }
        Write-ConsoleItem -Label 'Label' -Value 'Value' 6>$null
        Write-ConsoleResult -Status FAIL -ErrorRecord $errorRecord 6>$null

        @(Get-ConsoleStatusLog)[0].Error | Should -Be 'one two three'
    }

    It 'picks up a multiline exception message and rewraps it' {
        $lines = @(Get-RenderedLines -Script {
                Invoke-ConsoleStep -Label 'Label' -Value 'Value' -ContinueOnError -Action {
                    Write-ConsoleTick -Count 40
                    throw ("first sentence here.{0}second sentence here.{0}third sentence here." -f [Environment]::NewLine)
                }
            })

        $lines.Count | Should -BeGreaterThan 1

        foreach ($line in $lines) {
            $line.Length | Should -BeLessOrEqual 100
        }

        Get-SpilledText -Lines $lines | Should -BeLike '*first sentence here. second sentence here. third sentence here.*'
    }
}

Describe 'Explicit notes' {
    BeforeEach { Reset-TestState }

    It 'always writes a note on its own line, even when it would have fitted inline' {
        $lines = @(Get-RenderedLines -Script {
                Write-ConsoleItem -Label 'Label' -Value 'Value'
                Write-ConsoleTick -Count 5
                Write-ConsoleResult -Status OK -Note 'short'
            })

        $lines.Count | Should -Be 2
        $lines[0] | Should -Not -BeLike '*short*'
        $lines[1] | Should -Match '^ {4}> short$'
    }

    It 'writes the overflowing detail and the note as separate blocks' {
        $lines = @(Get-RenderedLines -Script {
                Write-ConsoleItem -Label 'Label' -Value 'Value'
                Write-ConsoleTick -Count 45
                Write-ConsoleResult -Status FAIL -Detail 'a detail that is far too long to fit next to the status' -Note 'and a note as well'
            })

        ($lines | Where-Object { $_ -match '^\s+> ' }).Count | Should -Be 2
        $lines[-1] | Should -Match '^ {4}> and a note as well$'
    }

    It 'takes a note set from inside an action' {
        $lines = @(Get-RenderedLines -Script {
                Invoke-ConsoleStep -Label 'Label' -Value 'Value' -Action {
                    Write-ConsoleTick -Count 4
                    Set-ConsoleStepNote -Text 'from the step'
                }
            })

        $lines[-1] | Should -Match '^ {4}> from the step$'
    }

    It 'records the note as its own field' {
        Write-ConsoleItem -Label 'Label' -Value 'Value' 6>$null
        Write-ConsoleResult -Status OK -Note 'C:\some\long\path.txt' 6>$null

        @(Get-ConsoleStatusLog)[0].Note | Should -Be 'C:\some\long\path.txt'
    }

    It 'does not carry a note over to the next item' {
        Write-ConsoleItem -Label 'First' -Value 'Value' 6>$null
        Write-ConsoleResult -Status OK -Note 'only here' 6>$null

        $lines = @(Get-RenderedLines -Script {
                Write-ConsoleItem -Label 'Second' -Value 'Value'
                Write-ConsoleResult -Status OK
            })

        $lines.Count | Should -Be 1
    }
}

Describe 'Records and summary' {
    BeforeEach { Reset-TestState }

    It 'lists the failures under the summary' {
        $errorRecord = try { throw 'the reason it broke' } catch { $_ }
        Write-ConsoleItem -Label 'Good step' -Value 'v' 6>$null
        Write-ConsoleResult -Status OK 6>$null
        Write-ConsoleItem -Label 'Bad step' -Value 'wildcard.pfx' 6>$null
        Write-ConsoleResult -Status FAIL -ErrorRecord $errorRecord 6>$null

        $lines = @(Get-RenderedLines -Script { Write-ConsoleSummary })
        $joined = $lines -join "`n"

        $joined | Should -BeLike '*Bad step (wildcard.pfx)*'
        $joined | Should -BeLike '*the reason it broke*'
        $joined | Should -Not -BeLike '*Good step*'
    }

    It 'lists nothing extra when there are no failures' {
        Write-ConsoleItem -Label 'Good step' -Value 'v' 6>$null
        Write-ConsoleResult -Status OK 6>$null

        $lines = @(Get-RenderedLines -Script { Write-ConsoleSummary })
        ($lines | Where-Object { $_ -match '^\s+> ' }).Count | Should -Be 0
    }

    It 'counts every status' {
        Write-ConsoleItem -Label 'a' -Value '1' 6>$null
        Write-ConsoleResult -Status OK 6>$null
        Write-ConsoleItem -Label 'b' -Value '2' 6>$null
        Write-ConsoleResult -Status WARN 6>$null
        Write-ConsoleItem -Label 'c' -Value '3' 6>$null
        Write-ConsoleResult -Status FAIL 6>$null

        $summary = Get-ConsoleStatusSummary
        $summary.Total | Should -Be 3
        $summary.OK | Should -Be 1
        $summary.Warn | Should -Be 1
        $summary.Fail | Should -Be 1
    }

    It 'records the label, value, section and status' {
        Write-ConsoleSection -Title 'My section' 6>$null
        Write-ConsoleItem -Label 'My label' -Value 'My value' 6>$null
        Write-ConsoleResult -Status OK -Detail 'My detail' 6>$null

        $record = @(Get-ConsoleStatusLog)[0]
        $record.Section | Should -Be 'My section'
        $record.Label | Should -Be 'My label'
        $record.Value | Should -Be 'My value'
        $record.Detail | Should -Be 'My detail'
        $record.Status | Should -Be 'OK'
    }

    It 'keeps the duration out of the recorded detail' {
        Set-ConsoleStatusStyle -ShowDuration -Width 100
        Write-ConsoleItem -Label 'a' -Value '1' 6>$null
        Write-ConsoleResult -Status OK -Detail 'plain detail' 6>$null

        @(Get-ConsoleStatusLog)[0].Detail | Should -Be 'plain detail'
    }

    It 'keeps the full detail in the record when the display truncates it' {
        $long = 'y' * 200
        Write-ConsoleItem -Label 'a' -Value '1' 6>$null
        Write-ConsoleResult -Status OK -Detail $long 6>$null

        @(Get-ConsoleStatusLog)[0].Detail | Should -Be $long
    }

    It 'records the exception message on FAIL' {
        $record = try { throw 'kaboom' } catch { $_ }
        Write-ConsoleItem -Label 'a' -Value '1' 6>$null
        Write-ConsoleResult -Status FAIL -ErrorRecord $record 6>$null

        @(Get-ConsoleStatusLog)[0].Error | Should -Be 'kaboom'
    }

    It 'does not count or log a NoRecord line' {
        Write-ConsoleItem -Label 'a' -Value '1' 6>$null
        Write-ConsoleResult -Status OK -NoRecord 6>$null

        (Get-ConsoleStatusSummary).Total | Should -Be 0
        @(Get-ConsoleStatusLog).Count | Should -Be 0
    }

    It 'leaves its own summary lines out of the totals' {
        Write-ConsoleItem -Label 'a' -Value '1' 6>$null
        Write-ConsoleResult -Status OK 6>$null
        Write-ConsoleSummary 6>$null

        (Get-ConsoleStatusSummary).Total | Should -Be 1
    }

    It 'invokes LogAction once per completed item' {
        $script:seen = New-Object -TypeName 'System.Collections.Generic.List[string]'
        Set-ConsoleStatusStyle -Width 100 -LogAction { param($Record) $script:seen.Add($Record.Label) }

        Write-ConsoleItem -Label 'first' -Value '1' 6>$null
        Write-ConsoleResult -Status OK 6>$null
        Write-ConsoleItem -Label 'second' -Value '2' 6>$null
        Write-ConsoleResult -Status OK 6>$null

        $script:seen.Count | Should -Be 2
        $script:seen[1] | Should -Be 'second'
    }

    It 'survives a LogAction that throws, and warns only once' {
        Set-ConsoleStatusStyle -Width 100 -LogAction { throw 'logger is broken' }

        # Not wrapped in a scriptblock: -WarningVariable would then land in that inner scope.
        # An exception from the logger would fail the test by escaping here.
        Write-ConsoleItem -Label 'a' -Value '1' 6>$null
        Write-ConsoleResult -Status OK -WarningVariable firstWarnings -WarningAction SilentlyContinue 6>$null
        Write-ConsoleItem -Label 'b' -Value '2' 6>$null
        Write-ConsoleResult -Status OK -WarningVariable secondWarnings -WarningAction SilentlyContinue 6>$null

        (Get-ConsoleStatusSummary).Total | Should -Be 2
        @($firstWarnings).Count | Should -Be 1
        @($secondWarnings).Count | Should -Be 0
    }

    It 'clears the log and the counters on reset' {
        Write-ConsoleItem -Label 'a' -Value '1' 6>$null
        Write-ConsoleResult -Status OK 6>$null
        Reset-ConsoleStatusLog

        (Get-ConsoleStatusSummary).Total | Should -Be 0
        @(Get-ConsoleStatusLog).Count | Should -Be 0
    }
}

Describe 'Output stream cleanliness' {
    BeforeEach { Reset-TestState }

    It 'writes nothing to the success stream' {
        $captured = & {
            Write-ConsoleSection -Title 'Section'
            Write-ConsoleItem -Label 'Label' -Value 'Value'
            Write-ConsoleTick -Count 3
            Set-ConsoleStepDetail -Text 'detail'
            Write-ConsoleResult -Status OK
            Write-ConsoleSummary
        } 6>$null

        @($captured).Count | Should -Be 0
    }

    It 'returns the action output from Invoke-ConsoleStep unchanged' {
        $result = Invoke-ConsoleStep -Label 'Step' -Value 'v' -Action {
            Write-ConsoleTick -Count 2
            1, 2, 3
        } 6>$null

        $result | Should -Be @(1, 2, 3)
    }

    It 'rethrows by default and reports FAIL' {
        { Invoke-ConsoleStep -Label 'Step' -Value 'v' -Action { throw 'nope' } 6>$null } | Should -Throw '*nope*'
        (Get-ConsoleStatusSummary).Fail | Should -Be 1
    }

    It 'swallows the exception with ContinueOnError but still records FAIL' {
        { Invoke-ConsoleStep -Label 'Step' -Value 'v' -ContinueOnError -Action { throw 'nope' } 6>$null } | Should -Not -Throw
        (Get-ConsoleStatusSummary).Fail | Should -Be 1
    }
}
