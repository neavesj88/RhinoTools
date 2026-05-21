Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Create Form
$form = New-Object System.Windows.Forms.Form
$form.Text = "Stomp-a-Bug with Rhino!"
$form.Size = New-Object System.Drawing.Size(600, 500)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"

# Rhino Image Path
$rhinoImagePath = "C:\Scripts\RhinoStomp\Rhino.png"

# Rhino Image
$rhinoBox = New-Object System.Windows.Forms.PictureBox
$rhinoBox.Size = New-Object System.Drawing.Size(100, 110)
$rhinoBox.Location = New-Object System.Drawing.Point(225, 320)
$rhinoBox.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::StretchImage

if (Test-Path $rhinoImagePath) {
    $rhinoBox.Image = [System.Drawing.Image]::FromFile($rhinoImagePath)
} else {
    $rhinoBox.BackColor = [System.Drawing.Color]::Gray
}

$form.Controls.Add($rhinoBox)

# Label for Rhino's Comments
$commentLabel = New-Object System.Windows.Forms.Label
$commentLabel.Size = New-Object System.Drawing.Size(560, 40)
$commentLabel.Location = New-Object System.Drawing.Point(20, 10)
$commentLabel.Font = New-Object System.Drawing.Font("Arial", 10, [System.Drawing.FontStyle]::Bold)
$commentLabel.TextAlign = "MiddleCenter"
$form.Controls.Add($commentLabel)

# Bug Image Path
$bugImagePath = "C:\Scripts\RhinoStomp\foc_logo_circle_blue.png"

# Bug Image
$bugBox = New-Object System.Windows.Forms.PictureBox
$bugBox.Size = New-Object System.Drawing.Size(40, 50) 
$bugBox.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::StretchImage

if (Test-Path $bugImagePath) {
    $bugBox.Image = [System.Drawing.Image]::FromFile($bugImagePath)
} else {
    $bugBox.BackColor = [System.Drawing.Color]::Red
}

$form.Controls.Add($bugBox)

