@echo off
setlocal
rem Claude Accessibility: sets up Claude Code for screen reader users on this Windows account.
rem It turns on screen reader settings, installs the quiet-tools mod, silences the
rem Windows Terminal bell, and installs the Console Redraw Fix add-on for NVDA. Safe to run again at any time.
rem When it starts, it checks GitHub for a newer version, and if there is one it
rem replaces this file with it and runs it instead.
rem Raise CA_VERSION with every change pushed to GitHub, or copies already out there will not update.
set "CA_VERSION=1.2.0"
set "CA_SELF=%~f0"
set "CA_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%CA_PS%" set "CA_PS="
for %%P in (powershell.exe pwsh.exe) do if not defined CA_PS for %%Q in (%%P) do if not "%%~$PATH:Q"=="" set "CA_PS=%%~$PATH:Q"
if not defined CA_PS (
  echo PowerShell was not found on this PC, so nothing was changed.
  echo Windows normally includes it. Ask whoever manages this PC to turn it back on.
  echo.
  pause
  exit /b
)
rem This block is read in one go, so it keeps working after the update rewrites this file.
rem Exit code 10: this file was updated. 11: the update was saved to the temp folder instead.
(
  "%CA_PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "try { $t=[IO.File]::ReadAllText($env:CA_SELF); $i=$t.IndexOf('#'+'PSSTART'); if ($i -lt 0) { throw 'This file is damaged. Download it again.' }; iex $t.Substring($i) } catch { Write-Host ''; Write-Host ('Something unexpected went wrong: ' + $_.Exception.Message); exit 9 }"
  if errorlevel 11 (
    set "CA_UPDATED=1"
    call "%TEMP%\claude-accessibility-update.cmd"
    exit /b
  ) else if errorlevel 10 (
    set "CA_UPDATED=1"
    call "%CA_SELF%"
    exit /b
  ) else if errorlevel 9 (
    echo.
    echo The setup stopped partway. The steps reported above were done. You can run this file again.
  )
  echo.
  pause
  exit /b
)

#PSSTART
$ErrorActionPreference = 'Stop'
$enc = New-Object System.Text.UTF8Encoding($false)
$failed = 0
$backupSuffix = '.before-claude-accessibility'

function Say([string]$m) { Write-Host $m }

# Reads a text file, retrying while another program has it open.
function Read-Text([string]$p) {
    for ($n = 1; ; $n++) {
        try { return [IO.File]::ReadAllText($p, $enc) }
        catch { if ($n -ge 5) { throw }; Start-Sleep -Milliseconds 400 }
    }
}

# Writes a text file through a temporary file, retrying while another program has it open.
# A backup of the original is kept the first time only, so it is always the real original.
function Write-Text([string]$p, [string]$text) {
    if ((Test-Path -LiteralPath $p) -and -not (Test-Path -LiteralPath ($p + $backupSuffix))) {
        Copy-Item -LiteralPath $p -Destination ($p + $backupSuffix)
    }
    if (Test-Path -LiteralPath $p) {
        $item = Get-Item -LiteralPath $p
        if ($item.IsReadOnly) { throw "the file is read-only: $p" }
    }
    $tmp = $p + '.tmp-claude-accessibility'
    [IO.File]::WriteAllText($tmp, $text, $enc)
    for ($n = 1; ; $n++) {
        try {
            if (Test-Path -LiteralPath $p) { [IO.File]::Replace($tmp, $p, [NullString]::Value) } else { [IO.File]::Move($tmp, $p) }
            return
        } catch {
            if ($n -ge 8) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue; throw }
            Start-Sleep -Milliseconds 500
        }
    }
}

# Runs a program with a time limit and returns its exit code and output.
function Invoke-Tool([string]$exe, [string[]]$argList, [int]$seconds = 120) {
    $ext = [IO.Path]::GetExtension($exe).ToLowerInvariant()
    $quoted = ($argList | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $psi = New-Object Diagnostics.ProcessStartInfo
    if ($ext -eq '.cmd' -or $ext -eq '.bat') {
        $psi.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
        $psi.Arguments = '/d /s /c ""' + $exe + '" ' + $quoted + '"'
    } elseif ($ext -eq '.ps1') {
        $psi.FileName = (Get-Process -Id $PID).Path
        $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $exe + '" ' + $quoted
    } else {
        $psi.FileName = $exe
        $psi.Arguments = $quoted
    }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.EnvironmentVariables['NO_COLOR'] = '1'
    $psi.EnvironmentVariables['FORCE_COLOR'] = '0'
    $proc = [Diagnostics.Process]::Start($psi)
    $proc.StandardInput.Close()
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit($seconds * 1000)) {
        try { $proc.Kill() } catch {}
        return @{ Code = -1; Out = 'It did not answer within ' + $seconds + ' seconds.'; TimedOut = $true }
    }
    $proc.WaitForExit()
    $text = ($outTask.Result + "`n" + $errTask.Result) -replace '\x1b\[[0-9;?]*[A-Za-z]', ''
    return @{ Code = $proc.ExitCode; Out = $text.Trim(); TimedOut = $false }
}

# ---------------------------------------------------------------- Update check
# If GitHub has a newer version, it replaces this file and exits with code 10, so
# the batch part above starts the new copy. If this file cannot be replaced, the new
# copy goes to the temp folder instead (code 11). A copy just updated skips the check.
$updateUrl = 'https://raw.githubusercontent.com/ce2004/accessible-claude-code/main/claude-accessibility.cmd'
if (-not $env:CA_UPDATED -and $env:CA_SELF) {
    $newCopy = $null
    try {
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 } catch {}
        $req = [Net.WebRequest]::Create($updateUrl)
        $req.Timeout = 10000
        if ($req -is [Net.HttpWebRequest]) {
            $req.ReadWriteTimeout = 10000
            $req.UserAgent = 'claude-accessibility-updater'
            $req.CachePolicy = New-Object Net.Cache.RequestCachePolicy([Net.Cache.RequestCacheLevel]::NoCacheNoStore)
        }
        $resp = $req.GetResponse()
        try {
            $ms = New-Object IO.MemoryStream
            $resp.GetResponseStream().CopyTo($ms)
            $bytes = $ms.ToArray()
        } finally { $resp.Close() }
        $text = $enc.GetString($bytes)
        $m = [regex]::Match($text, '(?m)^set "CA_VERSION=([0-9]+(\.[0-9]+){1,3})"')
        if ($m.Success -and $text.StartsWith('@echo off') -and $text.Contains('#' + 'PSSTART') -and
            ([version]$m.Groups[1].Value -gt [version]$env:CA_VERSION)) {
            $newCopy = $bytes
            Say ('A newer version of this setup is out (' + $m.Groups[1].Value + '). Updating and starting it again.')
        }
    } catch {
        Say 'Could not check for a newer version, so this one will run.'
        Say ''
    }
    if ($newCopy) {
        $tmp = $env:CA_SELF + '.new-claude-accessibility'
        try {
            [IO.File]::WriteAllBytes($tmp, $newCopy)
            [IO.File]::Replace($tmp, $env:CA_SELF, [NullString]::Value)
            Say ''
            exit 10
        } catch {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
        try {
            [IO.File]::WriteAllBytes((Join-Path $env:TEMP 'claude-accessibility-update.cmd'), $newCopy)
            Say 'This file could not be replaced, so the new version runs from the temp folder.'
            Say ''
            exit 11
        } catch {
            Say ('The update could not be saved, so this version will run: ' + $_.Exception.Message)
            Say ''
        }
    }
}

