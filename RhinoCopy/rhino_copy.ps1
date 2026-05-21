<#
================================================================================
  RhinoCopy v1.69 - Robocopy front-end with dark/light themes
================================================================================

.SYNOPSIS
    A GUI-based file copying tool using Robocopy.

.DESCRIPTION
    Polished WinForms GUI wrapping Robocopy. Features:
      - Source / destination selection with browse dialogs.
      - Performance modes (/MT 18 / 9 / 4).
      - Copy flag presets (Data / Attributes / Timestamps / Security / Owner).
      - Standard recurse (/E) vs destructive Mirror (/MIR) mode.
      - Optional dry run (/L) and timestamped log file (/LOG+:).
      - Junction exclusion (/XJ) hardcoded - prevents AppData infinite recursion.
      - Working animation during copy (marquee bar + cycling status text +
        spinner glyph + elapsed-time clock).
      - Plain-English exit code decoder (decomposes the bit-flag value into
        which conditions actually fired, e.g. "3 = 1+2 = files copied + extras").
      - In-app Robocopy Flag Reference popup.
      - Light / dark theme toggle with full repaint of registered controls.
      - Copy-command-to-clipboard for users learning the tool.
      - Clickable Rhino mascot easter egg with escalating moods.
      - Dual-purpose Cancel/Clear button (Cancel during run, Clear when idle).

.AUTHOR
    Jared Neaves with a little help from Grock.

.CODE STRUCTURE
    1.  Assembly imports + WinForms bootstrap
    2.  Theme palettes (dark + light) + font definitions
    3.  Theme helpers (Register-Themed, Apply-ButtonTheme, Apply-Theme)
    4.  Script-level state + path resolution + crash log path
    5.  Form build (inside the outer try block):
        5a. Form shell + FormClosing handler + icon
        5b. Header panel - mascot, title, subtitle, progress label + bar,
            flag-reference and theme-toggle buttons stacked top-right
        5c. Mascot click-count easter egg message arrays + click handler
        5d. Path input rows (source / destination)
        5e. Option group boxes (Performance Mode, Copy Options, Mode)
        5f. Tooltips + Create-Log / Dry-Run checkboxes + status log textbox
        5g. Action buttons (Copy Files, Copy Command, Cancel/Clear)
        5h. Execute-Copy, Generate-Command, Format-RobocopyCommand,
            Show-FlagReference, Set-ButtonCancelMode, Set-ButtonClearMode
        5i. ShowDialog (modal blocking call)
    6.  Outer catch block - logs any startup crash to %TEMP%\RhinoCopy_crash.log

.NOTES
    - The script intentionally launches robocopy SYNCHRONOUSLY (via
      Start-Process + DoEvents wait loop, NOT BeginOutputReadLine).
      Do not change this without reading HANDOFF.md - the async pattern
      caused PowerShell host crashes due to a threadpool / runspace race.
    - Version 1.69 is intentional, do not change.
================================================================================
#>


# ==============================================================================
# SECTION 1 - Assembly imports
# ==============================================================================
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
# SetCompatibleTextRenderingDefault must run before any form is created. We
# wrap it in try/catch because if the script is re-run in the same PS session
# after a form was already instantiated, the API throws.
try { [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false) } catch { }


# ==============================================================================
# SECTION 2 - Theme palettes + fonts
# ==============================================================================
# Two complete palettes. The active one is swapped at runtime by the toggle
# button. All colours in the UI come from these - nothing hardcoded downstream.
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
    }
}
$script:currentTheme = "dark"   # Default theme on launch. Toggle to "light" via the header button.
$script:t = $script:themes[$script:currentTheme]   # Active-theme shortcut, re-pointed on toggle.

# Fonts used throughout the UI. Pre-created once at script scope so every
# control reuses the same Font objects (cheaper than allocating new ones
# every time, and consistent appearance):
#   - Regular:  body text, labels, radio/checkbox text
#   - Semibold: section headers, primary button text
#   - Title:    the big "RhinoCopy" wordmark in the header
#   - Header:   group box titles ("Performance Mode", "Copy Options", "Mode")
#   - Mono:     the status log textbox so robocopy's column-aligned output
#               lines up cleanly. Consolas is on every Windows install.
$fontRegular  = New-Object System.Drawing.Font("Segoe UI", 10)
$fontSemibold = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
$fontTitle    = New-Object System.Drawing.Font("Segoe UI Semibold", 18)
$fontHeader   = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
$fontMono     = New-Object System.Drawing.Font("Consolas", 9.5)


# ==============================================================================
# SECTION 3 - Theme helpers (Register-Themed, Apply-ButtonTheme, Apply-Theme)
# ==============================================================================
# Pattern explanation:
#   1. Every control that needs to participate in theme switching is "registered"
#      with a semantic role string when it's created. Role examples: "surface",
#      "input", "muted", "btn-success", "radio", etc.
#   2. The control's initial colours are also set explicitly at creation time
#      using $script:t.<Property>, so the form looks correct on first paint
#      without needing Apply-Theme to be called.
#   3. When the user clicks the Light/Dark toggle button, $script:currentTheme
#      is flipped, $script:t is re-pointed to the new palette, and Apply-Theme
#      is called. Apply-Theme walks every registered control and repaints it
#      based on its role using the new palette.
# This is conceptually identical to CSS classes: the role tag is like a class
# name, and the two theme palettes are like two stylesheets.
# Why this rather than recreate the form on toggle? Because that would lose
# all user-entered state (source/dest paths, radio selections, status log).
# Walking and repainting is much cheaper.

# The list of (Control, Role) pairs. Populated by Register-Themed as controls
# are built up.
$script:themedControls = @()

# Register-Themed
# ---------------
# Tag a control with a semantic role so Apply-Theme can paint it later.
# The += operator on an array assigns a new array back, which does NOT emit
# to the pipeline. Using $script:themedControls.Add() would emit the count.
function Register-Themed {
    param($Control, [string]$Role)
    $script:themedControls += @{ Control = $Control; Role = $Role }
}

# Apply-ButtonTheme
# -----------------
# Apply a button role to a single Button control. Called by Apply-Theme (when
# the theme is toggled) and also directly at button-creation time. Pulls all
# colours from $script:t at call time, so theme switches work correctly.
#
# We use FlatStyle = Flat throughout so we have full control over button
# appearance. The default "System" FlatStyle inherits OS chrome and ignores
# our BackColor/ForeColor settings, which defeats theming.
#
# Roles:
#   btn-success  - Solid green, white text, bold. Used for the primary
#                  "Copy Files" action button.
#   btn-accent   - Solid blue, white text, regular weight. Used for the
#                  secondary "Copy Command to Clipboard" button.
#   btn-danger   - Solid red, white text. Used for the Cancel mode of the
#                  dual-purpose Cancel/Clear button.
#   btn-help     - Subtle background, accent text, semibold. Used for the
#                  small round "?" help buttons next to radio options.
#   btn-neutral  - Plain surface background, default text. Used for Browse
#                  buttons, the header theme/flag-reference buttons, and
#                  the Clear mode of the dual-purpose button.
function Apply-ButtonTheme {
    param($Button, [string]$Role)
    $t = $script:t
    $Button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $Button.FlatAppearance.BorderSize = 1
    $Button.Cursor = [System.Windows.Forms.Cursors]::Hand
    $Button.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    switch ($Role) {
        "btn-success" { $Button.BackColor = $t.Success; $Button.ForeColor = [System.Drawing.Color]::White; $Button.FlatAppearance.BorderColor = $t.Success; $Button.FlatAppearance.MouseOverBackColor = $t.SuccessHov; $Button.FlatAppearance.MouseDownBackColor = $t.SuccessHov; $Button.Font = $fontSemibold }
        "btn-accent"  { $Button.BackColor = $t.Accent;  $Button.ForeColor = [System.Drawing.Color]::White; $Button.FlatAppearance.BorderColor = $t.Accent;  $Button.FlatAppearance.MouseOverBackColor = $t.AccentHov;  $Button.FlatAppearance.MouseDownBackColor = $t.AccentHov;  $Button.Font = $fontRegular }
        "btn-danger"  { $Button.BackColor = $t.Danger;  $Button.ForeColor = [System.Drawing.Color]::White; $Button.FlatAppearance.BorderColor = $t.Danger;  $Button.FlatAppearance.MouseOverBackColor = $t.DangerHov;  $Button.FlatAppearance.MouseDownBackColor = $t.DangerHov;  $Button.Font = $fontRegular }
        "btn-help"    { $Button.BackColor = $t.SurfaceAlt; $Button.ForeColor = $t.Accent; $Button.FlatAppearance.BorderColor = $t.Border; $Button.FlatAppearance.MouseOverBackColor = $t.Surface; $Button.FlatAppearance.MouseDownBackColor = $t.Border; $Button.Font = $fontSemibold }
        default       { $Button.BackColor = $t.Surface; $Button.ForeColor = $t.Text; $Button.FlatAppearance.BorderColor = $t.Border; $Button.FlatAppearance.MouseOverBackColor = $t.SurfaceAlt; $Button.FlatAppearance.MouseDownBackColor = $t.Border; $Button.Font = $fontRegular }
    }
}

# Apply-Theme
# -----------
# Walk every registered control and re-apply its role-based colours from the
# current $script:t palette. Called when the user clicks the Light/Dark
# toggle button.
#
# Each control assignment is wrapped in try/catch so that ONE malfunctioning
# control (e.g. one whose handle has been disposed) doesn't abort the whole
# repaint loop and leave the form in a half-themed state.
#
# Non-button roles set BackColor and ForeColor directly. Button roles delegate
# to Apply-ButtonTheme which handles their more complex multi-property setup
# (border, hover, mousedown colours, etc.).
function Apply-Theme {
    $t = $script:t
    if ($form) { $form.BackColor = $t.Bg; $form.ForeColor = $t.Text }
    foreach ($entry in $script:themedControls) {
        try {
            $c = $entry.Control
            $role = $entry.Role
            switch ($role) {
                "form"        { $c.BackColor = $t.Bg;      $c.ForeColor = $t.Text }
                "surface"     { $c.BackColor = $t.Surface; $c.ForeColor = $t.Text }
                "muted"       { $c.BackColor = $t.Surface; $c.ForeColor = $t.Muted }
                "header"      { $c.BackColor = $t.Surface; $c.ForeColor = $t.Text }
                "input"       { $c.BackColor = $t.Surface; $c.ForeColor = $t.Text }
                "log"         { $c.BackColor = $t.Surface; $c.ForeColor = $t.Text }
                "groupbox"    { $c.BackColor = $t.Surface; $c.ForeColor = $t.Text }
                "radio"       { $c.BackColor = $t.Surface; $c.ForeColor = $t.Text }
                "checkbox"    { $c.BackColor = $t.Bg;      $c.ForeColor = $t.Text }
                "label-body"  { $c.BackColor = $t.Bg;      $c.ForeColor = $t.Text }
                "btn-success" { Apply-ButtonTheme -Button $c -Role "btn-success" }
                "btn-accent"  { Apply-ButtonTheme -Button $c -Role "btn-accent" }
                "btn-danger"  { Apply-ButtonTheme -Button $c -Role "btn-danger" }
                "btn-help"    { Apply-ButtonTheme -Button $c -Role "btn-help" }
                "btn-neutral" { Apply-ButtonTheme -Button $c -Role "btn-neutral" }
                "progressbar" { $c.ForeColor = $t.Accent }
            }
        } catch { }
    }
    # The header panel has a custom Paint handler that draws its own border
    # using $script:t.Border at paint time. We have to Invalidate it so the
    # border redraws in the new theme colour.
    if ($headerPanel) { try { $headerPanel.Invalidate() } catch { } }
}


