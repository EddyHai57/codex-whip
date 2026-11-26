[CmdletBinding()]
param(
    [string]$Cd = (Get-Location).Path,
    [string]$Model = $(if ($env:CODEX_WHIP_DEFAULT_MODEL) { $env:CODEX_WHIP_DEFAULT_MODEL } else { "gpt-6.2-sol" }),
    [ValidateSet("low", "medium", "high", "xhigh")]
    [string]$Effort = $(if ($env:CODEX_WHIP_DEFAULT_EFFORT) { $env:CODEX_WHIP_DEFAULT_EFFORT } else { "high" }),
    [int]$Timeout = $(if ($env:CODEX_WHIP_TIMEOUT) { [int]$env:CODEX_WHIP_TIMEOUT } else { 600 }),
    [string]$Prompt = "",
    [string]$PromptFile = "",
    [string[]]$Image = @(),
    [string]$Out = "",
    [switch]$Persist,
    [string]$Label = "-",
    [string]$Resume = "",
    [string]$Delete = "",
    [string]$Archive = "",
    [switch]$ListSessions,
    [switch]$CleanupAll,
    [switch]$Worktree,
    [switch]$Yolo
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SchemaPath = Join-Path (Split-Path -Parent $ScriptDir) "resources\result.schema.json"
$StateDir = if ($env:CODEX_WHIP_HOME) { $env:CODEX_WHIP_HOME } else { Join-Path $HOME ".codex-whip" }
$LedgerPath = Join-Path $StateDir "sessions.tsv"
$LatestLogPath = Join-Path $env:TEMP "codex-whip-latest.log"
$CdExplicit = $PSBoundParameters.ContainsKey("Cd")

switch ($Model) {
    "sol" { $Model = "gpt-6.2-sol" }
    "astra" { $Model = "gpt-6.2-astra" }
}
if ($Worktree) { $Persist = $true }

function Resolve-CodexBin {
    if ($env:CODEX_BIN -and (Test-Path $env:CODEX_BIN)) { return $env:CODEX_BIN }
    $cmd = Get-Command codex -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidates = @(
        (Join-Path $env:APPDATA "npm\codex.cmd"),
        (Join-Path $env:LOCALAPPDATA "Programs\codex\codex.exe")
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { return $c }
    }
    throw "Codex CLI not found. Put 'codex' in PATH or set `$env:CODEX_BIN."
}

function Test-IsUuid([string]$Value) {
    return $Value -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
}

function Get-LedgerRows {
    if (-not (Test-Path $LedgerPath)) { return @() }
    $rows = @()
    foreach ($line in Get-Content -Path $LedgerPath -Encoding UTF8) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line -split "`t"
        if ($parts.Count -ge 5) {
            $rows += [pscustomobject]@{
                Timestamp = $parts[0]
                SessionId = $parts[1]
                Workdir   = $parts[2]
                Mode      = $parts[3]
                Label     = $parts[4]
            }
        }
    }
    return $rows
}

function Remove-LedgerEntry([string]$SessionId) {
    if (-not (Test-Path $LedgerPath)) { return }
    $kept = Get-LedgerRows | Where-Object { $_.SessionId -ne $SessionId }
    $lines = $kept | ForEach-Object { "$($_.Timestamp)`t$($_.SessionId)`t$($_.Workdir)`t$($_.Mode)`t$($_.Label)" }
    Set-Content -Path $LedgerPath -Value $lines -Encoding UTF8
}

function Add-LedgerEntry([string]$SessionId, [string]$Workdir, [string]$Mode, [string]$Note) {
    if ([string]::IsNullOrWhiteSpace($SessionId)) { return }
    New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
    Remove-LedgerEntry $SessionId
    $cleanNote = ($Note -replace "[\t\r\n]", " ").Trim()
    if (-not $cleanNote) { $cleanNote = "-" }
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $LedgerPath -Value "$ts`t$SessionId`t$Workdir`t$Mode`t$cleanNote" -Encoding UTF8
}

