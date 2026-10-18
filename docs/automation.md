# Automatic handoff after closing Codex

Starting a child process from a desktop app is not reliable when the app exits. For a one-shot migration, register the worker with Task Scheduler under the interactive user, then start the task. The worker waits for ChatGPT/Codex/VS Code processes, removes its own task after success or refusal, and opens `codex:` again.

```powershell
$taskName = 'Codex-LocalLogs-Migration-<run-id>'
$worker = 'J:\path\to\migrate-encrypted-logs-after-exit.ps1'
$pwsh = 'C:\Program Files\PowerShell\7\pwsh.exe'
$args = "-NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$worker`" -Source `"C:\Users\<user>\AppData\Local\Codex\Logs`" -Target `"J:\codex\.codex-data\desktop-app\Local\Codex\Logs` -TaskName `"$taskName`""
$action = New-ScheduledTaskAction -Execute $pwsh -Argument $args
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1)
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Force
Start-ScheduledTask -TaskName $taskName
```

Do not create a recurring task for this workflow. If the worker cannot preserve EFS encryption, it must leave the C: source untouched and still reopen Codex. Remove any orphaned task only after inspecting its final state and log.