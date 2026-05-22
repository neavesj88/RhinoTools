<#
================================================================================
  SecretRhinoMessages.ps1 - Reusable Rhino mascot easter-egg snippet
================================================================================

This file is a drop-in code block for adding the "click the rhino" easter egg
to any Rhino-themed PowerShell GUI tool. Copy the three message arrays and the
click handler into your script, then wire it up to a mascot PictureBox.

USAGE:
    1. Paste the message arrays + click handler into your script, somewhere
       after your mascot PictureBox is created.
    2. Replace the output target inside the handler with whatever your tool
       uses to display status text (e.g. $txtStatus.Text in RhinoCopy,
       Write-RhinoLog in RhinoShadow, $commentLabel.Text in RhinoStomp, etc.)
    3. Tweak the message arrays to taste - or keep them verbatim for
       consistency across the toolset.

MOOD ESCALATION:
    Clicks 1-10  : $friendlyMessages   - cheerful IT-isms and shoutouts
    Clicks 11-20 : $irritatedMessages  - Rhino is getting tired of you
    Clicks 21+   : $blanketStatements  - Rhino has fully checked out

The $script:lastMessage + do...while guard ensures the same message never
appears twice in a row.

ORIGINAL HOME:
    RhinoCopy/rhino_copy.ps1 (currently the canonical source of truth).
    If you add or change messages, prefer editing RhinoCopy first and then
    syncing this file + any other tools.
================================================================================
#>


# ==============================================================================
# CLICK COUNTER AND LAST-MESSAGE TRACKER
# ==============================================================================
# $script:clickCount drives which message array we pull from on each click.
# $script:lastMessage is the no-repeat guard - prevents the same message
# appearing twice consecutively, which would feel like a bug.
$script:clickCount = 0
$script:lastMessage = ""


# ==============================================================================
# MESSAGE ARRAYS
# ==============================================================================

# ----- Clicks 1-10: friendly tips, IT jokes, and shoutouts -----
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

# ----- Clicks 11-20: Rhino is getting irritated -----
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

# ----- Clicks 21+: Rhino has checked out -----
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


# ==============================================================================
# CLICK HANDLER
# ==============================================================================
# Wire this onto the .Add_Click of your mascot PictureBox. Replace the
# OUTPUT line with whatever your tool uses to surface status text:
#
#   RhinoCopy   :  $txtStatus.Text = "Secret Rhino Message: " + $newMessage
#   RhinoShadow :  Write-RhinoLog "Secret Rhino Message: $newMessage"
#   RhinoStomp  :  $commentLabel.Text = $newMessage
#
# The do...while loop with the $lastMessage check is the no-repeat guard.
# The "Count -gt 1" condition prevents an infinite loop if an array somehow
# ends up with only one entry (defensive, not actually reachable today).

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

    # >>> REPLACE THIS LINE with your tool's status-output target <<<
    Write-Host "Secret Rhino Message: $newMessage"
})


# ==============================================================================
# OPTIONAL: RESET ON OTHER INTERACTIONS
# ==============================================================================
# In RhinoCopy, $script:clickCount is reset to 0 whenever the user does
# something productive (changes a setting, clicks a help button, etc.).
# That way Rhino doesn't stay angry while you actually use the tool. To
# replicate this, sprinkle `$script:clickCount = 0` into the Add_Click /
# Add_CheckedChanged handlers of your other controls. Example:
#
#     $someButton.Add_Click({
#         # ... do the button thing ...
#         $script:clickCount = 0
#     })
