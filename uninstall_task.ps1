#requires -Version 3.0
<#
  卸载 WeNet 自动登录计划任务（需要管理员权限）
#>
[CmdletBinding()]
param(
    [string]$TaskName = 'WeNetAutoLogin'
)

$ErrorActionPreference = 'Stop'

function Test-Admin {
    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

if (-not (Test-Admin)) {
    Write-Host '需要管理员权限。请右键点击本脚本（或 uninstall.bat），选择“以管理员身份运行”。' -ForegroundColor Yellow
    pause
    exit 1
}

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if (-not $task) {
    Write-Host "没有找到计划任务: $TaskName" -ForegroundColor Yellow
} else {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "已删除计划任务: $TaskName" -ForegroundColor Green
}
Write-Host ""
pause
