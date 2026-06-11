$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "hook-lib.ps1")

try {
    $hookData = Read-CodexHookPayloadObject
    if (-not $hookData) {
        exit 0
    }

    $sessionId = [string](Get-HookField $hookData "session_id")
    $turnId = [string](Get-HookField $hookData "turn_id")
    $assistantText = [string](Get-HookField $hookData "last_assistant_message")

    if (Test-WebhookEnabled -and -not [string]::IsNullOrWhiteSpace($assistantText)) {
        try {
            $config = Get-HookConfig
            $outbound = [ordered]@{
                source           = "codex"
                direction        = "agent_response"
                event            = Get-HookField $hookData "hook_event_name"
                session_id       = $sessionId
                turn_id          = $turnId
                model            = Get-HookField $hookData "model"
                text             = $assistantText
                cwd              = Get-HookField $hookData "cwd"
                transcript_path  = Get-HookField $hookData "transcript_path"
                permission_mode  = Get-HookField $hookData "permission_mode"
                stop_hook_active = Get-HookField $hookData "stop_hook_active"
                timestamp        = (Get-Date).ToString("o")
            }
            Send-WebhookPayload -Outbound $outbound
            Write-HookLog -LogFileName "codex-hooks.log" -Message "Webhook sent session_id=$sessionId turn_id=$turnId"
        }
        catch {
            Write-HookLog -LogFileName "codex-hooks.log" -Message "Webhook error session_id=$sessionId : $($_.Exception.Message)"
        }
    }

    if (-not (Test-AgentTextContainsContinueKeyword -Text $assistantText)) {
        Reset-ContinueLoopCount -SessionId $sessionId
        exit 0
    }

    $loopCount = Get-ContinueLoopCount -SessionId $sessionId
    if ($loopCount -ge (Get-MaxContinueLoops)) {
        Write-HookLog -LogFileName "codex-hooks.log" -Message "Skip auto-continue: loop limit reached session_id=$sessionId count=$loopCount"
        exit 0
    }

    $nextLoop = Increment-ContinueLoopCount -SessionId $sessionId
    $reason = Get-ContinueMessage
    Write-HookStdoutJson -Object @{
        decision = "block"
        reason   = $reason
    }

    Write-HookLog -LogFileName "codex-hooks.log" -Message "Auto-continue session_id=$sessionId turn_id=$turnId loop=$nextLoop reason=$reason"
    exit 0
}
catch {
    Write-HookLog -LogFileName "codex-hooks.log" -Message "Stop hook error: $($_.Exception.Message)"
    exit 0
}
