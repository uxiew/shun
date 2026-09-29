# 契约草案，不是插件实现

plugin-manifest.schema.json与两个示例用于X00/X12的结构测试，API major=1仅是拟定版本。包名和pluginId为占位，不代表实际已安装软件或官方提供方。

不把证书放进自报JSON当信任证明；读取安装包实际signer。schema结构通过不等于权限安全、路由支持或App验收通过。JSON没有任意exec/文件读取/URL回调透传字段；网络和会话数据必须由实际类型接口承载。

`examples/` 是合法示例，`examples/invalid/` 是必须被拒绝的负例。两处同时检查同一批文件：
`scripts/validate_plan.py`（JSON schema）和 `packages/plugin_api` 的 Dart 测试（运行期校验器），
两边判定必须一致。唯一有意差异见 docs/15 §9：插件 minor 比宿主新时，未知能力在运行期被忽略而非拒绝。

