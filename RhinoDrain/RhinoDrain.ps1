<#
================================================================================
  RhinoDrain v1.0 - RDS Session Host Drain Manager
================================================================================

  PURPOSE
  -------
  A GUI front end for the otherwise-manual chore of turning RDS session
  hosts on and off inside a collection. "Drain" = block NEW connections on
  a host so users naturally land on the other hosts, then reopen it when
  the box is healthy again. Tagline: "Pool's closed".

  This is a member of the Rhino tool family (RhinoShadow, RhinoCopy) and
  follows Rhino_DesignBrief.md. Theme system, button helper, logging,
  async pattern and FormClosing guard are lifted directly from RhinoShadow
  so the two tools feel identical to operate.

  THE MAIN WORKFLOW
  -----------------
  1. On launch RhinoDrain probes the configured connection brokers and uses
     whichever one actually has the RDS deployment (the other broker throws
     "deployment does not exist" and is skipped automatically).
  2. Pick a collection from the dropdown (type to filter).
  3. The grid lists every session host with its New Connections state shown
     green (Yes) or red (No), plus a live user-session count per host.
  4. Tick the hosts you want to act on, then Block Selected / Allow Selected.
     "Block All Except Selected" funnels everyone onto the host(s) you tick.
  5. When maintenance is done, hit "Allow All (Open Pool)". It reopens every
     host, re-reads the state, and tells you in plain words whether the pool
     is fully open or which hosts are still blocked.

  HONESTY NOTE (per the design brief)
  -----------------------------------
  Set-RDSessionHost returns no useful failure signal on its own, so after
  every change RhinoDrain re-reads the host's state and compares it against
  what was asked for. If a Set "succeeded" but the state did not actually
  change, the activity log says so in red rather than logging a cheerful OK.

  IMPORTANT
  ---------
  Blocking a host blocks NEW logons only. It does NOT kick anyone off the
  box - existing sessions stay until they disconnect or are signed out.
  Use RhinoShadow for forced sign-outs. RhinoDrain only herds new traffic.

  SECTION MAP
  -----------
    1.  Assembly imports + WinForms bootstrap
    2.  Theme palettes + fonts
    3.  Theme helpers (Register-Themed, Apply-ButtonTheme, New-RhinoButton,
        Apply-Theme, Register-FilterableDropdown)
    4.  CONFIGURATION block (broker FQDNs) + script state + paths
    5.  Async worker scriptblocks (broker detect, query/set)
    6.  Form build
        6a. Form shell + FormClosing handler + icon
        6b. Header panel (mascot, title, theme + help buttons)
        6c. Mascot easter egg
        6d. Connection panel (broker status + collection dropdown)
        6e. Hosts grid + filter + select-all controls
        6f. Action buttons row
        6g. Status log
        6h. Worker functions: Write-RhinoLog, Apply-HostFilter,
            Get-CheckedHosts, Start-Detect, Start-RdsAction, action handlers
        6i. Help dialog (Show-RhinoHelp)
        6j. Initial broker detect + ShowDialog
    7.  Outer catch (startup crash logger)

  ASYNC MODEL
  -----------
  Every broker/RDS call can block on RPC for a noticeable time, so all of
  them run in a background runspace polled by a WinForms Timer (the exact
  pattern from RhinoShadow's Invoke-SignOut). The UI thread never blocks,
  FormClosing can always fire, and $script:asyncTimers lets a close-anyway
  stop pending ticks cleanly so they never fire against a disposed form.
================================================================================
#>

# ==============================================================================
# SECTION 1 - Assembly imports + WinForms bootstrap
# ==============================================================================
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
# Must run before any Form is created. Wrapped because re-running the script
# in the same PowerShell session after a form already existed throws
# "DefaultCompatibleTextRenderingDefault has been called already".
try { [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false) } catch { }


# ==============================================================================
# SECTION 2 - Theme palettes + fonts
# ==============================================================================
# Two complete palettes, one active at a time, mirrored into $script:t for
# terse access. Every colour in the UI comes from here - nothing downstream
# is hardcoded. Values are the Rhino family palette from the design brief.
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

# Fonts pre-created at script scope so every control reuses the same Font
# object. Segoe UI is the system font; Consolas is monospace for the log.
$fontRegular  = New-Object System.Drawing.Font("Segoe UI", 10)
$fontSemibold = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
$fontTitle    = New-Object System.Drawing.Font("Segoe UI Semibold", 18)
$fontSubtitle = New-Object System.Drawing.Font("Segoe UI", 9)
$fontHeader   = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
$fontMono     = New-Object System.Drawing.Font("Consolas", 9.5)


# ==============================================================================
# SECTION 3 - Theme helpers
# ==============================================================================
# Conceptually a CSS-class system: each control is registered with a semantic
# role string, the two palettes are two stylesheets, and Apply-Theme is the
# "swap stylesheet" operation. Identical to RhinoShadow.

$script:themedControls = @()

# Tag a control with a semantic role. += rebinds the array rather than
# mutating-and-emitting like .Add() would.
function Register-Themed {
    param($Control, [string]$Role)
    $script:themedControls += @{ Control = $Control; Role = $Role }
}

# Apply a button role to a single Button. Called at build time and on theme
# toggle. FlatStyle = Flat so the OS chrome does not override our colours.
#   btn-accent   - Blue. Primary actions.
#   btn-success  - Green. Constructive (Allow, Refresh).
#   btn-danger   - Red. Destructive (Block).
#   btn-neutral  - Plain surface. Secondary (Clear, theme toggle).
#   btn-help     - Subtle background, accent text. Small "?" header button.
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

# One-call button construction: build, size, position, theme, parent and
# register a button in one expression. Optional -OnClick wires the handler.
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

# Walk every registered control and repaint it from the active palette. Each
# assignment is wrapped so one disposed handle does not abort the whole pass.
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
                "label-body"  { $c.BackColor = $t.Bg;      $c.ForeColor = $t.Text }
                "label-surf"  { $c.BackColor = $t.Surface; $c.ForeColor = $t.Text }
                "grid" {
                    # The DataGridView has many sub-properties that each need
                    # their own palette colours. Set them together so a theme
                    # swap looks right in one go. Per-cell colours (the green/
                    # red New Connections cells) are reapplied separately by
                    # Apply-HostFilter, which the theme toggle also calls.
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

# Make a ComboBox a type-to-filter dropdown using ONLY native WinForms
# AutoComplete (SuggestAppend + ListItems). No custom TextChanged filtering -
# WinForms already does inline completion, the suggestion popup, tab-to-commit
# and arrow cycling correctly, and custom filtering only fights it. This is
# what makes collection search "robust" without bespoke code.
function Register-FilterableDropdown {
    param(
        [System.Windows.Forms.ComboBox]$Dropdown,
        [string[]]$MasterList   # accepted but unused - Items is the source of truth
    )
    $Dropdown.DropDownStyle      = [System.Windows.Forms.ComboBoxStyle]::DropDown
    $Dropdown.AutoCompleteMode   = [System.Windows.Forms.AutoCompleteMode]::SuggestAppend
    $Dropdown.AutoCompleteSource = [System.Windows.Forms.AutoCompleteSource]::ListItems
}


# ==============================================================================
# >>>  CONFIGURATION - EDIT THESE WHEN MOVING TO A NEW DEPLOYMENT  <<<
# ==============================================================================
#
# RhinoDrain needs the connection broker(s) for your RDS deployment.
#
#   $script:brokers - an ORDERED list of connection broker FQDNs. RhinoDrain
#   tries each in turn at startup and uses the FIRST one that actually has
#   the RDS deployment configured. A broker that responds with "A Remote
#   Desktop Services deployment does not exist on <host>" is skipped and the
#   next one is tried. This handles the common multi-broker layout where only
#   one broker in the pair holds the live deployment at any given time, and
#   it means you never have to remember which broker is the right one today.
#
# FORMAT: fully qualified domain names, one per line, most-likely-live first.
#   "broker01.example.com.au"
#
# HOW TO FIND YOURS:
#   On a box with the RDS management tools installed, run:
#     (Get-RDSessionCollection -ConnectionBroker "<fqdn>").CollectionName
#   The broker that lists your collections is a live one. The broker that
#   errors with "deployment does not exist" is the standby and goes second.
#
# EXAMPLE (generic placeholders, not a real deployment):
#   $script:brokers = @(
#       "rds-broker-a.example.com.au",
#       "rds-broker-b.example.com.au"
#   )
#
# These are the only lines you should ever need to change to point RhinoDrain
# at a new deployment.
# ==============================================================================

$script:brokers = @(
    "per-quad-rds1.focusnet.net.au",
    "per-quad-rds2.focusnet.net.au"
)

# ==============================================================================
# >>>  END OF CONFIGURATION - the rest of the script is generic  <<<
# ==============================================================================

# Script state -----------------------------------------------------------------
# The live broker chosen by Start-Detect. $null until detection succeeds.
$script:activeBroker = $null
# The collection whose hosts are currently loaded into the grid. Used to avoid
# redundant reloads when the dropdown fires both SelectedIndexChanged and Leave.
$script:loadedCollection = $null
# Master list of hosts currently displayed. Each item is a PSCustomObject with
# Host (FQDN), State (Yes/No/NotUntilReboot) and Sessions (int, or -1 = unknown).
# The grid is filtered from this; this is the source of truth for the data.
$script:currentHosts = @()
# Set of host FQDNs whose checkbox is ticked, keyed by FQDN so the tick state
# survives filtering and refresh (the grid rows are rebuilt each time).
$script:checkedHosts = @{}

# Resolve the script directory in a launch-context-tolerant way (RhinoCopy
# pattern) so we can find Rhino.png and the .ico beside the script regardless
# of how it was launched (double-click, shortcut, VBS shim, dot-source).
$scriptPath = if ($PSScriptRoot) { $PSScriptRoot }
              elseif ($PSCommandPath) { Split-Path -Parent $PSCommandPath }
              elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path }
              else { (Get-Location).Path }
$iconPath   = Join-Path $scriptPath "RhinoDrain.ico"
$mascotPath = Join-Path $scriptPath "Rhino.png"

# Log paths. LOCALAPPDATA\Temp rather than $env:TEMP because TEMP can resolve
# to a session-numbered subfolder under some launch contexts; LOCALAPPDATA is
# stable.
$tempDir     = Join-Path $env:LOCALAPPDATA "Temp"
$activityLog = Join-Path $tempDir "RhinoDrain.log"
$crashLog    = Join-Path $tempDir "RhinoDrain_crash.log"


# ==============================================================================
# SECTION 5 - Async worker scriptblocks
# ==============================================================================
# These run inside a child runspace ([powershell]::Create()), off the UI
# thread. A child runspace does not inherit the parent's loaded modules, so
# each worker imports RemoteDesktop explicitly. PSModulePath is inherited from
# the process environment so the import resolves normally.

# Broker detection. Tries each broker in order; the first that returns its
# collection list without throwing is the live one. Returns the chosen broker,
# its sorted collection names, and the error text from any broker that failed
# (so the UI can show WHY a broker was skipped rather than hiding it).
$script:detectWorker = {
    param($brokerList)
    $out = @{ Broker = $null; Collections = @(); Errors = @() }
    Import-Module RemoteDesktop -ErrorAction SilentlyContinue
    foreach ($b in $brokerList) {
        try {
            $cols = @(Get-RDSessionCollection -ConnectionBroker $b -ErrorAction Stop |
                      Select-Object -ExpandProperty CollectionName)
            $out.Broker = $b
            $out.Collections = @($cols | Sort-Object)
            break
        } catch {
            $out.Errors += @{ Broker = $b; Message = $_.Exception.Message }
        }
    }
    return $out
}

# Unified query/set worker. Applies any requested NewConnectionAllowed changes,
# then re-reads the whole collection (for verification AND to refresh the grid)
# and the per-host session counts. One code path serves load, refresh, block,
# allow, block-others and open-all - the only difference is the SetList.
#   SetList: array of @{ Host = <fqdn>; Desired = 'Yes'|'No' }
# Returns:
#   Error      - top-level failure message if the re-read itself failed
#   SetResults - per-host @{ Host; Desired; Ok; Error }
#   Hosts      - array of @{ Host; State; Sessions } for the whole collection
$script:rdsWorker = {
    param($broker, $collection, $setList)
    $out = @{ Error = $null; SetResults = @(); Hosts = @() }
    Import-Module RemoteDesktop -ErrorAction SilentlyContinue

    # 1. Apply the requested changes. Each Set is independent: one failing
    #    host must not stop the others, so each gets its own try/catch and a
    #    recorded result. Set-RDSessionHost emits no reliable success signal,
    #    which is why verification happens in step 2 by re-reading state.
    foreach ($item in @($setList)) {
        if ($null -eq $item) { continue }
        $r = @{ Host = $item.Host; Desired = $item.Desired; Ok = $false; Error = $null }
        try {
            Set-RDSessionHost -SessionHost $item.Host -ConnectionBroker $broker -NewConnectionAllowed $item.Desired -ErrorAction Stop
            $r.Ok = $true
        } catch {
            $r.Error = $_.Exception.Message
        }
        $out.SetResults += $r
    }

    # 2. Re-read the collection. This is both the verification source (compare
    #    against Desired in the UI) and the new grid data. If this throws the
    #    whole action is reported as failed - we will not show stale state.
    try {
        $hosts = @(Get-RDSessionHost -CollectionName $collection -ConnectionBroker $broker -ErrorAction Stop)
    } catch {
        $out.Error = $_.Exception.Message
        return $out
    }

    # 3. Per-host session counts. Get-RDUserSession returns every session in
    #    the collection with a HostServer property; group by host short name
    #    (case-insensitive, FQDN-tolerant) rather than making one call per
    #    host. Counts are secondary: if this fails we still return the hosts,
    #    flag counts as unknown (-1) and let the UI log a warning. Honesty
    #    over a fake zero.
    $counts = @{}
    $countsOk = $true
    try {
        $sessions = @(Get-RDUserSession -CollectionName $collection -ConnectionBroker $broker -ErrorAction Stop)
        foreach ($s in $sessions) {
            $key = (([string]$s.HostServer) -split '\.')[0].ToLower()
            if ($counts.ContainsKey($key)) { $counts[$key] = $counts[$key] + 1 } else { $counts[$key] = 1 }
        }
    } catch {
        $countsOk = $false
        $out.CountsError = $_.Exception.Message
    }

    foreach ($h in $hosts) {
        $short = (([string]$h.SessionHost) -split '\.')[0].ToLower()
        $cnt = -1
        if ($countsOk) { if ($counts.ContainsKey($short)) { $cnt = $counts[$short] } else { $cnt = 0 } }
        $out.Hosts += @{ Host = [string]$h.SessionHost; State = [string]$h.NewConnectionAllowed; Sessions = $cnt }
    }
    return $out
}


# ==============================================================================
# SECTION 6 - Form build
# ==============================================================================
try {

    # ------------------------------------------------------------------
    # SECTION 6a - Form shell
    # ------------------------------------------------------------------
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "RhinoDrain v1.0"
    $form.MinimumSize = New-Object System.Drawing.Size(900, 680)
    $form.Size        = New-Object System.Drawing.Size(1000, 740)
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

    # Action-in-flight tracking. Any broker/RDS call sets this to a human
    # description when it dispatches and clears it on completion. FormClosing
    # reads it to decide whether to prompt before closing. $script:asyncTimers
    # holds active polling timers so a close-anyway can stop them before a
    # Tick fires against disposed controls.
    $script:actionInFlight = $null
    $script:asyncTimers = @()

    # FormClosing: prompt if an action is in flight; on confirmed close stop
    # pending timers, write an ABANDONED audit line, write the session-end
    # marker, and dispose the script-scope font handles.
    $form.Add_FormClosing({
        if ($script:actionInFlight) {
            $msg  = "RhinoDrain is currently: $($script:actionInFlight).`n`n"
            $msg += "If you close now the action may not complete cleanly and the activity log will record it as abandoned.`n`n"
            $msg += "Close anyway?"
            $ans = [System.Windows.Forms.MessageBox]::Show($msg, "RhinoDrain - Action in Flight", 'YesNo', 'Warning')
            if ($ans -ne 'Yes') { $_.Cancel = $true; return }
            foreach ($tm in $script:asyncTimers) {
                try { $tm.Stop(); $tm.Dispose() } catch { }
            }
            $script:asyncTimers = @()
            try {
                $stamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                Add-Content -Path $activityLog -Value "$stamp ABANDONED: $($script:actionInFlight) (form closed before completion)" -Encoding UTF8
            } catch { }
        }
        try {
            $stamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            Add-Content -Path $activityLog -Value "=== RhinoDrain session ended $stamp ===" -Encoding UTF8
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
    $headerPanel.Size = New-Object System.Drawing.Size(1000, 90)
    $headerPanel.Dock = 'Top'
    $headerPanel.BackColor = $script:t.Surface
    # Paint a thin bottom border in the active palette. try/finally so a GDI
    # exception during draw never leaks the Pen handle on repeated repaints.
    $headerPanel.Add_Paint({
        $g = $_.Graphics
        $pen = New-Object System.Drawing.Pen($script:t.Border, 1)
        try { $g.DrawLine($pen, 0, $headerPanel.Height - 1, $headerPanel.Width, $headerPanel.Height - 1) }
        finally { $pen.Dispose() }
    })
    $form.Controls.Add($headerPanel)
    Register-Themed -Control $headerPanel -Role "header"

    # Mascot. Falls back to a coloured square if Rhino.png is not beside the script.
    $mascot = New-Object System.Windows.Forms.PictureBox
    $mascot.Size = New-Object System.Drawing.Size(70, 70)
    $mascot.Location = New-Object System.Drawing.Point(15, 10)
    $mascot.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
    $mascot.Cursor = [System.Windows.Forms.Cursors]::Hand
    if (Test-Path $mascotPath) {
        try { $mascot.Image = [System.Drawing.Image]::FromFile($mascotPath) } catch { $mascot.BackColor = $script:t.Accent }
    } else { $mascot.BackColor = $script:t.Accent }
    $headerPanel.Controls.Add($mascot)

    # Title wordmark
    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = "RhinoDrain"
    $titleLabel.Font = $fontTitle
    $titleLabel.AutoSize = $true
    $titleLabel.Location = New-Object System.Drawing.Point(95, 15)
    $titleLabel.ForeColor = $script:t.Text
    $titleLabel.BackColor = $script:t.Surface
    $headerPanel.Controls.Add($titleLabel)
    Register-Themed -Control $titleLabel -Role "label-surf"

    # Subtitle / tagline. Doubles as the mascot easter-egg display.
    $subtitleLabel = New-Object System.Windows.Forms.Label
    $subtitleLabel.Text = "Pool's closed. Drain the hosts, send the users elsewhere."
    $subtitleLabel.Font = $fontSubtitle
    $subtitleLabel.AutoSize = $true
    $subtitleLabel.Location = New-Object System.Drawing.Point(95, 50)
    $subtitleLabel.ForeColor = $script:t.Muted
    $subtitleLabel.BackColor = $script:t.Surface
    $headerPanel.Controls.Add($subtitleLabel)
    Register-Themed -Control $subtitleLabel -Role "muted-surf"

    # Theme + Help buttons anchored top-right. The X values are the initial
    # positions at the default width; the Top,Right anchor keeps them tucked
    # in the corner on resize.
    $anchorTR = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
    $themeButton = New-RhinoButton -Text "Light" -X 835 -Y 20 -W 70 -H 28 -Role "btn-neutral" -Parent $headerPanel -Anchor $anchorTR
    $themeButton.Add_Click({
        if ($script:currentTheme -eq "dark") { $script:currentTheme = "light"; $script:t = $script:themes.light; $themeButton.Text = "Dark" }
        else { $script:currentTheme = "dark"; $script:t = $script:themes.dark; $themeButton.Text = "Light" }
        Apply-Theme
        # Repaint the grid so the per-cell green/red New Connections colours
        # follow the new palette too (Apply-Theme only does default styling).
        if ($script:currentHosts.Count -gt 0) { Apply-HostFilter }
    })

    $helpButton = New-RhinoButton -Text "?" -X 910 -Y 20 -W 32 -H 28 -Role "btn-help" -Parent $headerPanel -Anchor $anchorTR

    # ------------------------------------------------------------------
    # SECTION 6c - Mascot easter egg
    # ------------------------------------------------------------------
    # Click the rhino for escalating "pool's closed" flavour. Pure cosmetics.
    $script:mascotClicks = 0
    $mascotMessages = @(
        "Pool's closed. Yeah, I made the sign. You're welcome.",
        "Block new connections, watch the box drain. Patience, operator.",
        "Blocking a host does not kick anyone off. That's RhinoShadow's job.",
        "Reopen the pool when you're done. The big green button. Yes, that one.",
        "Two brokers walk into a deployment. Only one of them has it configured.",
        "I checked both brokers so you didn't have to. This is the whole point of me.",
        "Green means go, red means closed. I kept it simple on purpose.",
        "Drain one host, the users wander to the next. Like cattle, but with Outlook.",
        "Blocked everything by accident? Hit Allow All. No judgement here.",
        "Right, back to work. Someone's RDP session isn't going to herd itself."
    )
    $mascot.Add_Click({
        $idx = $script:mascotClicks % $mascotMessages.Count
        $subtitleLabel.Text = $mascotMessages[$idx]
        $script:mascotClicks++
    })

    # ------------------------------------------------------------------
    # SECTION 6d - Connection panel (broker status + collection dropdown)
    # ------------------------------------------------------------------
    $connBox = New-Object System.Windows.Forms.GroupBox
    $connBox.Text = " Connection "
    $connBox.Font = $fontHeader
    $connBox.Location = New-Object System.Drawing.Point(15, 100)
    $connBox.Size = New-Object System.Drawing.Size($contentW, 110)
    $connBox.Anchor = 'Top,Left,Right'
    $connBox.BackColor = $script:t.Bg
    $connBox.ForeColor = $script:t.Text
    $form.Controls.Add($connBox)
    Register-Themed -Control $connBox -Role "groupbox"

    # Row 1 - broker status
    $brokerCaption = New-Object System.Windows.Forms.Label
    $brokerCaption.Text = "Broker:"
    $brokerCaption.Location = New-Object System.Drawing.Point(15, 30)
    $brokerCaption.AutoSize = $true
    $brokerCaption.BackColor = $script:t.Bg
    $brokerCaption.ForeColor = $script:t.Text
    $connBox.Controls.Add($brokerCaption)
    Register-Themed -Control $brokerCaption -Role "label-body"

    # Status label is coloured directly (green live / red none / amber busy),
    # so it is NOT registered for theme recolouring - its colour carries state.
    $brokerStatus = New-Object System.Windows.Forms.Label
    $brokerStatus.Text = "Detecting live broker..."
    $brokerStatus.Location = New-Object System.Drawing.Point(75, 30)
    $brokerStatus.AutoSize = $true
    $brokerStatus.Font = $fontSemibold
    $brokerStatus.BackColor = $script:t.Bg
    $brokerStatus.ForeColor = $script:t.Warning
    $connBox.Controls.Add($brokerStatus)

    $redetectButton = New-RhinoButton -Text "Re-detect" -X 0 -Y 27 -W 110 -H 28 -Role "btn-neutral" -Parent $connBox -Anchor $anchorTR
    # Initial X set after the box has its real width; reposition for the right edge.
    $redetectButton.Location = New-Object System.Drawing.Point(($connBox.ClientSize.Width - 125), 27)

    # Row 2 - collection picker + refresh
    $collCaption = New-Object System.Windows.Forms.Label
    $collCaption.Text = "Collection:"
    $collCaption.Location = New-Object System.Drawing.Point(15, 70)
    $collCaption.AutoSize = $true
    $collCaption.BackColor = $script:t.Bg
    $collCaption.ForeColor = $script:t.Text
    $connBox.Controls.Add($collCaption)
    Register-Themed -Control $collCaption -Role "label-body"

    $collectionDropdown = New-Object System.Windows.Forms.ComboBox
    $collectionDropdown.Location = New-Object System.Drawing.Point(95, 67)
    $collectionDropdown.Size = New-Object System.Drawing.Size(420, 26)
    $collectionDropdown.Anchor = 'Top,Left,Right'
    $collectionDropdown.BackColor = $script:t.Surface
    $collectionDropdown.ForeColor = $script:t.Text
    $collectionDropdown.FlatStyle = 'Flat'
    $collectionDropdown.Enabled = $false
    $connBox.Controls.Add($collectionDropdown)
    Register-Themed -Control $collectionDropdown -Role "input"

    $refreshButton = New-RhinoButton -Text "Refresh Hosts" -X 0 -Y 66 -W 130 -H 28 -Role "btn-success" -Parent $connBox -Anchor $anchorTR
    $refreshButton.Location = New-Object System.Drawing.Point(($connBox.ClientSize.Width - 145), 66)
    $refreshButton.Enabled = $false

    # ------------------------------------------------------------------
    # SECTION 6e - Hosts grid + filter + select-all controls
    # ------------------------------------------------------------------
    $hostsBox = New-Object System.Windows.Forms.GroupBox
    $hostsBox.Text = " Session Hosts "
    $hostsBox.Font = $fontHeader
    $hostsBox.Location = New-Object System.Drawing.Point(15, 220)
    $hostsBox.Size = New-Object System.Drawing.Size($contentW, 318)
    $hostsBox.Anchor = 'Top,Bottom,Left,Right'
    $hostsBox.BackColor = $script:t.Bg
    $hostsBox.ForeColor = $script:t.Text
    $form.Controls.Add($hostsBox)
    Register-Themed -Control $hostsBox -Role "groupbox"

    $filterLabel = New-Object System.Windows.Forms.Label
    $filterLabel.Text = "Filter:"
    $filterLabel.Location = New-Object System.Drawing.Point(15, 30)
    $filterLabel.AutoSize = $true
    $filterLabel.BackColor = $script:t.Bg
    $filterLabel.ForeColor = $script:t.Text
    $hostsBox.Controls.Add($filterLabel)
    Register-Themed -Control $filterLabel -Role "label-body"

    $filterTextBox = New-Object System.Windows.Forms.TextBox
    $filterTextBox.Location = New-Object System.Drawing.Point(60, 28)
    $filterTextBox.Size = New-Object System.Drawing.Size(240, 26)
    $filterTextBox.BackColor = $script:t.Surface
    $filterTextBox.ForeColor = $script:t.Text
    $filterTextBox.BorderStyle = 'FixedSingle'
    $hostsBox.Controls.Add($filterTextBox)
    Register-Themed -Control $filterTextBox -Role "input"

    $clearFilterButton = New-RhinoButton -Text "Clear" -X 305 -Y 27 -W 55 -H 27 -Role "btn-neutral" -Parent $hostsBox -OnClick { $filterTextBox.Text = "" }
    $tickAllButton   = New-RhinoButton -Text "Tick All"   -X 372 -Y 27 -W 80 -H 27 -Role "btn-neutral" -Parent $hostsBox
    $untickAllButton = New-RhinoButton -Text "Untick All" -X 458 -Y 27 -W 90 -H 27 -Role "btn-neutral" -Parent $hostsBox

    # Host count label, top-right of the box.
    $countLabel = New-Object System.Windows.Forms.Label
    $countLabel.Text = "0 hosts"
    $countLabel.Anchor = 'Top,Right'
    $countLabel.Location = New-Object System.Drawing.Point(($hostsBox.ClientSize.Width - 110), 32)
    $countLabel.AutoSize = $true
    $countLabel.Font = $fontSubtitle
    $countLabel.BackColor = $script:t.Bg
    $countLabel.ForeColor = $script:t.Muted
    $hostsBox.Controls.Add($countLabel)
    Register-Themed -Control $countLabel -Role "muted"

    # The grid. Checkbox column drives which hosts the actions apply to.
    $hostsGrid = New-Object System.Windows.Forms.DataGridView
    $hostsGrid.Location = New-Object System.Drawing.Point(15, 60)
    $hostsGrid.Size = New-Object System.Drawing.Size(($contentW - 30), 240)
    $hostsGrid.Anchor = 'Top,Bottom,Left,Right'
    $hostsGrid.AutoGenerateColumns = $false
    $hostsGrid.MultiSelect = $false
    $hostsGrid.SelectionMode = 'FullRowSelect'
    $hostsGrid.RowHeadersVisible = $false
    $hostsGrid.AllowUserToAddRows = $false
    $hostsGrid.AllowUserToDeleteRows = $false
    $hostsGrid.AllowUserToResizeRows = $false
    $hostsGrid.ReadOnly = $false   # the Sel checkbox needs to be editable
    $hostsGrid.BorderStyle = 'FixedSingle'
    $hostsGrid.CellBorderStyle = 'SingleHorizontal'
    $hostsGrid.BackgroundColor = $script:t.Surface
    $hostsGrid.GridColor = $script:t.Border
    $hostsGrid.EnableHeadersVisualStyles = $false
    $hostsGrid.ColumnHeadersHeightSizeMode = 'AutoSize'
    $hostsGrid.AutoSizeColumnsMode = 'Fill'
    Register-Themed -Control $hostsGrid -Role "grid"
    $hostsGrid.DefaultCellStyle.BackColor = $script:t.Surface
    $hostsGrid.DefaultCellStyle.ForeColor = $script:t.Text
    $hostsGrid.DefaultCellStyle.SelectionBackColor = $script:t.Accent
    $hostsGrid.DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::White
    $hostsGrid.AlternatingRowsDefaultCellStyle.BackColor = $script:t.SurfaceAlt
    $hostsGrid.ColumnHeadersDefaultCellStyle.BackColor = $script:t.SurfaceAlt
    $hostsGrid.ColumnHeadersDefaultCellStyle.ForeColor = $script:t.Text
    $hostsBox.Controls.Add($hostsGrid)

    # Columns. Sel is a fixed-width checkbox; the rest fill the remaining space.
    $colSel = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $colSel.Name = "Sel"
    $colSel.HeaderText = ""
    $colSel.AutoSizeMode = 'None'
    $colSel.Width = 42
    $colSel.SortMode = 'NotSortable'
    $hostsGrid.Columns.Add($colSel) | Out-Null

    $colHost = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colHost.Name = "Host"; $colHost.HeaderText = "Session Host"; $colHost.FillWeight = 58; $colHost.SortMode = 'Automatic'; $colHost.ReadOnly = $true
    $hostsGrid.Columns.Add($colHost) | Out-Null

    $colState = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colState.Name = "State"; $colState.HeaderText = "New Connections"; $colState.FillWeight = 24; $colState.SortMode = 'Automatic'; $colState.ReadOnly = $true
    $colState.DefaultCellStyle.Alignment = 'MiddleCenter'
    $hostsGrid.Columns.Add($colState) | Out-Null

    $colSess = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colSess.Name = "Sessions"; $colSess.HeaderText = "Sessions"; $colSess.FillWeight = 18; $colSess.SortMode = 'Automatic'; $colSess.ReadOnly = $true
    $colSess.DefaultCellStyle.Alignment = 'MiddleCenter'
    $hostsGrid.Columns.Add($colSess) | Out-Null

    # Commit checkbox edits immediately so CellValueChanged fires on the click
    # rather than waiting for the cell to lose focus.
    $hostsGrid.Add_CurrentCellDirtyStateChanged({
        if ($hostsGrid.IsCurrentCellDirty) {
            $hostsGrid.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit)
        }
    })
    # Keep $script:checkedHosts in sync so tick state survives filter/refresh.
    $hostsGrid.Add_CellValueChanged({
        param($sender, $e)
        if ($e.ColumnIndex -ne $hostsGrid.Columns["Sel"].Index) { return }
        if ($e.RowIndex -lt 0) { return }
        $row = $hostsGrid.Rows[$e.RowIndex]
        $hn = [string]$row.Cells["Host"].Value
        if (-not $hn) { return }
        if ([bool]$row.Cells["Sel"].Value) { $script:checkedHosts[$hn] = $true }
        else { $script:checkedHosts.Remove($hn) }
    })

    # ------------------------------------------------------------------
    # SECTION 6f - Action buttons row
    # ------------------------------------------------------------------
    $actionPanel = New-Object System.Windows.Forms.Panel
    $actionPanel.Location = New-Object System.Drawing.Point(15, 548)
    $actionPanel.Size = New-Object System.Drawing.Size($contentW, 40)
    $actionPanel.Anchor = 'Bottom,Left,Right'
    $actionPanel.BackColor = $script:t.Bg
    $form.Controls.Add($actionPanel)
    Register-Themed -Control $actionPanel -Role "form"

    # Built here; click handlers wired after the worker functions exist.
    $blockSelButton    = New-RhinoButton -Text "Block Selected"           -X 0   -Y 4 -W 130 -H 32 -Role "btn-danger"  -Parent $actionPanel
    $allowSelButton    = New-RhinoButton -Text "Allow Selected"           -X 138 -Y 4 -W 130 -H 32 -Role "btn-success" -Parent $actionPanel
    $blockOthersButton = New-RhinoButton -Text "Block All Except Selected" -X 276 -Y 4 -W 200 -H 32 -Role "btn-danger"  -Parent $actionPanel
    # Open Pool sits at the right edge so it reads as the final "reset" step.
    $openPoolButton    = New-RhinoButton -Text "Allow All (Open Pool)"     -X 0   -Y 4 -W 190 -H 32 -Role "btn-success" -Parent $actionPanel -Anchor ([System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right)
    $openPoolButton.Location = New-Object System.Drawing.Point(($actionPanel.ClientSize.Width - 190), 4)

    # All action buttons start disabled until a collection's hosts are loaded.
    foreach ($btn in @($blockSelButton, $allowSelButton, $blockOthersButton, $openPoolButton)) { $btn.Enabled = $false }

    # ------------------------------------------------------------------
    # SECTION 6g - Status log
    # ------------------------------------------------------------------
    $logLabel = New-Object System.Windows.Forms.Label
    $logLabel.Text = "Activity:"
    $logLabel.Location = New-Object System.Drawing.Point(15, 596)
    $logLabel.AutoSize = $true
    $logLabel.Anchor = 'Bottom,Left'
    $logLabel.BackColor = $script:t.Bg
    $logLabel.ForeColor = $script:t.Muted
    $form.Controls.Add($logLabel)
    Register-Themed -Control $logLabel -Role "muted"

    $logBox = New-Object System.Windows.Forms.TextBox
    $logBox.Location = New-Object System.Drawing.Point(15, 616)
    $logBox.Size = New-Object System.Drawing.Size($contentW, 70)
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
    # SECTION 6h - Worker functions (defined after $logBox exists since they log)
    # ------------------------------------------------------------------

    # Timestamped line to the on-screen log AND the on-disk activity log.
    # level -> 5-char prefix: info "     ", ok "[OK] ", warn "[!]  ", error "[ERR]".
    function Write-RhinoLog {
        param([string]$message, [string]$level = "info")
        $stamp = (Get-Date).ToString("HH:mm:ss")
        $prefix = switch ($level) { "error" { "[ERR]" } "warn" { "[!]  " } "ok" { "[OK] " } default { "     " } }
        $line = "$stamp $prefix $message"
        $logBox.AppendText("$line`r`n")
        try { Add-Content -Path $activityLog -Value $line -Encoding UTF8 } catch { }
    }

    # Colour a State cell from the active palette. Yes -> green, No -> red,
    # NotUntilReboot -> amber (shown honestly even though RhinoDrain never sets
    # it, because someone could have set it manually). SelectionBackColor is
    # matched so selecting the row does not hide the state colour.
    function Set-StateCellColour {
        param($cell, [string]$state)
        $t = $script:t
        if ($state -eq 'Yes') {
            $cell.Style.BackColor = $t.Success; $cell.Style.ForeColor = [System.Drawing.Color]::White
            $cell.Style.SelectionBackColor = $t.Success; $cell.Style.SelectionForeColor = [System.Drawing.Color]::White
        } elseif ($state -eq 'No') {
            $cell.Style.BackColor = $t.Danger; $cell.Style.ForeColor = [System.Drawing.Color]::White
            $cell.Style.SelectionBackColor = $t.Danger; $cell.Style.SelectionForeColor = [System.Drawing.Color]::White
        } elseif ($state -eq 'NotUntilReboot') {
            $cell.Style.BackColor = $t.Warning; $cell.Style.ForeColor = [System.Drawing.Color]::Black
            $cell.Style.SelectionBackColor = $t.Warning; $cell.Style.SelectionForeColor = [System.Drawing.Color]::Black
        } else {
            $cell.Style.BackColor = $t.Surface; $cell.Style.ForeColor = $t.Muted
        }
    }

    # Rebuild the grid from $script:currentHosts applying the live filter.
    # Re-applies tick state from $script:checkedHosts and recolours State cells
    # (so it also serves as the "repaint on theme toggle" path). Filter is a
    # case-insensitive substring match on the host name using .Contains() so
    # any * or ? typed in the filter is treated literally, not as a wildcard.
    function Apply-HostFilter {
        $filter = $filterTextBox.Text.Trim().ToLower()
        $hostsGrid.Rows.Clear()
        $shown = 0
        foreach ($h in $script:currentHosts) {
            if ($filter -ne "" -and -not ($h.Host.ToLower().Contains($filter))) { continue }
            $sessText = if ($h.Sessions -lt 0) { "?" } else { [string]$h.Sessions }
            $rowIdx = $hostsGrid.Rows.Add(@($false, $h.Host, $h.State, $sessText))
            $row = $hostsGrid.Rows[$rowIdx]
            if ($script:checkedHosts.ContainsKey($h.Host)) { $row.Cells["Sel"].Value = $true }
            Set-StateCellColour -cell $row.Cells["State"] -state $h.State
            $shown++
        }
        $total = $script:currentHosts.Count
        if ($filter -ne "") { $countLabel.Text = "$shown of $total hosts" } else { $countLabel.Text = "$total hosts" }
    }
    $filterTextBox.Add_TextChanged({ Apply-HostFilter })

    $tickAllButton.Add_Click({
        # Tick only the hosts currently visible under the filter, so "Tick All"
        # respects what the operator can actually see.
        foreach ($row in $hostsGrid.Rows) { $row.Cells["Sel"].Value = $true; $script:checkedHosts[[string]$row.Cells["Host"].Value] = $true }
    })
    $untickAllButton.Add_Click({
        foreach ($row in $hostsGrid.Rows) { $row.Cells["Sel"].Value = $false }
        $script:checkedHosts = @{}
    })

    # Return the FQDNs of ticked hosts (from the authoritative set, so hosts
    # ticked then hidden by a filter still count).
    function Get-CheckedHosts { return @($script:checkedHosts.Keys) }

    # Enable/disable the action buttons as a group.
    function Set-ActionsEnabled {
        param([bool]$enabled)
        foreach ($btn in @($blockSelButton, $allowSelButton, $blockOthersButton, $openPoolButton, $refreshButton, $redetectButton)) { $btn.Enabled = $enabled }
        $collectionDropdown.Enabled = $enabled
    }

    # --- Broker detection (async) -------------------------------------------
    # Runs the detect worker in a runspace polled by a 250ms timer with a 30s
    # ceiling so a powered-off broker (which would hang on RPC rather than
    # erroring fast) can never freeze the launch. On success it fills the
    # collection dropdown; on failure it logs the per-broker error so the
    # operator sees exactly why each broker was rejected.
    function Start-Detect {
        if (-not (Get-Command Get-RDSessionCollection -ErrorAction SilentlyContinue)) {
            $brokerStatus.Text = "RemoteDesktop module not found"
            $brokerStatus.ForeColor = $script:t.Danger
            Write-RhinoLog "RemoteDesktop module not available. Run RhinoDrain on a box with the RDS management tools (RSAT) installed." "error"
            return
        }
        $script:actionInFlight = "detecting the live connection broker"
        Set-ActionsEnabled $false
        $redetectButton.Enabled = $false
        $brokerStatus.Text = "Detecting live broker..."
        $brokerStatus.ForeColor = $script:t.Warning
        Write-RhinoLog "Probing $($script:brokers.Count) broker(s) for the live RDS deployment..."

        $ps = [powershell]::Create()
        $null = $ps.AddScript($script:detectWorker).AddArgument($script:brokers)
        $handle = $ps.BeginInvoke()

        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 250
        $timer.Tag = @{ Pipe = $ps; Handle = $handle; Ticks = 0; MaxTicks = 120 }  # 120 * 250ms = 30s
        $script:asyncTimers += $timer
        $timer.Add_Tick({
            $state = $this.Tag
            $state.Ticks++
            if (-not $state.Handle.IsCompleted) {
                if ($state.Ticks -ge $state.MaxTicks) {
                    $this.Stop()
                    try { $state.Pipe.Stop() } catch { }
                    try { $state.Pipe.Dispose() } catch { }
                    $script:asyncTimers = @($script:asyncTimers | Where-Object { $_ -ne $this })
                    $this.Dispose()
                    $script:actionInFlight = $null
                    $brokerStatus.Text = "Broker detection timed out"
                    $brokerStatus.ForeColor = $script:t.Danger
                    Write-RhinoLog "Broker detection timed out after 30s. A broker may be unreachable. Use Re-detect to retry." "error"
                    $redetectButton.Enabled = $true
                }
                return
            }
            $this.Stop()
            try {
                $r = @($state.Pipe.EndInvoke($state.Handle))[0]
                foreach ($e in $r.Errors) { Write-RhinoLog "Broker '$($e.Broker)' skipped: $($e.Message)" "warn" }
                if ($r.Broker) {
                    $script:activeBroker = $r.Broker
                    $brokerStatus.Text = "$($r.Broker)  (live)"
                    $brokerStatus.ForeColor = $script:t.Success
                    Write-RhinoLog "Live broker: $($r.Broker). Loaded $($r.Collections.Count) collection(s)." "ok"
                    $collectionDropdown.Items.Clear()
                    foreach ($c in $r.Collections) { $collectionDropdown.Items.Add($c) | Out-Null }
                    Register-FilterableDropdown -Dropdown $collectionDropdown -MasterList @($r.Collections)
                    $collectionDropdown.Enabled = $true
                    $refreshButton.Enabled = $true
                    Write-RhinoLog "Pick a collection to list its session hosts." "ok"
                } else {
                    $script:activeBroker = $null
                    $brokerStatus.Text = "No live broker found"
                    $brokerStatus.ForeColor = $script:t.Danger
                    Write-RhinoLog "No configured broker returned a deployment. Check the CONFIGURATION block and connectivity." "error"
                }
            } catch {
                $brokerStatus.Text = "Broker detection failed"
                $brokerStatus.ForeColor = $script:t.Danger
                Write-RhinoLog "Broker detection failed: $_" "error"
            } finally {
                try { $state.Pipe.Dispose() } catch { }
                $script:asyncTimers = @($script:asyncTimers | Where-Object { $_ -ne $this })
                $this.Dispose()
                $script:actionInFlight = $null
                $redetectButton.Enabled = $true
            }
        })
        $timer.Start()
    }
    $redetectButton.Add_Click({ Start-Detect })

    # --- Unified query/set action (async) -----------------------------------
    # The single async path for load, refresh and every state change. SetList
    # is empty for a pure load/refresh, or @{Host;Desired} entries for changes.
    # -Summarise makes the completion emit the unambiguous "pool open / still
    # blocked" verdict used by the Open Pool button.
    function Start-RdsAction {
        param([string]$Description, [object[]]$SetList = @(), [switch]$Summarise)
        if (-not $script:activeBroker) { Write-RhinoLog "No live broker. Run Re-detect first." "warn"; return }
        $col = $collectionDropdown.Text.Trim()
        if ($col -eq "") { Write-RhinoLog "Pick a collection first." "warn"; return }

        $script:actionInFlight = $Description
        Set-ActionsEnabled $false
        Write-RhinoLog "$Description ..."

        $ps = [powershell]::Create()
        $null = $ps.AddScript($script:rdsWorker).AddArgument($script:activeBroker).AddArgument($col).AddArgument([object[]]$SetList)
        $handle = $ps.BeginInvoke()

        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 250
        $timer.Tag = @{ Pipe = $ps; Handle = $handle; Ticks = 0; MaxTicks = 240; Collection = $col; SetList = $SetList; Summarise = [bool]$Summarise }  # 240 * 250ms = 60s
        $script:asyncTimers += $timer
        $timer.Add_Tick({
            $state = $this.Tag
            $state.Ticks++
            if (-not $state.Handle.IsCompleted) {
                if ($state.Ticks -ge $state.MaxTicks) {
                    $this.Stop()
                    try { $state.Pipe.Stop() } catch { }
                    try { $state.Pipe.Dispose() } catch { }
                    $script:asyncTimers = @($script:asyncTimers | Where-Object { $_ -ne $this })
                    $this.Dispose()
                    $script:actionInFlight = $null
                    Set-ActionsEnabled $true
                    Write-RhinoLog "Action timed out after 60s against '$($state.Collection)'. The broker may be slow or unreachable." "error"
                }
                return
            }
            $this.Stop()
            try {
                # EndInvoke returns a one-element collection wrapping the
                # worker's hashtable; unwrap to the hashtable itself so method
                # and key access behave as expected.
                $r = @($state.Pipe.EndInvoke($state.Handle))[0]
                if ($r.Error) {
                    Write-RhinoLog "Failed to read hosts for '$($state.Collection)': $($r.Error)" "error"
                    return
                }

                # Build a desired-state map for verification.
                $stateMap = @{}
                foreach ($h in $r.Hosts) { $stateMap[$h.Host] = $h.State }

                # Per-host set results, verified against the freshly read state.
                foreach ($sr in $state.SetList) {
                    $res = $r.SetResults | Where-Object { $_.Host -eq $sr.Host } | Select-Object -First 1
                    $actual = if ($stateMap.ContainsKey($sr.Host)) { $stateMap[$sr.Host] } else { "unknown" }
                    if ($res -and -not $res.Ok) {
                        Write-RhinoLog "$($sr.Host): set failed - $($res.Error)" "error"
                    } elseif ($actual -eq $sr.Desired) {
                        Write-RhinoLog "$($sr.Host): New Connections now $actual." "ok"
                    } else {
                        Write-RhinoLog "$($sr.Host): set reported success but state is '$actual', expected '$($sr.Desired)'." "error"
                    }
                }

                if ($state.SetList.Count -eq 0) {
                    Write-RhinoLog "Loaded $($r.Hosts.Count) host(s) for '$($state.Collection)'." "ok"
                }
                if ($r.CountsError) { Write-RhinoLog "Session counts unavailable: $($r.CountsError)" "warn" }

                # Push the new data into the grid.
                $script:currentHosts = @($r.Hosts | ForEach-Object { [PSCustomObject]@{ Host = $_.Host; State = $_.State; Sessions = $_.Sessions } } | Sort-Object Host)
                $script:loadedCollection = $state.Collection
                Apply-HostFilter

                # Open Pool verdict.
                if ($state.Summarise) {
                    $bad = @($script:currentHosts | Where-Object { $_.State -ne 'Yes' })
                    if ($bad.Count -eq 0) {
                        Write-RhinoLog "POOL OPEN: all $($script:currentHosts.Count) host(s) in '$($state.Collection)' are allowing new connections." "ok"
                    } else {
                        $names = ($bad | ForEach-Object { (($_.Host) -split '\.')[0] }) -join ", "
                        Write-RhinoLog "POOL NOT FULLY OPEN: $($bad.Count) host(s) still blocked - $names" "error"
                    }
                }
            } catch {
                Write-RhinoLog "Action post-processing failed: $_" "error"
            } finally {
                try { $state.Pipe.Dispose() } catch { }
                $script:asyncTimers = @($script:asyncTimers | Where-Object { $_ -ne $this })
                $this.Dispose()
                $script:actionInFlight = $null
                Set-ActionsEnabled $true
            }
        })
        $timer.Start()
    }

    # Load the picked collection's hosts. Shared by the dropdown commit and the
    # Refresh button. $force re-loads even if the same collection is already shown.
    function Load-HostsForSelection {
        param([switch]$Force)
        $col = $collectionDropdown.Text.Trim()
        if ($col -eq "") { return }
        if (-not $Force -and $col -eq $script:loadedCollection) { return }
        # New collection selected: drop any stale tick state from the old one.
        if ($col -ne $script:loadedCollection) { $script:checkedHosts = @{} }
        Start-RdsAction -Description "Loading hosts for '$col'"
    }

    # Wire collection commit to BOTH SelectedIndexChanged (AutoComplete commit)
    # and Leave (typed-and-tabbed), via one shared scriptblock so the two paths
    # cannot drift. Matches the RhinoShadow dropdown convention.
    $collectionCommit = { Load-HostsForSelection }
    $collectionDropdown.Add_SelectedIndexChanged($collectionCommit)
    $collectionDropdown.Add_Leave($collectionCommit)
    $refreshButton.Add_Click({ Load-HostsForSelection -Force })

    # --- Action button handlers ---------------------------------------------
    # Each builds a SetList, confirms with the specific targets spelled out,
    # then dispatches through Start-RdsAction. Blocking is destructive (it
    # changes deployment state), so every one gets a modal Yes/No first.

    function Format-HostList { param([string[]]$hostnames) return (($hostnames | ForEach-Object { ($_ -split '\.')[0] } | Sort-Object) -join "`n  ") }

    $blockSelButton.Add_Click({
        $sel = Get-CheckedHosts
        if ($sel.Count -eq 0) { Write-RhinoLog "Tick at least one host to block." "warn"; return }
        $msg = "Block NEW connections on these $($sel.Count) host(s)?`n`n  $(Format-HostList $sel)`n`nExisting sessions stay connected. Only new logons are blocked."
        if ([System.Windows.Forms.MessageBox]::Show($msg, "RhinoDrain - Block Selected", 'YesNo', 'Warning') -ne 'Yes') { return }
        $setList = @($sel | ForEach-Object { @{ Host = $_; Desired = 'No' } })
        Start-RdsAction -Description "Blocking $($sel.Count) host(s)" -SetList $setList
    })

    $allowSelButton.Add_Click({
        $sel = Get-CheckedHosts
        if ($sel.Count -eq 0) { Write-RhinoLog "Tick at least one host to allow." "warn"; return }
        $msg = "Allow NEW connections on these $($sel.Count) host(s)?`n`n  $(Format-HostList $sel)"
        if ([System.Windows.Forms.MessageBox]::Show($msg, "RhinoDrain - Allow Selected", 'YesNo', 'Question') -ne 'Yes') { return }
        $setList = @($sel | ForEach-Object { @{ Host = $_; Desired = 'Yes' } })
        Start-RdsAction -Description "Allowing $($sel.Count) host(s)" -SetList $setList
    })

    $blockOthersButton.Add_Click({
        $sel = Get-CheckedHosts
        if ($sel.Count -eq 0) { Write-RhinoLog "Tick the host(s) to KEEP OPEN, then use Block All Except Selected." "warn"; return }
        $keep = @{}; foreach ($h in $sel) { $keep[$h] = $true }
        $others = @($script:currentHosts | Where-Object { -not $keep.ContainsKey($_.Host) } | ForEach-Object { $_.Host })
        if ($others.Count -eq 0) { Write-RhinoLog "Nothing to block - every host is in your keep-open selection." "warn"; return }
        $msg  = "Keep NEW connections OPEN on:`n  $(Format-HostList $sel)`n`n"
        $msg += "and BLOCK new connections on the other $($others.Count) host(s):`n  $(Format-HostList $others)`n`nProceed?"
        if ([System.Windows.Forms.MessageBox]::Show($msg, "RhinoDrain - Block All Except Selected", 'YesNo', 'Warning') -ne 'Yes') { return }
        # Set the kept ones to Yes as well, so this funnels traffic exactly onto
        # the selection regardless of their previous state.
        $setList  = @($sel    | ForEach-Object { @{ Host = $_; Desired = 'Yes' } })
        $setList += @($others | ForEach-Object { @{ Host = $_; Desired = 'No' } })
        Start-RdsAction -Description "Funnelling traffic onto $($sel.Count) host(s)" -SetList $setList
    })

    $openPoolButton.Add_Click({
        if ($script:currentHosts.Count -eq 0) { Write-RhinoLog "Load a collection first." "warn"; return }
        $all = @($script:currentHosts | ForEach-Object { $_.Host })
        $msg = "Set ALL $($all.Count) host(s) in '$($collectionDropdown.Text.Trim())' to allow NEW connections (Yes)?`n`nThis reopens the pool."
        if ([System.Windows.Forms.MessageBox]::Show($msg, "RhinoDrain - Allow All (Open Pool)", 'YesNo', 'Question') -ne 'Yes') { return }
        $setList = @($all | ForEach-Object { @{ Host = $_; Desired = 'Yes' } })
        Start-RdsAction -Description "Reopening all $($all.Count) host(s)" -SetList $setList -Summarise
    })

    # ------------------------------------------------------------------
    # SECTION 6i - Help dialog
    # ------------------------------------------------------------------
    # Rebuilt fresh on each open so a mid-session theme change cannot leave a
    # cached dialog with stale colours. RichTextBox, WordWrap off, natural
    # widths. The body is a LITERAL here-string (no variable expansion); the
    # config section is appended separately with the live broker values so the
    # operator sees what this instance is actually using.
    function Show-RhinoHelp {
        $h = New-Object System.Windows.Forms.Form
        $h.Text = "RhinoDrain - Help"
        $h.Size = New-Object System.Drawing.Size(720, 560)
        $h.StartPosition = "CenterParent"
        $h.FormBorderStyle = 'FixedDialog'
        $h.MaximizeBox = $false
        $h.MinimizeBox = $false
        $h.BackColor = $script:t.Bg
        $h.ForeColor = $script:t.Text
        $h.Font = $fontRegular
        $body = New-Object System.Windows.Forms.RichTextBox
        $body.Multiline = $true; $body.ReadOnly = $true; $body.ScrollBars = 'Vertical'
        $body.WordWrap = $false; $body.Dock = 'Fill'; $body.BorderStyle = 'None'
        $body.BackColor = $script:t.Surface; $body.ForeColor = $script:t.Text; $body.Font = $fontRegular
        $main = @'
RhinoDrain - Quick Guide
========================

WHAT IT DOES
------------
RhinoDrain turns RDS session hosts on and off inside a collection. "Drain" a
host by blocking new connections so users naturally land on the other hosts,
then reopen it when the box is healthy. Blocking does NOT sign anyone off; it
only stops NEW logons. Use RhinoShadow to force sign-outs.

THE MAIN WORKFLOW
-----------------
1. On launch RhinoDrain probes the configured brokers and uses whichever one
   actually has the deployment. The other broker is skipped automatically and
   the reason is shown in the activity log.
2. Pick a collection from the dropdown. Type to filter the list.
3. The grid lists every session host with its New Connections state (green Yes,
   red No) and a live count of user sessions on each host.
4. Tick the hosts you want to act on.
5. Block Selected   - block new logons on the ticked hosts (drain them).
   Allow Selected   - reopen new logons on the ticked hosts.
   Block All Except Selected - funnel everyone onto the ticked host(s) by
                      allowing those and blocking every other host in one go.
   Allow All (Open Pool) - reopen every host, then report whether the pool is
                      fully open or name the hosts still blocked.

VERIFICATION
------------
After every change RhinoDrain re-reads each host's state and compares it to
what you asked for. If a change "succeeded" but the state did not actually
move, the log says so in red rather than logging a false OK.

TIPS
----
- The Filter box does a live substring match on host names. Tick state is kept
  per host, so a host you ticked then filtered out is still acted on.
- Tick All / Untick All operate on the hosts currently visible in the grid.
- Refresh Hosts re-reads the current collection without changing anything.
- Re-detect re-probes the brokers if the live one changed or was unreachable.
- The Sessions count includes disconnected sessions, so a host can read "2"
  with nobody actively typing. A host at 0 is safe to take down.

ACTIONS REFERENCE
-----------------
  Block Selected             Sets ticked hosts to NewConnectionAllowed = No.
  Allow Selected             Sets ticked hosts to NewConnectionAllowed = Yes.
  Block All Except Selected  Ticked hosts -> Yes, all other hosts -> No.
  Allow All (Open Pool)      Every host -> Yes, with a plain-English verdict.
  Refresh Hosts              Re-reads the current collection's hosts.
  Re-detect                  Re-probes the configured brokers.

CLOSING THE WINDOW
------------------
If you close while an action is still running, RhinoDrain asks you to confirm
and records an ABANDONED line in the activity log so the audit trail captures
that the outcome is unknown.

LOG FILES
---------
  Activity log   %LOCALAPPDATA%\Temp\RhinoDrain.log
                 Every action with timestamps, including session start and end
                 markers and the Windows user and machine name.
  Crash log      %LOCALAPPDATA%\Temp\RhinoDrain_crash.log
                 Only written on a startup crash. Check this first if the
                 window fails to open.
'@
        $cfg = "`r`n`r`nCONFIG`r`n------`r`n"
        $cfg += "RhinoDrain probes these brokers in order (set in the CONFIGURATION`r`n"
        $cfg += "banner near the top of the script, look for the >>> markers). The`r`n"
        $cfg += "values below are what THIS instance is using and will differ per`r`n"
        $cfg += "deployment:`r`n`r`n"
        $i = 1
        foreach ($b in $script:brokers) { $cfg += "  $i. $b`r`n"; $i++ }
        if ($script:activeBroker) { $cfg += "`r`nCurrently live: $($script:activeBroker)`r`n" } else { $cfg += "`r`nCurrently live: none detected`r`n" }
        $cfg += "`r`nTo point RhinoDrain at a new deployment, edit those broker lines,`r`n"
        $cfg += "save and relaunch.`r`n"
        $body.Text = $main + $cfg
        $h.Controls.Add($body)
        $h.ShowDialog() | Out-Null
    }
    $helpButton.Add_Click({ Show-RhinoHelp })

    # ------------------------------------------------------------------
    # SECTION 6j - Initial broker detect + ShowDialog
    # ------------------------------------------------------------------
    # Session start marker so multiple runs stay separated in the file log.
    $sessionStamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    try { Add-Content -Path $activityLog -Value "" -Encoding UTF8 } catch { }
    try { Add-Content -Path $activityLog -Value "=== RhinoDrain session started $sessionStamp | $env:USERNAME on $env:COMPUTERNAME ===" -Encoding UTF8 } catch { }
    Write-RhinoLog "RhinoDrain ready. Detecting the live broker..."

    # Kick off detection once the form is shown so the UI paints immediately
    # and the user sees "Detecting..." rather than a frozen blank window.
    $form.Add_Shown({ Start-Detect })

    [void]$form.ShowDialog()

# ==============================================================================
# SECTION 7 - Outer catch (startup crash logger)
# ==============================================================================
} catch {
    $stamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $entry = @"
[$stamp] RhinoDrain startup crash
$($_.Exception.Message)
$($_.ScriptStackTrace)

"@
    try { Add-Content -Path $crashLog -Value $entry -Encoding UTF8 } catch { }
    try {
        [System.Windows.Forms.MessageBox]::Show(
            "RhinoDrain crashed on startup.`n`n$($_.Exception.Message)`n`nDetails: $crashLog",
            "RhinoDrain", 'OK', 'Error') | Out-Null
    } catch { }
}
