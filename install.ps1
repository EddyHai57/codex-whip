[CmdletBinding()]
param(
    [switch]$Antigravity,
    [switch]$Claude,
    [switch]$All
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not $Antigravity -and -not $Claude -and -not $All) {
    $All = $true
}
if ($All) {
    $Antigravity = $true
    $Claude = $true
}

$RepoDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SkillSrc = Join-Path $RepoDir "skill"

function Install-SkillJunction([string]$ParentDir, [string]$Label) {
    New-Item -ItemType Directory -Path $ParentDir -Force | Out-Null
    $dest = Join-Path $ParentDir "codex-whip"
    if (Test-Path $dest) {
        $item = Get-Item $dest -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            Remove-Item $dest -Force
        } else {
            throw "Cannot overwrite existing non-link directory for ${Label}: $dest"
        }
    }
    New-Item -ItemType Junction -Path $dest -Target $SkillSrc | Out-Null
    Write-Output "Installed ${Label}: $dest -> $SkillSrc"
}

if ($Antigravity) {
    Install-SkillJunction (Join-Path $HOME ".gemini\config\skills") "Antigravity"
}
if ($Claude) {
    Install-SkillJunction (Join-Path $HOME ".claude\skills") "Claude Code"
}

$codexCmd = Get-Command codex -ErrorAction SilentlyContinue
if ($codexCmd) {
    Write-Output "Detected Codex CLI: $($codexCmd.Source)"
} else {
    Write-Output "Note: 'codex' CLI not found in PATH yet. Install Codex CLI or set `$env:CODEX_BIN."
}

Write-Output ""
Write-Output "Done! Tip: view latest Codex log in PowerShell with:"
Write-Output '  Get-Content "$env:TEMP\codex-whip-latest.log" -Wait'
