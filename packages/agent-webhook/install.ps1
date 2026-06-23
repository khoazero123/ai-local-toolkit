#Requires -Version 5.1
$ErrorActionPreference = "Stop"

$RepoHttps = "https://github.com/khoazero123/ai-local-toolkit.git"
$RawBase = "https://raw.githubusercontent.com/khoazero123/ai-local-toolkit/main"
$ArchiveZipUrl = "https://codeload.github.com/khoazero123/ai-local-toolkit/zip/refs/heads/main"
$script:HookUtf8 = [System.Text.UTF8Encoding]::new($false)

function Set-InstallerConsoleEncoding {
    try { [Console]::InputEncoding = $script:HookUtf8 } catch {}
    try { [Console]::OutputEncoding = $script:HookUtf8 } catch {}
    $script:OutputEncoding = $script:HookUtf8
    if ($Host.Name -eq "ConsoleHost") {
        try {
            $null = cmd.exe /c "chcp 65001 >nul"
        }
        catch {}
    }
}

function Read-DefaultConfig([string]$PackageRoot) {
    $defaultsPath = Join-Path $PackageRoot "config.defaults.json"
    $json = [System.IO.File]::ReadAllText($defaultsPath, $script:HookUtf8)
    return ($json | ConvertFrom-Json)
}

function Test-ValueInList {
    param(
        [object]$Value,
        [string[]]$Candidates
    )

    if ($null -eq $Value) { return $false }
    $text = [string]$Value
    foreach ($candidate in $Candidates) {
        if ($text -eq $candidate) { return $true }
    }
    return $false
}

