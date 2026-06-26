$ErrorActionPreference = "Stop"

$script:HookUtf8 = [System.Text.UTF8Encoding]::new($false)
$script:HookRootDir = $PSScriptRoot
$script:HookConfig = $null

function Get-HookUtf8 {
    return $script:HookUtf8
}

function Get-HookRootDir {
    return $script:HookRootDir
}

function Get-HookConfig {
    if ($null -ne $script:HookConfig) {
        return $script:HookConfig
    }

    $configPath = Join-Path $script:HookRootDir "hook-config.json"
    if (-not (Test-Path $configPath)) {
        throw "Missing hook-config.json at $configPath"
    }

    $json = [System.IO.File]::ReadAllText($configPath, $script:HookUtf8)
    $script:HookConfig = Convert-HookJson -JsonText $json
    return $script:HookConfig
}

function Test-WebhookEnabled {
    $config = Get-HookConfig
    $url = [string](Get-HookField $config "webhook_url")
    return -not [string]::IsNullOrWhiteSpace($url)
}

function Get-WebhookUrl {
    $config = Get-HookConfig
    return [string](Get-HookField $config "webhook_url")
}

function Get-ContinueMessage {
    $config = Get-HookConfig
    $message = [string](Get-HookField $config "continue_message")
    if ([string]::IsNullOrWhiteSpace($message)) {
        return -join @(
            [char]0x0054, [char]0x0069, [char]0x1EBF, [char]0x0070,
            [char]0x0020, [char]0x0074, [char]0x1EE5, [char]0x0063
        )
    }
    return $message
}

function Get-MaxContinueLoops {
    $config = Get-HookConfig
    $value = Get-HookField $config "max_continue_loops"
    if ($null -eq $value -or "$value" -notmatch '^\d+$') {
        return 100
    }
    return [int]$value
}

function Get-TailLength {
    $config = Get-HookConfig
    $value = Get-HookField $config "tail_length"
    if ($null -eq $value -or "$value" -notmatch '^\d+$') {
        return 1000
    }
    return [int]$value
}

function Convert-HookBytesToText {
    param([byte[]]$Bytes)

    if ($null -eq $Bytes -or $Bytes.Length -eq 0) {
        return ""
    }

    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        $Bytes = $Bytes[3..($Bytes.Length - 1)]
    }

    return $script:HookUtf8.GetString($Bytes)
}

function Read-HookRawFile {
    param([string]$Path)
    return Convert-HookBytesToText -Bytes ([System.IO.File]::ReadAllBytes($Path))
}

function Get-CursorHookPayloadFile {
    $tempRoot = [System.IO.Path]::GetTempPath()
    $pattern = Join-Path $tempRoot "cursor-hook-payload-*.json"
    $cutoff = (Get-Date).AddSeconds(-5)

    $candidates = @(Get-ChildItem -Path $pattern -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $cutoff } |
        Sort-Object LastWriteTime -Descending)

    if ($candidates.Count -gt 0) {
        return $candidates[0].FullName
    }

    return $null
}

