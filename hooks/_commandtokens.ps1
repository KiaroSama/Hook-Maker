# Shared COMMAND TOKENIZER: a shell command as DATA - quote-aware tokens,
# separator-token segments and a comparable program name. Nothing here executes,
# evaluates or re-parses a nested shell string.
#
# Moved verbatim out of Test-Run-Guard\_commandanalysis.ps1 so every hook that reads
# a tool command (Test-Run-Guard, Install-Location-Check) tokenizes it the same way.
# Installed runtimes carry a private copy beside each hook script.

# ---- command parsing (data only - nothing here executes anything) ----------

# Quote-aware tokenizer. A quoted run stays ONE token, so an argument holding a
# space, a pipe, an ampersand or a semicolon can never be mistaken for a
# separator or split into two arguments.
function Split-CommandTokens {
    param([string]$Text)
    $tokens = New-Object System.Collections.Generic.List[string]
    # A NEWLINE is a token, because it is a separator. $script:SeparatorTokens
    # has always listed it - but `\S+` cannot match whitespace, so one was
    # never emitted and every line of a multi-line command collapsed into a
    # single segment. The line after a heredoc terminator therefore glued
    # itself to the program that opened the block, and no command written
    # under another could ever be recognised. Ordered last in the
    # alternation, which is safe: `\S+` cannot match a newline anyway.
    foreach ($match in [regex]::Matches($Text, '"([^"]*)"|''([^'']*)''|(\S+)|(\r?\n)')) {
        if ($match.Groups[1].Success) { [void]$tokens.Add($match.Groups[1].Value) }
        elseif ($match.Groups[2].Success) { [void]$tokens.Add($match.Groups[2].Value) }
        elseif ($match.Groups[3].Success) { [void]$tokens.Add($match.Groups[3].Value) }
        else { [void]$tokens.Add("`n") }
    }
    return $tokens.ToArray()
}

# Separator TOKENS only. Because the tokenizer already swallowed quoted runs, a
# '|' inside "-k 'a|b'" is part of a token and cannot split anything here.
#
# Redirections end the command's ARGUMENTS exactly as a pipe does, and they were
# missing: '|' was recognised but '2>&1' was not, so
#   python -m pytest tests/x.py -q 2>&1 | tail -3
# produced ["-m","pytest","tests/x.py","-q","2>&1"] and the replacement this hook
# prints died with `file or directory not found: 2>&1`. Every redirection form
# leaked the same way, operand included: '>' out.txt, '2>' err.txt, '>>' log.txt.
# The runner captures both streams itself, so a shell redirection has nothing to
# express here anyway - dropping it is what makes the suggestion runnable.
# Reported from real use.
$script:SeparatorTokens = @('&&', '||', ';', '|', '&', "`n",
    '>', '>>', '<', '2>', '2>>', '2>&1', '1>', '1>>', '&>', '&>>', '>&', '3>', '*>', '*>&1')

function Split-CommandSegments {
    param([string[]]$Tokens)
    $segments = New-Object System.Collections.Generic.List[object]
    $current = New-Object System.Collections.Generic.List[string]
    foreach ($token in @($Tokens)) {
        if ($script:SeparatorTokens -contains $token) {
            if ($current.Count -gt 0) { [void]$segments.Add($current.ToArray()) }
            $current = New-Object System.Collections.Generic.List[string]
            continue
        }
        [void]$current.Add($token)
    }
    if ($current.Count -gt 0) { [void]$segments.Add($current.ToArray()) }
    return $segments.ToArray()
}

# Comparable program name: last path segment, launcher extension removed.
# '.\scripts\Run-Tests.ps1' -> 'run-tests.ps1', 'C:\bin\pytest.exe' -> 'pytest'.
function Get-ProgramName {
    param([string]$Token)
    $name = $Token.Replace('/', '\')
    $slash = $name.LastIndexOf('\')
    if ($slash -ge 0) { $name = $name.Substring($slash + 1) }
    $name = $name.ToLowerInvariant()
    foreach ($extension in @('.exe', '.cmd', '.bat', '.com')) {
        if ($name.EndsWith($extension)) { return $name.Substring(0, $name.Length - $extension.Length) }
    }
    return $name
}