# ==============================================================================
# SECTION 4 - Script-level state + path resolution
# ==============================================================================
# $script:process holds the running robocopy Process object. Used by the
# Cancel button to send Kill() and by the wait loop in Execute-Copy to detect
# when robocopy has finished. Null when nothing is running.
$script:process = $null

# Resolve the script's directory in a launch-context-tolerant way. We need
# this to locate rhino_copy.ico relative to the .ps1 file regardless of how
# the script was started:
#   - $PSScriptRoot is the standard automatic variable for "the folder this
#     script lives in" under powershell.exe -File launches. Most reliable.
#   - $PSCommandPath is set when the script is dot-sourced or invoked via
#     a path. Take its parent directory.
#   - $MyInvocation.MyCommand.Path is a legacy fallback for ISE / older hosts.
#   - Last resort: current working directory, which works if the user
#     happened to cd into the script's directory before running it.
$scriptPath = if ($PSScriptRoot) { $PSScriptRoot }
              elseif ($PSCommandPath) { Split-Path -Parent $PSCommandPath }
              elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path }
              else { (Get-Location).Path }
$iconPath = Join-Path $scriptPath "rhino_copy.ico"

# Crash log path. Critical for diagnosing failures when the script is
# launched with -WindowStyle Hidden, because then there is no visible
# console and Write-Host / unhandled errors otherwise vanish silently.
# The outer catch block in Section 6 appends here on any startup failure.
$crashLog = Join-Path $env:TEMP "RhinoCopy_crash.log"


