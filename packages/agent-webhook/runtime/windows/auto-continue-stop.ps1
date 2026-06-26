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

    $conversationId = [string](Get-HookField $hookData "conversation_id")
    $generationId = [string](Get-HookField $hookData "generation_id")
    $status = [string](Get-HookField $hookData "status")
    $loopCount = Get-HookField $hookData "loop_count"

    if (-not (Test-ContinueFlag -ConversationId $conversationId)) {
        exit 0
    }

    $flag = Get-ContinueFlag -ConversationId $conversationId
    if (-not (Test-ContinueFlagForStop -ConversationId $conversationId -GenerationId $generationId)) {
        Clear-ContinueFlag -ConversationId $conversationId
        $flagGenerationId = [string](Get-HookField $flag "generation_id")
        Write-HookLog -LogFileName "auto-continue.log" -Message ("Cleared stale flag conversation_id=$conversationId flag_generation=$flagGenerationId stop_generation=$generationId")
        exit 0
    }

    if ($status -ne "completed") {
        Clear-ContinueFlag -ConversationId $conversationId
        Write-HookLog -LogFileName "auto-continue.log" -Message ("Cleared flag: status=$status conversation_id=$conversationId generation_id=$generationId")
        exit 0
    }

    Clear-ContinueFlag -ConversationId $conversationId
    $followupMessage = Get-ContinueMessage
    Write-HookStdoutJson -Object @{ followup_message = $followupMessage }
    Write-HookLog -LogFileName "auto-continue.log" -Message ("Sent followup_message conversation_id=$conversationId generation_id=$generationId loop_count=$loopCount text=$followupMessage")
    exit 0
}
catch {
    Write-HookLog -LogFileName "auto-continue.log" -Message ("Stop error: " + $_.Exception.Message)
    exit 0
}
