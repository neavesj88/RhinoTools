<#
================================================================================
  RhinoShadow v1.0 - RDS Session Manager (fork of "Shadow User")
================================================================================

.SYNOPSIS
    A polished WinForms GUI for finding and managing user sessions across
    Remote Desktop Services (RDS) servers in Active Directory.

.DESCRIPTION
    A modern reimagining of the original Shadow User script. The primary
    workflow this is optimised for: "User X just called me. Which RDS server
    are they on? Sign their session out." Everything in the UI is arranged
    to make that flow take three clicks or fewer.

    Features:
      - Quick Find: type a username, instantly searches every RDS server
        across every client OU in parallel (runspace pool, NOT sequential).
      - Browse by OU: traditional client OU -> server-list -> sessions flow.
      - Sessions grid: Username / State / Idle / Logon / Server / Session ID,
        with click-to-sort headers and a live filter textbox.
      - Robust session parsing: correctly handles "Disc" (disconnected)
        sessions where the SESSIONNAME column is blank, which the original
        script silently dropped.
      - Action buttons: Shadow (mstsc /shadow /control), Sign Out (logoff),
        Send Message (msg *), Refresh.
      - Status log with timestamps - mirrors the RhinoCopy pattern so you
        can see exactly which servers were queried and what came back.
      - Light / dark theme toggle (dark by default).
      - Rhino mascot easter egg with escalating moods.
      - Crash log to %TEMP%\RhinoShadow_crash.log so failures aren't silent
        when launched with -WindowStyle Hidden.

.AUTHOR
    Jared Neaves - forked from "Shadow User" (original by the team).

.CODE STRUCTURE
    1.  Assembly imports + WinForms bootstrap
    2.  Theme palettes (dark + light) + font definitions
    3.  Theme helpers (Register-Themed, Apply-ButtonTheme, Apply-Theme)
    4.  Script-level state + path resolution + crash log path + config
    5.  AD / RDS query functions (no UI):
        5a. Get-RhinoOUs          - list immediate child OUs of an LDAP path
        5b. Get-RhinoServers      - list computer objects in one OU
        5c. Get-AllRhinoServers   - enumerate every server across every OU
        5d. Parse-QuserLine       - robust parser for one line of `query user`
        5e. Get-RhinoSessions     - parallel session query via runspace pool
    6.  Form build (inside the outer try block):
        6a. Form shell + FormClosing handler + icon
        6b. Header panel - mascot, title, subtitle, theme + help buttons
        6c. Mascot click easter egg
        6d. Quick Find panel - search box + Find Everywhere button
        6e. Browse by OU panel - OU dropdown + server checklist + Show button
        6f. Sessions grid + filter textbox + count label
        6g. Action buttons (Shadow / Sign Out / Send Message / Refresh)
        6h. Status log textbox
        6i. Worker functions: Write-RhinoLog, Find-UserEverywhere,
            Show-SessionsForSelectedServers, Invoke-Shadow, Invoke-SignOut,
            Invoke-SendMessage, Refresh-Grid, Apply-SessionFilter
        6j. Help dialog (Show-RhinoHelp)
        6k. ShowDialog (modal blocking call)
    7.  Outer catch block - logs any startup crash to %TEMP%

