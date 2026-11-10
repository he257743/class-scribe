# 验证范围

## 1.7.1：macOS 27.2 收音兼容性

2026 年 11 月 10 日，在 Apple M6 / 24GB、macOS 27.2、Swift 6.4.2 / macOS 27 SDK 上复现了 Float32 PCM 经过 `AnalyzerInput` 时的 SIGTRAP。独立合成输入和重采样输入均可复现，Int16 对照正常。1.7.1 将原始 PCM 采集与 Apple Speech 输入分开，千问模式不再构造 `AnalyzerInput`；苹果模式在新系统上选用支持的 Int16 格式并提前拒绝不兼容输入。

全部原有 228 项 Swift 检查、14 项新增音频检查和 25 项 Python 检查通过，合计 **267 项**。新检查覆盖 Float32 原样传送、重采样后的有效帧长度、保存原音后数据不变、异步时间戳、Int16 苹果输入与不兼容格式错误。

真实本机 Qwen3-ASR 与 Apple Translation 通过合成英语文件的三次按时回放，包含暂停与恢复、末段定稿、保存和重新读取。此次没有打开麦克风，没有运行数小时课堂测试；苹果完整识别流程未在这台机器上重跑，苹果输入构造由合成 Int16 检查覆盖。翻译完成只证明流程可用，不代表中文语义质量已经通过人工评估。报告见 `validation/macos27-audio-capture.json` 与 `validation/qwen-lifecycle-macos27.json`。

复现检查：`zsh Tests/run.sh`；已准备本机组件与翻译语言包时，可运行 `zsh Tests/run-qwen-lifecycle.sh`。无需重下千问识别或上下文模型。

## 1.7.0 及以前的历史检查

以下记录基于应用 1.7.0，保留历史检查的范围和复现方法。具体结果见 `validation/summary.json`，环境和执行日期不代表 1.7.1 的当前检查。

2026 年 11 月 5–6 日，本机重新构建、签名与 ZIP 检查通过；十组 Swift 回归检查共 **228 项通过**：转录与导出 16、删除 21、段落 30、实时预览 30、暂停恢复 27、上下文校订 47、识别后端 21、提示回显保护 13、循环识别保护 13、识别节奏 10。另有 25 项 Python 音频调度与生成检查通过，合计 **253 项**。脚本额外执行了 DOCX 导出检查。

此前在本机通过的 Apple 两项可选原生管线报告也予以保留。1.7.0 另行运行下方的双引擎与真实录音应用管线检查。对应报告为 `validation/native-live-preview-test.json` 和 `validation/native-paragraph-test.json`。所有输入均为脚本化文字或本机合成英语，不是私人课堂录音。

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
| 识别引擎与通信 | `Tests/SpeechBackendTests.swift`、`Tests/QwenWorkerTests.py` | 后端选择、组件准备取消、缺失恢复、匿名音频管道、过载停止、样本保留与末段收尾 |
| 异常回显 | `Tests/PromptEchoTests.swift` | 历史异常标记、原文保留、翻译与校对隔离、导出标签和人工确认 |
| 循环识别 | `Tests/RepetitionTests.swift` | 旧循环标记、正常重复保留、异常窗口隔离、保存恢复、相邻段落继续翻译 |
| ZIP | `python3 Tools/VerifyPackage.py dist/听课译记.zip` | 归档结构、UTF-8 文件名、图标和可执行权限 |
| 原生预览（可选） | `Tests/NativeLivePreviewTest.swift` | 脚本化英文识别文本经过真实 Apple 翻译与应用调度流程 |
| 原生音频管线（可选） | `Tests/NativeParagraphTest.swift` | 本机合成英语文件经过真实识别、应用段落队列、翻译与保存恢复 |

可选本机模型入口为 `Tests/NativeContextReviewTest.swift`，需要预先准备较大模型；不开启麦克风。

逻辑测试使用临时存储和合成内容；暂停测试注入录音后端和可控时钟。两项可选的原生管线均不启用麦克风，不读取私人课堂录音。

## 延迟数字的解释

原生预览报告中的时间范围是“识别文字输入到中文写入模型状态”，不包含麦克风、音频采集和语音识别，也不等于用户屏幕上实际完成绘制的时间。它只能帮助验证预览流程，不能作为课堂端到端延迟宣传。

上下文校对报告中的耗时从提交合成识别文字窗口开始，到校订通过验证为止。此次有判断任务的开发样例约为 4.1–5.3 秒（无候选的两个保留样例不调用模型）；应用调度与保存样例约 5.2 秒。这不包含获取后文所需的等待、麦克风、语音识别或屏幕绘制，不能当作语音到中文的端到端延迟，也不能承诺其他机器或负载下相同耗时。

## 双识别引擎的实际管线

`validation/backend-comparison.json` 记录同一段合成英语按墙钟节奏回放到 `AudioCapturing`，经过真实苹果或千问识别、真实 Apple Translation、应用预览队列和保存恢复的结果。两个引擎均成功完成。单一开发样例的词错误率为 Apple 2.27%、Qwen3-ASR 0.00%；首次中文分别约 1.91 / 4.41 秒。启动时间另计，词错误率不评价标点、断句和中文质量；不能推广为真实课堂准确率。

