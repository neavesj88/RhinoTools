<#
================================================================================
  RhinoShadow v1.69 - RDS Session Manager (fork of "Shadow User")
================================================================================

.SYNOPSIS
    A polished WinForms GUI for finding and managing user sessions across
    Remote Desktop Services (RDS) servers in Active Directory.

.DESCRIPTION
    A modern reimagining of the original Shadow User script. The primary
    workflow this is optimised for: "User X just called me. Which RDS server
    are they on? Sign their session out." Everything in the UI is arranged
    to make that flow take three clicks or fewer.

    DESIGNED FOR MSP / MULTI-TENANT ACTIVE DIRECTORY LAYOUTS:
    Two AD trees are involved - one holding client tenant OUs (where user
    accounts live), one holding RDS server OUs (where the RDS host computer
    objects live). RhinoShadow joins the two by matching client OU names
    across them. See $script:clientRoot and $script:rdsServerRoot in the
    CONFIGURATION banner block (Section 4) for details. For single-tenant
    setups, point both variables at the same OU.

    Features:
      - Quick Find: type a username, instantly searches every RDS server
        across every client in parallel (runspace pool, NOT sequential).
        Optionally scope to one client to narrow the search.
      - Browse by Client: pick a client from the dropdown, see all that
        client's RDS hosts pre-ticked in a check-list, click Show Sessions.
      - Sessions grid: Username / State / Idle / Logon / Server / Session /
        UPN / Local Computer, with click-to-sort headers and a live filter.
        The Local Computer column shows the hostname of the PC the user is
        connecting FROM (via WTS API) - handy for RMM-into-the-workstation
        handoffs when a user calls for help.
      - Robust session parsing: header-driven column detection, correctly
        handles disconnected sessions where the SESSIONNAME column is blank,
        which the original script silently dropped.
      - Action buttons: Shadow (mstsc /shadow /control), Sign Out (logoff,
        with post-action verification), Send Message (msg.exe), Refresh
        (re-runs the last query).
      - Status log with timestamps - mirrors the RhinoCopy pattern so you
        can see exactly which servers were queried and what came back.
        Also written to %LOCALAPPDATA%\Temp\RhinoShadow.log as an audit
        trail (especially: every msg.exe body is recorded with the target).
      - Light / dark theme toggle (dark by default).
      - Rhino mascot easter egg with escalating moods.
      - Crash log to %TEMP%\RhinoShadow_crash.log so failures aren't silent
        when launched with -WindowStyle Hidden.

.AUTHOR
    Forked from "Shadow User" (original by the team).

.CODE STRUCTURE
    1.  Assembly imports + WinForms bootstrap
    2.  Theme palettes (dark + light) + font definitions
    3.  Theme helpers (Register-Themed, Apply-ButtonTheme, New-RhinoButton,
        Apply-Theme, Register-FilterableDropdown)
    4.  CONFIGURATION block + script-level state (paths, caches)
    5.  AD / RDS query functions (no UI):
        5a. Get-RhinoOUs              - list direct-child OUs of a path (OneLevel)
        5b. Get-RhinoServers          - list computer objects under an OU (subtree)
        5c. Get-AllRhinoServers       - cached single-call enum of every RDS host
            Get-RhinoServerOuForClient- map client name -> server-tree OU DN
        5d. Resolve-RhinoUsernames    - AD freetext user search -> SAM+UPN pairs
        5e. Get-UPNMap                - bulk SAM->UPN lookup for grid display
        5f. Parse-QuserOutput         - header-driven block parser for `query user`
        5g. Get-RhinoSessions         - parallel session query via runspace pool
    6.  Form build (inside the outer try block):
        6a. Form shell + FormClosing handler + icon
        6b. Header panel - mascot, title, subtitle, theme + help buttons
        6c. Mascot click easter egg
        6d. Quick Find panel - username box + scope dropdown + Find button
        6e. Browse by Client panel - client dropdown + server checklist + Show
        6f. Sessions grid + filter textbox + Clear filter button
        6g. Action buttons (Shadow / Sign Out / Send Message / Refresh)
        6h. Status log textbox
        6i. Worker functions: Write-RhinoLog, Apply-SessionFilter,
            Find-UserEverywhere, Show-SessionsForSelectedServers,
            Get-SelectedSession, Invoke-Shadow, Invoke-SignOut,
            Invoke-SendMessage, Invoke-Refresh
        6j. Help dialog (Show-RhinoHelp)
        6k. Dropdown population from AD + ShowDialog (modal blocking call)
    7.  Outer catch block - logs any startup crash to %TEMP%

.NOTES
    - The parallel server query uses a runspace pool (1..15 threads). This is
      genuinely the killer feature - sequential queries against ~30 RDS
      servers can take 30+ seconds, parallel completes in ~2-3s.
    - Two variables to edit if moving to a new domain: $script:clientRoot
      and $script:rdsServerRoot. Both live in the CONFIGURATION banner
      block at the top of Section 4 - look for the >>> markers.
    - Action verification: Sign Out re-queries the server after logoff.exe
      returns and warns explicitly if the session is still present (handles
      the documented Server 2019 case where logoff.exe returns 0 on silent
      failure). Send Message can't be verified server-side - we log it as
      "issued" not "delivered" and the activity log captures the body so
      there's an audit trail regardless.
    - Closing the window while a destructive action is mid-flight triggers
      a confirmation prompt. Sign-out runs in a background runspace with a
      UI-thread Timer polling for completion, so the message pump stays
      alive during logoff.exe and FormClosing actually fires. Send Message
      runs synchronously but msg.exe is short-lived so the message pump is
      blocked only briefly. Abandoned actions get an "ABANDONED" line in
      the activity log.
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

