# 第三方组件与模型

## Apple 系统框架

基础收音、语音识别和翻译使用 AVFoundation、Speech 与 Translation。框架和系统语言包由 macOS 提供，遵循 Apple 的相关条款；本仓库不分发 Apple 模型权重。

## 可选本机上下文校对

- **运行组件：Ollama 0.40.14**。源码和许可见 [Ollama](https://github.com/ollama/ollama/tree/v0.40.14) 与 [MIT License](https://github.com/ollama/ollama/blob/v0.40.14/LICENSE)。准备时从官方发行地址下载，并核对固定 SHA-256。
- **语言模型：Qwen3**，可选 `qwen3:0.6b` 或 `qwen3:1.7b` 的量化版本。模型信息见 [轻量模型](https://ollama.com/library/qwen3:0.6b)、[较大模型](https://ollama.com/library/qwen3:1.7b) 与 [Qwen 官方模型](https://huggingface.co/Qwen/Qwen3-1.7B)。模型按其 Apache-2.0 许可提供，不受本仓库 MIT 许可替代。

模型与运行组件首次准备需要联网，之后保存在 Mac 本机的应用支持目录。推理服务固定监听 `127.0.0.1:11435`，关闭云端模型功能；课堂文字只发送到这个本机地址。

下载过程使用官方 HTTPS 源并校验文件摘要。某些代理的 DNS 映射会被运行组件的下载保护拒绝；应用保留该保护，必要时从固定官方注册表和官方 CDN 下载模型文件，逐个校验 SHA-256 后注册到本机缓存。

仓库不包含这些第三方二进制或模型文件，也不包含用户的课堂录音、记录和运行日志。

## 可选千问语音识别

- **语音模型**：Qwen3-ASR-1.7B 的 MLX 4-bit 转换，约 1.6GB。[Qwen 官方项目](https://github.com/QwenLM/Qwen3-ASR)、[社区转换模型](https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-4bit)。固定版本 `78a389c776a5483b2d0d4ea5494e11012e0d6159`，权重 SHA-256 `9848eaf7a5c1589c671b35035ac27b72e248dd0c604eacae547e7e403d29db45`，遵循模型的 Apache-2.0 许可。
- **推理组件**：[MLX](https://github.com/ml-explore/mlx) 与 [MLX-Audio](https://github.com/Neywa-Labs/mlx-audio)，遵循各自 MIT 许可；[Transformers](https://github.com/huggingface/transformers) 遵循 Apache-2.0 许可。版本约束列于 `Resources/qwen-asr-requirements.txt`。
- **Python**：[CPython](https://www.python.org/psf/license/) 与 [python-build-standalone](https://github.com/astral-sh/python-build-standalone)。安装器固定使用 20261026 发行的 Apple Silicon Python 3.12.16 归档，并核对官方 SHA-256。Python 及其附带组件保留各自的许可。

运行组件与模型均在用户准备时单独安装到 Mac 的应用支持目录，不包含在源码或应用 ZIP 中。音频在匿名管道中传递给应用自己的本机进程；推理关闭 Hugging Face 自动下载和遥测，不启用云端 ASR。
