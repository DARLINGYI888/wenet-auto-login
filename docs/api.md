# WeNet 认证门户协议参考（非官方）

> 本文档记录的是对**公开可访问的校园网认证前端**与其 HTTP 接口的逆向整理，仅用于学习和个人自动化。
> 请遵守你所在学校的网络使用规定，只使用**你自己的账号**，不要用于任何违规用途。
> 接口随时可能被校方升级/修改，本文档不保证长期有效。

## 1. 整体结构

认证门户是一个 umi/React 单页应用，地址形如：

```
http://<portal-ip>/?userip=<本机IP>&wlanacname=&nasip=<NAS IP>&usermac=<本机MAC>
```

主要接口分两类：

- `/portal-conversion/api/v3/...`：认证、会话、下线；
- `/radacct-service/api/v2/...`：当前会话查询、断开请求。

## 2. 传输层加密

页面 JS 里实现了一层固定密钥的 AES：

- 算法：AES-128-CBC / PKCS7
- key = iv = `1234567890000000`（16 字节 ASCII）
- 请求体：`JSON.stringify(body)` → AES 加密 → **小写 hex 字符串**，直接作为 body 发送
- 请求头：`Content-Type: application/json;charset=UTF-8`
- 响应体：服务器返回**带引号的 JSON 字符串**，内容为 hex；先去掉引号，再 hex→AES 解密→JSON
- 需要鉴权的接口带 `Authorization: <token>`（token 来自接口响应）

示例（PowerShell 思路）：

```powershell
# 加密：JSON -> AES-CBC/PKCS7 -> hex
# 解密：hex -> AES-CBC/PKCS7 -> JSON
```

## 3. 登录

```
POST /portal-conversion/api/v3/portal/connect
Content-Type: application/json;charset=UTF-8

{
  "webAuthUser":     "学号",
  "webAuthPassword": "密码",
  "userip":          "10.111.x.x",
  "usermac":         "aa-bb-cc-dd-ee-ff",
  "nasip":           "10.112.1.253",
  "wlanacname":      "",
  "redirectUrl":     "http://10.112.0.10/?userip=...&usermac=...",
  "url":             "http://10.112.0.10/?userip=...&usermac=...",
  "deviceType":      "PC"
}
```

响应 HTTP 恒为 200，需要看 `statusCode`：

```json
// 成功
{"statusCode":200, "session": {...}, "error":0, "token":"..."}

// 未登录/名额满
{"statusCode":400, "error":81, "errorDescription":"pc already have 2  sessions ", "token":"..."}
```

判断规则：

- `statusCode == 200`：登录成功；
- `errorDescription` 含 `already have`（或 error 为 205/240）：**名额已满**；
- `error` 为 82/233/245 或描述含 `already online`：本机/账号已在线；
- `errorDescription` 含 `invalid username or password`：账号密码错误；
- 151/208：请求或登录过于频繁，需要退避重试。

> 注意：失败响应里也会带一个 `token`，可用来查询在线设备列表、执行下线。

## 4. 查询在线设备

```
POST /portal-conversion/api/v3/session/list
Authorization: <登录失败响应里的 token>
Body: 空
```

```json
{
  "concurrency": "2",
  "sessions": [
    {
      "deviceType": "ANDROID",
      "acct_session_id": "HGD-...",
      "nas_ip_address": "10.112.1.253",
      "framed_ip_address": "10.111.1.23",
      "calling_station_id": "02:00:00:00:00:02",
      "acct_start_time": "2026-10-24 20:34:37",
      "acct_unique_id": "radius:acct:...:xx:..."
    }
  ]
}
```

## 5. 下线设备

门户里有两套“下线”，效果不同：

### 5.1 登录页「超出并发」弹窗的【下线】（推荐）

```
POST /portal-conversion/api/v3/session/acctUniqueId
Authorization: <token>

{"acctUniqueId": "<acct_unique_id>", "mac": "<calling_station_id>"}
```

实测这条接口下线后，设备**不会**立刻自动重连，可以直接重新登录抢名额。

### 5.2 门户「在线设备列表」的【下线】

先删掉该设备的“无感知绑定”（MAC 绑定）：

```
POST /portal-conversion/api/v3/mac/deleteMac
Authorization: <token>

{ 该会话对象的字段（camelCase / snake_case 均可，服务端忽略未知字段） }
```

再发断开请求：

```
POST /radacct-service/api/v2/disconnect/request
Authorization: <token>

{"userRequestList":[{"acctSessionId":"<acct_session_id>","userIp":"<framed_ip_address>","nasIp":"<nas_ip_address>"}]}
```

> 只发 `disconnect/request` 而不删“无感知绑定”时，设备会被 AC 通过 MAC 绑定**自动重新认证上线**，表现为“踢掉瞬间又回来”。

## 6. 查询本机是否在线

```
POST /radacct-service/api/v2/session/me/online
Body: {"userIp":"<本机IP>"}
```

- 已在线：返回会话对象（含 `acctSessionId`、`mac`、`framedIPAddress` 等）；
- 未在线：HTTP 200，响应体为空。

## 7. 其他接口（参考）

- `/portal-conversion/api/v3/portal/connect/token`：获取 portal token；
- `/portal-conversion/api/v3/session/me/all`：按 `{userIp, username}` 查在线设备（需鉴权）；
- `/portal-conversion/api/v3/mac/getMacList` / `saveMac` / `deleteMac`：无感知绑定管理；
- `/portal-conversion/api/v3/portal/get/jsonConfig?filename=configration.json`：门户配置（学校名、表单字段、弹窗文案等）。

## 8. 免责声明

本文档仅用于学习 HTTP 协议、JavaScript 逆向和自动化脚本编写。不同学校、不同版本的 WeNet 门户可能在路径、字段、加密方式上有差异；请勿将本文档用于未经授权的访问或破坏网络管理规定。
