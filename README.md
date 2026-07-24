# Candy Skills

这个仓库用于沉淀可以跨项目、跨机器复用的 Agent Skill、工作流、脚本和操作规范。
仓库会持续增加新的 skill；远程端口映射和浏览器 MCP 是当前最先收录的一组能力，
不代表仓库只服务于远程开发场景。

## 当前 Skills

| Skill | 用途 |
| --- | --- |
| `remote-port-mapping` | 使用系统 OpenSSH 创建本地到远程开发机的持久反向端口映射，并提供登录自启和应用层健康检查 |
| `remote-browser-mcp` | 在本地启动 Playwright MCP，将固定端口 `8931` 映射到远程开发机，并配置用户指定的远程 Agent |

`remote-browser-mcp` 依赖 `remote-port-mapping`，不会重复实现 SSH tunnel。

## 当前浏览器链路

```text
本地 Chrome 或 Playwright 默认浏览器
  -> 本地 Playwright MCP 127.0.0.1:8931
  -> SSH reverse tunnel
  -> 远程开发机 127.0.0.1:8931
  -> 用户指定的 Codex、Claude Code、Cursor 或其他 Agent
```

浏览器链路不使用 CDP，也不会自动选择其他端口。远端默认只监听 loopback，
不会把 MCP 直接暴露到公网。

## 安装

安装仓库中的全部 skills：

```bash
npx skills add candy-Tong/candy-skills-public
```

只安装其中一个：

```bash
npx skills add candy-Tong/candy-skills-public \
  --skill remote-port-mapping
```

```bash
npx skills add candy-Tong/candy-skills-public \
  --skill remote-browser-mcp
```

## 使用

### 通用端口映射

向 Agent 提出类似请求：

```text
请使用 $remote-port-mapping，把本地 8080 映射到开发机的
127.0.0.1:8080，并设置为用户登录后自动启动。
```

执行前需要提供：

- 映射名称。
- 本地服务的 host 和 port。
- 可以直接执行 `ssh <target>` 的 SSH 目标。
- 远端端口。
- `tcp`、`http`、`ws` 或 `mcp` 探测类型。

macOS 使用 LaunchAgent，Windows 使用 Task Scheduler。两端都使用系统
OpenSSH，不依赖 `autossh`。

### 远程浏览器 MCP

向 Agent 提出类似请求：

```text
请使用 $remote-browser-mcp，让开发机上的 Codex 通过 Playwright MCP
操作我本地的浏览器。
```

流程分为两个阶段：

1. 在本地配置 Playwright MCP、登录自启和 60 秒 watchdog。
2. 用户提供 SSH 目标与远端 Agent 后，建立端口映射并配置该 Agent。

本地浏览器可以使用：

- 已有 Chrome：需要安装
  [Playwright MCP Bridge 扩展](https://chromewebstore.google.com/detail/playwright-extension/mmlmfjhmonkocbjadbfplnigmagldckm)
  并提供扩展 token。
- Playwright 默认浏览器：不使用扩展，不指定自定义 profile。

远端 Agent 的 MCP 连接契约固定为：

```text
MCP name: playwright
Transport: Streamable HTTP
URL: http://127.0.0.1:8931/mcp
```

Skill 会在运行时检查所选 Agent 的实际版本、帮助信息和配置格式，不内置固定的
Agent 配置文件列表。

## 当前 Skills 的安全边界

- Playwright MCP 固定使用 `127.0.0.1:8931`。
- SSH reverse tunnel 默认只绑定远端 `127.0.0.1`。
- 不会自动终止未知进程，也不会在端口被占用时随机换端口。
- 不会自动启动 Chrome。
- 扩展 token 只写入受限的本地用户配置，不会写入远端 Agent 配置或日志。
- 修改远端 Agent 前必须由用户明确指定 SSH 目标和 Agent。
- 最终验证使用 MCP `initialize` 和真实工具调用，不以“端口正在监听”代替应用层验证。

## 当前 Skills 的支持范围

- 本地：macOS、Windows。
- 远端：Linux/POSIX，需要 `bash`、`ss` 和 `curl`。
- 浏览器 MCP：Playwright MCP Streamable HTTP。

## 仓库结构

```text
skills/
  <skill-name>/
    SKILL.md
    agents/
    references/
    scripts/
```

每个 skill 的入口说明位于对应的 `SKILL.md`。按需使用 `references/`、
`scripts/`、`templates/` 或其他必要目录，不为简单 skill 强行增加空目录。

当前仓库内容：

```text
skills/
  remote-port-mapping/
  remote-browser-mcp/
```

## 本地验证

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

仓库通过 `.gitignore` 排除 `log/`、`logs/`、`*.log`、环境文件和常见私钥文件。
