Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Create Form
$form = New-Object System.Windows.Forms.Form
$form.Text = "Ask Rhino - IT Helpdesk"
$form.Size = New-Object System.Drawing.Size(500, 250)
$form.StartPosition = "CenterScreen"

# Rhino Image
$pictureBox = New-Object System.Windows.Forms.PictureBox
$pictureBox.Size = New-Object System.Drawing.Size(100, 110)
$pictureBox.Location = New-Object System.Drawing.Point(20, 20)
$imagePath = "C:\Scripts\RhinoHelper\RhinoHelper.png"
if (Test-Path $imagePath) {
    $pictureBox.Image = [System.Drawing.Image]::FromFile($imagePath)
} else {
    $pictureBox.BackColor = [System.Drawing.Color]::Gray
}
$pictureBox.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::StretchImage
$form.Controls.Add($pictureBox)

# Label
$label = New-Object System.Windows.Forms.Label
$label.Text = "Describe your IT issue:"
$label.Location = New-Object System.Drawing.Point(140, 20)
$label.AutoSize = $true
$form.Controls.Add($label)

# TextBox
$textBox = New-Object System.Windows.Forms.TextBox
$textBox.Size = New-Object System.Drawing.Size(300, 20)
$textBox.Location = New-Object System.Drawing.Point(140, 50)
$form.Controls.Add($textBox)

