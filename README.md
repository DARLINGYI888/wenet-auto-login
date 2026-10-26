# WeNet 校园网自动登录（Windows）

Windows 开机登录后自动完成 WeNet 校园网认证：没登录就登录；名额满了就按你自定义的规则下线一台设备，再登录。

**新手友好**：双击 `start.bat` 打开 cmd 控制台菜单，跟着提示填账号、改规则、装开机任务即可，不需要编辑 JSON 或敲命令。

> 本项目基于对 WeNet 认证前端与其 HTTP 接口的逆向整理，**仅用于个人在自己学校、使用自己账号的自动化**。
> 请遵守所在学校的网络使用规定；接口可能随校方升级而变化。

English: a small Windows PowerShell tool that logs into a WeNet campus captive portal automatically at logon, kicking one online device according to **user-defined rules** when the device quota is full. MIT licensed, no third-party dependencies.

## 功能特性

- **cmd 控制台菜单** `start.bat`：首次向导、一键登录/演练、可视化修改下线规则、安装/卸载开机任务；`\n- **只在开机后第一次登录 Windows 时执行一次**，跑完即退出：不常驻后台、不定时轮询、运行中掉线不会自动重连；
- 自动等待连上校园网 Wi-Fi（默认最多 5 分钟）；
- 同时开着手机热点时，自动补一条到认证服务器的临时路由（需管理员权限）；
- 已在线则跳过，不重复下线设备；
- **自定义下线规则 `kickRules`**：按顺序匹配设备，支持按设备类型 / MAC / IP / 账号 / 在线时长筛选，并按最久、最新、随机等策略选出要踢的设备；
- **全局保护名单**：`neverKickMacs`（支持通配符）、`protectDeviceTypes`、`protectIpPrefixes`；
- 被踢设备 1 秒内“秒重连”导致名额仍满时，自动换下一台再试（最多 `maxKickPerRun` 台）；
- 优先使用认证页「超出并发」弹窗同款下线接口；失败再回退到「删无感知绑定 + 断开请求」；
- 密码可选 **Windows DPAPI** 加密保存（不落明文）；
- 演练模式（只看不动手）、规则自检（9 项断言）、按天日志、自动清理旧日志；
- 计划任务安装/卸载脚本。

## 工作原理

门户是一个 SPA，所有 API 请求/响应都经过一层固定密钥的 AES 加密（详见 [docs/api.md](docs/api.md)）。脚本做了：

1. 等本机拿到校园网网段 IP（默认 `10.111.*`）；
2. （有热点时）补 `10.112.0.0/16` 路由，保证能访问认证服务器；
3. `POST /radacct-service/api/v2/session/me/online` 判断本机是否已在线；
4. 未在线 → `POST /portal-conversion/api/v3/portal/connect` 登录；
5. 若返回“名额已满” → 拿失败响应里的 token 查在线设备 → **按 `kickRules` 选一台设备下线** → 1 秒后重试登录；
6. 结果写日志并退出。

## 免责声明

- 本项目仅用于学习 HTTP 协议逆向和 Windows 自动化，**请使用你自己的账号**，不要用于绕过学校网络的任何管理规定。
- 作者不对使用本脚本造成的账号限制、网络故障或违反校规等后果负责。
- 不同学校、不同版本的 WeNet 门户在接口路径、字段、加密方式上可能不同，本项目不保证通用；请自行评估风险。

## 环境要求

- Windows 10 / 11
- Windows PowerShell 5.1（系统自带）或 PowerShell 7
- 安装计划任务需要管理员权限（一次性）
- 无需 Python/Node，无第三方模块

## 一键控制台（推荐）

不想编辑 JSON、敲命令？直接**双击 `start.bat`**，会打开一个控制台菜单：

- 首次运行：自动引导填写学号/密码（DPAPI 加密保存），并询问是否安装开机任务；
- 之后菜单里可以：立即登录、演练预览、查看日志、修改学号/密码、**可视化修改下线规则**、规则自检、安装/卸载开机任务；
- 修改规则时按 1/2/3 选预设即可（优先 PC、只踢手机、随机、先清僵尸设备、按 MAC/设备类型），不用打开配置文件。

## 安装

1. 下载或克隆本仓库到任意目录（下面以 `<项目目录>` 表示）。（下面以 `<项目目录>` 表示）。
2. 复制配置模板并填写：

   ```powershell
   Copy-Item .\config.example.json .\config.json
   notepad .\config.json
   ```

   至少填写 `account`（学号/工号）和 `password`。
   如果你的学校门户 IP / NAS IP / 网段不同，也一并修改。

3. （推荐）先演练，不产生任何下线/登录动作：

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\wenet_auto.ps1 -DryRun
   ```

