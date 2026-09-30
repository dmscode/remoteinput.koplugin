# RemoteInput 插件（KOReader）

为 KOReader 提供**实时**远程文本输入，带持久连接与**双向**同步。在另一台设备上输入文字，内容会即时出现在你的电纸书上——无需刷新页面，切换输入框时也无需重新连接。

> **本项目是基于 [j-v/remotenote.koplugin](https://github.com/j-v/remotenote.koplugin) 的修改版（fork）。** RemoteInput 保留了原项目的核心思路与大量底层代码（TLS 服务器、二维码流程、Kindle 防火墙处理、设置菜单），但把交互模型从「一次性 HTML 表单」重构为「实时双向同步的 Web 应用」。完整差异见[与 RemoteNote 的差异](#与-remotenote-的差异)。
>
> For the English version of this document, see [README.md](README.md). · 英文版说明见 [README.md](README.md)。

> **安全提示：** 默认情况下，打开 RemoteInput 会在电纸书上启动一个**未加密**的简易 Web 服务器。建议避免在公共网络中使用。你可以启用 HTTPS，但会受自签名证书的限制（详见[配置](#配置)）。

## 支持的设备

已在 Kindle Paperwhite 上测试通过。其他设备效果可能有所差异。

KOReader 最低版本要求：2025.10 —— 其他版本可能不受支持。

## 功能特性

- **实时同步**：远程设备输入的文字会即时（带 250ms 防抖）出现在 KOReader 上，无需点击提交按钮。
- **双向同步**：在阅读器本地的编辑也会回传到网页端。
- **持久连接**：保存后服务器保持运行，无需重新扫描二维码。
- **无缝上下文切换**：在批注编辑与任意输入对话框之间切换时无需重新连接。
- **自动跟随输入焦点**：会话活跃期间，设备上新打开的任意文本输入框会静默接管远程上下文——网页端一秒内自动跟进，无需再点按钮。
- **无冲突双向编辑**：通过 `dirty` 标志状态机实现「谁在输入谁说了算」，另一端绝不覆盖。
- **空闲自动停止**：服务器在可配置的无活动时长后自行关闭（关闭 / 5 / 15 / 30 / 60 分钟）。
- **对低功耗设备友好**：自适应轮询在空闲或页面后台时自动降低频率，减轻低端设备与手机电量负担。
- **远程笔记（Remote Note）**：为书内高亮段落输入笔记。
- **远程输入（Remote Input）**：在 KOReader 标准文本输入框中注入「Remote input」按钮，可从远程设备填写。
- **RESTful JSON API**（`/api/state`、`/api/text`、`/api/submit`），配有无外部依赖、完整符合规范的 JSON 编解码器。
- **可选 HTTPS**，自动生成自签名 TLS 证书。

## 安装

1. 从 [Releases（发行版）](#发行版) 页面下载与你设备架构对应的版本：

   | 架构 | 设备 |
   | --- | --- |
   | **armv7** | Kindle（全部型号）、Kobo、reMarkable 2、PocketBook |
   | **arm64** | reMarkable Paper Pro |
   | **arm-legacy** | Kindle 3、Kindle DX、较老的 32 位 ARM 设备 |
   | **x86_64** | 模拟器 |

   > **不确定？** 先试 `armv7`。仅当 `armv7` 在较老硬件上不工作时再使用 `arm-legacy`。

2. 将 `remoteinput.koplugin` 解压到 KOReader 的插件目录：
   - Kindle：`/mnt/us/koreader/plugins/`
   - Kobo：`/.adds/koreader/plugins/`

3. 重启 KOReader。

## 发行版

发行版由 GitHub Actions 工作流自动生成（从上游项目复制并适配）。推送以 `v` 开头的标签（例如 `v0.1.0`）会触发 [`release.yml`](.github/workflows/release.yml)，它会：

1. 把 `_meta.lua` 中的版本号改为与标签一致。
2. 为 `armv7`、`arm64`、`arm-legacy`、`x86_64` 交叉编译 `certgen` Go 二进制（源码在 [`certgen/`](certgen/)）。
3. 通过 [`build.sh`](build.sh) 每个架构打包一个 zip——各自包含插件的 Lua 源码、`README.md`、`README.zh-CN.md`、`LICENSE` 以及对应的 `bin/certgen`。
4. 创建 GitHub Release（默认标记为预发布）并将四个 zip 作为资产上传。

### 本地构建

如果你已安装 Go，可自行复现发行版产物：

```bash
bash ./build.sh          # 完整构建：编译全部架构的 certgen 并打包
bash ./build.sh -p       # 仅打包：复用已有二进制重新打包
```

工作树中的 `bin/certgen` 二进制仅是本地生成 TLS 证书时的便利文件，**不会**提交到仓库（`bin/` 已被 git 忽略，与上游一致）。发行版 zip 才是受支持的分发渠道。

## 配置

入口在顶部菜单：**工具（Tools）> 远程输入（Remote Input）**。

### 端口（Port）

默认服务器运行在 8089 端口，可在此修改。新端口从下一次会话开始生效。

### 空闲自动停止

服务器在选定时长内没有**实质活动**（文本编辑、上下文切换、页面加载——仅后台轮询不算）时自动关闭。可在**关闭 / 5 / 15 / 30 / 60** 分钟间循环切换，默认 15 分钟。超时触发时阅读器会弹出提示，已打开的网页会显示「Session ended」。手动停止（设备端 **Stop** 按钮或网页端 **Save & Close**）始终立即生效。

### 启用 HTTPS（加密）

> **注意：** 使用 HTTPS 可保证传输内容加密，但仍受自签名证书限制（如中间人攻击），现代浏览器会显示连接不安全。

启用后，插件会自动生成所需的 TLS 证书（`cert.pem` 与 `key.pem`）并使用加密连接。

### 刷新 TLS 证书

强制重新生成 HTTPS 证书（仅在启用 HTTPS 时可见）。

### 在所有文本输入框允许远程输入

全局开关「远程输入」功能在 KOReader 界面中的注入。修改后需重启生效，默认启用。

### 自动跟随新打开的输入框

会话活跃期间，设备上新打开任意文本输入框并弹出键盘时，远程上下文会自动切换到该输入框——网页端无需再点「Remote input」。笔记对话框不在此列：请用其中的「Remote edit note」按钮切换到批注编辑。默认启用。

### 内联渲染「Remote input」按钮

切换对话框中「Remote input」按钮的显示方式。勾选时尝试与 KOReader 默认按钮内联放置；不勾选时在对话框边界内单独占一行。

## 架构

RemoteInput 在阅读器上内置了一个小型 HTTP 服务器，并提供一个交互式单页 Web 应用。浏览器与阅读器通过一个精简的 JSON API 通信：

| 端点 | 方法 | 用途 |
| --- | --- | --- |
| `/` | GET | 提供交互式 Web 前端 |
| `/api/state` | GET | 返回当前上下文、文本、版本号与 dirty 标志（供前端轮询） |
| `/api/text` | POST | 将网页文本实时推送到 KOReader |
| `/api/submit` | POST | 保存笔记并关闭会话（批注场景） |

### 同步机制

两端各自运行一个精简状态机以避免编辑冲突：

- `dirty` 标志标记哪一方正在编辑。浏览器输入时（`isDirty = true`）拥有编辑权，KOReader 不会覆盖它。
- 当浏览器空闲、而 KOReader 检测到本地改动（`server_dirty`）时，网页端会在下一次轮询时采用阅读器的文本。其他打开的页签也通过这一机制跟进远程编辑。
- 上下文 `version` 计数器**只**在上下文切换（例如切到另一个输入框）时递增，前端据此无需刷新页面即可重置——绝不会把普通文本更新误判为切换，从而覆盖正在输入的一端。
- 每个会话都有随机 id（`sid`）；阅读器开启新会话后，旧网页检测到不匹配会自行结束，不会带着过期状态复活。
- 10 秒安全定时器会自动释放 `dirty` 标志，网络故障绝不会造成永久锁死。
- 轮询间隔自适应：交互后 600ms，空闲后 2s，页面后台 5s。

## 与 RemoteNote 的差异

### 变化与提升

| 方面 | RemoteNote（上游） | RemoteInput（本项目） |
| --- | --- | --- |
| **同步模型** | 一次性 HTML 表单：输入 → 点「保存」→ 服务器关闭 | 边输入边实时自动同步（250ms 防抖） |
| **同步方向** | 仅 Web → 阅读器 | **双向**（阅读器侧编辑也会显示到浏览器） |
| **连接方式** | 每次保存后服务器停止，需重新扫码 | **持久**连接，切换输入框无需重连 |
| **冲突处理** | 无（后者覆盖前者） | `dirty` 标志状态机 + 10 秒安全释放 |
| **前端** | 极简 HTML 表单 | 带样式、状态指示与提示的单页应用 |
| **API** | 普通 `POST` 表单数据 | RESTful JSON API（`/api/state`、`/api/text`、`/api/submit`） |
| **依赖** | 依赖 `socket.url` 解码 | 自包含 JSON 编解码器 + URL 解码（无外部依赖） |
| **会话状态** | 无 | 跟踪 `session_active`、`context_version`、`server_dirty` |
| **批注提交** | 隐式（表单提交即保存） | 显式 **保存并关闭（Save & Close）** 按钮 |
| **插件名** | `remotenote` /「Remote Note」 | `remoteinput` /「Remote Input」 |
| **版本号** | 0.1.0 | 由标签驱动自动升级（见「发行版」） |

### 原样保留的部分

- `securetcpserver.lua`（SSL 包装的 TCP 服务器）与上游完全一致。
- HTTPS 证书生成、二维码对话框、Kindle `iptables` 防火墙处理、设置菜单结构均沿用上游。

### 有意调整的行为

- 服务器 URL 以居中纯文本显示，而非带下划线的「打开链接」按钮（`Device:openLink`）。
- 移除了上游的「内容正在被 *IP* 编辑…」状态对话框——实时同步下已不再需要。
- 对话框按钮由单一的「取消（Cancel）」改为 **隐藏（Hide，关闭但保持会话）** 与 **停止（Stop，结束会话）**。

## 已知问题

- 打开「编辑笔记」对话框时，KOReader 键盘可能遮挡对话框底部按钮。缓解方法是启用「内联渲染『Remote input』按钮」选项。
- HTTPS 依赖自签名证书，浏览器会提示连接不受信任。

## 许可证

[GNU AGPL v3](LICENSE)，继承自上游项目 [j-v/remotenote.koplugin](https://github.com/j-v/remotenote.koplugin)。

## 致谢

本项目基于 [j-v](https://github.com/j-v) 的 [j-v/remotenote.koplugin](https://github.com/j-v/remotenote.koplugin)。原始 RemoteNote 插件、TLS 服务器以及 KOReader 集成工作的全部功劳归原作者所有。
