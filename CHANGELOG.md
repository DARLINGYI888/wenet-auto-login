# Changelog

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循语义化版本。

## [1.2.0] - 2026-10-26

### Added

- **一键控制台菜单** `start.bat` / `tools/menu.ps1`：
  - 首次运行向导：填写学号/密码（DPAPI 加密）、可选安装开机任务；
  - 菜单操作：立即登录、演练预览、查看日志、修改账号/密码、修改下线规则、规则自检、安装/卸载计划任务；
  - 下线规则可视化编辑：默认（优先 PC）、只踢手机/平板、随机、先清长时间在线设备、按 MAC/设备类型指定；并可修改保护名单、最多下线台数、重试等待秒数；
  - 主界面显示账号、计划任务状态、上次运行结果。

## [1.1.0] - 2026-10-26

### Added

- **自定义下线规则 `kickRules`**：按顺序匹配，第一条命中的规则决定踢哪台设备；
  - 匹配字段：`deviceType`、`mac`、`ipPrefix`、`username`、`olderThanMinutes`、`newerThanMinutes`，支持 `*` / `?` 通配符；
  - 选择策略 `pick`：`oldest` / `newest` / `random` / `first` / `last`；
  - 日志会记录命中的规则名和策略；
- 全局保护名单：`neverKickMacs`（支持通配符）、`protectDeviceTypes`、`protectIpPrefixes`；
- `-ShowVersion` 参数；`-SelfTest` 扩展为 9 个断言，失败时返回非 0 退出码（CI 可用）。

### Changed

- `-SelfTest` 现在覆盖规则引擎、通配符、保护名单、时间条件；
- 更新 `config.example.json` 为规则引擎示例；
- 文档补充规则语法与示例。

## [1.0.0] - 2026-10-26

### Added

- Windows 开机（登录）后自动完成 WeNet 校园网认证；
- 自动检测校园网 Wi-Fi、自动补 `10.112.0.0/16` 临时路由（兼容同时开手机热点）；
- 名额已满时自动下线设备：优先 PC，全是手机/平板时随机；若被踢设备秒重连则换下一台，最多 3 台；
- 优先使用认证页「超出并发」弹窗同款下线接口（`session/acctUniqueId`），失败再回退到「删无感知绑定 + disconnect/request」；
- 已在线时直接跳过，不重复下线设备；运行结束即退出，不常驻、不自动重连；
- 计划任务（登录时触发、管理员权限）、安装/卸载脚本、演练/自检模式；
- 可选 DPAPI 加密保存密码（`tools/set_password.ps1`）；
- 完整日志（按天分割、自动清理）；
- 文档：README、`docs/api.md` 协议说明、SECURITY、CONTRIBUTING。
