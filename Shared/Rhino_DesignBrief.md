# Rhino-themed Tool Design Brief

This document defines the philosophy, visual language, and engineering
patterns established by RhinoShadow and RhinoCopy. Future tools in the
Rhino family should follow this brief so they feel like a coherent set
rather than independent one-offs.

## Origin and naming

The "Rhino" family started with RhinoCopy, a PowerShell WinForms wrapper
around robocopy built to replace ad-hoc copy scripts on RSAT2. RhinoShadow
followed as a fork of the original Shadow User script, rebuilt in the
same idiom. The naming pattern is "Rhino<Verb>" or "Rhino<Noun>" -
short, single-word, evocative without being silly.

The rhino mascot is the unifying brand element. It appears in the header
of every Rhino tool with a click-to-trigger easter egg (escalating
messages, lore references, etc - keep the tone playful but never
unprofessional). Mascot art lives in a `rhino.ico` or `rhino.png`
alongside the script.

## Philosophy

The tools exist to make IT/sysadmin work more enjoyable, faster, and
more honest. Three principles drive the design:

1. **The right answer in three clicks or fewer.** Whatever the primary
   workflow is, the UI is arranged to make it the path of least
   resistance. Every other capability is secondary and can be tucked
   away. RhinoShadow's primary workflow is "user called, find their
   session, sign them out" - everything else (Browse mode, theming,
   help, easter eggs) is subordinated to that.

2. **Honesty over false reassurance.** When an action's outcome can't
   be verified, the tool says so explicitly rather than logging a
   confident "OK". When a Windows tool returns a uniform exit code,
   stderr is captured so the operator sees the real reason. When a
   guard or feature has limits, those limits are documented in the
   help dialog AND in the source comments. Never lie to the operator
   to keep the UI tidy.

3. **The code is the documentation.** Every function has a comment
   block explaining purpose, design choices, and failure modes. A
   reviewer should be able to read each function's header and
   understand WHY it was built that way without spelunking the body.
   This applies as much to internal helpers as to top-level entry
   points.

## Visual language

### Colour palette (dark - default)

  Bg:         #181A1F  (24, 26, 31)    - app background
  Surface:    #22252C  (34, 37, 44)    - panels, grouboxes, inputs
  SurfaceAlt: #2A2E36  (42, 46, 54)    - hover, alternating rows
  Border:    #3A3F49   (58, 63, 73)    - 1px borders, separators
  Text:      #E6E9EE   (230, 233, 238) - primary text
  Muted:     #949CA8   (148, 156, 168) - secondary text, hints, counts
  Accent:    #60A5FA   (96, 165, 250)  - primary action, links
  AccentHov: #3B82F6   (59, 130, 246)  - accent hover
  Success:   #34A861   (52, 168, 97)   - success state, ok actions
  SuccessHov:#288C4E   (40, 140, 78)
  Danger:    #EF5363   (239, 83, 99)   - destructive action, errors
  DangerHov: #D23C4B   (210, 60, 75)
  Warning:   #F59E42   (245, 158, 66)  - warnings, disconnected state

### Colour palette (light - toggle)

  Bg:         #F5F6F8  (245, 246, 248)
  Surface:    #FFFFFF
  SurfaceAlt: #EDF0F5  (237, 240, 245)
  Border:     #D7DAE0  (215, 218, 224)
  Text:       #20252E  (32, 37, 46)
  Muted:      #6E7681  (110, 118, 129)
  Accent:     #2563EB  (37, 99, 235)
  AccentHov:  #1D4ED8  (29, 78, 216)
  Success:    #228B4E  (34, 139, 78)
  SuccessHov: #1B703E  (27, 112, 62)
  Danger:     #DC3545  (220, 53, 69)
  DangerHov:  #B92837  (185, 40, 55)
  Warning:    #D97706  (217, 119, 6)

Both palettes must be present and switchable. Dark is the default.
Light is for users who need it (washed-out monitors, vision preferences).
The theme toggle lives top-right in the header next to the help button.

### Typography

  Regular text:  Segoe UI 10pt
  Semibold:      Segoe UI Semibold 10pt   (group headers, button labels)
  Title:         Segoe UI Semibold 18pt   (header)
  Subtitle:      Segoe UI 9pt             (hints, counts, statuses)
  Section header:Segoe UI Semibold 10pt   (group box captions)
  Monospace:     Consolas 9.5pt           (activity log, code samples)

Stick to these. Don't introduce new sizes or families.

### Layout

  Form minimum:  Sized so the primary workflow's grid is visible
                 without horizontal scroll. RhinoShadow is 1085x780.
  Form default:  Slightly larger than minimum, ~10% headroom.
  Margins:       15px around the form's content area.
  Panel spacing: 8-12px between groupboxes.

