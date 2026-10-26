#requires -Version 3.0
<#
  把校园网密码用 Windows DPAPI（当前用户）加密后写入 config.json
  用法：powershell -ExecutionPolicy Bypass -File .\tools\set_password.ps1
  注意：加密后的密码只能用同一个 Windows 用户（同一台电脑）解密；
        计划任务也是用同一个用户运行，所以可以正常解密。
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = ''
)

$ErrorActionPreference = 'Stop'

if (-not $ConfigPath) {
    $root = Split-Path -Parent $PSScriptRoot
    $ConfigPath = Join-Path $root 'config.json'
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Write-Host "找不到 $ConfigPath" -ForegroundColor Yellow
    Write-Host "请先把 config.example.json 复制为 config.json，并填好 account。" -ForegroundColor Yellow
    exit 1
}

$cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

if (-not $cfg.account -or ('' + $cfg.account) -like '你的*') {
    Write-Host '请先在 config.json 里填好 account（学号/工号），再运行本脚本。' -ForegroundColor Yellow
    exit 1
}

$secure = Read-Host '请输入校园网密码（输入内容不会显示）' -AsSecureString
$bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try {
    $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringUni($bstr)
} finally {
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
}

if ([string]::IsNullOrEmpty($plain)) {
    Write-Host '密码为空，已取消。' -ForegroundColor Yellow
    exit 1
}

$bytes = [System.Text.Encoding]::UTF8.GetBytes($plain)
if (-not ('System.Security.Cryptography.ProtectedData' -as [type])) {
    Add-Type -AssemblyName System.Security
}
$blob = [System.Security.Cryptography.ProtectedData]::Protect(
    $bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
$b64 = [Convert]::ToBase64String($blob)

$cfg | Add-Member -NotePropertyName 'passwordDpapi' -NotePropertyValue $b64 -Force
$cfg | Add-Member -NotePropertyName 'password' -NotePropertyValue '' -Force
($cfg | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $ConfigPath -Encoding UTF8

Write-Host ''
Write-Host '完成：密码已用 DPAPI 加密写入 config.json 的 passwordDpapi 字段，明文 password 已清空。' -ForegroundColor Green
Write-Host '提示：只能被当前 Windows 用户解密；换用户或重装系统后需要重新运行本脚本。' -ForegroundColor DarkGray
