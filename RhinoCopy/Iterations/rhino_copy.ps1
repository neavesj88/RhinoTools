<#
================================================================================
  RhinoCopy v1.69 - Robocopy front-end with dark/light themes
================================================================================

.SYNOPSIS
    A GUI-based file copying tool using Robocopy.

.DESCRIPTION
    Polished WinForms GUI wrapping Robocopy. Features:
    - Source/destination selection with browse dialogs.
    - Performance modes (MT:18 / MT:9 / MT:4).
    - Copy flag presets (Data / Attributes / Timestamps / Security / Owner).
    - Optional dry run and log file output.
    - Live progress and status log tailing.
    - Clickable Rhino mascot easter egg.
    - Runtime light/dark theme toggle (defaults to dark).

.AUTHOR
    Jared Neaves with a little help from Grock.

.CODE STRUCTURE
    1. Assembly imports
    2. Theme palettes + fonts
    3. Theme helpers (register/apply)
    4. Script state + path resolution
    5. Form build (inside try block):
        5a. Form shell + FormClosing
        5b. Header panel + mascot + progress + theme toggle
        5c. Path inputs
        5d. Option group boxes
        5e. Checkboxes + status log
        5f. Action buttons
        5g. Functions (Execute-Copy, Generate-Command)
        5h. ShowDialog
    6. Startup crash catch
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
$script:currentTheme = "dark"   # default theme on launch
$script:t = $script:themes[$script:currentTheme]   # active-theme shortcut

$fontRegular  = New-Object System.Drawing.Font("Segoe UI", 10)
$fontSemibold = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
$fontTitle    = New-Object System.Drawing.Font("Segoe UI Semibold", 18)
$fontHeader   = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
$fontMono     = New-Object System.Drawing.Font("Consolas", 9.5)


# ==============================================================================
# SECTION 3 - Theme helpers
# ==============================================================================
# Pattern: every themeable control is tagged with a semantic role when it's
# created. Apply-Theme walks the list and repaints based on current palette.
# This is the mechanism that makes the dark/light toggle work at runtime.

$script:themedControls = @()

function Register-Themed {
    param($Control, [string]$Role)
    # Use += which reassigns the array - doesn't emit to pipeline.
    $script:themedControls += @{ Control = $Control; Role = $Role }
}

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

# Walks all registered controls and applies the active palette. Wrapped in
# try/catch per control so one bad control doesn't kill the whole repaint.
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
    if ($headerPanel) { try { $headerPanel.Invalidate() } catch { } }
}


# ==============================================================================
# SECTION 4 - Script state + path resolution
# ==============================================================================
$script:process = $null
$script:isClosing = $false

# Path resolution with fallbacks for various launch contexts.
$scriptPath = if ($PSScriptRoot) { $PSScriptRoot }
              elseif ($PSCommandPath) { Split-Path -Parent $PSCommandPath }
              elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path }
              else { (Get-Location).Path }
$iconPath = Join-Path $scriptPath "rhino_copy.ico"

# Crash log - essential for diagnosing -WindowStyle Hidden launch failures
# where no console output is visible.
$crashLog = Join-Path $env:TEMP "RhinoCopy_crash.log"


