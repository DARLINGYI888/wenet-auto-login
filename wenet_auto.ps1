#requires -Version 3.0
<#
  WeNet 校园网自动登录脚本（Windows）
  适用于 WeNet 门户；示例：某高校 WeNet 门户，portal 10.112.0.10
  版本：1.2.0  许可证：MIT
  规则（按用户要求）：
    - 只在「开机后第一次登录 Windows」时运行一次，跑完即退出；运行期间不后台监控、不自动重连。
    - 没有登录则尝试登录；账号设备名额已满时：优先下线 PC；若全是手机/平板则随机下线一台，然后重新登录。
    - 若同时开着手机热点，自动补一条到认证服务器的临时路由（需管理员权限）。

  用法：
    powershell -ExecutionPolicy Bypass -File wenet_auto.ps1             # 正常自动登录
    powershell -ExecutionPolicy Bypass -File wenet_auto.ps1 -DryRun     # 演练：只查看，不真正下线/登录
    powershell -ExecutionPolicy Bypass -File wenet_auto.ps1 -Force      # 忽略"10 分钟内已跑过"的限制
    powershell -ExecutionPolicy Bypass -File wenet_auto.ps1 -SelfTest   # 自检：验证下线选择规则`n    powershell -ExecutionPolicy Bypass -File wenet_auto.ps1 -ShowVersion # 显示版本
#>

[CmdletBinding()]
param(
    [string]$ConfigPath = '',
    [switch]$DryRun,
    [switch]$Force,
    [switch]$SelfTest,
    [switch]$ShowVersion
)

$ErrorActionPreference = 'Stop'

# ---------------- 基础环境 ----------------
$script:Root = $PSScriptRoot
if (-not $script:Root) { $script:Root = Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $ConfigPath) { $ConfigPath = Join-Path $script:Root 'config.json' }
$script:LogDir = Join-Path $script:Root 'logs'
if (-not (Test-Path -LiteralPath $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
$script:LogFile = Join-Path $script:LogDir ('wenet-' + (Get-Date -Format 'yyyyMMdd') + '.log')
$script:RunId = ([guid]::NewGuid().ToString('N')).Substring(0, 6)
$script:Version = '1.2.0'
$script:Cfg = $null
$script:Token = $null
$script:PortalBase = ''
$script:RefUrl = ''
$script:UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 Edg/130.0.0.0'
$script:AesKey = '1234567890000000'

# ---------------- 日志 ----------------
function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')][string]$Level = 'INFO'
    )
    $line = '{0} [{1}] [{2}] {3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $script:RunId, $Message
    try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 } catch { }
    try { Write-Host $line } catch { }
}

function Clear-OldLogs {
    param([int]$Days = 14)
    if ($Days -le 0) { return }
    try {
        Get-ChildItem -LiteralPath $script:LogDir -Filter 'wenet-*.log' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$Days) } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch { }
}

# ---------------- 运行状态（防止短时间内重复执行/重复下线） ----------------
function Get-StatePath { return (Join-Path $script:Root 'state.json') }

function Read-RunState {
    try {
        $path = Get-StatePath
        if (-not (Test-Path -LiteralPath $path)) { return $null }
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json)
    } catch { return $null }
}

function Write-RunState {
    param([string]$Result, [int]$ExitCode)
    try {
        $obj = [ordered]@{
            lastRun    = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            lastRunUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            result     = $Result
            exitCode   = $ExitCode
            computer   = $env:COMPUTERNAME
        }
        ($obj | ConvertTo-Json -Compress) | Set-Content -LiteralPath (Get-StatePath) -Encoding UTF8
    } catch { }
}

# ---------------- 配置 ----------------
function Set-CfgDefault {
    param($Object, [string]$Name, $Value)
    if ($null -eq $Object.PSObject.Properties[$Name] -or $null -eq $Object.$Name) {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    }
}

function Get-Cfg {
    if ($script:Cfg) { return $script:Cfg }
    if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "找不到配置文件: $ConfigPath" }
    $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
    $cfg = $raw | ConvertFrom-Json

    Set-CfgDefault $cfg 'portalIp' '10.112.0.10'
    Set-CfgDefault $cfg 'nasIp' '10.112.1.253'
    Set-CfgDefault $cfg 'wlanacname' ''
    Set-CfgDefault $cfg 'deviceType' 'PC'
    Set-CfgDefault $cfg 'campusIpPrefixes' @('10.111.')
    Set-CfgDefault $cfg 'campusGatewayFallback' '10.111.0.1'
    Set-CfgDefault $cfg 'autoAddCampusRoute' $true
    Set-CfgDefault $cfg 'kickPreference' @('PC')
    Set-CfgDefault $cfg 'neverKickMacs' @()
    Set-CfgDefault $cfg 'kickFallback' 'random'
    Set-CfgDefault $cfg 'kickRules' @()
    Set-CfgDefault $cfg 'protectDeviceTypes' @()
    Set-CfgDefault $cfg 'protectIpPrefixes' @()
    Set-CfgDefault $cfg 'maxKickPerRun' 3
    Set-CfgDefault $cfg 'kickWaitSeconds' 1
    Set-CfgDefault $cfg 'startupWaitSeconds' 300
    Set-CfgDefault $cfg 'retryIntervalSeconds' 5
    Set-CfgDefault $cfg 'maxAttempts' 4
    Set-CfgDefault $cfg 'logRetentionDays' 14

    $account = '' + $cfg.account
    $password = ''
    if ($cfg.PSObject.Properties['password'] -and $cfg.password) { $password = '' + $cfg.password }

    # 可选：用 Windows DPAPI 加密保存密码（tools/set_password.ps1 生成 passwordDpapi）
    if ($cfg.PSObject.Properties['passwordDpapi'] -and $cfg.passwordDpapi) {
        try {
            if (-not ('System.Security.Cryptography.ProtectedData' -as [type])) {
                foreach ($asmName in @('System.Security', 'System.Security.Cryptography.ProtectedData')) {
                    try { Add-Type -AssemblyName $asmName -ErrorAction Stop; break } catch { }
                }
            }
            $blob = [Convert]::FromBase64String([string]$cfg.passwordDpapi)
            $plainBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
                $blob, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
            $password = [System.Text.Encoding]::UTF8.GetString($plainBytes)
        } catch {
            throw 'passwordDpapi 解密失败：请用同一个 Windows 用户运行，或重新执行 tools/set_password.ps1'
        }
    }

    if (-not $account -or -not $password) { throw 'config.json 里 account / password 不能为空' }
    $cfg | Add-Member -NotePropertyName 'account' -NotePropertyValue $account -Force
    $cfg | Add-Member -NotePropertyName 'password' -NotePropertyValue $password -Force

    $script:Cfg = $cfg
    $script:PortalBase = 'http://' + $cfg.portalIp
    return $script:Cfg
}

