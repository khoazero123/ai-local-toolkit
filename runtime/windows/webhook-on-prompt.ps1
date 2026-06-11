param(
    [string]$HookInputPath
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "hook-lib.ps1")

try {
    if (-not (Test-WebhookEnabled)) {
        exit 0
    }

    $hookData = Read-HookPayloadObject -HookInputPath $HookInputPath
    if (-not $hookData) {
        exit 0
    }

    $promptText = [string](Get-HookField $hookData "prompt")
    if ([string]::IsNullOrWhiteSpace($promptText)) {
        $promptText = [string](Get-HookField $hookData "text")
    }

    if ([string]::IsNullOrWhiteSpace($promptText)) {
        exit 0
    }

    $config = Get-HookConfig
    $outbound = [ordered]@{
        source             = [string](Get-HookField $config "source")
        direction          = "user_prompt"
        event              = Get-HookField $hookData "hook_event_name"
        conversation_id    = Get-HookField $hookData "conversation_id"
        generation_id      = Get-HookField $hookData "generation_id"
        model              = Get-HookField $hookData "model"
        composer_mode      = Get-HookField $hookData "composer_mode"
        text               = $promptText
        session_id         = Get-HookField $hookData "session_id"
        workspace_roots    = @(Get-HookField $hookData "workspace_roots")
        transcript_path    = Get-HookField $hookData "transcript_path"
        timestamp          = (Get-Date).ToString("o")
    }

    Send-WebhookPayload -Outbound $outbound
    Write-HookLog -LogFileName "webhook-on-prompt.log" -Message ("Sent prompt webhook for conversation_id=" + (Get-HookField $hookData 'conversation_id'))
    exit 0
}
catch {
    Write-HookLog -LogFileName "webhook-on-prompt.log" -Message ("Webhook error: " + $_.Exception.Message)
    exit 0
}