# ==============================================================================
# SECTION 5 - Form build (inside try block)
# ==============================================================================
try {

    # --- 5a. Form shell + FormClosing ---------------------------------------
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "RhinoCopy v1.69"
    $form.MinimumSize = New-Object System.Drawing.Size(1000,790)
    $form.Size = New-Object System.Drawing.Size(1100,810)
    $form.StartPosition = "CenterScreen"
    $form.MaximizeBox = $true
    $form.FormBorderStyle = 'Sizable'
    $form.Font = $fontRegular
    $form.AutoScaleMode = 'Font'
    $form.Padding = New-Object System.Windows.Forms.Padding(6)
    # Set form colours from the active theme so dark mode is visible on load.
    # Without this the form body would render in default Windows grey while
    # the panels and controls inside it are dark.
    $form.BackColor = $script:t.Bg
    $form.ForeColor = $script:t.Text
    # FormClosing handler. Since robocopy runs synchronously now, the form
    # can only be closed when no copy is in progress (the UI is blocked
    # during a copy), so this is just a safe no-op.
    $form.Add_FormClosing({
        param($sender, $e)
        $script:isClosing = $true
    })

    if (Test-Path $iconPath) { try { $form.Icon = New-Object System.Drawing.Icon($iconPath) } catch { } }


    # --- 5b. Header panel ---------------------------------------------------
    # Panel acts as a card containing mascot, title, progress, theme toggle.
    # Custom-paint border reads $script:t at paint time so it re-colours on
    # theme switch automatically via Invalidate().
    $headerPanel = New-Object System.Windows.Forms.Panel
    $headerPanel.Location = New-Object System.Drawing.Point(10,10)
    $headerPanel.Size = New-Object System.Drawing.Size(1070,84)
    $headerPanel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $headerPanel.BackColor = $script:t.Surface
    $headerPanel.Add_Paint({
        param($s, $e)
        $pen = New-Object System.Drawing.Pen($script:t.Border, 1)
        $e.Graphics.DrawRectangle($pen, 0, 0, $s.Width - 1, $s.Height - 1)
        $pen.Dispose()
    })
    Register-Themed -Control $headerPanel -Role "surface"
    $form.Controls.Add($headerPanel)

    $pictureBox = New-Object System.Windows.Forms.PictureBox
    $pictureBox.Location = New-Object System.Drawing.Point(10,5)
    $pictureBox.Size = New-Object System.Drawing.Size(60,60)
    $pictureBox.SizeMode = "StretchImage"
    $pictureBox.Cursor = [System.Windows.Forms.Cursors]::Hand
    $pictureBox.BackColor = $script:t.Surface
    Register-Themed -Control $pictureBox -Role "surface"
    if (Test-Path $iconPath) { try { $pictureBox.Image = [System.Drawing.Image]::FromFile($iconPath) } catch { } }

    # Mascot click-count easter egg: 1-10 friendly, 11-20 irritated, 21+ retired.
    # Any real interaction (browse, copy, radio change) resets the counter.
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
    $pictureBox.Add_Click({
        $script:clickCount++
        $newMessage = ""
        if ($script:clickCount -le 10) { do { $newMessage = $friendlyMessages | Get-Random } while ($newMessage -eq $script:lastMessage -and $friendlyMessages.Count -gt 1) }
        elseif ($script:clickCount -le 20) { do { $newMessage = $irritatedMessages | Get-Random } while ($newMessage -eq $script:lastMessage -and $irritatedMessages.Count -gt 1) }
        else { do { $newMessage = $blanketStatements | Get-Random } while ($newMessage -eq $script:lastMessage -and $blanketStatements.Count -gt 1) }
        $script:lastMessage = $newMessage
        $txtStatus.Text = "Secret Rhino Message: " + $newMessage
    })
    $headerPanel.Controls.Add($pictureBox)

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

    # Status label - changes colour per state (muted/accent/success/danger).
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

    $progressBar = New-Object System.Windows.Forms.ProgressBar
    $progressBar.Location = New-Object System.Drawing.Point(350,34)
    $progressBar.Size = New-Object System.Drawing.Size(580,16)
    $progressBar.Style = "Continuous"
    $progressBar.ForeColor = $script:t.Accent
    $progressBar.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    Register-Themed -Control $progressBar -Role "progressbar"
    $headerPanel.Controls.Add($progressBar)

    # --- Header buttons (flag reference + theme toggle, stacked vertically) ---
    # Flag reference: opens a popup with every robocopy flag explained.
    $btnFlags = New-Object System.Windows.Forms.Button
    $btnFlags.Location = New-Object System.Drawing.Point(945,10)
    $btnFlags.Size = New-Object System.Drawing.Size(115,30)
    $btnFlags.Text = "Flag Reference"
    $btnFlags.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
    Apply-ButtonTheme -Button $btnFlags -Role "btn-neutral"
    Register-Themed -Control $btnFlags -Role "btn-neutral"
    $btnFlags.Add_Click({ Show-FlagReference; $script:clickCount = 0 })
    $headerPanel.Controls.Add($btnFlags)

    # Theme toggle: flips dark/light and repaints all registered controls.
    # Label shows the *target* theme (what happens if you click).
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


    # --- 5c. Path input rows ------------------------------------------------
    $lblSource = New-Object System.Windows.Forms.Label
    $lblSource.Text = "Source"
    $lblSource.Location = New-Object System.Drawing.Point(10,100)
    $lblSource.Size = New-Object System.Drawing.Size(110,22)
    $lblSource.Font = $fontHeader
    $lblSource.BackColor = $script:t.Bg
    $lblSource.ForeColor = $script:t.Text
    Register-Themed -Control $lblSource -Role "label-body"
    $form.Controls.Add($lblSource)

    $txtSource = New-Object System.Windows.Forms.TextBox
    $txtSource.Location = New-Object System.Drawing.Point(125,98)
    $txtSource.Size = New-Object System.Drawing.Size(845,26)
    $txtSource.Font = $fontRegular
    $txtSource.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $txtSource.BackColor = $script:t.Surface
    $txtSource.ForeColor = $script:t.Text
    $txtSource.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    Register-Themed -Control $txtSource -Role "input"
    $form.Controls.Add($txtSource)

    $btnSource = New-Object System.Windows.Forms.Button
    $btnSource.Location = New-Object System.Drawing.Point(980,96)
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

    $lblDest = New-Object System.Windows.Forms.Label
    $lblDest.Text = "Destination"
    $lblDest.Location = New-Object System.Drawing.Point(10,138)
    $lblDest.Size = New-Object System.Drawing.Size(110,22)
    $lblDest.Font = $fontHeader
    $lblDest.BackColor = $script:t.Bg
    $lblDest.ForeColor = $script:t.Text
    Register-Themed -Control $lblDest -Role "label-body"
    $form.Controls.Add($lblDest)

    $txtDest = New-Object System.Windows.Forms.TextBox
    $txtDest.Location = New-Object System.Drawing.Point(125,136)
    $txtDest.Size = New-Object System.Drawing.Size(845,26)
    $txtDest.Font = $fontRegular
    $txtDest.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $txtDest.BackColor = $script:t.Surface
    $txtDest.ForeColor = $script:t.Text
    $txtDest.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    Register-Themed -Control $txtDest -Role "input"
    $form.Controls.Add($txtDest)

    $btnDest = New-Object System.Windows.Forms.Button
    $btnDest.Location = New-Object System.Drawing.Point(980,134)
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


    # --- 5d. Option group boxes ---------------------------------------------

    # Performance Mode: /MT level selection. MT:18 for SSD-to-SSD, MT:9 for
    # mixed, MT:4 for network/constrained boxes where MT:18 causes thrashing.
    $groupBoxPerformance = New-Object System.Windows.Forms.GroupBox
    $groupBoxPerformance.Location = New-Object System.Drawing.Point(10,180)
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
    $groupBoxCopy.Location = New-Object System.Drawing.Point(10,300)
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
    $groupBoxMode.Location = New-Object System.Drawing.Point(10,460)
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


    # --- 5e. Checkboxes + status log ----------------------------------------
    $chkLog = New-Object System.Windows.Forms.CheckBox
    $chkLog.Location = New-Object System.Drawing.Point(14,560)
    $chkLog.Size = New-Object System.Drawing.Size(130,24)
    $chkLog.Text = "Create Log"
    $chkLog.Font = $fontRegular
    $chkLog.BackColor = $script:t.Bg
    $chkLog.ForeColor = $script:t.Text
    $chkLog.Checked = $true
    $chkLog.Add_CheckedChanged({ $script:clickCount = 0 })
    $tooltip.SetToolTip($chkLog, "Save operation details to a log file in the destination folder")
    Register-Themed -Control $chkLog -Role "checkbox"
    $form.Controls.Add($chkLog)

    $chkDryRun = New-Object System.Windows.Forms.CheckBox
    $chkDryRun.Location = New-Object System.Drawing.Point(150,560)
    $chkDryRun.Size = New-Object System.Drawing.Size(130,24)
    $chkDryRun.Text = "Dry Run"
    $chkDryRun.Font = $fontRegular
    $chkDryRun.BackColor = $script:t.Bg
    $chkDryRun.ForeColor = $script:t.Text
    $chkDryRun.Add_CheckedChanged({ $script:clickCount = 0 })
    $tooltip.SetToolTip($chkDryRun, "Test the operation without actually copying files")
    Register-Themed -Control $chkDryRun -Role "checkbox"
    $form.Controls.Add($chkDryRun)

    # Status log - Consolas mono so Robocopy's column-aligned output lines up.
    $txtStatus = New-Object System.Windows.Forms.TextBox
    $txtStatus.Multiline = $true
    $txtStatus.ScrollBars = "Vertical"
    $txtStatus.Location = New-Object System.Drawing.Point(300,180)
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


    # --- 5f. Action buttons -------------------------------------------------

    $btnCopy = New-Object System.Windows.Forms.Button
    $btnCopy.Location = New-Object System.Drawing.Point(20,600)
    $btnCopy.Size = New-Object System.Drawing.Size(260,44)
    $btnCopy.Text = "Copy Files"
    $btnCopy.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
    Apply-ButtonTheme -Button $btnCopy -Role "btn-success"
    Register-Themed -Control $btnCopy -Role "btn-success"
    $btnCopy.Add_Click({
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
            try { $btnCopy.Enabled = $true; $btnCancel.Enabled = $false } catch { }
        }
        $script:clickCount = 0
    })
    $tooltip.SetToolTip($btnCopy, "Start the file copy operation")
    $form.Controls.Add($btnCopy)

    $btnCopyCmd = New-Object System.Windows.Forms.Button
    $btnCopyCmd.Location = New-Object System.Drawing.Point(20,652)
    $btnCopyCmd.Size = New-Object System.Drawing.Size(260,40)
    $btnCopyCmd.Text = "Copy Command to Clipboard"
    $btnCopyCmd.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
    Apply-ButtonTheme -Button $btnCopyCmd -Role "btn-accent"
    Register-Themed -Control $btnCopyCmd -Role "btn-accent"
    $btnCopyCmd.Add_Click({
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

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Location = New-Object System.Drawing.Point(20,700)
    $btnCancel.Size = New-Object System.Drawing.Size(260,40)
    $btnCancel.Text = "Cancel Operation"
    $btnCancel.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
    $btnCancel.Enabled = $false
    Apply-ButtonTheme -Button $btnCancel -Role "btn-danger"
    Register-Themed -Control $btnCancel -Role "btn-danger"
    $btnCancel.Add_Click({
        if ($script:process -ne $null -and -not $script:process.HasExited) {
            $result = [System.Windows.Forms.MessageBox]::Show("Are you sure you want to cancel the copy operation?", "Confirm Cancel", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
            if ($result -eq 'Yes') {
                try { $script:process.Kill() } catch { }
                $txtStatus.AppendText("`r`n`r`nOperation cancelled by user.")
                $btnCancel.Enabled = $false
                $btnCopy.Enabled = $true
                $lblProgress.Text = "Cancelled"
                # Use $script:t.Danger so colour stays theme-appropriate after a switch.
                $lblProgress.ForeColor = $script:t.Danger
            }
        }
    })
    $tooltip.SetToolTip($btnCancel, "Cancel the running copy operation")
    $form.Controls.Add($btnCancel)


    # --- 5g. Functions ------------------------------------------------------

    # Execute-Copy: builds Robocopy args from UI state, spawns process with
    # redirected stdout/stderr, pumps output to log + progress bar live.
    # Uses System.Diagnostics.Process directly (not Start-Process) because
    # we need synchronous access to redirected streams for live tailing.
    function Execute-Copy {
        param([bool]$DryRun)

        $btnCopy.Enabled = $false
        $btnCancel.Enabled = $true
        # Marquee animation - the chevron-style scrolling bar. No real progress
        # info needed (robocopy doesn't reliably emit total %, and a pre-scan
        # is misleadingly slow on big trees). The animation just tells the
        # user "something is happening, the form isn't frozen".
        $progressBar.Style = "Marquee"
        $progressBar.MarqueeAnimationSpeed = 30
        $lblProgress.ForeColor = $script:t.Accent
        $txtStatus.Clear()

        # Build /COPY flag from radio selection. Default to DAT.
        $copyFlags = if ($radioCopyMinimal.Checked) { "D" } elseif ($radioCopyStandard.Checked) { "DAT" } elseif ($radioCopySecure.Checked) { "DATS" } elseif ($radioCopyFull.Checked) { "DATSO" } else { "DAT" }
        $recurseFlag = if ($radioModeMirror.Checked) { "/MIR" } else { "/E" }

        # Build robocopy command and run as a real child process.
        # We do NOT redirect stdout/stderr to PowerShell - robocopy writes
        # to its own log file. This avoids the PowerShell async stream race
        # that previously crashed the host. The user-facing log (when ticked)
        # is also robocopy's own /LOG+ output, written to the destination.
        $progressLog = Join-Path $env:TEMP "RhinoCopy_progress_$([Guid]::NewGuid().ToString('N')).log"
        $rcArgs = @($txtSource.Text, $txtDest.Text, "*.*", "/COPY:$copyFlags", "/DCOPY:$copyFlags", $recurseFlag, "/XJ", "/W:1", "/R:10", "/NP", "/NDL", "/UNILOG:$progressLog")
        if ($radioPerformance.Checked) { $rcArgs += "/MT:18" } elseif ($radioRestricted.Checked) { $rcArgs += "/MT:9" } elseif ($radioSuperRestricted.Checked) { $rcArgs += "/MT:4" }
        # User-facing log (separate from the polling log written to %TEMP%).
        $userLogFile = $null
        if ($chkLog.Checked) {
            $userLogFile = Join-Path $txtDest.Text "RhinoCopy_Log_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
            $rcArgs += "/LOG+:$userLogFile"
        }
        if ($DryRun) { $rcArgs += "/L" }

        # Build the displayed command string. Always quotes paths.
        $command = Format-RobocopyCommand -ArgList $rcArgs
        $txtStatus.AppendText("Running:`r`n$command`r`n`r`nThe form will stay responsive while robocopy runs. The animation below means it is working - not frozen.`r`n")
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
            "Don't quit on me now"
        )

        $animTimer = New-Object System.Windows.Forms.Timer
        $animTimer.Interval = 200
        $animTimer.Add_Tick({
            try {
                $script:animFrame++
                $spin = $spinnerFrames[$script:animFrame % $spinnerFrames.Count]
                $dots = $dotsFrames[$script:animFrame % $dotsFrames.Count]
                # Rotate the verb every ~8 frames (~1.6s) so it has time to read.
                $verb = $verbFrames[[math]::Floor($script:animFrame / 8) % $verbFrames.Count]
                $elapsed = (Get-Date) - $startTime
                $elapsedStr = "{0:mm\:ss}" -f $elapsed
                if ($DryRun) {
                    $lblProgress.Text = "$spin  Dry run: $verb$dots  ($elapsedStr)"
                } else {
                    $lblProgress.Text = "$spin  $verb$dots  ($elapsedStr)"
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
        # Robocopy exit codes are bit flags. Decode them in plain English.
        $explanation = @()
        if ($exitCode -eq 0) { $explanation += "No files were copied. Source and destination are already in sync." }
        if ($exitCode -band 1)  { $explanation += "[+1] Files were copied successfully." }
        if ($exitCode -band 2)  { $explanation += "[+2] Extra files or folders were detected in the destination (not in source). With Mirror mode these were deleted; otherwise they were left untouched." }
        if ($exitCode -band 4)  { $explanation += "[+4] Mismatched files or folders were detected. Examine the log to investigate." }
        if ($exitCode -band 8)  { $explanation += "[+8] Some files or folders could not be copied (e.g. access denied, in use). Check the log for details." }
        if ($exitCode -band 16) { $explanation += "[+16] Serious error - robocopy did not copy any files. Usually invalid command line or insufficient access to source/destination." }
        if ($exitCode -lt 0)    { $explanation += "Robocopy did not run, or exited abnormally. Check that the source and destination paths are valid." }
        $txtStatus.AppendText("What this means:`r`n")
        foreach ($line in $explanation) { $txtStatus.AppendText("  - $line`r`n") }
        $txtStatus.AppendText("`r`n")
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
        $btnCancel.Enabled = $false
    }

    # Format an argument array as a single command-line string suitable for
    # display or pasting into cmd.exe. Quotes paths consistently:
    # - Source / dest / non-switch args: always wrapped in quotes (the first
    #   two positional args).
    # - /LOG+:path, /UNILOG:path, /LOG:path: path portion wrapped in quotes,
    #   the switch prefix is left alone.
    # - Plain switches like /E, /MT:18, /COPY:DAT: not quoted.
    # The result matches what a person would type by hand on the cmd line.
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

    # Generate-Command: display string for clipboard copy. Omits /NP /NDL
    # because a user pasting this into cmd probably wants full output.
    function Generate-Command {
        $copyFlags = if ($radioCopyMinimal.Checked) { "D" } elseif ($radioCopyStandard.Checked) { "DAT" } elseif ($radioCopySecure.Checked) { "DATS" } elseif ($radioCopyFull.Checked) { "DATSO" } else { "DAT" }
        $recurseFlag = if ($radioModeMirror.Checked) { "/MIR" } else { "/E" }
        $rcArgs = @($txtSource.Text, $txtDest.Text, "*.*", "/COPY:$copyFlags", "/DCOPY:$copyFlags", $recurseFlag, "/XJ", "/W:1", "/R:10")
        if ($radioPerformance.Checked) { $rcArgs += "/MT:18" } elseif ($radioRestricted.Checked) { $rcArgs += "/MT:9" } elseif ($radioSuperRestricted.Checked) { $rcArgs += "/MT:4" }
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

        $ref.ShowDialog($form) | Out-Null
        $ref.Dispose()
    }


    # --- 5h. ShowDialog (blocking) ------------------------------------------
    $form.ShowDialog() | Out-Null

} catch {
    # =========================================================================
    # SECTION 6 - Startup crash log
    # =========================================================================
    # Any uncaught error in form build lands here. Write to temp log FIRST -
    # if the form system itself is broken, the MessageBox may also throw and
    # the log is the only diagnostic trail, especially with -WindowStyle Hidden.
    $errMsg = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] RhinoCopy startup error: $($_ | Out-String)"
    try { Add-Content -Path $crashLog -Value $errMsg -Encoding UTF8 } catch { }
    try { [System.Windows.Forms.MessageBox]::Show("An error occurred: $_`r`n`r`nDetails logged to:`r`n$crashLog", "RhinoCopy Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null } catch { }
}
