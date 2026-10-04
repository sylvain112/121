# ZHFRLive iOS v1

原生 iPhone 中法实时同传第一版骨架。

## 当前架构

- **本地语音转文字**：Argmax WhisperKit，模型 `large-v3-v20240930_626MB`
- **实时翻译**：OpenAI `gpt-realtime-translate`
- **源语言判断**：完全在手机端，根据本地转写文本判断中文 / 法语
- **OpenAI API Key**：不放进 App；App 只从现有 Vercel 后端 `/api/session` 获取短期 `ek_...` client secret
- **音频链路**：同一个 WhisperKit 麦克风采集同时用于本地转写和 Realtime Translation，不再使用 Safari WebRTC 双轨方案

Argmax 当前官方文档推荐 `large-v3-v20240930_626MB` 作为 iOS 上最高多语言准确率的 WhisperKit 变体。首次运行会下载模型，之后模型保存在设备上，本地转写不再产生 OpenAI 转写费用。

## 生成 Xcode 项目

> iOS App 的编译与签名必须使用 macOS + Xcode。Windows 不能直接生成可安装的 iPhone IPA。

1. 在 Mac 安装 Xcode 16+。
2. 安装 XcodeGen：

```bash
brew install xcodegen
```

3. 在本目录运行：

```bash
xcodegen generate
open ZHFRLive.xcodeproj
```

4. Xcode 中选择自己的 Apple Developer Team。
5. 连接 iPhone，选择真机运行。

## 无签名 IPA

仓库包含 `.github/workflows/build-ios-unsigned.yml`。GitHub Actions 会在 macOS/Xcode 上构建真机 Release `.app`，再打包为 `ZHFRLive-unsigned.ipa`，用于 Sideloadly / AltStore / SideStore 等工具自行签名安装。

## 第一次测试

1. App 首次启动会下载约 626 MB 的本地模型，并进行 Core ML specialization。
2. 等界面显示“本地模型已就绪”。
3. 点击“开始同传”。
4. 先连续说中文，观察原文与法语译文。
5. 再连续说法语，观察原文与中文译文。

## 下一步

- 本地 Whisper 分句 / VAD 与两条 Translation 输出更精确地对齐
- 本地模型档位：Small / Medium / Large-v3 Turbo
- 译文语音播放
- 最终高精度二次校正
- 会话总结与导出
- 真机性能 / 发热 / 内存 profiling
