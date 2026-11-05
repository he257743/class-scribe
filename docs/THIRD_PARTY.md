# 第三方组件与模型

## Apple 系统框架

基础收音、语音识别和翻译使用 AVFoundation、Speech 与 Translation。框架和系统语言包由 macOS 提供，遵循 Apple 的相关条款；本仓库不分发 Apple 模型权重。

## 可选本机上下文校对

- **运行组件：Ollama 0.40.14**。源码和许可见 [Ollama](https://github.com/ollama/ollama/tree/v0.40.14) 与 [MIT License](https://github.com/ollama/ollama/blob/v0.40.14/LICENSE)。准备时从官方发行地址下载，并核对固定 SHA-256。
- **语言模型：Qwen3**，可选 `qwen3:0.6b` 或 `qwen3:1.7b` 的量化版本。模型信息见 [轻量模型](https://ollama.com/library/qwen3:0.6b)、[较大模型](https://ollama.com/library/qwen3:1.7b) 与 [Qwen 官方模型](https://huggingface.co/Qwen/Qwen3-1.7B)。模型按其 Apache-2.0 许可提供，不受本仓库 MIT 许可替代。

模型与运行组件首次准备需要联网，之后保存在 Mac 本机的应用支持目录。推理服务固定监听 `127.0.0.1:11435`，关闭云端模型功能；课堂文字只发送到这个本机地址。

下载过程使用官方 HTTPS 源并校验文件摘要。某些代理的 DNS 映射会被运行组件的下载保护拒绝；应用保留该保护，必要时从固定官方注册表和官方 CDN 下载模型文件，逐个校验 SHA-256 后注册到本机缓存。

仓库不包含这些第三方二进制或模型文件，也不包含用户的课堂录音、记录和运行日志。
