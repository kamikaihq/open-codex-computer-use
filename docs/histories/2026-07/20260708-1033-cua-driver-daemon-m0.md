# cua-driver daemon M0

## 用户诉求

新增一个名为 `cua-driver` 的 daemon-mode binary，面向外部 supervisor 的 M0 wire contract：foreground `serve`、快速 `status`、JSON `call`、固定 `--version`，并提供 framing、M0 verbs、single-instance lock、pid/socket cleanup 和测试覆盖。

## 主要改动

- 在 `Package.swift` 增加 `cua-driver` executable product 和 `CuaDriverCLI` target。
- 新增 `apps/CuaDriverCLI/` 作为薄入口，保持 binary argv 由调用方原样控制。
- 新增 `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/Daemon/`，包含：
  - 4-byte big-endian length-prefixed JSON frame codec。
  - Unix socket client/server transport。
  - foreground AppKit accessory daemon runtime、socket bind、pidfile、lockfile 和 SIGTERM/SIGINT cleanup。
  - `status`、`check_permissions`、`get_cursor_position` M0 verbs。
- 新增 `CuaDriverDaemonTests.swift` 覆盖 framing、verb envelope serialization 和 spawn-based socket lifecycle。
- 更新 `docs/ARCHITECTURE.md`，记录新 CLI 和 daemon 层边界。

## 设计取舍

- SwiftPM target 使用 `CuaDriverCLI`，product 名固定为 `cua-driver`，以满足 macOS Swift module 命名约束和外部 binary 名要求。
- `call <verb>` 在没有 positional JSON 且 stdin 不是管道输入时使用 `{}`，避免无参数 verbs 在交互式终端阻塞；如果 stdin 有输入则按合约读取 JSON。
- `check_permissions` granted case 只输出 `{"accessibility":true,"screen_recording":true}`，不附加任何可能命中 `/false|denied/i` 的额外文本。
- lockfile 在正常退出后保留为空文件；合约要求清理 socket 和 pidfile，lock 通过 `flock` release 保证 single-instance。

## 验证

- `swift build` 通过。
- `swift build --configuration release --product cua-driver` 通过。
- 本地 release binary shell proof 通过：serve 创建 socket/pid/lock，status exit 0，call status/check_permissions/get_cursor_position 返回 JSON，SIGTERM 后 socket 和 pidfile 被移除，status exit nonzero。
- `swift test` 当前被本机 Command Line Tools 环境阻塞：SwiftPM 无法 import `XCTest`，同样影响仓库已有 `StandaloneCursorSupportTests`。
