param(
    [string]$HookInputPath
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "hook-lib.ps1")

try {
    $hookData = Read-HookPayloadObject -HookInputPath $HookInputPath
    if (-not $hookData) {
        exit 0
    }

    $conversationId = Get-HookField $hookData "conversation_id"
    $generationId = Get-HookField $hookData "generation_id"
    $text = [string](Get-HookField $hookData "text")

    if (-not (Test-AgentTextContainsContinueKeyword -Text $text)) {
        exit 0
    }

    Set-ContinueFlag -ConversationId $conversationId -GenerationId $generationId
    $preview = if ($text.Length -le 120) { $text } else { $text.Substring(0, 120) + "..." }
    Write-HookLog -LogFileName "auto-continue.log" -Message ("Flag set conversation_id=$conversationId generation_id=$generationId preview=$preview")
    exit 0
}
catch {
    Write-HookLog -LogFileName "auto-continue.log" -Message ("Flag error: " + $_.Exception.Message)
    exit 0
}
