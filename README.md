# RelayPulse — Sub2API & NewAPI 多中转站消耗统计 iOS App

原生 SwiftUI 打造的 iOS 数据统计客户端，全面适配 **iOS 26 / iOS 27 Liquid Glass（液态玻璃）** 视觉语言，内置 GitHub Actions 自动编译打包未签名 `.ipa`。

## 核心功能

- **双协议深度兼容**：同时支持 **Sub2API**（`Wei-Shaw/sub2api`）与 **NewAPI / OneAPI**（`QuantumNous/new-api` 及兼容分支）。
- **多中转站管理与总览**：
  - 独立登录并管理任意数量的 Sub2API 与 NewAPI 中转站，每个站点会话 Cookie、密码与 Token 独立加密保存在 iOS Keychain。
  - **消耗总览页**：汇总所有活跃中转站的折算总花费、原始 USD 额度、总剩余余额、总请求数、总 Tokens，提供交互式柱状/曲线趋势图、多站点占比环形图、各中转站独立消耗对比卡片以及全站模型消耗排行。
- **灵活时间范围统计**：
  - 支持 **今日（分时）**、**近 7 天**、**近 30 天**、以及 **自定义起止日期**（含近 14 天、本月至今、上个月、近 90 天快捷选择；NewAPI 超 28 天查询自动分段拉取合并）。
- **双模式登录认证**：
  - **账号密码登录**：支持 Sub2API（邮箱+密码，自动续期 Refresh Token）与 NewAPI（用户名+密码，自动管理独立 Session Cookie）。
  - **访问令牌登录**：支持 Sub2API（面板 JWT Token / `sk-` API Key 兜底）与 NewAPI（系统访问令牌 + `New-Api-User` ID / `sk-` API Key 兜底）。
  - 登录表单内置 **「测试连接并验证登录」**，自动探测余额与 NewAPI `quota_per_unit`。
- **每站点独立汇率转换比例**：
  - 针对不同中转站折扣汇率差异（如 1.5 元/刀、2 元/刀、原价 7.2 元/刀），添加/编辑中转站或详情页均可独立设置 `1 USD = ? 目标货币`，总览自动精准折算并同时展示原始美元额度。
- **iOS 26 / iOS 27 Liquid Glass 液态玻璃 UI**：
  - 使用原生 `GlassEffectContainer`、`.glassEffect(.regular.interactive(), in:)`、`.glassEffectID(_:in:)` 流体形变动画、`.buttonStyle(.glass)` / `.buttonStyle(.glassProminent)` 与 `.tabBarMinimizeBehavior(.onScrollDown)`，搭配动态 `MeshGradient` 环境光背景（自适应深浅色模式）。

## GitHub Actions 自动打包未签名 IPA

项目已配置 `.github/workflows/build-ipa.yml`：

1. 将本文件夹推送至 GitHub 仓库（`main` / `master` 分支），或在 GitHub 仓库的 **Actions** 页面手动点击 **Run workflow** 触发构建。
2. Workflow 会自动在 `macos-26` Runner 上：
   - 选用最新预装的 Xcode（支持 Xcode 26 / Xcode 27 SDK）
   - 使用 `XcodeGen` 根据 `project.yml` 生成 `RelayPulse.xcodeproj`
   - 以 `CODE_SIGNING_ALLOWED=NO` 编译 Release 真机产物
   - 打包为标准 `Payload/RelayPulse.app` 结构的未签名 `.ipa`（`RelayPulse-<version>-b<run>-unsigned.ipa`）
3. 构建完成后，在 Workflow 的 **Artifacts** 区域即可下载 `RelayPulse-unsigned-ipa`；若推送 `v*` 标签（如 `git tag v1.0.0 && git push origin v1.0.0`），还会自动创建 GitHub Release 并附带未签名 `.ipa`。
4. 下载后可使用 TrollStore、AltStore、SideStore、Sideloadly、ESign 等工具签名或直接安装到设备。

## 项目结构

```text
├── .github/workflows/build-ipa.yml   # GitHub Actions 自动构建未签名 IPA
├── project.yml                       # XcodeGen 工程配置 (iOS 26.0+ / Liquid Glass)
└── RelayPulse/
    ├── App/                          # 应用入口与 Liquid Glass TabView
    ├── DesignSystem/                 # Liquid Glass 封装、MeshGradient、格式化工具
    ├── Models/                       # 站点模型、用量统计模型、Sub2API/NewAPI DTO
    ├── Services/                     # Keychain 凭据存储、Sub2API/NewAPI 客户端、状态管理
    ├── Views/                        # 总览、中转站管理、站点详情、登录编辑表单、图表、设置
    └── Resources/                    # Info.plist 与 Assets.xcassets (含 AppIcon)
```
