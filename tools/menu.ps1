#requires -Version 3.0
<#
  WeNet 校园网自动登录 - 控制台菜单
  用法：双击 start.bat，或在 cmd 里运行 start.bat
  版本：1.2.0
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = ''
)

$ErrorActionPreference = 'Stop'

$script:Root = Split-Path -Parent $PSScriptRoot
if (-not $ConfigPath) { $ConfigPath = Join-Path $script:Root 'config.json' }
$script:ConfigPath = $ConfigPath
$script:ExamplePath = Join-Path $script:Root 'config.example.json'
$script:MainScript = Join-Path $script:Root 'wenet_auto.ps1'
$script:Version = '1.2.0'
$script:TaskFile = 'C:\Windows\System32\Tasks\WeNetAutoLogin'

$script:Bar = '============================================================'

# ---------------- 小工具 ----------------
function Write-Title {
    param([string]$Text)
    Write-Host ''
    Write-Host $script:Bar -ForegroundColor DarkCyan
    Write-Host ('  ' + $Text) -ForegroundColor Cyan
    Write-Host $script:Bar -ForegroundColor DarkCyan
}

function Pause-Menu {
    param([string]$Text = '按回车返回菜单...')
    [void](Read-Host $Text)
}

function Test-Admin {
    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Protect-Password {
    param([System.Security.SecureString]$Secure)
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringUni($bstr) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    if ([string]::IsNullOrEmpty($plain)) { throw '密码为空' }
    if (-not ('System.Security.Cryptography.ProtectedData' -as [type])) {
        foreach ($asmName in @('System.Security', 'System.Security.Cryptography.ProtectedData')) {
            try { Add-Type -AssemblyName $asmName -ErrorAction Stop; break } catch { }
        }
    }
    $blob = [System.Security.Cryptography.ProtectedData]::Protect(
        [System.Text.Encoding]::UTF8.GetBytes($plain), $null,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [Convert]::ToBase64String($blob)
}

function Read-SecurePassword {
    param([string]$Prompt = '请输入校园网密码（输入不显示）')
    return (Read-Host $Prompt -AsSecureString)
}

function Test-EmptySecure {
    param([System.Security.SecureString]$Secure)
    if ($null -eq $Secure) { return $true }
    if ($Secure.Length -eq 0) { return $true }
    return $false
}

# ---------------- 配置读写 ----------------
function Set-Prop {
    param($Object, [string]$Name, $Value)
    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

function Read-Config {
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) { return $null }
    try {
        $cfg = Get-Content -LiteralPath $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        throw ('config.json 格式错误，无法解析：' + $_.Exception.Message)
    }
    # 兼容缺失字段
    if ($null -eq $cfg.PSObject.Properties['kickRules']) { Set-Prop $cfg 'kickRules' @() }
    if ($null -eq $cfg.PSObject.Properties['neverKickMacs']) { Set-Prop $cfg 'neverKickMacs' @() }
    if ($null -eq $cfg.PSObject.Properties['protectDeviceTypes']) { Set-Prop $cfg 'protectDeviceTypes' @() }
    if ($null -eq $cfg.PSObject.Properties['protectIpPrefixes']) { Set-Prop $cfg 'protectIpPrefixes' @() }
    if ($null -eq $cfg.PSObject.Properties['maxKickPerRun']) { Set-Prop $cfg 'maxKickPerRun' 3 }
    if ($null -eq $cfg.PSObject.Properties['kickWaitSeconds']) { Set-Prop $cfg 'kickWaitSeconds' 1 }
    return $cfg
}

function Save-Config {
    param($Config)
    if ($null -ne $Config.PSObject.Properties['password']) {
        # 菜单不直接保存明文密码：有 DPAPI 密文时清空明文
        if ($Config.PSObject.Properties['passwordDpapi'] -and $Config.passwordDpapi) { $Config.password = '' }
    }
    ($Config | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $script:ConfigPath -Encoding UTF8
}

function Get-DefaultConfig {
    $cfg = Get-Content -LiteralPath $script:ExamplePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $cfg.account = ''
    $cfg.password = ''
    $cfg.passwordDpapi = ''
    return $cfg
}

function Get-RunState {
    $p = Join-Path $script:Root 'state.json'
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { return (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Get-TaskInstalled { return (Test-Path -LiteralPath $script:TaskFile) }

# ---------------- 执行主脚本 ----------------
function Invoke-MainScript {
    param([string[]]$Arguments = @())
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    & $ps -NoProfile -ExecutionPolicy Bypass -File $script:MainScript @Arguments
}

function Invoke-RealLogin {
    Write-Title '立即登录（真实执行）'
    Write-Host '正在执行，可能会下线一台在线设备……' -ForegroundColor Yellow
    Write-Host ''
    Invoke-MainScript -Arguments @('-Force')
    Write-Host ''
    Pause-Menu
}

function Invoke-DryRun {
    Write-Title '演练预览（不会真正下线/登录）'
    Write-Host '正在检查当前网络与账号状态……' -ForegroundColor Yellow
    Write-Host ''
    Invoke-MainScript -Arguments @('-DryRun')
    Write-Host ''
    Pause-Menu
}

function Invoke-SelfTest {
    Write-Title '规则自检'
    Write-Host '正在验证下线规则（不会访问网络）……' -ForegroundColor Yellow
    Write-Host ''
    Invoke-MainScript -Arguments @('-SelfTest')
    Write-Host ''
    Pause-Menu
}

function Show-Log {
    Write-Title '运行日志（最近 40 行）'
    $logDir = Join-Path $script:Root 'logs'
    if (-not (Test-Path -LiteralPath $logDir)) { Write-Host '暂无日志目录' -ForegroundColor Yellow; Pause-Menu; return }
    $latest = Get-ChildItem -LiteralPath $logDir -Filter 'wenet-*.log' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latest) { Write-Host '暂无日志文件' -ForegroundColor Yellow; Pause-Menu; return }
    Write-Host ('文件：' + $latest.FullName) -ForegroundColor DarkGray
    Write-Host ''
    Get-Content -LiteralPath $latest.FullName -Encoding UTF8 -Tail 40 | ForEach-Object { Write-Host $_ }
    Write-Host ''
    Pause-Menu
}

# ---------------- 账号密码 ----------------
function Edit-Account {
    while ($true) {
        $cfg = Read-Config
        Write-Title '修改学号 / 密码'
        Write-Host ('当前学号：' + $cfg.account)
        if ($cfg.PSObject.Properties['passwordDpapi'] -and $cfg.passwordDpapi) {
            Write-Host '当前密码：已用 DPAPI 加密保存（推荐）' -ForegroundColor Green
        } elseif ($cfg.password) {
            Write-Host '当前密码：明文保存（建议改成 DPAPI 加密）' -ForegroundColor Yellow
        } else {
            Write-Host '当前密码：未设置' -ForegroundColor Yellow
        }
        Write-Host ''
        Write-Host '  1) 修改学号'
        Write-Host '  2) 修改密码（DPAPI 加密）'
        Write-Host '  3) 同时修改'
        Write-Host '  0) 返回'
        $choice = (Read-Host '请选择').Trim()
        if ($choice -eq '0') { return }
        if ($choice -notin @('1', '2', '3')) { continue }

        if ($choice -eq '1' -or $choice -eq '3') {
            $newAccount = (Read-Host ('新学号（当前 ' + $cfg.account + '，回车不变）')).Trim()
            if ($newAccount) { $cfg.account = $newAccount }
        }
        if ($choice -eq '2' -or $choice -eq '3') {
            $secure = Read-SecurePassword
            if (Test-EmptySecure $secure) {
                Write-Host '密码为空，未修改。' -ForegroundColor Yellow
                Pause-Menu
                continue
            }
            try {
                $cfg.passwordDpapi = Protect-Password $secure
                $cfg.password = ''
                Write-Host '密码已用 DPAPI 加密（只有当前 Windows 用户能解密）。' -ForegroundColor Green
            } catch {
                Write-Host ('加密失败：' + $_.Exception.Message) -ForegroundColor Red
                Pause-Menu
                continue
            }
        }
        Save-Config $cfg
        Write-Host '已保存。' -ForegroundColor Green
        Pause-Menu
        return
    }
}

# ---------------- 规则编辑 ----------------
function New-KickRule {
    param([string]$Name, $Match, [string]$Pick = 'oldest')
    return [pscustomobject]@{ name = $Name; match = $Match; pick = $Pick }
}

function Format-Match {
    param($Match)
    if ($null -eq $Match) { return '全部设备' }
    $props = @($Match.PSObject.Properties)
    if ($props.Count -eq 0) { return '全部设备' }
    $parts = @()
    foreach ($p in $props) {
        $v = $p.Value
        if ($v -is [array]) { $v = ($v -join '/') }
        $parts += ($p.Name + '=' + $v)
    }
    return ($parts -join ', ')
}

function Show-RulesSummary {
    param($Cfg)
    Write-Host '当前下线规则：' -ForegroundColor Cyan
    $rules = @($Cfg.kickRules)
    if ($rules.Count -eq 0) {
        Write-Host '  （未配置 kickRules，使用旧兼容模式）' -ForegroundColor DarkGray
        Write-Host ('    kickPreference=' + (@($Cfg.kickPreference) -join '/') + '  kickFallback=' + $Cfg.kickFallback) -ForegroundColor DarkGray
    } else {
        $i = 0
        foreach ($r in $rules) {
            $i++
            $name = '规则#' + $i
            if ($r.PSObject.Properties['name'] -and $r.name) { $name = $r.name }
            $pick = 'oldest'
            if ($r.PSObject.Properties['pick'] -and $r.pick) { $pick = $r.pick }
            $match = $null
            if ($r.PSObject.Properties['match']) { $match = $r.match }
            Write-Host ('  ' + $i + ') ' + $name) -ForegroundColor White
            Write-Host ('     匹配：' + (Format-Match $match) + '    策略：' + $pick) -ForegroundColor DarkGray
        }
    }
    $protect = @($Cfg.neverKickMacs | Where-Object { $_ })
    if ($protect.Count -eq 0) { Write-Host '保护 MAC：无' -ForegroundColor DarkGray }
    else { Write-Host ('保护 MAC：' + ($protect -join ', ')) -ForegroundColor DarkGray }
    Write-Host ('一次最多下线：' + $Cfg.maxKickPerRun + ' 台；下线后等待 ' + $Cfg.kickWaitSeconds + ' 秒重试') -ForegroundColor DarkGray
}

function Read-NumberOrDefault {
    param([string]$Prompt, $Default, [int]$Min, [int]$Max)
    while ($true) {
        $raw = (Read-Host ($Prompt + '（当前 ' + $Default + '，回车不变）')).Trim()
        if (-not $raw) { return $Default }
        $n = 0
        if ([int]::TryParse($raw, [ref]$n) -and $n -ge $Min -and $n -le $Max) { return $n }
        Write-Host ('请输入 ' + $Min + '-' + $Max + ' 之间的整数') -ForegroundColor Yellow
    }
}

function Edit-Rules {
    $cfg = Read-Config
    while ($true) {
        Write-Title '修改下线规则'
        Show-RulesSummary $cfg
        Write-Host ''
        Write-Host '  1) 默认：优先 PC（最久的先），其余随机'
        Write-Host '  2) 只踢手机/平板（ANDROID、IOS）'
        Write-Host '  3) 随机踢任意设备'
        Write-Host '  4) 先踢在线超过 N 分钟的设备，再随机'
        Write-Host '  5) 只踢指定设备（按 MAC 前缀 / 通配符）'
        Write-Host '  6) 只踢指定设备类型'
        Write-Host '  7) 修改保护名单（neverKickMacs）'
        Write-Host '  8) 修改“一次最多下线台数 / 等待秒数”'
        Write-Host '  0) 返回'
        $choice = (Read-Host '请选择').Trim()
        $rules = @($cfg.kickRules)
        if ($choice -eq '0') { return }

        if ($choice -eq '1') {
            $rules = @(
                (New-KickRule '优先下线 PC（最久的先）' ([pscustomobject]@{ deviceType = @('PC') }) 'oldest'),
                (New-KickRule '其余设备随机' ([pscustomobject]@{}) 'random')
            )
        } elseif ($choice -eq '2') {
            $rules = @(
                (New-KickRule '只踢手机/平板（最久的先）' ([pscustomobject]@{ deviceType = @('ANDROID', 'IOS') }) 'oldest')
            )
        } elseif ($choice -eq '3') {
            $rules = @( (New-KickRule '随机踢任意设备' ([pscustomobject]@{}) 'random') )
        } elseif ($choice -eq '4') {
            $minutes = Read-NumberOrDefault '在线超过多少分钟优先踢' 60 1 10080
            $rules = @(
                (New-KickRule ('先踢在线超过 ' + $minutes + ' 分钟的设备') ([pscustomobject]@{ olderThanMinutes = $minutes }) 'oldest'),
                (New-KickRule '其余设备随机' ([pscustomobject]@{}) 'random')
            )
        } elseif ($choice -eq '5') {
            Write-Host '示例：aa:bb:cc:*  或  aa:bb:cc:dd:ee:ff' -ForegroundColor DarkGray
            $pattern = (Read-Host '要踢的设备 MAC（支持通配符）').Trim()
            if (-not $pattern) { Write-Host '已取消' -ForegroundColor Yellow; Pause-Menu; continue }
            $rules = @( (New-KickRule ('只踢 MAC ' + $pattern) ([pscustomobject]@{ mac = @($pattern) }) 'oldest') )
        } elseif ($choice -eq '6') {
            Write-Host '示例：PC  或  ANDROID  或  IOS；多个用逗号分隔' -ForegroundColor DarkGray
            $types = (Read-Host '要踢的设备类型').Trim()
            if (-not $types) { Write-Host '已取消' -ForegroundColor Yellow; Pause-Menu; continue }
            $typeList = @($types -split '[,，;； ]+' | Where-Object { $_ } | ForEach-Object { $_.ToUpperInvariant() })
            $pick = 'oldest'
            $pickRaw = (Read-Host '选择策略 oldest/newest/random/first/last（回车=oldest）').Trim()
            if ($pickRaw) { $pick = $pickRaw.ToLowerInvariant() }
            $rules = @( (New-KickRule ('只踢设备类型 ' + ($typeList -join '/')) ([pscustomobject]@{ deviceType = $typeList }) $pick) )
        } elseif ($choice -eq '7') {
            $current = (@($cfg.neverKickMacs) -join ', ')
            Write-Host ('当前保护 MAC：' + $(if ($current) { $current } else { '无' })) -ForegroundColor DarkGray
            $raw = (Read-Host '新的保护 MAC（逗号分隔，支持通配；输入 - 清空，回车不变）').Trim()
            if ($raw -eq '-') { $cfg.neverKickMacs = @() }
            elseif ($raw) { $cfg.neverKickMacs = @($raw -split '[,，;；\s]+' | Where-Object { $_ }) }
            Save-Config $cfg
            Write-Host '已保存保护名单。' -ForegroundColor Green
            Pause-Menu
            continue
        } elseif ($choice -eq '8') {
            $cfg.maxKickPerRun = Read-NumberOrDefault '一次最多下线几台' $cfg.maxKickPerRun 0 10
            $cfg.kickWaitSeconds = Read-NumberOrDefault '下线后等待几秒再重试登录' $cfg.kickWaitSeconds 1 60
            Save-Config $cfg
            Write-Host '已保存。' -ForegroundColor Green
            Pause-Menu
            continue
        } else {
            Write-Host '无效选项' -ForegroundColor Yellow
            continue
        }

        $cfg.kickRules = @($rules)
        if ($choice -eq '1') {
            # 默认预设同时恢复兼容配置，避免旧配置干扰
            Set-Prop $cfg 'kickPreference' @('PC')
            Set-Prop $cfg 'kickFallback' 'random'
        }
        Write-Host ''
        Write-Host '将要保存的规则：' -ForegroundColor Cyan
        Show-RulesSummary $cfg
        $ok = (Read-Host '确认保存？(Y/n)').Trim()
        if ($ok -match '^[Nn]') { Write-Host '已取消。' -ForegroundColor Yellow; Pause-Menu; continue }
        Save-Config $cfg
        Write-Host '规则已保存。' -ForegroundColor Green
        Pause-Menu
        return
    }
}

# ---------------- 安装 / 卸载计划任务 ----------------
function Install-TaskInteractive {
    Write-Title '安装“开机自动登录”计划任务'
    if (Test-Admin) {
        Write-Host '当前已是管理员，直接安装……' -ForegroundColor Yellow
        & (Join-Path $script:Root 'install_task.ps1')
    } else {
        Write-Host '需要管理员权限，正在弹出 UAC 确认，请在弹窗里点“是”……' -ForegroundColor Yellow
        try {
            Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', ('"' + (Join-Path $script:Root 'install.bat') + '"') -Verb RunAs -Wait | Out-Null
        } catch {
            Write-Host ('启动管理员窗口失败：' + $_.Exception.Message) -ForegroundColor Red
            Pause-Menu
            return
        }
    }
    Write-Host ''
    if (Get-TaskInstalled) { Write-Host '安装成功：计划任务 WeNetAutoLogin 已存在。' -ForegroundColor Green }
    else { Write-Host '没检测到计划任务（可能取消了 UAC）。' -ForegroundColor Red }
    Pause-Menu
}

function Uninstall-TaskInteractive {
    Write-Title '卸载“开机自动登录”计划任务'
    if (-not (Get-TaskInstalled)) {
        Write-Host '计划任务未安装，无需卸载。' -ForegroundColor Yellow
        Pause-Menu
        return
    }
    $ok = (Read-Host '确认卸载？(y/N)').Trim()
    if ($ok -notmatch '^[Yy]') { return }
    if (Test-Admin) {
        & (Join-Path $script:Root 'uninstall_task.ps1')
    } else {
        Write-Host '需要管理员权限，正在弹出 UAC 确认……' -ForegroundColor Yellow
        try {
            Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', ('"' + (Join-Path $script:Root 'uninstall.bat') + '"') -Verb RunAs -Wait | Out-Null
        } catch {
            Write-Host ('启动管理员窗口失败：' + $_.Exception.Message) -ForegroundColor Red
            Pause-Menu
            return
        }
    }
    Write-Host ''
    if (Get-TaskInstalled) { Write-Host '计划任务仍然存在，可能未卸载成功。' -ForegroundColor Red }
    else { Write-Host '已卸载。' -ForegroundColor Green }
    Pause-Menu
}

# ---------------- 首次使用向导 ----------------
function Invoke-FirstRun {
    Clear-Host
    Write-Title '首次使用设置'
    Write-Host '没有找到 config.json，先花 30 秒完成账号设置（只需要一次）。' -ForegroundColor Yellow
    Write-Host ''
    $cfg = Get-DefaultConfig

    $accountAttempts = 0
    while (-not $cfg.account) {
        $accountAttempts++
        if ($accountAttempts -gt 5) { Write-Host '未输入学号，已取消。' -ForegroundColor Red; return }
        $account = (Read-Host '请输入学号/工号').Trim()
        if ($account) { $cfg.account = $account }
        else { Write-Host '学号不能为空。' -ForegroundColor Yellow }
    }
    $cfg.password = ''
    $cfg.passwordDpapi = ''
    $passwordAttempts = 0
    while ($true) {
        $passwordAttempts++
        if ($passwordAttempts -gt 5) { Write-Host '未输入密码，已取消。' -ForegroundColor Red; return }
        try {
            $secure = Read-SecurePassword
        } catch {
            Write-Host ('读取密码失败：' + $_.Exception.Message) -ForegroundColor Red
            Write-Host '请在 cmd 窗口中键盘输入密码后重试。' -ForegroundColor Yellow
            return
        }
        if (Test-EmptySecure $secure) { Write-Host '密码不能为空。' -ForegroundColor Yellow; continue }
        try { $cfg.passwordDpapi = Protect-Password $secure; break }
        catch { Write-Host ('加密失败：' + $_.Exception.Message) -ForegroundColor Red }
    }
    Save-Config $cfg
    Write-Host ''
    Write-Host '已保存配置：' -ForegroundColor Green
    Write-Host ('  学号：' + $cfg.account)
    Write-Host '  密码：DPAPI 加密保存（仅当前 Windows 用户可解密）'
    Write-Host ''
    $ans = (Read-Host '现在安装“开机自动登录”计划任务吗？(Y/n)').Trim()
    if ($ans -notmatch '^[Nn]') { Install-TaskInteractive }
    Pause-Menu
}

# ---------------- 主界面 ----------------
function Show-Header {
    $cfg = $null
    try { $cfg = Read-Config } catch { }
    Clear-Host
    Write-Host $script:Bar -ForegroundColor DarkCyan
    Write-Host ('  WeNet 校园网自动登录 控制台   v' + $script:Version) -ForegroundColor Cyan
    if ($cfg) {
        $taskText = '未安装'
        if (Get-TaskInstalled) { $taskText = '已安装' }
        Write-Host ('  账号：' + $cfg.account + '      计划任务：' + $taskText) -ForegroundColor Gray
        $st = Get-RunState
        if ($st) {
            Write-Host ('  上次运行：' + $st.lastRun + '   结果：' + $st.result) -ForegroundColor DarkGray
        } else {
            Write-Host '  上次运行：无记录' -ForegroundColor DarkGray
        }
    } else {
        Write-Host '  尚未配置账号' -ForegroundColor Yellow
    }
    Write-Host $script:Bar -ForegroundColor DarkCyan
}

function Main-Menu {
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) {
        Invoke-FirstRun
    }
    while ($true) {
        Show-Header
        Write-Host ''
        Write-Host '  1. 立即登录（真实执行，可能下线一台设备）' -ForegroundColor White
        Write-Host '  2. 演练预览 / 查看当前状态（不会真正下线登录）' -ForegroundColor White
        Write-Host '  3. 查看运行日志' -ForegroundColor White
        Write-Host '  4. 修改学号 / 密码' -ForegroundColor White
        Write-Host '  5. 修改下线规则（优先踢谁、保护名单等）' -ForegroundColor White
        Write-Host '  6. 规则自检' -ForegroundColor White
        Write-Host '  7. 安装开机自动登录' -ForegroundColor White
        Write-Host '  8. 卸载开机自动登录' -ForegroundColor White
        Write-Host '  9. 打开项目文件夹' -ForegroundColor White
        Write-Host '  0. 退出' -ForegroundColor White
        Write-Host ''
        $choice = (Read-Host '请输入序号').Trim()
        try {
            switch ($choice) {
                '1' { Invoke-RealLogin }
                '2' { Invoke-DryRun }
                '3' { Show-Log }
                '4' { Edit-Account }
                '5' { Edit-Rules }
                '6' { Invoke-SelfTest }
                '7' { Install-TaskInteractive }
                '8' { Uninstall-TaskInteractive }
                '9' { Start-Process explorer.exe -ArgumentList $script:Root | Out-Null }
                '0' { return }
                default { }
            }
        } catch {
            Write-Host ''
            Write-Host ('出错了：' + $_.Exception.Message) -ForegroundColor Red
            Pause-Menu
        }
    }
}

# ---------------- 入口 ----------------
try {
    Main-Menu
}
catch {
    Write-Host ''
    Write-Host ('菜单运行出错：' + $_.Exception.Message) -ForegroundColor Red
    Write-Host ('位置：' + $_.InvocationInfo.PositionMessage) -ForegroundColor DarkGray
    Pause-Menu
}
