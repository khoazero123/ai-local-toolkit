#Requires -Version 5.1
$ErrorActionPreference = "Stop"

$RepoHttps = "https://github.com/khoazero123/ai-local-toolkit.git"
$RawBase = "https://raw.githubusercontent.com/khoazero123/ai-local-toolkit/main"
$DefaultNodeVersion = "22"

function Write-Info([string]$Message) {
  Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Ok([string]$Message) {
  Write-Host "OK  $Message" -ForegroundColor Green
}

function Write-Warn([string]$Message) {
  Write-Host "!!  $Message" -ForegroundColor Yellow
}

function Prompt-YesNo([string]$Question, [bool]$DefaultYes = $true) {
  $suffix = if ($DefaultYes) { "[Y/n]" } else { "[y/N]" }
  $answer = Read-Host "$Question $suffix"
  if ([string]::IsNullOrWhiteSpace($answer)) { return $DefaultYes }
  return @("y", "yes") -contains $answer.Trim().ToLowerInvariant()
}

function Get-RepoRoot {
  $localRoot = $PSScriptRoot
  if (-not [string]::IsNullOrWhiteSpace($localRoot) -and (Test-Path (Join-Path $localRoot "packages\codex-usage\runtime\codex-usage.mjs"))) {
    return (Resolve-Path $localRoot).Path
  }

  Write-Info "Downloading repo to a temp directory..."
  $tempRoot = Join-Path $env:TEMP ("ai-local-toolkit-codex-usage-" + [Guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

  $git = Get-Command git -ErrorAction SilentlyContinue
  if ($git) {
    & git clone --depth 1 $RepoHttps (Join-Path $tempRoot "repo") | Out-Null
    return (Resolve-Path (Join-Path $tempRoot "repo")).Path
  }

  $zipPath = Join-Path $tempRoot "repo.zip"
  Invoke-WebRequest -Uri "$RawBase/archive/refs/heads/main.zip" -OutFile $zipPath
  Expand-Archive -Path $zipPath -DestinationPath $tempRoot -Force
  return (Resolve-Path (Join-Path $tempRoot "ai-local-toolkit-main")).Path
}

function Refresh-SessionPath {
  $machine = [Environment]::GetEnvironmentVariable("Path", "Machine")
  $user = [Environment]::GetEnvironmentVariable("Path", "User")
  if ($machine -and $user) {
    $env:Path = "$machine;$user"
  }
}

function Test-NodeAvailable {
  Refresh-SessionPath
  $node = Get-Command node -ErrorAction SilentlyContinue
  if (-not $node) { return $null }
  try {
    $version = (& node --version 2>$null).Trim()
    if ($version) { return $version }
  } catch {}
  return $null
}

function Get-NvmExecutable {
  $candidates = @(
    (Join-Path $env:LOCALAPPDATA "nvm\nvm.exe"),
    (Join-Path ${env:ProgramFiles} "nvm\nvm.exe"),
    (Join-Path $env:USERPROFILE "AppData\Roaming\nvm\nvm.exe")
  )
  foreach ($path in $candidates) {
    if (Test-Path $path) { return $path }
  }
  $cmd = Get-Command nvm -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return $null
}

function Install-NvmWindows {
  Write-Info "Installing nvm-windows via winget..."
  $winget = Get-Command winget -ErrorAction SilentlyContinue
  if (-not $winget) {
    throw "winget is not available. Install nvm-windows manually: https://github.com/coreybutler/nvm-windows/releases"
  }
  & winget install --id CoreyButler.NVMforWindows -e --accept-package-agreements --accept-source-agreements
  Refresh-SessionPath
}

function Install-NodeWithNvm([string]$Version) {
  $nvmExe = Get-NvmExecutable
  if (-not $nvmExe) {
    Install-NvmWindows
    $nvmExe = Get-NvmExecutable
  }
  if (-not $nvmExe) {
    throw "nvm-windows is still not available after install attempt."
  }

  Write-Info "Installing Node.js $Version with nvm..."
  & $nvmExe install $Version | Write-Host
  & $nvmExe use $Version | Write-Host
  Refresh-SessionPath

  $nodeVersion = Test-NodeAvailable
  if (-not $nodeVersion) {
    throw "Node.js is still unavailable after nvm install."
  }
  Write-Ok "Node.js $nodeVersion is ready"
}

function Ensure-NodeJs {
  $nodeVersion = Test-NodeAvailable
  if ($nodeVersion) {
    Write-Ok "Node.js already installed ($nodeVersion)"
    return
  }

  Write-Warn "Node.js was not found in PATH."
  if (-not (Prompt-YesNo "Install Node.js using nvm-windows?" $true)) {
    throw "Node.js is required. Install it manually, then rerun this installer."
  }

  Install-NodeWithNvm -Version $DefaultNodeVersion
}

function Test-Pm2Available {
  Refresh-SessionPath
  $pm2 = Get-Command pm2 -ErrorAction SilentlyContinue
  if ($pm2) {
    try {
      $version = (& pm2 --version 2>$null | Select-Object -First 1).ToString().Trim()
      if ($version) { return $version }
    } catch {}
    return "installed"
  }
  return $null
}

function Ensure-Pm2 {
  $pm2Version = Test-Pm2Available
  if ($pm2Version) {
    Write-Ok "PM2 already installed ($pm2Version)"
    return
  }

  Write-Warn "PM2 was not found."
  if (-not (Prompt-YesNo "Install PM2 globally with npm?" $true)) {
    throw "PM2 is required for the background watcher."
  }

  Write-Info "Installing PM2 globally..."
  & npm install -g pm2 | Write-Host
  Refresh-SessionPath

  $pm2Version = Test-Pm2Available
  if (-not $pm2Version) {
    throw "PM2 install failed."
  }
  Write-Ok "PM2 installed ($pm2Version)"
}

function Get-CodexHome {
  if ($env:CODEX_HOME) { return $env:CODEX_HOME }
  return (Join-Path $env:USERPROFILE ".codex")
}

function Install-CodexUsageFiles {
  param(
    [string]$RepoRoot,
    [string]$CodexHome
  )

  $runtimeDir = Join-Path $RepoRoot "packages\codex-usage\runtime"
  if (-not (Test-Path $runtimeDir)) {
    throw "Runtime package not found: $runtimeDir"
  }

  New-Item -ItemType Directory -Path $CodexHome -Force | Out-Null

  $files = @(
    "codex-usage.mjs",
    "codex-reset-watch.mjs",
    "codex-reset-watch.config.json",
    "ecosystem.config.cjs",
    "codex-reset-watch-startup.ps1",
    "register-codex-reset-watch-task.ps1"
  )

  foreach ($name in $files) {
    Copy-Item -Path (Join-Path $runtimeDir $name) -Destination (Join-Path $CodexHome $name) -Force
  }

  Write-Ok "Installed runtime files to $CodexHome"
}

function Start-CodexResetWatcher {
  param([string]$CodexHome)

  $ecosystem = Join-Path $CodexHome "ecosystem.config.cjs"
  $env:CODEX_HOME = $CodexHome

  $existing = & pm2 jlist 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
  if ($existing) {
    foreach ($app in @($existing | Where-Object { $_.name -like "codex-reset-watch*" })) {
      & pm2 delete $app.name 2>$null | Out-Null
    }
  }

  & pm2 start $ecosystem --only codex-reset-watch | Write-Host
  & pm2 save | Write-Host
  Write-Ok "PM2 watcher started (codex-reset-watch)"
}

function Test-CodexAuth([string]$CodexHome) {
  $authPath = Join-Path $CodexHome "auth.json"
  return (Test-Path $authPath)
}

Write-Host ""
Write-Host "Codex Usage + Reset Watch Installer (Windows)" -ForegroundColor Magenta
Write-Host "=============================================" -ForegroundColor Magenta

$repoRoot = Get-RepoRoot
$codexHome = Get-CodexHome

Ensure-NodeJs
Ensure-Pm2
Install-CodexUsageFiles -RepoRoot $repoRoot -CodexHome $codexHome

if (-not (Test-CodexAuth -CodexHome $codexHome)) {
  Write-Warn "Codex auth.json not found at $codexHome\auth.json"
  Write-Warn "Open Codex and sign in once before using codex-usage or the reset watcher."
} else {
  Write-Info "Testing codex-usage..."
  try {
    & node (Join-Path $codexHome "codex-usage.mjs")
    Write-Ok "codex-usage ran successfully"
  } catch {
    Write-Warn "codex-usage test failed: $($_.Exception.Message)"
  }
}

$startWatcher = Prompt-YesNo "Start PM2 reset watcher now?" $true
if ($startWatcher) {
  Start-CodexResetWatcher -CodexHome $codexHome
}

$registerTask = Prompt-YesNo "Register Windows Task Scheduler for boot/logon startup?" $false
if ($registerTask) {
  $registerScript = Join-Path $codexHome "register-codex-reset-watch-task.ps1"
  & powershell -NoProfile -ExecutionPolicy Bypass -File $registerScript
}

Write-Host ""
Write-Ok "Installation complete."
Write-Host ""
Write-Host "Quick commands:" -ForegroundColor White
Write-Host "  node $codexHome\codex-usage.mjs"
Write-Host "  pm2 status codex-reset-watch"
Write-Host "  pm2 logs codex-reset-watch"
Write-Host "  Get-Content $codexHome\codex-reset-watch.log -Tail 20"