# ---------------------------------------------------------------- Checks
if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    Say 'This PC restricts PowerShell (Constrained Language Mode), so nothing was changed.'
    Say 'This is usually set by a work or school. Ask whoever manages this PC.'
    exit 1
}
if (-not $env:USERPROFILE -or -not (Test-Path -LiteralPath $env:USERPROFILE)) {
    Say 'Your user folder could not be found, so nothing was changed.'
    exit 1
}
try {
    $me = [Security.Principal.WindowsIdentity]::GetCurrent()
    if ((New-Object Security.Principal.WindowsPrincipal($me)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Say ('Note: this is running as administrator, so it sets up the account ' + $me.Name + '.')
        Say 'If that is not the account you use Claude Code with, run it again without Run as administrator.'
        Say ''
    }
} catch {}

$dir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
$settingsPath = Join-Path $dir 'settings.json'

# Find Claude Code.
$claude = $null
try {
    $found = Get-Command claude -CommandType Application, ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { $claude = $found.Source }
} catch {}
if (-not $claude) {
    foreach ($c in @(
        (Join-Path $env:USERPROFILE '.local\bin\claude.exe'),
        (Join-Path "$env:APPDATA" 'npm\claude.cmd'),
        (Join-Path "$env:LOCALAPPDATA" 'Programs\claude\claude.exe')
    )) { if ($c -and (Test-Path -LiteralPath $c)) { $claude = $c; break } }
}
if ($claude) {
    try {
        $v = Invoke-Tool $claude @('--version') 60
        if ($v.Code -ne 0) { Say ('Claude Code was found but did not start: ' + $v.Out); Say ''; $claude = $null; $failed++ }
    } catch { Say ('Claude Code was found but could not be started: ' + $_.Exception.Message); Say ''; $claude = $null; $failed++ }
}
if (-not $claude -and -not (Test-Path -LiteralPath $dir)) {
    Say 'Claude Code is not installed for this Windows account, so nothing was changed.'
    Say 'Install Claude Code first, then run this file again.'
    exit 1
}

# ---------------------------------------------------------------- Part 1: Claude Code settings
# Installing the mod also writes to this settings file, so a problem here stops that too.
$settingsProblem = $null
try {
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $s = $null
    $ok = $true
    if (Test-Path -LiteralPath $settingsPath) {
        $text = Read-Text $settingsPath
        if ($text.Trim()) {
            try { $s = $text | ConvertFrom-Json } catch { $ok = $false }
            if ($ok -and -not ($s -is [Management.Automation.PSCustomObject])) { $ok = $false }
        }
    }
    if (-not $ok) {
        Say 'Your Claude Code settings file has a mistake in it, so it was left alone:'
        Say ('  ' + $settingsPath)
        Say 'Fix or delete that file, then run this again. The other steps still ran.'
        $settingsProblem = 'it has a mistake in it'
        $failed++
    } else {
        if (-not $s) { $s = New-Object PSObject }
        function Set-Value($obj, $name, $value) {
            $p = $obj.PSObject.Properties[$name]
            if ($p) {
                if ($p.Value -is [string] -and $value -is [string] -and $p.Value -ceq $value) { return $false }
                if ($p.Value -is [bool] -and $value -is [bool] -and $p.Value -eq $value) { return $false }
                $p.Value = $value
            } else {
                $obj | Add-Member -NotePropertyName $name -NotePropertyValue $value
            }
            return $true
        }
        $done = @()
        if (Set-Value $s 'axScreenReader' $true)       { $done += 'Screen reader mode turned on.' }
        if (Set-Value $s 'prefersReducedMotion' $true) { $done += 'Reduced motion turned on.' }
        if (Set-Value $s 'spinnerTipsEnabled' $false)  { $done += 'Spinner tips turned off.' }
        $envProp = $s.PSObject.Properties['env']
        if (-not $envProp -or $null -eq $envProp.Value) {
            if ($envProp) { $s.env = New-Object PSObject } else { $s | Add-Member -NotePropertyName env -NotePropertyValue (New-Object PSObject) }
        }
        if ($s.env -is [Management.Automation.PSCustomObject]) {
            if (Set-Value $s.env 'CLAUDE_CODE_DISABLE_TERMINAL_TITLE' '1') { $done += 'Window title changes turned off.' }
        } else {
            Say 'The env section of your settings is not in the usual form, so window title changes were left as they are.'
        }
        if ($done.Count -eq 0) {
            Say 'The screen reader settings were already on.'
        } else {
            $json = $s | ConvertTo-Json -Depth 100
            $null = $json | ConvertFrom-Json
            Write-Text $settingsPath $json
            $done | ForEach-Object { Say $_ }
        }
    }
} catch {
    Say ('The Claude Code settings could not be changed: ' + $_.Exception.Message)
    $settingsProblem = 'it could not be changed'
    $failed++
}
try {
    if (-not $settingsProblem -and (Test-Path -LiteralPath $settingsPath) -and (Get-Item -LiteralPath $settingsPath).IsReadOnly) {
        Say 'Your Claude Code settings file is read-only. Turn that off in its Properties, then run this again.'
        $settingsProblem = 'it is read-only'
        $failed++
    }
} catch {}

# ---------------------------------------------------------------- Part 2: the quiet-tools mod
# It is kept in a small local plugin catalog in the .claude folder, and Claude Code
# loads it from there, so that folder has to stay.
Say ''
$modReady = $false
if (-not $claude) {
    Say 'The quiet-tools mod was not installed, because Claude Code could not be started.'
    Say 'Install or repair Claude Code, then run this file again.'
    $failed++
} elseif ($settingsProblem) {
    Say ('The quiet-tools mod was not installed, because installing it changes the Claude Code settings file, and ' + $settingsProblem + '.')
    Say 'Once that file is fixed, run this again.'
} else {
    try {
        $mkt = Join-Path $dir 'claude-accessibility'
        $mod = Join-Path $mkt 'plugins\quiet-tools'
        foreach ($d in @("$mkt\.claude-plugin", "$mod\.claude-plugin", "$mod\hooks", "$mod\sounds")) {
            if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        }

        $files = [ordered]@{}
        $files["$mkt\.claude-plugin\marketplace.json"] = @'
{ "name": "claude-accessibility", "owner": { "name": "Claude Accessibility" }, "plugins": [ { "name": "quiet-tools", "source": "./plugins/quiet-tools", "description": "Hides tool call lines for screen reader users." } ] }
'@
        $files["$mod\.claude-plugin\plugin.json"] = @'
{ "name": "quiet-tools", "version": "0.2.0", "description": "Screen reader help for Claude Code: hides tool call lines (Ctrl+O shows them), plays sounds, names the window after the conversation, and lists or searches conversations with /resume." }
'@
        $files["$mod\hooks\hooks.json"] = @'
{ "modules": ["./register.tsx"] }
'@
        $files["$mod\hooks\register.tsx"] = @'
import type { Register } from 'claude-code'

// Tools whose rows stay visible because they ask the person something.
const ASKS = new Set(['AskUserQuestion', 'ExitPlanMode'])

// Sounds: Windows plays them, since the engine has no player on Windows.
// Tries powershell on the PATH, then its usual place.
const PLAYERS = ['powershell.exe', 'C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe']
function sound($: any, name: string) {
  const file = `${$.plugin.root}\\sounds\\${name}.wav`.replace(/'/g, "''")
  const script = `(New-Object Media.SoundPlayer '${file}').PlaySync()`
  const tryPlayer = (i: number): void => {
    if (i >= PLAYERS.length) return
    try {
      $.process
        .run([PLAYERS[i], '-NoProfile', '-NonInteractive', '-Command', script], { timeoutMs: 10000 })
        .catch(() => tryPlayer(i + 1))
    } catch {
      tryPlayer(i + 1)
    }
  }
  tryPlayer(0)
}

// Window title: settitle.exe (built by the installer) sets the title of the
// Claude Code window, so a screen reader can read it with its title key.
// It reads the conversation's name, then what Claude is doing:
// "Fix the login page - Claude is working".
let shownTitle = ''
let stateText = 'Claude is ready'
let convTitle = ''
function title($: any, state?: string) {
  if (state) stateText = state
  const text = convTitle ? `${convTitle} - ${stateText}` : stateText
  if (text === shownTitle) return
  shownTitle = text
  try {
    $.process.run([`${$.plugin.root}\\settitle.exe`, text], { timeoutMs: 5000 }).catch(() => {})
  } catch {}
  void writeWindowFile($, text)
}

// The NVDA add-on's Control+F finds this conversation by the window's title:
// one small file per session, in .claude\claude-accessibility\windows.
async function writeWindowFile($: any, text: string) {
  try {
    const info = await $.session.info()
    const id = await $.session.id()
    const path: string = info.transcriptPath
    const sep = path.includes('\\') ? '\\' : '/'
    const up = (p: string) => p.slice(0, p.lastIndexOf(sep))
    const config = up(up(up(path))) // <config>\projects\<folder>\<id>.jsonl
    await $.fs.write(
      [config, 'claude-accessibility', 'windows', `${id}.json`].join(sep),
      JSON.stringify({ title: text, name: convTitle, transcript: path }),
    )
  } catch {}
}

// Background work Claude started (commands and helper agents), by tool call id.
const background = new Set<string>()
function idleTitle($: any) {
  title($, background.size ? 'Claude is done, still working in the background' : 'Claude is done')
}
function backgroundChanged($: any) {
  try { $.ui.invalidate('ui.render') } catch {}
}

// While Claude waits on the person, the attention sound repeats every 6 seconds
// (for 10 minutes at most) until the question or prompt is dealt with.
let waiting: any = null
function startWaiting($: any, why: string) {
  if (waiting) return
  title($, why)
  sound($, 'attention')
  let count = 0
  try {
    waiting = $.clock.every(6000, () => {
      count++
      if (count > 100) stopWaiting($, false)
      else sound($, 'attention')
    })
  } catch {
    waiting = null
  }
}
function stopWaiting($: any, retitle: boolean) {
  if (waiting) {
    try { waiting.cancel() } catch {}
    waiting = null
    if (retitle) title($, 'Claude is working')
  }
}

// The conversation's name. Claude Code keeps it as the session title, which
// /rename sets and /resume lists. When a conversation has none, a short name is
// made from what the person asked (again after the 4th prompt, as the topic
// settles), shown at once, and saved as the session title with the next prompt.
let titleIsOwn = false      // set by the person or Claude Code, so never replaced
let savedTitle = ''         // the last name this mod saved
let pendingTitle = ''       // made, waiting for the next prompt to be saved
let prompts: string[] = []  // what the person typed this session
let naming = false
function clean(s: string) {
  return s.replace(/\s+/g, ' ').trim()
}
function setConvTitle($: any, t: string) {
  convTitle = clean(t).slice(0, 80)
  title($)
}
async function makeTitle($: any) {
  if (naming || titleIsOwn || !prompts.length) return
  naming = true
  try {
    const asked = prompts.slice(0, 6).map((p, i) => `Request ${i + 1}: ${p.slice(0, 1500)}`).join('\n\n')
    const r: any = await $.model.complete({
      model: 'haiku',
      maxTokens: 40,
      timeoutMs: 20000,
      prompt:
        'Name this conversation with Claude, from what the person asked so far. ' +
        'Write 3 to 7 plain words in sentence case that say what it is about, like "Fix the login page" or "Plan a trip to Rome". ' +
        'No quotes, no ending punctuation, no emoji. Reply with the name only.\n\n' + asked,
    })
    const t = r?.isAnswered ? clean(String(r.text)).replace(/^["'`]+|["'`.]+$/g, '').slice(0, 80) : ''
    if (t && !titleIsOwn) {
      pendingTitle = t
      setConvTitle($, t)
    }
  } catch {
  } finally {
    naming = false
  }
}

// Writing rules Claude reads in every conversation.
const SCREEN_READER_RULES = [
  'The person using this session is blind and uses a screen reader (such as NVDA or JAWS). Write for listening:',
  '- Put the answer or outcome first, in plain words.',
  '- No tables, ASCII art, diagrams, box-drawing characters or emoji. Use short paragraphs or simple lists instead.',
  '- Tool call lines are hidden from the person, so always say in your reply what you did and what you found. Never rely on tool output they cannot see.',
  '- Keep code and long file listings out of replies unless asked; describe them instead.',
  '- Spell out a symbol when it matters (say "backslash", not just show it).',
  '- The person can copy your last reply with the /copy command.',
].join('\n')

// Extra words for the working line, mixed in with Claude Code's own.
const EXTRA_WORDS = [
  'Faering', 'Paering', 'Pondering', 'Tinkering', 'Brewing', 'Noodling', 'Percolating',
  'Mulling', 'Conjuring', 'Whittling', 'Simmering', 'Rummaging', 'Puttering', 'Fiddling',
]
let engineWord = ''
let shownWord = ''

// /resume as plain text a screen reader can read: a numbered list of past
// conversations, newest first, or the ones that mention every word typed after
// /resume. "/resume 3" then opens number 3 of the last list.
type Conv = {
  id: string
  path: string
  mtime: number
  size: number
  cwd: string
  title: string
  first: string
  text: string // what the person and Claude wrote, lowercased, for searching
}
const convCache = new Map<string, Conv>()
let lastList: Conv[] = []
const CHUNK = 4 * 1024 * 1024
const MAX_TEXT = 400000

function messageText(content: any): string {
  if (typeof content === 'string') return content
  if (!Array.isArray(content)) return ''
  return content.filter((b: any) => b && b.type === 'text' && typeof b.text === 'string').map((b: any) => b.text).join('\n')
}

async function scanConv($: any, path: string, id: string, size: number, mtime: number): Promise<Conv> {
  const c: Conv = { id, path, mtime, size, cwd: '', title: '', first: '', text: '' }
  let custom = ''
  let ai = ''
  const parts: string[] = []
  let used = 0
  let carry = ''
  const take = (line: string) => {
    if (line.length < 20) return
    const head = line.slice(0, 400)
    const isTitle = head.includes('"type":"custom-title"') || head.includes('"type":"ai-title"')
    const isUser = head.includes('"type":"user"') && head.includes('"isSidechain":false')
    const isClaude = line.includes('"role":"assistant"') && head.includes('"isSidechain":false')
    if (!isTitle && !isUser && !isClaude) return
    let o: any
    try { o = JSON.parse(line) } catch { return }
    if (o.type === 'custom-title' && o.customTitle) custom = String(o.customTitle)
    else if (o.type === 'ai-title' && o.aiTitle) ai = String(o.aiTitle)
    else if (o.type === 'user' && !o.isMeta && o.message) {
      if (!c.cwd && o.cwd) c.cwd = String(o.cwd)
      const t = messageText(o.message.content).trim()
      if (!t || t.startsWith('<')) return
      // Short openers ("hi") say little, so take more prompts until there is enough.
      if (c.first.length < 40) c.first = c.first ? `${c.first}, then: ${clean(t)}` : clean(t)
      if (used < MAX_TEXT) { parts.push(t); used += t.length }
    } else if (o.type === 'assistant' && o.message) {
      const t = messageText(o.message.content).trim()
      if (t && used < MAX_TEXT) { parts.push(t); used += t.length }
    }
  }
  for (let offset = 0; offset < size; offset += CHUNK) {
    const piece: string = await $.fs.read(path, { offset, length: CHUNK })
    const lines = (carry + piece).split('\n')
    carry = lines.pop() ?? ''
    for (const line of lines) take(line)
  }
  take(carry)
  c.title = clean(custom || ai)
  c.text = (c.title + '\n' + parts.join('\n')).toLowerCase()
  return c
}

async function allConvs($: any): Promise<Conv[]> {
  const info = await $.session.info()
  const me = await $.session.id()
  const sep = info.transcriptPath.includes('\\') ? '\\' : '/'
  const projectDir = info.transcriptPath.slice(0, info.transcriptPath.lastIndexOf(sep))
  const projects = projectDir.slice(0, projectDir.lastIndexOf(sep))
  const found: Conv[] = []
  for (const d of await $.fs.list(projects)) {
    if (d.kind !== 'dir') continue
    let files: any[] = []
    try { files = await $.fs.list(projects + sep + d.name) } catch { continue }
    for (const f of files) {
      if (f.kind !== 'file' || !f.name.endsWith('.jsonl')) continue
      const id = f.name.slice(0, -6)
      if (id === me) continue
      const path = projects + sep + d.name + sep + f.name
      let c = convCache.get(path)
      if (!c || c.size !== f.size || c.mtime !== f.mtimeMs) {
        try { c = await scanConv($, path, id, f.size, f.mtimeMs) } catch { continue }
        convCache.set(path, c)
      }
      if (c.first || c.title) found.push(c)
    }
  }
  return found.sort((a, b) => b.mtime - a.mtime)
}

const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December']
function when(ms: number, now: number) {
  const d = new Date(ms)
  const day = (x: Date) => new Date(x.getFullYear(), x.getMonth(), x.getDate()).getTime()
  const days = Math.round((day(new Date(now)) - day(d)) / 86400000)
  const h = d.getHours()
  const time = `${h % 12 || 12}:${String(d.getMinutes()).padStart(2, '0')} ${h < 12 ? 'AM' : 'PM'}`
  if (days === 0) return `today at ${time}`
  if (days === 1) return `yesterday at ${time}`
  const date = `${MONTHS[d.getMonth()]} ${d.getDate()}`
  return d.getFullYear() === new Date(now).getFullYear() ? date : `${date}, ${d.getFullYear()}`
}

// A short piece of text around the first place the first word appears.
function snippet(c: Conv, word: string) {
  const i = c.text.indexOf(word)
  if (i < 0) return ''
  const start = Math.max(0, i - 60)
  return clean(c.text.slice(start, i + word.length + 90))
}

function folderName(cwd: string) {
  const parts = cwd.split(/[\\/]/).filter(Boolean)
  return parts[parts.length - 1] || cwd
}

const SHOW = 15

export const register: Register = on => {
  on('session.start', ($, e, next) => {
    background.clear()
    shownTitle = ''
    title($, 'Claude is ready')
    return next(e)
  }).catch(($, e, next) => next(e))

  // A new, cleared or resumed conversation: take its name, if it has one.
  on('classic.SessionStart', ($, e, next) => {
    prompts = []
    pendingTitle = ''
    savedTitle = ''
    const t = clean(String((e as any).session_title ?? ''))
    titleIsOwn = !!t
    setConvTitle($, t)
    return next(e)
  }).catch(($, e, next) => next(e))

  // Each prompt: pick up a name set elsewhere, or save the one this mod made.
  on('classic.UserPromptSubmit', async ($, e, next) => {
    const t = clean(String((e as any).session_title ?? ''))
    if (t && t !== savedTitle && t !== convTitle) {
      titleIsOwn = true
      pendingTitle = ''
      setConvTitle($, t)
    }
    const r: any = await next(e)
    if (pendingTitle && !titleIsOwn) {
      savedTitle = pendingTitle
      pendingTitle = ''
      return { ...r, sessionTitle: savedTitle }
    }
    return r
  }).catch(($, e, next) => next(e))

  // /rename names the conversation at once.
  on('command.run', { command: 'rename' }, async ($, e, next) => {
    const r = await next(e)
    const t = clean(e.args)
    if (t) {
      titleIsOwn = true
      pendingTitle = ''
      setConvTitle($, t)
    }
    return r
  }).catch(($, e, next) => next(e))

  on('command.run', { command: 'resume' }, async ($, e, next) => {
    const args = clean(e.args)
    // A conversation id, as Claude Code's own /resume takes it.
    if (/^[0-9a-f]{8}-[0-9a-f]{4}-/i.test(args)) return next(e)
    // A number from the last list.
    if (/^\d+$/.test(args)) {
      const c = lastList[Number(args) - 1]
      if (!c) {
        return {
          text: lastList.length
            ? `There is no number ${args} in the last list. Pick 1 to ${lastList.length}.`
            : 'Type /resume first to list your conversations, then /resume and a number.',
          isTextDisplayOnly: true,
        }
      }
      return next({ ...e, args: c.id })
    }
    const words = args.toLowerCase().split(' ').filter(Boolean)
    const now: number = await $.clock.now()
    const convs = await allConvs($)
    const hits = words.length ? convs.filter(c => words.every(w => c.text.includes(w))) : convs
    lastList = hits.slice(0, SHOW)
    if (!lastList.length) {
      return {
        text: words.length ? `No conversations mention ${args}.` : 'You have no other conversations yet.',
        isTextDisplayOnly: true,
      }
    }
    const here = clean(await $.session.root()).toLowerCase()
    const lines = [
      words.length
        ? `${hits.length} conversation${hits.length === 1 ? '' : 's'} mention ${args}` + (hits.length > SHOW ? `. The newest ${SHOW}:` : ':')
        : `Your ${lastList.length} newest conversations:`,
    ]
    lastList.forEach((c, i) => {
      const name = c.title || c.first.slice(0, 100)
      let line = `${i + 1}. ${name}. ${when(c.mtime, now)}`
      if (c.cwd && c.cwd.toLowerCase() !== here) line += `, in the folder ${folderName(c.cwd)}`
      line += '.'
      if (words.length) {
        const s = snippet(c, words[0] ?? '')
        if (s) line += ` "...${s}..."`
      }
      lines.push(line)
    })
    lines.push('Type /resume and a number to open one, such as /resume 1.')
    return { text: lines.join('\n'), isTextDisplayOnly: true }
  }).catch(($, e, next) => next(e))

  on('prompt.compose', async ($, e, next) => {
    const r = await next(e)
    return { sections: [...r.sections, { id: 'quiet-tools:screen-reader', text: SCREEN_READER_RULES, scope: 'session' }] }
  })

  // Working line: keep Claude Code's random word, now and then one of ours.
  // One pick per word Claude Code samples, so it never flickers.
  on('ui.render', { component: 'Spinner' }, ($, e, next) => {
    const w = e.props.word
    if (w !== engineWord) {
      engineWord = w
      shownWord = Math.random() < 0.3 ? (EXTRA_WORDS[Math.floor(Math.random() * EXTRA_WORDS.length)] ?? w) : w
    }
    return next({ ...e, props: { ...e.props, word: shownWord } })
  })

  // Done sound when Claude finishes a reply (not when a helper agent finishes).
  on('turn.complete', async ($, e, next) => {
    const r = await next(e)
    if (!e.agentId) {
      stopWaiting($, false)
      sound($, 'done')
      idleTitle($)
    }
    return r
  })

  // Questions and plan approvals: repeat until answered (by the person, or by
  // Claude Code itself after the person has been away). Any other tool call
  // finishing means a permission prompt for it was answered.
  // Calls sent to the background are remembered until their notice arrives.
  // If a sound hook ever fails, the call still goes through.
  on('tool.call', async ($, e, next) => {
    if (e.tool === 'AskUserQuestion') startWaiting($, 'Claude has a question for you')
    else if (e.tool === 'ExitPlanMode') startWaiting($, 'Claude needs your plan approval')
    const isBackground = (e as any).run_in_background === true
    try {
      const r: any = await next(e)
      if (isBackground && e.tool_use_id && !r?.deny && !r?.isError) {
        background.add(e.tool_use_id)
        backgroundChanged($)
      }
      return r
    } finally {
      stopWaiting($, true)
    }
  }).catch(($, e, next) => next(e))

  // Permission prompts and other dialogs that wait on the person.
  on('classic.Notification', ($, e, next) => {
    if (e.notification_type === 'permission_prompt') startWaiting($, 'Claude needs your permission')
    else if (e.notification_type === 'elicitation_dialog') startWaiting($, 'Claude needs your answer')
    return next(e)
  }).catch(($, e, next) => next(e))
  on('classic.PermissionDenied', ($, e, next) => {
    stopWaiting($, true)
    return next(e)
  }).catch(($, e, next) => next(e))

  // Something new to do: the person typed, or a background job reported back.
  on('prompt.submit', ($, e, next) => {
    const kind = (e as any).origin?.kind
    if (kind === 'task-notification') {
      const ids = String(e.text).match(/<tool-use-id>([^<]+)<\/tool-use-id>/g) || []
      for (const m of ids) background.delete(m.replace(/<\/?tool-use-id>/g, '').trim())
      backgroundChanged($)
    } else if (kind === 'composer' || kind === 'bridge') {
      stopWaiting($, false)
      const typed = clean(String(e.text))
      if (typed && !typed.startsWith('/')) {
        prompts.push(typed)
        if (!titleIsOwn && (prompts.length === 1 || prompts.length === 4)) void makeTitle($)
      }
    }
    title($, 'Claude is working')
    return next(e)
  }).catch(($, e, next) => next(e))

  // A single tool call row: hide it unless it asks a question or the view is expanded (ctrl+o).
  on('ui.render', { component: 'ToolUse' }, ($, e, next) => {
    const p = e.props
    if (p.isExpanded || ASKS.has(p.tool)) return next(e)
    const { Box } = $.ui.resolve(e)
    return <Box />
  })

  // The result block under a tool row.
  on('ui.render', { component: 'ToolResult' }, ($, e, next) => {
    const p = e.props
    if (p.isExpanded || ASKS.has(p.tool)) return next(e)
    const { Box } = $.ui.resolve(e)
    return <Box />
  })

  // Grouped calls ("Read 1 file").
  on('ui.render', { component: 'ToolGroup' }, ($, e, next) => {
    const p = e.props
    if (p.isExpanded || p.calls.some(c => ASKS.has(c.tool))) return next(e)
    const { Box } = $.ui.resolve(e)
    return <Box />
  })

  // The "(ctrl+b to run in background)" hint under a running call.
  on('ui.render', { component: 'ToolProgress' }, ($, e, next) =>
    next({ ...e, props: { ...e.props, hint: '' } }),
  )

  // The hint under the prompt ("(shift+tab to cycle)", "esc to interrupt").
  // The "auto mode on" and "/rc" labels are drawn elsewhere; mods cannot reach them.
  on('ui.render', { component: 'PromptHint' }, ($, e) => {
    const { Box } = $.ui.resolve(e)
    return <Box />
  })

  // The line that ends each reply ("Churned for 1s") becomes "Done.", or says
  // so when work is still running in the background.
  // The "Waiting for background agents" form and ctrl+o keep the engine's line.
  on('ui.render', { component: 'TurnDuration' }, ($, e, next) => {
    const p = e.props
    if (p.isExpanded || p.waitingFor) return next(e)
    const { Text } = $.ui.resolve(e)
    return <Text dimColor>{background.size ? 'Done. Still working in the background.' : 'Done.'}</Text>
  })

  // The mode labels at the right of the prompt footer.
  on('ui.render', { component: 'SessionMode' }, ($, e, next) =>
    next({ ...e, props: { ...e.props, modes: [] } }),
  )
}
'@
        # Check the new files in a temporary copy first, so a failed check never
        # replaces a mod that already works. This also checks Claude Code can run mods.
        $stage = Join-Path ([IO.Path]::GetTempPath()) ('claude-accessibility-' + [Guid]::NewGuid().ToString('N'))
        $stageMod = Join-Path $stage 'quiet-tools'
        try {
            foreach ($d in @("$stageMod\.claude-plugin", "$stageMod\hooks")) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
            foreach ($k in $files.Keys) {
                if ($k.StartsWith($mod + '\')) { [IO.File]::WriteAllText($stageMod + $k.Substring($mod.Length), ($files[$k] -replace "`r`n", "`n"), $enc) }
            }
            $check = Invoke-Tool $claude @('plugin', 'validate', $stageMod) 120
        } finally {
            Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($check.Code -ne 0) {
            Say 'Your Claude Code is too old for this mod, or could not check it. Nothing about the mod was changed.'
            Say 'Run "claude update" in a terminal, then run this file again. Claude Code said:'
            Say $check.Out
            $failed++
        } else {
            foreach ($k in $files.Keys) { Write-Text $k ($files[$k] -replace "`r`n", "`n") }
            Get-ChildItem -LiteralPath $mkt -Recurse -Filter ('*' + $backupSuffix) -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
            $add = Invoke-Tool $claude @('plugin', 'marketplace', 'add', $mkt) 120
            $inst = Invoke-Tool $claude @('plugin', 'install', 'quiet-tools@claude-accessibility') 180
            if ($inst.Code -eq 0) {
                $null = Invoke-Tool $claude @('plugin', 'enable', 'quiet-tools@claude-accessibility') 60
                # An earlier install recorded an older version; this records the new one.
                $null = Invoke-Tool $claude @('plugin', 'update', 'quiet-tools@claude-accessibility') 120
                if ($inst.Out -match 'already installed') { Say 'The quiet-tools mod was already installed. Its files were refreshed.' }
                else { Say 'The quiet-tools mod was installed. Tool call lines are now hidden; press Ctrl+O to see them.' }
                Say 'Tip: type /copy in Claude Code to copy its last reply to the clipboard.'
                Say 'Type /resume to hear your newest conversations, or /resume and some words to search them.'
                $modReady = $true
            } else {
                Say 'The quiet-tools mod could not be installed. Claude Code said:'
                if ($add.Code -ne 0) { Say $add.Out }
                Say $inst.Out
                $failed++
            }
        }
    } catch {
        Say ('The quiet-tools mod could not be set up: ' + $_.Exception.Message)
        $failed++
    }

    # Two short sounds, made here so this stays a single file. If this part fails,
    # the mod still works, just without sounds.
    # Soft chords, notes rolled in one after another like a gentle strum.
    # done: a full C major chord (resolved). attention: a G7 chord (unresolved, a question).
    # Each note is @(start pitch, end pitch, start ms, length ms). $peak sets the loudness.
    if ($modReady) {
        try {
            function New-Wav($file, $notes, $peak) {
                $rate = 44100
                $total = 0
                foreach ($n in $notes) { $total = [Math]::Max($total, [int]($rate * ($n[2] + $n[3]) / 1000)) }
                $total += [int]($rate * 0.02)
                $mix = New-Object double[] $total
                foreach ($n in $notes) {
                    $f0 = $n[0]; $f1 = $n[1]; $start = [int]($rate * $n[2] / 1000); $len = [int]($rate * $n[3] / 1000)
                    $attack = $rate * 0.012
                    $phase = 0.0
                    for ($i = 0; $i -lt $len; $i++) {
                        $x = $i / $len
                        $freq = $f1 - ($f1 - $f0) * [Math]::Exp(-9 * $x)
                        $phase += 2 * [Math]::PI * $freq / $rate
                        $rise = if ($i -lt $attack) { 0.5 - 0.5 * [Math]::Cos([Math]::PI * $i / $attack) } else { 1 }
                        $fall = [Math]::Exp(-4 * $x) * (1 - $x)
                        $mix[$start + $i] += $rise * $fall * ([Math]::Sin($phase) + 0.12 * [Math]::Sin(2 * $phase))
                    }
                }
                $max = 0.0001
                foreach ($x in $mix) { if ([Math]::Abs($x) -gt $max) { $max = [Math]::Abs($x) } }
                $ms = New-Object IO.MemoryStream
                $w = New-Object IO.BinaryWriter($ms)
                $data = $total * 2
                $w.Write([Text.Encoding]::ASCII.GetBytes('RIFF')); $w.Write([int](36 + $data))
                $w.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt ')); $w.Write([int]16)
                $w.Write([int16]1); $w.Write([int16]1); $w.Write([int]$rate); $w.Write([int]($rate * 2))
                $w.Write([int16]2); $w.Write([int16]16)
                $w.Write([Text.Encoding]::ASCII.GetBytes('data')); $w.Write([int]$data)
                foreach ($x in $mix) { $w.Write([int16]($x / $max * $peak * 32767)) }
                $w.Flush()
                [IO.File]::WriteAllBytes($file, $ms.ToArray())
            }
            New-Wav "$mod\sounds\done.wav" @(@(261.63, 261.63, 0, 500), @(392.00, 392.00, 15, 485), @(523.25, 523.25, 30, 470), @(659.25, 659.25, 45, 455), @(783.99, 783.99, 60, 440)) 0.15
            New-Wav "$mod\sounds\attention.wav" @(@(392.00, 392.00, 0, 375), @(493.88, 493.88, 15, 360), @(587.33, 587.33, 30, 345), @(698.46, 698.46, 45, 330)) 0.15
            Say 'Sounds are on: a soft chord when Claude finishes, and another that repeats while it waits for you.'
        } catch {
            Say ('The mod works, but its sounds could not be made: ' + $_.Exception.Message)
            $failed++
        }

        # The window title helper, built here from source with the C# compiler that
        # comes with Windows. It runs on any processor (ARM, Intel, AMD).
        try {
            $csc = $null
            foreach ($c in @(
                "$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
                "$env:SystemRoot\Microsoft.NET\Framework\v4.0.30319\csc.exe"
            )) { if (Test-Path -LiteralPath $c) { $csc = $c; break } }
            if (-not $csc) { throw 'the C# compiler that comes with Windows (.NET Framework 4) was not found' }
            $buildDir = Join-Path ([IO.Path]::GetTempPath()) ('claude-accessibility-' + [Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $buildDir | Out-Null
            try {
                [IO.File]::WriteAllText("$buildDir\settitle.cs", @'
using System;
using System.Runtime.InteropServices;

// Sets the title of the console window of the program that started this one
// (Claude Code), or of the process id given second.
static class SetTitle
{
    [DllImport("kernel32.dll")] static extern bool FreeConsole();
    [DllImport("kernel32.dll")] static extern bool AttachConsole(int processId);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool SetConsoleTitleW(string title);

    static int Main(string[] args)
    {
        if (args.Length < 1) return 2;
        int pid = -1;
        if (args.Length > 1 && !int.TryParse(args[1], out pid)) return 2;
        FreeConsole();
        if (!AttachConsole(pid)) return 3;
        return SetConsoleTitleW(args[0]) ? 0 : 4;
    }
}
'@, $enc)
                $build = Invoke-Tool $csc @('/nologo', '/target:winexe', '/platform:anycpu', '/optimize', "/out:$buildDir\settitle.exe", "$buildDir\settitle.cs") 120
                if ($build.Code -ne 0 -or -not (Test-Path -LiteralPath "$buildDir\settitle.exe")) { throw ('the compiler said: ' + $build.Out) }
                $dest = Join-Path $mod 'settitle.exe'
                for ($n = 1; ; $n++) {
                    try { Copy-Item -LiteralPath "$buildDir\settitle.exe" -Destination $dest -Force; break }
                    catch { if ($n -ge 8) { throw }; Start-Sleep -Milliseconds 500 }
                }
            } finally {
                Remove-Item -LiteralPath $buildDir -Recurse -Force -ErrorAction SilentlyContinue
            }
            Say 'Window titles are on: the title says when Claude is working, done, or needs you.'
        } catch {
            Say ('The mod works, but window titles could not be set up: ' + $_.Exception.Message)
            $failed++
        }
    }
}

# ---------------------------------------------------------------- Part 3: the Windows Terminal bell
# Screen reader mode rings the bell at the end of every reply. Only bellStyle is
# changed; the rest of each file is left exactly as it was.
Say ''
$wtFound = $false
$bellTurnedOff = 0
$bellAlreadyOff = 0
# Store and Preview installs keep settings in their package folder. A non-Store copy
# uses the last folder, but only when it already has a settings file there (the
# Store version also uses that folder, for add-on profiles only).
$wtPlaces = @(
    @{ Pkg = "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe"; File = "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"; Create = $true },
    @{ Pkg = "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe"; File = "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json"; Create = $true },
    @{ Pkg = "$env:LOCALAPPDATA\Microsoft\Windows Terminal\settings.json"; File = "$env:LOCALAPPDATA\Microsoft\Windows Terminal\settings.json"; Create = $false }
)
foreach ($place in $wtPlaces) {
    $wf = $place.File
    try {
        if (-not (Test-Path -LiteralPath $place.Pkg)) { continue }
        $wtFound = $true
        if (-not (Test-Path -LiteralPath $wf)) {
            if (-not $place.Create) { continue }
            # Installed but never opened: start a settings file with just the bell off.
            $parent = Split-Path $wf
            if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            Write-Text $wf "{`n    `"profiles`": {`n        `"defaults`": {`n            `"bellStyle`": `"none`"`n        }`n    }`n}`n"
            $bellTurnedOff++
            continue
        }
        $text = Read-Text $wf
        $current = $null
        $parsed = $false
        try { $j = $text | ConvertFrom-Json; $parsed = $true; $current = $j.profiles.defaults.bellStyle } catch {}
        $new = $null
        if ($current -is [string] -and $current -eq 'none') {
            $bellAlreadyOff++
            continue
        } elseif ($text -notmatch '"defaults"\s*:' -and $text -match '"profiles"\s*:\s*\{') {
            $new = [regex]::Replace($text, '("profiles"\s*:\s*\{)', '$1 "defaults": { "bellStyle": "none" },', 1)
        } elseif ($text -match '"defaults"\s*:\s*\{\s*\}') {
            $new = [regex]::Replace($text, '"defaults"\s*:\s*\{\s*\}', '"defaults": { "bellStyle": "none" }', 1)
        } elseif (($parsed -and $null -eq $current) -or (-not $parsed -and $text -notmatch '"bellStyle"')) {
            $new = [regex]::Replace($text, '("defaults"\s*:\s*\{)', '$1 "bellStyle": "none",', 1)
        } elseif ($parsed) {
            $new = [regex]::Replace($text, '("defaults"\s*:\s*\{[^{}]*?"bellStyle"\s*:\s*)("[^"]*"|\[[^\]]*\])', '$1"none"', 1)
        }
        if ($new -and $new -ne $text -and $parsed) {
            # Make sure the result still reads, and the bell really is off in it.
            try { $chk = $new | ConvertFrom-Json; if ($chk.profiles.defaults.bellStyle -ne 'none') { $new = $null } } catch { $new = $null }
        }
        if (-not $new -or $new -eq $text) {
            Say 'The Windows Terminal bell could not be changed automatically.'
            Say 'In Windows Terminal, open Settings, then Defaults, then Advanced, and set Bell notification style to none.'
            $failed++
            continue
        }
        Write-Text $wf $new
        $bellTurnedOff++
    } catch {
        Say ('The Windows Terminal bell could not be changed: ' + $_.Exception.Message)
        Say 'In Windows Terminal, open Settings, then Defaults, then Advanced, and set Bell notification style to none.'
        $failed++
    }
}
if ($bellTurnedOff -gt 0) { Say 'The Windows Terminal bell was turned off.' } elseif ($bellAlreadyOff -gt 0) { Say 'The Windows Terminal bell was already off.' }
if (-not $wtFound) {
    Say 'Windows Terminal is not installed, so the bell setting was skipped.'
    Say 'If you hear a bell after each reply, install Windows Terminal from the Microsoft Store and run this again.'
}

# ---------------------------------------------------------------- Part 4: the Console Redraw Fix add-on for NVDA
# Claude Code sometimes wipes the console and draws it again, and NVDA then reads
# the whole screen from the top. This add-on stops that. It is downloaded from
# GitHub each time, and installed or updated when GitHub has a newer version.
# If the person removed it from NVDA, it is not put back.
Say ''
$nvdaRestart = $null
$addonName = 'consoleRedrawFix'
$addonBase = 'https://raw.githubusercontent.com/ce2004/accessible-claude-code/main/console-redraw-fix/'
$addonFiles = @('manifest.ini', 'globalPlugins/consoleRedrawFix.py')
$nvdaConfig = Join-Path $env:APPDATA 'nvda'
$addonDir = Join-Path $nvdaConfig "addons\$addonName"
$addonMark = Join-Path $dir 'claude-accessibility\nvda-addon-installed.txt'

function Get-Download([string]$url) {
    $req = [Net.WebRequest]::Create($url)
    $req.Timeout = 15000
    if ($req -is [Net.HttpWebRequest]) {
        $req.ReadWriteTimeout = 15000
        $req.UserAgent = 'claude-accessibility-updater'
        $req.CachePolicy = New-Object Net.Cache.RequestCachePolicy([Net.Cache.RequestCacheLevel]::NoCacheNoStore)
    }
    $resp = $req.GetResponse()
    try {
        $ms = New-Object IO.MemoryStream
        $resp.GetResponseStream().CopyTo($ms)
        return , $ms.ToArray()
    } finally { $resp.Close() }
}
# Reads one value, such as version, from an add-on manifest.
function Get-ManifestValue([string]$text, [string]$key) {
    $m = [regex]::Match($text, '(?m)^\s*' + $key + '\s*=\s*"?([^"\r\n]*?)"?\s*$')
    if ($m.Success) { return $m.Groups[1].Value } else { return $null }
}
function ConvertTo-Version([string]$v) {
    $m = [regex]::Match([string]$v, '^\s*(\d+)(\.\d+)?(\.\d+)?')
    if (-not $m.Success) { return $null }
    $parts = @($m.Groups[1].Value, ($m.Groups[2].Value.TrimStart('.')), ($m.Groups[3].Value.TrimStart('.'))) | ForEach-Object { if ($_) { $_ } else { '0' } }
    return [version]($parts -join '.')
}

try {
    # The NVDA that is running, or else the installed one.
    $nvdaExe = $null
    try { $nvdaExe = (Get-Process -Name nvda -ErrorAction SilentlyContinue | Where-Object { $_.Path } | Select-Object -First 1).Path } catch {}
    if (-not $nvdaExe) {
        foreach ($key in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\NVDA', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\NVDA')) {
            try {
                $u = (Get-ItemProperty -LiteralPath $key -ErrorAction Stop).UninstallDirectory
                if ($u -and (Test-Path -LiteralPath (Join-Path $u 'nvda.exe'))) { $nvdaExe = Join-Path $u 'nvda.exe'; break }
            } catch {}
        }
    }
    $nvdaRunning = [bool](Get-Process -Name nvda -ErrorAction SilentlyContinue)
    $installedText = if (Test-Path -LiteralPath "$addonDir\manifest.ini") { Read-Text "$addonDir\manifest.ini" } else { $null }

    if (-not $nvdaExe -and -not (Test-Path -LiteralPath $nvdaConfig)) {
        Say 'NVDA is not installed, so the Console Redraw Fix add-on was skipped. It is only for NVDA.'
    } elseif (-not $installedText -and (Test-Path -LiteralPath $addonMark)) {
        Say 'The Console Redraw Fix add-on was removed from NVDA earlier, so it was not put back.'
        Say 'To get it back, see How to undo it in the readme.'
    } else {
        # Download it into a temporary folder and check it before touching NVDA.
        $stage = Join-Path ([IO.Path]::GetTempPath()) ('claude-accessibility-' + [Guid]::NewGuid().ToString('N'))
        try {
            foreach ($f in $addonFiles) {
                $target = Join-Path $stage ($f -replace '/', '\')
                $parent = Split-Path $target
                if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
                try { $data = Get-Download ($addonBase + $f) }
                catch { throw 'it could not be downloaded from GitHub. Check that you are online, then run this again.' }
                [IO.File]::WriteAllBytes($target, $data)
            }
            $newText = Read-Text "$stage\manifest.ini"
            if ((Get-ManifestValue $newText 'name') -ne $addonName) { throw 'the downloaded add-on did not look right' }
            $newVersion = ConvertTo-Version (Get-ManifestValue $newText 'version')
            $minNvda = ConvertTo-Version (Get-ManifestValue $newText 'minimumNVDAVersion')
            $oldVersion = if ($installedText) { ConvertTo-Version (Get-ManifestValue $installedText 'version') } else { $null }
            $nvdaVersion = $null
            if ($nvdaExe) { try { $nvdaVersion = ConvertTo-Version ([Diagnostics.FileVersionInfo]::GetVersionInfo($nvdaExe).ProductVersion) } catch {} }

            if (-not $newVersion) {
                throw 'the downloaded add-on has no version number'
            } elseif ($oldVersion -and $oldVersion -ge $newVersion) {
                Say ('The Console Redraw Fix add-on for NVDA is already up to date (version ' + $oldVersion + ').')
            } elseif ($nvdaVersion -and $minNvda -and $nvdaVersion -lt $minNvda) {
                Say ('The Console Redraw Fix add-on needs NVDA ' + $minNvda + ' or newer, and this PC has NVDA ' + $nvdaVersion + ', so it was skipped.')
                Say 'Update NVDA, then run this again.'
                $failed++
            } else {
                # Swap the folders, keeping the old one until the new one is in place.
                $addonsRoot = Split-Path $addonDir
                if (-not (Test-Path -LiteralPath $addonsRoot)) { New-Item -ItemType Directory -Path $addonsRoot -Force | Out-Null }
                $old = $addonDir + '.old-claude-accessibility'
                if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Recurse -Force }
                if (Test-Path -LiteralPath $addonDir) { Move-Item -LiteralPath $addonDir -Destination $old }
                try {
                    Copy-Item -LiteralPath $stage -Destination $addonDir -Recurse
                } catch {
                    if (Test-Path -LiteralPath $addonDir) { Remove-Item -LiteralPath $addonDir -Recurse -Force -ErrorAction SilentlyContinue }
                    if (Test-Path -LiteralPath $old) { Move-Item -LiteralPath $old -Destination $addonDir }
                    throw
                }
                if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Recurse -Force -ErrorAction SilentlyContinue }
                if ($oldVersion) { Say ('The Console Redraw Fix add-on for NVDA was updated to version ' + $newVersion + '.') }
                else { Say 'The Console Redraw Fix add-on for NVDA was installed. NVDA now reads only new lines when Claude Code redraws the screen.' }
                $nvdaRestart = 'to load the Console Redraw Fix add-on'
            }
        } finally {
            Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    # Remember that it was installed, so removing it in NVDA is respected later.
    if (Test-Path -LiteralPath "$addonDir\manifest.ini") {
        $markDir = Split-Path $addonMark
        if (-not (Test-Path -LiteralPath $markDir)) { New-Item -ItemType Directory -Path $markDir -Force | Out-Null }
        [IO.File]::WriteAllText($addonMark, "The Console Redraw Fix add-on was installed in NVDA. Delete this file to have it put back.`r`n", $enc)
    }
} catch {
    Say ('The Console Redraw Fix add-on could not be set up: ' + $_.Exception.Message)
    $failed++
}

# ---------------------------------------------------------------- Finish
Say ''
if ($failed -eq 0) {
    Say 'All done. If Claude Code is open, close it and start it again.'
} else {
    Say ('Finished, but ' + $failed + ' step(s) need attention; see the messages above.')
    Say 'Everything else was set up. If Claude Code is open, close it and start it again.'
}
if ($nvdaRestart) {
    Say ''
    if (-not $nvdaRunning -or -not $nvdaExe) {
        Say ('Restart NVDA ' + $nvdaRestart + '.')
    } else {
        Say ('NVDA needs to restart ' + $nvdaRestart + '. Press R to restart it now, or any other key to restart it yourself later.')
        $key = $null
        try { $key = [Console]::ReadKey($true) } catch {}
        if ($key -and $key.Key -eq [ConsoleKey]::R) {
            try {
                Start-Process -FilePath $nvdaExe -ArgumentList '-r'
                Say 'NVDA is restarting.'
            } catch {
                Say ('NVDA could not be restarted: ' + $_.Exception.Message + ' Restart it yourself.')
            }
        } else {
            Say 'Restart NVDA when you are ready.'
        }
    }
}
if ($failed -gt 0) { exit 2 }
