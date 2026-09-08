# 快网云客户端

面向 Android 和 Windows 的快网云客户端，使用网站账号登录、同步订阅并通过内置连接核心使用节点。

网站：https://kuaiwangyun.com/vpn

基于 FlClash v0.8.96 定制，保留 GPL-3.0 许可证及上游著作权。上游项目：https://github.com/chen08209/FlClash 。内核源码随仓库提供，固定版本记录在 `UPSTREAM.json`。

## 本地构建

安装 Flutter 3.44.4、Go 1.26.4 和 Rust stable。Android 另需 JDK 17、SDK 36、NDK 28.2.13676358。Windows 需要 Visual Studio C++ 和 Inno Setup。

```sh
flutter pub get
flutter analyze --no-fatal-infos
flutter test test/features/client_api_test.dart
dart setup.dart android --env stable
dart setup.dart windows --env stable
```

Android 的发布签名放在 `android/app/keystore.jks`，密码和别名放在 `android/local.properties`，这些文件不应提交到源码仓库。Windows 打包可运行本仓库的 GitHub Actions 工作流。

会员到期后本站会拒绝订阅更新。共享上游中已经下载的节点凭据仍由上游管理，客户端不能替代上游独立账号控制。

新增登录功能只与快网云的 HTTPS 账号接口通信。密码不持久化；客户端会话令牌使用系统安全存储。已取消上游 Android 崩溃统计集成。
