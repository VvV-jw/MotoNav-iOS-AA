# MotoNav iOS AA 移植版

基于 [zyn950929/MotoNav](https://github.com/zyn950929/MotoNav) 的 iOS 0.15.0 源码，来源提交和归档校验值见 [UPSTREAM.json](UPSTREAM.json)。本项目为个人非商业修改，保留原项目 [使用条款](LICENSE.md) 及第三方声明。

本轮移植版本：**0.15.1（1），iOS v0.15.1-aa.1**。保留上游 SwiftUI、导航、蓝牙与分享扩展，迁入 Android AA 版本的地图数据处理。尚待 iPhone 与 ESP32-S3-Touch-AMOLED-1.75C 联机验证，电脑测试不能代替设备帧率和后台行为实测。

- 五种圆屏风格：原版、罪恶都市、GTA5、极简黑白、龙珠雷达。
- 原版保留 1200×1200 完整地图和抗锯齿色阶，16 色量化与 Android 对齐；完整包容量为 1.5 MB。
- GTA5 由 OpenFreeMap / OpenStreetMap 矢量瓦片生成五级完整路网、水域与实际 POI，交给 AA 圆屏固件绘制灰色地图和黄色导航路线。
- 按风格隔离离线缓存，沿路线预下载。损坏或未完成的数据不替换当前地图。
- 收到 `CAP,RZ,1` 后才使用兼容圆屏的标准 zlib `RZ1` 压缩；切换风格会取消旧地图队列，导航消息保持优先。

交通灯状态及倒计时沿用固件按实际状态着色：红灯红色、绿灯绿色、黄灯黄色。当前上游 iOS 导航接口没有提供真实灯态倒计时来源，本移植不生成虚假倒计时。GTA5 的圆屏图标和黄色路线由配套 AA 固件绘制，iOS App 传送地图与导航数据。

## 电脑测试与云端编译

Windows 可运行 `python scripts/validate-ios-project.py` 检查工程登记和配置。Swift 及 Xcode 在 GitHub Actions 的标准 macOS runner 上执行：进入 Actions → Build iOS aa unsigned IPA → Run workflow。流程执行全部 Swift 回归测试，按 Podfile.lock 安装 CocoaPods 依赖，编译 App 与分享扩展，并上传未签名 IPA、SHA256 及日志，不创建 Release。

macOS 本机可执行：

```bash
bash scripts/test-ios.sh
gem install cocoapods -v 1.16.2 --no-document
(cd ios && pod _1.16.2_ install --deployment)
bash scripts/build-ios-ipa.sh
```

IPA 需要之后在本机签名。实机阶段优先使用 [iLoader 官方项目](https://github.com/nab138/iloader)；Apple 账号、证书、配对文件不放入仓库。高德 Key 在 App 内填写，必须是绑定最终签名 Bundle ID 的 iOS Key。Android 的 SHA1 Key 不能直接用于 iOS。

先保持 App 前台完成沿线路网准备，再测试锁屏后的缓存地图传输。iOS 后台图形捕获受系统限制，本版不承诺后台无限截图或真机 30 FPS。