4. 真实运行一次：

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\wenet_auto.ps1
   ```

   或者双击 `start.bat` 选 `1`（强制运行，忽略“3 分钟内已跑过”的保护）。

5. 安装开机自启任务：**右键 `install.bat` → 以管理员身份运行**。
   它会在“当前用户登录 Windows 时”触发一次，并以管理员权限运行（补路由需要）。

6. 卸载：右键 `uninstall.bat` → 以管理员身份运行。

> 计划任务触发的是“登录 Windows 时”，所以 Wi-Fi 通常已经连上或正在连；脚本会等最多 5 分钟。
> 如果开机后停留在锁屏界面不登录，任务不会触发（符合“只在开机时检测”的预期）。

## 配置说明（config.json）

| 字段 | 说明 |
| --- | --- |
| `account` / `password` | 学号 / 密码 |
| `passwordDpapi` | 可选，DPAPI 密文；非空时优先于 `password` |
| `portalIp` | 认证服务器地址（示例 `10.112.0.10`） |
| `nasIp` | 认证报文里的 NAS IP（示例 `10.112.1.253`） |
| `wlanacname` | 一般留空 |
| `deviceType` | 本机在校园网里的设备类型，固定 `PC` 即可 |
| `campusIpPrefixes` | 校园网 Wi-Fi 的 IP 前缀列表，默认 `["10.111."]` |
| `campusGatewayFallback` | 取不到网关时的兜底网关 |
| `autoAddCampusRoute` | 有手机热点时是否自动补路由 |
| `kickRules` | **自定义下线规则**，见下一节（推荐） |
| `neverKickMacs` | 绝不能下线的设备 MAC，支持 `*`/`?` 通配 |
| `protectDeviceTypes` | 绝不能下线的设备类型，如 `["IOS"]` |
| `protectIpPrefixes` | 绝不能下线的 IP 前缀，如 `["10.111.5."]` |
| `maxKickPerRun` | 一次运行最多下线几台（`0` = 只记录不动手） |
| `kickWaitSeconds` | 下线后等多久重试登录（秒，默认 1） |
| `startupWaitSeconds` | 开机后最多等多久连上校园网（秒） |
| `retryIntervalSeconds` | 普通失败重试间隔（秒） |
| `maxAttempts` | 登录尝试次数上限 |
| `logRetentionDays` | 日志保留天数 |

> 兼容旧配置：如果没有 `kickRules`，会退回使用 `kickPreference`（按设备类型优先）、`kickFallback`（`random`/`oldest`）。
> 同时存在时以 `kickRules` 为准。

### 自定义下线规则（kickRules）

`kickRules` 是一个**有序数组**，从上往下匹配，第一条有匹配结果的规则决定踢哪台设备：

```json
"kickRules": [
  {
    "name": "优先下线 PC（最久的先）",
    "match": { "deviceType": ["PC"] },
    "pick": "oldest"
  },
  {
    "name": "其余设备随机",
    "match": {},
    "pick": "random"
  }
]
```

每条规则：

| 字段 | 必填 | 说明 |
| --- | --- | --- |
| `name` | 否 | 规则名，会写进日志，便于排查 |
| `match` | 否 | 匹配条件；省略或 `{}` 表示匹配所有设备 |
| `pick` | 否 | 命中后怎么选：`oldest`（默认）/ `newest` / `random` / `first` / `last` |

`match` 支持的字段（全部可选，多个字段是“并且”关系）：

| 字段 | 值 | 说明 |
| --- | --- | --- |
| `deviceType` | `["PC"]`、`["ANDROID","IOS"]` | 设备类型，支持通配符，如 `["ANDROID*"]` |
| `mac` | `["aa:bb:cc:dd:ee:*"]` | MAC，支持通配符；冒号/横线都行，不区分大小写 |
| `ipPrefix` | `["10.111.1."]` | 设备在线 IP 的前缀 |
| `username` | `"245125"` | 账号，支持通配符 |
| `olderThanMinutes` | `60` | 只匹配“已在线超过 60 分钟”的设备 |
| `newerThanMinutes` | `5` | 只匹配“在线不足 5 分钟”的设备 |

**注意**：`match` 里出现不认识的字段时，这条规则视为**不匹配**（避免手误踢错设备）。

常用示例：

```json
// 1) 只踢手机/平板，不碰电脑
"kickRules": [
  { "name": "优先手机", "match": { "deviceType": ["ANDROID", "IOS"] }, "pick": "oldest" }
]

// 2) 先踢在线超过 2 小时的“僵尸设备”，否则随机踢一台
"kickRules": [
  { "name": "先清僵尸设备", "match": { "olderThanMinutes": 120 }, "pick": "oldest" },
  { "name": "其他随机", "match": {}, "pick": "random" }
]

