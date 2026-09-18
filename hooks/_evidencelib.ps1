# Closing-declaration evidence, shared by every hook that gates on one.
#
# A separate file rather than more of _stoplib.ps1: that file is past the size
# ceiling, and this is its own responsibility anyway - _stoplib owns the
# continuation LEDGER, this owns what a closing line has to look like before it
# counts as a claim. It is dot-sourced by _hooklib.ps1 as a sibling, exactly
# like _stoplib.ps1, and staged the same way by the install plan.
#
# THE DEFECT IT FIXES (L05): the three closing gates tested for a PREFIX and
# nothing else. `MCP used:` with nothing after it satisfied the gate. So did
# `Skills used: none` with no reason, and so did a line inside a fenced example
# the agent had written to SHOW the format rather than to make a claim. A prefix
# is a shape; a claim needs content, and these are not the same thing.

# Placeholders that are the shape of an answer without being one. Deliberately
# short and literal - this is not a natural-language check, it is a list of the
# tokens people actually leave behind.
$script:ClosingPlaceholders = @('tbd', 'todo', 'n/a', 'na', 'none yet', 'tbc', '...', '-', '--')

# The content of one closing declaration, or $null when the label is absent.
#
# A transcript line break is the two-character \n ESCAPE as often as a real one,
# so both start a line and both end one. A capture that ran past the escape
# would swallow the rest of the answer and read a later sentence as the claim.
function Get-ClosingDeclarationLine {
    param([AllowEmptyString()][string]$Text, [Parameter(Mandatory = $true)][string]$LabelPattern)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $pattern = '(?im)(?:^|\\n)[ \t]{0,8}(?:[-*>#]+[ \t]{0,4})?(?:\*\*)?' + $LabelPattern + '[ \t]*:((?:(?!\\n)[^\r\n])*)'
    foreach ($match in @([regex]::Matches($Text, $pattern))) {
        # A match inside a fenced block is an EXAMPLE of the format, not a claim
        # in it. Counting the fences before the match is enough: an odd number
        # means the match sits inside one.
        $before = $Text.Substring(0, $match.Index)
        $fences = ([regex]::Matches($before, '```')).Count
        if (($fences % 2) -eq 1) { continue }
        return [string]$match.Groups[1].Value
    }
    return $null
}

# Is a declaration SUBSTANTIVE - does it actually claim something?
#
# Returns @{ Present; Value; Substantive; Reason }. Present says the label was
# found at all; Substantive says it carried a claim. A caller that only checks
# Present is back to the prefix test this exists to replace.
function Test-ClosingDeclaration {
    param(
        [AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][string]$LabelPattern,
        # 'none' is a legitimate answer for these gates, but only WITH a reason -
        # "none" alone is indistinguishable from not having looked.
        [bool]$AllowNoneWithReason = $true
    )
    $value = Get-ClosingDeclarationLine -Text $Text -LabelPattern $LabelPattern
    if ($null -eq $value) {
        return [pscustomobject]@{ Present = $false; Value = ''; Substantive = $false; Reason = 'absent' }
    }
    $trimmed = ([string]$value).Trim().Trim('*').Trim()
    if ($trimmed -eq '') {
        return [pscustomobject]@{ Present = $true; Value = ''; Substantive = $false; Reason = 'empty' }
    }
    if ($script:ClosingPlaceholders -contains $trimmed.ToLowerInvariant()) {
        return [pscustomobject]@{ Present = $true; Value = $trimmed; Substantive = $false; Reason = 'placeholder' }
    }
    # A bracketed template ("<skill names>") is what the instruction itself shows.
    if ($trimmed -match '^<[^>]*>$') {
        return [pscustomobject]@{ Present = $true; Value = $trimmed; Substantive = $false; Reason = 'placeholder' }
    }
    if ($trimmed -match '^(?i)none\b') {
        $rest = $trimmed.Substring(4).Trim()
        # Any separator the instructions suggest, then a real reason.
        $rest = $rest.TrimStart([char[]]@('-', [char]0x2013, [char]0x2014, ':', ',', '.', ' '))
        if (-not $AllowNoneWithReason -or $rest.Length -lt 3) {
            return [pscustomobject]@{ Present = $true; Value = $trimmed; Substantive = $false; Reason = 'none-without-reason' }
        }
    }
    return [pscustomobject]@{ Present = $true; Value = $trimmed; Substantive = $true; Reason = 'ok' }
}