Anchored panels use `Top,Left,Right` so they stretch with the form
during resize. Content width derived from `$form.ClientSize.Width -
($margin * 2)` once at startup, then anchoring handles the rest.

Header bar is `Dock = 'Top'`, height 90px, contains: mascot icon (left),
title and subtitle (centre-left), theme + help buttons (top-right with
`Top,Right` anchor).

### Button roles

Buttons are styled by ROLE not by individual colour choice:

  btn-accent    - primary action (Find, Save, Send). Accent colour.
  btn-success   - confirming action (Refresh, Show, OK). Success green.
  btn-danger    - destructive action (Sign Out, Delete). Danger red.
  btn-neutral   - secondary action (Clear, Cancel). Surface colour.
  btn-help      - small icon button (?, X). Surface with accent text.

A `New-RhinoButton` helper builds, sizes, themes, parents, and registers
a button in one call. Don't construct buttons inline - use the helper.

## Engineering patterns

### Script structure

Every Rhino tool follows the same section ordering:

  1. Assembly imports + WinForms bootstrap
  2. Theme palettes + font definitions
  3. Theme helpers (Register-Themed, Apply-ButtonTheme, New-RhinoButton,
     Apply-Theme, Register-FilterableDropdown if dropdowns used)
  4. CONFIGURATION block (in a clearly marked >>> banner) + script state
  5. Domain-specific non-UI functions (AD queries, file ops, whatever)
  6. Form build:
     a. Form shell + FormClosing handler + icon
     b. Header panel (mascot, title, theme + help buttons)
     c. Mascot click easter egg
     d. Primary workflow panel
     e. Secondary workflow panel (if applicable)
     f. Main results display (grid, list, etc) + filter
     g. Action buttons
     h. Status log textbox
     i. Worker functions: Write-RhinoLog, action handlers
     j. Help dialog (Show-RhinoHelp)
     k. Dropdown population + ShowDialog
  7. Outer catch block for startup crash logging

### Logging

Every Rhino tool ships with two log paths:

  Activity log: %LOCALAPPDATA%\Temp\<ToolName>.log
  Crash log:    %LOCALAPPDATA%\Temp\<ToolName>_crash.log

Write-RhinoLog takes a message and a level (info/ok/warn/error). The
level becomes a 5-char prefix shown after the timestamp:
  info  ->  "     "
  ok    ->  "[OK] "
  warn  ->  "[!]  "
  error ->  "[ERR]"

Every line goes to both the on-screen textbox AND the on-disk file.
File writes are wrapped in try/catch so disk-full or permissions errors
never break the UI.

Session start and end markers go in the file log so an operator
debugging months later can see when the tool was running.

### Destructive actions

Three rules for any operation that changes state:

1. **Confirm before doing.** Modal Yes/No dialog with the specific
   target spelled out ("Sign out X on Y?" not "Proceed?").
2. **Verify after doing, where possible.** If the OS tool reports
   success but you can independently check, do the check. Don't trust
   uniform exit codes.
3. **Capture stderr.** If the underlying tool emits a uniform exit
   code on failure, redirect stderr to a temp file and include the
   real error message in the activity log.

Long-running destructive actions (>1s typically) should run in a
background runspace with a WinForms Timer polling for completion.
This keeps the UI responsive and lets FormClosing actually fire if
the user closes mid-action. RhinoShadow's Invoke-SignOut is the
reference implementation.

### Close-during-action guard

A `$script:actionInFlight` variable holds a human-readable description
of the current destructive action, or `$null` when idle. The
FormClosing handler reads it and prompts before closing. Confirmed
close writes an "ABANDONED" line to the activity log so the audit
trail captures unfinished work.

Active timers are tracked in `$script:asyncTimers`. FormClosing stops
and disposes them on confirmed close so ticks don't fire against a
disposed form.

### Configuration block

Any environment-specific values (AD roots, server names, paths) go in
a clearly demarcated CONFIGURATION block near the top of Section 4:

```
# ==============================================================================
# >>>  CONFIGURATION - EDIT THESE WHEN MOVING TO A NEW DOMAIN  <<<
# ==============================================================================
# (explanation of what each variable does, what format it takes, with
# examples for common layouts)
# ==============================================================================

$script:foo = "..."
$script:bar = "..."

# ==============================================================================
# >>>  END OF CONFIGURATION - the rest of the script is generic  <<<
# ==============================================================================
```

The banner should be visually unmissable. The explanation should cover
purpose, format, examples, and how to find your own values. Anyone
opening the script for the first time should know within 30 seconds
which lines they need to edit and which to leave alone.

### Filterable dropdowns

