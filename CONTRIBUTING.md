# 贡献指南

感谢帮忙！提交 PR 前请先看这几条。

## 环境

- Windows 10 / 11
- PowerShell 5.1（系统自带）或 PowerShell 7
- 不引入第三方依赖（主脚本只依赖 .NET 自带库）

## 本地验证

```powershell
# 1. 复制示例配置并填入测试账号（不要提交 config.json）
Copy-Item config.example.json config.json

# 2. 语法/选择规则自检（不会真的下线/登录）
powershell -ExecutionPolicy Bypass -File .\wenet_auto.ps1 -SelfTest

# 3. 演练模式（会访问认证页，但不会下线设备）
powershell -ExecutionPolicy Bypass -File .\wenet_auto.ps1 -DryRun
```

## 编码要求

- `*.ps1` / `*.bat` 建议使用 **UTF-8 with BOM**（Windows PowerShell 5.1 读取无 BOM 的 UTF-8 中文会乱码，甚至解析失败）。
- 修改后请跑一遍 `-SelfTest` 和 PowerShell 语法解析：

```powershell
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path .\wenet_auto.ps1), [ref]$null, [ref]$errors)
if ($errors) { $errors | Format-List }
```

## 提交前检查

- [ ] 没有把 `config.json`、`logs/`、`state.json`、截图提交进去
- [ ] 没有在代码/注释/README 里出现真实学号、密码、IP、MAC、token
- [ ] `-SelfTest` 通过
- [ ] 如果改了协议相关逻辑，请同步更新 `docs/api.md`
- [ ] 尽量一个 PR 只做一件事，说明改动原因和测试方式

## 代码风格

- 保持单文件主脚本，函数名用 PowerShell 动词-名词（如 `Get-Cfg`、`Invoke-Login`）。
- 日志用 `Write-Log`，不要用 `Write-Output` 输出状态。
- 出错时返回明确退出码：`0` 成功/已在线，`2` 网络不可用，`3` 登录失败，`9` 未处理异常。
