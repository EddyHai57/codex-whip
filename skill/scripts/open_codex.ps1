[CmdletBinding()]
param(
    [string]$Cd = (Get-Location).Path,
    [string]$Session = "",
    [switch]$Copy
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$StateDir = if ($env:CODEX_WHIP_HOME) { $env:CODEX_WHIP_HOME } else { Join-Path $HOME ".codex-whip" }
$LedgerPath = Join-Path $StateDir "sessions.tsv"
$CdExplicit = $PSBoundParameters.ContainsKey("Cd")

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

$SessionId = ""
if ($Session) {
    $isUuid = $Session -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    $rows = @()
    if (Test-Path $LedgerPath) {
        foreach ($line in Get-Content -Path $LedgerPath -Encoding UTF8) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $p = $line -split "`t"
            if ($p.Count -ge 5) {
                $rows += [pscustomobject]@{ SessionId = $p[1]; Workdir = $p[2]; Label = $p[4] }
            }
        }
    }
    if ($isUuid) {
        $SessionId = $Session
        $hit = $rows | Where-Object { $_.SessionId -eq $Session } | Select-Object -First 1
        if (-not $CdExplicit -and $hit -and (Test-Path $hit.Workdir)) { $Cd = $hit.Workdir }
    } else {
        $q = $Session.Trim().ToLowerInvariant()
        $exact = @($rows | Where-Object { $_.Label.Trim().ToLowerInvariant() -eq $q })
        $chosen = if ($exact.Count -gt 0) { $exact } else { @($rows | Where-Object { $_.Label.Trim().ToLowerInvariant().Contains($q) }) }
        if ($chosen.Count -eq 1) {
            $SessionId = $chosen[0].SessionId
            if (-not $CdExplicit -and (Test-Path $chosen[0].Workdir)) { $Cd = $chosen[0].Workdir }
        } elseif ($chosen.Count -gt 1) {
            Write-Error ("Ambiguous session name '{0}'. Pass an exact label or UUID." -f $Session)
            exit 2
        } else {
            $SessionId = $Session
        }
    }
}

$CodexBin = Resolve-CodexBin
$LaunchCmd = if ($SessionId) {
    "Set-Location -LiteralPath '$Cd'; & '$CodexBin' resume '$SessionId'"
} else {
    "Set-Location -LiteralPath '$Cd'; & '$CodexBin'"
}

if ($Copy) {
    Set-Clipboard -Value $LaunchCmd
    Write-Output "mode=clipboard"
    Write-Output "session_id=$(if ($SessionId) { $SessionId } else { 'new' })"
    Write-Output "command=$LaunchCmd"
    exit 0
}

$wt = Get-Command wt.exe -ErrorAction SilentlyContinue
$shellExe = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { "pwsh.exe" } else { "powershell.exe" }
if ($wt) {
    Start-Process -FilePath $wt.Source -ArgumentList @("-d", $Cd, $shellExe, "-NoExit", "-Command", $LaunchCmd)
} else {
    Start-Process -FilePath $shellExe -ArgumentList @("-NoExit", "-Command", $LaunchCmd)
}

Write-Output "mode=terminal"
Write-Output "session_id=$(if ($SessionId) { $SessionId } else { 'new' })"
Write-Output "command=$LaunchCmd"