.NOTES
    - The parallel server query uses a runspace pool (1..15 threads). This is
      genuinely the killer feature - sequential queries against ~30 RDS
      servers can take 30+ seconds, parallel completes in ~2-3s.
    - The AD root is hardcoded to OU=RDS Servers,OU=Servers,DC=focusnet,
      DC=net,DC=au - matches the original. Update $script:adRoot if the
      domain changes.
    - Servers matching "*sh77*" are filtered out (legacy behaviour from the
      original - kept because that's what the team is used to).
================================================================================
#>


# ==============================================================================
# SECTION 1 - Assembly imports + WinForms bootstrap
# ==============================================================================
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.DirectoryServices
[System.Windows.Forms.Application]::EnableVisualStyles()
# Must run before any Form is created. Wrapped in try/catch because if the
# script is re-run in the same PowerShell session after a form was already
# created, this API throws "DefaultCompatibleTextRenderingDefault has been
# called already".
try { [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false) } catch { }


# ==============================================================================
# SECTION 2 - Theme palettes + fonts
# ==============================================================================
# Two complete palettes, one active at a time. The active palette is mirrored
# into $script:t for terse access throughout the build. Every colour used in
# the UI comes from these two palettes - nothing is hardcoded downstream.
#
# Colour philosophy:
#   Bg          - app background (darkest in dark mode, lightest in light)
#   Surface     - cards / inputs / grid cells - one step up from Bg
#   SurfaceAlt  - alternating row, hover states - one step up from Surface
#   Border      - thin separators around panels and inputs
#   Text        - primary readable text
#   Muted       - secondary text (timestamps, hints, counts)
#   Accent      - primary action colour (shadow / search / theme buttons)
#   Success     - constructive (refresh / send message)
#   Danger      - destructive (sign out)
#   Warning     - amber, used for "no results" / idle warnings
$script:themes = @{
    dark = @{
        Bg         = [System.Drawing.Color]::FromArgb(24, 26, 31)
        Surface    = [System.Drawing.Color]::FromArgb(34, 37, 44)
        SurfaceAlt = [System.Drawing.Color]::FromArgb(42, 46, 54)
        Border     = [System.Drawing.Color]::FromArgb(58, 63, 73)
        Text       = [System.Drawing.Color]::FromArgb(230, 233, 238)
        Muted      = [System.Drawing.Color]::FromArgb(148, 156, 168)
        Accent     = [System.Drawing.Color]::FromArgb(96, 165, 250)
        AccentHov  = [System.Drawing.Color]::FromArgb(59, 130, 246)
        Success    = [System.Drawing.Color]::FromArgb(52, 168, 97)
        SuccessHov = [System.Drawing.Color]::FromArgb(40, 140, 78)
        Danger     = [System.Drawing.Color]::FromArgb(239, 83, 99)
        DangerHov  = [System.Drawing.Color]::FromArgb(210, 60, 75)
        Warning    = [System.Drawing.Color]::FromArgb(245, 158, 66)
    }
    light = @{
        Bg         = [System.Drawing.Color]::FromArgb(245, 246, 248)
        Surface    = [System.Drawing.Color]::White
        SurfaceAlt = [System.Drawing.Color]::FromArgb(237, 240, 245)
        Border     = [System.Drawing.Color]::FromArgb(215, 218, 224)
        Text       = [System.Drawing.Color]::FromArgb(32, 37, 46)
        Muted      = [System.Drawing.Color]::FromArgb(110, 118, 129)
        Accent     = [System.Drawing.Color]::FromArgb(37, 99, 235)
        AccentHov  = [System.Drawing.Color]::FromArgb(29, 78, 216)
        Success    = [System.Drawing.Color]::FromArgb(34, 139, 78)
        SuccessHov = [System.Drawing.Color]::FromArgb(27, 112, 62)
        Danger     = [System.Drawing.Color]::FromArgb(220, 53, 69)
        DangerHov  = [System.Drawing.Color]::FromArgb(185, 40, 55)
        Warning    = [System.Drawing.Color]::FromArgb(217, 119, 6)
    }
}
$script:currentTheme = "dark"
$script:t = $script:themes[$script:currentTheme]

# Fonts - pre-created at script scope so every control reuses the same Font
# object (cheaper, consistent rendering). Segoe UI is the Windows system
# font; Consolas is monospace for the status log and grid (used for IDs).
$fontRegular  = New-Object System.Drawing.Font("Segoe UI", 10)
$fontSemibold = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
$fontTitle    = New-Object System.Drawing.Font("Segoe UI Semibold", 18)
$fontSubtitle = New-Object System.Drawing.Font("Segoe UI", 9)
$fontHeader   = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
$fontMono     = New-Object System.Drawing.Font("Consolas", 9.5)


# ==============================================================================
# SECTION 3 - Theme helpers
# ==============================================================================
# Same pattern as RhinoCopy:
#   1. Every theme-aware control is "registered" with a semantic role string
#      ("surface", "input", "btn-success", etc.) when it is built.
#   2. Initial colours are set explicitly using $script:t at build time so the
#      first paint is correct without needing Apply-Theme.
#   3. Apply-Theme walks the registered list and recolours every control
#      from the new palette when the user toggles light/dark.
#
# This is conceptually a CSS-class system - the role is the class name, the
# two palettes are two stylesheets, and Apply-Theme is the "swap stylesheet"
# operation.

$script:themedControls = @()

# Tag a control with a semantic role. Using += rebinds the array (instead of
# .Add() which would mutate and emit to the pipeline).
function Register-Themed {
    param($Control, [string]$Role)
    $script:themedControls += @{ Control = $Control; Role = $Role }
}

# Apply a button role to a single Button. Called both at build time and on
# theme toggle. We use FlatStyle = Flat so the OS chrome doesn't override
# our BackColor / hover colours - "System" style ignores them.
#
# Roles:
#   btn-accent   - Blue, white text. Primary actions (Shadow, Find).
#   btn-success  - Green, white text. Constructive (Refresh, Show Users).
#   btn-danger   - Red, white text. Destructive (Sign Out).
#   btn-neutral  - Plain surface. Browse, Theme toggle, Help, etc.
#   btn-help     - Subtle background, accent text. Small "?" header buttons.
function Apply-ButtonTheme {
    param($Button, [string]$Role)
    $t = $script:t
    $Button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $Button.FlatAppearance.BorderSize = 1
    $Button.Cursor = [System.Windows.Forms.Cursors]::Hand
    $Button.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    switch ($Role) {
        "btn-success" { $Button.BackColor = $t.Success; $Button.ForeColor = [System.Drawing.Color]::White; $Button.FlatAppearance.BorderColor = $t.Success; $Button.FlatAppearance.MouseOverBackColor = $t.SuccessHov; $Button.FlatAppearance.MouseDownBackColor = $t.SuccessHov; $Button.Font = $fontSemibold }
        "btn-accent"  { $Button.BackColor = $t.Accent;  $Button.ForeColor = [System.Drawing.Color]::White; $Button.FlatAppearance.BorderColor = $t.Accent;  $Button.FlatAppearance.MouseOverBackColor = $t.AccentHov;  $Button.FlatAppearance.MouseDownBackColor = $t.AccentHov;  $Button.Font = $fontSemibold }
        "btn-danger"  { $Button.BackColor = $t.Danger;  $Button.ForeColor = [System.Drawing.Color]::White; $Button.FlatAppearance.BorderColor = $t.Danger;  $Button.FlatAppearance.MouseOverBackColor = $t.DangerHov;  $Button.FlatAppearance.MouseDownBackColor = $t.DangerHov;  $Button.Font = $fontSemibold }
        "btn-help"    { $Button.BackColor = $t.SurfaceAlt; $Button.ForeColor = $t.Accent; $Button.FlatAppearance.BorderColor = $t.Border; $Button.FlatAppearance.MouseOverBackColor = $t.Surface; $Button.FlatAppearance.MouseDownBackColor = $t.Border; $Button.Font = $fontSemibold }
        default       { $Button.BackColor = $t.Surface; $Button.ForeColor = $t.Text; $Button.FlatAppearance.BorderColor = $t.Border; $Button.FlatAppearance.MouseOverBackColor = $t.SurfaceAlt; $Button.FlatAppearance.MouseDownBackColor = $t.Border; $Button.Font = $fontRegular }
    }
}

# Walk every registered control and repaint it. Each assignment is wrapped
# in try/catch so one bad control (e.g. disposed handle) doesn't abort the
# whole loop and leave the form in a half-themed state.
function Apply-Theme {
    $t = $script:t
    if ($form) { $form.BackColor = $t.Bg; $form.ForeColor = $t.Text }
    foreach ($entry in $script:themedControls) {
        try {
            $c = $entry.Control
            switch ($entry.Role) {
                "form"        { $c.BackColor = $t.Bg;      $c.ForeColor = $t.Text }
                "surface"     { $c.BackColor = $t.Surface; $c.ForeColor = $t.Text }
                "muted"       { $c.BackColor = $t.Bg;      $c.ForeColor = $t.Muted }
                "muted-surf"  { $c.BackColor = $t.Surface; $c.ForeColor = $t.Muted }
                "header"      { $c.BackColor = $t.Surface; $c.ForeColor = $t.Text }
                "input"       { $c.BackColor = $t.Surface; $c.ForeColor = $t.Text }
                "log"         { $c.BackColor = $t.Surface; $c.ForeColor = $t.Text }
                "groupbox"    { $c.BackColor = $t.Bg;      $c.ForeColor = $t.Text }
                "checkbox"    { $c.BackColor = $t.Surface; $c.ForeColor = $t.Text }
                "label-body"  { $c.BackColor = $t.Bg;      $c.ForeColor = $t.Text }
                "label-surf"  { $c.BackColor = $t.Surface; $c.ForeColor = $t.Text }
                "grid" {
                    # The DataGridView has many sub-properties that each
                    # need their own palette colours. Set them all together
                    # so a theme swap looks right in one go.
                    $c.BackgroundColor = $t.Surface
                    $c.GridColor = $t.Border
                    $c.DefaultCellStyle.BackColor = $t.Surface
                    $c.DefaultCellStyle.ForeColor = $t.Text
                    $c.DefaultCellStyle.SelectionBackColor = $t.Accent
                    $c.DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::White
                    $c.AlternatingRowsDefaultCellStyle.BackColor = $t.SurfaceAlt
                    $c.AlternatingRowsDefaultCellStyle.ForeColor = $t.Text
                    $c.ColumnHeadersDefaultCellStyle.BackColor = $t.SurfaceAlt
                    $c.ColumnHeadersDefaultCellStyle.ForeColor = $t.Text
                    $c.ColumnHeadersDefaultCellStyle.SelectionBackColor = $t.SurfaceAlt
                    $c.EnableHeadersVisualStyles = $false
                    $c.RowHeadersDefaultCellStyle.BackColor = $t.Surface
                    $c.RowHeadersDefaultCellStyle.ForeColor = $t.Text
                }
                "btn-accent"  { Apply-ButtonTheme -Button $c -Role "btn-accent" }
                "btn-success" { Apply-ButtonTheme -Button $c -Role "btn-success" }
                "btn-danger"  { Apply-ButtonTheme -Button $c -Role "btn-danger" }
                "btn-help"    { Apply-ButtonTheme -Button $c -Role "btn-help" }
                "btn-neutral" { Apply-ButtonTheme -Button $c -Role "btn-neutral" }
            }
        } catch { }
    }
    if ($headerPanel) { try { $headerPanel.Invalidate() } catch { } }
}


# ==============================================================================
# SECTION 4 - Script-level state + paths + config
# ==============================================================================
# AD root for the RDS Servers OU. All OU enumeration starts here. If the
# domain ever changes, this is the one constant to update.
$script:adRoot = "OU=RDS Servers,OU=Servers,DC=focusnet,DC=net,DC=au"

# Legacy filter from the original Shadow User: servers whose name contains
# "sh77" are hidden. Kept for muscle-memory compatibility - the team is
# used to them not appearing.
$script:serverExcludePattern = "*sh77*"

# Domain root for user searches - derived from adRoot by stripping the OU
# components and keeping only the DC parts. Used by Resolve-RhinoUsernames
# to search the whole directory for matching accounts.
$script:domainRoot = ($script:adRoot -split ',' | Where-Object { $_ -match '^DC=' }) -join ','

# Cache of "all servers across all OUs". Populated on first Quick Find so
# we don't re-enumerate AD every search. Null = not yet populated.
$script:allServersCache = $null

# Currently displayed sessions (raw - the grid is filtered from this).
# Each item is a PSObject with Username/SessionID/State/IdleTime/LogonTime/Server.
$script:currentSessions = @()

# Resolve the script's directory in a launch-context-tolerant way (matches
# the RhinoCopy pattern). Needed to find Rhino.png and the .ico relative to
# the script regardless of how it was launched.
$scriptPath = if ($PSScriptRoot) { $PSScriptRoot }
              elseif ($PSCommandPath) { Split-Path -Parent $PSCommandPath }
              elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path }
              else { (Get-Location).Path }
$iconPath  = Join-Path $scriptPath "RhinoShadow.ico"
$mascotPath = Join-Path $scriptPath "Rhino.png"

# Crash log path. Critical for debugging when the script is launched with
# -WindowStyle Hidden (no console = silent failures otherwise).
$crashLog = Join-Path $env:TEMP "RhinoShadow_crash.log"


# ==============================================================================
# SECTION 5 - AD / RDS query functions (no UI)
# ==============================================================================

# 5a - Get-RhinoOUs
# -----------------
# List immediate child OUs of an LDAP path. SearchScope=OneLevel keeps it
# from recursing into nested OUs (we only want the client list, not every
# OU under every client).
function Get-RhinoOUs {
    param([string]$adPath)
    $ouList = @()
    try {
        $entry = New-Object System.DirectoryServices.DirectoryEntry("LDAP://" + $adPath)
        $searcher = New-Object System.DirectoryServices.DirectorySearcher($entry)
        $searcher.Filter = '(objectClass=organizationalUnit)'
        $searcher.SearchScope = [System.DirectoryServices.SearchScope]::OneLevel
        $result = $searcher.FindAll()
        foreach ($obj in $result) { $ouList += $obj.Properties['name'][0] }
        $result.Dispose(); $searcher.Dispose(); $entry.Dispose()
    } catch {
        # Surface the error in the status log if it's available; otherwise
        # swallow silently and return an empty list. The caller decides what
        # to do with an empty list.
        if (Get-Command Write-RhinoLog -ErrorAction SilentlyContinue) {
            Write-RhinoLog "AD error enumerating OUs: $_" "error"
        }
    }
    return $ouList
}

# 5b - Get-RhinoServers
# ---------------------
# List computer objects (servers) under one OU. Default SearchScope is
# Subtree which is what we want - some clients have their RDS hosts nested
# one more level deep.
function Get-RhinoServers {
    param([string]$adPath)
    $serverList = @()
    try {
        $entry = New-Object System.DirectoryServices.DirectoryEntry("LDAP://" + $adPath)
        $searcher = New-Object System.DirectoryServices.DirectorySearcher($entry)
        $searcher.Filter = '(objectClass=computer)'
        $result = $searcher.FindAll()
        foreach ($obj in $result) { $serverList += $obj.Properties['name'][0] }
        $result.Dispose(); $searcher.Dispose(); $entry.Dispose()
    } catch {
        if (Get-Command Write-RhinoLog -ErrorAction SilentlyContinue) {
            Write-RhinoLog "AD error enumerating servers in '$adPath': $_" "error"
        }
    }
    # Apply the legacy exclusion. -notlike returns true for non-matches.
    return $serverList | Where-Object { $_ -notlike $script:serverExcludePattern }
}

