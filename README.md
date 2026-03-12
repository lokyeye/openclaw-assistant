# OpenClaw 小助手

一个原生 Swift 实现的 macOS 菜单栏助手，用来统一发现、监控和控制本机上的多套 OpenClaw / openclaw-cn 实例。

它适合这样的场景：

- 同一台 Mac 上同时跑多套 OpenClaw
- 不同实例使用不同端口、不同 profile、不同仓库目录
- 需要从菜单栏快速看状态、重启实例、打开控制页

## 现在支持什么

- 菜单栏实时显示运行数量
- 实例前置状态圆点
  - 绿色：运行中 / 启动中
  - 红色：停止 / 崩溃 / 项目缺失 / 禁用
- 单个实例启动、停止、重启
- 全部实例启动、停止、重启
- 快速打开实例项目目录、日志文件、控制管理页
- 自动发现桌面上的 `openclaw` / `openclaw-cn` 仓库
- 可忽略不想再自动扫回来的实例
- 手动触发全量扫描
- CLI 控制接口
- 开机启动小助手
- 打开小助手时自动启动 OpenClaw
- 崩溃后自动保活拉起

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
- `settings`
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
      "id": "nexus-link",
      "name": "Nexus Link",
      "repoPath": "/Users/lok/Desktop/Nexus Link/openclaw",
      "startCommand": [
        "node",
        "scripts/run-node.mjs",
        "gateway",
        "run"
      ],
      "env": {},
      "processMatch": [
        "OPENCLAW_ASSISTANT_INSTANCE_ID=nexus-link"
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

## 开源说明

- 这是一个社区工具，不属于 OpenClaw 官方项目
- 发布前请自行检查本地配置文件和日志，避免把个人信息或密钥一起提交
- 仓库默认使用 MIT License

## 目录结构

- `Sources/OpenClawAssistant`: 主程序源码
- `Resources`: `Info.plist`、图标资源
- `scripts`: 打包与 CLI 脚本

## License

[MIT](./LICENSE)
