# Which spans of a command are CONTENT rather than INSTRUCTION?
#
# Why this exists. Recognition tokenises the command's whole text, and had no
# concept of a span that is data. So a command that merely WRITES a file whose
# text happens to name a test runner was recognised as an unguarded test run and
# blocked - and worse, the replacement the hook then suggested was assembled out
# of fragments of that prose. Reported from a sibling project, then reproduced
# here immediately: the guard blocked the script written to reproduce it,
# quoting the heredoc body back as the "arguments" of the test it thought it had
# caught. Each such block also filed a completion record that nothing could ever
# satisfy, because no test ran and so no result could exist.
#
# The rule, and why it is this one. The body of a heredoc is the receiving
# program's STANDARD INPUT. Whether it is commands is therefore a property of
# that program, not of how the text was delimited: `python - <<'PY'` is Python
# source and `cat > f <<'EOF'` is bytes, neither of which can run a test, while
# `bash <<'SH'` really is shell and really can. So a shell keeps its body
# scanned and everything else does not. Quoting the delimiter controls variable
# expansion inside the body - a different question - so it is deliberately not
# what decides here.
#
# A PowerShell here-string needs no such question: it is a string literal, a
# value and never an instruction, whoever receives it later.
#
# Failing safe. An unknown program is NOT a shell and is NOT a transparent
# wrapper. Both defaults err toward scanning text that could never have run a
# test, which is today's behaviour and merely a false positive; the opposite
# error would let a real unbounded run escape the guard, which is the harm this
# hook exists to prevent.

# Opener: `<<` or `<<-`, optional quoting, then the delimiter word.
# Groups: 1 = the dash form, 2 = the quote, 3 = the delimiter.
$script:HeredocOpenerPattern = [regex]'<<(-)?[ \t]*(["'']?)([A-Za-z_][A-Za-z0-9_]*)\2'

function Split-CommandTextLines {
    param([string]$Text)
    return ($Text -split "`r`n|`n|`r")
}

# The program that will actually READ a fed-in block, looked through wrappers
# that merely pass a command along. Switches and NAME=value assignments are
# skipped; an unknown program ends the walk and is returned as-is.
function Get-EffectiveReceivingProgram {
    param([string[]]$Tokens)
    foreach ($token in @($Tokens)) {
        $t = ([string]$token).Trim('"').Trim("'")
        if ($t -eq '') { continue }
        if ($t.StartsWith('-')) { continue }
        if ($t -match '^[A-Za-z_][A-Za-z0-9_]*=') { continue }
        $name = Get-ProgramName $t
        if (@($script:TransparentWrappers) -contains $name) { continue }
        return $name
    }
    return ''
}

# Tokens of the last command segment before a given point on the line - the one
# the opener actually belongs to, so `echo hi && bash <<'SH'` resolves to bash
# and not to echo.
function Get-ReceivingSegmentTokens {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    $parts = @($Text -split '\|\||&&|[;|&]')
    $last = [string]$parts[$parts.Count - 1]
    return @($last -split '\s+' | Where-Object { $_ -ne '' })
}

# Does this segment feed a shell?
#
# Two checks, not one. The wrapper walk is the precise answer, but a wrapper
# switch that takes its own argument would derail it - `sudo -u root bash` puts
# `root` where the walk expects a program. So a shell name appearing ANYWHERE in
# the segment also counts. That second check can only ever keep a body scanned
# when it did not need to be, which costs a false positive and never a missed
# test run.
function Test-SegmentFeedsShell {
    param([string]$Text)
    $tokens = @(Get-ReceivingSegmentTokens -Text $Text)
    if ($tokens.Count -eq 0) { return $false }
    if (@($script:ShellPrograms) -contains (Get-EffectiveReceivingProgram -Tokens $tokens)) { return $true }
    foreach ($token in $tokens) {
        $t = ([string]$token).Trim('"').Trim("'")
        if ($t -eq '' -or $t.StartsWith('-')) { continue }
        if (@($script:ShellPrograms) -contains (Get-ProgramName $t)) { return $true }
    }
    return $false
}

# `@'` ... `'@` and `@"` ... `"@`. Removed unconditionally: a here-string is a
# value in the language itself, so no receiving program is involved.
#
# The opener must END its line (PowerShell's own rule) and the terminator must
# START one, which is why neither is matched loosely - a `@"` inside ordinary
# prose cannot open a phantom block that swallows the rest of the command.
function Remove-PowerShellHereStrings {
    param([string]$Text)
    $lines = @(Split-CommandTextLines -Text $Text)
    $out = New-Object System.Collections.Generic.List[string]
    $closer = ''
    foreach ($line in $lines) {
        if ($closer -ne '') {
            if ($line.StartsWith($closer)) {
                [void]$out.Add($line.Substring($closer.Length))
                $closer = ''
            }
            else { [void]$out.Add('') }
            continue
        }
        $open = -1
        $quote = ''
        foreach ($marker in @("@'", '@"')) {
            $at = $line.IndexOf($marker)
            if ($at -ge 0 -and ($open -lt 0 -or $at -lt $open)) { $open = $at; $quote = $marker.Substring(1) }
        }
        if ($open -lt 0 -or $line.Substring($open + 2).Trim() -ne '') { [void]$out.Add($line); continue }
        [void]$out.Add($line.Substring(0, $open))
        $closer = $quote + '@'
    }
    return ($out -join "`n")
}

# Heredoc bodies, kept or removed according to who receives them.
#
# The body ends at the first line whose ENTIRE content is the delimiter, with
# leading whitespace allowed only for the `<<-` form - the shell's own rule, so
# the guard and the shell agree on where data stops. A delimiter appearing
# inside a longer line does not end anything.
function Remove-HeredocBodies {
    param([string]$Text)
    $lines = @(Split-CommandTextLines -Text $Text)
    $out = New-Object System.Collections.Generic.List[string]
    $delimiter = ''
    $allowIndent = $false
    $keepBody = $false
    foreach ($line in $lines) {
        if ($delimiter -ne '') {
            $candidate = $(if ($allowIndent) { $line.TrimStart(' ', "`t") } else { $line })
            if ($candidate -eq $delimiter) { $delimiter = ''; [void]$out.Add(''); continue }
            [void]$out.Add($(if ($keepBody) { $line } else { '' }))
            continue
        }
        $match = $script:HeredocOpenerPattern.Match($line)
        if (-not $match.Success) { [void]$out.Add($line); continue }
        $before = $line.Substring(0, $match.Index)
        $keepBody = Test-SegmentFeedsShell -Text $before
        $delimiter = $match.Groups[3].Value
        $allowIndent = ($match.Groups[1].Value -eq '-')
        if ($keepBody) { [void]$out.Add($line) }
        else { [void]$out.Add($before + $line.Substring($match.Index + $match.Length)) }
    }
    return ($out -join "`n")
}

# The one entry point. Here-strings FIRST: a here-string may itself contain text
# that looks like a heredoc opener, and removing it first means such text cannot
# open a phantom block. The reverse order has no equivalent protection.
#
# Line structure survives a removal - a dropped body leaves its line boundaries
# behind rather than splicing the text on either side together, because the last
# token before a block and the first token after it must never become
# neighbours and invent a command out of two unrelated fragments.
function Remove-InlineDataBlocks {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    if ($Text.IndexOf('<<') -lt 0 -and $Text.IndexOf('@') -lt 0) { return $Text }
    return (Remove-HeredocBodies -Text (Remove-PowerShellHereStrings -Text $Text))
}