function Get-SafePropertyValue {
    param(
        [object]$Object,
        [string]$Name
    )

    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function Build-LocaleDefaults {
    param(
        [object]$Config,
        [string]$Locale
    )

    $locales = Get-SafePropertyValue -Object $Config -Name "locales"
    if ($null -eq $locales) {
        $Locale = "en"
    }
    elseif ($null -eq (Get-SafePropertyValue -Object $locales -Name $Locale)) {
        $Locale = "en"
    }

    $localeConfig = Get-SafePropertyValue -Object $locales -Name $Locale
    return [pscustomobject]@{
        locale             = $Locale
        keywords           = @($localeConfig.keywords | ForEach-Object { [string]$_ })
        continue_message   = [string]$localeConfig.continue_message
        tail_length        = [int]$Config.tail_length
        max_continue_loops = [int]$Config.max_continue_loops
    }
}

Set-InstallerConsoleEncoding

function Write-Info([string]$Message) {
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Ok([string]$Message) {
    Write-Host "OK  $Message" -ForegroundColor Green
}

function Write-Warn([string]$Message) {
    Write-Host "!!  $Message" -ForegroundColor Yellow
}

function Resolve-DownloadedPackageRoot([string]$RepoRoot) {
    $packageRoot = Join-Path $RepoRoot "packages\agent-webhook"
    if (-not (Test-Path (Join-Path $packageRoot "runtime\windows\hook-lib.ps1"))) {
        throw "agent-webhook package not found in downloaded repo"
    }
    return (Resolve-Path $packageRoot).Path
}

function Get-PackageRoot {
    $localRoot = $PSScriptRoot
    if (-not [string]::IsNullOrWhiteSpace($localRoot) -and (Test-Path (Join-Path $localRoot "runtime\windows\hook-lib.ps1"))) {
        return (Resolve-Path $localRoot).Path
    }

    Write-Info "Downloading repo to a temp directory..."
    $tempRoot = Join-Path $env:TEMP ("agent-webhook-install-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) {
        $clonePath = Join-Path $tempRoot "repo"
        & git clone --depth 1 $RepoHttps $clonePath | Out-Null
        return (Resolve-DownloadedPackageRoot -RepoRoot $clonePath)
    }

    $zipPath = Join-Path $tempRoot "repo.zip"
    Invoke-WebRequest -Uri $ArchiveZipUrl -OutFile $zipPath
    Expand-Archive -Path $zipPath -DestinationPath $tempRoot -Force
    return (Resolve-DownloadedPackageRoot -RepoRoot (Join-Path $tempRoot "ai-local-toolkit-main"))
}

function Test-VietnameseText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    return [regex]::IsMatch(
        $Text,
        '[\u00C0-\u00C3\u00C8-\u00CA\u00CC-\u00CD\u00D2-\u00D5\u00D9-\u00DA\u00DD\u0102\u0103\u0110\u0111\u0128\u0129\u0168\u0169\u01A0\u01A1\u01AF\u01B0\u1EA0-\u1EF9]'
    )
}

function Get-NormalizedUserText {
    param([string]$Text)
    if ($Text -match '(?is)<user_query>\s*(.*?)\s*</user_query>') {
        return $Matches[1].Trim()
    }
    return $Text.Trim()
}

function Test-SkipTranscriptText {
    param([string]$Text)
    $trimmed = $Text.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) { return $true }
    $prefixes = @(
        '<environment_context>',
        '<permissions',
        '<app-context>',
        '<collaboration_mode>',
        '<skills_instructions>',
        '<plugins_instructions>'
    )
    foreach ($prefix in $prefixes) {
        if ($trimmed.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Get-TranscriptTextFromCursorLine {
    param([string]$Line)
    try {
        $obj = $Line | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return ""
    }

    $role = Get-SafePropertyValue -Object $obj -Name "role"
    if (-not (Test-ValueInList -Value $role -Candidates @("user", "assistant"))) { return "" }

    $message = Get-SafePropertyValue -Object $obj -Name "message"
    $content = @(Get-SafePropertyValue -Object $message -Name "content")
    $chunks = @()
    foreach ($part in $content) {
        if ($null -eq $part) { continue }
        $partType = Get-SafePropertyValue -Object $part -Name "type"
        if ($partType -ne "text") { continue }
        $text = [string](Get-SafePropertyValue -Object $part -Name "text")
        if (Test-SkipTranscriptText -Text $text) { continue }
        $chunks += (Get-NormalizedUserText -Text $text)
    }
    return ($chunks -join "`n")
}

function Get-TranscriptTextFromCodexLine {
    param([string]$Line)
    try {
        $obj = $Line | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return ""
    }

    if ((Get-SafePropertyValue -Object $obj -Name "type") -ne "response_item") { return "" }

    $payload = Get-SafePropertyValue -Object $obj -Name "payload"
    if ($null -eq $payload -or $payload -isnot [psobject]) { return "" }
    if ((Get-SafePropertyValue -Object $payload -Name "type") -ne "message") { return "" }

    $role = Get-SafePropertyValue -Object $payload -Name "role"
    if (-not (Test-ValueInList -Value $role -Candidates @("user", "assistant"))) { return "" }

    $content = @(Get-SafePropertyValue -Object $payload -Name "content")
    $chunks = @()
    foreach ($part in $content) {
        if ($null -eq $part) { continue }
        $partType = Get-SafePropertyValue -Object $part -Name "type"
        if (-not (Test-ValueInList -Value $partType -Candidates @("input_text", "output_text", "text"))) { continue }
        $text = [string](Get-SafePropertyValue -Object $part -Name "text")
        if (Test-SkipTranscriptText -Text $text) { continue }
        $chunks += (Get-NormalizedUserText -Text $text)
    }
    return ($chunks -join "`n")
}

function Find-TranscriptFiles {
    $files = New-Object System.Collections.Generic.List[string]
    $cursorRoot = Join-Path $env:USERPROFILE ".cursor\projects"
    if (Test-Path $cursorRoot) {
        Get-ChildItem -Path $cursorRoot -Filter "*.jsonl" -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match "agent-transcripts" } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 40 |
            ForEach-Object { $files.Add($_.FullName) | Out-Null }
    }

    $codexRoots = @((Join-Path $env:USERPROFILE ".codex"))
    if ($env:CODEX_HOME) { $codexRoots += $env:CODEX_HOME }
    foreach ($codexRoot in ($codexRoots | Select-Object -Unique)) {
        $sessionsRoot = Join-Path $codexRoot "sessions"
        if (-not (Test-Path $sessionsRoot)) { continue }
        Get-ChildItem -Path $sessionsRoot -Filter "*.jsonl" -Recurse -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 40 |
            ForEach-Object { $files.Add($_.FullName) | Out-Null }
    }

    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $unique = New-Object System.Collections.Generic.List[string]
    foreach ($path in $files) {
        if ($seen.Add($path)) {
            [void]$unique.Add($path)
        }
    }
    return $unique.ToArray()
}

function Detect-LocaleFromTranscripts {
    $files = Find-TranscriptFiles
    if ($files.Count -eq 0) { return "en" }

    $sampledBytes = 0
    $maxBytes = 512000
    foreach ($file in $files) {
        if ($sampledBytes -ge $maxBytes) { break }
        try {
            $stream = [System.IO.File]::Open(
                $file,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                [System.IO.FileShare]::ReadWrite
            )
            $reader = New-Object System.IO.StreamReader($stream)
            try {
                while (($line = $reader.ReadLine()) -ne $null) {
                    if ($sampledBytes -ge $maxBytes) { break }
                    $text = Get-TranscriptTextFromCursorLine -Line $line
                    if ([string]::IsNullOrWhiteSpace($text)) {
                        $text = Get-TranscriptTextFromCodexLine -Line $line
                    }
                    if ([string]::IsNullOrWhiteSpace($text)) { continue }
                    $sampledBytes += [System.Text.Encoding]::UTF8.GetByteCount($text)
                    if (Test-VietnameseText -Text $text) {
                        return "vi"
                    }
                }
            }
            finally {
                $reader.Dispose()
            }
        }
        catch {
            continue
        }
    }

    return "en"
}

function Resolve-LocaleDefaults {
    param([string]$PackageRoot)

    try {
        $locale = Detect-LocaleFromTranscripts
        $config = Read-DefaultConfig -PackageRoot $PackageRoot
        return (Build-LocaleDefaults -Config $config -Locale $locale)
    }
    catch {
        Write-Warn "Locale detection failed ($($_.Exception.Message)); using English defaults."
        $config = Read-DefaultConfig -PackageRoot $PackageRoot
        return (Build-LocaleDefaults -Config $config -Locale "en")
    }
}

function Get-ExistingHookConfigPath {
    $paths = @(
        (Join-Path $env:USERPROFILE ".cursor\tools\agent-webhook\hook-config.json"),
        (Join-Path $env:USERPROFILE ".codex\tools\agent-webhook\hook-config.json"),
        (Join-Path $env:USERPROFILE ".cursor\hooks\hook-config.json"),
        (Join-Path $env:USERPROFILE ".codex\hooks\hook-config.json")
    )
    if ($env:CODEX_HOME) {
        $codexToolPath = Join-Path $env:CODEX_HOME "tools\agent-webhook\hook-config.json"
        $codexLegacyPath = Join-Path $env:CODEX_HOME "hooks\hook-config.json"
        if ($paths -notcontains $codexToolPath) { $paths += $codexToolPath }
        if ($paths -notcontains $codexLegacyPath) { $paths += $codexLegacyPath }
    }

    $newestPath = $null
    $newestTime = [datetime]::MinValue
    foreach ($path in $paths) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $item = Get-Item -LiteralPath $path
        if ($item.LastWriteTime -gt $newestTime) {
            $newestTime = $item.LastWriteTime
            $newestPath = $item.FullName
        }
    }

    return $newestPath
}

function Read-ExistingHookConfig {
    param([string]$ConfigPath)

    if ([string]::IsNullOrWhiteSpace($ConfigPath)) { return $null }
    try {
        $json = [System.IO.File]::ReadAllText($ConfigPath, $script:HookUtf8)
        return ($json | ConvertFrom-Json)
    }
    catch {
        return $null
    }
}

function Apply-ExistingHookConfig {
    param(
        [object]$Defaults,
        [object]$Existing
    )

    $webhookUrl = ""
    if ($null -eq $Existing) {
        return [pscustomobject]@{
            Defaults   = $Defaults
            WebhookUrl = $webhookUrl
        }
    }

    $keywords = Get-SafePropertyValue -Object $Existing -Name "keywords"
    if ($null -ne $keywords) {
        $parsedKeywords = @($keywords | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($parsedKeywords.Count -gt 0) {
            $Defaults.keywords = $parsedKeywords
        }
    }

    $continueMessage = Get-SafePropertyValue -Object $Existing -Name "continue_message"
    if (-not [string]::IsNullOrWhiteSpace([string]$continueMessage)) {
        $Defaults.continue_message = [string]$continueMessage
    }

    $tailLength = Get-SafePropertyValue -Object $Existing -Name "tail_length"
    if ($null -ne $tailLength) {
        $Defaults.tail_length = [int]$tailLength
    }

    $maxLoops = Get-SafePropertyValue -Object $Existing -Name "max_continue_loops"
    if ($null -ne $maxLoops) {
        $Defaults.max_continue_loops = [int]$maxLoops
    }

    $webhookUrl = [string](Get-SafePropertyValue -Object $Existing -Name "webhook_url")
    if ($null -eq $webhookUrl) { $webhookUrl = "" }

    return [pscustomobject]@{
        Defaults   = $Defaults
        WebhookUrl = $webhookUrl
    }
}

function Read-LineWithDefault {
    param(
        [string]$Prompt,
        [string]$Default = ""
    )

    $prefix = "$Prompt "
    $buffer = New-Object System.Text.StringBuilder
    if (-not [string]::IsNullOrEmpty($Default)) {
        [void]$buffer.Append($Default)
    }

    [Console]::Write($prefix + $buffer.ToString())

    while ($true) {
        $key = [Console]::ReadKey($true)
        switch ($key.Key) {
            "Enter" {
                [Console]::WriteLine()
                return $buffer.ToString()
            }
            "Backspace" {
                if ($buffer.Length -gt 0) {
                    $buffer.Remove($buffer.Length - 1, 1) | Out-Null
                    $line = $prefix + $buffer.ToString()
                    [Console]::Write("`r$line ")
                    [Console]::Write("`r$line")
                }
            }
            default {
                if ($key.KeyChar -ge 32) {
                    [void]$buffer.Append($key.KeyChar)
                    [Console]::Write($key.KeyChar)
                }
            }
        }
    }
}

function Prompt-WebhookUrl {
    param([string]$Default = "")

    Write-Host ""
    Write-Host "Webhook URL (leave empty to disable webhooks):" -ForegroundColor White
    return (Read-LineWithDefault -Prompt "Webhook URL" -Default $Default).Trim()
}

function Prompt-Keywords([object]$Defaults) {
    Write-Host ""
    Write-Host "Auto-continue keywords (comma-separated, edit then Enter):" -ForegroundColor White
    Write-Host "Detected locale: $($Defaults.locale)" -ForegroundColor DarkGray
    $defaultText = ($Defaults.keywords -join ", ")
    $input = Read-LineWithDefault -Prompt "Keywords" -Default $defaultText
    if ([string]::IsNullOrWhiteSpace($input)) {
        return @()
    }
    return [string[]](@($input.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ }))
}

function Prompt-ContinueMessage {
    param([object]$Defaults)

    Write-Host ""
    Write-Host "Auto-continue prompt sent when keywords match (edit then Enter):" -ForegroundColor White
    Write-Host "Detected locale: $($Defaults.locale)" -ForegroundColor DarkGray
    $input = Read-LineWithDefault -Prompt "Continue prompt" -Default ([string]$Defaults.continue_message)
    if ([string]::IsNullOrWhiteSpace($input)) {
        return [string]$Defaults.continue_message
    }
    return $input.Trim()
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
        [string[]]$Keywords,
        [int]$TailLength,
        [string]$ContinueMessage,
        [int]$MaxContinueLoops
    )

    $keywordList = New-Object System.Collections.Generic.List[string]
    foreach ($keyword in @($Keywords)) {
        $text = [string]$keyword
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            [void]$keywordList.Add($text.Trim())
        }
    }

    $payload = [ordered]@{
        source             = [string]$Source
        webhook_url        = [string]$WebhookUrl
        keywords           = $keywordList.ToArray()
        tail_length        = [int]$TailLength
        continue_message   = [string]$ContinueMessage
        max_continue_loops = [int]$MaxContinueLoops
    }
    return ($payload | ConvertTo-Json -Compress -Depth 5)
}

