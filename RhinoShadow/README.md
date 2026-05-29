# RhinoShadow v1.69

A PowerShell WinForms RDS session manager built for MSP / multi-tenant
Active Directory layouts. Forked from "Shadow User" (original by the team).

The primary workflow this is optimised for: "User X just called for help.
Which RDS server are they on? Which PC are they connecting from? Sign them
out or shadow them." Designed to make that three clicks or fewer.

## What changed in this release (v0.69 → v1.69)

Substantial cleanup-and-feature pass over a week of testing and bug
fixing against the live environment.

### New features

- **Local Computer column** in the sessions grid, showing the hostname of
  the workstation each user is connecting FROM. Looked up via the WTS API
  (Wtsapi32.dll) at query time - no module dependency. Lets the operator
  spot the right workstation for RMM handoffs without manual lookups.
- **Background async sign-out**. logoff.exe runs in a runspace, polled
  every 200ms by a WinForms Timer. The form stays responsive during the
  wait, FormClosing actually fires if the user clicks X mid-action.
- **Post-action sign-out verification**. After logoff.exe returns we
  re-query the server with quser. If the session is still present, we
  log an explicit error rather than the false-positive OK that the
  Server 2019 silent-fail case would otherwise produce.
- **Action-in-flight close guard**. Closing the form while a destructive
  action is running triggers a Yes/No confirmation. Confirmed close
  writes an "ABANDONED" line to the activity log. Active timers are
  tracked and stopped on close-anyway so they don't tick against a
  disposed form.
- **Large-search confirmation modal**. Unscoped Find with 30+ servers
  shows a Yes/No prompt to catch the "forgot to set scope" mistake.
- **MSP dual-root config**. Separate `$script:clientRoot` (tenant tree
  where user accounts live) and `$script:rdsServerRoot` (server tree
  where RDS hosts live), joined by client OU name. Single-tenant setups
  point both at the same OU.
- **Custom themed message dialog** replacing the VB InputBox - constrained
  to 255 chars with a live character counter, multi-line input, theme-
  aware styling, Send / Cancel buttons.
- **Clear button on the filter textbox** in the Sessions section.
- **Clear button on the client dropdown** (renamed from misleading "All").
- **stderr capture for logoff.exe and msg.exe failures**. Previously a
  bare "exit code 1" was logged - now the actual Windows error message
  ("Access is denied", "RPC server is unavailable", etc) is captured
  via RedirectStandardError and surfaced in the activity log.
- **Help dialog shows the current AD config values** rather than the
  variable names. The here-string is intentionally expanding so each
  deployment sees its own configured roots without having to scroll
  back up to Section 4.
- **Selected server names in Browse log line** instead of just a count.
- **ClientName in destructive action audit logs**: Sign Out, Shadow, and
  Send Message lines now include " from <workstation>" when known.
- **Two-line message logging** so 255-char message bodies don't crowd
  the issue line off-screen.

### Bug fixes (in roughly chronological discovery order)

1. **`$pId` case-folded to read-only `$PID` automatic variable**. PowerShell
   variable names are case-insensitive. `$pId` and `$PID` are the same
   variable; `$PID` is a read-only process-ID automatic. Assignment threw
   "Cannot overwrite variable PID..." inside the runspace, every quser
   query failed silently as an ERROR row. Renamed to `$pIdAt` with a
   sticky warning comment in both copies of the parser.
2. **LDAP filter escape order in `Resolve-RhinoUsernames`**. Paren / star
   escapes ran BEFORE backslash escape, so the `\` we added for `\28`
   got re-escaped to `\5c28` on any input containing parens, stars, or
   backslashes. Searches for names like `O'Brien (Bob)` silently returned
   wrong results. Fixed by escaping backslash first.
3. **`$matches` autovar shadowing** in Find-UserEverywhere. Local variable
   named `$matches` shadowed PowerShell's automatic `$Matches` populated
   by `-match` operators. Renamed to `$hits`.
4. **Runspace pool leak on dispatch exception**. The `foreach` dispatch
   loop in `Get-RhinoSessions` had no try/finally - a `[powershell]::Create()`
   failure mid-loop would leak the pool and already-created pipes.
   Wrapped the whole dispatch+collect block.
5. **Get-UPNMap LDAP filter length cap**. Building one giant
   `(|(sAMAccountName=a)(sAMAccountName=b)...)` filter could overflow on
   large result sets. Chunked to 100 SAMs per query with proper escaping.
6. **Server 2019 logoff.exe silent-success failures**. logoff.exe can
   return 0 even when it didn't actually sign anyone out. Added the
   re-query verification (see Features above).
7. **ERROR-row hazard in Get-SelectedSession**. Action buttons would
   happily try to act on a server-query-failure ERROR marker row,
   passing empty SessionID to logoff.exe - which can target the WRONG
   session. Now explicitly rejected with a user-visible warning.
8. **`[array]::Reverse()` scalar-unwrap crash** in the prior breadcrumb
   code path (since removed). PowerShell unwraps single-element slices
   to bare scalars; `[array]::Reverse($scalar)` throws.
9. **Mouse cursor disappearance** over the client dropdown. Caused by
   `$this.DroppedDown = $true` inside a focus event handler - documented
   WinForms quirk. Removed; native AutoCompleteMode.SuggestAppend covers
   the use case correctly.
