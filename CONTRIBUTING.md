# 参与贡献

欢迎反馈使用问题、提出功能建议，或提交代码和文档改进。

## 报告问题

请在 Issue 中说明 macOS 版本、应用版本、使用步骤、预期结果和实际结果。涉及识别或翻译的问题，尽量用一小段可分享的合成文字或音频复现，便于比较。

## 修改代码

1. Fork 仓库并创建分支。
2. 按 README 配置 Apple Silicon Mac、macOS 26 和 Xcode 开发环境。
3. 实现改动，保持原文、译文和录音时间范围的对应关系。
4. 运行与改动相关的检查：

```sh
zsh build.sh
zsh Tests/run.sh
python3 Tools/VerifyPackage.py dist/听课译记.zip
```

需要验证系统模型管线时，先安装对应语言包，再运行 `zsh Tests/run-native.sh`。这个脚本使用合成音频，不开启麦克风。

5. 提交 Pull Request，说明改动内容、验证方式和已知限制。

技术结构见[开发文档](docs/ENGINEERING.md)，测试覆盖与边界见[验证范围](docs/VALIDATION.md)。请将改动集中在所解决的问题上，并注明新增行为需要的系统版本或语言包。

## 许可证

贡献内容以仓库中的 [MIT 许可证](LICENSE)提供。