function Migrate-LegacyHookFiles {
    param(
        [string]$LegacyDir,
        [string]$ToolDir
    )

    if (-not (Test-Path $LegacyDir)) { return }
    New-Item -ItemType Directory -Path $ToolDir -Force | Out-Null
    foreach ($item in Get-ChildItem -Path $LegacyDir -File -ErrorAction SilentlyContinue) {
        $dest = Join-Path $ToolDir $item.Name
        if (-not (Test-Path $dest)) {
            Move-Item -Path $item.FullName -Destination $dest -Force
        }
    }
}

function Install-CursorHooks {
    param(
        [string]$PackageRoot,
        [string]$WebhookUrl,
        [object[]]$Keywords,
        [object]$Defaults
    )

    $cursorRoot = Join-Path $env:USERPROFILE ".cursor"
    $hooksDir = Join-Path $cursorRoot "tools\agent-webhook"
    Migrate-LegacyHookFiles -LegacyDir (Join-Path $cursorRoot "hooks") -ToolDir $hooksDir
    New-Item -ItemType Directory -Path $hooksDir -Force | Out-Null

    $runtimeDir = Join-Path $PackageRoot "runtime\windows"
    Copy-Item -Path (Join-Path $runtimeDir "hook-lib.ps1") -Destination $hooksDir -Force
    Copy-Item -Path (Join-Path $runtimeDir "webhook-on-prompt.*") -Destination $hooksDir -Force
    Copy-Item -Path (Join-Path $runtimeDir "webhook-on-response.*") -Destination $hooksDir -Force
    Copy-Item -Path (Join-Path $runtimeDir "auto-continue-flag.*") -Destination $hooksDir -Force
    Copy-Item -Path (Join-Path $runtimeDir "auto-continue-stop.*") -Destination $hooksDir -Force

    $configJson = New-HookConfigJson `
        -WebhookUrl $WebhookUrl `
        -Source "cursor" `
        -Keywords $Keywords `
        -TailLength ([int]$Defaults.tail_length) `
        -ContinueMessage ([string]$Defaults.continue_message) `
        -MaxContinueLoops ([int]$Defaults.max_continue_loops)
    [System.IO.File]::WriteAllText((Join-Path $hooksDir "hook-config.json"), $configJson, $script:HookUtf8)

    $hooksJson = @{
        version = 1
        hooks   = @{
            beforeSubmitPrompt = @(
                @{ command = "./tools/agent-webhook/webhook-on-prompt.cmd"; timeout = 15 }
            )
            afterAgentResponse = @(
                @{ command = "./tools/agent-webhook/webhook-on-response.cmd"; timeout = 15 },
                @{ command = "./tools/agent-webhook/auto-continue-flag.cmd"; timeout = 10 }
            )
            stop = @(
                @{ command = "./tools/agent-webhook/auto-continue-stop.cmd"; timeout = 10; loop_limit = [int]$Defaults.max_continue_loops }
            )
        }
    }

    $hooksPath = Join-Path $cursorRoot "hooks.json"
    $hooksText = ($hooksJson | ConvertTo-Json -Depth 6)
    [System.IO.File]::WriteAllText($hooksPath, $hooksText, $script:HookUtf8)
    Write-Ok "Installed Cursor hooks at $hooksDir"
}