// 3) 先踢室友的电脑，再踢自己的旧手机（按 MAC 前缀）
"kickRules": [
  { "name": "先踢指定电脑", "match": { "mac": ["aa:bb:cc:*"] }, "pick": "first" },
  { "name": "其余随机", "match": {}, "pick": "random" }
]

// 4) 只踢某个 IP 段的设备；其他设备不踢（没有兜底规则）
"kickRules": [
  { "name": "只踢访客段", "match": { "ipPrefix": ["10.111.200."] }, "pick": "newest" }
]
```

想验证规则是否符合预期，运行：

```powershell
powershell -ExecutionPolicy Bypass -File .\wenet_auto.ps1 -SelfTest
```

`-DryRun` 演练时日志会打印命中的规则名和策略，例如：

```
[DryRun] 命中规则 [优先下线 PC（最久的先）] 策略 [oldest]，将会下线: PC aa:bb:cc:dd:ee:ff
```

### 密码加密（可选）

在控制台菜单里选 `4. 修改学号 / 密码`，输入的密码会自动用当前 Windows 用户的 DPAPI 加密写入 `config.json` 的 `passwordDpapi`，并清空明文 `password`，不需要额外脚本。

注意：DPAPI 密文只能被**同一个 Windows 用户、同一台机器**解密。

## 使用

| 操作 | 方法 |
| --- | --- |
| 打开控制台菜单 | 双击 `start.bat` |
| 演练（不下线、不登录） | 菜单选 `2`，或 `wenet_auto.ps1 -DryRun` |
| 立即真实运行 | 菜单选 `1`，或 `wenet_auto.ps1 -Force` |
| 只自检下线规则 | `-SelfTest` |
| 查看版本 | `-ShowVersion` |
| 查看日志 | `<项目目录>\logs\wenet-YYYYMMDD.log` |
| 卸载开机任务 | 右键 `uninstall.bat` → 管理员运行 |

## 目录结构

```
.
├─ wenet_auto.ps1          # 主程序
├─ config.example.json     # 配置模板（复制为 config.json）
├─ config.json             # 你的本地配置（已 gitignore）
├─ install.bat / install_task.ps1
├─ uninstall.bat / uninstall_task.ps1
├─ start.bat               # 一键打开控制台菜单（推荐）
├─ tools/menu.ps1          # 控制台菜单
├─ docs/api.md             # 协议说明
├─ logs/                   # 运行日志（已 gitignore）
├─ SECURITY.md
├─ CONTRIBUTING.md
└─ CHANGELOG.md
```

## 常见问题

**1. 提示“认证页无法访问”**
- 确认电脑连的是校园网 Wi-Fi，不是手机热点；
- 同时开热点时，需要管理员权限补路由：右键 `start.bat` → 以管理员身份运行 → 选 `1`，脚本会自动补路由；
- 学校换了认证服务器地址的话，改 `portalIp` / `nasIp`。

**2. 开机后没登录成功**
- 看 `logs`。Wi-Fi 可能要几十秒才连上，脚本默认等 5 分钟；
- 本次开机失败后不会自动再试（按设计，运行期间不重连）；可以在菜单里选 `1` 手动重试，或重启。

**3. 设备被踢后同一秒又自己登录回来**
- 学校对手机/平板有“无感知认证”（MAC 绑定），只发断开请求会被立刻自动重新认证；
- 脚本已优先使用弹窗同款下线接口，并支持“删无感知绑定 + 断开”的回退；仍被抢回时会换下一台设备（最多 `maxKickPerRun` 台）；
- 如果那台设备是你自己的、且有自动登录客户端，关掉它成功率更高。

**4. 运行中我断网/被别的设备顶掉，会自己重连吗？**
- 不会。脚本只运行一次，结束即退出。

**5. 规则好像没生效 / 踢错设备？**
- 先跑 `-SelfTest`（内置 9 个断言，会把失败项打印出来）；
- 用 `-DryRun` 看日志里“命中规则”和“策略”；
- 检查 `match` 字段名是否拼错（未知字段会直接不匹配）、MAC 是否写成通配符形式；
- 用 `neverKickMacs` / `protectDeviceTypes` / `protectIpPrefixes` 把绝对不能踢的设备保护起来。

## 适配其他学校

本项目按 WeNet 门户实现。换学校时通常只需要改 `config.json`：

- `portalIp`、`nasIp`：认证页地址和 NAS 地址；
- `campusIpPrefixes`：校园网分配的 IP 段；
- 如果接口路径/AES 密钥不同，需要改 `wenet_auto.ps1` 里的接口路径和 `$script:AesKey`（欢迎 PR）。

## 安全

不要提交 `config.json`、`logs/`、截图等隐私文件；详见 [SECURITY.md](SECURITY.md)。

## 贡献

欢迎 Issue / PR，提交前请看 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 许可证

[MIT](LICENSE)