# ------------------------------------------------------------------------------
# WTS (Windows Terminal Services) P/Invoke for ClientName lookups
# ------------------------------------------------------------------------------
# `query user` (quser.exe) gives us session ID, state, idle and logon time, but
# it does NOT expose the CLIENT name - i.e. the hostname of the local computer
# the RDP user connected FROM. That field is what we need for "the user just
# called for help, what's their workstation called so I can hop on with RMM".
#
# We get it via WTSQuerySessionInformation from Wtsapi32.dll, info class
# WTSClientName (10). Same API the Cassia / PSTerminalServices module wraps,
# but we don't need to depend on that module being installed.
#
# The type is loaded once into the AppDomain at script start. Once added,
# it's visible from every runspace - PowerShell's [WTS.NativeMethods]
# resolves to the same type whether called from the main scope or from
# inside a runspace pool worker.
#
# The Add-Type call is wrapped because a second add in the same PS session
# throws "Cannot add type. The type name '...' already exists." This is the
# standard pattern for re-runnable P/Invoke declarations.
if (-not ('WTS.NativeMethods' -as [type])) {
    Add-Type -Namespace WTS -Name NativeMethods -MemberDefinition @"
        [System.Runtime.InteropServices.DllImport("Wtsapi32.dll", SetLastError = true)]
        public static extern System.IntPtr WTSOpenServer(string pServerName);

        [System.Runtime.InteropServices.DllImport("Wtsapi32.dll")]
        public static extern void WTSCloseServer(System.IntPtr hServer);

        [System.Runtime.InteropServices.DllImport("Wtsapi32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Auto)]
        public static extern bool WTSQuerySessionInformation(
            System.IntPtr hServer,
            int sessionId,
            int wtsInfoClass,
            out System.IntPtr ppBuffer,
            out int pBytesReturned);

        [System.Runtime.InteropServices.DllImport("Wtsapi32.dll")]
        public static extern void WTSFreeMemory(System.IntPtr pointer);
"@
}


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
$script:t = $script:themes.dark

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

# One-call button construction: build, size, position, theme, parent, and
# register a button in one expression. Removes ~6 lines of boilerplate per
# button across the 11 buttons in this file.
#
# Optional -Anchor lets the caller override the default anchoring (which
# is whatever AnchorStyles default is for that parent, usually Top,Left).
# Optional -OnClick wires up the Click handler in the same call.
function New-RhinoButton {
    param(
        [string]$Text,
        [int]$X, [int]$Y, [int]$W, [int]$H,
        [string]$Role,
        $Parent,
        [scriptblock]$OnClick = $null,
        [System.Windows.Forms.AnchorStyles]$Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left
    )
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Size = New-Object System.Drawing.Size($W, $H)
    $b.Location = New-Object System.Drawing.Point($X, $Y)
    $b.Anchor = $Anchor
    Apply-ButtonTheme -Button $b -Role $Role
    $Parent.Controls.Add($b)
    Register-Themed -Control $b -Role $Role
    if ($OnClick) { $b.Add_Click($OnClick) }
    return $b
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


# Make a ComboBox behave as a type-to-filter dropdown. On each keystroke the
# Items list is narrowed to only entries matching the typed text, and the
# dropdown opens automatically so the user can see the filtered result.
# Committing a selection or leaving the control restores the full list.
#
# PS5.1 WinForms event handlers do NOT close over local variables reliably --
# the scriptblock runs in a different scope and locals go null. We work around
# this by storing state in the control's Tag property (a hashtable) and
# accessing the control via $this inside the handler.
#
# Both $clientDropdown and $scopeDropdown use this - logic lives here once.
# Make a ComboBox behave as a type-to-filter dropdown using ONLY the
# native WinForms AutoComplete support. No custom TextChanged or Leave
# handler.
#
# Why no custom handlers? An earlier version of this function did its own
# filtering by clearing and rebuilding Items on every TextChanged. That
# fought with the native AutoComplete state machine - keystrokes raced
# the suggestion popup, tab-to-complete and arrow-key cycling broke,
# and we needed extra workarounds (Tag-based InFilter flags) just to
# avoid recursion. The whole approach was solving a problem that
# WinForms already solves correctly out of the box.
#
# AutoCompleteMode.SuggestAppend gives us:
#   - Inline completion: type "Cl" and the rest of "Clearlake" appears
#     selected so Enter or Tab commits it.
#   - A filtered suggestion popup below the field showing all matches.
#   - Arrow-key cycling through the suggestion popup.
#   - Mouse-click selection from the popup.
#   - Esc to cancel completion.
# AutoCompleteSource.ListItems means the suggestions come straight from
# the Items collection we populate at startup. No filter logic needed.
#
# Both $clientDropdown and $scopeDropdown use this so behaviour is
# identical between Quick Find scope and Browse client.
function Register-FilterableDropdown {
    param(
        [System.Windows.Forms.ComboBox]$Dropdown,
        [string[]]$MasterList   # accepted but unused - the Items collection
                                 # is the source of truth for AutoComplete
    )
    $Dropdown.DropDownStyle      = [System.Windows.Forms.ComboBoxStyle]::DropDown
    $Dropdown.AutoCompleteMode   = [System.Windows.Forms.AutoCompleteMode]::SuggestAppend
    $Dropdown.AutoCompleteSource = [System.Windows.Forms.AutoCompleteSource]::ListItems
}


# ==============================================================================
# >>>  CONFIGURATION - EDIT THESE WHEN MOVING TO A NEW DOMAIN  <<<
# ==============================================================================
#
# RhinoShadow needs two AD roots in an MSP/multi-tenant layout:
#
#   1. $script:clientRoot - the parent of your CLIENT TENANT OUs. Each
#      direct child of this is one client. The Client dropdowns are
#      populated from this. User accounts for each client live somewhere
#      inside their client OU (e.g. .../ClientX/Users/sasha_lee).
#
#   2. $script:rdsServerRoot - the parent of your RDS SERVER OUs. Each
#      direct child of this is the per-client folder containing that
#      client's RDS hosts. Quick Find's "all clients" mode walks every
#      computer beneath this root.
#
# In a single-tenant setup where the same OU holds both servers and users,
# set both variables to the same string. In a typical MSP "hosting" layout
# (which is the case RhinoShadow was built for), they're different - users
# live under one tree and servers under another, linked by matching client
# OU names.
#
# HOW CLIENT MATCHING WORKS:
#   The Client dropdown shows the names from $script:clientRoot. When you
#   pick a client (say "Clearlake"), the script looks for a matching same-
#   named direct child under $script:rdsServerRoot to find that client's
#   RDS servers. The match is case-insensitive. If no same-named server OU
#   exists, the Browse panel will show no servers for that client - and
#   the activity log will say so explicitly.
#
# FORMAT: standard LDAP distinguished name, leaf-first.
#   OU=<leaf>,OU=<parent>,...,DC=<sub>,DC=<root>
#
# HOW TO FIND YOURS:
#   In Active Directory Users and Computers, enable View > Advanced
#   Features, right-click the parent OU, Properties > Attribute Editor,
#   copy "distinguishedName".
#
# EXAMPLES:
#   MSP hosting layout (separate server + tenant trees):
#     $clientRoot    = "OU=FocusNet - Hosting,DC=focusnet,DC=net,DC=au"
#     $rdsServerRoot = "OU=RDS Servers,OU=Servers,DC=focusnet,DC=net,DC=au"
#
#   Single-tenant flat layout (everything under one OU):
#     $clientRoot    = "OU=RDS,DC=corp,DC=local"
#     $rdsServerRoot = "OU=RDS,DC=corp,DC=local"
#
# These two lines are the only ones you should ever need to change to
# point RhinoShadow at a new domain.
# ==============================================================================

$script:clientRoot    = "OU=FocusNet - Hosting,DC=focusnet,DC=net,DC=au"
$script:rdsServerRoot = "OU=RDS Servers,OU=Servers,DC=focusnet,DC=net,DC=au"

# $script:domainRoot is auto-derived. Used by Get-UPNMap (domain-wide UPN
# lookup). Kept as DC= components only so it works regardless of where
# user accounts physically live.
$script:domainRoot = ($script:clientRoot -split ',' | Where-Object { $_ -match '^DC=' }) -join ','

# ==============================================================================
# >>>  END OF CONFIGURATION - the rest of the script is generic  <<<
# ==============================================================================

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

# Log paths. Using $env:LOCALAPPDATA\Temp rather than $env:TEMP because
# $env:TEMP can resolve to a session-numbered subfolder (e.g. Temp\3\) when
# the script is launched via a VBS shim or certain other contexts. LOCALAPPDATA
# always points to the base user temp directory.
$tempDir  = Join-Path $env:LOCALAPPDATA "Temp"
$crashLog    = Join-Path $tempDir "RhinoShadow_crash.log"
$activityLog = Join-Path $tempDir "RhinoShadow.log"


# ==============================================================================
# SECTION 5 - AD / RDS query functions (no UI)
# ==============================================================================

# 5a - Get-RhinoOUs
# -----------------
# List the DIRECT-CHILD organizational units under an LDAP path. Returns
# an array of PSCustomObjects with:
#   Display = the OU name as shown in dropdowns (just the leaf name).
#   Path    = the full distinguishedName for LDAP:// binding.
#
# SCOPE NOTE: this uses OneLevel, not Subtree. The intent is "list the
# clients" - which means listing direct children of the tenant root, not
# every nested OU inside every client's internal tree. In an MSP layout
# each client has their own internal Users/Computers/Groups sub-tree and
# we DO NOT want those polluting the client dropdown. A previous
# subtree-walk version produced 87 entries on this user's domain when
# they have ~20 actual clients.
function Get-RhinoOUs {
    param([string]$adPath)
    $ouList = @()
    $entry = $null
    $searcher = $null
    $result = $null
    try {
        $entry = New-Object System.DirectoryServices.DirectoryEntry("LDAP://" + $adPath)
        $searcher = New-Object System.DirectoryServices.DirectorySearcher($entry)
        $searcher.Filter = '(objectClass=organizationalUnit)'
        $searcher.SearchScope = [System.DirectoryServices.SearchScope]::OneLevel
        $searcher.PropertiesToLoad.Add("name") | Out-Null
        $searcher.PropertiesToLoad.Add("distinguishedName") | Out-Null
        $result = $searcher.FindAll()
        foreach ($obj in $result) {
            $name = $obj.Properties['name'][0]
            $dn   = $obj.Properties['distinguishedName'][0]
            $ouList += [PSCustomObject]@{
                Display = $name.ToString()
                Path    = $dn.ToString()
            }
        }
    } catch {
        if (Get-Command Write-RhinoLog -ErrorAction SilentlyContinue) {
            Write-RhinoLog "AD error enumerating OUs under '$adPath': $_" "error"
        }
    } finally {
        if ($result)   { try { $result.Dispose() }   catch { } }
        if ($searcher) { try { $searcher.Dispose() } catch { } }
        if ($entry)    { try { $entry.Dispose() }    catch { } }
    }
    return $ouList
}

# 5b - Get-RhinoServers
# ---------------------
# Enumerate computer objects (RDS hosts) under an LDAP path. Returns an
# array of computer names (just the `name` attribute, not full DNs - the
# names are what quser /server expects).
#
# Uses SearchScope.Subtree by default because some MSP clients have their
# RDS hosts nested one OU level deeper than others (e.g. .../ClientX/
# Production/RDS vs just .../ClientX/RDS) and we want both layouts to
# work without a per-client config.
#
# PropertiesToLoad is restricted to "name" only. Without that restriction
# AD returns the full property set per computer object (~100 attributes
# each) and the wire payload becomes meaningful on big OUs.
#
# Disposal of the SearchResultCollection, DirectorySearcher and
# DirectoryEntry is in a finally block - these wrap COM objects and
# leaking them across many calls in a long-lived host accumulates handles.
# Failures are logged (when Write-RhinoLog is defined) but otherwise
# swallowed; an empty list is a valid return for "no servers found".
function Get-RhinoServers {
    param([string]$adPath)
    $serverList = @()
    $entry = $null
    $searcher = $null
    $result = $null
    try {
        $entry = New-Object System.DirectoryServices.DirectoryEntry("LDAP://" + $adPath)
        $searcher = New-Object System.DirectoryServices.DirectorySearcher($entry)
        $searcher.Filter = '(objectClass=computer)'
        # Restrict returned properties - without this, AD ships every
        # attribute of every computer object (~100+ each). Name is all we
        # need; this cuts the wire payload substantially on large OUs.
        $searcher.PropertiesToLoad.Add("name") | Out-Null
        $result = $searcher.FindAll()
        foreach ($obj in $result) { $serverList += $obj.Properties['name'][0] }
    } catch {
        if (Get-Command Write-RhinoLog -ErrorAction SilentlyContinue) {
            Write-RhinoLog "AD error enumerating servers in '$adPath': $_" "error"
        }
    } finally {
        if ($result)   { try { $result.Dispose() }   catch { } }
        if ($searcher) { try { $searcher.Dispose() } catch { } }
        if ($entry)    { try { $entry.Dispose() }    catch { } }
    }
    return $serverList
}

# 5c - Get-AllRhinoServers / Get-RhinoServerOuForClient
# -----------------------------------------------------
# Get-AllRhinoServers returns every server under $script:rdsServerRoot,
# cached after first call. Pass -Force to invalidate the cache (used by
# the Refresh button when in Quick Find "all clients" mode). Since
# Get-RhinoServers walks subtree, one call from the root picks up every
# server in every per-client folder underneath - no need to iterate the
# per-client OUs separately.
function Get-AllRhinoServers {
    param([switch]$Force)
    if ($script:allServersCache -and -not $Force) {
        return $script:allServersCache
    }
    $servers = Get-RhinoServers $script:rdsServerRoot
    # Deduplicate (defensive) and sort so log output reads nicely.
    $script:allServersCache = $servers | Sort-Object -Unique
    return $script:allServersCache
}

# Get-RhinoServerOuForClient performs the cross-tree client name match
# that makes the MSP layout work. The Client dropdown is populated from
# $script:clientRoot (tenant tree), but Browse-mode server lookups and
# Quick Find's "scope to one client" mode need the matching OU under
# $script:rdsServerRoot (server tree). Given a client display name (e.g.
# "Clearlake") this returns the LDAP DN of the matching server-side OU,
# or $null if no same-named OU exists there.
#
# The match is case-insensitive. The map is built lazily on first call
# and cached in $script:rdsServerOuMap for the rest of the session.
function Get-RhinoServerOuForClient {
    param([string]$ClientName)
    if (-not $ClientName) { return $null }
    if (-not $script:rdsServerOuMap) {
        $script:rdsServerOuMap = @{}
        $entries = Get-RhinoOUs $script:rdsServerRoot
        foreach ($e in $entries) {
            $script:rdsServerOuMap[$e.Display.ToLower()] = $e.Path
        }
    }
    $key = $ClientName.ToLower()
    if ($script:rdsServerOuMap.ContainsKey($key)) {
        return $script:rdsServerOuMap[$key]
    }
    return $null
}

# 5d - Resolve-RhinoUsernames
# ----------------------------
# Given a freetext search term, query AD for matching user accounts and
# return their SAM account names plus UPNs. Searches across:
#   - sAMAccountName  (login name, e.g. jsmith_acme)
#   - displayName     (e.g. "Jane Smith")
#   - givenName       (first name)
#   - sn              (surname)
#   - userPrincipalName (UPN prefix, e.g. jsmith_acme@example.com.au)
#
# Returns an array of hashtables @{ Sam = '...'; UPN = '...' }. If AD is
# unreachable or the search fails, returns an empty array so the caller
# falls back to raw username matching.
function Resolve-RhinoUsernames {
    param(
        [string]$term,
        [string]$SearchRoot = ""   # LDAP path to scope the search. Empty = entire domain.
    )
    # Disposal is in a finally block so an exception during result iteration
    # doesn't leak the SearchResultCollection (which holds COM resources).
    $results = @()
    $entry = $null
    $searcher = $null
    $found = $null
    try {
        $ldapBase = if ($SearchRoot) { $SearchRoot } else { $script:domainRoot }
        $entry = New-Object System.DirectoryServices.DirectoryEntry("LDAP://" + $ldapBase)
        $searcher = New-Object System.DirectoryServices.DirectorySearcher($entry)
        # LDAP filter value escaping. ORDER MATTERS: backslash MUST be done
        # first, otherwise the \28/\29/\2a we add for ()/* would themselves
        # get re-escaped to \5c28 etc, breaking the filter on any input
        # that contains parens, stars, or backslashes.
        $escaped = $term -replace '\\','\\5c' -replace '\(','\\28' -replace '\)','\\29' -replace '\*','\\2a'
        $searcher.Filter = "(|" +
            "(sAMAccountName=*$escaped*)" +
            "(displayName=*$escaped*)" +
            "(givenName=*$escaped*)" +
            "(sn=*$escaped*)" +
            "(userPrincipalName=*$escaped*)" +
            ")"
        $searcher.SearchScope = [System.DirectoryServices.SearchScope]::Subtree
        $searcher.PropertiesToLoad.Add("sAMAccountName") | Out-Null
        $searcher.PropertiesToLoad.Add("userPrincipalName") | Out-Null
        $searcher.SizeLimit = 200
        $found = $searcher.FindAll()
        foreach ($obj in $found) {
            $sam = $obj.Properties['sAMAccountName']
            $upn = $obj.Properties['userPrincipalName']
            if ($sam -and $sam.Count -gt 0) {
                $results += @{
                    Sam = $sam[0].ToString()
                    UPN = if ($upn -and $upn.Count -gt 0) { $upn[0].ToString() } else { "" }
                }
            }
        }
    } catch {
        if (Get-Command Write-RhinoLog -ErrorAction SilentlyContinue) {
            Write-RhinoLog "AD user lookup failed, falling back to raw match: $_" "warn"
        }
    } finally {
        if ($found)    { try { $found.Dispose() }    catch { } }
        if ($searcher) { try { $searcher.Dispose() } catch { } }
        if ($entry)    { try { $entry.Dispose() }    catch { } }
    }
    return $results
}

# 5e - Get-UPNMap
# ----------------
# Given a list of SAM account names, return a hashtable keyed by SAM with
# UPN as the value. Uses a single LDAP query with an OR filter across all
# provided SAMs rather than one query per user. Returns an empty hashtable
# if AD is unreachable or the list is empty.
function Get-UPNMap {
    param([string[]]$SamNames)
    # Use a case-insensitive hashtable so quser-reported case differences
    # against AD-reported case never cause a UPN lookup miss.
    $map = New-Object 'System.Collections.Hashtable' ([System.StringComparer]::OrdinalIgnoreCase)
    if (-not $SamNames -or $SamNames.Count -eq 0) { return $map }
    # Filter out error/empty SAMs before building the LDAP filter.
    $valid = @($SamNames | Where-Object { $_ -and $_ -ne "(error)" })
    if ($valid.Count -eq 0) { return $map }
    # Chunk the SAM list. LDAP filter strings have practical length limits
    # and the disjunction count gets unwieldy past ~100 clauses, so we batch
    # 100 SAMs per query and merge into one hashtable. For typical browse
    # results (single client, 5-50 sessions) this is one chunk anyway.
    $chunkSize = 100
    $entry = $null
    try {
        $entry = New-Object System.DirectoryServices.DirectoryEntry("LDAP://" + $script:domainRoot)
        for ($i = 0; $i -lt $valid.Count; $i += $chunkSize) {
            $end = [Math]::Min($i + $chunkSize - 1, $valid.Count - 1)
            $chunk = $valid[$i..$end]
            $searcher = $null
            $result = $null
            try {
                $searcher = New-Object System.DirectoryServices.DirectorySearcher($entry)
                # Build (|(sAMAccountName=sam1)(sAMAccountName=sam2)...) filter.
                # Escape LDAP special chars in each SAM value to avoid filter
                # injection or breakage on legitimately unusual account names.
                # ORDER MATTERS: backslash MUST be escaped first - see the same
                # comment in Resolve-RhinoUsernames for the reasoning.
                $clauses = $chunk | ForEach-Object {
                    $esc = $_ -replace '\\','\\5c' -replace '\(','\\28' -replace '\)','\\29' -replace '\*','\\2a'
                    "(sAMAccountName=$esc)"
                }
                $searcher.Filter = "(|$($clauses -join ''))"
                $searcher.SearchScope = [System.DirectoryServices.SearchScope]::Subtree
                $searcher.PropertiesToLoad.Add("sAMAccountName") | Out-Null
                $searcher.PropertiesToLoad.Add("userPrincipalName") | Out-Null
                $searcher.SizeLimit = 1000
                $result = $searcher.FindAll()
                foreach ($obj in $result) {
                    $sam = $obj.Properties['sAMAccountName']
                    $upn = $obj.Properties['userPrincipalName']
                    if ($sam -and $sam.Count -gt 0) {
                        $map[$sam[0].ToString()] = if ($upn -and $upn.Count -gt 0) { $upn[0].ToString() } else { "" }
                    }
                }
            } finally {
                if ($result)   { try { $result.Dispose() }   catch { } }
                if ($searcher) { try { $searcher.Dispose() } catch { } }
            }
        }
    } catch {
        if (Get-Command Write-RhinoLog -ErrorAction SilentlyContinue) {
            Write-RhinoLog "UPN bulk lookup failed: $_" "warn"
        }
    } finally {
        if ($entry) { try { $entry.Dispose() } catch { } }
    }
    return $map
}


# 5f - Parse-QuserOutput
# ----------------------
# Parse the full output of `query user` into session objects.
# Returns an array of PSObjects (one per session) or @() if no sessions.
#
# WHY THIS FUNCTION EXISTS:
# The original Shadow User script used `-split '\s+', 7` and skipped any
# line that didn't produce 7 fields. This silently dropped DISCONNECTED
# sessions because a disconnected session has no SESSIONNAME, so the
# split produces 6 fields instead of 7. Disconnected sessions are exactly
# the ones the IT team needs to find and log off, so missing them was a
# real bug.
#
# WHY HEADER-DRIVEN PARSING:
# An earlier version used hardcoded substring offsets (1, 23, 41, 46, 54,
# 65). That works on default en-US Server 2016/2019 output but breaks
# silently when:
#   - The USERNAME column widens to fit a long SAM (overruns into SESSIONNAME)
#   - The server is non-English (column widths differ per locale)
#   - A future Windows release adjusts the padding
#
# So instead we read the header row, find each column header word's start
# position, and use those as the slice boundaries for every subsequent
# data line. The header is always the first non-blank line of output and
# always contains USERNAME / SESSIONNAME / ID / STATE / IDLE TIME / LOGON
# TIME in that order (with appropriate localised translations).
#
# The header words we look for are tried in order: en-US first, then known
# alternates. If the header can't be parsed we fall back to fixed offsets
# so behaviour is never worse than the previous version.
function Parse-QuserOutput {
    param([string[]]$lines, [string]$server)
    if (-not $lines -or $lines.Count -eq 0) { return @() }

    # Find the header line (first non-blank line starting with USERNAME or
    # known localised equivalents). The leading character is whitespace or
    # ">" - check from column 1 onwards.
    $headerIdx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        if ([string]::IsNullOrWhiteSpace($l)) { continue }
        if ($l -match '^\s*(USERNAME|BENUTZERNAME|UTILISATEUR|NOMBRE\s+DE\s+USUARIO)') {
            $headerIdx = $i; break
        }
    }

    # Compute column starts from the header. The $col* variables are
    # pre-seeded with en-US fixed offsets and only get overwritten if the
    # header parse succeeds and is well-ordered. If parsing fails we
    # silently use those defaults - behaviour is never worse than the
    # pre-header-driven version.
    $colUser=1; $colSess=23; $colId=41; $colState=46; $colIdle=54; $colLogon=65
    if ($headerIdx -ge 0) {
        $h = $lines[$headerIdx]
        # Try each column header by literal substring search. IndexOf returns
        # -1 if not present, in which case we accept fallback for that column.
        # WARNING: do not rename $pIdAt back to $pId or anything case-folding
        # to $PID. PowerShell variable names are case-insensitive and $PID is
        # a read-only automatic - any write to $pId throws "Cannot overwrite
        # variable PID because it is read-only or constant" which caused
        # every single server query to fail in v1.69 dev.
        $pUser  = $h.IndexOf("USERNAME")
        $pSess  = $h.IndexOf("SESSIONNAME")
        $pIdAt  = $h.IndexOf("ID", [Math]::Max(0, $pSess))
        $pState = $h.IndexOf("STATE")
        $pIdle  = $h.IndexOf("IDLE TIME")
        $pLogon = $h.IndexOf("LOGON TIME")
        # Only adopt the parsed positions if all six were found AND in the
        # expected order. Any inconsistency = stick with the en-US defaults.
        if ($pUser -ge 0 -and $pSess -gt $pUser -and $pIdAt -gt $pSess -and
            $pState -gt $pIdAt -and $pIdle -gt $pState -and $pLogon -gt $pIdle) {
            $colUser = $pUser; $colSess = $pSess; $colId = $pIdAt
            $colState = $pState; $colIdle = $pIdle; $colLogon = $pLogon
        }
    }

    $results = @()
    $start = if ($headerIdx -ge 0) { $headerIdx + 1 } else { 0 }
    for ($i = $start; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match '^\s*USERNAME') { continue }   # extra header (paranoia)
        $isCurrent = $line.StartsWith('>')
        # Replace the > marker with a space so column positions align.
        $clean = if ($isCurrent) { ' ' + $line.Substring(1) } else { $line }
        # Defensive: need at least enough length to slice the logon column.
        if ($clean.Length -lt ($colLogon + 1)) { continue }

        try {
            $username    = $clean.Substring($colUser,  $colSess  - $colUser ).Trim()
            $sessionName = $clean.Substring($colSess,  $colId    - $colSess ).Trim()
            $idText      = $clean.Substring($colId,    $colState - $colId   ).Trim()
            $state       = $clean.Substring($colState, $colIdle  - $colState).Trim()
            $idleTime    = $clean.Substring($colIdle,  $colLogon - $colIdle ).Trim()
            $logonTime   = $clean.Substring($colLogon).Trim()
        } catch {
            continue
        }
        if ([string]::IsNullOrWhiteSpace($username) -or [string]::IsNullOrWhiteSpace($idText)) {
            continue
        }
        $results += [PSCustomObject]@{
            Username    = $username
            SessionName = $sessionName
            SessionID   = $idText
            State       = $state
            IdleTime    = $idleTime
            LogonTime   = $logonTime
            Server      = $server
            IsCurrent   = $isCurrent
        }
    }
    return ,$results
}

# 5g - Get-RhinoSessions
# ----------------------
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

    # All pool usage wrapped in try/finally so a Create() / AddScript failure
    # mid-dispatch can't leak the pool or already-allocated pipes.
    $jobs = @()
    $allSessions = @()
    try {

    # The script each runspace executes. We MUST do all parsing inside the
    # runspace and only return primitive PSObjects to the main thread,
    # because runspaces can't share function references with the parent
    # scope. So we inline a copy of the parser here.
    $workerScript = {
        param($server)
        # Inline header-driven parser - mirrors Parse-QuserOutput in the
        # main scope. Duplicated here because runspaces don't inherit
        # functions from the parent. If this ever drifts from the main
        # function, fix both.
        function Parse-Block {
            param([string[]]$lines, [string]$srv)
            if (-not $lines -or $lines.Count -eq 0) { return @() }
            $headerIdx = -1
            for ($i = 0; $i -lt $lines.Count; $i++) {
                $l = $lines[$i]
                if ([string]::IsNullOrWhiteSpace($l)) { continue }
                if ($l -match '^\s*(USERNAME|BENUTZERNAME|UTILISATEUR|NOMBRE\s+DE\s+USUARIO)') {
                    $headerIdx = $i; break
                }
            }
            $colUser=1; $colSess=23; $colId=41; $colState=46; $colIdle=54; $colLogon=65
            if ($headerIdx -ge 0) {
                $h = $lines[$headerIdx]
                # WARNING: do not rename $pIdAt to $pId. PowerShell variable
                # names are case-insensitive and $PID is a read-only automatic
                # - any write to $pId throws inside the runspace and the whole
                # server query fails. See the parent Parse-QuserOutput.
                $pUser  = $h.IndexOf("USERNAME")
                $pSess  = $h.IndexOf("SESSIONNAME")
                $pIdAt  = $h.IndexOf("ID", [Math]::Max(0, $pSess))
                $pState = $h.IndexOf("STATE")
                $pIdle  = $h.IndexOf("IDLE TIME")
                $pLogon = $h.IndexOf("LOGON TIME")
                if ($pUser -ge 0 -and $pSess -gt $pUser -and $pIdAt -gt $pSess -and
                    $pState -gt $pIdAt -and $pIdle -gt $pState -and $pLogon -gt $pIdle) {
                    $colUser = $pUser; $colSess = $pSess; $colId = $pIdAt
                    $colState = $pState; $colIdle = $pIdle; $colLogon = $pLogon
                }
            }
            $out = @()
            $start = if ($headerIdx -ge 0) { $headerIdx + 1 } else { 0 }
            for ($i = $start; $i -lt $lines.Count; $i++) {
                $line = $lines[$i]
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                if ($line -match '^\s*USERNAME') { continue }
                $isCurrent = $line.StartsWith('>')
                $clean = if ($isCurrent) { ' ' + $line.Substring(1) } else { $line }
                if ($clean.Length -lt ($colLogon + 1)) { continue }
                try {
                    $username    = $clean.Substring($colUser,  $colSess  - $colUser ).Trim()
                    $sessionName = $clean.Substring($colSess,  $colId    - $colSess ).Trim()
                    $idText      = $clean.Substring($colId,    $colState - $colId   ).Trim()
                    $state       = $clean.Substring($colState, $colIdle  - $colState).Trim()
                    $idleTime    = $clean.Substring($colIdle,  $colLogon - $colIdle ).Trim()
                    $logonTime   = $clean.Substring($colLogon).Trim()
                } catch { continue }
                if ([string]::IsNullOrWhiteSpace($username)) { continue }
                $out += [PSCustomObject]@{
                    Username    = $username
                    SessionName = $sessionName
                    SessionID   = $idText
                    State       = $state
                    IdleTime    = $idleTime
                    LogonTime   = $logonTime
                    Server      = $srv
                    IsCurrent   = $isCurrent
                    ClientName  = ""   # populated by WTS lookup after parse
                }
            }
            return ,$out
        }
        $results = @()
        try {
            # 2>$null suppresses stderr noise like "No User exists for *"
            # which is what quser emits for an idle server with no sessions.
            $output = query user /server:$server 2>$null
            if ($output) {
                # Coerce to string array so Parse-Block can index by line.
                $lines = @($output | ForEach-Object { "$_" })
                $parsed = Parse-Block $lines $server
                foreach ($p in $parsed) { $results += $p }
            }
            # Decorate each parsed session with the WTS ClientName (the
            # hostname of the local PC the RDP user connected from). We
            # open ONE WTS handle per server, look up ClientName for each
            # session in a tight loop, then close. This keeps the RPC
            # overhead per server low - WTSOpenServer is the expensive
            # bit, individual WTSQuerySessionInformation calls are cheap
            # once the handle is open.
            # WTSClientName is info class 10 (WTS_INFO_CLASS enum).
            if ($results.Count -gt 0) {
                $hServer = [System.IntPtr]::Zero
                try {
                    $hServer = [WTS.NativeMethods]::WTSOpenServer($server)
                    if ($hServer -ne [System.IntPtr]::Zero) {
                        for ($i = 0; $i -lt $results.Count; $i++) {
                            $clientName = ""
                            $sid = 0
                            if ([int]::TryParse($results[$i].SessionID, [ref]$sid)) {
                                $pBuf = [System.IntPtr]::Zero
                                $bytes = 0
                                try {
                                    $ok = [WTS.NativeMethods]::WTSQuerySessionInformation($hServer, $sid, 10, [ref]$pBuf, [ref]$bytes)
                                    if ($ok -and $pBuf -ne [System.IntPtr]::Zero) {
                                        $clientName = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($pBuf)
                                        if ($null -eq $clientName) { $clientName = "" }
                                    }
                                } finally {
                                    if ($pBuf -ne [System.IntPtr]::Zero) {
                                        [WTS.NativeMethods]::WTSFreeMemory($pBuf)
                                    }
                                }
                            }
                            # ClientName property already exists on the
                            # PSCustomObject from Parse-Block (set to ""),
                            # so direct property assignment works here -
                            # no need for Add-Member.
                            $results[$i].ClientName = $clientName
                        }
                    }
                } catch {
                    # WTS lookup failure is non-fatal - the row still has
                    # everything else. ClientName stays "" / absent.
                } finally {
                    if ($hServer -ne [System.IntPtr]::Zero) {
                        [WTS.NativeMethods]::WTSCloseServer($hServer)
                    }
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
                ClientName  = ""
            }
        }
        return ,$results   # Comma forces array return even when only one item
    }

    # Dispatch one runspace per server.
    foreach ($srv in $Servers) {
        $ps = [powershell]::Create()
        $ps.RunspacePool = $pool
        $null = $ps.AddScript($workerScript).AddArgument($srv)
        $jobs += @{ Pipe = $ps; Handle = $ps.BeginInvoke(); Server = $srv }
    }

    # Collect results. EndInvoke blocks until that runspace finishes - but
    # because we dispatched all of them before any started collecting, they
    # run concurrently regardless.
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

    } finally {
        # Defensive: if dispatch threw partway through, dispose any pipes
        # that were created but never collected from above.
        foreach ($job in $jobs) {
            if ($job.Pipe) {
                try { $job.Pipe.Dispose() } catch { }
            }
        }
        try { $pool.Close() } catch { }
        try { $pool.Dispose() } catch { }
    }
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
    $form.Text = "RhinoShadow v1.69"
    # Sized to fit all 8 grid columns at their default widths without
    # horizontal scroll. Bumped from 950/1050 to 1085/1190 when the
    # Local Computer column was added (~135px wider).
    $form.MinimumSize = New-Object System.Drawing.Size(1085, 780)
    $form.Size        = New-Object System.Drawing.Size(1190, 830)
    # Derive the usable content width from the form's client area minus left+right margins.
    # All anchored panels use this so they never overflow the right edge regardless of
    # window chrome width. Anchor=Top,Left,Right then handles resize correctly from here.
    $margin = 15
    $contentW = $form.ClientSize.Width - ($margin * 2)
    $form.StartPosition = "CenterScreen"
    $form.Font = $fontRegular
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Font
    $form.BackColor = $script:t.Bg
    $form.ForeColor = $script:t.Text
    if (Test-Path $iconPath) {
        try { $form.Icon = New-Object System.Drawing.Icon($iconPath) } catch { }
    }

    # Action-in-flight tracking. Destructive actions (Sign Out, Send Message)
    # set this to a human-readable description when they start their
    # synchronous blocking work, and clear it in their finally. The
    # FormClosing handler reads it to decide whether to prompt the user
    # before closing.
    # Sign Out specifically runs in a background runspace polled by a
    # WinForms Timer (see Invoke-SignOut). $script:asyncTimers tracks any
    # such active timers so FormClosing can stop them cleanly on close-
    # anyway - otherwise a Tick after form disposal crashes trying to
    # access disposed controls.
    $script:actionInFlight = $null
    $script:asyncTimers = @()

    # FormClosing handler:
    #   1. If a destructive action is in flight, prompt the user with a
    #      modal Yes/No. Yes -> proceed with close (action is abandoned,
    #      activity log records that). No -> cancel the close by setting
    #      $_.Cancel and stay open.
    #   2. On actual close: write the session-ended marker to the activity
    #      log and dispose script-level font GDI handles. Without disposal,
    #      repeated runs in the same PowerShell session leak GDI font
    #      objects (Windows reclaims them at process exit anyway, so this
    #      only matters for long-lived hosts).
    $form.Add_FormClosing({
        if ($script:actionInFlight) {
            $msg  = "RhinoShadow is currently: $($script:actionInFlight).`n`n"
            $msg += "If you close now the action may not complete cleanly and the activity log will record it as abandoned.`n`n"
            $msg += "Close anyway?"
            $ans = [System.Windows.Forms.MessageBox]::Show($msg, "RhinoShadow - Action in Flight", 'YesNo', 'Warning')
            if ($ans -ne 'Yes') {
                $_.Cancel = $true
                return
            }
            # Stop any active async-action timers so their next Tick doesn't
            # fire against this disposed form's controls. The runspaces
            # themselves keep running until the underlying OS process (e.g.
            # logoff.exe) finishes - which is fine, they don't reference
            # the form.
            foreach ($t in $script:asyncTimers) {
                try { $t.Stop(); $t.Dispose() } catch { }
            }
            $script:asyncTimers = @()
            # Record the abandonment in the audit log before we lose the
            # textbox handle to disposal below.
            try {
                $stamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                Add-Content -Path $activityLog -Value "$stamp ABANDONED: $($script:actionInFlight) (form closed before completion)" -Encoding UTF8
            } catch { }
        }
        try {
            $stamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            Add-Content -Path $activityLog -Value "=== RhinoShadow session ended $stamp ===" -Encoding UTF8
        } catch { }
        foreach ($f in @($fontRegular, $fontSemibold, $fontTitle, $fontSubtitle, $fontHeader, $fontMono)) {
            try { if ($f) { $f.Dispose() } } catch { }
        }
    })

    # ------------------------------------------------------------------
    # SECTION 6b - Header panel (mascot, title, theme + help buttons)
    # ------------------------------------------------------------------
    $headerPanel = New-Object System.Windows.Forms.Panel
    $headerPanel.Location = New-Object System.Drawing.Point(0, 0)
    $headerPanel.Size = New-Object System.Drawing.Size(1050, 90)
    $headerPanel.Dock = 'Top'
    $headerPanel.BackColor = $script:t.Surface
    # Custom Paint to draw a thin bottom border in the active palette colour.
    # try/finally so a GDI exception during draw doesn't leak the Pen handle
    # on every repaint (which over many resizes/theme toggles would exhaust
    # the per-process GDI handle quota).
    $headerPanel.Add_Paint({
        $g = $_.Graphics
        $pen = New-Object System.Drawing.Pen($script:t.Border, 1)
        try {
            $g.DrawLine($pen, 0, $headerPanel.Height - 1, $headerPanel.Width, $headerPanel.Height - 1)
        } finally {
            $pen.Dispose()
        }
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

    # Theme + Help buttons anchored to top-right. The X coordinates here
    # are the INITIAL positions at default form width (1190). The Top,Right
    # anchor then preserves the distance from the right edge on resize, so
    # the buttons stay tucked in the corner regardless of how wide the
    # user makes the window.
    $anchorTR = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
    $themeButton = New-RhinoButton -Text "Light" -X 1025 -Y 20 -W 70 -H 28 -Role "btn-neutral" -Parent $headerPanel -Anchor $anchorTR
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

    $helpButton = New-RhinoButton -Text "?" -X 1100 -Y 20 -W 32 -H 28 -Role "btn-help" -Parent $headerPanel -Anchor $anchorTR

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
    $quickFindBox.Size = New-Object System.Drawing.Size($contentW, 110)
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
    $findEverywhereButton = New-RhinoButton -Text "Find Everywhere" -X 455 -Y 28 -W 140 -H 30 -Role "btn-accent" -Parent $quickFindBox

    # Helper text on the right side. The default text is referenced from
    # multiple places (initial render, scope-cleared, scope-leave-blank) so
    # we keep one canonical copy in $script:scopeHintAll to avoid drift.
    $script:scopeHintAll = "Searches every RDS server across every client OU. Partial names OK."
    $quickFindHint = New-Object System.Windows.Forms.Label
    $quickFindHint.Text = $script:scopeHintAll
    $quickFindHint.Location = New-Object System.Drawing.Point(610, 28)
    $quickFindHint.Size = New-Object System.Drawing.Size(390, 40)
    $quickFindHint.Anchor = 'Top,Left,Right'
    $quickFindHint.AutoSize = $false
    $quickFindHint.Font = $fontSubtitle
    $quickFindHint.BackColor = $script:t.Bg
    $quickFindHint.ForeColor = $script:t.Muted
    $quickFindBox.Controls.Add($quickFindHint)
    Register-Themed -Control $quickFindHint -Role "muted"

    # Client scope dropdown. Leave blank to search all clients (default
    # behaviour). Selecting a specific client restricts the search to that
    # OU's servers only - much faster when you already know which client
    # the user is on.
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
    $scopeDropdown.BackColor = $script:t.Surface
    $scopeDropdown.ForeColor = $script:t.Text
    $quickFindBox.Controls.Add($scopeDropdown)
    Register-Themed -Control $scopeDropdown -Role "input"

    # Clear-scope button next to the dropdown. Resets the scope to "all clients"
    # and restores the default hint + button text in one click.
    $clearScopeButton = New-RhinoButton -Text "All" -X 448 -Y 65 -W 40 -H 26 -Role "btn-neutral" -Parent $quickFindBox -OnClick {
        $scopeDropdown.Text = ""
        $quickFindHint.Text = $script:scopeHintAll
        $findEverywhereButton.Text = "Find Everywhere"
    }

    # Update the hint label and button text when the scope dropdown changes.
    # Wired to BOTH SelectedIndexChanged AND Leave - same problem we hit
    # with the client dropdown: with AutoCompleteMode = SuggestAppend, the
    # autocomplete commit fires SelectedIndexChanged but not Leave (focus
    # stays on the dropdown). The Leave path catches the typed-and-tabbed
    # case where SelectedIndexChanged didn't fire because no popup was
    # involved. Either way the button text and hint stay in sync with the
    # current scope.
    $updateScopeUi = {
        if ($scopeDropdown.Text -eq "") {
            $quickFindHint.Text = $script:scopeHintAll
            $findEverywhereButton.Text = "Find Everywhere"
        } else {
            $quickFindHint.Text = "Searches only $($scopeDropdown.Text.Trim()) servers. Partial names OK."
            $findEverywhereButton.Text = "Find in Client"
        }
    }
    $scopeDropdown.Add_SelectedIndexChanged($updateScopeUi)
    $scopeDropdown.Add_Leave($updateScopeUi)

    # Pressing Enter in the username box is the same as clicking Find.
    # Cleaner workflow - never have to touch the mouse for the common case.
    $usernameTextBox.Add_KeyDown({
        if ($_.KeyCode -eq 'Enter') {
            $findEverywhereButton.PerformClick()
            $_.SuppressKeyPress = $true
        }
    })

    # ------------------------------------------------------------------
    # SECTION 6e - Browse by Client panel (secondary path)
    # ------------------------------------------------------------------
    # Traditional flow: pick a client from the dropdown, see its RDS hosts
    # appear in a check-list (all ticked by default), click Show Sessions.
    # Useful for "everyone on PER-SH118 right now" or pre-restart sweeps.
    # The dropdown uses the same name-based cross-tree lookup as Quick
    # Find's scope - the client name comes from $script:clientRoot and
    # the servers come from the matching OU under $script:rdsServerRoot.
    $browseBox = New-Object System.Windows.Forms.GroupBox
    $browseBox.Text = " Browse by Client "
    $browseBox.Font = $fontHeader
    $browseBox.Location = New-Object System.Drawing.Point(15, 220)
    $browseBox.Size = New-Object System.Drawing.Size($contentW, 165)
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
    $clientDropdown.BackColor = $script:t.Surface
    $clientDropdown.ForeColor = $script:t.Text
    $browseBox.Controls.Add($clientDropdown)
    Register-Themed -Control $clientDropdown -Role "input"

    # Clear button: empties the dropdown and the server list.
    # Named "Clear" not "All" because that's what it does - it CLEARS the
    # current selection rather than selecting all clients (which wouldn't
    # make sense in Browse mode anyway).
    $clearClientButton = New-RhinoButton -Text "Clear" -X 448 -Y 30 -W 50 -H 26 -Role "btn-neutral" -Parent $browseBox -OnClick {
        $clientDropdown.Text = ""
        $serverListBox.Items.Clear()
    }

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

    # Select All / Deselect All toggle for the server checklist.
    $selectAllButton = New-RhinoButton -Text "Select All" -X 455 -Y 70  -W 120 -H 30 -Role "btn-neutral" -Parent $browseBox -OnClick {
        # Toggle: if everything is already checked, uncheck all.
        $anyUnchecked = $false
        for ($i = 0; $i -lt $serverListBox.Items.Count; $i++) {
            if (-not $serverListBox.GetItemChecked($i)) { $anyUnchecked = $true; break }
        }
        for ($i = 0; $i -lt $serverListBox.Items.Count; $i++) {
            $serverListBox.SetItemChecked($i, $anyUnchecked)
        }
    }

    # Show Sessions: triggers the parallel query against the ticked servers.
    # Handler wired further down once the worker function exists.
    $showUsersButton = New-RhinoButton -Text "Show Sessions" -X 455 -Y 105 -W 120 -H 30 -Role "btn-success" -Parent $browseBox

    # Browse panel hint
    $browseHint = New-Object System.Windows.Forms.Label
    $browseHint.Text = "Pick a client, tick the RDS hosts you want to inspect, then Show Sessions."
    $browseHint.Location = New-Object System.Drawing.Point(595, 75)
    $browseHint.Size = New-Object System.Drawing.Size(405, 40)
    $browseHint.Anchor = 'Top,Left,Right'
    $browseHint.AutoSize = $false
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
    $sessionsBox.Size = New-Object System.Drawing.Size($contentW, 230)
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

    # Clear button to the right of the filter. Empties the filter text;
    # the TextChanged handler then re-runs Apply-SessionFilter automatically
    # and the full unfiltered grid comes back.
    $clearFilterButton = New-RhinoButton -Text "Clear" -X 368 -Y 27 -W 55 -H 27 -Role "btn-neutral" -Parent $sessionsBox -OnClick {
        $filterTextBox.Text = ""
    }

    # Session count label - lives in the top-right of the sessions box
    $countLabel = New-Object System.Windows.Forms.Label
    $countLabel.Text = "0 sessions"
    $countLabel.Anchor = 'Top,Right'
    # Initial X positioned for the default form width (sessionsBox at
    # full contentW ~1160). Top,Right anchor keeps the label tucked in
    # the corner during resize.
    $countLabel.Location = New-Object System.Drawing.Point(1040, 32)
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
    $sessionsGrid.Size = New-Object System.Drawing.Size(($contentW - 30), 160)
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
    # scans first when deciding who to log off. ClientName (the local PC
    # the user RDP'd FROM) goes on the right because it's the field we
    # use for RMM-into-the-workstation handoffs.
    # "Session" instead of "Session ID" so the header fits on one line.
    $colDefs = @(
        @{ Name = "Username";   Header = "Username";       Width = 160; Sort = 'Automatic' }
        @{ Name = "State";      Header = "State";          Width = 80;  Sort = 'Automatic' }
        @{ Name = "IdleTime";   Header = "Idle";           Width = 80;  Sort = 'Automatic' }
        @{ Name = "LogonTime";  Header = "Logon Time";     Width = 160; Sort = 'Automatic' }
        @{ Name = "Server";     Header = "RDS Server";     Width = 135; Sort = 'Automatic' }
        @{ Name = "SessionID";  Header = "Session";        Width = 75;  Sort = 'Automatic' }
        @{ Name = "UPN";        Header = "UPN";            Width = 210; Sort = 'Automatic' }
        @{ Name = "ClientName"; Header = "Local Computer"; Width = 135; Sort = 'Automatic' }
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
    $actionPanel.Size = New-Object System.Drawing.Size($contentW, 40)
    $actionPanel.Anchor = 'Bottom,Left,Right'
    $actionPanel.BackColor = $script:t.Bg
    $form.Controls.Add($actionPanel)
    Register-Themed -Control $actionPanel -Role "form"

    # The four primary action buttons. Order chosen to match common workflow:
    # Shadow first (most common), Sign Out (next), Send Message (occasional),
    # Refresh (just re-runs the last query - bound to the rightmost slot).
    # Click handlers are wired further down once the Invoke-* worker functions
    # are defined; we just build the buttons here.
    $shadowButton  = New-RhinoButton -Text "Shadow"       -X 0   -Y 4 -W 110 -H 32 -Role "btn-accent"  -Parent $actionPanel
    $signOutButton = New-RhinoButton -Text "Sign Out"     -X 120 -Y 4 -W 110 -H 32 -Role "btn-danger"  -Parent $actionPanel
    $sendMsgButton = New-RhinoButton -Text "Send Message" -X 240 -Y 4 -W 130 -H 32 -Role "btn-neutral" -Parent $actionPanel
    $refreshButton = New-RhinoButton -Text "Refresh"      -X 380 -Y 4 -W 110 -H 32 -Role "btn-success" -Parent $actionPanel

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
    $logBox.Size = New-Object System.Drawing.Size($contentW, 80)
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

    # Write a timestamped line to the activity log textbox AND tee a copy
    # to the on-disk activity log at $activityLog. The $level argument
    # selects a 5-char prefix shown after the timestamp:
    #   "info"  -> "     " (blank, used for status updates)
    #   "ok"    -> "[OK] "
    #   "warn"  -> "[!]  "
    #   "error" -> "[ERR]"
    # The file log captures the same line so there's a persistent audit
    # trail even after the user closes the form.
    function Write-RhinoLog {
        param([string]$message, [string]$level = "info")
        $stamp = (Get-Date).ToString("HH:mm:ss")
        $prefix = switch ($level) {
            "error" { "[ERR]" }
            "warn"  { "[!]  " }
            "ok"    { "[OK] " }
            default { "     " }
        }
        $line = "$stamp $prefix $message"
        $logBox.AppendText("$line`r`n")
        # File log failures are silently swallowed so a full disk or
        # permissions issue never breaks the UI.
        try { Add-Content -Path $activityLog -Value $line -Encoding UTF8 } catch { }
    }

    # Repopulate the sessionsGrid from $script:currentSessions, applying
    # the live filter from $filterTextBox if one is set.
    #
    # The grid is the SOURCE OF TRUTH FOR THE USER but $script:currentSessions
    # is the SOURCE OF TRUTH FOR THE DATA. Whenever currentSessions changes
    # (query completes, row deleted after sign-out) we call this to push the
    # updated data into the grid. The filter textbox's TextChanged also
    # calls this on every keystroke for live filtering.
    #
    # Filter semantics:
    #   - Case-insensitive substring match.
    #   - Matches against Username, Server, State, and ClientName (the local
    #     PC the user RDP'd from). Includes ClientName specifically so the
    #     IT operator can filter the grid by "I'm on LAPTOP-42" without
    #     having to scroll to find that workstation.
    #   - Uses .Contains() not -like so '*' and '?' in the filter text are
    #     treated as literal characters rather than wildcards.
    #
    # Updates the countLabel ("X of Y sessions" when filtered, "X sessions"
    # otherwise) so the operator can see at a glance how many rows the
    # current filter is hiding.
    function Apply-SessionFilter {
        $filter = $filterTextBox.Text.Trim().ToLower()
        $sessionsGrid.Rows.Clear()
        $shown = 0
        foreach ($s in $script:currentSessions) {
            if ($filter) {
                # Filter matches if it's a substring of Username, Server,
                # or State. Case insensitive. Username is the common case
                # but Server lets you e.g. type "PROD" to see only prod
                # servers, and "Disc" to see only disconnected. Using
                # .Contains() rather than -like so '*' and '?' in the
                # filter text are treated literally not as wildcards.
                # ClientName is included so you can search by the local
                # PC name (handy when someone tells you "I'm on LAPTOP-42").
                $haystack = "$($s.Username) $($s.Server) $($s.State) $($s.ClientName)".ToLower()
                if (-not $haystack.Contains($filter)) { continue }
            }
            $idx = $sessionsGrid.Rows.Add(
                $s.Username, $s.State, $s.IdleTime, $s.LogonTime,
                $s.Server, $s.SessionID, $s.UPN, $s.ClientName
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

    # The PRIMARY workflow function: given a username (or partial), find
    # every active session for that user across the RDS estate.
    #
    # Pipeline:
    #   1. Read username from $usernameTextBox. Empty -> warn and return.
    #   2. Resolve scope. If the Quick Find scope dropdown has a client
    #      picked, we use that client's tenant DN for the AD search and
    #      that client's matching RDS server OU for the server enumeration.
    #      If scope is empty, AD search is domain-wide and server enum is
    #      every RDS host under $script:rdsServerRoot.
    #   3. AD search: Resolve-RhinoUsernames returns matching SAMs and UPNs.
    #      If AD returns nothing we fall back to wildcard matching on raw
    #      quser usernames - the search still works, just without UPN
    #      enrichment.
    #   4. Server enumeration: Get-RhinoServers (scoped) or Get-AllRhinoServers
    #      (everything). If the unscoped count is large enough we prompt
    #      before proceeding so accidental "search everywhere" can be
    #      cancelled.
    #   5. Get-RhinoSessions runs quser against every server in parallel
    #      via the runspace pool. This is the bulk of the wait time and
    #      includes per-session WTS ClientName lookups.
    #   6. Filter the combined results to matching usernames (AD-resolved
    #      SAMs, or wildcard fallback). Error-marker rows from failed
    #      servers are PRESERVED so failures surface in the grid rather
    #      than being silently dropped.
    #   7. Push to currentSessions, refresh the grid, log a summary.
    # If exactly one match, the row is auto-selected so the operator can
    # press Sign Out or Shadow without further clicks.
    function Find-UserEverywhere {
        $query = $usernameTextBox.Text.Trim()
        if (-not $query) {
            Write-RhinoLog "Type a username first." "warn"
            return
        }
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try {
            # Determine client scope first. In MSP layouts the tenant tree
            # (where users live) and the RDS server tree are separate, so
            # picking a client requires TWO DN lookups:
            #   - $userSearchRoot: the client OU under $script:clientRoot,
            #     used to scope the AD user search. Comes from ouPathMap.
            #   - $serverScopeOu: the same-named OU under $script:rdsServerRoot
            #     that holds that client's RDS hosts. Comes from
            #     Get-RhinoServerOuForClient.
            # If either lookup fails we degrade gracefully: missing user
            # root = domain-wide user search; missing server OU = error
            # because there's nowhere to send the quser query.
            $scopedClient = if ($scopeDropdown.Text.Trim()) { $scopeDropdown.Text.Trim() } else { $null }
            $userSearchRoot = ""
            $serverScopeOu = $null
            if ($scopedClient) {
                if ($script:ouPathMap.ContainsKey($scopedClient)) {
                    $userSearchRoot = $script:ouPathMap[$scopedClient]
                } else {
                    Write-RhinoLog "Scope '$scopedClient' isn't a known client - searching all clients." "warn"
                    $scopedClient = $null
                }
                if ($scopedClient) {
                    $serverScopeOu = Get-RhinoServerOuForClient -ClientName $scopedClient
                    if (-not $serverScopeOu) {
                        Write-RhinoLog "No matching RDS server OU found for client '$scopedClient'. Falling back to all-servers query." "warn"
                    }
                }
            }

            # Resolve the search term against AD. When scoped to a client,
            # we search inside that client's tenant OU - which is where the
            # user accounts live in an MSP "hosting" layout. If unscoped,
            # we search the whole domain so we catch users in any client.
            $resolved = @(Resolve-RhinoUsernames -term $query -SearchRoot $userSearchRoot)
            $resolvedSams = @()
            # Case-insensitive so quser case variants don't miss UPN lookup.
            $upnMap = New-Object 'System.Collections.Hashtable' ([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($r in $resolved) {
                $resolvedSams += $r.Sam
                $upnMap[$r.Sam] = $r.UPN
            }

            if ($resolvedSams.Count -gt 0) {
                Write-RhinoLog "AD resolved '$query' to: $($resolvedSams -join ', ')"
            } else {
                Write-RhinoLog "No AD match for '$query', falling back to raw username wildcard." "warn"
            }

            if ($scopedClient -and $serverScopeOu) {
                Write-RhinoLog "Enumerating RDS servers for client '$scopedClient'..."
                $servers = @(Get-RhinoServers $serverScopeOu)
            } else {
                Write-RhinoLog "Enumerating RDS servers across all clients..."
                $servers = @(Get-AllRhinoServers)
            }
            if (-not $servers -or $servers.Count -eq 0) {
                Write-RhinoLog "No RDS servers found. Check connectivity or client selection." "error"
                return
            }
            $scope = if ($scopedClient) { "client '$scopedClient'" } else { "all clients" }
            # Modal confirmation when we're about to query a large unscoped
            # search. Two conditions both have to be true:
            #   - The user has NOT picked a client (unscoped Find Everywhere).
            #     Scoped searches always proceed silently - the user made a
            #     deliberate choice about what to query.
            #   - The server count is large enough that the wait would be
            #     noticeable (>=30 servers = 2+ batches through the 15-thread
            #     runspace pool).
            # The confirmation is to catch the case where someone forgot to
            # set the scope and hit Enter, intending only one client. The
            # wait cursor is reset before the dialog opens so the user
            # isn't staring at an hourglass while deciding.
            if (-not $scopedClient -and $servers.Count -ge 30) {
                $form.Cursor = [System.Windows.Forms.Cursors]::Default
                $confirmMsg = "Are you sure you want to search '$query' across ALL $($servers.Count) servers? This may take a while."
                $ans = [System.Windows.Forms.MessageBox]::Show($confirmMsg, "RhinoShadow - Confirm Large Search", 'YesNo', 'Warning')
                if ($ans -ne 'Yes') {
                    Write-RhinoLog "Large search cancelled by user. Pick a client from the scope dropdown to narrow it." "warn"
                    return
                }
                # Re-arm the wait cursor for the actual query.
                $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
            }
            Write-RhinoLog "Querying $($servers.Count) server(s) in parallel across $scope..."
            $allSessions = Get-RhinoSessions -Servers $servers

            # Exact SAM match against resolved names if AD gave us results;
            # otherwise fall back to wildcard on raw session username.
            # Always preserve "(error)" marker rows so a server that failed
            # the query is visible in the grid as an ERROR-state row rather
            # than silently dropped (which would hide the failure entirely).
            $errors = @($allSessions | Where-Object { $_.Username -eq "(error)" })
            $hits = if ($resolvedSams.Count -gt 0) {
                $allSessions | Where-Object { $resolvedSams -contains $_.Username }
            } else {
                $allSessions | Where-Object { $_.Username -like "*$query*" }
            }
            $hits = @($hits) + $errors

            # Stamp the UPN onto each matched session so the grid can display
            # it. Sessions from quser only carry the SAM account name; the UPN
            # comes from the AD map we built above. Browse-mode sessions that
            # didn't go through AD resolution will already have UPN = "".
            $hits = @($hits | ForEach-Object {
                $upn = if ($upnMap.ContainsKey($_.Username)) { $upnMap[$_.Username] } else { "" }
                $_ | Add-Member -NotePropertyName UPN -NotePropertyValue $upn -Force -PassThru
            })

            $script:currentSessions = @($hits)
            Apply-SessionFilter
            # Count real matches separately from error markers so the log
            # message doesn't claim "1 match" when the only row is an ERROR.
            $realCount = @($hits | Where-Object { $_.Username -ne "(error)" }).Count
            $errCount  = $errors.Count
            # If any servers errored, surface the FIRST error message so the
            # user can actually see what went wrong rather than just "4 errored".
            # The error message is stashed in the LogonTime field of each
            # error marker (see worker script in Get-RhinoSessions).
            if ($errCount -gt 0) {
                $firstErr = $errors[0]
                Write-RhinoLog "First error was on $($firstErr.Server): $($firstErr.LogonTime)" "error"
            }
            if ($realCount -eq 0) {
                if ($errCount -gt 0) {
                    Write-RhinoLog "No sessions matched '$query'. $errCount server(s) errored during query - see ERROR rows in grid for details." "warn"
                } else {
                    Write-RhinoLog "No sessions found matching '$query'. Maybe they've already logged off." "warn"
                }
            } elseif ($realCount -eq 1) {
                $m = @($hits | Where-Object { $_.Username -ne "(error)" })[0]
                $suffix = if ($errCount -gt 0) { " ($errCount server error(s) shown below.)" } else { "" }
                Write-RhinoLog "Found '$($m.Username)' on $($m.Server) (session $($m.SessionID), $($m.State)).$suffix" "ok"
                if ($sessionsGrid.Rows.Count -gt 0) { $sessionsGrid.Rows[0].Selected = $true }
            } else {
                $suffix = if ($errCount -gt 0) { " ($errCount server error(s) shown.)" } else { "" }
                Write-RhinoLog "Found $realCount sessions matching '$query'.$suffix" "ok"
            }
        } catch {
            Write-RhinoLog "Find failed: $_" "error"
        } finally {
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    }

    # The SECONDARY workflow function: show every active session on a
    # specific set of RDS hosts, regardless of who's logged in.
    #
    # Used when the operator already knows which servers they care about
    # (e.g. pre-restart sweeps, "everyone on PER-SH118 right now",
    # investigating a specific host's load). The Browse panel's checklist
    # is the input - any ticked servers get queried.
    #
    # Differences from Find-UserEverywhere:
    #   - No username filter. Every session on every ticked server appears
    #     in the grid.
    #   - No AD-side user resolution upfront. UPN enrichment is done
    #     reactively via Get-UPNMap after the quser results come in -
    #     one bulk AD query for every SAM in the result set, not one per
    #     user.
    #   - Error markers from failed servers are shown in the grid as
    #     ERROR rows, with the failure reason in the LogonTime cell.
    # As with Find, the heavy lifting is parallel quser via Get-RhinoSessions.
    function Show-SessionsForSelectedServers {
        $checked = @($serverListBox.CheckedItems)
        if ($checked.Count -eq 0) {
            Write-RhinoLog "Tick at least one server first." "warn"
            return
        }
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try {
            # Sort and join the chosen server names so the audit log records
            # exactly which hosts were queried, not just how many.
            $serverList = ($checked | Sort-Object) -join ", "
            Write-RhinoLog "Querying $($checked.Count) selected server(s): $serverList"
            $allSessions = Get-RhinoSessions -Servers $checked
            # Bulk-resolve UPNs for all SAM accounts in the result set using
            # a single AD query rather than one per user.
            $samList = @($allSessions | Where-Object { $_.Username -ne "(error)" } | Select-Object -ExpandProperty Username -Unique)
            $upnMap = Get-UPNMap -SamNames $samList
            $allSessions = @($allSessions | ForEach-Object {
                $upn = if ($upnMap.ContainsKey($_.Username)) { $upnMap[$_.Username] } else { "" }
                $_ | Add-Member -NotePropertyName UPN -NotePropertyValue $upn -Force -PassThru
            })
            $script:currentSessions = @($allSessions)
            Apply-SessionFilter
            # Distinguish real session count from error markers for the log
            # message - "5 sessions returned" lies if 4 of those are servers
            # that errored on quser.
            $realCount = @($allSessions | Where-Object { $_.Username -ne "(error)" }).Count
            $errCount  = @($allSessions | Where-Object { $_.Username -eq "(error)" }).Count
            if ($errCount -gt 0) {
                Write-RhinoLog "$realCount session(s) returned. $errCount server(s) errored - shown as ERROR rows." "warn"
            } else {
                Write-RhinoLog "$realCount session(s) returned." "ok"
            }
        } catch {
            Write-RhinoLog "Browse query failed: $_" "error"
        } finally {
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    }

    # Pull the selected session as a PSObject. Returns $null and logs a
    # warning if:
    #   - no row is selected
    #   - the selected row is an ERROR marker (server-query-failure row)
    #   - the selected row is missing critical data (SessionID, Server)
    # All callers (Shadow, SignOut, SendMessage) rely on this so a single
    # gate here is enough to keep destructive actions away from bad data.
    function Get-SelectedSession {
        if ($sessionsGrid.SelectedRows.Count -eq 0) {
            Write-RhinoLog "Select a session in the grid first." "warn"
            return $null
        }
        $row = $sessionsGrid.SelectedRows[0]
        $username   = $row.Cells["Username"].Value
        $sessionID  = $row.Cells["SessionID"].Value
        $server     = $row.Cells["Server"].Value
        $state      = $row.Cells["State"].Value
        $clientName = $row.Cells["ClientName"].Value
        # Block ERROR rows. These represent servers that failed the quser
        # query - there's no real session here to act on, and logoff.exe
        # called with a blank SessionID can log off the WRONG session.
        if ($state -eq "ERROR" -or $username -eq "(error)") {
            Write-RhinoLog "That row is an error marker, not a real session. Pick a real one." "warn"
            return $null
        }
        # Reject anything missing the IDs we need to dispatch. Defensive -
        # shouldn't happen if Parse-QuserOutput did its job, but a malformed
        # quser line that slipped through could produce a row with no ID.
        if (-not $sessionID -or -not $server) {
            Write-RhinoLog "Selected row is missing session ID or server name - cannot act on it." "warn"
            return $null
        }
        return [PSCustomObject]@{
            Username   = $username
            SessionID  = $sessionID
            Server     = $server
            State      = $state
            ClientName = $clientName
        }
    }

    # Tiny helper for log messages: returns " from <ClientName>" when the
    # ClientName is known, or "" otherwise. This keeps action log lines
    # concise when we don't have a workstation name (e.g. disconnected
    # session, WTS lookup failed) while still recording it in the audit
    # trail when we do.
    function Get-ClientNameSuffix {
        param($s)
        if ($s.ClientName) { return " from $($s.ClientName)" } else { return "" }
    }

    # Launch mstsc.exe in shadow mode against the selected session. The
    # operator gets a live view of the user's desktop and (with /control)
    # full keyboard + mouse input - the standard helpdesk takeover.
    #
    # Design choices worth knowing:
    #   - /control is included for full input control. Drop it for view-
    #     only shadowing if your environment requires it (some compliance
    #     setups do).
    #   - The target session must be in the Active state. quser reports
    #     "Disc" for disconnected sessions and mstsc can't shadow those
    #     because there's no live display surface. We check up front and
    #     warn rather than letting mstsc fail opaquely.
    #   - We rely on the SHADOW GPO at the RDS host end to control whether
    #     the user sees a consent prompt. RhinoShadow doesn't (and can't)
    #     override that policy.
    #   - Unlike Sign Out, this is FIRE AND FORGET. No async runspace,
    #     no exit-code check. mstsc launches its own GUI process and
    #     manages its own lifetime; we just kick it off and move on.
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
        Write-RhinoLog "Launching mstsc /shadow for $($s.Username) on $($s.Server)$(Get-ClientNameSuffix $s)..."
        Start-Process mstsc -ArgumentList "/v:$($s.Server)", "/shadow:$($s.SessionID)", "/control"
    }

    # Sign out (logoff) a session. This is the most common destructive
    # action so the confirmation dialog spells out exactly who/where.
    #
    # logoff.exe's exit code is unreliable on some Server 2019 configurations
    # - it can return 0 even when the operation silently failed (e.g.
    # access denied, session already gone, RPC issue). So after running it
    # we re-query the server for that session ID and confirm it really did
    # disappear before we report success.
    #
    # ASYNC EXECUTION:
    # The logoff + verification runs in a background runspace, NOT on the
    # UI thread. A WinForms Timer polls $handle.IsCompleted every 200ms and
    # finalises the operation when the runspace finishes. This keeps the
    # UI message pump alive during the wait, which is important because:
    #   1. The user can still interact with other parts of the app
    #      (filter the grid, look at the log) while it runs.
    #   2. If they click X mid-action, the FormClosing handler can actually
    #      fire and show the "action in flight" warning. Previously the
    #      synchronous Start-Process -Wait would block the message pump,
    #      Windows would mark the form as "Not Responding", and FormClosing
    #      would only fire after the wait returned.
    #
    # $script:actionInFlight is set while the runspace is in progress and
    # cleared when it completes (or when the user confirms close-anyway).
    function Invoke-SignOut {
        $s = Get-SelectedSession
        if (-not $s) { return }
        $msg = "Sign out $($s.Username) on $($s.Server)?`n`nThis is immediate. Any unsaved work is lost."
        $ans = [System.Windows.Forms.MessageBox]::Show($msg, "RhinoShadow - Sign Out", 'YesNo', 'Warning')
        if ($ans -ne 'Yes') { return }
        $script:actionInFlight = "signing out $($s.Username) on $($s.Server)"

        # Disable destructive buttons during the operation so the user
        # can't queue a second action on top.
        $signOutButton.Enabled = $false
        $sendMsgButton.Enabled = $false

        # The runspace runs everything that would otherwise have blocked
        # the UI thread: logoff.exe (synchronous wait), 500ms settle, and
        # the verification quser. Returns a hashtable that the UI thread
        # turns into log messages and grid updates after IsCompleted.
        $workScript = {
            param($sessionId, $server)
            $result = @{ Success = $false; StillThere = $false; ErrorMessage = $null }
            # Capture stderr to a temp file so we get the human-readable
            # reason ("Access is denied", "The RPC server is unavailable",
            # etc) when logoff.exe fails. Without this we only get the
            # exit code, which is uniformly 1 for almost every failure
            # mode and useless for diagnosis.
            $errFile = [System.IO.Path]::GetTempFileName()
            try {
                $p = Start-Process -FilePath "logoff.exe" -ArgumentList "$sessionId", "/server:$server" -Wait -PassThru -NoNewWindow -RedirectStandardError $errFile
                if ($p.ExitCode -ne 0) {
                    $stderr = ""
                    try { $stderr = (Get-Content -Path $errFile -Raw -ErrorAction Stop).Trim() } catch { }
                    if ($stderr) {
                        $result.ErrorMessage = "logoff.exe (code $($p.ExitCode)): $stderr"
                    } else {
                        $result.ErrorMessage = "logoff.exe exited with code $($p.ExitCode)"
                    }
                    return $result
                }
                Start-Sleep -Milliseconds 500
                try {
                    $verify = query user /server:$server 2>$null
                    if ($verify) {
                        $escaped = [regex]::Escape($sessionId)
                        foreach ($line in $verify) {
                            if ($line -match "\s$escaped\s") {
                                $result.StillThere = $true
                                break
                            }
                        }
                    }
                    $result.Success = $true
                } catch {
                    $result.ErrorMessage = "Verification failed: $_"
                }
            } catch {
                $result.ErrorMessage = "$_"
            } finally {
                try { Remove-Item -Path $errFile -Force -ErrorAction SilentlyContinue } catch { }
            }
            return $result
        }
        $ps = [powershell]::Create()
        $null = $ps.AddScript($workScript).AddArgument($s.SessionID).AddArgument($s.Server)
        $asyncHandle = $ps.BeginInvoke()

        # Timer polls for completion on the UI thread. 200ms keeps it
        # snappy without burning cycles.
        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 200
        # Stash everything the Tick handler needs into Tag so the closure
        # doesn't have to capture script-scoped variables across the boundary.
        $timer.Tag = @{
            Pipe       = $ps
            Handle     = $asyncHandle
            Session    = $s
        }
        # Track this timer so FormClosing can stop it on close-anyway -
        # otherwise the Tick after disposal would crash on disposed controls.
        $script:asyncTimers += $timer
        $timer.Add_Tick({
            $state = $this.Tag
            if (-not $state.Handle.IsCompleted) { return }
            $this.Stop()
            $sess = $state.Session
            try {
                $r = $state.Pipe.EndInvoke($state.Handle)
                if ($r.ErrorMessage) {
                    Write-RhinoLog "Sign-out failed: $($r.ErrorMessage)" "error"
                } elseif (-not $r.Success) {
                    Write-RhinoLog "Sign-out issued for $($sess.Username) on $($sess.Server) but verification was inconclusive." "warn"
                } elseif ($r.StillThere) {
                    Write-RhinoLog "Sign-out for $($sess.Username) on $($sess.Server) reported success but session $($sess.SessionID) is still active. Check permissions or session state." "error"
                } else {
                    Write-RhinoLog "Sign-out confirmed: $($sess.Username) on $($sess.Server) (session $($sess.SessionID))$(Get-ClientNameSuffix $sess)." "ok"
                    $script:currentSessions = @($script:currentSessions | Where-Object {
                        -not ($_.Server -eq $sess.Server -and $_.SessionID -eq $sess.SessionID)
                    })
                    Apply-SessionFilter
                }
            } catch {
                Write-RhinoLog "Sign-out post-processing failed: $_" "error"
            } finally {
                try { $state.Pipe.Dispose() } catch { }
                # Remove from the tracking array before disposing so we
                # don't accumulate dead references.
                $script:asyncTimers = @($script:asyncTimers | Where-Object { $_ -ne $this })
                $this.Dispose()
                $script:actionInFlight = $null
                $signOutButton.Enabled = $true
                $sendMsgButton.Enabled = $true
            }
        })
        Write-RhinoLog "Sign-out dispatched for $($s.Username) on $($s.Server) - waiting for confirmation..."
        $timer.Start()
    }

    # Send a pop-up message to the selected session via msg.exe. Prompts
    # for the message body with a small custom dialog.
    #
    # Caveat: msg.exe's exit code is unreliable like logoff.exe's - it can
    # return 0 even when the message wasn't actually delivered (no console
    # session, RPC blocked, session too stale to receive). Unlike sign-out
    # there is no server-side way to verify delivery, so we trust the exit
    # code and log it as "issued" rather than "confirmed". The full message
    # body is recorded in the activity log on a second line so the audit
    # trail captures what was sent regardless of delivery.
    #
    # Why this runs SYNCHRONOUSLY while Sign Out runs ASYNC:
    # msg.exe is short-lived - it queues the message via RPC and returns
    # within a fraction of a second. The blocking wait is negligible and
    # not worth the runspace+timer plumbing that Sign Out needs. If a
    # specific deployment finds msg.exe hanging for long enough to be a
    # problem, lift the async pattern from Invoke-SignOut into here.
    function Invoke-SendMessage {
        $s = Get-SelectedSession
        if (-not $s) { return }
        # Build a small custom dialog rather than using
        # [Microsoft.VisualBasic.Interaction]::InputBox - that one can't be
        # styled to match the theme, can't constrain input length, and
        # gives no character counter. A short purpose-built dialog avoids
        # users typing essays into a pop-up that's meant to be a quick
        # heads-up. The cap is 255 chars which is what WTS messages
        # typically render cleanly within.
        $maxLen = 255
        $dlg = New-Object System.Windows.Forms.Form
        $dlg.Text = "RhinoShadow - Send Message"
        $dlg.Size = New-Object System.Drawing.Size(480, 240)
        $dlg.StartPosition = "CenterParent"
        $dlg.FormBorderStyle = 'FixedDialog'
        $dlg.MaximizeBox = $false
        $dlg.MinimizeBox = $false
        $dlg.BackColor = $script:t.Bg
        $dlg.ForeColor = $script:t.Text
        $dlg.Font = $fontRegular

        $prompt = New-Object System.Windows.Forms.Label
        $prompt.Text = "Message to send to $($s.Username) on $($s.Server):"
        $prompt.Location = New-Object System.Drawing.Point(15, 15)
        $prompt.Size = New-Object System.Drawing.Size(440, 20)
        $prompt.BackColor = $script:t.Bg
        $prompt.ForeColor = $script:t.Text
        $dlg.Controls.Add($prompt)

        $msgBox = New-Object System.Windows.Forms.TextBox
        $msgBox.Location = New-Object System.Drawing.Point(15, 45)
        $msgBox.Size = New-Object System.Drawing.Size(440, 80)
        $msgBox.Multiline = $true
        $msgBox.MaxLength = $maxLen   # hard cap enforced by the control itself
        $msgBox.AcceptsReturn = $true
        $msgBox.BackColor = $script:t.Surface
        $msgBox.ForeColor = $script:t.Text
        $msgBox.BorderStyle = 'FixedSingle'
        $dlg.Controls.Add($msgBox)

        # Character counter that updates as the user types, so they can see
        # how much room they have left before hitting MaxLength.
        $counter = New-Object System.Windows.Forms.Label
        $counter.Text = "0 / $maxLen"
        $counter.Location = New-Object System.Drawing.Point(15, 130)
        $counter.Size = New-Object System.Drawing.Size(200, 18)
        $counter.BackColor = $script:t.Bg
        $counter.ForeColor = $script:t.Muted
        $dlg.Controls.Add($counter)
        $msgBox.Add_TextChanged({ $counter.Text = "$($msgBox.TextLength) / $maxLen" })

        # OK / Cancel. OK is the default (Enter doesn't insert a newline in
        # single-line mode, but since this is Multiline we accept that the
        # user has to click OK or Ctrl+Enter equivalent - DialogResult on
        # button click is the simplest contract here).
        $okBtn = New-RhinoButton -Text "Send" -X 270 -Y 160 -W 85 -H 30 -Role "btn-accent"  -Parent $dlg
        $cancelBtn = New-RhinoButton -Text "Cancel" -X 365 -Y 160 -W 90 -H 30 -Role "btn-neutral" -Parent $dlg
        $okBtn.Add_Click({ $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK; $dlg.Close() })
        $cancelBtn.Add_Click({ $dlg.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $dlg.Close() })
        $dlg.AcceptButton = $okBtn
        $dlg.CancelButton = $cancelBtn

        $result = $dlg.ShowDialog()
        $body = $msgBox.Text
        $dlg.Dispose()
        if ($result -ne [System.Windows.Forms.DialogResult]::OK) { return }
        if (-not $body) { return }

        $script:actionInFlight = "sending a message to $($s.Username) on $($s.Server)"
        # Temp file captures msg.exe stderr so we can include the human-
        # readable error ("Access is denied", "Error 1722 The RPC server
        # is unavailable", "Error 5 access is denied", etc) in the activity
        # log. Exit code 1 alone is uniform across every msg.exe failure
        # mode and not useful for diagnosis.
        $errFile = [System.IO.Path]::GetTempFileName()
        try {
            # msg.exe args: session ID, /server switch, then the message text.
            # The message must be passed as a single quoted token so spaces
            # inside the text don't get split into separate arguments.
            $p = Start-Process -FilePath "msg.exe" -ArgumentList "$($s.SessionID)", "/server:$($s.Server)", "`"$body`"" -Wait -PassThru -NoNewWindow -RedirectStandardError $errFile
            if ($p.ExitCode -ne 0) {
                $stderr = ""
                try { $stderr = (Get-Content -Path $errFile -Raw -ErrorAction Stop).Trim() } catch { }
                if ($stderr) {
                    throw "msg.exe (code $($p.ExitCode)): $stderr"
                } else {
                    throw "msg.exe exited with code $($p.ExitCode)"
                }
            }
            # Flatten whitespace in the body so multi-line or tab-containing
            # messages don't break the activity log's one-line-per-entry
            # format. The full text is preserved in $body for msg.exe itself;
            # only the LOGGED copy is flattened.
            # Log as two separate entries - the issue confirmation line and
            # a follow-up body line - because the message body can be up to
            # 255 chars and crowding it onto the same line as the metadata
            # makes the on-screen log hard to scan.
            $flat = ($body -replace '\s+', ' ').Trim()
            Write-RhinoLog "Message issued to $($s.Username) on $($s.Server)$(Get-ClientNameSuffix $s) (delivery not verifiable):" "ok"
            Write-RhinoLog "  Body: $flat"
        } catch {
            Write-RhinoLog "Message send failed: $_" "error"
        } finally {
            try { Remove-Item -Path $errFile -Force -ErrorAction SilentlyContinue } catch { }
            $script:actionInFlight = $null
        }
    }

    # Re-run whichever query type last populated the grid.
    #
    # $script:lastQueryMode is set by the click handlers of Find Everywhere
    # ("find") and Show Sessions ("browse") to remember which mode the
    # operator was using. Refresh just dispatches to the right function
    # based on that state.
    #
    # If neither has run yet (lastQueryMode is $null), we warn rather than
    # silently doing nothing - the operator was probably expecting SOMETHING
    # to happen and "nothing happens" is the worst UX.
    #
    # Refresh deliberately re-uses the current state of the search fields
    # (username textbox, scope dropdown, ticked servers) rather than
    # capturing them at the time of original query. This is what the
    # operator usually wants: "show me the current state of what I was
    # just looking at".
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

    # Shared logic for loading the server list when the user has chosen
    # a client. Wired to two events to catch all ways the dropdown text
    # can change:
    #   - SelectedIndexChanged: fires when the user picks from the dropdown
    #     list OR when AutoComplete suggest-append commits a suggestion.
    #     This is what SelectionChangeCommitted *should* have caught, but
    #     SelectionChangeCommitted doesn't fire reliably with AutoComplete.
    #   - Leave: catches the case where the user types the name and tabs
    #     away without ever triggering an autocomplete commit.
    # The Clear button (defined earlier in this section) clears state
    # directly and doesn't go through this handler.
    # No skip-if-same-client guard - the AD query takes milliseconds and
    # any guard would risk skipping legitimate re-selects after the
    # autocomplete state machine resets things.
    $loadServersForClient = {
        $selectedOU = $clientDropdown.Text.Trim()
        if (-not $selectedOU) { return }
        # Validate the text against the known master list. If the user
        # typed garbage and tabbed away, do nothing rather than firing a
        # pointless query against an OU that won't exist.
        if ($script:ouOptions -notcontains $selectedOU) { return }
        # Browse mode wants the RDS-side OU, not the tenant-side OU - the
        # dropdown shows client names from the tenant tree but the actual
        # servers live in a parallel server tree. Cross-tree lookup by name.
        $serverOu = Get-RhinoServerOuForClient -ClientName $selectedOU
        if (-not $serverOu) {
            Write-RhinoLog "No matching RDS server OU under '$script:rdsServerRoot' for client '$selectedOU'. Check that the server-tree OU name matches." "error"
            $serverListBox.Items.Clear()
            return
        }
        $servers = Get-RhinoServers $serverOu
        $serverListBox.Items.Clear()
        # CheckedListBox.Items.Add($item, $true) is meant to add pre-checked
        # but is unreliable when CheckOnClick is enabled. Add first, then
        # set the check state by index - this actually ticks them.
        foreach ($s in ($servers | Sort-Object)) {
            $idx = $serverListBox.Items.Add($s)
            $serverListBox.SetItemChecked($idx, $true)
        }
        Write-RhinoLog "Loaded $($servers.Count) servers for client '$selectedOU' (all ticked - untick any you want to skip)."
    }
    $clientDropdown.Add_SelectedIndexChanged($loadServersForClient)
    $clientDropdown.Add_Leave($loadServersForClient)

    # ------------------------------------------------------------------
    # SECTION 6j - Help dialog
    # ------------------------------------------------------------------
    # Build and show a modal help window with workflow walkthroughs, tips,
    # action descriptions, and config notes. Built fresh on every call
    # rather than cached because it's infrequent (one-off click) and
    # building once-then-reuse complicates the lifecycle (theme changes
    # mid-session would leave the cached help dialog in the wrong palette).
    #
    # Content lives in a here-string below and uses RichTextBox with
    # WordWrap=false because the workflow steps and column tables read
    # better at their natural widths than hard-wrapped at the dialog edge.
    # An earlier version used a TextBox which compressed the layout in
    # ways the original author didn't intend.
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
        # Expanding here-string @"..."@ so PowerShell substitutes
        # $script:clientRoot / $script:rdsServerRoot with their actual
        # configured values when the dialog is shown. The whole point of
        # the CONFIGURATION section in the help is to tell whoever is
        # looking at it what THIS deployment is currently pointing at,
        # so they don't have to scroll back up to Section 4. Nothing
        # else in the body contains $-prefixed text that would be
        # misinterpreted, so expansion is safe.
        $body.Text = @"
RhinoShadow - Quick Guide
==========================

THE MAIN WORKFLOW
-----------------
1. Type a name into Quick Find - username, first name, surname, or UPN all
   work. RhinoShadow resolves the search against Active Directory first so
   you never need to know the exact SAM account name.
2. Optionally narrow to a specific client using the Client dropdown (type to
   filter the list). Leave it blank to search everywhere.
3. Press Enter or click Find Everywhere / Find in Client.
4. The grid fills with matching sessions showing Username, State, Idle time,
   Logon Time, RDS Server, Session, UPN, and Local Computer.
5. Click the row, then Sign Out (red) or Shadow (blue). For a quick RMM
   handoff, note the Local Computer name from the grid - that's the user's
   actual workstation, not the RDS host.

TIPS
----
- Partial names work in every field. 'smith' finds 'Jane Smith', 'jsmith_acme',
  or any UPN containing 'smith'.
- Double-click a row to shadow it directly without clicking Shadow first.
- The Filter box above the Sessions grid does a live substring filter across
  Username, Server, State and Local Computer. Type "Disc" to see only
  disconnected sessions, a server name fragment to narrow to one host, or a
  workstation name fragment when the user told you which PC they're on.
- The Local Computer column shows the hostname of the PC the user RDP'd in
  FROM, looked up via the WTS API at query time. Empty means the lookup
  failed (permissions, session in transition, no client info available) -
  not that they connected from nowhere.
- Click any column header to sort by that column.
- Both Client dropdowns support type-to-filter - start typing a client name
  and the list narrows automatically.

BROWSE BY CLIENT
----------------
Use the Browse panel when you want to see ALL sessions on specific servers
(e.g. "everyone currently on a specific host"). Pick the client from the
dropdown, all of that client's servers tick on automatically, untick any
you want to skip, click Show Sessions. UPNs and Local Computer names are
populated for Browse results too.

ACTIONS
-------
  Shadow       Launches mstsc /shadow /control against the selected session.
               Full keyboard and mouse takeover. The user sees a consent
               prompt on their end. Only works on Active sessions - you will
               get a warning if you try to shadow a Disconnected session.
  Sign Out     Runs logoff.exe against the session, then re-queries the
               server to verify the session actually disappeared. If
               logoff.exe reports success but the session is still there
               (a known Server 2019 silent-fail) you get an explicit error
               in the activity log rather than a false-positive OK.
               Immediate - any unsaved work is lost. Confirmation dialog
               always fires first.
  Send Message Runs msg.exe to pop a dialog on the user's session. Useful
               for "please save and log off, rebooting in 10 mins". Note
               that msg.exe's exit code is unreliable - the activity log
               says "issued" not "delivered". If the user's session has
               no console attached, the message silently fails.
  Refresh      Re-runs whichever search you last did (Find or Browse).

CLOSING THE WINDOW
------------------
If you click the X (or Alt+F4) while a Sign Out or Send Message is still
running, RhinoShadow will ask you to confirm before closing. Closing
mid-action leaves an "ABANDONED" entry in the activity log marking that
the action's outcome is unknown.

Sign Out runs in a background runspace so the form stays responsive
during logoff.exe - you can keep using the rest of the app while it
waits. Send Message blocks briefly during msg.exe (it's short-lived,
unlike logoff) but the same guard applies if you do try to close.

LOG FILES
---------
  Activity log   %LOCALAPPDATA%\Temp\RhinoShadow.log
                 Every action logged with timestamps. Each run is marked
                 with a session header showing date, time, Windows username
                 and machine name (e.g. "jsmith on WORKSTATION01") so logs
                 from multiple staff or machines stay attributable.

  Crash log      %LOCALAPPDATA%\Temp\RhinoShadow_crash.log
                 Only written on startup crashes. Check this first if
                 the script opens a crash dialog or silently does nothing
                 when launched with -WindowStyle Hidden.

CONFIG
------
RhinoShadow uses two AD locations set inside the CONFIGURATION banner
block near the top of the script (look for the >>> markers). The values
shown below are what THIS INSTANCE is currently using - they will be
different on other deployments depending on how the script was set up.

  Client root (current value):
    $script:clientRoot
    Parent OU of your client tenants. Each direct child is one client.
    Populates the Client dropdowns and scopes user account searches.

  RDS server root (current value):
    $script:rdsServerRoot
    Parent OU of your RDS server folders. Each direct child should have
    the same name as the matching client's tenant OU.

In single-tenant setups both variables point at the same OU. In MSP
hosting layouts they point at different trees joined by matching client
OU names. To move RhinoShadow between domains: edit those two lines in
the script, save, relaunch.
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
    # The dropdown is populated from $script:clientRoot (the tenant tree),
    # NOT the RDS server tree. In an MSP layout these are different trees
    # joined by client OU name. Server lookups for a selected client use
    # Get-RhinoServerOuForClient to find the matching server-tree OU.
    try {
        $ouEntries = Get-RhinoOUs $script:clientRoot
        $ouEntries = @($ouEntries | Sort-Object Display)
        $script:ouOptions = @($ouEntries | ForEach-Object { $_.Display })
        # Display -> tenant DN map. Used by the AD user search to scope to
        # one client. The map of Display -> RDS server DN is built lazily
        # inside Get-RhinoServerOuForClient and cached for the session.
        $script:ouPathMap = @{}
        foreach ($e in $ouEntries) { $script:ouPathMap[$e.Display] = $e.Path }

        foreach ($display in $script:ouOptions) {
            $clientDropdown.Items.Add($display) | Out-Null
            $scopeDropdown.Items.Add($display)  | Out-Null
        }

        # Register filter behaviour after items are loaded. Both dropdowns
        # get identical treatment - same function, same args, no special cases.
        Register-FilterableDropdown -Dropdown $scopeDropdown  -MasterList $script:ouOptions
        Register-FilterableDropdown -Dropdown $clientDropdown -MasterList $script:ouOptions

        Write-RhinoLog "Loaded $($ouEntries.Count) clients from tenant tree."
        Write-RhinoLog "Ready. Type a username in Quick Find to begin." "ok"
    } catch {
        Write-RhinoLog "Failed to enumerate client OUs: $_" "error"
    }

    # Write a session start marker to the activity log so multiple runs stay
    # clearly separated in the same file.
    $sessionStamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    try { Add-Content -Path $activityLog -Value "" -Encoding UTF8 } catch { }
    try { Add-Content -Path $activityLog -Value "=== RhinoShadow session started $sessionStamp | $env:USERNAME on $env:COMPUTERNAME ===" -Encoding UTF8 } catch { }

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
