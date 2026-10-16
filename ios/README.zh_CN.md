# Passport Agent（iOS/iPadOS 27+）

这是无需电脑运行的原生 Agent App。它通过 ScreenCaptureKit 获取用户授权的整个显示屏，把抽取的 JPEG
关键帧发送给兼容 OpenAI Chat Completions 的视觉模型，再通过 BLE 自定义服务把单步命令发给 AI Passport。
Passport 同时保持系统级鼠标和键盘 HID 连接。

## 构建

需要 Xcode 27 和 XcodeGen：

```bash
cd ios
xcodegen generate
open PassportAgent.xcodeproj
```

在 Xcode 中选择自己的开发团队和一台运行 iOS/iPadOS 27 或更高版本的真机。ScreenCaptureKit 全屏采集、
蓝牙 HID 和自定义 GATT 服务都必须在真机验收，模拟器不能代替。

## 首次使用

1. 把本仓库的 `hardware/ai_passport` 固件刷入 AI Passport。
2. 在设备的“设置 → 辅助功能 → 触控 → 辅助触控”中开启辅助触控。
3. 在系统蓝牙设置中配对 **AI Passport**。
4. 打开 Passport Agent；在“设置”中填写 HTTPS API 地址、视觉模型名称和 API Key。
5. 输入任务并点击“开始任务”，在系统共享面板选择整个显示屏。
6. 保持 AI Passport 的 OK 急停键随时可用。

API Key 仅保存在本机钥匙串；屏幕 JPEG、任务文本和最近操作会发送到用户配置的模型服务。首个版本拒绝让
模型继续处理密码、支付、删除账号和权限确认。每次最多执行 100 步或 10 分钟。

## BLE 控制服务

- Service: `8F5B0001-6F57-4E28-9B5D-6D1D6F7A1000`
- Command（write）: `8F5B0002-6F57-4E28-9B5D-6D1D6F7A1000`
- Reply（read/notify）: `8F5B0003-6F57-4E28-9B5D-6D1D6F7A1000`

命令使用现有 UTF-8 单行协议，最大 255 字节；回复为 `ok` 或 `err <原因>`。特征要求加密连接。

## 当前验收边界

坐标点击由 App 拆成 `home`（把指针推到左上边界）、`move x y` 和 `click`。不同设备的辅助触控跟踪速度
和指针加速度仍需真机校准；在完成校准前，不应把默认坐标用于精确或不可逆操作。