10. **Browse panel not loading servers**. Caused by wiring to
    SelectionChangeCommitted which doesn't fire when AutoComplete commits
    a suggestion. Switched to SelectedIndexChanged + Leave.
11. **Find-in-Client button text not updating** on scope dropdown change.
    Same SelectionChangeCommitted-vs-SelectedIndexChanged issue.
12. **Servers not auto-ticking** in the Browse checklist. `CheckedListBox.Items.Add($item, $true)`
    is documented but unreliable when `CheckOnClick = $true`. Switched
    to add-then-`SetItemChecked()`.
13. **AD SearchResultCollection leaks** on exception. All four AD-query
    functions had their `.Dispose()` calls inline in the try block; any
    exception during result iteration leaked COM resources. All wrapped
    in finally blocks now.
14. **GDI Pen leak** in headerPanel.Paint. Pen disposed inline; an
    exception during DrawLine would leak the handle per repaint.
    Wrapped in try/finally.
15. **Filter / dropdown `-like` wildcard interpretation**. `*` and `?`
    in user-typed filter text were being interpreted as wildcards.
    Switched to `.Contains()` for literal matching.
16. **Quser parser brittle to non-en-US locales and long usernames**.
    Hardcoded substring offsets (1, 23, 41, 46, 54, 65) broke on
    non-default column widths. Now reads the header row, finds each
    column header's start position, slices accordingly. Falls back to
    en-US fixed offsets if header parsing fails so behaviour is never
    worse than before.
17. **Get-RhinoOUs returning 87 entries** when there should be ~20. The
    earlier subtree-walk picked up every nested OU inside every client's
    internal tree (Users/Computers/Groups/etc). Reverted to OneLevel,
    paired with the new dual-root config so the dropdown shows clients
    and Get-RhinoServerOuForClient does cross-tree name matching for
    the server lookup.
18. **Case-sensitive UPN map lookups**. The `$upnMap` hashtable was
    case-sensitive by default; quser case variants would miss UPN lookup.
    Both hashtables now use `[StringComparer]::OrdinalIgnoreCase`.
19. **UI thread blocked during logoff.exe**. Synchronous `Start-Process -Wait`
    blocked the message pump, so FormClosing couldn't fire mid-action
    and Windows marked the form as "Not Responding" forcing the user
    into the force-close path. Sign Out now runs in a background
    runspace with a UI timer polling for completion - the form stays
    interactive for the duration.
20. **Bare exit codes for logoff/msg failures**. logoff.exe and msg.exe
    return 1 for almost every failure mode (permissions, RPC, session
    state, etc) which gave no useful diagnostic info. Both now capture
    stderr via `-RedirectStandardError` to a temp file and include the
    human-readable error in the activity log.

### Architectural / commenting work

- **`New-RhinoButton` helper** replacing 11 button-construction sites of
  6-7 lines each. Takes text, position, size, role, parent, and optional
  click handler in one call.
- **Every function has a function-level comment block** explaining purpose,
  design choices, failure modes, and key gotchas. The file is for code
  review - reviewers should be able to read each function header and
  understand WHY it was written that way without spelunking the body.
- **Identifying info scrubbed** from comments and examples. The
  `$script:clientRoot` and `$script:rdsServerRoot` strings are the only
  domain-specific values left, and they're in a clearly marked
  CONFIGURATION banner block at the top of Section 4.

## Configuration

Edit two lines at the top of Section 4 (look for the `>>>` markers):

```powershell
$script:clientRoot    = "OU=...your tenant tree...,DC=...,DC=..."
$script:rdsServerRoot = "OU=...your RDS server tree...,DC=...,DC=..."
```

Single-tenant setups: set both to the same OU. MSP / multi-tenant setups:
set them to the two parallel trees that share matching client OU names.

## Logs

- Activity log: `%LOCALAPPDATA%\Temp\RhinoShadow.log` - every action
  with timestamps, session start/end markers, audit trail of destructive
  actions including message bodies and target workstations.
- Crash log: `%LOCALAPPDATA%\Temp\RhinoShadow_crash.log` - startup
  crashes that bypass the form-level error handling. Written only on
  actual crash; not present in normal operation.

## Known remaining behaviours

- **Shadow is fire-and-forget**. Invoke-Shadow launches mstsc.exe and
  immediately returns. mstsc's own failures (e.g. "session is already
  being shadowed") appear in mstsc's own dialog, NOT in RhinoShadow's
  activity log. Documented this way intentionally - mstsc is an
  interactive GUI tool with its own error reporting.
- **Send Message runs msg.exe synchronously** (UI blocks briefly). msg.exe
  is short-lived enough not to need the async pattern Sign Out uses.
- **AD layout assumption**: scoped user search assumes user accounts
  live inside their client's tenant OU (or a child of it). If your AD
  has users in a separate tree from the client OUs the dropdown shows,
  the scoped search returns empty and we fall back to wildcard matching
  on raw quser usernames - works but loses UPN enrichment.
- **quser parser fallback is en-US column positions**. Non-English
  Windows Server RDS hosts should still work as long as the header line
  is parseable; keyword detection covers German, French, and Spanish.
