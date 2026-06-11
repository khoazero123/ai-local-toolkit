#Requires -Version 5.1
$ErrorActionPreference = "Stop"

$RepoHttps = "https://github.com/khoazero123/agent-webhook-tracking-continues.git"
$RawBase = "https://raw.githubusercontent.com/khoazero123/agent-webhook-tracking-continues/main"

function Write-Info([string]$Message) {
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Ok([string]$Message) {
    Write-Host "OK  $Message" -ForegroundColor Green
}

function Write-Warn([string]$Message) {
    Write-Host "!!  $Message" -ForegroundColor Yellow
}

function Get-RepoRoot {
    $localRoot = $PSScriptRoot
    if (-not [string]::IsNullOrWhiteSpace($localRoot) -and (Test-Path (Join-Path $localRoot "runtime\windows\hook-lib.ps1"))) {
        return (Resolve-Path $localRoot).Path
    }

    Write-Info "Downloading repo to a temp directory..."
    $tempRoot = Join-Path $env:TEMP ("agent-webhook-install-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) {
        & git clone --depth 1 $RepoHttps (Join-Path $tempRoot "repo") | Out-Null
        return (Resolve-Path (Join-Path $tempRoot "repo")).Path
    }

    $zipPath = Join-Path $tempRoot "repo.zip"
    Invoke-WebRequest -Uri "$RawBase/archive/refs/heads/main.zip" -OutFile $zipPath
    Expand-Archive -Path $zipPath -DestinationPath $tempRoot -Force
    return (Resolve-Path (Join-Path $tempRoot "agent-webhook-tracking-continues-main")).Path
}

function Read-DefaultConfig([string]$RepoRoot) {
    $defaultsPath = Join-Path $RepoRoot "config.defaults.json"
    return Get-Content $defaultsPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Prompt-WebhookUrl {
    Write-Host ""
    Write-Host "Webhook URL (leave empty to disable webhooks):" -ForegroundColor White
    $url = Read-Host "Webhook URL"
    return $url.Trim()
}

function Prompt-Keywords([object]$Defaults) {
    $defaultText = ($Defaults.keywords -join ", ")
    Write-Host ""
    Write-Host "Auto-continue keywords (comma-separated, Enter = default):" -ForegroundColor White
    Write-Host "Default: $defaultText" -ForegroundColor DarkGray
    $input = Read-Host "Keywords"
    if ([string]::IsNullOrWhiteSpace($input)) {
        return @($Defaults.keywords)
    }
    return @($input.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Prompt-YesNo([string]$Question, [bool]$DefaultYes = $true) {
    $suffix = if ($DefaultYes) { "[Y/n]" } else { "[y/N]" }
    $answer = Read-Host "$Question $suffix"
    if ([string]::IsNullOrWhiteSpace($answer)) {
        return $DefaultYes
    }
    return @("y", "yes") -contains $answer.Trim().ToLowerInvariant()
}

function New-HookConfigJson {
    param(
        [string]$WebhookUrl,
        [string]$Source,
        [object[]]$Keywords,
        [object]$Defaults
    )

    $config = [ordered]@{
        source               = $Source
        webhook_url          = $WebhookUrl
        keywords             = @($Keywords)
        tail_length          = [int]$Defaults.tail_length
        continue_message     = [string]$Defaults.continue_message
        max_continue_loops   = [int]$Defaults.max_continue_loops
    }
    return ($config | ConvertTo-Json -Depth 5)
}

function Install-CursorHooks {
    param(
        [string]$RepoRoot,
        [string]$WebhookUrl,
        [object[]]$Keywords,
        [object]$Defaults
    )

    $cursorRoot = Join-Path $env:USERPROFILE ".cursor"
    $hooksDir = Join-Path $cursorRoot "hooks"
    New-Item -ItemType Directory -Path $hooksDir -Force | Out-Null

    $runtimeDir = Join-Path $RepoRoot "runtime\windows"
    Copy-Item -Path (Join-Path $runtimeDir "hook-lib.ps1") -Destination $hooksDir -Force
    Copy-Item -Path (Join-Path $runtimeDir "webhook-on-prompt.*") -Destination $hooksDir -Force
    Copy-Item -Path (Join-Path $runtimeDir "webhook-on-response.*") -Destination $hooksDir -Force
    Copy-Item -Path (Join-Path $runtimeDir "auto-continue-flag.*") -Destination $hooksDir -Force
    Copy-Item -Path (Join-Path $runtimeDir "auto-continue-stop.*") -Destination $hooksDir -Force

    $configJson = New-HookConfigJson -WebhookUrl $WebhookUrl -Source "cursor" -Keywords $Keywords -Defaults $Defaults
    [System.IO.File]::WriteAllText((Join-Path $hooksDir "hook-config.json"), $configJson, [System.Text.UTF8Encoding]::new($false))

    $hooksJson = @{
        version = 1
        hooks   = @{
            beforeSubmitPrompt = @(
                @{ command = "./hooks/webhook-on-prompt.cmd"; timeout = 15 }
            )
            afterAgentResponse = @(
                @{ command = "./hooks/webhook-on-response.cmd"; timeout = 15 },
                @{ command = "./hooks/auto-continue-flag.cmd"; timeout = 10 }
            )
            stop = @(
                @{ command = "./hooks/auto-continue-stop.cmd"; timeout = 10; loop_limit = [int]$Defaults.max_continue_loops }
            )
        }
    }

    $hooksPath = Join-Path $cursorRoot "hooks.json"
    $hooksText = ($hooksJson | ConvertTo-Json -Depth 6)
    [System.IO.File]::WriteAllText($hooksPath, $hooksText, [System.Text.UTF8Encoding]::new($false))
    Write-Ok "Installed Cursor hooks at $hooksDir"
}

function Install-CodexHooks {
    param(
        [string]$RepoRoot,
        [string]$WebhookUrl,
        [object[]]$Keywords,
        [object]$Defaults
    )

    $codexRoot = Join-Path $env:USERPROFILE ".codex"
    $hooksDir = Join-Path $codexRoot "hooks"
    New-Item -ItemType Directory -Path $hooksDir -Force | Out-Null

    $runtimeDir = Join-Path $RepoRoot "runtime\windows"
    Copy-Item -Path (Join-Path $runtimeDir "hook-lib.ps1") -Destination $hooksDir -Force
    Copy-Item -Path (Join-Path $runtimeDir "codex-user-prompt-webhook.*") -Destination $hooksDir -Force
    Copy-Item -Path (Join-Path $runtimeDir "codex-stop-webhook-continue.*") -Destination $hooksDir -Force

    $configJson = New-HookConfigJson -WebhookUrl $WebhookUrl -Source "codex" -Keywords $Keywords -Defaults $Defaults
    [System.IO.File]::WriteAllText((Join-Path $hooksDir "hook-config.json"), $configJson, [System.Text.UTF8Encoding]::new($false))

    $promptPs1 = (Join-Path $hooksDir "codex-user-prompt-webhook.ps1")
    $stopPs1 = (Join-Path $hooksDir "codex-stop-webhook-continue.ps1")
    $promptCmd = (Join-Path $hooksDir "codex-user-prompt-webhook.cmd")
    $stopCmd = (Join-Path $hooksDir "codex-stop-webhook-continue.cmd")

    $hooksJson = @{
        hooks = @{
            UserPromptSubmit = @(
                @{
                    hooks = @(
                        @{
                            type            = "command"
                            command         = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$promptPs1`""
                            commandWindows  = $promptCmd
                            timeout         = 15
                            statusMessage   = "Webhook user prompt"
                        }
                    )
                }
            )
            Stop = @(
                @{
                    hooks = @(
                        @{
                            type            = "command"
                            command         = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$stopPs1`""
                            commandWindows  = $stopCmd
                            timeout         = 15
                            statusMessage   = "Webhook + auto continue"
                        }
                    )
                }
            )
        }
    }

    $hooksPath = Join-Path $codexRoot "hooks.json"
    $hooksText = ($hooksJson | ConvertTo-Json -Depth 8)
    [System.IO.File]::WriteAllText($hooksPath, $hooksText, [System.Text.UTF8Encoding]::new($false))
    Write-Ok "Installed Codex hooks at $hooksDir"
    Write-Warn "In Codex, run /hooks to trust hooks after installing."
}

Write-Host ""
Write-Host "Agent Webhook + Auto Continue Installer (Windows)" -ForegroundColor Magenta
Write-Host "=================================================" -ForegroundColor Magenta

$repoRoot = Get-RepoRoot
$defaults = Read-DefaultConfig -RepoRoot $repoRoot

$webhookUrl = Prompt-WebhookUrl
$keywords = Prompt-Keywords -Defaults $defaults

$installCursor = Prompt-YesNo "Install for Cursor?" $true
$installCodex = Prompt-YesNo "Install for Codex?" $true

if (-not $installCursor -and -not $installCodex) {
    Write-Warn "No tools selected. Exiting."
    exit 1
}

if ($installCursor) {
    Install-CursorHooks -RepoRoot $repoRoot -WebhookUrl $webhookUrl -Keywords $keywords -Defaults $defaults
}

if ($installCodex) {
    Install-CodexHooks -RepoRoot $repoRoot -WebhookUrl $webhookUrl -Keywords $keywords -Defaults $defaults
}

Write-Host ""
Write-Ok "Installation complete. Restart Cursor/Codex to apply hooks."
if ([string]::IsNullOrWhiteSpace($webhookUrl)) {
    Write-Warn "Webhooks disabled (empty URL). Auto-continue only."
}