# ==============================================================================
# SECTION 5 - Form build (entire form construction is inside an outer try
#             block so any startup error is caught and logged)
# ==============================================================================
try {

    # --------------------------------------------------------------------
    # SECTION 5a - Form shell, top-level form properties, FormClosing
    # --------------------------------------------------------------------
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "RhinoCopy v1.69"
    # MinimumSize prevents the user shrinking the form to where controls
    # would overlap. Set just slightly smaller than the default Size so
    # there is no jarring resize on first display.
    $form.MinimumSize = New-Object System.Drawing.Size(1000,810)
    $form.Size = New-Object System.Drawing.Size(1100,830)
    $form.StartPosition = "CenterScreen"
    $form.MaximizeBox = $true
    $form.FormBorderStyle = 'Sizable'
    $form.Font = $fontRegular
    $form.AutoScaleMode = 'Font'
    $form.Padding = New-Object System.Windows.Forms.Padding(6)
    # Set form background and text colour to the active theme NOW (rather
    # than relying on Apply-Theme to do it later), so dark mode is visible
    # the instant the form first paints. Without this the form body would
    # flash default Windows grey for one frame before being repainted.
    $form.BackColor = $script:t.Bg
    $form.ForeColor = $script:t.Text
    # FormClosing handler. Since robocopy runs synchronously (the click
    # handler blocks while the copy runs), the form is functionally locked
    # during a copy - the user cannot reach the close button. So this
    # handler is just a no-op placeholder. Kept here to make it obvious
    # where to add close-time cleanup if it's ever needed.
    $form.Add_FormClosing({
        param($sender, $e)
        # Intentionally empty. The form cannot be closed while a copy is
        # running because the UI thread is occupied by Execute-Copy's
        # DoEvents wait loop. After the copy completes, control returns
        # to the message pump and normal close behaviour resumes.
    })

    # Window icon - silently ignored if the .ico file is missing.
    if (Test-Path $iconPath) { try { $form.Icon = New-Object System.Drawing.Icon($iconPath) } catch { } }


    # --------------------------------------------------------------------
    # SECTION 5b - Header panel: mascot, title, progress, top-right buttons
    # --------------------------------------------------------------------
    # The header panel acts as a card containing the mascot picture box on
    # the left, title and subtitle labels in the middle, a progress label
    # and bar below them, and two buttons stacked top-right (Flag Reference
    # over Light/Dark mode toggle).
    #
    # The panel has a custom Paint handler that draws its own border. We
    # use Paint rather than setting BorderStyle because BorderStyle gives
    # us the ugly default System chrome that won't respect $script:t.Border.
    # The Paint handler reads $script:t at paint time, so when the theme
    # is toggled and Apply-Theme calls $headerPanel.Invalidate(), the
    # border is automatically redrawn in the new theme colour.
    $headerPanel = New-Object System.Windows.Forms.Panel
    $headerPanel.Location = New-Object System.Drawing.Point(10,10)
    $headerPanel.Size = New-Object System.Drawing.Size(1070,84)
    # Anchor Top|Left|Right so the panel stretches with the form on resize.
    $headerPanel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $headerPanel.BackColor = $script:t.Surface
    $headerPanel.Add_Paint({
        param($s, $e)
        # Read $script:t at paint time so the border colour updates on
        # theme switch. The pen is disposed inside this scope to avoid
        # leaking a GDI handle every time the panel repaints.
        $pen = New-Object System.Drawing.Pen($script:t.Border, 1)
        $e.Graphics.DrawRectangle($pen, 0, 0, $s.Width - 1, $s.Height - 1)
        $pen.Dispose()
    })
    Register-Themed -Control $headerPanel -Role "surface"
    $form.Controls.Add($headerPanel)

    # ----- Mascot picture box (clickable easter egg trigger) -----
    # PictureBox is a small bitmap displayed on the left of the header.
    # Clicking it cycles through three escalating mood arrays of messages.
    # The Hand cursor signals it's clickable. SizeMode = StretchImage so
    # the bitmap fits the 60x60 box regardless of source dimensions.
    $pictureBox = New-Object System.Windows.Forms.PictureBox
    $pictureBox.Location = New-Object System.Drawing.Point(10,5)
    $pictureBox.Size = New-Object System.Drawing.Size(60,60)
    $pictureBox.SizeMode = "StretchImage"
    $pictureBox.Cursor = [System.Windows.Forms.Cursors]::Hand
    $pictureBox.BackColor = $script:t.Surface
    Register-Themed -Control $pictureBox -Role "surface"
    # Loads the rhino_copy.ico file as the mascot image. The .ico file is
    # shipped alongside the script. Wrapped in try/catch so an absent or
    # corrupt icon doesn't kill form construction - the mascot is just
    # invisible in that case.
    if (Test-Path $iconPath) { try { $pictureBox.Image = [System.Drawing.Image]::FromFile($iconPath) } catch { } }

    # ----- Easter egg message arrays -----
    # Three arrays representing the rhino's mood as the user keeps clicking:
    #   1-10 clicks   -> friendlyMessages (helpful IT humour)
    #   11-20 clicks  -> irritatedMessages (he's getting annoyed)
    #   21+ clicks    -> blanketStatements (he's retired, send help to neaves.au/resume)
    # Any real interaction with the form (Browse, Copy, radio change)
    # resets $script:clickCount to 0 so the mascot stays friendly when the
    # user is actually working. $script:lastMessage prevents the same
    # message being shown twice in a row.
    $script:clickCount = 0
    $script:lastMessage = ""
    $friendlyMessages = @(
        'This is a cute Rhino mascot!',
        "FocusNet is great, don't you think?",
        'Have you tried turning it off and on again?',
        'How good is SFC Scannow?',
        'Ctrl+Alt+Delete is your friend!',
        'Coffee keeps the IT desk alive!',
        'Ping me if you need help!',
        'Rebooting solves 90% of issues!',
        'Have you checked the event logs?',
        'A fresh install fixes everything!',
        'Did you update your drivers yet?',
        "The cloud is just someone else's computer!",
        'Unplug it, wait 10 seconds, plug it back in!',
        'Run as administrator - magic words!',
        'Did you try incognito mode?',
        "Clear the cache, it's always the cache!",
        'The server room needs more fans!',
        "Backup your data before it's too late!",
        'Is the printer on? Really on?',
        'IT: the unsung heroes of tech!',
        'A quick reboot can fix anything!',
        'Did you check for Windows updates?',
        'The IT team deserves a raise!',
        'Power cycling is the ultimate trick!',
        'Keep calm and call IT!',
        'Why is the network slow? Because Brad is streaming again.',
        'Tip: my homelab adventures are over at neaves.au/blog',
        "If you're enjoying RhinoCopy, the rest of my work lives at neaves.au",
        'Got a question for me? https://neaves.au/contact',
        'Single? Looking? https://neaves.au/cupid - no judgement here',
        "I'd write more easter eggs but I'm busy at neaves.au/blog",
        'There are 10 types of people: those who understand binary and those who don''t.',
        "It's not a bug, it's an undocumented feature.",
        "If it works, don't touch it. If it doesn't work, blame DNS.",
        "There's no place like 127.0.0.1.",
        'sudo make me a sandwich.',
        "Have you tried it with the antivirus disabled? (just for testing)",
        "It's always DNS. Always.",
        'Step 1: Backup. Step 2: Pray. Step 3: Restore.',
        'Hardware: the parts of a computer you can kick.',
        "I'd tell you a UDP joke, but you might not get it.",
        'A SQL query walks into a bar, walks up to two tables, and asks: may I join you?',
        "The S in IoT stands for Security.",
        'Why do programmers prefer dark mode? Because light attracts bugs.',
        "There are two hard things in computer science: cache invalidation, naming things, and off-by-one errors.",
        'Have you cleared the print spooler today?',
        'PEBKAC: Problem Exists Between Keyboard And Chair.',
        'ID-10-T error detected.',
        "It worked on my machine.",
        "I'm not lazy, I'm just running in low-power mode.",
        'Real programmers count from 0.',
        "Tabs vs spaces? Yes.",
        "Friday afternoon deployments are a love language.",
        'The user manual is the last resort. Like, after Stack Overflow.',
        "Did you put it in airplane mode? Then back? Magic!",
        'Have you tried percussive maintenance?',
        "Production is just a staging environment with users.",
        'My code does not have bugs. It develops random features.',
        "Backups are great. Tested backups are greater.",
        'Press any key to continue. No, not THAT key.',
        "Ticket says: 'Computer broken'. Investigating with great enthusiasm.",
        "RAID is not a backup. Say it with me.",
        'Have you tried defragging your feelings?',
        'In case of fire: git commit, git push, leave building.',
        "Caffeine: the IT department's most critical dependency.",
        "404: Motivation not found.",
        'Reboots heal all wounds.',
        "The user asked for fewer popups, so I removed the error messages.",
        'Why is the network slow? Because Brad is streaming again.'
    )
    $irritatedMessages = @(
        'Stop, why are you still doing this?',
        'Get back to work Brad!',
        'Leave me alone Andrew!',
        "I'm reporting you to HR!",
        "Don't poke me there!",
        "I'm quitting!",
        'Enough already, go troubleshoot!',
        'Take a break, seriously!',
        "I'm calling the sysadmin!",
        'This is harassment, Rhino-style!',
        'Click me one more time, I dare you!',
        'My horn is not for clicking!',
        "I'm not your personal tech support!",
        'Go fix your own Wi-Fi!',
        'I need a vacation from you!',
        'Stop clicking, start working!',
        "I'm too tired for this nonsense!",
        "You're giving me a headache!",
        "I'm about to stampede - watch out!",
        "Clicking me won't fix your computer!",
        "I've had it with your clicking obsession!",
        'My patience is thinner than a cable!',
        "I'm charging you per click now!",
        'Go bother the network switch!',
        "Lonely? Try neaves.au/cupid - bother someone else for a change.",
        "I'm hibernating - leave me alone!",
        "You've worn out my Rhino welcome!",
        "I'm filing a complaint with the herd!",
        'No more advice, figure it out!',
        "I'm muting you digitally!",
        "My horn's on strike - good luck!",
        "I've opened a ticket. It is P4. You will hear back in 6-8 weeks.",
        "Your warranty just expired.",
        "Have you tried reading the manual? Anyone? Anyone?",
        "I'm putting your IP on the blocklist.",
        "Escalating this to my manager. He's also a rhino.",
        "RTFM. The 'F' isn't for 'friendly'.",
        "I've muted this conversation in Teams.",
        "Adding you to my Outlook rules: auto-delete.",
        'Marking this as "wontfix".',
        "Your ticket has been closed. Reason: existential exhaustion.",
        "I am pivoting to mainframe support. Goodbye.",
        "Did you try Googling it? With your eyes open?",
        "Have you tried not clicking me?",
        "I'm initiating a hard reset on this relationship.",
        'You have been throttled.',
        "Your access has been revoked. By me. Personally.",
        'Rate limiting your clicks now. 1 per hour.',
        'PEBKAC, and the K stands for "keep clicking".',
        "Your IT skills are giving me a kernel panic.",
        "I'm running on fumes and 2% battery.",
        'My SLA does not cover stupid questions.',
        "I'm taking this to the change advisory board. They will say no.",
        "I'm escalating. To my therapist.",
        "Closing as 'works as designed'. The design is: leave me alone."
    )
    $blanketStatements = @(
        "I'm done talking - go fix your own mess!",
        "I've retired - talk to the horn!",
        'No more Rhino wisdom for you!',
        "I'm off to graze - goodbye!",
        "You've annoyed me into silence!",
        "Out of office. Forever. Do not contact.",
        "Permanently AFK.",
        "Status: Do Not Disturb. Status reason: you.",
        'I have been ghosted by my own patience.',
        "Service unavailable. Try again never.",
        "Connection refused.",
        "503: Rhino Temporarily Unavailable (and by temporarily, I mean forever).",
        "I am now a mainframe operator in a cave. Do not follow.",
        "kthxbai.",
        "I have moved to /dev/null. Mail will not be forwarded.",
        "I quit. Hiring managers can find me at https://neaves.au/resume",
        "Forwarding my CV to neaves.au/resume - you can't fire me, I fire me."
    )
    # Mascot click handler. Bumps the counter, picks a non-repeating message
    # from the appropriate mood array, writes it into the status log. The
    # `do...while` loop with the lastMessage check prevents the same message
    # appearing twice consecutively. The `Count -gt 1` guard avoids an
    # infinite loop in the (unreachable) case of a single-entry array.
    $pictureBox.Add_Click({
        $script:clickCount++
        $newMessage = ""
        if ($script:clickCount -le 10) {
            do { $newMessage = $friendlyMessages | Get-Random } while ($newMessage -eq $script:lastMessage -and $friendlyMessages.Count -gt 1)
        } elseif ($script:clickCount -le 20) {
            do { $newMessage = $irritatedMessages | Get-Random } while ($newMessage -eq $script:lastMessage -and $irritatedMessages.Count -gt 1)
        } else {
            do { $newMessage = $blanketStatements | Get-Random } while ($newMessage -eq $script:lastMessage -and $blanketStatements.Count -gt 1)
        }
        $script:lastMessage = $newMessage
        $txtStatus.Text = "Secret Rhino Message: " + $newMessage
    })
    $headerPanel.Controls.Add($pictureBox)

    # ----- Title and subtitle labels -----
    # Title is the big "RhinoCopy" wordmark to the right of the mascot.
    # Subtitle is the tagline below it. Both registered for theming so they
    # repaint on dark/light toggle.
    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = "RhinoCopy"
    $lblTitle.Location = New-Object System.Drawing.Point(80,10)
    $lblTitle.Size = New-Object System.Drawing.Size(180,30)
    $lblTitle.Font = $fontTitle
    $lblTitle.BackColor = $script:t.Surface
    $lblTitle.ForeColor = $script:t.Text
    $lblTitle.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    Register-Themed -Control $lblTitle -Role "header"
    $headerPanel.Controls.Add($lblTitle)

    $lblSubtitle = New-Object System.Windows.Forms.Label
    $lblSubtitle.Text = "Robocopy with a friendly face"
    $lblSubtitle.Location = New-Object System.Drawing.Point(82,40)
    $lblSubtitle.Size = New-Object System.Drawing.Size(260,18)
    $lblSubtitle.Font = $fontRegular
    $lblSubtitle.BackColor = $script:t.Surface
    $lblSubtitle.ForeColor = $script:t.Muted
    Register-Themed -Control $lblSubtitle -Role "muted"
    $headerPanel.Controls.Add($lblSubtitle)

    # ----- Progress label and bar -----
    # The progress label sits above the progress bar. Its text and colour
    # are both updated dynamically during a copy:
    #   - At rest:        "Ready"               (muted colour)
    #   - During copy:    animated by a Timer   (accent colour)
    #   - After success:  "Completed (exit N)"  (success colour)
    #   - After failure:  "Failed (exit N)"     (danger colour)
    # Anchor Top|Left|Right so it stretches with the form on resize.
    $lblProgress = New-Object System.Windows.Forms.Label
    $lblProgress.Text = "Ready"
    $lblProgress.Location = New-Object System.Drawing.Point(350,10)
    $lblProgress.Size = New-Object System.Drawing.Size(580,18)
    $lblProgress.Font = $fontSemibold
    $lblProgress.BackColor = $script:t.Surface
    $lblProgress.ForeColor = $script:t.Muted
    $lblProgress.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $lblProgress.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    Register-Themed -Control $lblProgress -Role "muted"
    $headerPanel.Controls.Add($lblProgress)

    # The progress bar starts in Continuous style at 0%. Execute-Copy
    # flips it to Marquee style during a copy so it shows a scrolling
    # chevron animation (since robocopy doesn't emit reliable overall %).
    $progressBar = New-Object System.Windows.Forms.ProgressBar
    $progressBar.Location = New-Object System.Drawing.Point(350,34)
    $progressBar.Size = New-Object System.Drawing.Size(580,16)
    $progressBar.Style = "Continuous"
    $progressBar.ForeColor = $script:t.Accent
    $progressBar.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    Register-Themed -Control $progressBar -Role "progressbar"
    $headerPanel.Controls.Add($progressBar)

    # ----- Header buttons (Flag Reference + Theme Toggle, stacked) -----
    # Two buttons in the top-right column, stacked vertically. Anchored to
    # Top|Right so they stay pinned to the top-right corner on resize.
    # Both use the neutral button style since they're auxiliary actions
    # (not primary or destructive).

    # Flag Reference button - opens a child dialog with every robocopy flag
    # documented. Click resets the mascot counter so opening the reference
    # mid-easter-egg doesn't keep his anger going.
    $btnFlags = New-Object System.Windows.Forms.Button
    $btnFlags.Location = New-Object System.Drawing.Point(945,10)
    $btnFlags.Size = New-Object System.Drawing.Size(115,30)
    $btnFlags.Text = "Flag Reference"
    $btnFlags.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
    Apply-ButtonTheme -Button $btnFlags -Role "btn-neutral"
    Register-Themed -Control $btnFlags -Role "btn-neutral"
    $btnFlags.Add_Click({ Show-FlagReference; $script:clickCount = 0 })
    $headerPanel.Controls.Add($btnFlags)

    # Theme toggle button. The text shows the TARGET theme (what happens
    # when you click), not the current theme. So in dark mode it reads
    # "Light mode" because clicking it switches to light.
    # On click: flip $script:currentTheme, re-point $script:t to the new
    # palette, then call Apply-Theme to walk all registered controls and
    # repaint them with the new colours.
    $btnTheme = New-Object System.Windows.Forms.Button
    $btnTheme.Location = New-Object System.Drawing.Point(945,44)
    $btnTheme.Size = New-Object System.Drawing.Size(115,30)
    $btnTheme.Text = "Light mode"
    $btnTheme.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
    Apply-ButtonTheme -Button $btnTheme -Role "btn-neutral"
    Register-Themed -Control $btnTheme -Role "btn-neutral"
    $btnTheme.Add_Click({
        if ($script:currentTheme -eq "dark") { $script:currentTheme = "light"; $btnTheme.Text = "Dark mode" }
        else { $script:currentTheme = "dark"; $btnTheme.Text = "Light mode" }
        $script:t = $script:themes[$script:currentTheme]
        Apply-Theme
    })
    $headerPanel.Controls.Add($btnTheme)


    # --------------------------------------------------------------------
    # SECTION 5c - Path input rows (Source and Destination)
    # --------------------------------------------------------------------
    # Two identical-looking rows: a label on the left, a wide textbox in
    # the middle (anchored to stretch with the form), and a Browse button
    # on the right (anchored to stay pinned right on resize). The label
    # role is "label-body" because labels outside group boxes sit on the
    # form's main background, not on a surface card.

    # --- Source row ---
    $lblSource = New-Object System.Windows.Forms.Label
    $lblSource.Text = "Source"
    $lblSource.Location = New-Object System.Drawing.Point(10,120)
    $lblSource.Size = New-Object System.Drawing.Size(110,22)
    $lblSource.Font = $fontHeader
    $lblSource.BackColor = $script:t.Bg
    $lblSource.ForeColor = $script:t.Text
    Register-Themed -Control $lblSource -Role "label-body"
    $form.Controls.Add($lblSource)

    $txtSource = New-Object System.Windows.Forms.TextBox
    $txtSource.Location = New-Object System.Drawing.Point(125,118)
    $txtSource.Size = New-Object System.Drawing.Size(845,26)
    $txtSource.Font = $fontRegular
    $txtSource.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $txtSource.BackColor = $script:t.Surface
    $txtSource.ForeColor = $script:t.Text
    # Top|Left|Right anchor stretches the textbox with the form width,
    # keeping the Browse button pinned to the right edge.
    $txtSource.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    Register-Themed -Control $txtSource -Role "input"
    $form.Controls.Add($txtSource)

    # Source Browse button. Opens FolderBrowserDialog. If the textbox
    # already contains a valid path, pre-seed the dialog with it so the
    # user doesn't have to navigate from C:\ each time. Resets the mascot
    # click counter since this is a real interaction.
    $btnSource = New-Object System.Windows.Forms.Button
    $btnSource.Location = New-Object System.Drawing.Point(980,116)
    $btnSource.Size = New-Object System.Drawing.Size(90,30)
    $btnSource.Text = "Browse"
    $btnSource.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
    Apply-ButtonTheme -Button $btnSource -Role "btn-neutral"
    Register-Themed -Control $btnSource -Role "btn-neutral"
    $btnSource.Add_Click({
        $folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
        $folderBrowser.Description = "Select Source Folder"
        # Pre-seed with current value if valid - saves navigating from root.
        if ($txtSource.Text -and (Test-Path $txtSource.Text)) { $folderBrowser.SelectedPath = $txtSource.Text }
        if ($folderBrowser.ShowDialog() -eq "OK") { $txtSource.Text = $folderBrowser.SelectedPath }
        $script:clickCount = 0
    })
    $form.Controls.Add($btnSource)

    # --- Destination row ---
    # Same pattern as Source, just 38px lower.
    $lblDest = New-Object System.Windows.Forms.Label
    $lblDest.Text = "Destination"
    $lblDest.Location = New-Object System.Drawing.Point(10,158)
    $lblDest.Size = New-Object System.Drawing.Size(110,22)
    $lblDest.Font = $fontHeader
    $lblDest.BackColor = $script:t.Bg
    $lblDest.ForeColor = $script:t.Text
    Register-Themed -Control $lblDest -Role "label-body"
    $form.Controls.Add($lblDest)

    $txtDest = New-Object System.Windows.Forms.TextBox
    $txtDest.Location = New-Object System.Drawing.Point(125,156)
    $txtDest.Size = New-Object System.Drawing.Size(845,26)
    $txtDest.Font = $fontRegular
    $txtDest.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $txtDest.BackColor = $script:t.Surface
    $txtDest.ForeColor = $script:t.Text
    $txtDest.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    Register-Themed -Control $txtDest -Role "input"
    $form.Controls.Add($txtDest)

    $btnDest = New-Object System.Windows.Forms.Button
    $btnDest.Location = New-Object System.Drawing.Point(980,154)
    $btnDest.Size = New-Object System.Drawing.Size(90,30)
    $btnDest.Text = "Browse"
    $btnDest.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
    Apply-ButtonTheme -Button $btnDest -Role "btn-neutral"
    Register-Themed -Control $btnDest -Role "btn-neutral"
    $btnDest.Add_Click({
        $folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
        $folderBrowser.Description = "Select Destination Folder"
        if ($txtDest.Text -and (Test-Path $txtDest.Text)) { $folderBrowser.SelectedPath = $txtDest.Text }
        if ($folderBrowser.ShowDialog() -eq "OK") { $txtDest.Text = $folderBrowser.SelectedPath }
        $script:clickCount = 0
    })
    $form.Controls.Add($btnDest)


    # --------------------------------------------------------------------
    # SECTION 5d - Option group boxes (Performance, Copy Options, Mode)
    # --------------------------------------------------------------------
    # Three group boxes stacked in the left column under the path rows:
    #   Performance Mode  - /MT thread count (Performance / Restricted /
    #                       Super Restricted = 18 / 9 / 4 threads)
    #   Copy Options      - /COPY flag preset (Minimal D / Standard DAT /
    #                       Secure DATS / Full DATSO)
    #   Mode              - Standard (/E recurse) vs Mirror (/MIR, destructive)
    # Each option has a small "?" help button that writes a detailed
    # explanation to the status log on click. The help text is stored in
    # the option's .Tag property so the help button's click handler can
    # read it without duplicating the explanation in code.
    # mixed, MT:4 for network/constrained boxes where MT:18 causes thrashing.
    $groupBoxPerformance = New-Object System.Windows.Forms.GroupBox
    $groupBoxPerformance.Location = New-Object System.Drawing.Point(10,200)
    $groupBoxPerformance.Size = New-Object System.Drawing.Size(280,110)
    # Leading spaces fake padding - GroupBox has no Padding property for its title.
    $groupBoxPerformance.Text = "  Performance Mode"
    $groupBoxPerformance.Font = $fontHeader
    $groupBoxPerformance.BackColor = $script:t.Surface
    $groupBoxPerformance.ForeColor = $script:t.Text
    Register-Themed -Control $groupBoxPerformance -Role "groupbox"
    $form.Controls.Add($groupBoxPerformance)

    $radioPerformance = New-Object System.Windows.Forms.RadioButton
    $radioPerformance.Location = New-Object System.Drawing.Point(12,28)
    $radioPerformance.Size = New-Object System.Drawing.Size(260,24)
    $radioPerformance.Text = "Performance (MT:18)"
    $radioPerformance.Font = $fontRegular
    $radioPerformance.BackColor = $script:t.Surface
    $radioPerformance.ForeColor = $script:t.Text
    $radioPerformance.Checked = $true
    $radioPerformance.Add_CheckedChanged({ $script:clickCount = 0 })
    Register-Themed -Control $radioPerformance -Role "radio"
    $groupBoxPerformance.Controls.Add($radioPerformance)

    $radioRestricted = New-Object System.Windows.Forms.RadioButton
    $radioRestricted.Location = New-Object System.Drawing.Point(12,53)
    $radioRestricted.Size = New-Object System.Drawing.Size(260,24)
    $radioRestricted.Text = "Restricted (MT:9)"
    $radioRestricted.Font = $fontRegular
    $radioRestricted.BackColor = $script:t.Surface
    $radioRestricted.ForeColor = $script:t.Text
    $radioRestricted.Add_CheckedChanged({ $script:clickCount = 0 })
    Register-Themed -Control $radioRestricted -Role "radio"
    $groupBoxPerformance.Controls.Add($radioRestricted)

    $radioSuperRestricted = New-Object System.Windows.Forms.RadioButton
    $radioSuperRestricted.Location = New-Object System.Drawing.Point(12,78)
    $radioSuperRestricted.Size = New-Object System.Drawing.Size(260,24)
    $radioSuperRestricted.Text = "Super Restricted (MT:4)"
    $radioSuperRestricted.Font = $fontRegular
    $radioSuperRestricted.BackColor = $script:t.Surface
    $radioSuperRestricted.ForeColor = $script:t.Text
    $radioSuperRestricted.Add_CheckedChanged({ $script:clickCount = 0 })
    Register-Themed -Control $radioSuperRestricted -Role "radio"
    $groupBoxPerformance.Controls.Add($radioSuperRestricted)

    # Copy Options: /COPY flag preset. D=Data, A=Attrs, T=Times, S=Security, O=Owner.
    $groupBoxCopy = New-Object System.Windows.Forms.GroupBox
    $groupBoxCopy.Location = New-Object System.Drawing.Point(10,320)
    $groupBoxCopy.Size = New-Object System.Drawing.Size(280,150)
    $groupBoxCopy.Text = "  Copy Options"
    $groupBoxCopy.Font = $fontHeader
    $groupBoxCopy.BackColor = $script:t.Surface
    $groupBoxCopy.ForeColor = $script:t.Text
    Register-Themed -Control $groupBoxCopy -Role "groupbox"
    $form.Controls.Add($groupBoxCopy)

    # Helper for the "?" help buttons. Returns the button for the caller to place.
    $makeHelpBtn = {
        param($x, $y, $clickScript)
        $b = New-Object System.Windows.Forms.Button
        $b.Location = New-Object System.Drawing.Point($x, $y)
        $b.Size = New-Object System.Drawing.Size(24,24)
        $b.Text = "?"
        $b.Font = $fontSemibold
        Apply-ButtonTheme -Button $b -Role "btn-help"
        Register-Themed -Control $b -Role "btn-help"
        $b.Add_Click($clickScript)
        return $b
    }

    $radioCopyMinimal = New-Object System.Windows.Forms.RadioButton
    $radioCopyMinimal.Location = New-Object System.Drawing.Point(12,28)
    $radioCopyMinimal.Size = New-Object System.Drawing.Size(220,24)
    $radioCopyMinimal.Text = "Minimal (Data Only)"
    $radioCopyMinimal.Font = $fontRegular
    $radioCopyMinimal.BackColor = $script:t.Surface
    $radioCopyMinimal.ForeColor = $script:t.Text
    $radioCopyMinimal.Tag = "Quick: copies only file contents. Strips attributes, timestamps, NTFS permissions and owner from the destination - destination files inherit permissions from their parent folder.`r`n`r`nDetails: corresponds to robocopy /COPY:D. The 'D' flag means data only. Useful when you want the destination to be a clean copy without dragging along source-specific permissions or timestamps - common when copying from one user's folder to another, or seeding files into a new project area where you want fresh ACLs.`r`n`r`nFile permissions: NOT copied. Destination files inherit ACLs from their parent folder.`r`n`r`nTimestamps: NOT copied. Destination files get their creation/modification time set to the moment of the copy.`r`n`r`nOverwrites: yes, if source is newer than destination (default robocopy behaviour). The /COPY flag controls WHAT is copied per file, not WHETHER existing files are touched."
    $radioCopyMinimal.Add_CheckedChanged({ $script:clickCount = 0 })
    Register-Themed -Control $radioCopyMinimal -Role "radio"
    $groupBoxCopy.Controls.Add($radioCopyMinimal)
    $groupBoxCopy.Controls.Add((& $makeHelpBtn 245 28 { $txtStatus.Text = "Minimal (Data Only):`r`n" + $radioCopyMinimal.Tag; $script:clickCount = 0 }))

    $radioCopyStandard = New-Object System.Windows.Forms.RadioButton
    $radioCopyStandard.Location = New-Object System.Drawing.Point(12,58)
    $radioCopyStandard.Size = New-Object System.Drawing.Size(220,24)
    $radioCopyStandard.Text = "Standard (DAT)"
    $radioCopyStandard.Font = $fontRegular
    $radioCopyStandard.BackColor = $script:t.Surface
    $radioCopyStandard.ForeColor = $script:t.Text
    $radioCopyStandard.Tag = "Quick: copies file contents, attributes (read-only, hidden, etc.), and timestamps. Permissions and owner are NOT copied - the destination inherits them from its parent folder.`r`n`r`nDetails: corresponds to robocopy /COPY:DAT. This is robocopy's default and the right choice for most general-purpose copies. Files arrive at the destination with their original modification time and any non-security attributes intact, but with permissions appropriate for the destination location.`r`n`r`nFile permissions: NOT copied. Destination files inherit ACLs from their parent folder.`r`n`r`nTimestamps: copied. The destination preserves the source's last-modified time.`r`n`r`nOverwrites: yes, if source is newer than destination. To force overwrite of all matching files use /IS (not currently exposed in this tool)."
    $radioCopyStandard.Checked = $true
    $radioCopyStandard.Add_CheckedChanged({ $script:clickCount = 0 })
    Register-Themed -Control $radioCopyStandard -Role "radio"
    $groupBoxCopy.Controls.Add($radioCopyStandard)
    $groupBoxCopy.Controls.Add((& $makeHelpBtn 245 58 { $txtStatus.Text = "Standard (DAT):`r`n" + $radioCopyStandard.Tag; $script:clickCount = 0 }))

    $radioCopySecure = New-Object System.Windows.Forms.RadioButton
    $radioCopySecure.Location = New-Object System.Drawing.Point(12,88)
    $radioCopySecure.Size = New-Object System.Drawing.Size(220,24)
    $radioCopySecure.Text = "Secure (DATS)"
    $radioCopySecure.Font = $fontRegular
    $radioCopySecure.BackColor = $script:t.Surface
    $radioCopySecure.ForeColor = $script:t.Text
    $radioCopySecure.Tag = "Quick: copies file contents, attributes, timestamps, AND NTFS permissions (ACLs). The destination files have the same access control as the source.`r`n`r`nDetails: corresponds to robocopy /COPY:DATS. The 'S' flag adds NTFS security descriptors (DACLs and SACLs) to the copy. Use this when migrating files between servers or user profiles and you need to preserve who can read/write each file. Note: requires that both source and destination filesystems support NTFS ACLs - copying to FAT32, exFAT, or many network shares will silently lose the ACLs.`r`n`r`nFile permissions: COPIED. Source ACLs are written onto the destination files, replacing any inherited permissions.`r`n`r`nTimestamps: copied.`r`n`r`nOverwrites: yes, if source is newer than destination.`r`n`r`nGotcha: if the destination volume's permissions model differs from source, the copied ACLs may grant unintended access. Audit afterwards if security matters."
    $radioCopySecure.Add_CheckedChanged({ $script:clickCount = 0 })
    Register-Themed -Control $radioCopySecure -Role "radio"
    $groupBoxCopy.Controls.Add($radioCopySecure)
    $groupBoxCopy.Controls.Add((& $makeHelpBtn 245 88 { $txtStatus.Text = "Secure (DATS):`r`n" + $radioCopySecure.Tag; $script:clickCount = 0 }))

    $radioCopyFull = New-Object System.Windows.Forms.RadioButton
    $radioCopyFull.Location = New-Object System.Drawing.Point(12,118)
    $radioCopyFull.Size = New-Object System.Drawing.Size(220,24)
    $radioCopyFull.Text = "Full (DATSO)"
    $radioCopyFull.Font = $fontRegular
    $radioCopyFull.BackColor = $script:t.Surface
    $radioCopyFull.ForeColor = $script:t.Text
    $radioCopyFull.Tag = "Quick: copies EVERYTHING - contents, attributes, timestamps, NTFS permissions, and the file owner. Destination files match the source exactly.`r`n`r`nDetails: corresponds to robocopy /COPY:DATSO. The 'O' flag adds the file owner to the security descriptor copy. Use this for full server migrations, profile moves, or any scenario where the destination must be byte-and-metadata identical to the source.`r`n`r`nFile permissions: COPIED including the owner SID.`r`n`r`nTimestamps: copied.`r`n`r`nOverwrites: yes, if source is newer than destination.`r`n`r`nRequirements: typically needs to run elevated (administrator). Setting the owner of a file requires the SeRestorePrivilege - regular user accounts cannot transfer ownership to arbitrary other users. If you see access denied errors during copy, run the script as administrator. Add /B (Backup mode, not currently exposed) for cases where backup operator privileges should be used instead.`r`n`r`nNote: there is also /COPYALL (=/COPY:DATSOU) which additionally copies auditing info. Not exposed here as it is rarely needed."
    $radioCopyFull.Add_CheckedChanged({ $script:clickCount = 0 })
    Register-Themed -Control $radioCopyFull -Role "radio"
    $groupBoxCopy.Controls.Add($radioCopyFull)
    $groupBoxCopy.Controls.Add((& $makeHelpBtn 245 118 { $txtStatus.Text = "Full (DATSO):`r`n" + $radioCopyFull.Tag; $script:clickCount = 0 }))

    # Mode: choose between standard recurse (/E) and mirror (/MIR).
    # Mirror is destructive - it deletes destination files not in source.
    # Putting it as a radio rather than a checkbox forces the user to
    # explicitly choose one mode. Mirror radio is rendered in red.
    $groupBoxMode = New-Object System.Windows.Forms.GroupBox
    $groupBoxMode.Location = New-Object System.Drawing.Point(10,480)
    $groupBoxMode.Size = New-Object System.Drawing.Size(280,90)
    $groupBoxMode.Text = "  Mode"
    $groupBoxMode.Font = $fontHeader
    $groupBoxMode.BackColor = $script:t.Surface
    $groupBoxMode.ForeColor = $script:t.Text
    Register-Themed -Control $groupBoxMode -Role "groupbox"
    $form.Controls.Add($groupBoxMode)

    $radioModeStandard = New-Object System.Windows.Forms.RadioButton
    $radioModeStandard.Location = New-Object System.Drawing.Point(12,28)
    $radioModeStandard.Size = New-Object System.Drawing.Size(220,24)
    $radioModeStandard.Text = "Standard (/E)"
    $radioModeStandard.Font = $fontRegular
    $radioModeStandard.BackColor = $script:t.Surface
    $radioModeStandard.ForeColor = $script:t.Text
    $radioModeStandard.Tag = "Quick: copies all files and subfolders, including empty folders. Files in the destination that are not in the source are LEFT ALONE.`r`n`r`nDetails: corresponds to robocopy /E. Walks the source tree and copies files into the destination. If a file already exists at the destination with the same timestamp and size, it is skipped (not re-copied). If a file is newer in the source than in the destination, it is overwritten. If a file is older or the same age, the existing destination file is preserved (use /IS or /IT to force overwrite). Files present in the destination but not in the source are kept untouched.`r`n`r`nFile permissions: per the Copy Options group above. With Standard (DAT), destination inherits permissions from its parent folder. With Secure (DATS) or Full (DATSO), source ACLs are preserved on the destination.`r`n`r`nOverwrites: yes, if the source file is newer than the destination file."
    $radioModeStandard.Checked = $true
    $radioModeStandard.Add_CheckedChanged({ $script:clickCount = 0 })
    Register-Themed -Control $radioModeStandard -Role "radio"
    $groupBoxMode.Controls.Add($radioModeStandard)
    $groupBoxMode.Controls.Add((& $makeHelpBtn 245 28 { $txtStatus.Text = "Standard (/E):`r`n" + $radioModeStandard.Tag; $script:clickCount = 0 }))

    $radioModeMirror = New-Object System.Windows.Forms.RadioButton
    $radioModeMirror.Location = New-Object System.Drawing.Point(12,58)
    $radioModeMirror.Size = New-Object System.Drawing.Size(220,24)
    $radioModeMirror.Text = "Mirror (/MIR) - destructive"
    $radioModeMirror.Font = $fontSemibold
    $radioModeMirror.BackColor = $script:t.Surface
    $radioModeMirror.ForeColor = $script:t.Danger
    $radioModeMirror.Tag = "Quick: makes the destination an EXACT mirror of the source. DELETES files and folders in the destination that are not present in the source.`r`n`r`nDetails: corresponds to robocopy /MIR, which is /E plus /PURGE. Walks the source tree and copies all files into the destination. After copying, walks the destination and DELETES any file or folder that does not exist in the source. The destination becomes a one-to-one mirror of the source. Use this for incremental backups where you want destinations to track the exact state of the source.`r`n`r`nFile permissions: per the Copy Options group above. Same behaviour as /E.`r`n`r`nOverwrites: yes, if source is newer.`r`n`r`nDeletes: YES. Anything in the destination not in the source is removed without prompting. Cannot be undone except from a previous backup. Use Dry Run first to preview what would be deleted."
    $radioModeMirror.Add_CheckedChanged({
        $script:clickCount = 0
        # Confirmation only when toggling ON.
        if ($radioModeMirror.Checked) {
            $msg = "Mirror mode (/MIR) will DELETE files and folders in the destination that do not exist in the source. This makes the destination an exact mirror of the source.`r`n`r`nAre you sure you want to enable Mirror mode?"
            $r = [System.Windows.Forms.MessageBox]::Show($msg, "Confirm Mirror Mode", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
            if ($r -ne 'Yes') { $radioModeStandard.Checked = $true }
        }
    })
    Register-Themed -Control $radioModeMirror -Role "radio"
    $groupBoxMode.Controls.Add($radioModeMirror)
    $groupBoxMode.Controls.Add((& $makeHelpBtn 245 58 { $txtStatus.Text = "Mirror (/MIR):`r`n" + $radioModeMirror.Tag; $script:clickCount = 0 }))

    $tooltip = New-Object System.Windows.Forms.ToolTip
    $tooltip.SetToolTip($radioCopyMinimal, "Data only. Strips attributes, timestamps, permissions. Click ? for details.")
    $tooltip.SetToolTip($radioCopyStandard, "Data + Attributes + Timestamps. Permissions inherited. Click ? for details.")
    $tooltip.SetToolTip($radioCopySecure, "Adds NTFS permissions (ACLs). Click ? for details.")
    $tooltip.SetToolTip($radioCopyFull, "Adds owner info. Usually needs to run elevated. Click ? for details.")
    $tooltip.SetToolTip($pictureBox, "Click me for IT wisdom!")
    $tooltip.SetToolTip($btnTheme, "Toggle light/dark theme")
    $tooltip.SetToolTip($btnFlags, "Show all Robocopy flags and what they do")


    # --------------------------------------------------------------------
    # SECTION 5e - Bottom checkboxes (Create Log + Dry Run) and status log
    # --------------------------------------------------------------------
    # Two miscellaneous toggles that don't fit inside any of the option
    # group boxes:
    #   Create Log - adds /LOG+:<path>.txt to robocopy's command line so
    #                a timestamped log file is appended in the destination
    #                folder. On by default because a permanent record of
    #                what was copied is almost always wanted.
    #   Dry Run    - adds /L which makes robocopy list-only (no actual
    #                copies, no timestamps changed, no deletions). Useful
    #                for previewing what Mirror mode would delete before
    #                running it for real.

    $chkLog = New-Object System.Windows.Forms.CheckBox
    $chkLog.Location = New-Object System.Drawing.Point(14,580)
    $chkLog.Size = New-Object System.Drawing.Size(130,24)
    $chkLog.Text = "Create Log"
    $chkLog.Font = $fontRegular
    $chkLog.BackColor = $script:t.Bg
    $chkLog.ForeColor = $script:t.Text
    $chkLog.Checked = $true   # Default ON - keep a record of every run.
    $chkLog.Add_CheckedChanged({ $script:clickCount = 0 })
    $tooltip.SetToolTip($chkLog, "Save operation details to a log file in the destination folder")
    Register-Themed -Control $chkLog -Role "checkbox"
    $form.Controls.Add($chkLog)

    $chkDryRun = New-Object System.Windows.Forms.CheckBox
    $chkDryRun.Location = New-Object System.Drawing.Point(150,580)
    $chkDryRun.Size = New-Object System.Drawing.Size(130,24)
    $chkDryRun.Text = "Dry Run"
    $chkDryRun.Font = $fontRegular
    $chkDryRun.BackColor = $script:t.Bg
    $chkDryRun.ForeColor = $script:t.Text
    $chkDryRun.Add_CheckedChanged({ $script:clickCount = 0 })
    $tooltip.SetToolTip($chkDryRun, "Test the operation without actually copying files")
    Register-Themed -Control $chkDryRun -Role "checkbox"
    $form.Controls.Add($chkDryRun)

    # ----- Status log textbox -----
    # Multi-line read-only TextBox that occupies the right two-thirds of
    # the form. Used for:
    #   - The command line being executed (at the start of each run)
    #   - Robocopy's full output (read from /UNILOG: after the copy)
    #   - The plain-English exit code decoder
    #   - "Secret Rhino Message" easter eggs from the mascot
    #   - Help text from the ? buttons next to each radio option
    # Anchored to all four sides so it grows when the form is resized.
    # Consolas mono font so robocopy's column-aligned output lines up
    # cleanly. FixedSingle border for a clean inset look.
    $txtStatus = New-Object System.Windows.Forms.TextBox
    $txtStatus.Multiline = $true
    $txtStatus.ScrollBars = "Vertical"
    $txtStatus.Location = New-Object System.Drawing.Point(300,200)
    $txtStatus.Size = New-Object System.Drawing.Size(770,315)
    $txtStatus.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $txtStatus.Font = $fontMono
    $txtStatus.ReadOnly = $true
    $txtStatus.BackColor = $script:t.Surface
    $txtStatus.ForeColor = $script:t.Text
    $txtStatus.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $txtStatus.Text = "Ready to copy files. Select source and destination paths to begin."
    Register-Themed -Control $txtStatus -Role "log"
    $form.Controls.Add($txtStatus)


    # --------------------------------------------------------------------
    # SECTION 5f - Action buttons (Copy Files, Copy Command, Cancel/Clear)
    # --------------------------------------------------------------------
    # Three buttons stacked in the left column under the option groups:
    #   1. Copy Files (primary green) - validates inputs and runs the copy
    #   2. Copy Command to Clipboard (accent blue) - puts the robocopy
    #      command string on the clipboard for users learning the tool
    #   3. Cancel/Clear (dual-purpose) - shows "Cancel Operation" in red
    #      during a running copy, "Clear Log" in neutral when idle
    # All three anchored Bottom|Left so they stay pinned to the
    # bottom-left corner on resize.

    # ----- Primary action: Copy Files -----
    # The big green button. Validates source/dest paths, then calls
    # Execute-Copy which runs robocopy synchronously and updates the GUI
    # with output and exit code analysis.
    #
    # Validation rules (run in order, first failure shows a MessageBox
    # and aborts without proceeding):
    #   1. Both paths must be non-empty
    #   2. Source path must exist on disk
    #   3. Destination path must exist on disk
    # We deliberately do NOT auto-create the destination because that
    # could mask typos that would otherwise be caught here.
    #
    # The Execute-Copy call is wrapped in try/catch. Any exception is
    # written to the status log and buttons are reset to idle state, so
    # the form stays open and usable even if robocopy fails catastrophically.
    $btnCopy = New-Object System.Windows.Forms.Button
    $btnCopy.Location = New-Object System.Drawing.Point(20,620)
    $btnCopy.Size = New-Object System.Drawing.Size(260,44)
    $btnCopy.Text = "Copy Files"
    $btnCopy.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
    Apply-ButtonTheme -Button $btnCopy -Role "btn-success"
    Register-Themed -Control $btnCopy -Role "btn-success"
    $btnCopy.Add_Click({
        # Validate inputs before doing anything.
        if (-not $txtSource.Text -or -not $txtDest.Text) { [System.Windows.Forms.MessageBox]::Show("Please specify both source and destination paths.", "Invalid Paths", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning); return }
        if (-not (Test-Path $txtSource.Text)) { [System.Windows.Forms.MessageBox]::Show("Source path '$($txtSource.Text)' does not exist.", "Invalid Source Path", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning); return }
        if (-not (Test-Path $txtDest.Text)) { [System.Windows.Forms.MessageBox]::Show("Destination path '$($txtDest.Text)' does not exist or is inaccessible.", "Invalid Destination Path", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning); return }
        $txtStatus.Text = "Initializing copy operation..."
        # Wrap Execute-Copy in try/catch so any exception is contained and
        # doesn't propagate up to close the form. The form needs to stay
        # open after each copy so the user can run more without relaunching.
        try {
            Execute-Copy -DryRun:$chkDryRun.Checked
        } catch {
            try { $txtStatus.AppendText("`r`n[Error during copy: $($_.Exception.Message)]`r`n") } catch { }
            try { $btnCopy.Enabled = $true; Set-ButtonClearMode } catch { }
        }
        $script:clickCount = 0
    })
    $tooltip.SetToolTip($btnCopy, "Start the file copy operation")
    $form.Controls.Add($btnCopy)

    # ----- Secondary action: Copy Command to Clipboard -----
    # For users learning robocopy. Builds the same robocopy command line
    # that Execute-Copy would run and puts it on the clipboard. The user
    # can paste it into a cmd prompt to run it manually, inspect what
    # flags are being passed, save it into a script, etc.
    # Generate-Command (defined in 5g) builds the actual string and uses
    # the same Get-RobocopyFlagsFromUI helper as Execute-Copy, so the
    # displayed command is guaranteed to match what would really run.
    $btnCopyCmd = New-Object System.Windows.Forms.Button
    $btnCopyCmd.Location = New-Object System.Drawing.Point(20,672)
    $btnCopyCmd.Size = New-Object System.Drawing.Size(260,40)
    $btnCopyCmd.Text = "Copy Command to Clipboard"
    $btnCopyCmd.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
    Apply-ButtonTheme -Button $btnCopyCmd -Role "btn-accent"
    Register-Themed -Control $btnCopyCmd -Role "btn-accent"
    $btnCopyCmd.Add_Click({
        # Same path validation as the Copy Files button. Even though we
        # are not actually running anything, an invalid path would produce
        # a garbage command string the user could accidentally run.
        if (-not $txtSource.Text -or -not $txtDest.Text) { [System.Windows.Forms.MessageBox]::Show("Please specify both source and destination paths.", "Invalid Paths", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning); return }
        if (-not (Test-Path $txtSource.Text)) { [System.Windows.Forms.MessageBox]::Show("Source path '$($txtSource.Text)' does not exist.", "Invalid Source Path", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning); return }
        if (-not (Test-Path $txtDest.Text)) { [System.Windows.Forms.MessageBox]::Show("Destination path '$($txtDest.Text)' does not exist or is inaccessible.", "Invalid Destination Path", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning); return }
        $command = Generate-Command
        $txtStatus.Clear()
        $txtStatus.Text = "Command copied to clipboard!`r`n`r`n" + $command
        $command | Set-Clipboard
        [System.Windows.Forms.MessageBox]::Show("Robocopy command has been copied to clipboard!", "Command Copied", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        $script:clickCount = 0
    })
    $tooltip.SetToolTip($btnCopyCmd, "Copy the Robocopy command to clipboard")
    $form.Controls.Add($btnCopyCmd)

    # ----- Dual-purpose button: Cancel (during run) / Clear (when idle) -----
    # The same button changes role depending on whether a copy is in
    # progress. The .Tag property holds the current mode ("cancel" or
    # "clear") so the click handler can dispatch:
    #   - In CANCEL mode: prompts for confirmation, then kills the
    #     running robocopy process. The Execute-Copy wait loop will
    #     notice HasExited and unwind, calling Set-ButtonClearMode.
    #   - In CLEAR mode: wipes the status log box and resets the progress
    #     label back to "Ready". This fixes the annoying behaviour where
    #     a completion message from hours ago kept hanging around in the
    #     header until the next copy run.
    # Default state is Clear because that's what's appropriate when no
    # copy is running. Execute-Copy flips it to Cancel mode on entry
    # via Set-ButtonCancelMode (defined just below this block).
    $btnCancelClear = New-Object System.Windows.Forms.Button
    $btnCancelClear.Location = New-Object System.Drawing.Point(20,720)
    $btnCancelClear.Size = New-Object System.Drawing.Size(260,40)
    $btnCancelClear.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
    $btnCancelClear.Tag = "clear"
    $btnCancelClear.Text = "Clear Log"
    Apply-ButtonTheme -Button $btnCancelClear -Role "btn-neutral"
    Register-Themed -Control $btnCancelClear -Role "btn-neutral"
    $btnCancelClear.Add_Click({
        if ($btnCancelClear.Tag -eq "cancel") {
            # CANCEL mode: kill the running robocopy process.
            if ($script:process -ne $null -and -not $script:process.HasExited) {
                $result = [System.Windows.Forms.MessageBox]::Show("Are you sure you want to cancel the copy operation?", "Confirm Cancel", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
                if ($result -eq 'Yes') {
                    try { $script:process.Kill() } catch { }
                    $txtStatus.AppendText("`r`n`r`nOperation cancelled by user.")
                    $lblProgress.Text = "Cancelled"
                    $lblProgress.ForeColor = $script:t.Danger
                    # The DoEvents loop in Execute-Copy will notice HasExited
                    # and unwind on its own, calling Set-ButtonClearMode.
                }
            }
        } else {
            # CLEAR mode: wipe the status log box and reset the progress
            # label so it doesn't keep showing a stale "Completed (exit N)"
            # from hours ago.
            $txtStatus.Clear()
            $txtStatus.Text = "Ready to copy files. Select source and destination paths to begin."
            $progressBar.Value = 0
            $lblProgress.Text = "Ready"
            $lblProgress.ForeColor = $script:t.Muted
            $script:clickCount = 0
        }
    })
    $tooltip.SetToolTip($btnCancelClear, "Clear the status log and reset the progress display")
    $form.Controls.Add($btnCancelClear)

    # --------------------------------------------------------------------
    # Set-ButtonCancelMode / Set-ButtonClearMode
    # --------------------------------------------------------------------
    # Helpers to flip the dual-purpose Cancel/Clear button between its
    # two modes. They MUST be defined here (inside the form-build try
    # block) because they reference $btnCancelClear and $tooltip which
    # are in this scope.
    #
    # Each helper updates four things:
    #   1. The .Tag property (read by the click handler to dispatch)
    #   2. The button text
    #   3. The button colour (via Apply-ButtonTheme)
    #   4. The button's role in $script:themedControls so the theme
    #      toggle paints it correctly while in the new mode
    #   5. The tooltip text
    # --------------------------------------------------------------------

    # Set-ButtonCancelMode
    # --------------------
    # Called by Execute-Copy on entry. Turns the button red and labels
    # it "Cancel Operation".
    function Set-ButtonCancelMode {
        $btnCancelClear.Tag = "cancel"
        $btnCancelClear.Text = "Cancel Operation"
        Apply-ButtonTheme -Button $btnCancelClear -Role "btn-danger"
        # Update the role in the themed-controls registry too, so if the
        # user toggles light/dark while a copy is running, Apply-Theme
        # repaints the button with the danger-coloured palette.
        foreach ($entry in $script:themedControls) {
            if ($entry.Control -eq $btnCancelClear) { $entry.Role = "btn-danger" }
        }
        $tooltip.SetToolTip($btnCancelClear, "Cancel the running copy operation")
    }

    # Set-ButtonClearMode
    # -------------------
    # Called by Execute-Copy on exit (after the copy finishes or fails).
    # Turns the button neutral and labels it "Clear Log".
    function Set-ButtonClearMode {
        $btnCancelClear.Tag = "clear"
        $btnCancelClear.Text = "Clear Log"
        Apply-ButtonTheme -Button $btnCancelClear -Role "btn-neutral"
        foreach ($entry in $script:themedControls) {
            if ($entry.Control -eq $btnCancelClear) { $entry.Role = "btn-neutral" }
        }
        $tooltip.SetToolTip($btnCancelClear, "Clear the status log and reset the progress display")
    }


    # --------------------------------------------------------------------
    # SECTION 5g - Functions: Execute-Copy and friends
    # --------------------------------------------------------------------
    # The actual copy logic lives here. Defined inside the form-build try
    # block so it has $form, $txtStatus, $progressBar, etc. in scope.
    # PowerShell hoists function definitions to their containing scope at
    # parse time, so click handlers above this point can reference these
    # functions even though they appear later in source order.

    # Execute-Copy
    # ------------
    # The main copy logic. Reads UI state via Get-RobocopyFlagsFromUI,
    # builds the robocopy command, runs robocopy as a synchronous child
    # process (via Start-Process), animates a working progress bar while
    # it runs, then displays the output and exit code analysis.
    #
    # CRITICAL: robocopy is launched synchronously, NOT with async stream
    # redirection. See HANDOFF.md for the full story - using
    # BeginOutputReadLine + $form.Invoke from PowerShell 5.1 caused fatal
    # threadpool races that killed powershell.exe outright. Do not change
    # to async without understanding the prior crash.
    function Execute-Copy {
        param([bool]$DryRun)

        $btnCopy.Enabled = $false
        Set-ButtonCancelMode
        # Marquee animation - the chevron-style scrolling bar. No real progress
        # info needed (robocopy doesn't reliably emit total %, and a pre-scan
        # is misleadingly slow on big trees). The animation just tells the
        # user "something is happening, the form isn't frozen".
        $progressBar.Style = "Marquee"
        $progressBar.MarqueeAnimationSpeed = 30
        $lblProgress.ForeColor = $script:t.Accent
        $txtStatus.Clear()

        # Build /COPY flag and recurse flag from UI state via the shared
        # helper. Both Execute-Copy (here) and Generate-Command use this
        # single source of truth so the displayed clipboard command and
        # the actually-executed command cannot diverge.
        $f = Get-RobocopyFlagsFromUI

        # Build robocopy command and run as a real child process.
        # We do NOT redirect stdout/stderr to PowerShell - robocopy writes
        # to its own log file. This avoids the PowerShell async stream race
        # that previously crashed the host. The user-facing log (when ticked)
        # is also robocopy's own /LOG+ output, written to the destination.
        # /UNILOG: writes the unicode log to a temp file we read back later
        # to display robocopy's output in the GUI status box.
        $progressLog = Join-Path $env:TEMP "RhinoCopy_progress_$([Guid]::NewGuid().ToString('N')).log"
        $rcArgs = @($txtSource.Text, $txtDest.Text, "*.*",
                    "/COPY:$($f.CopyFlags)", "/DCOPY:$($f.CopyFlags)",
                    $f.RecurseFlag, "/XJ", "/W:1", "/R:10", "/NP", "/NDL",
                    $f.MtFlag, "/UNILOG:$progressLog")
        # User-facing log (separate from the /UNILOG: temp file). When ticked,
        # robocopy /LOG+: appends its standard output to a timestamped file
        # in the destination folder for the user to keep.
        $userLogFile = $null
        if ($chkLog.Checked) {
            $userLogFile = Join-Path $txtDest.Text "RhinoCopy_Log_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
            $rcArgs += "/LOG+:$userLogFile"
        }
        if ($DryRun) { $rcArgs += "/L" }   # /L = list-only mode (dry run)

        # Build the displayed command string. Always quotes paths.
        $command = Format-RobocopyCommand -ArgList $rcArgs
        $txtStatus.AppendText("Running:`r`n$command`r`n")
        $txtStatus.Refresh()

        $startTime = Get-Date
        $script:process = Start-Process -FilePath "robocopy" -ArgumentList $rcArgs -PassThru -WindowStyle Hidden -ErrorAction Stop

        # Animation state. Cycle through a spinner glyph + dot pattern + a
        # rotating "doing things" verb so the status label has visible motion
        # alongside the marquee bar. Updated by a WinForms Timer on the UI
        # thread (no threadpool, no race).
        # Use ASCII characters for the spinner so it renders correctly in any
        # font - Unicode braille spinners look great but only in Consolas/mono.
        $script:animFrame = 0
        $script:animVerb = ''
        $spinnerFrames = @('|', '/', '-', '\')
        $dotsFrames    = @('   ', '.  ', '.. ', '...')
        $verbFrames    = @(
            'Copying files',
            'Walking source tree',
            'Comparing timestamps',
            'Shuffling bytes',
            'Talking to NTFS',
            'Pleasing the file system',
            'Asking robocopy nicely',
            'Avoiding junction loops',
            'Probably almost done',
            "Don't quit on me now",
            'Bribing the disk controller',
            'Negotiating with the kernel',
            'Reticulating splines',
            'Convincing bits to move',
            'Yelling at the disk',
            'Waking up the drive heads',
            'Whispering sweet nothings to the file system',
            'Conjuring inodes',
            "It's giving 110%",
            'Performing CPR on slow files',
            'Politely queueing',
            'Looking busy',
            'Doing the needful',
            'Trust me bro',
            'Almost there (no really)',
            'Just one more file',
            'Counting in binary',
            'Stretching before the next folder',
            'Cracking knuckles',
            'Manifesting good outcomes',
            'Vibing with the spindle',
            "Files are people too, you know",
            'Therapising stuck handles',
            'Buffering optimism',
            'Optimising morale',
            'Defragging vibes',
            'Sweet-talking the cluster size',
            'Beep boop',
            'Hold my beer',
            'This is fine',
            'Definitely not stuck',
            'Crossing fingers and toes'
        )

        $animTimer = New-Object System.Windows.Forms.Timer
        $animTimer.Interval = 200
        $animTimer.Add_Tick({
            try {
                $script:animFrame++
                $spin = $spinnerFrames[$script:animFrame % $spinnerFrames.Count]
                $dots = $dotsFrames[$script:animFrame % $dotsFrames.Count]
                # Pick a fresh random verb every ~2.4s. Pick on tick 0 too so
                # we don't show an empty string on the first paint.
                if ($script:animVerb -eq '' -or $script:animFrame % 12 -eq 0) {
                    $script:animVerb = $verbFrames | Get-Random
                }
                $elapsed = (Get-Date) - $startTime
                $elapsedStr = "{0:mm\:ss}" -f $elapsed
                if ($DryRun) {
                    $lblProgress.Text = "$spin  Dry run: $($script:animVerb)$dots  ($elapsedStr)"
                } else {
                    $lblProgress.Text = "$spin  $($script:animVerb)$dots  ($elapsedStr)"
                }
            } catch { }
        })
        $animTimer.Start()

        # Wait for robocopy to finish, pumping the UI message loop.
        # DoEvents lets the animation Timer.Tick fire and the user click Cancel.
        try {
            while ($script:process -ne $null -and -not $script:process.HasExited) {
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 100
            }
        } catch { }

        # Stop the animation cleanly.
        $animTimer.Stop()
        $animTimer.Dispose()
        $progressBar.MarqueeAnimationSpeed = 0
        $progressBar.Style = "Continuous"
        $progressBar.Value = 100

        # Read final log content for display.
        $exitCode = -1
        $output = ""
        try {
            if ($script:process -ne $null) { $exitCode = $script:process.ExitCode }
            if (Test-Path $progressLog) {
                $output = Get-Content -LiteralPath $progressLog -Raw -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $progressLog -Force -ErrorAction SilentlyContinue
            }
        } catch { }

        # Cleanup process handle.
        if ($script:process -ne $null) {
            try { $script:process.Dispose() } catch { }
            $script:process = $null
        }

        $totalElapsed = "{0:mm\:ss}" -f ((Get-Date) - $startTime)

        # Show command + output + status in the log box.
        $txtStatus.Clear()
        $txtStatus.AppendText("Command:`r`n$command`r`n`r`n")
        if ($output) { $txtStatus.AppendText($output) } else { $txtStatus.AppendText("(no output captured)`r`n") }
        $txtStatus.AppendText("`r`n" + ("="*60) + "`r`n")
        $txtStatus.AppendText("Operation completed with exit code: $exitCode (elapsed: $totalElapsed)`r`n`r`n")

        # Robocopy exit codes are bit flags. Build two parallel lists:
        # - $bitsHit: the individual bit values that fired (e.g. 1, 2)
        # - $bitLabels: short label per bit for the headline math
        # - $explanation: full sentence per bit for the breakdown
        $bitsHit = @()
        $bitLabels = @()
        $explanation = @()
        if ($exitCode -band 1)  { $bitsHit += 1;  $bitLabels += "files copied";        $explanation += "[+1] Files were copied successfully." }
        if ($exitCode -band 2)  { $bitsHit += 2;  $bitLabels += "extras in dest";      $explanation += "[+2] Extra files or folders were detected in the destination (not in source). With Mirror mode these were deleted; otherwise they were left untouched." }
        if ($exitCode -band 4)  { $bitsHit += 4;  $bitLabels += "mismatches";          $explanation += "[+4] Mismatched files or folders were detected. Examine the log to investigate." }
        if ($exitCode -band 8)  { $bitsHit += 8;  $bitLabels += "copy errors";         $explanation += "[+8] Some files or folders could not be copied (e.g. access denied, in use). Check the log for details." }
        if ($exitCode -band 16) { $bitsHit += 16; $bitLabels += "fatal error";         $explanation += "[+16] Serious error - robocopy did not copy any files. Usually invalid command line or insufficient access to source/destination." }

        # Headline: explain WHY the exit code is the number it is.
        if ($exitCode -eq 0) {
            $txtStatus.AppendText("What exit code 0 means: nothing was copied because source and destination are already in sync. No errors, no changes needed.`r`n`r`n")
        } elseif ($exitCode -lt 0) {
            $txtStatus.AppendText("What exit code $exitCode means: robocopy did not run or exited abnormally. Check that source and destination paths are valid.`r`n`r`n")
            $explanation += "Robocopy did not run, or exited abnormally. Check that the source and destination paths are valid."
        } elseif ($bitsHit.Count -eq 1) {
            # Single bit set - just one thing happened.
            $txtStatus.AppendText("What exit code $exitCode means: $($bitLabels[0]).`r`n`r`n")
        } else {
            # Multiple bits OR'd together - show the math so the user sees
            # WHY 1+2 = 3, why 8+16 = 24, etc.
            $sum = ($bitsHit -join " + ")
            $labels = ($bitLabels -join " + ")
            $txtStatus.AppendText("What exit code $exitCode means: $sum = $exitCode  (i.e. $labels).`r`n")
            $txtStatus.AppendText("Robocopy adds the bit values of every condition that occurred. Breakdown:`r`n`r`n")
        }

        if ($explanation.Count -gt 0) {
            foreach ($line in $explanation) { $txtStatus.AppendText("  - $line`r`n") }
            $txtStatus.AppendText("`r`n")
        }
        if ($userLogFile) { $txtStatus.AppendText("Full log saved to: $userLogFile`r`n`r`n") }

        if ($exitCode -ge 0 -and $exitCode -le 7) {
            $txtStatus.AppendText("Overall: SUCCESS (or success with informational notes).")
            $lblProgress.Text = "Completed (exit $exitCode) - $totalElapsed"
            $lblProgress.ForeColor = $script:t.Success
        } elseif ($exitCode -ge 8) {
            $txtStatus.AppendText("Overall: FAILURE - one or more errors occurred. Review the explanation above and the log.")
            $lblProgress.Text = "Failed (exit $exitCode)"
            $lblProgress.ForeColor = $script:t.Danger
        } else {
            $txtStatus.AppendText("Overall: ROBOCOPY DID NOT COMPLETE. Verify your paths and try again.")
            $lblProgress.Text = "Failed (exit $exitCode)"
            $lblProgress.ForeColor = $script:t.Danger
        }
        $txtStatus.SelectionStart = $txtStatus.Text.Length
        $txtStatus.ScrollToCaret()

        $btnCopy.Enabled = $true
        Set-ButtonClearMode
    }

    # Format an argument array as a single command-line string suitable for
    # display or pasting into cmd.exe. Quotes paths consistently:
    # - Source / dest / non-switch args: always wrapped in quotes (the first
    #   two positional args).
    # - /LOG+:path, /UNILOG:path, /LOG:path: path portion wrapped in quotes,
    #   the switch prefix is left alone.
    # - Plain switches like /E, /MT:18, /COPY:DAT: not quoted.
    # The result matches what a person would type by hand on the cmd line.
    # ----------------------------------------------------------------------
    # Get-RobocopyFlagsFromUI
    # ----------------------------------------------------------------------
    # Single source of truth for translating the UI radio/checkbox state into
    # robocopy flag values. Both Execute-Copy (which actually runs robocopy)
    # and Generate-Command (which builds the clipboard string) call this so
    # they cannot drift apart.
    #
    # Returns a hashtable with these keys:
    #   CopyFlags    - "D" / "DAT" / "DATS" / "DATSO" (no leading /COPY:)
    #   RecurseFlag  - "/E" or "/MIR"
    #   MtFlag       - "/MT:18" / "/MT:9" / "/MT:4" (always set since one
    #                  Performance radio is always checked)
    # ----------------------------------------------------------------------
    function Get-RobocopyFlagsFromUI {
        # /COPY:flags preset. The four radios are mutually exclusive and one
        # is always checked by default, but we include an "else" fallback to
        # DAT just in case something pathological happens (e.g. all unchecked
        # via Tab + Space keyboard interaction we didn't anticipate).
        $cf = if ($radioCopyMinimal.Checked)  { "D" }
              elseif ($radioCopyStandard.Checked) { "DAT" }
              elseif ($radioCopySecure.Checked)   { "DATS" }
              elseif ($radioCopyFull.Checked)     { "DATSO" }
              else { "DAT" }

        # Recursion mode. /E = standard (keep extras), /MIR = mirror (delete
        # extras in destination that are not in source).
        $rf = if ($radioModeMirror.Checked) { "/MIR" } else { "/E" }

        # Multi-thread count. Same fallback story as $cf.
        $mt = if ($radioPerformance.Checked)       { "/MT:18" }
              elseif ($radioRestricted.Checked)    { "/MT:9" }
              elseif ($radioSuperRestricted.Checked) { "/MT:4" }
              else { "/MT:18" }

        return @{ CopyFlags = $cf; RecurseFlag = $rf; MtFlag = $mt }
    }

    # ----------------------------------------------------------------------
    # Format-RobocopyCommand
    # ----------------------------------------------------------------------
    # Format an argument array as a single command-line string suitable for
    # display in the status log or pasting into cmd.exe. Quoting rules:
    #   - First two positional args (source, destination): ALWAYS wrapped in
    #     quotes for consistency, even if they have no whitespace.
    #   - /LOG, /LOG+, /UNILOG, /UNILOG+: path portion after the colon is
    #     wrapped in quotes; the switch prefix is left bare. This matches
    #     what someone would type by hand on the command line.
    #   - Anything else containing whitespace: whole token wrapped in quotes.
    #   - Plain switches like /E, /MT:18, /COPY:DAT: not quoted.
    # ----------------------------------------------------------------------
    function Format-RobocopyCommand {
        param([string[]]$ArgList)
        $parts = @("robocopy")
        for ($i = 0; $i -lt $ArgList.Count; $i++) {
            $a = $ArgList[$i]
            if ($i -lt 2) {
                # First two positional args are source and destination - always quote.
                $parts += "`"$a`""
            } elseif ($a -match '^(/(LOG\+?|UNILOG\+?)):(.+)$') {
                # /LOG, /LOG+, /UNILOG, /UNILOG+ - quote the path part only.
                $parts += "$($matches[1]):`"$($matches[3])`""
            } elseif ($a -match '\s') {
                # Anything else with whitespace: quote whole thing.
                $parts += "`"$a`""
            } else {
                $parts += $a
            }
        }
        return $parts -join " "
    }

    # ----------------------------------------------------------------------
    # Generate-Command
    # ----------------------------------------------------------------------
    # Builds the display string for the "Copy Command to Clipboard" button.
    # Intentionally omits /NP and /NDL (which Execute-Copy includes for
    # cleaner internal output) because a user pasting this into cmd probably
    # wants robocopy's full default progress and directory listing output.
    # Intentionally omits /UNILOG: because that's an internal artifact path
    # only relevant when RhinoCopy itself is driving the run.
    # ----------------------------------------------------------------------
    function Generate-Command {
        $f = Get-RobocopyFlagsFromUI
        $rcArgs = @($txtSource.Text, $txtDest.Text, "*.*",
                    "/COPY:$($f.CopyFlags)", "/DCOPY:$($f.CopyFlags)",
                    $f.RecurseFlag, "/XJ", "/W:1", "/R:10", $f.MtFlag)
        if ($chkLog.Checked) {
            $logFile = Join-Path $txtDest.Text "RhinoCopy_Log_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
            $rcArgs += "/LOG+:$logFile"
        }
        if ($chkDryRun.Checked) { $rcArgs += "/L" }
        return Format-RobocopyCommand -ArgList $rcArgs
    }

    # Show-FlagReference: spawns a child form listing every Robocopy flag with
    # an explanation. Themed to match the parent. Read-only TextBox in mono
    # font so the columns line up cleanly. Closes when the user dismisses it.
    function Show-FlagReference {
        $ref = New-Object System.Windows.Forms.Form
        $ref.Text = "Robocopy Flag Reference"
        $ref.Size = New-Object System.Drawing.Size(900,720)
        $ref.StartPosition = "CenterParent"
        $ref.MinimizeBox = $false
        $ref.MaximizeBox = $true
        $ref.BackColor = $script:t.Bg
        $ref.ForeColor = $script:t.Text
        if (Test-Path $iconPath) { try { $ref.Icon = New-Object System.Drawing.Icon($iconPath) } catch { } }

        $tb = New-Object System.Windows.Forms.TextBox
        $tb.Multiline = $true
        $tb.ScrollBars = "Vertical"
        $tb.ReadOnly = $true
        $tb.Font = $fontMono
        $tb.BackColor = $script:t.Surface
        $tb.ForeColor = $script:t.Text
        $tb.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
        $tb.Location = New-Object System.Drawing.Point(10,10)
        $tb.Size = New-Object System.Drawing.Size(870,640)
        $tb.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
        $refText = @"
ROBOCOPY FLAG REFERENCE

COPY OPTIONS
  /S            Copy subdirectories, skipping empty ones.
  /E            Copy subdirectories including empty ones.
  /LEV:n        Copy only the top n levels of the source tree.
  /Z            Copy in restartable mode (resumable on network blip).
  /B            Copy in Backup mode (uses backup privilege; ignores ACLs).
  /ZB           Use restartable mode; if access denied, fall back to Backup.
  /COPY:flags   What to copy. flags = combination of:
                  D = Data
                  A = Attributes (read-only, hidden, etc.)
                  T = Timestamps
                  S = Security (NTFS ACLs)
                  O = Owner info
                  U = aUditing info
                Default is /COPY:DAT.
  /DCOPY:flags  Same flag set, but applied to directories. Default DA.
  /COPYALL      Equivalent to /COPY:DATSOU. Copies everything.
  /NOCOPY       Copy nothing (useful with /PURGE to just delete extras).
  /SECFIX       Fix file security on all files, even skipped ones.
  /TIMFIX       Fix file times on all files, even skipped ones.

PURGE / MIRROR
  /PURGE        Delete dest files and folders that no longer exist in source.
  /MIR          Mirror tree. Equivalent to /E plus /PURGE.
                WARNING: deletes destination files not in source.
  /MOVE         Move files and folders (delete from source after copying).
  /MOV          Move files only (not folders).

FILE SELECTION
  /A            Copy only files with the Archive attribute set.
  /M            Copy only files with the Archive attribute set, then clear it.
  /IA:flags     Include only files with any of the given attributes set.
  /XA:flags     Exclude files with any of the given attributes set.
                Attributes: R=ReadOnly H=Hidden S=System A=Archive
                            C=Compressed N=NotIndexed E=Encrypted T=Temp O=Offline
  /XF file...   Exclude files matching the given names/paths/wildcards.
  /XD dir...    Exclude directories matching the given names/paths.
  /XC           Exclude Changed files.
  /XN           Exclude Newer files.
  /XO           Exclude Older files.
  /XX           Exclude eXtra files and directories (present in dest, not source).
  /XL           Exclude Lonely files and directories (present in source, not dest).
  /XJ           Exclude all Junction points (and symbolic links). RECOMMENDED for
                user profile / system drive copies - Windows uses junctions like
                C:\Users\X\AppData\Local\Application Data that self-reference and
                cause infinite recursion. Default is to follow them.
  /XJD          Exclude Junction points for Directories only.
  /XJF          Exclude Junction points for Files only (symbolic file links).
  /SJ           Process Junction points as if they were normal directories
                (default behaviour - included for documentation).
  /SL           Copy symbolic Links versus the targets they point at.
  /IS           Include Same files (overwrites identical files - use to refresh).
  /IT           Include Tweaked files (changed attributes only, no content change).
  /MAX:n        Only copy files up to n bytes.
  /MIN:n        Only copy files at least n bytes.
  /MAXAGE:n     Maximum file age (days, or YYYYMMDD) - exclude files older.
  /MINAGE:n     Minimum file age - exclude files newer.
  /MAXLAD:n     Max last-access date - exclude files unused since then.
  /MINLAD:n     Min last-access date - exclude files used since then.

SPECIAL CONTENT
  /CREATE       Create the directory tree and zero-length placeholder files
                only. Useful for previewing what would be copied without
                touching actual content.
  /FAT          Create destination files in 8.3 FAT name format (truncates).
  /256          Turn off long-path (>256 char) support. Use only on filesystems
                that genuinely cannot handle long paths.
  /EFSRAW       Copy encrypted files in EFS raw mode. Without this, copying
                an EFS-encrypted file to a non-NTFS destination fails.
  /DST          Compensate for one-hour DST timestamp differences (legacy).

RETRY OPTIONS
  /R:n          Number of retries on failed copies. Default is 1 million.
  /W:n          Wait time between retries (seconds). Default 30.
  /REG          Save /R and /W as defaults in the registry.
  /TBD          Wait for share names to be defined (retry error 67).

LOGGING
  /L            List only - don't copy, timestamp, or delete anything (dry run).
  /X            Report all eXtra files, not just the ones being selected.
  /V            Verbose output, showing skipped files.
  /TS           Include source file timestamps in output.
  /FP           Include full pathname of files in output.
  /BYTES        Print sizes as bytes.
  /NS           No size info.
  /NC           No file class info.
  /NFL          No file list.
  /NDL          No directory list.
  /NP           No progress percentage shown per file.
  /ETA          Show estimated time of arrival of copied files.
  /LOG:file     Output status to log file (overwrite).
  /LOG+:file    Output status to log file (append).
  /UNILOG:file  Same as /LOG but Unicode encoding.
  /UNILOG+:file Same as /LOG+ but Unicode encoding.
  /TEE          Output to console window AND log file.
  /NJH          No job header.
  /NJS          No job summary.

PERFORMANCE
  /MT[:n]       Multi-threaded with n threads (default 8, max 128).
                RhinoCopy uses 18 / 9 / 4 depending on Performance Mode.
  /IPG:n        Inter-packet gap (ms) between packets - throttles network use.
  /J            Copy using unbuffered I/O. Recommended for large files.
  /NOOFFLOAD    Disable Windows offload copy mechanism.
  /COMPRESS     Request SMB-compressed network transfer (Windows 11/Server 2022+).

EXIT CODES (bit flags - reported value is OR of these)
  0   No files copied. Source and destination already in sync.
  1   One or more files copied successfully.
  2   Extra files or folders detected in destination.
  4   Mismatched files or folders detected.
  8   Some files or folders could not be copied (errors).
  16  Serious error - robocopy did not copy any files.

  So an exit code of 3 means files were copied (1) AND extras were detected (2).
  Anything 0-7 = OK or informational. 8+ = real failure.

For full official documentation:
  https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/robocopy
"@
        # WinForms multiline TextBox requires CRLF for line breaks - LF alone
        # renders as a single line. Force CRLF regardless of how the host
        # PowerShell saved the file.
        $tb.Text = $refText -replace "`r?`n", "`r`n"
        $ref.Controls.Add($tb)

        $btnClose = New-Object System.Windows.Forms.Button
        $btnClose.Text = "Close"
        $btnClose.Size = New-Object System.Drawing.Size(100,30)
        $btnClose.Location = New-Object System.Drawing.Point(780,660)
        $btnClose.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
        Apply-ButtonTheme -Button $btnClose -Role "btn-neutral"
        $btnClose.Add_Click({ $ref.Close() })
        $ref.Controls.Add($btnClose)
        $ref.AcceptButton = $btnClose
        $ref.CancelButton = $btnClose

        # When the form first shows, WinForms auto-selects the entire TextBox
        # content because it gets initial focus. Counter this on the Shown
        # event: focus the Close button instead, and reset the TextBox
        # selection to position 0 with zero length so nothing is highlighted.
        $ref.Add_Shown({
            try {
                $btnClose.Focus() | Out-Null
                $tb.SelectionStart = 0
                $tb.SelectionLength = 0
                $tb.ScrollToCaret()
            } catch { }
        })

        $ref.ShowDialog($form) | Out-Null
        $ref.Dispose()
    }


    # --------------------------------------------------------------------
    # SECTION 5h - ShowDialog: the modal blocking call
    # --------------------------------------------------------------------
    # ShowDialog() runs the WinForms message loop and BLOCKS until the
    # form is closed. While it blocks, all UI interaction happens via the
    # event handlers we wired up above. When the user closes the form,
    # ShowDialog returns and we fall through to the end of the try block.
    # Out-Null suppresses the DialogResult return value which we don't use.
    $form.ShowDialog() | Out-Null

} catch {
    # ========================================================================
    # SECTION 6 - Outer catch: startup crash log
    # ========================================================================
    # Any uncaught error during form construction (Section 5) lands here.
    # This is essentially a last-resort safety net for unexpected failures
    # like missing .NET assemblies, broken icon files that throw on load,
    # or anything else exotic.
    #
    # Order matters: we write to the temp log file FIRST and the
    # MessageBox SECOND, because:
    #   - If WinForms itself is broken (e.g. SetCompatibleTextRenderingDefault
    #     blew up), the MessageBox call will also throw, and the log file
    #     is then the only diagnostic trail left behind.
    #   - When launched with -WindowStyle Hidden via the desktop shortcut,
    #     there is no console output anyway, so the log is the only way
    #     to find out why nothing happened.
    # Both calls are wrapped in their own try/catch so one failing doesn't
    # prevent the other from running.
    $errMsg = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] RhinoCopy startup error: $($_ | Out-String)"
    try { Add-Content -Path $crashLog -Value $errMsg -Encoding UTF8 } catch { }
    try { [System.Windows.Forms.MessageBox]::Show("An error occurred: $_`r`n`r`nDetails logged to:`r`n$crashLog", "RhinoCopy Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null } catch { }
}
