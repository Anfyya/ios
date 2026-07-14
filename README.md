# NodeScope / 节点体检

面向 iOS 26 的节点质量检测 App。主页仅保留一个“开始测试”按钮，右上角进入历史记录；界面使用 SwiftUI 原生 Liquid Glass 组件。

## 检测流程

1. 对以下 11 个域名分别执行 5 次 TCP 443 主动探测，统计成功率、平均/最低/最高连接延迟和丢包；随后执行一次 HTTPS HEAD 探测，确认网站层面是否可访问：
   - Google、Gemini、OpenAI、ChatGPT、Claude.ai、Claude.com、Grok、xAI
   - 百度、哔哩哔哩、my78.cyou
2. 基础联通判定严格按当前需求：
   - 百度：成功率 ≥ 80%、丢包 ≤ 20%、平均延迟 ≤ 500ms、HTTPS 可访问；
   - 任意一个国外站点能够建立连接或完成 HTTPS 探测；
   - 两项同时满足才算基础联通合格。
3. 无论基础联通是否合格，都会继续完成全部 IP 质量检测，不会中途停止。
4. 自动获取当前公网 IPv4，并使用 6 个免 Key 数据源交叉判断国家/地区、ASN、代理、VPN、Tor、机房、滥用与垃圾记录：
   - ipapi.is
   - ip-api.com
   - ipwho.is
   - ipapi.co
   - proxycheck.io
   - StopForumSpam
5. 分别给出网络信誉风险与 Claude 风控风险，最后生成综合结论。

> iOS 普通 App 不适合依赖系统命令行 `ping`。本项目使用 TCP 连接建立时间作为主动 Ping 的延迟/丢包样本，并额外使用 HTTPS 探测验证真实服务可访问性；这比只看 ICMP 更贴近 AI 网站实际能否使用。

## 可视化

- 每个域名的 5 次探测状态、成功率、丢包、平均/最低/最高延迟、HTTPS 状态；
- 全部站点平均连接延迟图表；
- 每个 IP 数据源的成功/失败、位置、ASN 与风险标记；
- 网络风险、Claude 风险、可信度、判断依据；
- 最近 50 次完整历史记录，可查看详情、单条删除或清空。

## GitHub Actions 自动构建

推送到 `main`、提交 Pull Request 或手动触发 Actions，都会在 GitHub 的 `macos-26` runner 上使用 Xcode 26.5：

1. 安装 XcodeGen；
2. 从 `project.yml` 生成 Xcode 工程；
3. 编译 iOS 模拟器版本；
4. 编译无签名真机版本；
5. 打包并上传 `NodeScope-unsigned.ipa` 与 SHA-256 文件。

无签名 IPA 不能直接安装到未越狱 iPhone；需要使用你自己的开发者证书重新签名，或用支持自签名的安装方式。仓库不保存任何证书和私钥。

## 本地构建

```bash
brew install xcodegen
xcodegen generate
open NodeScope.xcodeproj
```

最低系统为 iOS 26.0，Bundle ID 为 `com.anfyya.NodeScope`。
