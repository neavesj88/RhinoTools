# Rhino Tools

A collection of PowerShell GUI tools built for the IT team. Each tool is a self-contained `.ps1` script with a WinForms interface.

---

## RhinoCopy

**`RhinoCopy/rhino_copy.ps1`**

A polished GUI front-end for Robocopy. Takes the pain out of constructing long Robocopy commands by wrapping all the common flags in a point-and-click interface.

**Features:**
- Browse dialogs for source and destination folders
- Performance mode selector (18 / 9 / 4 threads)
- Copy flag presets — Data, Attributes, Timestamps, Security, Owner
- Standard recurse (`/E`) vs destructive Mirror (`/MIR`) mode
- Optional dry run (`/L`) and timestamped log file output
- Live progress bar, spinner, and elapsed-time clock during copy
- Plain-English exit code decoder (e.g. `3 = 1+2 = files copied + extras`)
- In-app Robocopy flag reference popup
- Light / dark theme toggle
- "Copy Command" button to grab the raw Robocopy command for learning or reuse
- Rhino mascot easter egg with escalating moods

*Made by Jared.*

---

## RhinoHelper

**`RhinoHelper/RhinoHelper.ps1`**

An IT helpdesk "assistant" that responds to any problem description with a recommendation to run `SFC /scannow`. Has keyword-aware responses for common issues (printers, network, blue screens, etc.) and a generous library of snarky one-liners. Includes a few inside jokes for the team.

**Features:**
- Type any IT issue and get "help"
- Keyword matching for ~20 common problem types
- 70+ unique generic responses
- 15 responses specifically for blank input

*Made by the guys at work.*

---

## RhinoPass

**`RhinoPass/RhinoPass.ps1`**

A password generator that produces readable, memorable passwords in the format `AdjectiveNoun##` (e.g. `BravePenguin47`).

**Features:**
- Generates passwords from a large adjective + noun wordlist with a random 2-digit number
- Optional capital letters toggle
- Optional special character substitutions (`a→@`, `s→$`, `o→0`, `i→!`)
- One-click copy to clipboard
- Mood system — Rhino starts cheerful, gets annoyed after 10 generations, goes angry after 20, then recovers

*Made by the guys at work.*

---

## RhinoStomp

**`RhinoStomp/RhinoStomp.ps1`**

A mini click-to-squash game. A bug bounces around the screen and you click it to score points. Rhino provides running commentary.

**Features:**
- Bug moves to a random new position on each tick
- Speed increases over time (every 30 seconds)
- Score counter and reset button
- 47 unique miss taunts and 49 unique hit reactions from Rhino
- Bug spawns away from the Rhino mascot so it's always clickable

*Made by the guys at work.*

---

## Shadow User

**`Shadow User/ShadowUser.ps1`**

An Active Directory-aware RDS session manager. Lets you browse RDS servers by client OU, see who is logged in, and shadow or sign out a session — all from a GUI.

**Features:**
- Pulls OUs and servers directly from AD (`OU=RDS Servers,OU=Servers,DC=focusnet,DC=net,DC=au`)
- Checkbox list to select one or more RDS servers
- Grid view showing Username, Server, Logon Time, and Session ID
- Shadow a session via `mstsc /shadow` with control
- Sign out a selected session with confirmation prompt
- Refresh button to re-query live session data

*Made by the guys at work. Requires domain connectivity and appropriate AD permissions.*

---

## Requirements

All tools require Windows with PowerShell and .NET / WinForms available (standard on any domain-joined Windows machine). Shadow User additionally requires network access to the RDS servers and permission to run `query user` and `logoff` remotely.