function Read-HookStdinBytes {
    $inputStream = [Console]::OpenStandardInput()
    if ($null -eq $inputStream) {
        return @()
    }

    $ms = New-Object System.IO.MemoryStream
    $buffer = New-Object byte[] 16384

    try {
        while (($read = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $ms.Write($buffer, 0, $read)
        }
    }
    finally {
        $inputStream.Dispose()
    }

    return $ms.ToArray()
}

function Read-HookInput {
    param([string]$HookInputPath)

    if (-not [string]::IsNullOrWhiteSpace($HookInputPath) -and (Test-Path $HookInputPath)) {
        return @{
            Raw    = (Read-HookRawFile -Path $HookInputPath)
            Source = $HookInputPath
        }
    }

    $cursorPayloadFile = Get-CursorHookPayloadFile
    if ($cursorPayloadFile) {
        return @{
            Raw    = (Read-HookRawFile -Path $cursorPayloadFile)
            Source = $cursorPayloadFile
        }
    }

    return @{
        Raw    = (Convert-HookBytesToText -Bytes (Read-HookStdinBytes))
        Source = "stdin"
    }
}

function Get-HookJsonCandidate {
    param([string]$PayloadText)

    $start = $PayloadText.IndexOf("{")
    if ($start -lt 0) { return $null }

    $depth = 0
    $inString = $false
    $escape = $false

    for ($i = $start; $i -lt $PayloadText.Length; $i++) {
        $ch = $PayloadText[$i]

        if ($inString) {
            if ($escape) { $escape = $false; continue }
            if ($ch -eq "\") { $escape = $true; continue }
            if ($ch -eq '"') { $inString = $false }
            continue
        }

        if ($ch -eq '"') { $inString = $true; continue }
        if ($ch -eq "{") { $depth++; continue }
        if ($ch -eq "}") {
            $depth--
            if ($depth -eq 0) {
                return $PayloadText.Substring($start, $i - $start + 1)
            }
        }
    }

    return $null
}

function Convert-HookJson {
    param([string]$JsonText)

    try {
        return (ConvertFrom-Json -InputObject $JsonText -ErrorAction Stop)
    }
    catch {
        $firstError = $_.Exception.Message
    }

    try {
        Add-Type -AssemblyName System.Web.Extensions
        $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $serializer.MaxJsonLength = 104857600
        return $serializer.DeserializeObject($JsonText)
    }
    catch {
        $secondError = $_.Exception.Message
    }

    throw "ConvertFrom-Json: $firstError | JavaScriptSerializer: $secondError"
}

function Get-HookField {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function Read-HookPayloadObject {
    param([string]$HookInputPath = "")

    $input = Read-HookInput -HookInputPath $HookInputPath
    $normalized = $input.Raw.Trim().TrimStart([char]0xFEFF).Trim()

    if ([string]::IsNullOrWhiteSpace($normalized) -or $normalized.IndexOf("{") -lt 0) {
        return $null
    }

    try {
        return Convert-HookJson -JsonText $normalized
    }
    catch {
        $candidate = Get-HookJsonCandidate -PayloadText $normalized
        if ($candidate) {
            return Convert-HookJson -JsonText $candidate
        }
        throw
    }
}

function Read-CodexHookPayloadObject {
    $raw = (Convert-HookBytesToText -Bytes (Read-HookStdinBytes)).Trim().TrimStart([char]0xFEFF).Trim()
    if ([string]::IsNullOrWhiteSpace($raw) -or $raw.IndexOf("{") -lt 0) {
        return $null
    }

    try {
        return Convert-HookJson -JsonText $raw
    }
    catch {
        $candidate = Get-HookJsonCandidate -PayloadText $raw
        if ($candidate) {
            return Convert-HookJson -JsonText $candidate
        }
        throw
    }
}

function Test-AgentTextContainsContinueKeyword {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $false
    }

    $tailLength = Get-TailLength
    if ($Text.Length -gt $tailLength) {
        $Text = $Text.Substring($Text.Length - $tailLength)
    }

    $config = Get-HookConfig
    $keywords = @(Get-HookField $config "keywords")
    if ($keywords.Count -eq 0) {
        return $false
    }

    $options = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    foreach ($keyword in $keywords) {
        $pattern = [regex]::Escape([string]$keyword)
        if ([regex]::IsMatch($Text, $pattern, $options)) {
            return $true
        }
    }

    return $false
}

function Get-ContinueFlagPath {
    param([string]$ConversationId)

    $stateDir = Join-Path $script:HookRootDir "state"
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    $safeId = ($ConversationId -replace '[^\w\-]', '_')
    return Join-Path $stateDir ("continue-$safeId.flag")
}

function Set-ContinueFlag {
    param(
        [string]$ConversationId,
        [string]$GenerationId
    )

    if ([string]::IsNullOrWhiteSpace($ConversationId)) {
        return
    }

    $path = Get-ContinueFlagPath -ConversationId $ConversationId
    $payload = @{
        conversation_id = $ConversationId
        generation_id   = $GenerationId
        created_at      = (Get-Date).ToString("o")
    } | ConvertTo-Json -Compress

    [System.IO.File]::WriteAllText($path, $payload, $script:HookUtf8)
}

function Get-ContinueFlag {
    param([string]$ConversationId)

    if ([string]::IsNullOrWhiteSpace($ConversationId)) {
        return $null
    }

    $path = Get-ContinueFlagPath -ConversationId $ConversationId
    if (-not (Test-Path $path)) {
        return $null
    }

    try {
        $json = [System.IO.File]::ReadAllText($path, $script:HookUtf8)
        return Convert-HookJson -JsonText $json
    }
    catch {
        return $null
    }
}

function Test-ContinueFlag {
    param([string]$ConversationId)
    return ($null -ne (Get-ContinueFlag -ConversationId $ConversationId))
}

function Get-ContinueFlagMaxAgeSeconds {
    $config = Get-HookConfig
    $value = Get-HookField $config "continue_flag_max_age_seconds"
    if ($null -eq $value -or "$value" -notmatch '^\d+$') {
        return 120
    }
    return [int]$value
}

function Test-ContinueFlagFresh {
    param($Flag)

    $createdAt = [string](Get-HookField $Flag "created_at")
    if ([string]::IsNullOrWhiteSpace($createdAt)) {
        return $true
    }

    try {
        $created = [datetime]::Parse(
            $createdAt,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind
        )
        $ageSeconds = ((Get-Date).ToUniversalTime() - $created.ToUniversalTime()).TotalSeconds
        if ($ageSeconds -lt 0) {
            $ageSeconds = 0
        }
        return ($ageSeconds -le (Get-ContinueFlagMaxAgeSeconds))
    }
    catch {
        return $true
    }
}

function Test-ContinueFlagForGeneration {
    param(
        [string]$ConversationId,
        [string]$GenerationId
    )

    $flag = Get-ContinueFlag -ConversationId $ConversationId
    if (-not $flag) {
        return $false
    }

    $flagGenerationId = [string](Get-HookField $flag "generation_id")
    if ([string]::IsNullOrWhiteSpace($flagGenerationId) -or [string]::IsNullOrWhiteSpace($GenerationId)) {
        return $false
    }

    return $flagGenerationId -eq $GenerationId
}

function Test-ContinueFlagForStop {
    param(
        [string]$ConversationId,
        [string]$GenerationId
    )

    $flag = Get-ContinueFlag -ConversationId $ConversationId
    if (-not $flag) {
        return $false
    }

    $flagGenerationId = [string](Get-HookField $flag "generation_id")
    if (-not [string]::IsNullOrWhiteSpace($flagGenerationId) -and
            -not [string]::IsNullOrWhiteSpace($GenerationId) -and
            $flagGenerationId -eq $GenerationId) {
        return $true
    }

    # Cursor may pass a different generation_id on stop than afterAgentResponse.
    return (Test-ContinueFlagFresh -Flag $flag)
}

function Clear-ContinueFlag {
    param([string]$ConversationId)

    if ([string]::IsNullOrWhiteSpace($ConversationId)) {
        return
    }

    $path = Get-ContinueFlagPath -ConversationId $ConversationId
    if (Test-Path $path) {
        Remove-Item $path -Force -ErrorAction SilentlyContinue
    }
}

function Get-ContinueLoopPath {
    param([string]$SessionId)

    $stateDir = Join-Path $script:HookRootDir "state"
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    $safeId = ($SessionId -replace '[^\w\-]', '_')
    return Join-Path $stateDir ("continue-loop-$safeId.txt")
}

function Get-ContinueLoopCount {
    param([string]$SessionId)

    $path = Get-ContinueLoopPath -SessionId $SessionId
    if (-not (Test-Path $path)) {
        return 0
    }

    $value = [System.IO.File]::ReadAllText($path, $script:HookUtf8).Trim()
    if ($value -match '^\d+$') {
        return [int]$value
    }

    return 0
}

function Increment-ContinueLoopCount {
    param([string]$SessionId)

    $path = Get-ContinueLoopPath -SessionId $SessionId
    $next = (Get-ContinueLoopCount -SessionId $SessionId) + 1
    [System.IO.File]::WriteAllText($path, "$next", $script:HookUtf8)
    return $next
}

function Reset-ContinueLoopCount {
    param([string]$SessionId)

    $path = Get-ContinueLoopPath -SessionId $SessionId
    if (Test-Path $path) {
        Remove-Item $path -Force -ErrorAction SilentlyContinue
    }
}

function Write-HookLog {
    param(
        [string]$LogFileName,
        [string]$Message
    )

    $logFile = Join-Path $script:HookRootDir $LogFileName
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    [System.IO.File]::AppendAllText($logFile, "[$timestamp] $Message`n", $script:HookUtf8)
}

function Write-HookStdoutJson {
    param([hashtable]$Object)

    Add-Type -AssemblyName System.Web.Extensions
    $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $serializer.MaxJsonLength = 104857600
    $json = $serializer.Serialize($Object)
    $bytes = $script:HookUtf8.GetBytes($json)
    $stdout = [Console]::OpenStandardOutput()
    $stdout.Write($bytes, 0, $bytes.Length)
    $stdout.Flush()
}

function Send-WebhookPayload {
    param([hashtable]$Outbound)

    if (-not (Test-WebhookEnabled)) {
        return
    }

    Add-Type -AssemblyName System.Web.Extensions
    $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $serializer.MaxJsonLength = 104857600
    $body = $serializer.Serialize($Outbound)

    Invoke-RestMethod `
        -Uri (Get-WebhookUrl) `
        -Method Post `
        -Body ($script:HookUtf8.GetBytes($body)) `
        -ContentType "application/json; charset=utf-8" `
        -TimeoutSec 12 | Out-Null
}
