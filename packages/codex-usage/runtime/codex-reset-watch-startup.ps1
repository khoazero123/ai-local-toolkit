$ErrorActionPreference = "Stop"

$CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE ".codex" }
$LogFile = Join-Path $CodexHome "codex-reset-watch-startup.log"
$Pm2Home = if ($env:PM2_HOME) { $env:PM2_HOME } else { Join-Path $env:USERPROFILE ".pm2" }
$WatcherScript = Join-Path $CodexHome "codex-reset-watch.mjs"
$EcosystemFile = Join-Path $CodexHome "ecosystem.config.cjs"

function Write-Log([string]$Message) {
  $line = "[{0}] {1}" -f (Get-Date -Format "o"), $Message
  Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

function Resolve-NodeExe {
  $node = Get-Command node -ErrorAction SilentlyContinue
  if ($node) { return $node.Source }
  $fallback = Join-Path ${env:ProgramFiles} "nodejs\node.exe"
  if (Test-Path $fallback) { return $fallback }
  throw "Node.js not found in PATH"
}

function Wait-ForNetwork {
  param([int]$MaxWaitSeconds = 300)

  $deadline = (Get-Date).AddSeconds($MaxWaitSeconds)
  while ((Get-Date) -lt $deadline) {
    if (Test-Connection -ComputerName "1.1.1.1" -Count 1 -Quiet -ErrorAction SilentlyContinue) {
      return $true
    }
    Start-Sleep -Seconds 10
  }
  return $false
}

function Test-WatcherProcessOnline {
  $pattern = [regex]::Escape($WatcherScript)
  return @(Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" -ErrorAction SilentlyContinue |
      Where-Object { $_.CommandLine -and $_.CommandLine -match $pattern }).Count -gt 0
}

function Start-WatcherNode {
  $nodeExe = Resolve-NodeExe
  $env:CODEX_HOME = $CodexHome
  $env:CODEX_RESET_WATCH_CONFIG = Join-Path $CodexHome "codex-reset-watch.config.json"
  $process = Start-Process -FilePath $nodeExe -ArgumentList @($WatcherScript) -WorkingDirectory $CodexHome -WindowStyle Hidden -PassThru
  Write-Log "started node watcher pid=$($process.Id)"
}

function Resolve-Pm2Cmd {
  $pm2 = Get-Command pm2 -ErrorAction SilentlyContinue
  if ($pm2) { return $pm2.Source }
  $fallback = Join-Path ${env:ProgramFiles} "nodejs\pm2.cmd"
  if (Test-Path $fallback) { return $fallback }
  return "pm2"
}

function Invoke-Pm2([string[]]$Arguments) {
  $pm2Cmd = Resolve-Pm2Cmd
  $output = & $pm2Cmd @Arguments 2>&1
  foreach ($line in @($output)) {
    if ($null -ne $line -and "$line".Length -gt 0) {
      Write-Log "$line"
    }
  }
  return $LASTEXITCODE
}

function Test-Pm2WatcherOnline {
  $pm2Cmd = Resolve-Pm2Cmd
  $listRaw = & $pm2Cmd jlist 2>$null
  if (-not $listRaw) { return $false }

  try {
    $processes = $listRaw | ConvertFrom-Json
    return @($processes | Where-Object {
        $_.name -like "codex-reset-watch*" -and $_.pm2_env.status -eq "online"
      }).Count -gt 0
  } catch {
    Write-Log "failed to parse pm2 jlist: $_"
    return $false
  }
}

try {
  $runAs = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
  $env:CODEX_HOME = $CodexHome
  $env:PM2_HOME = $Pm2Home
  $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
    [Environment]::GetEnvironmentVariable("Path", "User")

  Write-Log "startup begin runAs=$runAs codexHome=$CodexHome"

  if (-not (Wait-ForNetwork)) {
    Write-Log "network not ready; continuing anyway"
  }

  if (Test-WatcherProcessOnline) {
    Write-Log "watcher node process already online"
    exit 0
  }

  if ($runAs -like "*\SYSTEM") {
    Write-Log "running under SYSTEM; starting node watcher directly"
    Start-WatcherNode
    exit 0
  }

  $resurrectCode = Invoke-Pm2 @("resurrect")
  if ($resurrectCode -ne 0) {
    Write-Log "pm2 resurrect exited with code $resurrectCode"
  }

  if (Test-Pm2WatcherOnline) {
    Write-Log "pm2 watcher online after resurrect"
    exit 0
  }

  Write-Log "watcher not online; starting ecosystem"
  $startCode = Invoke-Pm2 @("start", $EcosystemFile, "--only", "codex-reset-watch")
  if ($startCode -ne 0) {
    throw "failed to start watcher via pm2 (exit $startCode)"
  }
  Invoke-Pm2 @("save") | Out-Null

  Write-Log "startup complete"
  exit 0
} catch {
  Write-Log "startup failed: $_"
  exit 1
}
