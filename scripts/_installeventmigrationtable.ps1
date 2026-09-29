# The versioned table of RETIRED DEFAULT event bindings, read by
# _installeventmigration.ps1 (which dot-sources this file). Data only: the
# matching, the preconditions and the migration itself live there.

# ---- the versioned migration table ----------------------------------------
#
# One entry per RETIRED DEFAULT binding. `From` is matched as an exact set
# (case-insensitive, order-insensitive) against a client's recorded events; a
# record that matches nothing here is left alone. There is no `To`: the
# destination is always whatever Get-HookRecommendedEvents reports right now,
# so this table can never disagree with the shipped default.
#
# Version is the migration id and is unique. It is reported and logged so a run
# can be named ("event-binding migration v1"), and so a future retirement of a
# different set for the same hook is a NEW entry rather than an edit to this
# one - an edited entry would silently reclassify installs it already moved.
#
# Adding an entry requires evidence that the `From` set really was a SHIPPED
# DEFAULT, not merely a plausible one: a set a user chose by hand is a custom
# binding and must stay in the "report, do not rewrite" path.
$script:InstalledEventMigrations = @(
    [pscustomobject]@{
        Version = 1
        Hook    = 'Session-Summary-Check'
        From    = @('Stop', 'SubagentStop')
        Reason  = 'the retired closing-only default; it never delivers the pre-task summary requirement'
    }
    [pscustomobject]@{
        Version = 2
        Hook    = 'Session-Summary-Check'
        From    = @('SessionStart', 'UserPromptSubmit')
        Reason  = 'the prior shipped default delivered policy but never invoked the silent publication observer'
    }
    [pscustomobject]@{
        Version = 3
        Hook    = 'Git-Sync-Check'
        From    = @('SessionStart', 'Stop', 'SubagentStop')
        Reason  = 'the prior shipped default had no PreToolUse, so the side-branch and push-once reminders never ran'
    }
    # v4-v8: the pre-2026-09-07 shipped defaults (.env.example EVENTS before a5aeac4;
    # Utf8-Encoding-Check's metadata Events before 40edad7). Each binding never runs the
    # Stop/SubagentStop half the hook gained later, with no error and no output.
    [pscustomobject]@{
        Version = 4
        Hook    = 'Skills-Check'
        From    = @('SessionStart', 'UserPromptSubmit', 'Stop')
        Reason  = 'the prior shipped default had no SubagentStop, so a subagent closing never named the skills it used'
    }
    [pscustomobject]@{
        Version = 5
        Hook    = 'Rules-Check'
        From    = @('SessionStart', 'UserPromptSubmit')
        Reason  = 'the prior shipped default had no Stop, so the closing rules confirmation never ran'
    }
    [pscustomobject]@{
        Version = 6
        Hook    = 'Mcp-Usage-Check'
        From    = @('SessionStart', 'UserPromptSubmit')
        Reason  = 'the prior shipped default had no Stop, so the closing MCP used line was never checked'
    }
    [pscustomobject]@{
        Version = 7
        Hook    = 'Dependency-Version-Check'
        From    = @('SessionStart', 'UserPromptSubmit')
        Reason  = 'the prior shipped default had no Stop, so an unanswered finding was never checked at the end'
    }
    [pscustomobject]@{
        Version = 8
        Hook    = 'Utf8-Encoding-Check'
        From    = @('SessionStart', 'Stop')
        Reason  = 'the prior shipped default had no SubagentStop, so subagent edits were never validated'
    }
    # v9: the 2026-09-29 default gained UserPromptSubmit for one mid-session note.
    [pscustomobject]@{
        Version = 9
        Hook    = 'Synapse-Rules-Check'
        From    = @('SessionStart', 'Stop', 'SubagentStop')
        Reason  = 'the prior shipped default had no UserPromptSubmit, so the once-per-session mid-session reminder never reached the agent'
    }
)