# ---------------- 网络信息 ----------------
function Test-Admin {
    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Get-CampusInterface {
    param([string[]]$Prefixes)

    $candidates = @()
    foreach ($ni in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        try {
            if ($ni.OperationalStatus -ne [System.Net.NetworkInformation.OperationalStatus]::Up) { continue }
            $props = $ni.GetIPProperties()
            $ipv4 = $null
            foreach ($ua in $props.UnicastAddresses) {
                if ($ua.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
                    $ipv4 = $ua.Address.ToString()
                    break
                }
            }
            if (-not $ipv4) { continue }
            $matched = $false
            foreach ($prefix in $Prefixes) {
                if ($ipv4.StartsWith($prefix)) { $matched = $true; break }
            }
            if (-not $matched) { continue }

            $gateway = $null
            foreach ($g in $props.GatewayAddresses) {
                if ($g.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
                    $gateway = $g.Address.ToString()
                    break
                }
            }
            $mac = ''
            $pa = $ni.GetPhysicalAddress()
            if ($pa) {
                $bytes = $pa.GetAddressBytes()
                if ($bytes.Length -eq 6) { $mac = (($bytes | ForEach-Object { $_.ToString('x2') }) -join '-') }
            }
            $candidates += [pscustomobject]@{
                Name    = $ni.Name
                Type    = $ni.NetworkInterfaceType
                IP      = $ipv4
                MAC     = $mac
                Gateway = $gateway
            }
        } catch { }
    }

    if ($candidates.Count -eq 0) { return $null }
    $wireless = $candidates | Where-Object { $_.Type -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Wireless80211 }
    if ($wireless) { return @($wireless)[0] }
    return $candidates[0]
}

function Set-CampusRoute {
    param($Interface)
    if (-not $script:Cfg.autoAddCampusRoute) { return }
    $gateway = $Interface.Gateway
    if (-not $gateway) { $gateway = $script:Cfg.campusGatewayFallback }
    if (-not $gateway) { return }
    if (-not (Test-Admin)) {
        Write-Log '当前进程不是管理员，跳过补路由（若同时开着手机热点，可能访问不到认证页）' 'WARN'
        return
    }
    $parts = ($script:Cfg.portalIp + '').Split('.')
    if ($parts.Length -lt 2) { return }
    $network = $parts[0] + '.' + $parts[1] + '.0.0'
    try {
        & route.exe add $network mask 255.255.0.0 $gateway metric 1 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { & route.exe change $network mask 255.255.0.0 $gateway metric 1 2>&1 | Out-Null }
        Write-Log ("已确保校园网路由: $network/16 -> $gateway")
    } catch {
        Write-Log ('补路由失败: ' + $_.Exception.Message) 'WARN'
    }
}

function Test-PortalReachable {
    try {
        $req = [System.Net.HttpWebRequest]::Create($script:PortalBase + '/')
        $req.Method = 'GET'
        $req.Proxy = New-Object System.Net.WebProxy
        $req.Timeout = 5000
        $req.ReadWriteTimeout = 5000
        $req.AllowAutoRedirect = $false
        $req.UserAgent = $script:UserAgent
        try {
            $resp = $req.GetResponse()
            $resp.Close()
            return $true
        } catch [System.Net.WebException] {
            if ($_.Exception.Response) { $_.Exception.Response.Close(); return $true }
            return $false
        }
    } catch { return $false }
}

# ---------------- AES（AES-128-CBC / PKCS7，key=iv=1234567890000000） ----------------
function ConvertTo-AesHex {
    param([Parameter(Mandatory = $true)][string]$Plain)
    $key = [System.Text.Encoding]::ASCII.GetBytes($script:AesKey)
    $aes = [System.Security.Cryptography.Aes]::Create()
    try {
        $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
        $aes.Key = $key
        $aes.IV = $key
        $enc = $aes.CreateEncryptor()
        try {
            $data = [System.Text.Encoding]::UTF8.GetBytes($Plain)
            $out = $enc.TransformFinalBlock($data, 0, $data.Length)
        } finally { $enc.Dispose() }
    } finally { $aes.Dispose() }
    $sb = New-Object System.Text.StringBuilder
    foreach ($b in $out) { [void]$sb.Append($b.ToString('x2')) }
    return $sb.ToString()
}

function ConvertFrom-AesHex {
    param([Parameter(Mandatory = $true)][string]$Hex)
    $hex = $Hex.Trim()
    if ($hex.Length % 2 -ne 0) { throw '密文长度不是偶数' }
    $key = [System.Text.Encoding]::ASCII.GetBytes($script:AesKey)
    $count = [int]($hex.Length / 2)
    $data = New-Object byte[] $count
    for ($i = 0; $i -lt $count; $i++) { $data[$i] = [Convert]::ToByte($hex.Substring($i * 2, 2), 16) }
    $aes = [System.Security.Cryptography.Aes]::Create()
    try {
        $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
        $aes.Key = $key
        $aes.IV = $key
        $dec = $aes.CreateDecryptor()
        try {
            $out = $dec.TransformFinalBlock($data, 0, $data.Length)
        } finally { $dec.Dispose() }
    } finally { $aes.Dispose() }
    return [System.Text.Encoding]::UTF8.GetString($out)
}

# ---------------- 门户 HTTP ----------------
function Invoke-PortalApi {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$PlainBody = $null,
        [int]$TimeoutSec = 15
    )

    $url = $script:PortalBase + $Path
    $req = [System.Net.HttpWebRequest]::Create($url)
    $req.Method = 'POST'
    $req.Proxy = New-Object System.Net.WebProxy
    $req.Timeout = $TimeoutSec * 1000
    $req.ReadWriteTimeout = $TimeoutSec * 1000
    $req.UserAgent = $script:UserAgent
    $req.Accept = 'application/json, text/plain, */*'
    $req.Referer = $script:RefUrl
    $req.ContentType = 'application/json;charset=UTF-8'
    try { $req.Headers.Add('Origin', $script:PortalBase) } catch { }
    if ($script:Token) {
        try { $req.Headers.Add('Authorization', $script:Token) } catch { }
    }

    $bytes = [byte[]]@()
    if ($null -ne $PlainBody -and $PlainBody.Length -gt 0) {
        $hex = ConvertTo-AesHex $PlainBody
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($hex)
    }
    $req.ContentLength = $bytes.Length
    if ($bytes.Length -gt 0) {
        $rs = $req.GetRequestStream()
        try { $rs.Write($bytes, 0, $bytes.Length) } finally { $rs.Close() }
    }

    $resp = $null
    try {
        $resp = $req.GetResponse()
    } catch [System.Net.WebException] {
        if ($_.Exception.Response) { $resp = $_.Exception.Response }
        else { throw }
    }

    $status = 0
    $body = ''
    try {
        $status = [int]$resp.StatusCode
        $stream = $resp.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
        try { $body = $reader.ReadToEnd() } finally { $reader.Close() }
    } finally {
        if ($resp) { $resp.Close() }
    }
    return [pscustomobject]@{ Status = $status; Body = $body }
}

