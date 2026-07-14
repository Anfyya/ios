# NodeScope / 节点体检

[![Build iOS App](https://github.com/Anfyya/ios/actions/workflows/build-ios.yml/badge.svg)](https://github.com/Anfyya/ios/actions/workflows/build-ios.yml)

面向 iOS 26 的节点质量检测 App。主页仅保留一个“开始测试”按钮，右上角进入历史记录；界面使用 SwiftUI 原生 Liquid Glass 组件。

## 检测流程

### 1. 公共 DNS 基础网络检测

对 6 个公共 DNS 地址分别执行 5 次真实 ICMP Echo，记录每次回包、平均/最低/最高延迟、成功率与丢包率：

- 国内：阿里公共 DNS `223.5.5.5`、DNSPod `119.29.29.29`、114DNS `114.114.114.114`
- 国外：Cloudflare `1.1.1.1`、Google Public DNS `8.8.8.8`、Quad9 `9.9.9.9`

基础网络合格条件：

- 至少一个国内 DNS 达标：成功率 ≥ 80%、丢包率 ≤ 20%、平均延迟 ≤ 500ms；
- 至少一个国外 DNS 收到 ICMP 响应；
- 两项同时满足才判定基础网络合格。

部分网络会主动屏蔽或限速 ICMP，因此 DNS 结果只作为基础网络质量指标，不直接代替网站可访问性判断。

### 2. 网站服务可用性检测

对以下 11 个域名分别执行 5 次 TCP 443 主动连接，并执行 HTTPS 请求确认网站层是否可访问：

- Google、Gemini、OpenAI、ChatGPT、Claude.ai、Claude.com、Grok、xAI
- 百度、哔哩哔哩、my78.cyou

网站结果只表示对应服务当前能否访问，不参与公共 DNS 基础网络门槛。

### 3. 出口 IP 质量检测

无论 DNS 或网站检测结果是否合格，都会继续完成全部 IP 质量检测，不会中途停止。App 自动获取公网 IPv4，并通过 6 个免 Key 数据源交叉判断国家/地区、ASN、代理、VPN、Tor、机房、滥用与垃圾记录：

- ipapi.is
- ip-api.com
- ipwho.is
- ipapi.co
- proxycheck.io
- StopForumSpam

最终分别给出基础网络、服务可用性、网络信誉风险和 Claude 风控风险，并生成综合结论。

## 可视化

- 每个公共 DNS 的 5 次 ICMP 状态、丢包率、平均/最低/最高延迟；
- 国内 DNS 与国外 DNS 门槛判定；
- 每个网站的 5 次 TCP 连接、HTTPS 状态和连接延迟；
- DNS 与网站延迟图表；
- 每个 IP 数据源的成功/失败、位置、ASN 与风险标记；
- 网络风险、Claude 风险、可信度与完整判断依据；
- 最近 50 次完整历史记录，可查看详情、单条删除或清空。

## 开源依赖

ICMP Echo 使用 `samiyr/SwiftyPing`，通过 Swift Package Manager 固定到提交 `05591bc0047e41e0e1d98135c6bc457192a72d39`，避免上游更新导致构建结果漂移。

## GitHub Actions 自动构建

推送到 `main`、提交 Pull Request 或手动触发 Actions，都会在 GitHub 的 `macos-26` runner 上使用 Xcode 26.5：

1. 安装 XcodeGen；
2. 从 `project.yml` 生成 Xcode 工程；
3. 解析固定版本的 Swift Package；
4. 编译 iOS 模拟器版本；
5. 编译无签名真机版本；
6. 打包并上传 `NodeScope-unsigned.ipa` 与 SHA-256 文件。

无签名 IPA 不能直接安装到未越狱 iPhone；需要使用自己的开发者证书重新签名，或使用支持自签名的安装方式。仓库不保存任何证书和私钥。

## 本地构建

```bash
brew install xcodegen
xcodegen generate
open NodeScope.xcodeproj
```

最低系统为 iOS 26.0，Bundle ID 为 `com.anfyya.NodeScope`。
