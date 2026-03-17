# OpenClaw 小助手

一个原生 Swift 实现的 macOS 助手，用来统一发现、监控和控制本机上的多套 OpenClaw / openclaw-cn 实例。

它现在不是单纯的“菜单栏小工具”了，而是一个 `菜单栏 + Dock + 桌面主窗口` 的控制台：

- 菜单栏负责快速看状态和做轻操作
- 桌面主窗口负责总览、实例详情、提醒中心、设置
- 智能体 / 模型编组有单独的可缩放工作台，不再挤在二级菜单里

更新日志见 [CHANGELOG.md](./CHANGELOG.md)。

它适合这样的场景：

- 同一台 Mac 上同时跑多套 OpenClaw
- 不同实例使用不同端口、不同 profile、不同仓库目录
- 需要同时用 GUI 和 CLI 管理实例
- 需要稳定处理 launchd 托管实例、崩溃重启、忽略列表和重新发现

## 现在支持什么

### 桌面 UI

- 菜单栏实时显示运行数量
- Dock + 桌面主窗口双入口
- 桌面主窗口包含：
  - `总览`
  - `实例详情`
  - `提醒中心`
  - `设置`
- 实例前置状态圆点
  - 绿色：运行中 / 启动中
  - 红色：停止 / 崩溃 / 项目缺失 / 禁用
- 快速打开实例项目目录、日志文件、配置文件、控制管理页

### 智能体 / 模型编组

- 独立的智能体 / 模型编组工作台
- 按模型来源 / 系列分组，而不是按用途硬拆
- 当前默认分成 4 组：
  - `OpenAI 系列`
  - `百炼 / Bailian`
  - `DashScope / SiliconFlow`
  - `本地 / 私有 / 其他`
- 支持点选暂存、多智能体批量编组、应用前复核
- 支持可缩放窗口，内部布局会自适应
- 每个模型来源卡都可以独立上下滚动，适合模型很多的供应商

### 实例控制与发现

- 单个实例启动、停止、重启
- 全部实例启动、停止、重启
- 自动发现正在运行的 OpenClaw 进程，并尽量反推 `--profile`、`--port`
- 自动发现常见桌面仓库目录下的 `openclaw` / `openclaw-cn`
- 可忽略不想再自动扫回来的实例
- 手动触发全量扫描
- 支持 launchd 托管实例的启动 / 停止 / 重启，不再出现“点了没反应”

### 自动化与提醒

- 开机启动小助手
- 打开小助手时自动启动 OpenClaw
- 崩溃后自动保活拉起
- 相同错误点一次“知道了”后不会重复弹
- 提醒中心会汇总崩溃、忽略实例、launchd 托管状态等信息

### CLI

- CLI 控制接口
- 支持查看实例状态、设置开关、全量扫描
- 支持查看实例智能体 / 模型候选列表
- 支持直接通过 CLI 修改某个智能体使用的模型

## 运行环境

- macOS
- Xcode Command Line Tools
- Swift 5.9+

## 本地运行

```bash
cd ~/Desktop/openclaw小助手
swift run OpenClawAssistant
```

## 打包为 .app

```bash
cd ~/Desktop/openclaw小助手
chmod +x scripts/build-app.sh
./scripts/build-app.sh
open ./OpenClaw小助手.app
```

## CLI 用法

也可以直接走 CLI：

```bash
cd ~/Desktop/openclaw小助手
./scripts/openclaw-assistant-cli status
./scripts/openclaw-assistant-cli models <instance-id>
./scripts/openclaw-assistant-cli set-model <instance-id> <agent-id> <model-id>
./scripts/openclaw-assistant-cli start <instance-id>
./scripts/openclaw-assistant-cli stop <instance-id>
./scripts/openclaw-assistant-cli restart <instance-id>
./scripts/openclaw-assistant-cli remove <instance-id>
./scripts/openclaw-assistant-cli full-scan
./scripts/openclaw-assistant-cli set launch-at-login on
./scripts/openclaw-assistant-cli set auto-start-on-launch on
./scripts/openclaw-assistant-cli set auto-restart-crashed on
```

支持的命令：

- `status [instance-id]`
- `models <instance-id>`
- `settings`
- `set-model <instance-id> <agent-id> <model-id>`
- `start <instance-id>`
- `stop <instance-id>`
- `restart <instance-id>`
- `remove <instance-id>`
- `start-all`
- `stop-all`
- `restart-all`
- `full-scan`
- `set <launch-at-login|auto-start-on-launch|auto-restart-crashed> <on|off>`
- `paths`

## 配置文件

首次启动后会生成：

`~/Library/Application Support/OpenClawAssistant/instances.json`

核心字段说明：

- `repoPath`: 实例仓库路径
- `startCommand`: 启动命令
- `env`: 额外环境变量
- `processMatch`: 进程识别补充条件
- `activityPaths`: 活跃度判断路径
- `ignoredRepoPaths`: 已从列表移除、默认不再自动扫回的仓库

示例：

```json
{
  "refreshIntervalSeconds": 3,
  "launchAtLogin": false,
  "autoStartInstancesOnLaunch": false,
  "autoRestartCrashedInstances": true,
  "ignoredRepoPaths": [],
  "instances": [
    {
      "id": "studio-openclaw",
      "name": "Studio OpenClaw",
      "repoPath": "/Users/yourname/Desktop/openclaw",
      "startCommand": [
        "node",
        "scripts/run-node.mjs",
        "gateway",
        "run"
      ],
      "env": {},
      "processMatch": [
        "OPENCLAW_ASSISTANT_INSTANCE_ID=studio-openclaw"
      ],
      "activityPaths": [
        "~/.openclaw/logs",
        "~/.openclaw/agents"
      ],
      "disabled": false
    }
  ]
}
```

## 自动发现规则

- 优先识别当前正在运行的 OpenClaw 进程，并尽量反推 `--profile`、`--port` 等启动参数
- 其次读取仓库内的启动脚本
- 再其次读取 `.env` 里的 `OPENCLAW_GATEWAY_PORT`
- 对已经识别出的自定义启动参数，不会在后续自动刷新时被默认值覆盖
- 对 launchd 托管的实例，会额外记录并同步处理对应服务标签

## 自动保活说明

- 开启“实例崩溃后自动重新拉起”后，小助手会持续观察实例状态
- 实例不是手动停止、并且运行中断时，会自动重新拉起
- 即使实例之前被你手动停过，只要后来又重新运行，小助手也会重新接管保活
- 当前自动重试会带短冷却，避免崩溃时高频重启
- 如果实例本身配置无效，保活只会重复尝试启动，菜单里仍会显示崩溃；这时请先查看“最近日志”或实例日志文件修复根因

## 开源说明

- 这是一个社区工具，不属于 OpenClaw 官方项目
- 发布前请自行检查本地配置文件和日志，避免把个人敏感信息一起提交
- 仓库默认使用 MIT License

## 目录结构

- `Sources/OpenClawAssistant`: 主程序源码
- `Sources/OpenClawAssistant/AssistantDesktopUI.swift`: 桌面主窗口与智能体编组 UI
- `Sources/OpenClawAssistant/AgentModelManager.swift`: 智能体 / 模型读取与写回
- `Resources`: `Info.plist`、图标资源
- `scripts`: 打包与 CLI 脚本

## License

[MIT](./LICENSE)
