# ZHFRLive iOS v2.2

原生 iPhone 中法同传，使用本地识别与逐句音频翻译。

## 当前架构

- **本地语音转文字**：Argmax WhisperKit，模型 `large-v3-v20240930_626MB`，保留词级时间戳；两次完整解码结果稳定后按标点或停顿断句。已确认音频从待处理窗口移除，草稿只替换，不累计。
- **逐句流式翻译**：每句使用独立 ID 和相同时间范围的原始音频，发送到 OpenAI `gpt-realtime-translate`；译文回复只能更新对应 ID。每句结束发送 `session.close` 并等到 `session.closed`，保留最后几个词。
- **源语言判断**：完全在手机端，根据本地转写文本判断中文 / 法语
- **OpenAI API Key**：设置页支持本机 Keychain 个人密钥；未填写或关闭个人 API 时，从现有 Vercel `/api/session` 获取临时密钥。
- **文字记录**：只显示译文；原句保存在对应记录内，供 AI 总结和原文导出使用。翻译失败保留原句及音频并允许重试；清空会使旧请求失效。
- **音频链路**：一个麦克风采集；完整句子确认后将对应音频发送到正确的目标语言会话，不再将整个会议持续送往两条翻译通道。译文开始显示前需要等待断句、稳定确认及连接；连续说话的实际延迟和音质需在真机验证。

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
4. 先连续说中文，观察逐句出现的法语译文。
5. 再连续说法语，观察中文译文。测试“你没……你没有学习”不会产生多条碎片记录。
6. 测试结束时最后一句、真实重复句、清空后继续讲话、翻译失败重试，以及导出中原句的顺序。

## 回归验证

构建工作流先用 `swiftc` 执行 `Tests/main.swift`：覆盖稳定确认、累积回放、草稿修订、短句、标点与停顿、双语切换、音频切片、重复事件、清空和重试时迟到的回复；随后编译真机 Release App。测试不调用付费 API，不下载语音模型。

## 下一步

- 真机双语录音回归与分句、语音能量阈值调优
- 本地模型档位：Small / Medium / Large-v3 Turbo
- 译文语音播放
- 最终高精度二次校正
- 会话总结与导出
- 真机性能 / 发热 / 内存 profiling
