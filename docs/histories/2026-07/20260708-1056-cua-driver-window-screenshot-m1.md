# cua-driver window and screenshot M1

## 用户诉求

在 `cua-driver` daemon M0 之上新增 `list_windows` 与 `screenshot` 两个 verb，让外部 supervisor 的 `status -> check_permissions -> get_cursor_position -> list_windows -> screenshot` selftest 路径完整跑通。

## 主要改动

- 新增 `CuaDriverWindows.swift`，提供 daemon 专用的 window provider、screenshot capturer、response model 与 image encoding helper。
- `CuaDriverVerbHandler` 增加可注入的 window/capture provider，并实现：
  - `list_windows`：返回 layer 0 window 列表，支持可选 `pid` filter，并保留 `window_id` / `is_on_screen` contract 字段。
  - `screenshot`：支持只传 `window_id`，自动解析 owning pid；支持 `jpeg` / `png`，默认 `jpeg`。
- screenshot capture 优先 ScreenCaptureKit，任意 SCK 失败后 fallback 到 `CGWindowListCreateImage`，响应包含 `capture_path`。
- 扩展 daemon tests：fake-backed response shaping 覆盖 pid optional、`window_not_found`、base64/dimensions、JPEG default 与 PNG plumbing；真实 capture 和 lifecycle smoke 在没有 Screen Recording permission 时 skip。
- 更新 `docs/ARCHITECTURE.md` 记录 M1 daemon verbs 与 capture fallback 策略。

## 设计取舍

- provider/capturer 通过 protocol 注入，CI 单测不依赖真实窗口或 Screen Recording permission。
- SCK async capture 通过现有 blocking async bridge 加 10 秒 timeout 同步到 socket queue，避免无限阻塞 daemon；超时或任意 SCK error 都走 CGWindowList fallback。
- `screenshot.pid` 只作为可选约束；缺省时根据 `window_id` 从 CGWindowList 解析 owner pid，匹配外部 consumer 的调用方式。
- JPEG quality 固定约 0.85，编码结果必要时缩小，避免接近 64 MB frame cap。

## 验证

- `swift build` 通过。
- `swift build --configuration release --product cua-driver` 通过。
- 本地 `swift test` 仍被 Command Line Tools 缺少 `XCTest` 阻塞；CI 的 macOS runner 会执行。
- 本地 live daemon proof 通过：`list_windows` 返回窗口 JSON，`screenshot` 只传 `window_id` + `format` 时成功返回 JPEG，并通过 `--screenshot-out-file` 写出可解码图片。
