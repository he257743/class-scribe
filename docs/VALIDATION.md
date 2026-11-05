# 验证范围

以下记录基于应用 1.4.0，记录本地检查的范围和复现方法。具体结果见 `validation/summary.json`。

2026 年 11 月 5 日，本机重新构建、签名与 ZIP 检查通过；五组回归检查共 **124 项通过**：转录与导出 16、删除 21、段落 30、实时预览 30、暂停恢复 27。脚本额外执行了 DOCX 导出检查。

同日，两项可选原生管线也已通过。对应报告为 `validation/native-live-preview-test.json` 和 `validation/native-paragraph-test.json`。所有输入均为脚本化文字或本机合成英语，不是私人课堂录音。

## 分层验证

| 层次 | 入口 | 能证明什么 |
| --- | --- | --- |
| 构建与本机签名 | `zsh build.sh` | 当前源码可编译为原生应用，并通过本机签名检查 |
| 转录逻辑 | `Tests/TranscriptTests.swift` | 时间轴修订、重复识别、翻译覆盖保护、保存恢复和导出基础 |
| 删除 | `Tests/DeletionTests.swift` | 确认取消、文件归属、回滚、空列表与录音状态保护；废纸篓动作采用注入实现 |
| 段落 | `Tests/ParagraphTests.swift` | 分段、停顿、定稿、原始片段保留、继续听课与旧记录兼容 |
| 预览 | `Tests/LivePreviewTests.swift` | 节流、请求合并、原文修订、定稿优先、取消及迟到回复保护 |
| 暂停 | `Tests/PauseTests.swift` | 模拟收音停止、排除暂停间隔、恢复衔接、权限与启动失败、退出等待 |
| ZIP | `python3 Tools/VerifyPackage.py dist/听课译记.zip` | 归档结构、UTF-8 文件名、图标和可执行权限 |
| 原生预览（可选） | `Tests/NativeLivePreviewTest.swift` | 脚本化英文识别文本经过真实 Apple 翻译与应用调度流程 |
| 原生音频管线（可选） | `Tests/NativeParagraphTest.swift` | 本机合成英语文件经过真实识别、应用段落队列、翻译与保存恢复 |

逻辑测试使用临时存储和合成内容；暂停测试注入录音后端和可控时钟。两项可选的原生管线均不启用麦克风，不读取私人课堂录音。

## 延迟数字的解释

原生预览报告中的时间范围是“识别文字输入到中文写入模型状态”，不包含麦克风、音频采集和语音识别，也不等于用户屏幕上实际完成绘制的时间。它只能帮助验证预览流程，不能作为课堂端到端延迟宣传。

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

## 官方技术依据

- [SpeechAnalyzer / SpeechTranscriber（WWDC25）](https://developer.apple.com/videos/play/wwdc2025/277/)
- [TranslationSession](https://developer.apple.com/documentation/translation/translationsession)
- [GitHub 托管 runner 配置](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
