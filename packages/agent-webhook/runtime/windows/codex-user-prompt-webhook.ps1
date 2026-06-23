$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "hook-lib.ps1")

try {
    if (-not (Test-WebhookEnabled)) {
        exit 0
    }

    $hookData = Read-CodexHookPayloadObject
    if (-not $hookData) {
        exit 0
    }

    $sessionId = [string](Get-HookField $hookData "session_id")
    $turnId = [string](Get-HookField $hookData "turn_id")
    $promptText = [string](Get-HookField $hookData "prompt")

    if ([string]::IsNullOrWhiteSpace($promptText)) {
        Write-HookLog -LogFileName "codex-hooks.log" -Message "Skip prompt webhook: empty prompt session_id=$sessionId"
        exit 0
    }

    try {
        $outbound = [ordered]@{
            source          = "codex"
            direction       = "user_prompt"
            event           = Get-HookField $hookData "hook_event_name"
            session_id      = $sessionId
            turn_id         = $turnId
            model           = Get-HookField $hookData "model"
            text            = $promptText
            cwd             = Get-HookField $hookData "cwd"
            transcript_path = Get-HookField $hookData "transcript_path"
            timestamp       = (Get-Date).ToString("o")
        }
        Send-WebhookPayload -Outbound $outbound
        Write-HookLog -LogFileName "codex-hooks.log" -Message "Prompt webhook sent session_id=$sessionId turn_id=$turnId"
    }
    catch {
        Write-HookLog -LogFileName "codex-hooks.log" -Message "Prompt webhook error session_id=$sessionId : $($_.Exception.Message)"
    }

    exit 0
}
catch {
    Write-HookLog -LogFileName "codex-hooks.log" -Message "UserPromptSubmit hook error: $($_.Exception.Message)"
    exit 0
}