If the tool has dropdowns over more than ~10 items, use
`Register-FilterableDropdown`:
  - `DropDownStyle = DropDown` (editable)
  - `AutoCompleteMode = SuggestAppend`
  - `AutoCompleteSource = ListItems`

Don't try to write custom TextChanged filtering. WinForms' native
AutoComplete handles inline completion, suggestion popup, tab-to-commit,
and arrow-cycling correctly. Custom filtering will fight it.

Wire selection-driven UI updates to BOTH `SelectedIndexChanged` and
`Leave` - SelectedIndexChanged catches AutoComplete commits,
Leave catches typed-and-tabbed. Use a shared scriptblock so the two
event paths can't drift.

### Identifying info

No real client names, server names, usernames, IPs, or domain strings
in comments, examples, help text, or sample data. The only place
domain-specific values are allowed is in the CONFIGURATION block
itself, and those should be set to the deployment's actual values
(not placeholders) so the tool works without further editing.

If a comment needs example data, use obviously fake placeholders:
"user01", "ClientX", "PER-EXAMPLE-01", "example.com.au".

## Help dialog

Every Rhino tool has a "?" button top-right that opens a modal help
window. The help contains:

  - Quick workflow walkthrough (numbered steps for the primary task)
  - Tips section (keyboard shortcuts, filter syntax, gotchas)
  - Secondary workflows (if applicable)
  - Actions reference (what each button does, with caveats)
  - Closing the window (any in-flight action guards)
  - Log files (paths and what each contains)
  - Config (current values - expanding here-string so each deployment
    sees its own, with a sentence clarifying that this varies per
    deployment)

Build the help dialog fresh on each open rather than caching it. Theme
changes mid-session would corrupt a cached dialog. Use RichTextBox with
WordWrap=false so the layout reads at natural widths.

## What "looks Rhino" means

A user looking at any Rhino tool for the first time should immediately
recognise:

  - Dark theme by default, with the specific accent blue and danger red
  - Rhino mascot in the header
  - "Rhino<Name>" version string in the title bar
  - Activity log at the bottom with [OK]/[!]/[ERR] prefixed timestamped lines
  - Modal Yes/No confirmations for destructive actions
  - "?" help button top-right next to the theme toggle

A user moving between Rhino tools should never have to relearn how the
interface works. Keyboard shortcuts, filter syntax, dropdown behaviour,
log conventions - all consistent.

## What "feels Rhino" means

The tool should feel:

  - **Fast.** Parallelise anything that can be parallelised. Cache
    repeated lookups. Don't make the operator wait for things the
    tool could have prefetched.
  - **Honest.** If you can't verify, say so. If a Windows tool is
    being a jerk, capture its actual error message. Don't paper over
    inconsistency with cheerful UI text.
  - **Forgiving.** Confirmations before destructive actions, ABANDONED
    audit lines for interrupted operations, fallback paths when AD or
    a server isn't reachable. The operator should never accidentally
    nuke something or wonder why something silently didn't work.
  - **Self-documenting.** Help text, comments, and config block should
    let a new operator (and a code reviewer) get up to speed without
    needing tribal knowledge or chasing down the original author.

## Anti-patterns to avoid

  - **PSCustomObject in object construction.** Use `[PSCustomObject]@{...}`
    syntax, not New-Object PSCustomObject.
  - **Multi-line if/else with PowerShell aliases.** Use full cmdlet names
    (`Where-Object` not `?`, `ForEach-Object` not `%`) for readability.
  - **Silently swallowed exceptions.** Every try block needs a catch
    that either logs or rethrows. Bare `catch { }` only for cleanup
    code (e.g. dispose in finally) where the cleanup failure is
    genuinely uninteresting.
  - **Hardcoded paths.** Always use `Join-Path` with `$env:LOCALAPPDATA`
    or similar - never literal `C:\Users\...`.
  - **Modal dialogs for non-modal info.** Use the activity log for
    status updates. Modals are for confirmations or genuine "stop and
    decide" moments only.
  - **Bullet-pointed help.** Use prose with numbered steps for
    sequences. Help text reads top-to-bottom; bullets fragment that.
  - **Em dashes.** Use hyphens or sentence restructuring instead.
    Australian English throughout.

## Reference implementations

Look at these in priority order when building a new Rhino tool:

  1. RhinoShadow (this script) - the most complete reference. Covers
     theming, async actions, AD queries, parallel work via runspace
     pools, P/Invoke for Win32 APIs, FormClosing guards, action
     verification.
  2. RhinoCopy - the original. Simpler structure; good for seeing the
     baseline pattern without async/AD complexity. Has the rhino
     mascot, theme system, activity log, robocopy wrapper, and
     animated progress.

When in doubt, copy the pattern from RhinoShadow first. If the new
tool genuinely needs a different approach, document the deviation in
the file header explaining why.