# Score Counter Label
$scoreLabel = New-Object System.Windows.Forms.Label
$scoreLabel.Text = "Bugs Squashed: 0"
$scoreLabel.Size = New-Object System.Drawing.Size(200, 20)
$scoreLabel.Location = New-Object System.Drawing.Point(20, 55)
$scoreLabel.Font = New-Object System.Drawing.Font("Arial", 12, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($scoreLabel)

# Reset Button
$resetButton = New-Object System.Windows.Forms.Button
$resetButton.Text = "Reset"
$resetButton.Size = New-Object System.Drawing.Size(80, 30)
$resetButton.Location = New-Object System.Drawing.Point(500, 55)
$form.Controls.Add($resetButton)


$rhinoCommentsMiss = @(
    "That bug's got reflexes! Try harder!",
    "You call that a hit? Pathetic!",
    "Nice try! But that bug's faster than your internet!",
    "Did you even aim?!",
    "You whiffed it! Maybe try glasses?",
    "Hit the bug, not your self-esteem!",
    "That bug’s mocking you right now.",
    "You missed? Wow, I’m not surprised.",
    "You missed? Again? Just stop.",
    "SFC /scannow won’t fix your aim, but I’m recommending it anyway.",
    "This is getting sad. Hit detection is fine, you’re the problem.",
    "The bug dodged that like Neo in The Matrix. You? Not even close.",
    "Your mouse isn’t broken. Just your coordination.",
    "Your ancestors are watching this… and they’re disappointed.",
    "Even a blindfolded sloth would have hit that.",
    "Every time you miss, an IT guy facepalms somewhere in the world.",
    "At this point, the bug should be playing instead of you.",
    "I’d call it unlucky, but we both know that’s not it.",
    "Might as well uninstall PowerShell while you're at it.",
    "Keep missing like that and I’m installing Clippy to help you.",
    "Did you just try to hit it with an empty click? Good strategy.",
    "Even Windows 95 had better responsiveness than your reflexes.",
    "That bug’s winning. Embarrassing.",
    "Are you lagging? Oh wait… you’re just slow.",
    "Are you even playing? It’s like you’re throwing on purpose.",
    "Every miss adds 10 years to my suffering.",
    "Maybe the bug is dodging, or maybe you’re just terrible.",
    "At this point, I should give the bug a name. It’s family now.",
    "The bug has outlived Windows XP. Maybe let it stay?",
    "If your mouse had feelings, it would be crying right now.",
    "This isn’t just bad. This is a new level of awful.",
    "You’re missing so much I should rename this game ‘Whiff-a-Bug’.",
    "That bug is writing a memoir about how bad you are.",
    "Do you need a tutorial? Maybe an aim bot?",
    "Are you playing on inverted controls or just *this* bad?",
    "Even a potato has better accuracy than this.",
    "I could teach a goldfish to aim better than you.",
    "That bug is about to file a workplace safety complaint.",
    "NASA just called. They want to study your aiming failures.",
    "Even your shadow is disappointed in you right now.",
    "Would you like to lower the difficulty to ‘Baby Mode’?",
    "The bug isn’t even trying, and you still missed.",
    "Windows Update is faster than your reflexes.",
    "Maybe reinstalling Windows will fix your aim?",
    "I hope you don’t play FPS games, for your sake.",
    "You must be playing with a trackpad. Please say you are.",
    "If missing was a sport, you’d be the world champion."
)

$rhinoCommentsHit = @(
    "BOOM! Bug down!",
    "Finally, a hit! Took you long enough.",
    "Nice job! That bug never saw it coming.",
    "Okay, that was actually impressive.",
    "You got it! Maybe you’re not hopeless.",
    "One down, a million more to go.",
    "That was pure skill. Or luck. Probably luck.",
    "You actually hit it?! I need a moment...",
    "Confirmed: You are a bug-swatting legend.",
    "If you keep this up, we might win this war.",
    "Finally, some competence. Keep going.",
    "One step closer to reclaiming this land!",
    "Now we’re talking! Show them who’s boss!",
    "That bug had a family… not anymore.",
    "Your ancestors are slightly less ashamed now.",
    "Maybe there’s hope for you after all.",
    "Whoa. You hit it. Are you feeling okay?",
    "First hit! Don’t get cocky, it was luck.",
    "Wow, you actually clicked where you aimed!",
    "The bug’s friends are watching… and they’re scared now.",
    "You swatted that bug back to Windows 98.",
    "I felt that hit from here! Brutal!",
    "Someone’s finally waking up! Keep going!",
    "That’s one less bug. A million more to go.",
    "Nice hit! Maybe try doing it on purpose next time.",
    "You got it! See? Clicking *does* work!",
    "I take back 10% of the insults I’ve given you.",
    "If you get another one, I’ll consider respecting you.",
    "A win? I don’t know how to process this...",
    "SFC /scannow can’t save that bug now.",
    "Hey, you actually hit something! Proud of you.",
    "Wow, a functioning human being! Who knew?",
    "I was about to quit on you. Guess I’ll stay.",
    "I’ll admit, I was *not* expecting that.",
    "If you hit another one, I’ll actually be impressed.",
    "That bug never stood a chance. Brutal.",
    "Windows Defender wishes it was this effective.",
    "Holy cow, you’re actually playing the game!",
    "That was cleaner than a fresh Windows install.",
    "Not bad, but can you do it twice in a row?",
    "I blinked, and you actually got one? Amazing.",
    "You might just make me respect you. Maybe.",
    "You’re improving. Slowly. But it’s happening.",
    "Maybe you’re not a lost cause after all.",
    "That bug just rage-quit life.",
    "That was cold. I like it.",
    "I think I just saw the bug's soul leave its body.",
    "Are you using aimbot? No way you actually hit it.",
    "One bug closer to total annihilation.",
    "That was satisfying. Do it again."
)

# Score Counter
$script:score = 0

# Speed Settings
$baseInterval = 2000 
$minInterval = 500  

# Stopwatch to track elapsed time
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# Move the Bug to a New Location
function Move-Bug {
    $safeZone = 90
    do {
        $newX = Get-Random -Minimum 10 -Maximum ($form.ClientSize.Width - $bugBox.Width - 10)
        $newY = Get-Random -Minimum 50 -Maximum ($form.ClientSize.Height - $bugBox.Height - 150)
    } until (
        ($newX -lt $rhinoBox.Location.X - $safeZone -or $newX -gt $rhinoBox.Location.X + $rhinoBox.Width + $safeZone) -or
        ($newY -lt $rhinoBox.Location.Y - $safeZone -or $newY -gt $rhinoBox.Location.Y + $rhinoBox.Height + $safeZone)
    )

    $bugBox.Location = New-Object System.Drawing.Point($newX, $newY)
}

# Bug Movement Timer
$bugTimer = New-Object System.Windows.Forms.Timer
$bugTimer.Interval = $baseInterval
$bugTimer.Add_Tick({
    Move-Bug

    # Calculate elapsed time using Stopwatch
    $timeElapsed = $stopwatch.Elapsed.TotalSeconds

    # Adjust speed based on elapsed time
    if ($timeElapsed -ge 30 -and $timeElapsed -lt 60) {
        $bugTimer.Interval = 1500
    } elseif ($timeElapsed -ge 60 -and $timeElapsed -lt 90) {
        $bugTimer.Interval = 1200
    } elseif ($timeElapsed -ge 90) {
        $bugTimer.Interval = [Math]::Max($bugTimer.Interval - 100, $minInterval)
    }

    Write-Host "Time Elapsed: $timeElapsed seconds, Interval: $($bugTimer.Interval)ms"
})

# Click Detection
$bugBox.Add_MouseDown({
    $script:score++  
    $scoreLabel.Text = "Bugs Squashed: $script:score"
    $commentLabel.Text = $rhinoCommentsHit | Get-Random
    Write-Host "Bug clicked! Score: $script:score" 
    Move-Bug
})

# Form Click Misses
$form.Add_MouseDown({
    $mousePos = $form.PointToClient([System.Windows.Forms.Cursor]::Position)
    if (!$bugBox.Bounds.Contains($mousePos)) {
        $commentLabel.Text = $rhinoCommentsMiss | Get-Random
    }
})

# Reset Button Click
$resetButton.Add_Click({
    $script:score = 0 
    $scoreLabel.Text = "Bugs Squashed: 0"
    $stopwatch.Restart()
    $bugTimer.Interval = $baseInterval
    Move-Bug
})

# Start Game after Form Loads
$form.Add_Load({
    Move-Bug
    $bugTimer.Start()
    Write-Host "Form loaded and game started!"
})

# Show Form
$form.ShowDialog()
