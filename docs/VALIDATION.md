# 验证范围

以下记录基于应用 1.5.0，记录本地检查的范围和复现方法。具体结果见 `validation/summary.json`。

2026 年 11 月 5 日，本机重新构建、签名与 ZIP 检查通过；六组回归检查共 **168 项通过**：转录与导出 16、删除 21、段落 30、实时预览 30、暂停恢复 27、上下文校订 44。脚本额外执行了 DOCX 导出检查。

同日，Apple 两项可选原生管线也已通过。对应报告为 `validation/native-live-preview-test.json` 和 `validation/native-paragraph-test.json`。所有输入均为脚本化文字或本机合成英语，不是私人课堂录音。

实际本机 Qwen3 `qwen3:1.7b`、Apple 词语翻译和修订验证流程的 **8 个开发样例**均符合预期，另通过真实应用调度、保存和重新加载检查。样例覆盖 mutex / cache 误听、port / critical section 词义，以及现金、港口在话题切换时应保留原义的反例。报告见 `validation/native-context-test.json`。这些样例参与了开发调试，属于回归样例，不是独立准确率评估集。

## 分层验证

| 层次 | 入口 | 能证明什么 |
| --- | --- | --- |
| 构建与本机签名 | `zsh build.sh` | 当前源码可编译为原生应用，并通过本机签名检查 |
| 转录逻辑 | `Tests/TranscriptTests.swift` | 时间轴修订、重复识别、翻译覆盖保护、保存恢复和导出基础 |
| 删除 | `Tests/DeletionTests.swift` | 确认取消、文件归属、回滚、空列表与录音状态保护；废纸篓动作采用注入实现 |
| 段落 | `Tests/ParagraphTests.swift` | 分段、停顿、定稿、原始片段保留、继续听课与旧记录兼容 |
| 预览 | `Tests/LivePreviewTests.swift` | 节流、请求合并、原文修订、定稿优先、取消及迟到回复保护 |
| 暂停 | `Tests/PauseTests.swift` | 模拟收音停止、排除暂停间隔、恢复衔接、权限与启动失败、退出等待 |
| 后文校对 | `Tests/ContextReviewTests.swift` | 局部替换、后文引用、原文保留、人工修改、过期回复、旧记录兼容与导出 |
| ZIP | `python3 Tools/VerifyPackage.py dist/听课译记.zip` | 归档结构、UTF-8 文件名、图标和可执行权限 |
| 原生预览（可选） | `Tests/NativeLivePreviewTest.swift` | 脚本化英文识别文本经过真实 Apple 翻译与应用调度流程 |
| 原生音频管线（可选） | `Tests/NativeParagraphTest.swift` | 本机合成英语文件经过真实识别、应用段落队列、翻译与保存恢复 |

可选本机模型入口为 `Tests/NativeContextReviewTest.swift`，需要预先准备较大模型；不开启麦克风。

逻辑测试使用临时存储和合成内容；暂停测试注入录音后端和可控时钟。两项可选的原生管线均不启用麦克风，不读取私人课堂录音。

## 延迟数字的解释

原生预览报告中的时间范围是“识别文字输入到中文写入模型状态”，不包含麦克风、音频采集和语音识别，也不等于用户屏幕上实际完成绘制的时间。它只能帮助验证预览流程，不能作为课堂端到端延迟宣传。

上下文校对报告中的耗时从提交合成识别文字窗口开始，到校订通过验证为止。此次有判断任务的开发样例约为 4.1–5.3 秒（无候选的两个保留样例不调用模型）；应用调度与保存样例约 5.2 秒。这不包含获取后文所需的等待、麦克风、语音识别或屏幕绘制，不能当作语音到中文的端到端延迟，也不能承诺其他机器或负载下相同耗时。

## GitHub Actions

[构建与回归检查](https://github.com/he257743/class-scribe/actions/workflows/checks.yml)会在推送与合并请求时运行。每次执行关联其验证的提交，具体状态和日志可在 Actions 页面查看。本地报告与远端工作流结果分别记录，避免把本地检查当作远端执行结果。

## 尚未证明

- 真实教室、不同口音、远场距离和专业术语条件下的识别准确率。
- 与其他识别模型在同一人工标准稿上的优劣。
- 实际麦克风暂停操作和数小时课堂使用的稳定性。
- 已通过 Apple 公证或正式商店分发审核。

## 复现

在满足系统与工具链要求的 Apple Silicon Mac 上运行：

```sh
zsh build.sh
zsh Tests/run.sh
python3 Tools/VerifyPackage.py dist/听课译记.zip
```

安装系统英语识别和英中翻译语言包后，可额外运行：

```sh
zsh Tests/run-native.sh
```

原生语言资产由 macOS 管理，可能受系统支持范围、语言包安装状态和当前机器环境影响。CI 只执行构建、逻辑回归与打包检查，不自动下载语言包或启动麦克风。

已额外准备 Qwen3 较大模型后，可运行：

```sh
zsh Tests/run-context-native.sh
```

## 官方技术依据

- [SpeechAnalyzer / SpeechTranscriber（WWDC25）](https://developer.apple.com/videos/play/wwdc2025/277/)
- [TranslationSession](https://developer.apple.com/documentation/translation/translationsession)
- [GitHub 托管 runner 配置](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