function Install-CodexHooks {
    param(
        [string]$PackageRoot,
        [string]$WebhookUrl,
        [object[]]$Keywords,
        [object]$Defaults
    )

    $codexRoot = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE ".codex" }
    $hooksDir = Join-Path $codexRoot "tools\agent-webhook"
    Migrate-LegacyHookFiles -LegacyDir (Join-Path $codexRoot "hooks") -ToolDir $hooksDir
    New-Item -ItemType Directory -Path $hooksDir -Force | Out-Null

    $runtimeDir = Join-Path $PackageRoot "runtime\windows"
    Copy-Item -Path (Join-Path $runtimeDir "hook-lib.ps1") -Destination $hooksDir -Force
    Copy-Item -Path (Join-Path $runtimeDir "codex-user-prompt-webhook.*") -Destination $hooksDir -Force
    Copy-Item -Path (Join-Path $runtimeDir "codex-stop-webhook-continue.*") -Destination $hooksDir -Force

    $configJson = New-HookConfigJson `
        -WebhookUrl $WebhookUrl `
        -Source "codex" `
        -Keywords $Keywords `
        -TailLength ([int]$Defaults.tail_length) `
        -ContinueMessage ([string]$Defaults.continue_message) `
        -MaxContinueLoops ([int]$Defaults.max_continue_loops)
    [System.IO.File]::WriteAllText((Join-Path $hooksDir "hook-config.json"), $configJson, $script:HookUtf8)

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
    [System.IO.File]::WriteAllText($hooksPath, $hooksText, $script:HookUtf8)
    Write-Ok "Installed Codex hooks at $hooksDir"
    Write-Warn "In Codex, run /hooks to trust hooks after installing."
}