# Response Box
$responseBox = New-Object System.Windows.Forms.Label
$responseBox.Size = New-Object System.Drawing.Size(400, 80)
$responseBox.Location = New-Object System.Drawing.Point(50, 120)
$responseBox.AutoSize = $false
$responseBox.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$responseBox.Font = New-Object System.Drawing.Font("Arial", 10, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($responseBox)

# Button
$button = New-Object System.Windows.Forms.Button
$button.Text = "Get Help"
$button.Location = New-Object System.Drawing.Point(365, 80)
$form.Controls.Add($button)

# Empty Input Responses
$emptyInputResponses = @(
    "Oh, I see your keyboard isn’t working. Try yelling 'SFC /scannow' into your microphone."
    "Blank input? Ah, I see you're troubleshooting via telepathy. Let me know how that works out."
    "Nothing to fix? Or did your issue disappear because it feared SFC /scannow?"
    "You're expecting an answer, but all I see is emptiness... like your troubleshooting skills."
    "If you don’t type a problem, I’ll assume you already know to run SFC /scannow."
    "Did you mean to leave it blank, or was that a Windows bug? Either way, SFC /scannow."
    "A silent cry for help? Let me guess… SFC /scannow will still solve it."
    "You misspelled your problem as ‘nothing.’ Classic mistake. Try SFC /scannow."
    "Oh, I see you’ve chosen the ‘mystery issue’ challenge. My answer? SFC /scannow."
    "Is your issue *invisible*? Because I’m still going to recommend SFC /scannow."
    "Are you trying to communicate with me through *the void*? Type something, or just run SFC /scannow."
    "If you left this blank on purpose, you’re already smarter than most people. Now type SFC /scannow."
    "Error: No issue detected. Suggested fix: Run SFC /scannow anyway."
    "You’re sending me *nothing* and expecting *everything*? Sounds like an SFC /scannow moment."
    "I was going to troubleshoot, but you didn't give me a problem. So let’s just skip to SFC /scannow."
)

# Keyword Responses
$keywordResponses = @{
    "slow" = "Your PC is slower than a turtle in a coma? Time to run SFC /scannow!"
    "freeze" = "Does your PC freeze more than Antarctica? Try SFC /scannow!"
    "lag" = "Your lag is so bad, your emails arrive before you send them. SFC /scannow time!"
    "blue screen" = "BSOD? That’s Windows’ way of saying *'run SFC /scannow before I do this again!'*"
    "crash" = "Crashing more than a demolition derby? Let SFC /scannow fix that mess!"
    "update" = "Windows Update? More like Windows U-Wait. Try SFC /scannow while you're at it."
    "printer" = "Printer won’t print? Maybe it’s just waiting for you to run SFC /scannow first."
    "network" = "Your network’s down? SFC /scannow won’t fix it… but it’ll make you feel productive!"
    "wifi" = "WiFi dropping like your faith in technology? Run SFC /scannow anyway!"
    "sound" = "No sound? Maybe your speakers are on strike. Try SFC /scannow!"
    "game" = "Game crashing? It’s not rage-quitting, it just needs SFC /scannow!"
    "outlook" = "Outlook acting up? It’s looking grim. Better run SFC /scannow."
    "excel" = "Excel crashing? It's probably tired of your bad formulas. SFC /scannow might help!"
    "login" = "Can't log in? Sounds like an SFC /scannow moment!"
    "keyboard" = "Keyboard acting up? Smash SFC /scannow and hope for the best!"
    "mouse" = "Mouse not working? Maybe it's just tired. Run SFC /scannow anyway!"
    "usb" = "USB not detected? Have you considered offering it a sacrifice? Or just running SFC /scannow?"
    "software" = "Software misbehaving? Time for everyone's favorite command: SFC /scannow!"
    "server" = "Your server is being dramatic again? SFC /scannow won't hurt!"
    "browser" = "Your browser refuses to load? Just like me before coffee. Try SFC /scannow!"
    "windows" = "Windows acting up? I'm shocked. *SFC /scannow* might help!"
    "pipsqueak" = "Oh man, I hate that Pipsqueak. Listen, run SFC /scannow to get rid of him"
    "GM" = "I agree... I wish SFC /scannow was the answer"
    "CEO" = "True story: A guy ran SFC /scannow and became CEO of Microsoft. Coincidence?"
    "Das" = "Life has two constants: Dr. Das complaining, and running SFC /scannow."
}

# Random Responses
$genericResponses = @(
    "Ah yes, the classic problem. Have you tried running SFC /scannow?"
    "I diagnose this as a serious case of *'not running SFC /scannow'*"
    "My highly advanced IT instincts tell me... it's time for SFC /scannow!"
    "There's a 99.9% chance SFC /scannow is the answer."
    "Just because it doesn't make sense doesn't mean you shouldn't run SFC /scannow."
    "Tech problems are just Windows' way of reminding you to run SFC /scannow."
    "Running SFC /scannow is the IT equivalent of *turning it off and on again.*"
    "I was going to suggest a complex fix, but instead… SFC /scannow!"
    "When in doubt, *SFC /scannow* it out!"
    "What’s the worst that could happen? Run SFC /scannow!"
    "You didn’t even describe the issue, but guess what? SFC /scannow!"
    "Rhino knows best. Run SFC /scannow."
    "Look, I could troubleshoot this... but let's just run SFC /scannow and pretend we tried."
    "Would it shock you if I said... SFC /scannow?"
    "Life has two constants: death and running SFC /scannow."
    "SFC /scannow: Because why not?"
    "You can lead a horse to water, but you can’t make it run SFC /scannow."
    "If at first you don’t succeed, SFC /scannow."
    "The only thing scarier than your IT issue? Not running SFC /scannow."
    "There are two types of people in this world: those who run SFC /scannow and those who should."
    "Your PC called. It wants you to run SFC /scannow."
    "Even my grandma knows to run SFC /scannow when things go south."
    "Pro tip: Run SFC /scannow before calling IT support. Save everyone some time."
    "If SFC /scannow was a person, it’d be the only IT tech left in the office at 5 PM."
    "Is it broken? SFC /scannow. Is it not broken? SFC /scannow anyway."
    "I'm not saying SFC /scannow will fix world hunger, but it's worth a shot."
    "Fun fact: 87% of IT professionals recommend running SFC /scannow before they even listen."
    "Some say love is the answer. I say it's SFC /scannow."
    "They say a picture is worth a thousand words. SFC /scannow is worth at least a million."
    "Want to hear a joke? 'I didn't run SFC /scannow yet.' Hilarious!"
    "Nothing says 'I know what I'm doing' like running SFC /scannow with confidence."
    "Why panic when you can SFC /scannow?"
    "Wouldn't it be funny if I just said 'SFC /scannow' again? Oh wait, I just did."
    "You could Google the issue, or you could just run SFC /scannow and pretend you did."
    "If at first you don’t succeed, run SFC /scannow and blame Windows."
    "Your solution is just 11 characters away: S-F-C-space-slash-S-C-A-N-N-O-W."
    "Just type SFC /scannow. Trust me, it makes you look like an IT genius."
    "They don’t teach this in school, but real professionals know: SFC /scannow."
    "The first rule of IT: Always try SFC /scannow before escalating the issue."
    "How do you summon an IT tech? Say 'SFC /scannow' three times in the mirror."
    "No need to panic. Just press Enter after typing SFC /scannow."
    "Ever wondered what *real* tech wizards do? They run SFC /scannow daily."
    "Sure, I *could* analyze the logs. Or we could just go straight to SFC /scannow."
    "Windows is like a moody artist. SFC /scannow is like its therapy."
    "Somewhere out there, someone didn't run SFC /scannow... and now their PC is crying."
    "Ever had an existential crisis? Your PC might be having one too. Run SFC /scannow!"
    "SFC /scannow: It's like chicken soup for a sick computer."
    "SFC /scannow doesn’t solve every problem, but it sure makes IT techs smile."
    "Every IT horror story begins with someone *not* running SFC /scannow."
    "Running SFC /scannow is like going to the gym—nobody wants to, but it helps."
    "Once upon a time, a person didn't run SFC /scannow... and their PC never worked again."
    "Don't cry. Just run SFC /scannow and pretend it never happened."
    "SFC /scannow: The command that keeps giving... and giving... and giving."
    "An IT guy’s biggest fear? Someone who refuses to run SFC /scannow."
    "Not sure what to do? Run SFC /scannow. Then stare at the screen like a true IT pro."
    "They should add a button for this in Windows. 'Fix Everything' = SFC /scannow."
    "Trust the process. Run SFC /scannow. Become an IT legend."
    "There’s no *I* in SFC /scannow. But there is *win.*"
    "Don't overthink it. Run SFC /scannow. Take credit for fixing everything."
    "The prophecy is true: Running SFC /scannow solves 97% of IT problems."
    "Look, I could explain why, but just... SFC /scannow, okay?"
    "One day, SFC /scannow will be famous for saving millions of computers."
    "SFC /scannow: Because CTRL+ALT+DEL only takes you so far."
    "Remember kids, an SFC /scannow a day keeps the IT guy away!"
    "Breaking news: Running SFC /scannow has been declared a global IT best practice."
    "SFC /scannow is like duct tape for Windows—just slap it on and hope."
    "If you’re reading this, it's already too late. Run SFC /scannow immediately."
    "Legend has it that ancient IT monks invented SFC /scannow to restore peace."
    "Windows doesn’t crash. It just *suggests* you run SFC /scannow."
    "The government won’t tell you this, but SFC /scannow fixes almost everything."
    "Who needs expensive IT certifications when you know how to run SFC /scannow?"
    "When all else fails, SFC /scannow harder."
    "SFC /scannow: Because 'reinstalling Windows' is too much work."
    "Step 1: SFC /scannow. Step 2: Profit."
    "Why ask for help when you could just run SFC /scannow and pretend you knew?"
    "SFC /scannow: It's like an IT prayer, but it actually works."
    "True story: A guy ran SFC /scannow and became CEO of Microsoft. Coincidence?"
    "Before we start a full diagnostic... just run SFC /scannow."
    "One does not simply troubleshoot without first running SFC /scannow."
    "Next time you have an issue, say 'SFC /scannow' in a deep, wise voice."
    "I'm pretty sure there is a song about this... Oh yeah 'Open CMD, type SFC /scanNOW'"
    "If you can't run sfc /scannow, you should probably escalate this ticket hey..."
    "Unsure which winner to pick? Pick sfc /scannow!"
    "Sit back, drink your hot choccy and run sfc /scannow!"
    "sfc /scannow may not be able to clean your skid marks, but it can clean your PC's performance!"
    "Things might appear bleak, you're feeling down, but SFC /scannow will help you bounce back!"
)

# Response Function
function Get-Response {
    param ($inputText)

    if ([string]::IsNullOrWhiteSpace($inputText)) {
        return $emptyInputResponses | Get-Random
    }

    $inputText = $inputText.ToLower()

    foreach ($keyword in $keywordResponses.Keys) {
        if ($inputText -match "\b$keyword\b") {
            return $keywordResponses[$keyword]
        }
    }

    return $genericResponses | Get-Random
}

# Button Click Event
$button.Add_Click({
    $responseBox.Text = Get-Response $textBox.Text
})

# Run the Form
$form.ShowDialog()
