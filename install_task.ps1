#requires -Version 3.0
<#
  安装 WeNet 自动登录计划任务（需要管理员权限）
  触发方式：当前用户登录 Windows 时自动运行 wenet_auto.ps1
#>
[CmdletBinding()]
param(
    [string]$TaskName = 'WeNetAutoLogin',
    [switch]$StartNow
)

$ErrorActionPreference = 'Stop'
$script:Root = $PSScriptRoot
if (-not $script:Root) { $script:Root = Split-Path -Parent $MyInvocation.MyCommand.Definition }

function Test-Admin {
    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

if (-not (Test-Admin)) {
    Write-Host '需要管理员权限。请右键点击 install_task.ps1（或 install.bat），选择“以管理员身份运行”。' -ForegroundColor Yellow
    pause
    exit 1
}

$scriptPath = Join-Path $script:Root 'wenet_auto.ps1'
if (-not (Test-Path -LiteralPath $scriptPath)) {
    Write-Host "找不到主脚本: $scriptPath" -ForegroundColor Red
    pause
    exit 1
}

$powerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$argument = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $scriptPath + '"'

$user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

$action = New-ScheduledTaskAction -Execute $powerShellExe -Argument $argument -WorkingDirectory $script:Root
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
$settings.Hidden = $false
$settings.DisallowStartIfOnBatteries = $false

try {
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description '电脑登录后自动完成 WeNet 校园网认证（必要时先下线一台在线设备）' -Force | Out-Null
    Write-Host ""
    Write-Host "已创建计划任务: $TaskName" -ForegroundColor Green
    Write-Host "触发方式: 当前用户（$user）登录 Windows 时自动运行"
    Write-Host "运行脚本: $scriptPath"
    Write-Host "日志目录: $(Join-Path $script:Root 'logs')"
    Write-Host ""
    Write-Host "提示: 登录后若 Wi-Fi 还没连上，脚本会自动等待（默认最多 5 分钟）。"
} catch {
    Write-Host ("创建计划任务失败: " + $_.Exception.Message) -ForegroundColor Red
    pause
    exit 1
}

if ($StartNow) {
    try {
        Start-ScheduledTask -TaskName $TaskName
        Write-Host "已立即启动一次任务。" -ForegroundColor Green
    } catch {
        Write-Host ("立即启动失败: " + $_.Exception.Message) -ForegroundColor Yellow
    }
}

Write-Host ""
pause
