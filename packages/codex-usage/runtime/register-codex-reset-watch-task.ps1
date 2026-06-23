# Registers CodexResetWatchPM2 to run at boot, even when no user is logged in.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\register-codex-reset-watch-task.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\register-codex-reset-watch-task.ps1 -RunAsSystem
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\register-codex-reset-watch-task.ps1 -Password 'your-password'

[CmdletBinding(DefaultParameterSetName = "Auto")]
param(
  [string]$TaskName = "CodexResetWatchPM2",
  [string]$UserName = "$env:COMPUTERNAME\$env:USERNAME",
  [string]$Password,
  [switch]$RunAsSystem,
  [string]$StartupScript
)

$ErrorActionPreference = "Stop"

$ToolDir = $PSScriptRoot
$CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE ".codex" }
if (-not $StartupScript) {
  $StartupScript = Join-Path $ToolDir "codex-reset-watch-startup.ps1"
}

if (-not (Test-Path $StartupScript)) {
  throw "Startup script not found: $StartupScript"
}

function Test-LocalAccountHasPassword([string]$AccountName) {
  $localUser = Get-LocalUser -Name $AccountName -ErrorAction SilentlyContinue
  if (-not $localUser) { return $true }
  return [bool]$localUser.PasswordRequired
}

function New-TaskParts {
  param(
    [string]$PrincipalUserId,
    [ValidateSet("Password", "ServiceAccount")]
    [string]$LogonType
  )

  $action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$StartupScript`""

  $bootTrigger = New-ScheduledTaskTrigger -AtStartup
  $bootTrigger.Delay = "PT2M"
  $logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME

  $principal = New-ScheduledTaskPrincipal `
    -UserId $PrincipalUserId `
    -LogonType $LogonType `
    -RunLevel Highest

  $settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 5) `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 15)

  return @{
    Action = $action
    Triggers = @($bootTrigger, $logonTrigger)
    Principal = $principal
    Settings = $settings
  }
}

$accountName = $env:USERNAME
$hasPassword = Test-LocalAccountHasPassword -AccountName $accountName
$useSystem = [bool]$RunAsSystem

if ($PSCmdlet.ParameterSetName -eq "Auto" -and -not $Password -and -not $hasPassword) {
  $useSystem = $true
  Write-Host "Account '$accountName' has no Windows password (PasswordRequired=False)."
  Write-Host "Task Scheduler cannot store credentials for that mode, so this will register as SYSTEM."
  Write-Host "To run as your user instead, set a local password first: net user $accountName <password>"
}

if ($useSystem) {
  $parts = New-TaskParts -PrincipalUserId "SYSTEM" -LogonType ServiceAccount
  $runAsLabel = "SYSTEM"
} else {
  if (-not $Password) {
    $credential = Get-Credential -UserName $UserName -Message "Enter Windows password for scheduled task"
    if (-not $credential) {
      throw "Password is required to run the task without an interactive login."
    }
    $Password = $credential.GetNetworkCredential().Password
  }

  $parts = New-TaskParts -PrincipalUserId $UserName -LogonType Password
  $runAsLabel = $UserName
}

$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

if ($useSystem) {
  Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $parts.Action `
    -Trigger $parts.Triggers `
    -Principal $parts.Principal `
    -Settings $parts.Settings `
    -Description "Restore Codex reset watcher at boot/logon (SYSTEM, no login required)" `
    -Force | Out-Null
} else {
  Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $parts.Action `
    -Trigger $parts.Triggers `
    -Principal $parts.Principal `
    -Settings $parts.Settings `
    -Description "Restore Codex reset watcher at boot/logon (runs without interactive login)" `
    -User $UserName `
    -Password $Password `
    -Force | Out-Null
}

$task = Get-ScheduledTask -TaskName $TaskName
$info = Get-ScheduledTaskInfo -TaskName $TaskName

Write-Host ""
Write-Host "Registered: $TaskName"
Write-Host "Run as:     $runAsLabel"
Write-Host "State:      $($task.State)"
Write-Host "Triggers:   At startup (delay 2m), At logon"
Write-Host "LastResult: $($info.LastTaskResult)"
Write-Host ""
Write-Host "Test: schtasks /Run /TN $TaskName"
