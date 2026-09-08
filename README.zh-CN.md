# WordAI Community

免费的开源单词学习应用。使用 Flutter 和本地 SQLite，默认无需账号、订阅或服务器。

这是 WordAI 的社区版，导入了当前产品的学习与 Flash Card 核心，并采用独立、干净的 Git 历史。它不是生产版的完整镜像：账号、云同步、AI 查词、支付、生产词库下载与部署配置不包含在内。

## 已包含

- 本地学习记录、词义级进度、例句与独立识别两个阶段。
- 从本地已导入的全部词义中选择干扰选项，避免“题目不足”误报为“全部学完”。
- 每题自动发音，优先本地音频缓存；可选自建 HTTPS 语音网关；失败时尝试设备语音。
- 12 个原创示例词；导入自己有权使用的 S6 格式 JSON 词条。
- 英文、简体中文和繁体中文复习界面；减少动态效果支持。

## 运行

安装 Flutter 3.44 或更新的 stable 版本（Dart 3.6 或更新），然后：

```sh
flutter pub get
flutter run
```

原生工程包含 Android、iOS、macOS。iOS/macOS 真机签名由开发者自行配置；仓库没有个人签名团队、证书或生产服务配置。平台支持以实际构建和测试结果为准。

```sh
flutter analyze
flutter test
python3 scripts/check_public_tree.py
```

## 导入词条

首页选择“导入 JSON”。文件可以是一个词条对象或数组，采用 `lib/services/wordai_dossier.dart` 定义的 S6 schema。整个文件先验证，再写入本地数据库；实际读取上限 10 MiB / 20,000 条，空文件、空数组和没有学习内容的查词结果不能导入。重复导入更新内容并保留学习进度。导入过程中发生存储错误时，已完成的词条会保留，可以重试。

首页刷新只补充缺失的样例词义，不覆盖用户导入的内容或已有学习进度。CI 使用 Flutter 3.44.0 和 3.47.2 分别运行分析与测试，后者同时生成可下载的 Android debug APK；该产物用于开发验证，尚非商店签名发行版。

示例：`examples/words.json`。请确认导入内容的分发与使用许可。生产环境的第三方词库和音频没有随本仓库分发。

## 可选语音网关

默认不联系网络服务。设备离线语音是否可用取决于系统安装的语音包。需要下载发音时，自行实现 [网关协议](docs/speech-gateway.md)，再显式配置自己的地址：

```sh
flutter run --dart-define=WORD_AI_API_BASE_URL=https://your-gateway.example
```

该地址会编译进客户端，只能放非敏感的服务地址。供应商密钥只能保存在服务端。使用自建网关时，当前需要发音的文字会发送给该网关；失败不会阻止本地学习。

## 开源与贡献

源代码采用 Apache-2.0，可修改、自托管、再分发及商用，遵守许可证和第三方许可即可。WordAI 名称与图标不构成商标授权。依赖包继续适用各自许可证。

参见 [开源范围](docs/open-source-scope.zh-CN.md)、[贡献说明](CONTRIBUTING.md) 和 [安全说明](SECURITY.md)。