# 5c - Get-AllRhinoServers
# ------------------------
# Walk every client OU and gather every server. Result is cached in
# $script:allServersCache - on subsequent calls we just return the cache.
# Pass -Force to refresh the cache (used by the Refresh button when in
# "Quick Find" mode).
function Get-AllRhinoServers {
    param([switch]$Force)
    if ($script:allServersCache -and -not $Force) {
        return $script:allServersCache
    }
    $all = @()
    $ous = Get-RhinoOUs $script:adRoot
    foreach ($ou in $ous) {
        $ouPath = "OU=$ou,$script:adRoot"
        $servers = Get-RhinoServers $ouPath
        foreach ($s in $servers) { $all += $s }
    }
    # Deduplicate in case a server is somehow in two OUs, and sort so the
    # log output reads nicely.
    $script:allServersCache = $all | Sort-Object -Unique
    return $script:allServersCache
}

# 5d - Resolve-RhinoUsernames
# ----------------------------
# Given a freetext search term, query AD for matching user accounts and
# return their SAM account names. Searches across:
#   - sAMAccountName  (login name, e.g. rdisilvio_mpm)
#   - displayName     (e.g. "Rose Di Silvio")
#   - givenName       (first name)
#   - sn              (surname)
#   - userPrincipalName (UPN prefix, e.g. rdisilvio_mpm@focusnet.net.au)
#
# Returns an array of sAMAccountName strings. If AD is unreachable or the
# search fails, returns an empty array so the caller falls back to raw
# username matching.
function Resolve-RhinoUsernames {
    param([string]$term)
    $samNames = @()
    try {
        $entry = New-Object System.DirectoryServices.DirectoryEntry("LDAP://" + $script:domainRoot)
        $searcher = New-Object System.DirectoryServices.DirectorySearcher($entry)
        # OR filter across all name-like attributes. Wildcards on both sides
        # so "rose" matches "Alex Rose", "rdisilvio", "Rose Di Silvio", etc.
        $escaped = $term -replace '\(','\\28' -replace '\)','\\29' -replace '\\','\\5c' -replace '\*','\\2a'
        $searcher.Filter = "(|" +
            "(sAMAccountName=*$escaped*)" +
            "(displayName=*$escaped*)" +
            "(givenName=*$escaped*)" +
            "(sn=*$escaped*)" +
            "(userPrincipalName=*$escaped*)" +
            ")"
        $searcher.SearchScope = [System.DirectoryServices.SearchScope]::Subtree
        $searcher.PropertiesToLoad.Add("sAMAccountName") | Out-Null
        $searcher.SizeLimit = 200
        $result = $searcher.FindAll()
        foreach ($obj in $result) {
            $sam = $obj.Properties['sAMAccountName']
            if ($sam -and $sam.Count -gt 0) { $samNames += $sam[0].ToString() }
        }
        $result.Dispose(); $searcher.Dispose(); $entry.Dispose()
    } catch {
        if (Get-Command Write-RhinoLog -ErrorAction SilentlyContinue) {
            Write-RhinoLog "AD user lookup failed, falling back to raw match: $_" "warn"
        }
    }
    return $samNames
}

# 5e - Parse-QuserLine  (was 5d)
# --------------------
# Parse a single line of `query user` output into a session object.
# Returns $null for header lines / blank lines / unparseable lines.
#
# WHY THIS FUNCTION EXISTS:
# The original Shadow User script used `-split '\s+', 7` and skipped any
# line that didn't produce 7 fields. This silently dropped DISCONNECTED
# sessions, because a disconnected session has no SESSIONNAME, so the
# split produces 6 fields instead of 7. Disconnected sessions are exactly
# the ones the IT team needs to find and log off, so missing them was a
# real bug.
#
# Here we parse with a TOKEN-BASED REGEX. The previous version used fixed
# Substring() column positions, but quser's column widths drift slightly
# between Windows Server versions and locales - a 1-character shift was
# enough to extract "Active" into the SessionID slot, which then caused
# `logoff` to silently fail with "no such session". The regex below anchors
# on two things that are stable regardless of column widths:
#   - STATE is one of a known keyword set (Active, Disc, Listen, ...)
#   - SessionID is always pure digits
# The optional SESSIONNAME group + regex backtracking handles the gap that
# Disconnected sessions leave.
#
#  USERNAME              SESSIONNAME        ID  STATE   IDLE TIME  LOGON TIME
# >jneaves               rdp-tcp#1           5  Active        .   11/21 9:00 AM
#  bobsmith                                  7  Disc       1:23   11/21 8:45 AM
#
# Returns $null for header / blank / unparseable lines.
function Parse-QuserLine {
    param([string]$line, [string]$server)
    if ([string]::IsNullOrWhiteSpace($line)) { return $null }
    if ($line -match '^\s*USERNAME') { return $null }
    # ">" prefix marks the current console user. Strip it so the regex
    # doesn't have to know about it.
    $isCurrent = $line -match '^\s*>'
    $work = $line -replace '^\s*>\s*', ''
    # Anchors on STATE being a known keyword + ID being pure digits.
    # The optional (?:\s+(?<session>\S+))? handles both Active sessions
    # (SESSIONNAME present) and Disc ones (SESSIONNAME blank) via backtrack.
    $pattern = '^\s*(?<user>\S+)(?:\s+(?<session>\S+))?\s+(?<id>\d+)\s+(?<state>Active|Disc|Listen|Conn|ConnQ|Shadow|Reset|Down|Init|Idle)\s+(?<idle>\S+)\s+(?<logon>.+?)\s*$'
    if ($work -notmatch $pattern) { return $null }
    return [PSCustomObject]@{
        Username    = $Matches['user']
        SessionName = if ($Matches['session']) { $Matches['session'] } else { '' }
        SessionID   = $Matches['id']
        State       = $Matches['state']
        IdleTime    = $Matches['idle']
        LogonTime   = $Matches['logon'].Trim()
        Server      = $server
        IsCurrent   = $isCurrent
    }
}

# 5f - Get-RhinoSessions  (was 5e)
# Query session info from a list of servers IN PARALLEL using a runspace
# pool. This is the headline performance win over the original script.
#
# Why a runspace pool instead of Start-Job?
#   - Start-Job spawns a new powershell.exe process per job. ~50-100ms of
#     startup overhead each. 30 servers = 30 process launches.
#   - Runspaces are in-process threads. ~1ms startup each.
#   - For 30 servers we typically see <2s total vs >15s sequential.
#
# Returns a flat list of session PSObjects across all servers.
function Get-RhinoSessions {
    param([string[]]$Servers, [int]$MaxThreads = 15)
    if (-not $Servers -or $Servers.Count -eq 0) { return @() }

    # Build the runspace pool. Min 1, Max $MaxThreads - PowerShell will
    # spin up threads on demand up to the cap.
    $pool = [runspacefactory]::CreateRunspacePool(1, $MaxThreads)
    $pool.Open()

    # The script each runspace executes. We MUST do all parsing inside the
    # runspace and only return primitive PSObjects to the main thread,
    # because runspaces can't share function references with the parent
    # scope. So we inline a copy of the parser here.
    $workerScript = {
        param($server)
        # Inline parser - same logic as Parse-QuserLine. Duplicated because
        # runspaces don't inherit functions from the parent scope. Keep
        # this in sync with Parse-QuserLine above.
        function Parse-Line {
            param([string]$line, [string]$srv)
            if ([string]::IsNullOrWhiteSpace($line)) { return $null }
            if ($line -match '^\s*USERNAME') { return $null }
            $isCurrent = $line -match '^\s*>'
            $work = $line -replace '^\s*>\s*', ''
            $pattern = '^\s*(?<user>\S+)(?:\s+(?<session>\S+))?\s+(?<id>\d+)\s+(?<state>Active|Disc|Listen|Conn|ConnQ|Shadow|Reset|Down|Init|Idle)\s+(?<idle>\S+)\s+(?<logon>.+?)\s*$'
            if ($work -notmatch $pattern) { return $null }
            return [PSCustomObject]@{
                Username    = $Matches['user']
                SessionName = if ($Matches['session']) { $Matches['session'] } else { '' }
                SessionID   = $Matches['id']
                State       = $Matches['state']
                IdleTime    = $Matches['idle']
                LogonTime   = $Matches['logon'].Trim()
                Server      = $srv
                IsCurrent   = $isCurrent
            }
        }
        $results = @()
        try {
            # 2>$null suppresses stderr noise like "No User exists for *"
            # which is what quser emits for an idle server with no sessions.
            $output = query user /server:$server 2>$null
            if ($output) {
                foreach ($line in $output) {
                    $parsed = Parse-Line $line $server
                    if ($parsed) { $results += $parsed }
                }
            }
        } catch {
            # Return a marker object so the caller can log the failure.
            $results += [PSCustomObject]@{
                Username    = "(error)"
                SessionName = ""
                SessionID   = ""
                State       = "ERROR"
                IdleTime    = ""
                LogonTime   = $_.Exception.Message
                Server      = $server
                IsCurrent   = $false
            }
        }
        return ,$results   # Comma forces array return even when only one item
    }

    # Dispatch one runspace per server.
    $jobs = @()
    foreach ($srv in $Servers) {
        $ps = [powershell]::Create()
        $ps.RunspacePool = $pool
        $null = $ps.AddScript($workerScript).AddArgument($srv)
        $jobs += @{ Pipe = $ps; Handle = $ps.BeginInvoke(); Server = $srv }
    }

    # Collect results. EndInvoke blocks until that runspace finishes - but
    # because we dispatched all of them before any started collecting, they
    # run concurrently regardless.
    $allSessions = @()
    foreach ($job in $jobs) {
        try {
            $sessions = $job.Pipe.EndInvoke($job.Handle)
            foreach ($s in $sessions) { $allSessions += $s }
        } catch {
            # Runspace itself errored (rare - quser errors are caught inside
            # the worker). Skip silently.
        } finally {
            $job.Pipe.Dispose()
        }
    }

    $pool.Close()
    $pool.Dispose()
    return $allSessions
}


