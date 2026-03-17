# Changelog

## 2026-03-18

### Desktop UI

- Added a full desktop workspace alongside the menu bar entry, with `总览`、`实例详情`、`提醒中心` and `设置`.
- Switched agent/model editing from fragile nested menu items to a dedicated assistant-style workspace flow.
- Added a multi-stage model assignment surface with `编组`、`搜索` and `复核` steps.

### Model Assignment

- Reworked model grouping to use provider/source buckets instead of capability buckets.
- Grouped the board into 4 top-level libraries:
  - `OpenAI 系列`
  - `百炼 / Bailian`
  - `DashScope / SiliconFlow`
  - `本地 / 私有 / 其他`
- Added provider cards with independent vertical scrolling so large libraries like Bailian can hold more models without blowing up the whole layout.
- Added batch staging so model changes can be queued across multiple agents before applying.
- Added responsive resizing for the model assignment window:
  - the sheet window is now resizable
  - provider columns expand with width
  - provider cards grow vertically with height
  - search and review screens now reflow based on available space

### Instance Control

- Kept the menu bar as a lightweight launcher while moving advanced actions into the desktop window.
- Preserved start/restart/stop, open repo, open log, open config and open management page actions inside the new UI.
- Fixed control behavior for `launchd`-managed instances so start/stop actions work on services such as `Nexus Link`.

### Discovery And Recovery

- Improved auto discovery so external repos, custom ports and localized folder names are picked up more reliably.
- Added ignored repo persistence so removed instances stay removed until a full scan is requested.
- Added restore actions for ignored repos from settings.
- Kept auto-restart logic enabled for real crash cases while reducing false “all healthy” UI states during retry windows.

### Alerts And Safety

- Simplified crash alerts to focus on `打开配置文件`、`打开日志` and `知道了`.
- Added duplicate suppression so acknowledging one specific error stops repeated popups for the same instance/error pair.

### CLI And Packaging

- Kept the CLI interface compatible while extending it to match desktop features such as full scan, settings toggles and model inspection.
- Updated app packaging and launch behavior so the app works as a Dock + menu bar app instead of a menu-only utility.

## 2026-03-17

### Initial Public Release

- Published the first open-source version of OpenClaw Assistant.
- Added MIT licensing, public repository metadata and setup documentation.
