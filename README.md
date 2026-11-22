# RelayPulse — Sub2API、NewAPI & ReMail 多平台消耗统计 iOS App

原生 SwiftUI 打造的 iOS 数据统计客户端，全面适配 **iOS 26 / iOS 27 Liquid Glass（液态玻璃）** 视觉语言，内置 GitHub Actions 自动编译打包未签名 `.ipa`。

## 核心功能

- **三平台协议深度兼容**：同时支持 **Sub2API**（`Wei-Shaw/sub2api`）、**NewAPI / OneAPI**（`QuantumNous/new-api` 及兼容分支）与 **ReMail 轻松收码**（`https://remail.best/docs`）。
- **多中转站管理与总览**：
  - 独立登录并管理任意数量的 Sub2API、NewAPI 与 ReMail 账号，每个站点会话 Cookie、密码与 Token/API Key 独立加密保存在 iOS Keychain。
  - **消耗总览页**：汇总所有活跃站点的折算总花费、总剩余余额、总请求/订单数、总 Tokens，提供交互式柱状/曲线趋势图、多站点占比环形图、各站点独立消耗对比卡片以及全站模型/项目消耗排行。
- **灵活时间范围统计**：
  - 支持 **今日（分时）**、**近 7 天**、**近 30 天**、以及 **自定义起止日期**（含近 14 天、本月至今、上个月、近 90 天快捷选择；NewAPI 超 28 天查询自动分段拉取合并；ReMail 游标分页按时间窗口精准统计净支出 `payAmount - refundAmount`）。
- **认证方式说明**：
  - **Sub2API**：支持账号密码登录（`POST /api/v1/auth/login`，自动续期 Refresh Token）与访问令牌登录（JWT Token / `sk-` Key）。
  - **NewAPI**：支持账号密码登录（独立隔离 Session Cookie）与系统访问令牌登录（支持 `New-Api-User` ID / `sk-` Key）。
  - **ReMail (`remail.best`)**：基于官方 OpenAPI（`https://remail.best/openapi.json`）的 `Authorization: Bearer rk-...` 鉴权，调用 `/v1/open/apikey/profile`、`/v1/open/wallet`、`/v1/open/orders`（及 `/v1/open/wallet/transactions` 兜底）拉取钱包余额与各项目消耗。（注：ReMail 网页端 `/v1/login` 需 Cloudflare Turnstile 人机验证，因此开放 API 统一采用 `rk-...` API Key 认证。）
  - 登录表单内置 **「测试连接并验证登录」**，自动探测余额、User ID 与 NewAPI `quota_per_unit`。
- **每站点独立汇率转换比例**：
  - 针对不同中转站折扣汇率差异（如 1.5 元/刀、2 元/刀、原价 7.2 元/刀）及 ReMail 积分折算比例，添加/编辑或详情页均可独立设置，总览自动精准折算汇总。
- **每日 23:59 自动利润核算与历史审查账本**：
  - **主站点（销售额）**：可将任意一个 Sub2API 或 NewAPI 设为「主站点」，支持 **全站总消耗（管理员接口：NewAPI `/api/data/` / Sub2API `/api/v1/admin/dashboard/trend`）** 或 **个人账号消耗** 作为当日销售额。
  - **每日固定成本**：自由填写每日固定开销（如服务器费用、代理线路、CDN，支持填月费自动 ÷30）。
  - **定时自动结算**：注册 iOS `BGAppRefreshTask`（每晚 `23:59` 触发）+ 前台时钟监听 + 次日启动自动补算昨日机制，确保每日不漏账；支持本地通知推送当日盈亏。
  - **历史账本审查与导出**：持久化存储每天的销售额、每个渠道的独立成本明细、固定成本、净利润与毛利率，支持点击审查任意一天明细、添加审查备注、历史日期补录与一键导出 CSV（UTF-8 BOM）。
- **iOS 26 / iOS 27 Liquid Glass 液态玻璃 UI**：
  - 使用原生 `GlassEffectContainer`、`.glassEffect(.regular.interactive(), in:)`、`.glassEffectID(_:in:)` 流体形变动画、`.buttonStyle(.glass)` / `.buttonStyle(.glassProminent)` 与 `.tabBarMinimizeBehavior(.onScrollDown)`，搭配动态 `MeshGradient` 环境光背景（自适应深浅色模式）。

## GitHub Actions 自动打包未签名 IPA

项目已配置 `.github/workflows/build-ipa.yml`：

1. 将本文件夹推送至 GitHub 仓库（`main` / `master` 分支），或在 GitHub 仓库的 **Actions** 页面手动点击 **Run workflow** 触发构建。
2. Workflow 会自动在 `macos-26` Runner 上：
   - 选用最新预装的 Xcode（支持 Xcode 26 / Xcode 27 SDK）
   - 使用 `XcodeGen` 根据 `project.yml` 生成 `RelayPulse.xcodeproj`
   - 以 `CODE_SIGNING_ALLOWED=NO` 编译 Release 真机产物
   - 打包为标准 `Payload/RelayPulse.app` 结构的未签名 `.ipa`（默认版本号 `v0.0.1`，产物名 `RelayPulse-v0.0.1-unsigned.ipa`）
3. 构建完成后会自动上传为 **Artifacts**，并在 `main` / `master` 推送、标签推送或手动触发时 **自动创建/更新 GitHub Release（默认 `v0.0.1`）** 并附带未签名 `.ipa`。后续发新版本时可在手动触发中输入新版本号，或推送新标签（如 `git tag v0.0.2 && git push origin v0.0.2`）。
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
