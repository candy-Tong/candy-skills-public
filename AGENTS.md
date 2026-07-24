# 仓库协作说明

## 目标

这是一个持续沉淀跨项目、跨机器复用能力的 Agent Skill 仓库。不要把整个仓库限定
为某一个技术领域，也不要因为当前只包含两个 skill，就阻止新增其他类型的 skill。

当前收录：

- `remote-port-mapping`：负责通用、持久、可验证的 SSH reverse tunnel。
- `remote-browser-mcp`：负责 Playwright MCP、本地浏览器和远端 Agent 配置。

新增 skill 时应先明确它解决的独立问题、触发条件和完成标准。修改现有 skill 时
优先保持职责边界；浏览器 skill 必须复用端口映射 skill，不要复制 tunnel、
watchdog 或远端监听检查逻辑。

## 目录约定

典型 skill 结构：

```text
skills/<skill-name>/
  SKILL.md
  agents/openai.yaml
  references/
  scripts/
```

- `SKILL.md`：触发条件、工作流、安全门槛和完成标准。
- `agents/openai.yaml`：展示名称、简短说明和默认提示词。
- `references/`：只放运行、诊断和故障归属等按需读取内容。
- `scripts/`：放可重复执行的 macOS、Windows 和协议验证脚本。

只创建当前 skill 实际需要的目录，可以按需增加 `templates/`、`examples/` 或
其他配套资源。不要为单个 skill 增加与 `SKILL.md` 重复的 README 或 CHANGELOG；
仓库级索引和安装说明统一维护在根目录 `README.md`。

## 当前 Skills 的不可破坏契约

### Remote Port Mapping

- 使用系统 OpenSSH，不引入 `autossh`。
- 默认把远端 listener 绑定到 `127.0.0.1`，禁止直接绑定 `0.0.0.0`。
- 只有用户明确要求远端 IP 访问时，才能创建指定 IPv4 的 `socat` bridge。
- 端口被占用时不得静默换端口。
- 不得终止未知的本地或远端进程。
- listener 只能作为诊断证据，完成验证必须执行对应的应用层 probe。
- 支持 `tcp`、`http`、`ws`、`mcp`；WebSocket 必须验证 HTTP `101`，
  MCP 必须发送 `initialize`。
- macOS 使用 LaunchAgent，Windows 使用 Task Scheduler。
- 所有生成文件和任务名称必须幂等，重复执行不能创建重复 owner。

### Remote Browser MCP

- `remote-browser-mcp` 硬依赖 `remote-port-mapping`。
- Playwright MCP、本地 tunnel 和远端 endpoint 固定使用端口 `8931`。
- 传输协议固定为 Streamable HTTP，URL 为
  `http://127.0.0.1:8931/mcp`。
- 不支持 CDP，不自动选择备用端口。
- 不把 Chrome 加入登录启动项。
- 复用 Chrome 时使用 Playwright 扩展模式；默认浏览器模式不设置
  `--extension`、CDP、`--user-data-dir` 或自定义 profile。
- 本地阶段不得依赖远端机器信息。
- 只有用户同时给出 SSH 目标和准确的远端 Agent 后，才能进入远端阶段。
- 配置远端 Agent 前必须验证 `ssh -o BatchMode=yes <target>`。
- 只修改用户指定的 Agent；运行时检查它的真实版本、帮助和配置 schema。
- MCP 名称固定为 `playwright`。相同配置保持不变，冲突配置不能静默覆盖。

## 凭据和日志

- 不得提交 `log/`、`logs/`、`*.log`。
- 不得提交 `.env`、token、私钥、密码、认证 header 或真实内网配置。
- `PLAYWRIGHT_MCP_EXTENSION_TOKEN` 只能作为环境变量名或文档占位符出现，
  不能出现真实值。
- macOS token 临时文件必须为 `0600`，使用后立即删除。
- Windows token 文件只允许当前用户、SYSTEM 和 Administrators 访问。
- 含 token 的 LaunchAgent 或 launcher 文件必须限制为当前用户可读。
- 最终回复和诊断日志不得打印 token。

## 编辑原则

- 保持改动聚焦，不顺便重构无关代码。
- 新增或删除 skill 时，同步更新根目录 `README.md` 的当前 skill 列表。
- 优先延续已有脚本结构、任务命名和状态目录。
- Bash 使用 `set -Eeuo pipefail`，PowerShell 使用严格模式和
  `$ErrorActionPreference = 'Stop'`。
- 脚本失败时报告准确阶段，不实现自动回滚。
- 启停后台任务时考虑异步卸载、冷启动和 watchdog 竞争；验证重复执行行为。
- 新增参数时同时更新 `SKILL.md`、相关 reference 和两个平台脚本。
- 不得通过降低验证强度来让测试通过。

## 必跑验证

修改后至少执行：

```bash
python3 ~/.codex/skills/.system/skill-creator/scripts/quick_validate.py \
  skills/remote-port-mapping

python3 ~/.codex/skills/.system/skill-creator/scripts/quick_validate.py \
  skills/remote-browser-mcp

bash -n skills/remote-port-mapping/scripts/setup-macos.sh
bash -n skills/remote-browser-mcp/scripts/setup-macos.sh

npx -y shellcheck \
  skills/remote-port-mapping/scripts/setup-macos.sh \
  skills/remote-browser-mcp/scripts/setup-macos.sh

node --check skills/remote-browser-mcp/scripts/verify-mcp.mjs
npx skills add . --list
```

修改 Windows 脚本时，还必须使用 PowerShell parser 检查源脚本和生成出的
`.ps1` 文件。修改运行态逻辑时，使用 `--output-root` 做隔离生成测试，并验证
重复执行结果幂等。

## 发布前检查

提交前执行：

```bash
git diff --check
git status --short
git ls-files
```

确认：

- 没有日志、临时文件、备份或凭据进入暂存区。
- 仓库中的所有 skill 都能被 `npx skills add . --list` 发现。
- 文档中的端口、任务名、URL 和脚本参数与实现一致。
- 公共仓库中没有本机绝对路径、真实 SSH host、内网 IP 或用户 token。
