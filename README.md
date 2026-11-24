# AppLock（RootHide / iOS 17 适配移植版）

基于 [AT5HK/AppLock](https://github.com/AT5HK/AppLock)（原作者 AT5HK）移植，用于 iOS 17 + RootHide（iphoneos-arm64e）环境。

原仓库没有附带 LICENSE 文件，本仓库仅作个人适配与自用，不用于公开分发。

## 与原版的差异

- 构建目标改为 `iphone:clang:16.5:15.0`、`ARCHS = arm64e`、`THEOS_PACKAGE_SCHEME = roothide`
- 不再依赖 AltList 框架：设置面板自己枚举已安装 App 生成列表（原版用 AltList 的多选控制器，在 RootHide 下会因框架未加载导致面板打不开）
- 补了 `vendor/MobileCoreServices` 的最小声明，避免依赖 SDK 私有头
- PreferenceLoader 入口 plist 移到根 `layout/`，确保随包安装
- 设置界面与提示文案汉化

## 依赖

无第三方依赖，也不需要 AltList。

## 构建

推送到 main 后由 GitHub Actions（macos-15）用 roothide/theos 编译，产物为该 run 的 `roothide-deb` artifact。

## 使用说明

- 桌面图标 / Spotlight 点开已上锁的 App 时触发验证（面容 ID / 触控 ID 或密码）
- 设置 → 应用锁：总开关「启用」、验证方式「生物识别」「密码」，下方列表勾选要上锁的 App