function ConvertFrom-PortalBody {
    param([string]$Body)
    if ([string]::IsNullOrWhiteSpace($Body)) { return $null }
    $text = $Body.Trim()
    if ($text.StartsWith('"') -and $text.EndsWith('"') -and $text.Length -ge 2) {
        $text = $text.Substring(1, $text.Length - 2)
    }
    if ($text.Length % 2 -eq 0 -and $text -match '^[0-9a-fA-F]+$') {
        try {
            $plain = ConvertFrom-AesHex $text
            if ([string]::IsNullOrWhiteSpace($plain)) { return $null }
            return ($plain | ConvertFrom-Json)
        } catch { return $null }
    }
    try { return ($text | ConvertFrom-Json) } catch { return $null }
}

# ---------------- 业务接口 ----------------
function Get-SessionList {
    $resp = Invoke-PortalApi -Path '/portal-conversion/api/v3/session/list' -PlainBody ''
    $data = ConvertFrom-PortalBody -Body $resp.Body
    if ($resp.Status -ne 200) {
        Write-Log ("查询在线设备失败: HTTP $($resp.Status) " + $resp.Body) 'WARN'
        return @()
    }
    if ($data -and $data.sessions) { return @($data.sessions) }
    return @()
}

# ---------------- 下线规则引擎 ----------------
function Get-SessionStartTime {
    param($Session)
    try {
        return [datetime]::ParseExact(('' + $Session.acct_start_time), 'yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
    } catch {
        try { return [datetime]::Parse(('' + $Session.acct_start_time), [System.Globalization.CultureInfo]::InvariantCulture) }
        catch { return [datetime]::MaxValue }
    }
}

# 仅去掉分隔符（冒号/横线/空格）并转小写；保留 * ? [ ] 等通配符
function ConvertTo-MacNormalized {
    param([string]$Mac)
    if ($null -eq $Mac) { return '' }
    return (('' + $Mac).ToLowerInvariant() -replace '[\s:\-]', '')
}

function Test-MacPattern {
    param([string]$Mac, [string]$Pattern)
    $m = ConvertTo-MacNormalized $Mac
    $p = ConvertTo-MacNormalized $Pattern
    if (-not $m -or -not $p) { return $false }
    return ($m -like $p)
}

function Test-DeviceTypePattern {
    param([string]$DeviceType, $Patterns)
    $dt = ('' + $DeviceType).ToUpperInvariant()
    foreach ($pat in @($Patterns)) {
        if ($null -eq $pat) { continue }
        $p = ('' + $pat).ToUpperInvariant()
        if (-not $p) { continue }
        if ($dt -like $p) { return $true }
    }
    return $false
}

# 规则匹配字段（大小写不敏感）：
#   deviceType: ["PC"] / ["ANDROID", "IOS"]（支持通配符）
#   mac:        ["02:00:00:00:00:0*"]（支持 * 和 ?，冒号/横线均可）
#   ipPrefix:   ["10.111.1."]
#   username:   "245125"（支持通配符）
#   olderThanMinutes: 60   （只匹配在线超过 N 分钟的设备）
#   newerThanMinutes: 5    （只匹配在线不足 N 分钟的设备）
function Test-SessionMatch {
    param($Session, $Match)
    if ($null -eq $Match) { return $true }

    foreach ($prop in @($Match.PSObject.Properties)) {
        $key = ('' + $prop.Name).ToLowerInvariant()
        $val = $prop.Value
        switch ($key) {
            'devicetype' {
                if (-not (Test-DeviceTypePattern $Session.deviceType $val)) { return $false }
            }
            'mac' {
                $macOk = $false
                foreach ($pat in @($val)) {
                    if (Test-MacPattern $Session.calling_station_id $pat) { $macOk = $true; break }
                }
                if (-not $macOk) { return $false }
            }
            'ipprefix' {
                $ipOk = $false
                foreach ($prefix in @($val)) {
                    if (('' + $Session.framed_ip_address).StartsWith(('' + $prefix))) { $ipOk = $true; break }
                }
                if (-not $ipOk) { return $false }
            }
            'username' {
                if (-not (('' + $Session.user_name) -like ('' + $val))) { return $false }
            }
            'olderthanminutes' {
                $age = ((Get-Date) - (Get-SessionStartTime $Session)).TotalMinutes
                if ($age -le [double]$val) { return $false }
            }
            'newerthanminutes' {
                $age = ((Get-Date) - (Get-SessionStartTime $Session)).TotalMinutes
                if ($age -ge [double]$val) { return $false }
            }
            default {
                # 不认识的字段：为安全起见视为不匹配
                return $false
            }
        }
    }
    return $true
}

function Select-SessionByStrategy {
    param($Candidates, [string]$Strategy)
    $list = @($Candidates)
    if ($list.Count -eq 0) { return $null }
    switch ((('' + $Strategy).ToLowerInvariant())) {
        'random' { return (Get-Random -InputObject $list) }
        'newest' { return (@($list | Sort-Object { Get-SessionStartTime $_ } -Descending))[0] }
        'first'  { return @($list)[0] }
        'last'   { return @($list)[-1] }
        default  { return (@($list | Sort-Object { Get-SessionStartTime $_ }))[0] }
    }
}

function Select-KickTarget {
    param($Sessions, [string[]]$ExcludeMacs = @())

    $list = @($Sessions | Where-Object { $_ })
    if ($list.Count -eq 0) { return $null }

    # 全局保护：neverKickMacs 支持通配符；还可按设备类型 / IP 前缀保护
    $protectMacs = @($script:Cfg.neverKickMacs | Where-Object { $_ })
    if ($ExcludeMacs -and $ExcludeMacs.Count -gt 0) { $protectMacs += $ExcludeMacs }
    $protectTypes = @()
    if ($script:Cfg.PSObject.Properties['protectDeviceTypes'] -and $script:Cfg.protectDeviceTypes) { $protectTypes = @($script:Cfg.protectDeviceTypes) }
    $protectIps = @()
    if ($script:Cfg.PSObject.Properties['protectIpPrefixes'] -and $script:Cfg.protectIpPrefixes) { $protectIps = @($script:Cfg.protectIpPrefixes) }

    $list = @($list | Where-Object {
                $mac = ('' + $_.calling_station_id)
                foreach ($pat in $protectMacs) { if (Test-MacPattern $mac $pat) { return $false } }
                if ($protectTypes.Count -gt 0 -and (Test-DeviceTypePattern $_.deviceType $protectTypes)) { return $false }
                $ip = ('' + $_.framed_ip_address)
                foreach ($prefix in $protectIps) { if ($ip.StartsWith(('' + $prefix))) { return $false } }
                return $true
            })
    if ($list.Count -eq 0) { return $null }

    $rules = @()
    if ($script:Cfg.PSObject.Properties['kickRules'] -and $script:Cfg.kickRules) { $rules = @($script:Cfg.kickRules) }

    if ($rules.Count -gt 0) {
        for ($i = 0; $i -lt $rules.Count; $i++) {
            $rule = $rules[$i]
            if ($null -eq $rule) { continue }
            $match = $null
            if ($rule.PSObject.Properties['match']) { $match = $rule.match }
            $candidates = @($list | Where-Object { Test-SessionMatch -Session $_ -Match $match })
            if ($candidates.Count -eq 0) { continue }
            $strategy = 'oldest'
            if ($rule.PSObject.Properties['pick'] -and $rule.pick) { $strategy = ('' + $rule.pick) }
            $chosen = Select-SessionByStrategy -Candidates $candidates -Strategy $strategy
            if ($chosen) {
                $ruleName = ('规则#' + ($i + 1))
                if ($rule.PSObject.Properties['name'] -and $rule.name) { $ruleName = ('' + $rule.name) }
                return [pscustomobject]@{ Session = $chosen; RuleName = $ruleName; Strategy = $strategy }
            }
        }
        # 有规则但没有一条匹配 → 不踢
        return $null
    }

    # 兼容旧配置：kickPreference + kickFallback
    foreach ($pref in @($script:Cfg.kickPreference)) {
        $hit = $list | Where-Object { ('' + $_.deviceType).ToUpperInvariant() -eq ('' + $pref).ToUpperInvariant() } | Select-Object -First 1
        if ($hit) { return [pscustomobject]@{ Session = $hit; RuleName = ('兼容模式:kickPreference=' + $pref); Strategy = 'first' } }
    }
    $fallback = ('' + $script:Cfg.kickFallback).ToLowerInvariant()
    if ($fallback -eq 'oldest') {
        return [pscustomobject]@{ Session = (@($list | Sort-Object { Get-SessionStartTime $_ }))[0]; RuleName = '兼容模式:kickFallback=oldest'; Strategy = 'oldest' }
    }
    if ($fallback -eq 'random') {
        return [pscustomobject]@{ Session = (Get-Random -InputObject $list); RuleName = '兼容模式:kickFallback=random'; Strategy = 'random' }
    }
    return [pscustomobject]@{ Session = @($list)[0]; RuleName = '兼容模式:first'; Strategy = 'first' }
}

function Disconnect-Session {
    param($Session)

    $mac = '' + $Session.calling_station_id
    $user = '' + $Session.user_name

    # 同时带上 camelCase 和 snake_case 字段名；服务端会忽略不认识的字段
    $sessionPayload = [ordered]@{
        acctUniqueId       = $Session.acct_unique_id
        acct_unique_id     = $Session.acct_unique_id
        acctSessionId      = $Session.acct_session_id
        acct_session_id    = $Session.acct_session_id
        mac                = $mac
        callingStationId   = $mac
        calling_station_id = $mac
        deviceType         = $Session.deviceType
        username           = $user
        user_name          = $user
        nasIpAddress       = $Session.nas_ip_address
        nas_ip_address     = $Session.nas_ip_address
        framedIPAddress    = $Session.framed_ip_address
        framed_ip_address  = $Session.framed_ip_address
    }
    $json = $sessionPayload | ConvertTo-Json -Compress -Depth 5

    # 方式一：和登录页「超出并发」弹窗里的【下线】按钮完全一致（session/acctUniqueId + mac）
    $resp = Invoke-PortalApi -Path '/portal-conversion/api/v3/session/acctUniqueId' -PlainBody $json
    $respData = ConvertFrom-PortalBody -Body $resp.Body
    $respText = 'null'
    if ($null -ne $respData) { $respText = ($respData | ConvertTo-Json -Compress -Depth 4) }
    Write-Log ('session/acctUniqueId -> HTTP ' + $resp.Status + ' ' + $respText) 'INFO'

    $okOne = $false
    if ($resp.Status -eq 200) {
        if ($null -eq $respData) { $okOne = $true }
        elseif ($respData.PSObject.Properties['statusCode']) { $okOne = ([int]$respData.statusCode -eq 200) }
        else { $okOne = $true }
    }
    if ($okOne) { return $true }

    # 方式二：和门户「在线设备列表」里的【下线】一致：先删 MAC 无感知绑定，再发下线请求
    Write-Log 'session/acctUniqueId 未成功，改用 删无感知绑定 + disconnect/request' 'WARN'
    $resp2 = Invoke-PortalApi -Path '/portal-conversion/api/v3/mac/deleteMac' -PlainBody $json
    $resp2Data = ConvertFrom-PortalBody -Body $resp2.Body
    $resp2Text = 'null'
    if ($null -ne $resp2Data) { $resp2Text = ($resp2Data | ConvertTo-Json -Compress -Depth 4) }
    Write-Log ('mac/deleteMac -> HTTP ' + $resp2.Status + ' ' + $resp2Text) 'INFO'

    $payload = @{
        userRequestList = @(
            @{
                acctSessionId = $Session.acct_session_id
                userIp        = $Session.framed_ip_address
                nasIp         = $Session.nas_ip_address
            }
        )
    }
    $json2 = $payload | ConvertTo-Json -Compress -Depth 6
    $resp3 = Invoke-PortalApi -Path '/radacct-service/api/v2/disconnect/request' -PlainBody $json2
    Write-Log ('disconnect/request -> HTTP ' + $resp3.Status) 'INFO'

    return (($resp2.Status -eq 200) -or ($resp3.Status -eq 200))
}

function Invoke-Login {
    param($Interface)

    $script:Token = $null
    $referer = $script:RefUrl
    $payload = [ordered]@{
        webAuthUser     = $script:Cfg.account
        webAuthPassword = $script:Cfg.password
        userip          = $Interface.IP
        usermac         = $Interface.MAC
        nasip           = $script:Cfg.nasIp
        wlanacname      = $script:Cfg.wlanacname
        redirectUrl     = $referer
        url             = $referer
        deviceType      = $script:Cfg.deviceType
    }
    $json = $payload | ConvertTo-Json -Compress -Depth 5
    $resp = Invoke-PortalApi -Path '/portal-conversion/api/v3/portal/connect' -PlainBody $json
    $data = ConvertFrom-PortalBody -Body $resp.Body
    if ($null -eq $data) {
        $data = [pscustomobject]@{ statusCode = $resp.Status; error = $null; errorDescription = '无法解析的响应' }
    }
    if ($data.PSObject.Properties['token'] -and $data.token) { $script:Token = $data.token }
    return $data
}

function Get-MyOnline {
    param($Interface)

    $payload = @{ userIp = $Interface.IP }
    $json = $payload | ConvertTo-Json -Compress
    $resp = Invoke-PortalApi -Path '/radacct-service/api/v2/session/me/online' -PlainBody $json
    if ($resp.Status -ne 200) { return $null }
    $data = ConvertFrom-PortalBody -Body $resp.Body
    return $data
}

# 登录成功后会话信息可能延迟 1-3 秒才可查，重试几次
function Wait-MyOnline {
    param($Interface, [int]$Attempts = 5, [int]$DelaySeconds = 2)

    for ($i = 0; $i -lt $Attempts; $i++) {
        $data = Get-MyOnline -Interface $Interface
        if ($data) { return $data }
        Start-Sleep -Seconds $DelaySeconds
    }
    return $null
}

# ---------------- 自检（验证"优先下线 PC、全是手机时随机"规则） ----------------
function Invoke-SelfTest {
    $script:SelfTestFail = 0

    $origPref = $script:Cfg.kickPreference
    $origFallback = $script:Cfg.kickFallback
    $origNever = $script:Cfg.neverKickMacs
    $origRules = @()
    if ($script:Cfg.PSObject.Properties['kickRules']) { $origRules = $script:Cfg.kickRules }
    $origProtectTypes = @()
    if ($script:Cfg.PSObject.Properties['protectDeviceTypes']) { $origProtectTypes = $script:Cfg.protectDeviceTypes }
    $origProtectIps = @()
    if ($script:Cfg.PSObject.Properties['protectIpPrefixes']) { $origProtectIps = $script:Cfg.protectIpPrefixes }

    function New-FakeSession {
        param([string]$Type, [string]$Mac, [string]$Start, [string]$Ip = '10.111.1.1')
        return [pscustomobject]@{
            deviceType         = $Type
            calling_station_id = $Mac
            acct_start_time    = $Start
            acct_session_id    = ('S-' + $Mac)
            nas_ip_address     = '10.112.1.253'
            framed_ip_address  = $Ip
            acct_unique_id     = ('U-' + $Mac)
            user_name          = $script:Cfg.account
        }
    }

    function Assert-Equal {
        param([string]$Label, $Actual, $Expected)
        if (('' + $Actual) -eq ('' + $Expected)) {
            Write-Log ("[SelfTest] PASS  " + $Label + " -> " + $Actual) 'OK'
        } else {
            Write-Log ("[SelfTest] FAIL  " + $Label + " -> 实际=" + $Actual + " 期望=" + $Expected) 'ERROR'
            $script:SelfTestFail++
        }
    }

    $pc = New-FakeSession 'PC' '02:00:00:00:00:01' '2026-01-01 09:00:00' '10.111.1.1'
    $a1 = New-FakeSession 'ANDROID' '02:00:00:00:00:02' '2026-01-01 08:00:00' '10.111.1.2'
    $a2 = New-FakeSession 'ANDROID' '02:00:00:00:00:03' '2026-01-01 10:00:00' '10.111.1.3'
    $ios = New-FakeSession 'IOS' '02:00:00:00:00:04' '2026-01-01 11:00:00' '10.111.1.4'

    # 1) 兼容旧配置：优先 PC
    $script:Cfg.kickRules = @()
    $script:Cfg.neverKickMacs = @()
    $script:Cfg.protectDeviceTypes = @()
    $script:Cfg.protectIpPrefixes = @()
    $script:Cfg.kickPreference = @('PC')
    $script:Cfg.kickFallback = 'random'
    $r = Select-KickTarget -Sessions @($pc, $a1, $a2)
    Assert-Equal '兼容模式：PC+手机 → 踢 PC' $r.Session.deviceType 'PC'

    # 2) 兼容旧配置：全是手机 → 随机
    $seen = @{}
    for ($i = 0; $i -lt 20; $i++) {
        $r = Select-KickTarget -Sessions @($a1, $a2)
        $seen[('' + $r.Session.calling_station_id)] = $true
    }
    Assert-Equal '兼容模式：全手机随机（20 次内两种都出现）' $seen.Keys.Count 2

    # 3) neverKickMacs 支持通配符
    $script:Cfg.neverKickMacs = @('02:00:00:00:00:0[12]')
    $r = Select-KickTarget -Sessions @($pc, $a1, $a2)
    Assert-Equal '保护名单：MAC 通配 → 只剩 a2' $r.Session.calling_station_id '02:00:00:00:00:03'
    $script:Cfg.neverKickMacs = @()

    # 4) 规则：优先 ANDROID，且取最新
    $script:Cfg.kickRules = @(
        [pscustomobject]@{ name = '优先ANDROID(最新)'; match = [pscustomobject]@{ deviceType = @('ANDROID') }; pick = 'newest' },
        [pscustomobject]@{ name = '其余随机'; match = [pscustomobject]@{}; pick = 'random' }
    )
    $r = Select-KickTarget -Sessions @($pc, $a1, $a2)
    Assert-Equal '规则：优先ANDROID + newest' $r.Session.calling_station_id '02:00:00:00:00:03'
    Assert-Equal '规则：命中规则名' $r.RuleName '优先ANDROID(最新)'

    # 5) 规则：MAC 通配 + oldest
    $script:Cfg.kickRules = @(
        [pscustomobject]@{ name = '踢02网卡'; match = [pscustomobject]@{ mac = @('02:00:00:00:00:0*') }; pick = 'oldest' }
    )
    $r = Select-KickTarget -Sessions @($pc, $a1, $a2)
    Assert-Equal '规则：MAC 通配 + oldest' $r.Session.calling_station_id '02:00:00:00:00:02'

    # 6) 规则：olderThanMinutes
    $oldS = New-FakeSession 'ANDROID' '02:00:00:00:00:05' ((Get-Date).AddMinutes(-120).ToString('yyyy-MM-dd HH:mm:ss')) '10.111.1.5'
    $newS = New-FakeSession 'ANDROID' '02:00:00:00:00:06' ((Get-Date).AddMinutes(-5).ToString('yyyy-MM-dd HH:mm:ss')) '10.111.1.6'
    $script:Cfg.kickRules = @(
        [pscustomobject]@{ name = '先踢在线超过60分钟'; match = [pscustomobject]@{ olderThanMinutes = 60 }; pick = 'random' },
        [pscustomobject]@{ name = '其余'; match = [pscustomobject]@{}; pick = 'oldest' }
    )
    $r = Select-KickTarget -Sessions @($oldS, $newS)
    Assert-Equal '规则：olderThanMinutes' $r.Session.calling_station_id '02:00:00:00:00:05'

    # 7) 规则：无匹配则不踢
    $script:Cfg.kickRules = @(
        [pscustomobject]@{ name = '只踢IOS'; match = [pscustomobject]@{ deviceType = @('IOS') }; pick = 'random' }
    )
    $r = Select-KickTarget -Sessions @($pc, $a1)
    Assert-Equal '规则：无匹配返回 null' ($null -eq $r) $true

    # 8) protectDeviceTypes
    $script:Cfg.kickRules = @(
        [pscustomobject]@{ name = '全部'; match = [pscustomobject]@{}; pick = 'random' }
    )
    $script:Cfg.protectDeviceTypes = @('IOS')
    $r = Select-KickTarget -Sessions @($ios, $a1)
    Assert-Equal '保护：protectDeviceTypes 生效' $r.Session.calling_station_id '02:00:00:00:00:02'
    $script:Cfg.protectDeviceTypes = @()

    # 恢复配置
    $script:Cfg.kickPreference = $origPref
    $script:Cfg.kickFallback = $origFallback
    $script:Cfg.neverKickMacs = $origNever
    $script:Cfg.kickRules = $origRules
    $script:Cfg.protectDeviceTypes = $origProtectTypes
    $script:Cfg.protectIpPrefixes = $origProtectIps

    return $script:SelfTestFail
}

# ---------------- 主流程 ----------------
function Invoke-Main {
    Clear-OldLogs -Days ([int]$script:Cfg.logRetentionDays)
    Write-Log ("开始运行 v$script:Version (DryRun=$DryRun)")

    $iface = $null
    $deadline = (Get-Date).AddSeconds([int]$script:Cfg.startupWaitSeconds)
    while ((Get-Date) -lt $deadline) {
        $iface = Get-CampusInterface -Prefixes @($script:Cfg.campusIpPrefixes)
        if ($iface) { break }
        Start-Sleep -Seconds 3
    }
    if (-not $iface) {
        Write-Log ('等待 ' + $script:Cfg.startupWaitSeconds + ' 秒仍未连上校园网（未拿到 ' + ($script:Cfg.campusIpPrefixes -join ',') + ' 开头的 IP），退出') 'ERROR'
        return 2
    }
    Write-Log ("校园网网卡: $($iface.Name)  IP=$($iface.IP)  MAC=$($iface.MAC)  网关=$($iface.Gateway)")

    $script:RefUrl = $script:PortalBase + '/?userip=' + $iface.IP + '&wlanacname=' + $script:Cfg.wlanacname + '&nasip=' + $script:Cfg.nasIp + '&usermac=' + $iface.MAC

    Set-CampusRoute -Interface $iface

    # 等认证页可访问
    $portalDeadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $portalDeadline -and -not (Test-PortalReachable)) { Start-Sleep -Seconds 3 }
    if (-not (Test-PortalReachable)) {
        Write-Log ('认证页 ' + $script:PortalBase + ' 无法访问，退出') 'ERROR'
        return 2
    }

    # 已在线？
    $me = Get-MyOnline -Interface $iface
    if ($me) {
        Write-Log ('本机已经在线，无需登录：' + ($me | ConvertTo-Json -Compress -Depth 5)) 'OK'
        return 0
    }

    $kickCount = 0
    $kickedMacs = @()
    $attempt = 0
    $maxAttempts = [int]$script:Cfg.maxAttempts
    while ($attempt -lt $maxAttempts) {
        $attempt++
        Write-Log ("第 $attempt/$maxAttempts 次尝试登录 (账号 $($script:Cfg.account))")
        $login = $null
        try {
            $login = Invoke-Login -Interface $iface
        } catch {
            Write-Log ('登录请求异常: ' + $_.Exception.Message) 'ERROR'
            Start-Sleep -Seconds ([int]$script:Cfg.retryIntervalSeconds)
            continue
        }

        $statusCode = $null
        if ($login.PSObject.Properties['statusCode']) { $statusCode = $login.statusCode }
        $errCode = $null
        if ($login.PSObject.Properties['error']) { $errCode = $login.error }
        $desc = ''
        if ($login.PSObject.Properties['errorDescription']) { $desc = '' + $login.errorDescription }

        if ($statusCode -eq 200) {
            Write-Log ('登录成功：' + ($login | ConvertTo-Json -Compress -Depth 5)) 'OK'
            $meAfter = Wait-MyOnline -Interface $iface
            if ($meAfter) { Write-Log '在线状态复核：已在线' 'OK' } else { Write-Log '在线状态复核：暂时读不到会话信息（登录已返回成功）' 'WARN' }
            return 0
        }

        $descLower = $desc.ToLowerInvariant()
        $isConcurrency = ($descLower -match 'already\s*have') -or ($errCode -eq 205) -or ($errCode -eq 240)
        $isAlreadyOnline = ($errCode -eq 82) -or ($errCode -eq 233) -or ($errCode -eq 245) -or ($descLower -match 'already (online|login)')

        if ($isAlreadyOnline) {
            Write-Log ('账号/设备已在线，视为成功：' + $desc) 'OK'
            return 0
        }

        if ($isConcurrency) {
            Write-Log ("登录失败：超出并发限制（error=$errCode, $desc）") 'WARN'
            $sessions = Get-SessionList
            if ($sessions.Count -eq 0) {
                Write-Log '拿不到在线设备列表，稍后重试' 'WARN'
                Start-Sleep -Seconds ([int]$script:Cfg.retryIntervalSeconds)
                continue
            }
            Write-Log ('当前账号在线设备: ' + (($sessions | ForEach-Object { "$($_.deviceType)/$($_.calling_station_id)/$($_.acct_start_time)" }) -join ' ; '))

            $target = Select-KickTarget -Sessions $sessions -ExcludeMacs $kickedMacs
            if (-not $target -or -not $target.Session) { Write-Log '所有能下线的设备都已尝试过，仍无空位，退出' 'ERROR'; return 3 }
            $session = $target.Session

            if ($DryRun) {
                Write-Log ("[DryRun] 命中规则 [$($target.RuleName)] 策略 [$($target.Strategy)]，将会下线: $($session.deviceType) $($session.calling_station_id) (session=$($session.acct_session_id))") 'OK'
                return 0
            }
            if ($kickCount -ge [int]$script:Cfg.maxKickPerRun) {
                Write-Log ('本次运行已下线 ' + $kickCount + ' 台设备仍无空位，退出') 'ERROR'
                return 3
            }

            Write-Log ("命中规则 [$($target.RuleName)] 策略 [$($target.Strategy)]，准备下线: $($session.deviceType) $($session.calling_station_id) (session=$($session.acct_session_id))")
            $ok = Disconnect-Session -Session $session
            if ($ok) {
                $kickCount++
                $kickedMacs += ('' + $session.calling_station_id).ToLowerInvariant()
                $waitSeconds = 1
                if ($null -ne $script:Cfg.kickWaitSeconds) { $waitSeconds = [double]$script:Cfg.kickWaitSeconds }
                if ($waitSeconds -lt 0.2) { $waitSeconds = 0.2 }
                Write-Log ("已发送下线请求，等待 $waitSeconds 秒后立即重新登录") 'OK'
                Start-Sleep -Milliseconds ([int]($waitSeconds * 1000))
            } else {
                Write-Log '下线失败，稍后重试' 'WARN'
                Start-Sleep -Seconds ([int]$script:Cfg.retryIntervalSeconds)
            }
            continue
        }

        if ($descLower -match 'invalid username or password|密码不正确|用户名不存在|账号状态|未激活|余额|套餐|过期|冻结|不允许') {
            Write-Log ("账号或套餐问题，停止自动重试：error=$errCode, $desc") 'ERROR'
            return 3
        }

        if ($errCode -eq 151 -or $errCode -eq 208) {
            Write-Log ("请求过快/登录过于频繁，等待 30 秒：error=$errCode, $desc") 'WARN'
            Start-Sleep -Seconds 30
            continue
        }

        Write-Log ("登录失败：statusCode=$statusCode, error=$errCode, $desc") 'WARN'
        Start-Sleep -Seconds ([int]$script:Cfg.retryIntervalSeconds)
    }

    Write-Log ("重试 $maxAttempts 次仍未登录成功") 'ERROR'
    return 3
}