# ==============================================================================
# SECTION 6 - Form build
# ==============================================================================
try {

    # ------------------------------------------------------------------
    # SECTION 6a - Form shell
    # ------------------------------------------------------------------
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "RhinoShadow v1.0"
    $form.MinimumSize = New-Object System.Drawing.Size(950, 780)
    $form.Size = New-Object System.Drawing.Size(1050, 830)
    $form.StartPosition = "CenterScreen"
    $form.Font = $fontRegular
    $form.AutoScaleMode = 'Font'
    $form.BackColor = $script:t.Bg
    $form.ForeColor = $script:t.Text
    if (Test-Path $iconPath) {
        try { $form.Icon = New-Object System.Drawing.Icon($iconPath) } catch { }
    }

    # ------------------------------------------------------------------
    # SECTION 6b - Header panel (mascot, title, theme + help buttons)
    # ------------------------------------------------------------------
    $headerPanel = New-Object System.Windows.Forms.Panel
    $headerPanel.Location = New-Object System.Drawing.Point(0, 0)
    $headerPanel.Size = New-Object System.Drawing.Size(1050, 90)
    $headerPanel.Dock = 'Top'
    $headerPanel.BackColor = $script:t.Surface
    # Custom Paint to draw a thin bottom border in the active palette colour.
    $headerPanel.Add_Paint({
        $g = $_.Graphics
        $pen = New-Object System.Drawing.Pen($script:t.Border, 1)
        $g.DrawLine($pen, 0, $headerPanel.Height - 1, $headerPanel.Width, $headerPanel.Height - 1)
        $pen.Dispose()
    })
    $form.Controls.Add($headerPanel)
    Register-Themed -Control $headerPanel -Role "header"

    # Mascot picture box - shows the Rhino. Falls back to a coloured square
    # if the PNG isn't present.
    $mascot = New-Object System.Windows.Forms.PictureBox
    $mascot.Size = New-Object System.Drawing.Size(70, 70)
    $mascot.Location = New-Object System.Drawing.Point(15, 10)
    $mascot.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
    $mascot.Cursor = [System.Windows.Forms.Cursors]::Hand
    if (Test-Path $mascotPath) {
        try { $mascot.Image = [System.Drawing.Image]::FromFile($mascotPath) }
        catch { $mascot.BackColor = $script:t.Accent }
    } else {
        $mascot.BackColor = $script:t.Accent
    }
    $headerPanel.Controls.Add($mascot)

    # Title wordmark
    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = "RhinoShadow"
    $titleLabel.Font = $fontTitle
    $titleLabel.AutoSize = $true
    $titleLabel.Location = New-Object System.Drawing.Point(95, 15)
    $titleLabel.ForeColor = $script:t.Text
    $titleLabel.BackColor = $script:t.Surface
    $headerPanel.Controls.Add($titleLabel)
    Register-Themed -Control $titleLabel -Role "label-surf"

    # Subtitle / tagline - one-line description of what the app does
    $subtitleLabel = New-Object System.Windows.Forms.Label
    $subtitleLabel.Text = "Find users on RDS. Shadow or sign them out."
    $subtitleLabel.Font = $fontSubtitle
    $subtitleLabel.AutoSize = $true
    $subtitleLabel.Location = New-Object System.Drawing.Point(95, 50)
    $subtitleLabel.ForeColor = $script:t.Muted
    $subtitleLabel.BackColor = $script:t.Surface
    $headerPanel.Controls.Add($subtitleLabel)
    Register-Themed -Control $subtitleLabel -Role "muted-surf"

    # Theme toggle button (top right)
    $themeButton = New-Object System.Windows.Forms.Button
    $themeButton.Text = "Light"
    $themeButton.Size = New-Object System.Drawing.Size(70, 28)
    $themeButton.Anchor = 'Top,Right'
    $themeButton.Location = New-Object System.Drawing.Point(885, 20)
    Apply-ButtonTheme -Button $themeButton -Role "btn-neutral"
    $headerPanel.Controls.Add($themeButton)
    Register-Themed -Control $themeButton -Role "btn-neutral"
    $themeButton.Add_Click({
        if ($script:currentTheme -eq "dark") {
            $script:currentTheme = "light"
            $script:t = $script:themes.light
            $themeButton.Text = "Dark"
        } else {
            $script:currentTheme = "dark"
            $script:t = $script:themes.dark
            $themeButton.Text = "Light"
        }
        Apply-Theme
    })

    # Help button (top right, next to theme)
    $helpButton = New-Object System.Windows.Forms.Button
    $helpButton.Text = "?"
    $helpButton.Size = New-Object System.Drawing.Size(32, 28)
    $helpButton.Anchor = 'Top,Right'
    $helpButton.Location = New-Object System.Drawing.Point(960, 20)
    Apply-ButtonTheme -Button $helpButton -Role "btn-help"
    $headerPanel.Controls.Add($helpButton)
    Register-Themed -Control $helpButton -Role "btn-help"

    # ------------------------------------------------------------------
    # SECTION 6c - Mascot easter egg
    # ------------------------------------------------------------------
    # Click the rhino to get an escalating mood from the IT veteran inside.
    # Pure flavour, no functional impact. The original Shadow User had no
    # rhino at all - this is the rhino-theming brief at work.
    $script:mascotClicks = 0
    $mascotMessages = @(
        "Hi, I'm Rhino. Let's go hunt some sessions.",
        "Click me again, I dare you.",
        "Look, I'm working. You're working. Let's just focus on the sessions.",
        "Did you know logoff is the only command in Windows that does exactly what it says?",
        "Three clicks in. Are you supposed to be signing someone out right now?",
        "I once shadowed a session for 8 hours. Riveting stuff. They were in Excel.",
        "If you keep clicking me, I'm going to start sending YOUR session messages.",
        "Fine. Run SFC /scannow if it makes you happy. That's RhinoHelper's gig though.",
        "I'm just a rhino in a PNG. Please. The IT queue is growing.",
        "Okay seriously. Type a username up there. I'll find them. Promise."
    )
    $mascot.Add_Click({
        $idx = $script:mascotClicks % $mascotMessages.Count
        $subtitleLabel.Text = $mascotMessages[$idx]
        $script:mascotClicks++
    })

    # ------------------------------------------------------------------
    # SECTION 6d - Quick Find panel (search by username everywhere)
    # ------------------------------------------------------------------
    # The primary workflow: type a username, hit Find Everywhere, get a
    # list of every RDS server that user is logged into. This is the most
    # common use case so it lives at the top, immediately under the header.
    $quickFindBox = New-Object System.Windows.Forms.GroupBox
    $quickFindBox.Text = " Quick Find "
    $quickFindBox.Font = $fontHeader
    $quickFindBox.Location = New-Object System.Drawing.Point(15, 100)
    $quickFindBox.Size = New-Object System.Drawing.Size(1020, 110)
    $quickFindBox.Anchor = 'Top,Left,Right'
    $quickFindBox.BackColor = $script:t.Bg
    $quickFindBox.ForeColor = $script:t.Text
    $form.Controls.Add($quickFindBox)
    Register-Themed -Control $quickFindBox -Role "groupbox"

    # Username label
    $usernameLabel = New-Object System.Windows.Forms.Label
    $usernameLabel.Text = "Username:"
    $usernameLabel.Location = New-Object System.Drawing.Point(15, 32)
    $usernameLabel.AutoSize = $true
    $usernameLabel.BackColor = $script:t.Bg
    $usernameLabel.ForeColor = $script:t.Text
    $quickFindBox.Controls.Add($usernameLabel)
    Register-Themed -Control $usernameLabel -Role "label-body"

    # Username textbox - the star of the show. Big and obvious.
    $usernameTextBox = New-Object System.Windows.Forms.TextBox
    $usernameTextBox.Location = New-Object System.Drawing.Point(90, 30)
    $usernameTextBox.Size = New-Object System.Drawing.Size(350, 26)
    $usernameTextBox.Font = $fontRegular
    $usernameTextBox.BackColor = $script:t.Surface
    $usernameTextBox.ForeColor = $script:t.Text
    $usernameTextBox.BorderStyle = 'FixedSingle'
    $quickFindBox.Controls.Add($usernameTextBox)
    Register-Themed -Control $usernameTextBox -Role "input"

    # Find Everywhere button (primary action)
    $findEverywhereButton = New-Object System.Windows.Forms.Button
    $findEverywhereButton.Text = "Find Everywhere"
    $findEverywhereButton.Size = New-Object System.Drawing.Size(140, 30)
    $findEverywhereButton.Location = New-Object System.Drawing.Point(455, 28)
    Apply-ButtonTheme -Button $findEverywhereButton -Role "btn-accent"
    $quickFindBox.Controls.Add($findEverywhereButton)
    Register-Themed -Control $findEverywhereButton -Role "btn-accent"

    # Helper text on the right side
    $quickFindHint = New-Object System.Windows.Forms.Label
    $quickFindHint.Text = "Searches every RDS server across every client OU. Partial names OK."
    $quickFindHint.Location = New-Object System.Drawing.Point(610, 35)
    $quickFindHint.AutoSize = $true
    $quickFindHint.Font = $fontSubtitle
    $quickFindHint.BackColor = $script:t.Bg
    $quickFindHint.ForeColor = $script:t.Muted
    $quickFindBox.Controls.Add($quickFindHint)
    Register-Themed -Control $quickFindHint -Role "muted"

    # Client scope label + dropdown. "All Clients" = search everywhere (original
    # behaviour). Selecting a specific client restricts the search to that OU's
    # servers only - much faster when you already know which client the user is on.
    $scopeLabel = New-Object System.Windows.Forms.Label
    $scopeLabel.Text = "Client:"
    $scopeLabel.Location = New-Object System.Drawing.Point(15, 68)
    $scopeLabel.AutoSize = $true
    $scopeLabel.BackColor = $script:t.Bg
    $scopeLabel.ForeColor = $script:t.Text
    $quickFindBox.Controls.Add($scopeLabel)
    Register-Themed -Control $scopeLabel -Role "label-body"

    $scopeDropdown = New-Object System.Windows.Forms.ComboBox
    $scopeDropdown.Location = New-Object System.Drawing.Point(90, 65)
    $scopeDropdown.Size = New-Object System.Drawing.Size(350, 26)
    $scopeDropdown.DropDownStyle = 'DropDownList'
    $scopeDropdown.BackColor = $script:t.Surface
    $scopeDropdown.ForeColor = $script:t.Text
    $quickFindBox.Controls.Add($scopeDropdown)
    Register-Themed -Control $scopeDropdown -Role "input"

    $clearScopeButton = New-Object System.Windows.Forms.Button
    $clearScopeButton.Text = "All"
    $clearScopeButton.Size = New-Object System.Drawing.Size(40, 26)
    $clearScopeButton.Location = New-Object System.Drawing.Point(448, 65)
    Apply-ButtonTheme -Button $clearScopeButton -Role "btn-neutral"
    $quickFindBox.Controls.Add($clearScopeButton)
    Register-Themed -Control $clearScopeButton -Role "btn-neutral"
    $clearScopeButton.Add_Click({ $scopeDropdown.SelectedIndex = 0 })

    # When scope changes, update the hint text and button label so the user
    # knows at a glance what clicking Find will actually search.
    $scopeDropdown.Add_SelectedIndexChanged({
        if ($scopeDropdown.SelectedIndex -eq 0) {
            $quickFindHint.Text = "Searches every RDS server across every client OU. Partial names OK."
            $findEverywhereButton.Text = "Find Everywhere"
        } else {
            $quickFindHint.Text = "Searches only $($scopeDropdown.SelectedItem) servers. Partial names OK."
            $findEverywhereButton.Text = "Find in Client"
        }
    })

    # Pressing Enter in the username box is the same as clicking Find.
    # Cleaner workflow - never have to touch the mouse for the common case.
    $usernameTextBox.Add_KeyDown({
        if ($_.KeyCode -eq 'Enter') {
            $findEverywhereButton.PerformClick()
            $_.SuppressKeyPress = $true
        }
    })

    # ------------------------------------------------------------------
    # SECTION 6e - Browse by OU panel (secondary path)
    # ------------------------------------------------------------------
    # Traditional flow: pick a client OU, see its RDS servers, tick which
    # ones to query, show their sessions. Kept because the team uses it
    # for "show me everyone on these servers" use cases.
    $browseBox = New-Object System.Windows.Forms.GroupBox
    $browseBox.Text = " Browse by Client "
    $browseBox.Font = $fontHeader
    $browseBox.Location = New-Object System.Drawing.Point(15, 220)
    $browseBox.Size = New-Object System.Drawing.Size(1020, 165)
    $browseBox.Anchor = 'Top,Left,Right'
    $browseBox.BackColor = $script:t.Bg
    $browseBox.ForeColor = $script:t.Text
    $form.Controls.Add($browseBox)
    Register-Themed -Control $browseBox -Role "groupbox"

    # Client label + dropdown
    $clientLabel = New-Object System.Windows.Forms.Label
    $clientLabel.Text = "Client:"
    $clientLabel.Location = New-Object System.Drawing.Point(15, 32)
    $clientLabel.AutoSize = $true
    $clientLabel.BackColor = $script:t.Bg
    $clientLabel.ForeColor = $script:t.Text
    $browseBox.Controls.Add($clientLabel)
    Register-Themed -Control $clientLabel -Role "label-body"

    $clientDropdown = New-Object System.Windows.Forms.ComboBox
    $clientDropdown.Location = New-Object System.Drawing.Point(90, 30)
    $clientDropdown.Size = New-Object System.Drawing.Size(350, 26)
    $clientDropdown.DropDownStyle = 'DropDownList'
    $clientDropdown.BackColor = $script:t.Surface
    $clientDropdown.ForeColor = $script:t.Text
    $browseBox.Controls.Add($clientDropdown)
    Register-Themed -Control $clientDropdown -Role "input"

    $clearClientButton = New-Object System.Windows.Forms.Button
    $clearClientButton.Text = "All"
    $clearClientButton.Size = New-Object System.Drawing.Size(40, 26)
    $clearClientButton.Location = New-Object System.Drawing.Point(448, 30)
    Apply-ButtonTheme -Button $clearClientButton -Role "btn-neutral"
    $browseBox.Controls.Add($clearClientButton)
    Register-Themed -Control $clearClientButton -Role "btn-neutral"
    $clearClientButton.Add_Click({
        $clientDropdown.SelectedIndex = -1
        $serverListBox.Items.Clear()
    })

    # Server list (multi-check). Allow vertical resize through anchoring so
    # the box gets bigger as the user resizes the window.
    $serverLabel = New-Object System.Windows.Forms.Label
    $serverLabel.Text = "Servers:"
    $serverLabel.Location = New-Object System.Drawing.Point(15, 70)
    $serverLabel.AutoSize = $true
    $serverLabel.BackColor = $script:t.Bg
    $serverLabel.ForeColor = $script:t.Text
    $browseBox.Controls.Add($serverLabel)
    Register-Themed -Control $serverLabel -Role "label-body"

    $serverListBox = New-Object System.Windows.Forms.CheckedListBox
    $serverListBox.Location = New-Object System.Drawing.Point(90, 70)
    $serverListBox.Size = New-Object System.Drawing.Size(350, 85)
    $serverListBox.CheckOnClick = $true
    $serverListBox.BackColor = $script:t.Surface
    $serverListBox.ForeColor = $script:t.Text
    $serverListBox.BorderStyle = 'FixedSingle'
    $browseBox.Controls.Add($serverListBox)
    Register-Themed -Control $serverListBox -Role "input"

    # Action buttons on the right side of the browse panel
    $selectAllButton = New-Object System.Windows.Forms.Button
    $selectAllButton.Text = "Select All"
    $selectAllButton.Size = New-Object System.Drawing.Size(120, 30)
    $selectAllButton.Location = New-Object System.Drawing.Point(455, 70)
    Apply-ButtonTheme -Button $selectAllButton -Role "btn-neutral"
    $browseBox.Controls.Add($selectAllButton)
    Register-Themed -Control $selectAllButton -Role "btn-neutral"
    $selectAllButton.Add_Click({
        # Toggle: if everything is already checked, uncheck all.
        $anyUnchecked = $false
        for ($i = 0; $i -lt $serverListBox.Items.Count; $i++) {
            if (-not $serverListBox.GetItemChecked($i)) { $anyUnchecked = $true; break }
        }
        for ($i = 0; $i -lt $serverListBox.Items.Count; $i++) {
            $serverListBox.SetItemChecked($i, $anyUnchecked)
        }
    })

    $showUsersButton = New-Object System.Windows.Forms.Button
    $showUsersButton.Text = "Show Sessions"
    $showUsersButton.Size = New-Object System.Drawing.Size(120, 30)
    $showUsersButton.Location = New-Object System.Drawing.Point(455, 105)
    Apply-ButtonTheme -Button $showUsersButton -Role "btn-success"
    $browseBox.Controls.Add($showUsersButton)
    Register-Themed -Control $showUsersButton -Role "btn-success"

    # Browse panel hint
    $browseHint = New-Object System.Windows.Forms.Label
    $browseHint.Text = "Pick a client, tick the RDS hosts you want to inspect, then Show Sessions."
    $browseHint.Location = New-Object System.Drawing.Point(595, 75)
    $browseHint.MaximumSize = New-Object System.Drawing.Size(410, 0)
    $browseHint.AutoSize = $true
    $browseHint.Font = $fontSubtitle
    $browseHint.BackColor = $script:t.Bg
    $browseHint.ForeColor = $script:t.Muted
    $browseBox.Controls.Add($browseHint)
    Register-Themed -Control $browseHint -Role "muted"

    # ------------------------------------------------------------------
    # SECTION 6f - Sessions grid + filter
    # ------------------------------------------------------------------
    $sessionsBox = New-Object System.Windows.Forms.GroupBox
    $sessionsBox.Text = " Sessions "
    $sessionsBox.Font = $fontHeader
    $sessionsBox.Location = New-Object System.Drawing.Point(15, 395)
    $sessionsBox.Size = New-Object System.Drawing.Size(1020, 230)
    $sessionsBox.Anchor = 'Top,Bottom,Left,Right'
    $sessionsBox.BackColor = $script:t.Bg
    $sessionsBox.ForeColor = $script:t.Text
    $form.Controls.Add($sessionsBox)
    Register-Themed -Control $sessionsBox -Role "groupbox"

    # Filter textbox - filters the currently-displayed sessions live, no
    # button press needed. Filters across Username, Server, and State.
    $filterLabel = New-Object System.Windows.Forms.Label
    $filterLabel.Text = "Filter:"
    $filterLabel.Location = New-Object System.Drawing.Point(15, 30)
    $filterLabel.AutoSize = $true
    $filterLabel.BackColor = $script:t.Bg
    $filterLabel.ForeColor = $script:t.Text
    $sessionsBox.Controls.Add($filterLabel)
    Register-Themed -Control $filterLabel -Role "label-body"

    $filterTextBox = New-Object System.Windows.Forms.TextBox
    $filterTextBox.Location = New-Object System.Drawing.Point(60, 28)
    $filterTextBox.Size = New-Object System.Drawing.Size(300, 26)
    $filterTextBox.BackColor = $script:t.Surface
    $filterTextBox.ForeColor = $script:t.Text
    $filterTextBox.BorderStyle = 'FixedSingle'
    $sessionsBox.Controls.Add($filterTextBox)
    Register-Themed -Control $filterTextBox -Role "input"

    # Session count label - lives in the top-right of the sessions box
    $countLabel = New-Object System.Windows.Forms.Label
    $countLabel.Text = "0 sessions"
    $countLabel.Anchor = 'Top,Right'
    $countLabel.Location = New-Object System.Drawing.Point(900, 32)
    $countLabel.AutoSize = $true
    $countLabel.Font = $fontSubtitle
    $countLabel.BackColor = $script:t.Bg
    $countLabel.ForeColor = $script:t.Muted
    $sessionsBox.Controls.Add($countLabel)
    Register-Themed -Control $countLabel -Role "muted"

    # The DataGridView. Columns are added manually so headers / widths can
    # be controlled, and so sortability can be turned on per column.
    $sessionsGrid = New-Object System.Windows.Forms.DataGridView
    $sessionsGrid.Location = New-Object System.Drawing.Point(15, 60)
    $sessionsGrid.Size = New-Object System.Drawing.Size(990, 160)
    $sessionsGrid.Anchor = 'Top,Bottom,Left,Right'
    $sessionsGrid.AutoGenerateColumns = $false
    $sessionsGrid.MultiSelect = $false
    $sessionsGrid.SelectionMode = 'FullRowSelect'
    $sessionsGrid.RowHeadersVisible = $false
    $sessionsGrid.AllowUserToAddRows = $false
    $sessionsGrid.AllowUserToDeleteRows = $false
    $sessionsGrid.AllowUserToResizeRows = $false
    $sessionsGrid.ReadOnly = $true
    $sessionsGrid.BorderStyle = 'FixedSingle'
    $sessionsGrid.CellBorderStyle = 'SingleHorizontal'
    $sessionsGrid.BackgroundColor = $script:t.Surface
    $sessionsGrid.GridColor = $script:t.Border
    $sessionsGrid.EnableHeadersVisualStyles = $false
    $sessionsGrid.ColumnHeadersHeightSizeMode = 'AutoSize'
    $sessionsGrid.AutoSizeColumnsMode = 'Fill'
    # Theme the grid through the role registration which knows about all
    # the sub-properties.
    Register-Themed -Control $sessionsGrid -Role "grid"
    # Trigger one Apply-Theme equivalent pass for the grid right now (the
    # grid role does a lot of property setting).
    $sessionsGrid.DefaultCellStyle.BackColor = $script:t.Surface
    $sessionsGrid.DefaultCellStyle.ForeColor = $script:t.Text
    $sessionsGrid.DefaultCellStyle.SelectionBackColor = $script:t.Accent
    $sessionsGrid.DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::White
    $sessionsGrid.AlternatingRowsDefaultCellStyle.BackColor = $script:t.SurfaceAlt
    $sessionsGrid.ColumnHeadersDefaultCellStyle.BackColor = $script:t.SurfaceAlt
    $sessionsGrid.ColumnHeadersDefaultCellStyle.ForeColor = $script:t.Text
    $sessionsBox.Controls.Add($sessionsGrid)

    # Column setup. The order here is the order in the grid. State and
    # Idle come right after Username because that's what the IT team
    # scans first when deciding who to log off.
    $colDefs = @(
        @{ Name = "Username";    Header = "Username";     Width = 160; Sort = 'Automatic' }
        @{ Name = "State";       Header = "State";        Width = 80;  Sort = 'Automatic' }
        @{ Name = "IdleTime";    Header = "Idle";         Width = 80;  Sort = 'Automatic' }
        @{ Name = "LogonTime";   Header = "Logon Time";   Width = 160; Sort = 'Automatic' }
        @{ Name = "Server";      Header = "RDS Server";   Width = 200; Sort = 'Automatic' }
        @{ Name = "SessionID";   Header = "Session ID";   Width = 80;  Sort = 'Automatic' }
        @{ Name = "SessionName"; Header = "Session Name"; Width = 140; Sort = 'Automatic' }
    )
    foreach ($def in $colDefs) {
        $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $col.Name = $def.Name
        $col.HeaderText = $def.Header
        $col.SortMode = $def.Sort
        $col.FillWeight = $def.Width
        $sessionsGrid.Columns.Add($col) | Out-Null
    }

    # ------------------------------------------------------------------
    # SECTION 6g - Action buttons row
    # ------------------------------------------------------------------
    $actionPanel = New-Object System.Windows.Forms.Panel
    $actionPanel.Location = New-Object System.Drawing.Point(15, 635)
    $actionPanel.Size = New-Object System.Drawing.Size(1020, 40)
    $actionPanel.Anchor = 'Bottom,Left,Right'
    $actionPanel.BackColor = $script:t.Bg
    $form.Controls.Add($actionPanel)
    Register-Themed -Control $actionPanel -Role "form"

    $shadowButton = New-Object System.Windows.Forms.Button
    $shadowButton.Text = "Shadow"
    $shadowButton.Size = New-Object System.Drawing.Size(110, 32)
    $shadowButton.Location = New-Object System.Drawing.Point(0, 4)
    Apply-ButtonTheme -Button $shadowButton -Role "btn-accent"
    $actionPanel.Controls.Add($shadowButton)
    Register-Themed -Control $shadowButton -Role "btn-accent"

    $signOutButton = New-Object System.Windows.Forms.Button
    $signOutButton.Text = "Sign Out"
    $signOutButton.Size = New-Object System.Drawing.Size(110, 32)
    $signOutButton.Location = New-Object System.Drawing.Point(120, 4)
    Apply-ButtonTheme -Button $signOutButton -Role "btn-danger"
    $actionPanel.Controls.Add($signOutButton)
    Register-Themed -Control $signOutButton -Role "btn-danger"

    $sendMsgButton = New-Object System.Windows.Forms.Button
    $sendMsgButton.Text = "Send Message"
    $sendMsgButton.Size = New-Object System.Drawing.Size(130, 32)
    $sendMsgButton.Location = New-Object System.Drawing.Point(240, 4)
    Apply-ButtonTheme -Button $sendMsgButton -Role "btn-neutral"
    $actionPanel.Controls.Add($sendMsgButton)
    Register-Themed -Control $sendMsgButton -Role "btn-neutral"

    $refreshButton = New-Object System.Windows.Forms.Button
    $refreshButton.Text = "Refresh"
    $refreshButton.Size = New-Object System.Drawing.Size(110, 32)
    $refreshButton.Location = New-Object System.Drawing.Point(380, 4)
    Apply-ButtonTheme -Button $refreshButton -Role "btn-success"
    $actionPanel.Controls.Add($refreshButton)
    Register-Themed -Control $refreshButton -Role "btn-success"

    # ------------------------------------------------------------------
    # SECTION 6h - Status log
    # ------------------------------------------------------------------
    # A timestamped log of every action the user has taken. Persists for
    # the whole session. Mono-spaced so anything column-aligned reads well.
    $logLabel = New-Object System.Windows.Forms.Label
    $logLabel.Text = "Activity:"
    $logLabel.Location = New-Object System.Drawing.Point(15, 685)
    $logLabel.AutoSize = $true
    $logLabel.Anchor = 'Bottom,Left'
    $logLabel.BackColor = $script:t.Bg
    $logLabel.ForeColor = $script:t.Muted
    $form.Controls.Add($logLabel)
    Register-Themed -Control $logLabel -Role "muted"

    $logBox = New-Object System.Windows.Forms.TextBox
    $logBox.Location = New-Object System.Drawing.Point(15, 705)
    $logBox.Size = New-Object System.Drawing.Size(1020, 80)
    $logBox.Anchor = 'Bottom,Left,Right'
    $logBox.Multiline = $true
    $logBox.ScrollBars = 'Vertical'
    $logBox.ReadOnly = $true
    $logBox.Font = $fontMono
    $logBox.BackColor = $script:t.Surface
    $logBox.ForeColor = $script:t.Text
    $logBox.BorderStyle = 'FixedSingle'
    $form.Controls.Add($logBox)
    Register-Themed -Control $logBox -Role "log"

    # ------------------------------------------------------------------
    # SECTION 6i - Worker functions (need to be defined after $logBox exists
    #              because they all log to it)
    # ------------------------------------------------------------------

    # Write a timestamped line to the activity log. The optional $level
    # is informational - it changes nothing in the rendering today, but
    # leaves a hook to colour-code later if desired.
    function Write-RhinoLog {
        param([string]$message, [string]$level = "info")
        $stamp = (Get-Date).ToString("HH:mm:ss")
        $prefix = switch ($level) {
            "error" { "[ERR]" }
            "warn"  { "[!]  " }
            "ok"    { "[OK] " }
            default { "     " }
        }
        $logBox.AppendText("$stamp $prefix $message`r`n")
    }

    # Repopulate the grid from $script:currentSessions, optionally filtered
    # by the text in $filterTextBox. Called by both the query functions
    # (after they update currentSessions) and the filter TextChanged event.
    function Apply-SessionFilter {
        $filter = $filterTextBox.Text.Trim().ToLower()
        $sessionsGrid.Rows.Clear()
        $shown = 0
        foreach ($s in $script:currentSessions) {
            if ($filter) {
                # Filter matches if it's a substring of Username, Server,
                # or State. Case insensitive. Username is the common case
                # but Server lets you e.g. type "PROD" to see only prod
                # servers, and "Disc" to see only disconnected.
                $haystack = "$($s.Username) $($s.Server) $($s.State)".ToLower()
                if ($haystack -notlike "*$filter*") { continue }
            }
            $idx = $sessionsGrid.Rows.Add(
                $s.Username, $s.State, $s.IdleTime, $s.LogonTime,
                $s.Server, $s.SessionID, $s.SessionName
            )
            # Visually flag State - green for Active, amber for Disc/Idle,
            # red for the synthetic ERROR rows.
            $stateCell = $sessionsGrid.Rows[$idx].Cells["State"]
            switch -Wildcard ($s.State) {
                "Active" { $stateCell.Style.ForeColor = $script:t.Success }
                "Disc*"  { $stateCell.Style.ForeColor = $script:t.Warning }
                "ERROR"  { $stateCell.Style.ForeColor = $script:t.Danger }
            }
            $shown++
        }
        $total = $script:currentSessions.Count
        if ($filter) {
            $countLabel.Text = "$shown of $total sessions"
        } else {
            $countLabel.Text = "$total sessions"
        }
    }

    # Live filter as the user types.
    $filterTextBox.Add_TextChanged({ Apply-SessionFilter })

    # Search across every RDS server for the username in the textbox.
    # Bulk of the wait time is in Get-RhinoSessions; everything else here
    # is bookkeeping and UI updates.
    function Find-UserEverywhere {
        $query = $usernameTextBox.Text.Trim()
        if (-not $query) {
            Write-RhinoLog "Type a username first." "warn"
            return
        }
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try {
            # Resolve the search term against AD first so that display names,
            # surnames, given names, and UPNs all work -- not just SAM accounts.
            # Resolve-RhinoUsernames logs a warning and returns @() if AD is down,
            # in which case we fall back to raw wildcard match on quser output.
            $resolvedSams = @(Resolve-RhinoUsernames -term $query)
            if ($resolvedSams.Count -gt 0) {
                Write-RhinoLog "AD resolved '$query' to: $($resolvedSams -join ', ')"
            } else {
                Write-RhinoLog "No AD match for '$query', falling back to raw username wildcard." "warn"
            }

            $scopedClient = if ($scopeDropdown.SelectedIndex -gt 0) { $scopeDropdown.SelectedItem.ToString() } else { $null }
            if ($scopedClient) {
                Write-RhinoLog "Enumerating RDS servers for client '$scopedClient'..."
                $ouPath = "OU=$scopedClient,$script:adRoot"
                $servers = @(Get-RhinoServers $ouPath)
            } else {
                Write-RhinoLog "Enumerating RDS servers across all clients..."
                $servers = @(Get-AllRhinoServers)
            }
            if (-not $servers -or $servers.Count -eq 0) {
                Write-RhinoLog "No RDS servers found. Check connectivity or client selection." "error"
                return
            }
            $scope = if ($scopedClient) { "client '$scopedClient'" } else { "all clients" }
            Write-RhinoLog "Querying $($servers.Count) server(s) in parallel across $scope..."
            $allSessions = Get-RhinoSessions -Servers $servers

            # Exact SAM match against resolved names if AD gave us results;
            # otherwise fall back to wildcard on raw session username.
            $matches = if ($resolvedSams.Count -gt 0) {
                $allSessions | Where-Object { $resolvedSams -contains $_.Username }
            } else {
                $allSessions | Where-Object { $_.Username -like "*$query*" }
            }

            $script:currentSessions = @($matches)
            Apply-SessionFilter
            if ($matches.Count -eq 0) {
                Write-RhinoLog "No sessions found matching '$query'. Maybe they've already logged off." "warn"
            } elseif ($matches.Count -eq 1) {
                $m = $matches[0]
                Write-RhinoLog "Found '$($m.Username)' on $($m.Server) (session $($m.SessionID), $($m.State))." "ok"
                if ($sessionsGrid.Rows.Count -gt 0) { $sessionsGrid.Rows[0].Selected = $true }
            } else {
                Write-RhinoLog "Found $($matches.Count) sessions matching '$query'." "ok"
            }
        } catch {
            Write-RhinoLog "Find failed: $_" "error"
        } finally {
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    }

    # Query sessions for whichever servers are ticked in the Browse panel.
    function Show-SessionsForSelectedServers {
        $checked = @($serverListBox.CheckedItems)
        if ($checked.Count -eq 0) {
            Write-RhinoLog "Tick at least one server first." "warn"
            return
        }
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try {
            Write-RhinoLog "Querying $($checked.Count) selected server(s)..."
            $allSessions = Get-RhinoSessions -Servers $checked
            $script:currentSessions = @($allSessions)
            Apply-SessionFilter
            Write-RhinoLog "$($allSessions.Count) sessions returned." "ok"
        } catch {
            Write-RhinoLog "Browse query failed: $_" "error"
        } finally {
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    }

    # Helper: pull the selected session as a PSObject. Returns $null and
    # logs a warning if nothing is selected.
    function Get-SelectedSession {
        if ($sessionsGrid.SelectedRows.Count -eq 0) {
            Write-RhinoLog "Select a session in the grid first." "warn"
            return $null
        }
        $row = $sessionsGrid.SelectedRows[0]
        return [PSCustomObject]@{
            Username  = $row.Cells["Username"].Value
            SessionID = $row.Cells["SessionID"].Value
            Server    = $row.Cells["Server"].Value
            State     = $row.Cells["State"].Value
        }
    }

    # Shadow a session via mstsc. /control gives you full keyboard+mouse,
    # which is what helpdesk-style shadowing normally wants. Drop /control
    # for view-only.
    function Invoke-Shadow {
        $s = Get-SelectedSession
        if (-not $s) { return }
        if ($s.State -notlike "Active*") {
            Write-RhinoLog "Cannot shadow '$($s.Username)' - session is $($s.State). Only Active sessions can be shadowed." "warn"
            return
        }
        $msg = "Shadow $($s.Username) on $($s.Server) (session $($s.SessionID))?"
        $ans = [System.Windows.Forms.MessageBox]::Show($msg, "RhinoShadow", 'YesNo', 'Question')
        if ($ans -ne 'Yes') { return }
        Write-RhinoLog "Launching mstsc /shadow for $($s.Username) on $($s.Server)..."
        Start-Process mstsc -ArgumentList "/v:$($s.Server)", "/shadow:$($s.SessionID)", "/control"
    }

    # Sign out (logoff) a session. This is the most common destructive
    # action so the confirmation dialog spells out exactly who/where, and
    # we log the exact command being executed BEFORE running it so any
    # silent failure leaves a breadcrumb in the activity log.
    #
    # Previous version used Start-Process -NoNewWindow which sometimes
    # masked failures (logoff.exe would return 0 even when nothing was
    # actually done, or the call would never reach logoff.exe at all).
    # We now use direct invocation via the call operator (&) and check
    # $LASTEXITCODE, capturing stderr via 2>&1 so any error text from
    # logoff.exe ends up in the log.
    function Invoke-SignOut {
        $s = Get-SelectedSession
        if (-not $s) { return }

        # Defensive: validate the session ID before passing it to logoff.
        # If the quser parser produced garbage (e.g. shifted columns
        # captured a state keyword into the ID slot), this catches it and
        # blames the parser instead of leaving the user to wonder why
        # logoff "silently failed".
        $sessionId = "$($s.SessionID)".Trim()
        $server    = "$($s.Server)".Trim()
        $username  = "$($s.Username)".Trim()
        if ($sessionId -notmatch '^\d+$') {
            Write-RhinoLog "Cannot sign out: session ID '$sessionId' is not numeric. Parser problem?" "error"
            return
        }
        if (-not $server) {
            Write-RhinoLog "Cannot sign out: server is blank." "error"
            return
        }

        $msg = "Sign out $username on $server?`n`nSession ID: $sessionId`nState: $($s.State)`n`nThis is immediate. Any unsaved work is lost."
        $ans = [System.Windows.Forms.MessageBox]::Show($msg, "RhinoShadow - Sign Out", 'YesNo', 'Warning')
        if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        # Log BEFORE we run it. If logoff hangs, crashes, or returns
        # nonsense, this line is your evidence that the click made it
        # this far and shows the exact args used.
        Write-RhinoLog "Running: logoff.exe $sessionId /server:$server"

        try {
            # Direct invocation via the call operator. $LASTEXITCODE picks
            # up logoff.exe's exit code. 2>&1 redirects stderr into the
            # success stream so we can capture any error message and log it.
            # The full path is used so we never accidentally hit a stale
            # PATH alias or a local logoff.ps1 in the working directory.
            $logoffPath = Join-Path $env:WINDIR "System32\logoff.exe"
            if (-not (Test-Path $logoffPath)) {
                # Fallback to PATH-resolved if for some reason System32 is
                # not where logoff lives on this host.
                $logoffPath = "logoff.exe"
            }
            $output = & $logoffPath $sessionId "/server:$server" 2>&1
            $code = $LASTEXITCODE
            $outText = ($output | Out-String).Trim()

            if ($code -ne 0) {
                # Failure path. The error from logoff usually goes to
                # stderr which we captured into $output. Show it so the
                # user can see exactly why (e.g. "No User exists for *",
                # "Access is denied", "The RPC server is unavailable").
                $detail = if ($outText) { $outText } else { "(no output)" }
                Write-RhinoLog "logoff.exe failed (exit $code): $detail" "error"
                return
            }
            if ($outText) {
                # Success but logoff said something - keep the trail.
                Write-RhinoLog "logoff.exe output: $outText"
            }
            Write-RhinoLog "Sign-out issued: $username on $server (session $sessionId)." "ok"

            # Drop the row from local state. Faster than a re-query and
            # gives instant visual feedback that the action took effect.
            $script:currentSessions = @($script:currentSessions | Where-Object {
                -not ($_.Server -eq $server -and "$($_.SessionID)" -eq $sessionId)
            })
            Apply-SessionFilter
        } catch {
            Write-RhinoLog "Sign-out threw an exception: $_" "error"
        }
    }

    # Send a pop-up message to the selected session via msg.exe. Prompts
    # for the message body with a small input dialog. Uses the same direct-
    # invocation + exit-code-check pattern as Invoke-SignOut for the same
    # reasons (better diagnostics, easier stderr capture).
    function Invoke-SendMessage {
        $s = Get-SelectedSession
        if (-not $s) { return }

        $sessionId = "$($s.SessionID)".Trim()
        $server    = "$($s.Server)".Trim()
        $username  = "$($s.Username)".Trim()
        if ($sessionId -notmatch '^\d+$') {
            Write-RhinoLog "Cannot send message: session ID '$sessionId' is not numeric." "error"
            return
        }

        # InputBox lives in Microsoft.VisualBasic. Load on demand because
        # WinForms doesn't ship a native InputBox.
        Add-Type -AssemblyName Microsoft.VisualBasic
        $body = [Microsoft.VisualBasic.Interaction]::InputBox(
            "Message to send to $username on $($server):",
            "RhinoShadow - Send Message", "")
        if (-not $body) { return }

        Write-RhinoLog "Running: msg.exe $sessionId /server:$server `"$body`""
        try {
            $msgPath = Join-Path $env:WINDIR "System32\msg.exe"
            if (-not (Test-Path $msgPath)) { $msgPath = "msg.exe" }
            # Passing $body as a single arg - PowerShell handles the quoting
            # automatically when args are separate parameters to the call op.
            $output = & $msgPath $sessionId "/server:$server" $body 2>&1
            $code = $LASTEXITCODE
            $outText = ($output | Out-String).Trim()
            if ($code -ne 0) {
                $detail = if ($outText) { $outText } else { "(no output)" }
                Write-RhinoLog "msg.exe failed (exit $code): $detail" "error"
                return
            }
            Write-RhinoLog "Message sent to $username on $server." "ok"
        } catch {
            Write-RhinoLog "Message send threw an exception: $_" "error"
        }
    }

    # Refresh re-runs whichever query last populated the grid. We track
    # this via $script:lastQueryMode = "find" | "browse".
    $script:lastQueryMode = $null
    function Invoke-Refresh {
        switch ($script:lastQueryMode) {
            "find"   { Find-UserEverywhere }
            "browse" { Show-SessionsForSelectedServers }
            default  { Write-RhinoLog "Run a search or Show Sessions first." "warn" }
        }
    }

    # Wire up the buttons now that the functions exist.
    $findEverywhereButton.Add_Click({
        $script:lastQueryMode = "find"
        Find-UserEverywhere
    })
    $showUsersButton.Add_Click({
        $script:lastQueryMode = "browse"
        Show-SessionsForSelectedServers
    })
    $shadowButton.Add_Click({ Invoke-Shadow })
    $signOutButton.Add_Click({ Invoke-SignOut })
    $sendMsgButton.Add_Click({ Invoke-SendMessage })
    $refreshButton.Add_Click({ Invoke-Refresh })

    # Double-click a row to shadow it - matches RDP-console muscle memory.
    $sessionsGrid.Add_CellDoubleClick({
        if ($_.RowIndex -ge 0) { Invoke-Shadow }
    })

    # When the user picks a client OU, populate the server list.
    # Guard against SelectedIndex = -1 (set by the "All" clear button) which
    # leaves SelectedItem as $null - calling .ToString() on null throws.
    $clientDropdown.Add_SelectedIndexChanged({
        if ($clientDropdown.SelectedIndex -lt 0) { return }
        $selectedOU = $clientDropdown.SelectedItem.ToString()
        $ouPath = "OU=$selectedOU,$script:adRoot"
        $servers = Get-RhinoServers $ouPath
        $serverListBox.Items.Clear()
        foreach ($s in ($servers | Sort-Object)) {
            $serverListBox.Items.Add($s, $true) | Out-Null
        }
        Write-RhinoLog "Loaded $($servers.Count) servers for client '$selectedOU'."
    })

    # ------------------------------------------------------------------
    # SECTION 6j - Help dialog
    # ------------------------------------------------------------------
    function Show-RhinoHelp {
        $h = New-Object System.Windows.Forms.Form
        $h.Text = "RhinoShadow - Help"
        $h.Size = New-Object System.Drawing.Size(700, 520)
        $h.StartPosition = "CenterParent"
        $h.FormBorderStyle = 'FixedDialog'
        $h.MaximizeBox = $false
        $h.MinimizeBox = $false
        $h.BackColor = $script:t.Bg
        $h.ForeColor = $script:t.Text
        $h.Font = $fontRegular
        $body = New-Object System.Windows.Forms.RichTextBox
        $body.Multiline = $true
        $body.ReadOnly = $true
        $body.ScrollBars = 'Vertical'
        $body.WordWrap = $false
        $body.Dock = 'Fill'
        $body.BorderStyle = 'None'
        $body.BackColor = $script:t.Surface
        $body.ForeColor = $script:t.Text
        $body.Font = $fontRegular
        $body.Text = @"
RhinoShadow - Quick Guide
==========================

THE MAIN WORKFLOW
-----------------
1. Type a username into Quick Find and press Enter (or click Find Everywhere).
2. Wait ~2 seconds - RhinoShadow queries every RDS server in parallel.
3. The grid fills with matching sessions. State and Idle columns tell you
   if they're Active or already Disconnected.
4. Click the row, then Sign Out (red) or Shadow (blue).

TIPS
----
- Partial usernames work. 'jne' will find 'jneaves'.
- Double-click a row to shadow it directly (no need to click Shadow first).
- The Filter box at the top of the Sessions grid does a live substring
  filter across Username, Server, and State. Try typing "Disc" to see
  only disconnected sessions, or a server name fragment.
- Click any column header to sort by that column.

BROWSE BY CLIENT
----------------
Use the Browse panel when you want to see ALL sessions on specific
servers (e.g. "everyone currently on RDS-CLIENTX-01"). Pick the client
from the dropdown, tick the servers you care about, click Show Sessions.

ACTIONS
-------
  Shadow       mstsc /v:<server> /shadow:<id> /control. Full keyboard/
               mouse takeover. The user sees a prompt on their end.
  Sign Out     logoff <id> /server:<server>. Immediate. Any unsaved
               work is lost - confirmation dialog will warn you.
  Send Message msg <id> /server:<server> "<text>". Pops a dialog on the
               user's session. Useful for "please log off, we need to
               reboot in 10 mins".
  Refresh      Re-runs whichever search you last did.

CONFIG
------
The AD root is hardcoded in the script (see `$script:adRoot`). If we ever
move domains, that one line is what needs updating.
"@
        $h.Controls.Add($body)
        $h.ShowDialog() | Out-Null
    }
    $helpButton.Add_Click({ Show-RhinoHelp })

    # ------------------------------------------------------------------
    # SECTION 6k - Initial population + ShowDialog
    # ------------------------------------------------------------------
    # Populate the client dropdown once at startup. Failure here usually
    # means no domain connectivity - log it but still show the form so
    # the user can see what went wrong rather than getting a silent crash.
    try {
        $ouOptions = Get-RhinoOUs $script:adRoot
        $scopeDropdown.Items.Add("All Clients") | Out-Null
        foreach ($ou in ($ouOptions | Sort-Object)) {
            $clientDropdown.Items.Add($ou) | Out-Null
            $scopeDropdown.Items.Add($ou) | Out-Null
        }
        $scopeDropdown.SelectedIndex = 0
        Write-RhinoLog "Loaded $($ouOptions.Count) client OUs."
        Write-RhinoLog "Ready. Type a username in Quick Find to begin." "ok"
    } catch {
        Write-RhinoLog "Failed to enumerate client OUs: $_" "error"
    }

    # Modal show. Blocks here until the form is closed.
    [void]$form.ShowDialog()

# ==============================================================================
# SECTION 7 - Outer catch (startup crash logger)
# ==============================================================================
} catch {
    # Append the error and a brief stack to %TEMP%\RhinoShadow_crash.log.
    # Without this, a -WindowStyle Hidden launch would fail silently.
    $stamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $entry = @"
[$stamp] RhinoShadow startup crash
$($_.Exception.Message)
$($_.ScriptStackTrace)

"@
    try { Add-Content -Path $crashLog -Value $entry -Encoding UTF8 } catch { }
    # Also show a message box if we got far enough that forms work.
    try {
        [System.Windows.Forms.MessageBox]::Show(
            "RhinoShadow crashed on startup.`n`n$($_.Exception.Message)`n`nDetails: $crashLog",
            "RhinoShadow", 'OK', 'Error') | Out-Null
    } catch { }
}
