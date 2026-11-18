Accessible Claude Code

One file, claude-accessibility.cmd, that sets up Claude Code on Windows for blind and low vision people who use a screen reader such as NVDA or JAWS. Run it once and restart Claude Code.

What it does

It turns on Claude Code's screen reader mode and reduced motion, and turns off spinner tips and window title changes from Claude Code itself.

It installs a small Claude Code mod called quiet-tools, which:
Hides the lines for each command Claude runs, so you hear Claude's replies and not the commands in between. Press Control+O in Claude Code to see everything.
Hides the hint line under the prompt.
Replaces the "Churned for 3 seconds" line with "Done.", or "Done. Still working in the background." when something is still running.
Plays a soft chord when Claude finishes a reply.
Plays a different chord when Claude asks you a question or needs your permission, and repeats it every 6 seconds until you answer.
Says in the window title what Claude is doing while it works, such as "Claude is reading register.tsx" or "Claude is running a command: Install packages". When it needs your permission, the title says for what, such as "Claude wants to edit settings.json".
Warns under a reply when the conversation is 80 percent full, and again at 90, so you can type /compact to make room before it slows down.
Sets the window title to the conversation's name and what Claude is doing, such as "Fix the login page - Claude is working", "Claude is done", or "Claude needs your permission". With NVDA, press NVDA+T to hear it. A new conversation gets a short name from what you first asked, made again after your 4th message as the topic settles, and kept so it shows in the window title and the /resume list. It is not shown under the prompt; only a name you give with /rename is. A resumed conversation with no name is named from the whole conversation as soon as it opens. A name you give it with /rename, or one Claude Code gives it, is used instead and never replaced.
Makes /resume readable. Type /resume to hear your 15 newest conversations as a numbered list, with when and where each one was. Type /resume and some words, such as /resume login page, to list the conversations that mention all of those words, each with the text around the match. Then type just the number, such as 2, and press Enter to open that one. /resume and a number, such as /resume 2, also works.
Tells Claude to write for a screen reader: answer first, and no tables, diagrams or emoji.
Adds a few extra words to the working line, like Faering and Paering.

It turns off the bell that Windows Terminal plays at the end of every reply.

If you use NVDA, it installs the Console Redraw Fix add-on. Claude Code sometimes wipes the screen and draws everything again. Without the add-on, NVDA then reads the whole screen from the top, and your review cursor ends up at the top. With it, NVDA speaks only the lines you have not heard yet. Everything the add-on does works only in Claude Code windows set up with the quiet-tools mod, in Windows Terminal or the classic console that cmd and PowerShell open in. It knows them by the window titles the mod sets. Other terminal windows work as if the add-on were not there. Normal new output is read just like before. A change only counts as a redraw when it is at least 3 lines and at least half of them were already on screen. In Windows Terminal, NVDA must read new text by diffing, which is NVDA's default. It is under NVDA settings, Advanced, "Speak new text in Windows Terminal via".

The add-on also adds Find for Claude Code conversations. The terminal only keeps about the last screen of text, so it searches the saved conversation instead. In a Claude Code window, press Control+F (or NVDA+Control+F), type what to find, and press Enter. NVDA opens the whole conversation as a document in browse mode, with a heading for each of your messages and each of Claude's replies, and puts you on the most recent place the text appears. Read on with the arrow keys. Shift+F3 goes to the match before, F3 to the one after, and Escape closes it. In other windows Control+F works as usual. Your review cursor stays where you are reading. New text in Claude Code does not move it, so you can read back with the review keys (NVDA+arrows) while Claude keeps writing. To have it jump to new text as NVDA normally does, open NVDA's settings, choose Console Redraw Fix, and check "Move the review cursor to new text in Claude Code windows". In a Claude Code window, NVDA+A (or NVDA+Down Arrow on the desktop keyboard layout) reads from the review cursor to the end, and pressing Down Arrow puts the review cursor on the last line of text and reads it.

In a Claude Code window, NVDA+Control+L reads Claude's last reply. Press it twice to open the reply in browse mode and read it at your own pace. You can change these keys in NVDA's Input gestures, under Console Redraw Fix.

If you use NVDA, it installs the Claude Usage add-on from its newest release on GitHub. It says how much of your Claude plan you have used: the 5-hour session, the weekly limit and when they reset. It has no keys at first; give it some in NVDA under Preferences, Input gestures, Claude Usage. If you have it, the setup updates it when GitHub has a newer version. It needs NVDA 2026.1 or newer.

You need

Windows 10 or 11, on an ARM, Intel or AMD PC.
Claude Code, already installed and signed in.
For the add-on: NVDA 2024.1 or newer, installed on the PC (not a portable copy).

How to install

The easiest way: press Windows+R, paste this line, and press Enter.

powershell -nop -ep bypass -c "[Net.ServicePointManager]::SecurityProtocol=3072;$f=Join-Path $env:TEMP ca.cmd;irm https://raw.githubusercontent.com/ce2004/accessible-claude-code/main/claude-accessibility.cmd -OutFile $f;& $f"

Or download claude-accessibility.cmd from this page and double-click it. Windows may say "Windows protected your PC". Choose More info, then Run anyway.

When it finishes, it reads out what it did, then checks that each part is in place and names any that is not. Close Claude Code and start it again. If it installed or updated the NVDA add-on, it asks you to press R to restart NVDA, or any other key to restart NVDA yourself later.

It is safe to run again at any time. Each time it starts, it checks this page for a newer version. If there is one, it updates itself and starts again, so you always get the latest setup. It also checks for a newer version of the NVDA add-on, and updates it. If it cannot check, for example when you are offline, it runs the version you have. If one step fails, it says why and still does the rest.

Good to know

Type /copy in Claude Code to copy Claude's last reply to the clipboard, so you can paste it into Notepad and read it at your own pace.

The "auto mode on" and "/rc" labels near the prompt cannot be hidden by a mod.

How to undo it

The mod: in a terminal, run: claude plugin uninstall quiet-tools@claude-accessibility
Then delete the claude-accessibility folder inside the .claude folder in your user folder.

The NVDA add-on: in NVDA, open Tools, then Add-on store, go to the Installed add-ons tab, choose Console Redraw Fix, and remove it. Then restart NVDA. The setup will not put it back. To get it back later, delete the file nvda-addon-installed.txt in the claude-accessibility folder inside the .claude folder in your user folder, then run the setup again.

The Claude Usage add-on: remove it the same way, choosing Claude Usage. The setup will not put it back. To get it back later, delete the file claude-usage-installed.txt in the claude-accessibility folder inside the .claude folder in your user folder, then run the setup again.

The settings: before the first change, the script saves a copy of each settings file next to it, ending in .before-claude-accessibility. To go back, delete the changed file and remove that ending from the copy's name. The Claude Code settings are in the .claude folder in your user folder. The Windows Terminal settings can also be changed in Windows Terminal under Settings, then Defaults, then Advanced, then Bell notification style.

For developers

The add-on source is in the console-redraw-fix folder. The setup downloads it from there, file by file. When you change the add-on, raise version in its manifest.ini, or the setup will not update it. When you change claude-accessibility.cmd, raise CA_VERSION near its top, or copies people already have will not update themselves. To make an add-on file to open by hand, zip the contents of the console-redraw-fix folder (not the folder itself) and rename the zip to end in .nvda-addon.