额外使用同一段 45 秒已有课堂录音进行本机检查，两种引擎均完成识别、翻译与保存恢复。没有人工标准稿，因此不计算课堂词错误率。课堂音频和转录文字未进入公开仓库。

`Tests/run-qwen-lifecycle.sh` 使用真实千问进程验证停止、暂停后继续、排除暂停时间、末段定稿及保存恢复。独立 Python 首次安装流程也已验证：下载并核验官方 Python，从公开 PyPI 安装依赖，复用本机已校验权重后完成离线识别与正常退出。没有重复下载 1.6GB 权重来测试网络模型下载。

资源报告分别记录宿主进程 RSS、千问工作进程 RSS 和 Metal 分配峰值。苹果识别/翻译系统服务的完整内存未测，不能将进程 RSS 当作总内存，更不能直接将 RSS 与共享内存中的 Metal 分配相加。

可复现命令：

```sh
zsh Tests/run-backend-comparison.sh
python3 Tools/SummarizeBackendComparison.py build validation/backend-comparison.json
zsh Tests/run-qwen-lifecycle.sh
```

## 提示回显与底噪回归

1.6.0 可能把 ASR 指令与完整词表当成课堂内容输出。1.6.1 移除识别提示注入，在推理前使用 WebRTC VAD 筛查整段窗口，同时保留完整原音。历史异常的标记由读取时计算，不改写用户记录。

在本机同一段 12 秒问题录音上，旧版产生 24 次包含回显的增量结果更新（不是 24 段独立发言）；新版未出现回显。6 秒数字静音、低幅白噪声和风扇低频声均没有生成字幕；正常英语仍可识别并结束。结果见 `validation/prompt-echo-regression.json`。私人音频、识别文字和视频未公开。

上述是已知故障的回归，不证明所有背景声都能被排除；轻声、短语或远场语音仍可能漏判。组件升级正常路径已在现有安装上验证：补充 WebRTC 依赖并更新就绪标记，复用已校验的识别权重。

可选复现入口：

```sh
# 先运行 Tests/run-qwen-lifecycle.sh 生成本机合成英语文件
python3 Tests/run-qwen-no-speech.py
# 可用自己的 16kHz 单声道 PCM16 WAV 追加故障样例
python3 Tests/run-qwen-no-speech.py --problem-audio /path/to/example.wav
```

## 循环输出回归

1.6.1 的静音和提示回显保护没有覆盖所有生成退化。此次用另一段已有故障录音进行前后对比：旧版产生 20 次可疑增量字幕更新并提前退出；新版标记 1 次可疑快照，没有将循环作为普通字幕发布，且正常退出。把清楚的合成英语接到问题音频后，后续识别仍完成。这里的更新次数不是独立发言次数。

`Tests/run-qwen-repetition.py` 使用实际本机模型和文件回放。结果见 `validation/repetition-regression.json`，只保留统计，不包含私人音频和转录文字。另通过真实 Qwen 进程、Apple Translation 与 AppModel 队列的恢复和保存检查。更长窗口的正确结果可以替换异常草稿，因此不要求暂时出现的异常标记永久保留。

```sh
# 已准备模型，并通过生命周期检查生成合成英语文件后
python3 Tests/run-qwen-repetition.py --problem-audio /path/to/example.wav
```

这些样例证明已知故障的隔离和恢复，不证明所有循环都可检出，也不证明真实课堂准确率。

原生测试最多等待 60 秒让系统翻译进入就绪，准备等待不计入音频输入延迟；语言包未就绪时会保留系统返回的原因。

## 长上下文优化验证

本机用同一批已有课堂录音的 8 个 30 秒中段及 2 个低信息量片段，对比旧版与 1.7.0 上下文模式。源录音与全部识别原文只留本机，不进入仓库。新的窗口与完整词元解码在这些样例中保持正常退出；固定数字样例与部分短语有改善，部分专业词和低信息量短句仍未解决。统计见 `validation/lecture-optimization.json`。

真实课堂测试没有人工逐字标准稿，不计算 WER、不宣称整体准确率提升。中文交谈和背景声音样本也不作为“英语转中文”翻译质量的合格证明。另使用真实应用管线验证上下文与快速模式的翻译和保存；两种模式的原始时间范围仍由所选上限约束。

字符完整性覆盖 UTF-8 跨词元字节及历史损坏文本提示；完整序列解码的合成检查不等同于真实语音识别准确率。

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

原生语言资产由 macOS 管理，可能受系统支持范围、语言包安装状态和当前机器环境影响。CI 只执行构建、Swift / Python 逻辑回归与打包检查，不自动下载语言包或启动麦克风。

已额外准备 Qwen3 较大模型后，可运行：

```sh
zsh Tests/run-context-native.sh
```

## 官方技术依据

- [SpeechAnalyzer / SpeechTranscriber（WWDC25）](https://developer.apple.com/videos/play/wwdc2025/277/)
- [TranslationSession](https://developer.apple.com/documentation/translation/translationsession)
- [GitHub 托管 runner 配置](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