# ---------------- 入口 ----------------
$mutex = New-Object System.Threading.Mutex($false, 'Local\WeNetAutoLogin')
$hasLock = $false
try
{
    try { $hasLock = $mutex.WaitOne(0) } catch { $hasLock = $true }
    if (-not $hasLock) {
        Write-Log '已有另一个实例在运行，本次退出'
        exit 0
    }

    if ($ShowVersion) {
        Write-Host ("wenet-auto-login v" + $script:Version)
        exit 0
    }

    Get-Cfg | Out-Null

    if ($SelfTest) {
        $fail = Invoke-SelfTest
        if ($fail -gt 0) {
            Write-Log ('自检失败: ' + $fail + ' 项') 'ERROR'
            exit 1
        }
        Write-Log '自检通过' 'OK'
        exit 0
    }

    # 3 分钟内如果刚跑过（例如任务被重复触发），就不再重复检测（运行过程中不重连）
    if (-not $Force -and -not $DryRun) {
        $prev = Read-RunState
        if ($prev -and $prev.lastRun) {
            try {
                $last = [datetime]::ParseExact(('' + $prev.lastRun), 'yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
                $minutes = ((Get-Date) - $last).TotalMinutes
                if ($minutes -ge 0 -and $minutes -lt 3) {
                    Write-Log ('3 分钟内已执行过一次（' + $prev.lastRun + '，结果 ' + $prev.result + '），本次跳过；如需强制执行请加 -Force')
                    exit 0
                }
            } catch { }
        }
    }

    $exitCode = Invoke-Main
    if (-not $DryRun -and -not $Force) { Write-RunState -Result ('exit-' + $exitCode) -ExitCode $exitCode }
    Write-Log ("结束，退出码 $exitCode")
    exit $exitCode
}
catch
{
    Write-Log ('未处理异常: ' + $_.Exception.Message + ' | ' + $_.ScriptStackTrace) 'ERROR'
    exit 9
}
finally
{
    if ($hasLock) { try { $mutex.ReleaseMutex() } catch { } }
    try { $mutex.Dispose() } catch { }
}
