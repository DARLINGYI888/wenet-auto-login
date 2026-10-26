# 安全说明

## 不要提交的内容

- `config.json`：包含你的账号与密码（或 DPAPI 密文），已被 `.gitignore` 忽略。
- `logs/`、`state.json`：包含你的 IP、MAC、会话 ID 等。
- `.private/`、`*.png`：本地截图，可能包含学号等个人信息。

如果你不小心已经提交过，请删除文件后**重写历史**（例如 `git filter-repo`），仅删除最新提交是不够的。

## 密码存储

- 首次运行 `start.bat` 时，向导会让你输入密码，并默认用当前 Windows 用户的 DPAPI 加密后写入 `config.json` 的 `passwordDpapi` 字段，明文 `password` 留空。
- 之后要改密码：菜单选 `4. 修改学号 / 密码`，同样会用 DPAPI 加密保存。
- 注意：DPAPI 密文只能用**同一个 Windows 用户**（同一台机器）解密；换用户/重装系统后需要重新输入一次。

## 日志

日志里可能包含会话 ID、内网 IP、MAC、返回的 token。这些只用于本机排障，已在 `.gitignore` 中排除，请不要贴到公开 issue 里；如确需反馈问题，请自行打码。

## 漏洞报告

如果发现安全问题（例如命令注入、密码泄漏风险、路径问题），请不要直接开公开 issue，先通过 GitHub 的 Security Advisory 或仓库维护者邮箱私下联系。