function Resolve-SessionRef([string]$Ref, [bool]$RequireUuid = $false) {
    $rows = @(Get-LedgerRows)
    if (Test-IsUuid $Ref) {
        $hit = $rows | Where-Object { $_.SessionId -eq $Ref } | Select-Object -First 1
        return [pscustomobject]@{ Id = $Ref; Workdir = if ($hit) { $hit.Workdir } else { "" } }
    }
    $q = $Ref.Trim().ToLowerInvariant()
    $exact = @($rows | Where-Object { $_.Label.Trim().ToLowerInvariant() -eq $q })
    $chosen = if ($exact.Count -gt 0) { $exact } else { @($rows | Where-Object { $_.Label.Trim().ToLowerInvariant().Contains($q) }) }
    if ($chosen.Count -eq 1) {
        return [pscustomobject]@{ Id = $chosen[0].SessionId; Workdir = $chosen[0].Workdir }
    }
    if ($chosen.Count -gt 1) {
        Write-Error ("Ambiguous session name '{0}'. Matches:`n{1}" -f $Ref, (($chosen | ForEach-Object { "$($_.SessionId)`t$($_.Label)`t$($_.Workdir)" }) -join "`n"))
        exit 2
    }
    if ($RequireUuid) {
        Write-Error "Session '$Ref' not found in $LedgerPath (codex delete --force requires a UUID)."
        exit 2
    }
    return [pscustomobject]@{ Id = $Ref; Workdir = "" }
}

if ($ListSessions) {
    $rows = @(Get-LedgerRows)
    if ($rows.Count -eq 0) {
        Write-Output "(no active tracked sessions)"
        exit 0
    }
    Write-Output "TIMESTAMP`tSESSION_ID`tWORKDIR`tMODE`tLABEL"
    foreach ($r in $rows) {
        Write-Output "$($r.Timestamp)`t$($r.SessionId)`t$($r.Workdir)`t$($r.Mode)`t$($r.Label)"
    }
    exit 0
}

$CodexBin = Resolve-CodexBin

if ($CleanupAll) {
    $rows = @(Get-LedgerRows)
    if ($rows.Count -eq 0) {
        Write-Output "No active tracked sessions to clean up."
        exit 0
    }
    $deleted = 0; $failed = 0
    foreach ($r in $rows) {
        & $CodexBin delete --force $r.SessionId
        if ($LASTEXITCODE -eq 0) {
            Remove-LedgerEntry $r.SessionId
            $deleted++
        } else {
            $failed++
        }
    }
    Write-Output "cleanup_deleted=$deleted cleanup_failed=$failed"
    exit $(if ($failed -eq 0) { 0 } else { 1 })
}

if ($Delete) {
    $res = Resolve-SessionRef -Ref $Delete -RequireUuid $true
    & $CodexBin delete --force $res.Id
    $rc = $LASTEXITCODE
    if ($rc -eq 0) { Remove-LedgerEntry $res.Id }
    exit $rc
}

if ($Archive) {
    $res = Resolve-SessionRef -Ref $Archive -RequireUuid $false
    & $CodexBin archive $res.Id
    $rc = $LASTEXITCODE
    if ($rc -eq 0) { Remove-LedgerEntry $res.Id }
    exit $rc
}

if ($PromptFile -and $Prompt) { throw "Specify either -Prompt or -PromptFile, not both." }
if ($PromptFile) {
    if (-not (Test-Path $PromptFile)) { throw "Prompt file not found: $PromptFile" }
    $Prompt = Get-Content -Path $PromptFile -Raw -Encoding UTF8
}
if ([string]::IsNullOrWhiteSpace($Prompt)) { throw "Empty prompt. Pass -Prompt or -PromptFile." }
foreach ($img in $Image) {
    if (-not (Test-Path $img)) { throw "Image file not found: $img" }
}

$ResumeId = ""
if ($Resume) {
    $res = Resolve-SessionRef -Ref $Resume -RequireUuid $false
    $ResumeId = $res.Id
    if (-not $CdExplicit -and $res.Workdir -and (Test-Path $res.Workdir)) {
        $Cd = $res.Workdir
    }
}

$RunId = [guid]::NewGuid().ToString("N").Substring(0, 8)
$RunDir = Join-Path $env:TEMP "codex-whip-$RunId"
New-Item -ItemType Directory -Path $RunDir -Force | Out-Null
$LogFile = Join-Path $RunDir "raw.log"
$OutFile = if ($Out) { $Out } else { Join-Path $RunDir "result.json" }