Write-Host ""
Write-Host "Agent Webhook + Auto Continue Installer (Windows)" -ForegroundColor Magenta
Write-Host "=================================================" -ForegroundColor Magenta

$packageRoot = Get-PackageRoot
Write-Info "Scanning Cursor/Codex transcripts to detect conversation language..."
$defaults = Resolve-LocaleDefaults -PackageRoot $packageRoot
Write-Ok "Using $($defaults.locale) locale defaults"

$existingConfigPath = Get-ExistingHookConfigPath
$existingConfig = Read-ExistingHookConfig -ConfigPath $existingConfigPath
if ($null -ne $existingConfig) {
    Write-Ok "Loaded previous settings from $existingConfigPath"
}
$appliedDefaults = Apply-ExistingHookConfig -Defaults $defaults -Existing $existingConfig
$defaults = $appliedDefaults.Defaults

$webhookUrl = Prompt-WebhookUrl -Default $appliedDefaults.WebhookUrl
$keywords = Prompt-Keywords -Defaults $defaults
$defaults.continue_message = Prompt-ContinueMessage -Defaults $defaults

$installCursor = Prompt-YesNo "Install for Cursor?" $true
$installCodex = Prompt-YesNo "Install for Codex?" $true

if (-not $installCursor -and -not $installCodex) {
    Write-Warn "No tools selected. Exiting."
    exit 1
}

if ($installCursor) {
    Install-CursorHooks -PackageRoot $packageRoot -WebhookUrl $webhookUrl -Keywords $keywords -Defaults $defaults
}

if ($installCodex) {
    Install-CodexHooks -PackageRoot $packageRoot -WebhookUrl $webhookUrl -Keywords $keywords -Defaults $defaults
}

Write-Host ""
Write-Ok "Installation complete. Restart Cursor/Codex to apply hooks."
if ([string]::IsNullOrWhiteSpace($webhookUrl)) {
    Write-Warn "Webhooks disabled (empty URL). Auto-continue only."
}
