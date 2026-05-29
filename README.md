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

## RhinoShadow

**`RhinoShadow/RhinoShadow.ps1`** — currently at **v1.69**

A polished fork of Shadow User, rebuilt for the common workflow: *"User X just called me — which RDS server are they on, which PC are they on, sign them out or shadow them."* Three clicks or fewer.

**Headline features:**
- **Quick Find** — type any name (username, first name, surname, display name, or UPN) and RhinoShadow resolves it against AD, then searches every RDS server **in parallel** via runspace pool (~30 servers in 2-3s instead of 30s+).
- **Local Computer column** — shows the workstation each user is connecting FROM, looked up via the WTS API. Saves a manual lookup for RMM handoffs.
- **MSP / multi-tenant dual-root config** — separate AD trees for client tenants and RDS hosts, joined by client OU name. Single-tenant setups point both at the same OU.
- **Background async sign-out** with post-action verification — re-queries the server after `logoff.exe` returns to confirm the session actually went, catches the Server 2019 silent-success failure mode.
- **stderr capture** for logoff and msg failures — surfaces the actual Windows error message ("Access is denied", etc) instead of a bare exit code.
- **Light / dark theme toggle**, **live filter** across Username / Server / State / Local Computer, sortable grid, custom themed 255-char message dialog.
- **Persistent activity log** at `%LOCALAPPDATA%\Temp\RhinoShadow.log` — full audit trail including message bodies and target workstations.

Full release notes, changelog, configuration guide, and known behaviours are in [`RhinoShadow/README.md`](RhinoShadow/README.md). The code-review request that accompanies this release is in [`RhinoShadow/RhinoShadow_ReviewTicket.txt`](RhinoShadow/RhinoShadow_ReviewTicket.txt).

The original Browse-by-Client flow is preserved as a secondary panel.

*Forked by Jared from the original Shadow User. Requires the same domain access.*

---

## Shared

**`Shared/SecretRhinoMessages.ps1`**

A standalone, drop-in code block containing the full Rhino mascot easter-egg messages — three escalating mood arrays (friendly / irritated / blanket statements) plus the click handler. Copy-paste it into any Rhino-themed tool to give the mascot a personality. Currently used by RhinoCopy and RhinoShadow; RhinoCopy is the canonical source of truth for message edits.

---

## Requirements

All tools require Windows with PowerShell and .NET / WinForms available (standard on any domain-joined Windows machine). Shadow User additionally requires network access to the RDS servers and permission to run `query user` and `logoff` remotely.