$CmdArgs = @()
if ($ResumeId) {
    $CmdArgs += @("exec", "resume", "--skip-git-repo-check", "-m", $Model, "-c", "model_reasoning_effort=`"$Effort`"", "--output-schema", $SchemaPath, "-o", $OutFile)
    foreach ($img in $Image) { $CmdArgs += @("-i", $img) }
    if ($Worktree) { $CmdArgs += "--worktree" }
    if ($Yolo) { $CmdArgs += "--dangerously-bypass-approvals-and-sandbox" }
    $CmdArgs += @($ResumeId, $Prompt)
} else {
    $CmdArgs += @("exec", "--skip-git-repo-check", "--color", "never", "-m", $Model, "-c", "model_reasoning_effort=`"$Effort`"", "--cd", $Cd, "--output-schema", $SchemaPath, "-o", $OutFile)
    foreach ($img in $Image) { $CmdArgs += @("-i", $img) }
    if ($Worktree) { $CmdArgs += "--worktree" }
    if (-not $Persist) { $CmdArgs += "--ephemeral" }
    if ($Yolo) { $CmdArgs += "--dangerously-bypass-approvals-and-sandbox" } else { $CmdArgs += @("-s", "workspace-write") }
    $CmdArgs += @("--", $Prompt)
}

$Start = Get-Date
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $CodexBin
$psi.WorkingDirectory = $Cd
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
$psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
foreach ($a in $CmdArgs) { [void]$psi.ArgumentList.Add($a) }

$proc = New-Object System.Diagnostics.Process
$proc.StartInfo = $psi
Set-Content -Path $LatestLogPath -Value "" -Encoding UTF8
[void]$proc.Start()

$stdOutTask = $proc.StandardOutput.ReadToEndAsync()
$stdErrTask = $proc.StandardError.ReadToEndAsync()

$timedOut = $false
if ($Timeout -gt 0) {
    if (-not $proc.WaitForExit($Timeout * 1000)) {
        $timedOut = $true
        try { $proc.Kill($true) } catch {}
    }
} else {
    $proc.WaitForExit()
}

$combined = $stdOutTask.GetAwaiter().GetResult() + "`n" + $stdErrTask.GetAwaiter().GetResult()
if ($timedOut) { $combined += "`n[codex-whip] TIMEOUT after ${Timeout}s; process tree terminated.`n" }
Set-Content -Path $LogFile -Value $combined -Encoding UTF8
Set-Content -Path $LatestLogPath -Value $combined -Encoding UTF8

$RC = if ($timedOut) { 124 } else { $proc.ExitCode }
$Duration = [int]((Get-Date) - $Start).TotalSeconds

$SessionId = if ($combined -match '(?m)^session id:\s*(\S+)') { $Matches[1].Trim() } elseif ($ResumeId) { $ResumeId } else { "" }
$CodexWorkdir = if ($combined -match '(?m)^workdir:\s*(.+)$') { $Matches[1].Trim() } else { "" }
$TokensUsed = if ($combined -match '(?m)^tokens used\r?\n\s*([^\r\n]+)') { $Matches[1].Trim() } else { "unknown" }

if ($Persist -and -not $ResumeId -and $SessionId) {
    $modeTag = if ($Worktree) { "worktree" } else { "persist" }
    Add-LedgerEntry -SessionId $SessionId -Workdir $(if ($CodexWorkdir) { $CodexWorkdir } else { $Cd }) -Mode $modeTag -Note $Label
}

Write-Output "codex_exit_code=$RC"
Write-Output "codex_model=$Model (effort=$Effort)"
Write-Output "codex_duration_sec=$Duration"
Write-Output "codex_tokens=$TokensUsed"
if ($timedOut) { Write-Output "codex_timeout_sec=$Timeout" }
if ($Worktree) {
    Write-Output "codex_worktree=enabled"
    Write-Output "codex_workdir=$(if ($CodexWorkdir) { $CodexWorkdir } else { 'unknown' })"
}
$modeOut = if ($ResumeId) { "resumed" } elseif ($Persist) { "persisted" } else { "ephemeral" }
Write-Output "codex_session_mode=$modeOut"
Write-Output "codex_session_id=$SessionId"
if ($Persist -and -not $ResumeId -and $Label -ne "-") { Write-Output "codex_label=$Label" }
Write-Output "codex_log=$LogFile"
Write-Output "codex_result=$OutFile"
Write-Output "--- RESULT ---"

if ((Test-Path $OutFile) -and ((Get-Item $OutFile).Length -gt 0)) {
    Get-Content -Path $OutFile -Raw -Encoding UTF8
} else {
    Write-Output "(no structured result produced; tail of raw log follows)"
    Get-Content -Path $LogFile -Tail 40 -Encoding UTF8
}

exit $RC
