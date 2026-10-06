# DSH Remote
**简体中文** | [English](README.en.md)

用手机远程驱动桌面上的 DeepSeek Harness：列会话、看实时流、发消息、处理审批与提问。

## 它是什么

DSH Remote 是这条链路的手机端：Flutter 客户端，只与**你自己部署的中继**通信（HTTPS + WSS），
不直连桌面，所以家用 NAT、没有公网 IP 也能用。它需要另外两个组件配套运行：
[中继后端](https://github.com/AKHYui/DSH-Remote-backend) 与
[桌面插件](https://github.com/AKHYui/DSH-Remote-plugin)；三者之间的线协议由后端仓库的
[`docs/PROTOCOL.md`](https://github.com/AKHYui/DSH-Remote-backend/blob/main/docs/PROTOCOL.md) 定义。

当前版本 **0.2.8**（`pubspec.yaml`：`version: 0.2.8+13`）。启动器显示名为 `DSH Remote`，
applicationId 是 `com.dshremote.dsh_remote_app`——升级时保持该 id，覆盖安装不会丢失配对与设置。

## 架构

```
 ┌────────────┐   HTTPS / WSS    ┌───────────────┐   outbound WSS   ┌────────────────┐
 │ DSH Remote │ ───────────────▶ │     relay     │ ◀─────────────── │ desktop plugin │
 │  (Android) │                  │ FastAPI+SQLite│                  │   (in DSH)     │
 └────────────┘                  └───────────────┘                  └────────────────┘
```

手机只与中继通信；桌面插件主动拨号到中继，因此桌面不开放任何入站端口。
全部传输都是 TLS，证书由你的内部 CA 签发，该 CA 的**公开证书**打包在 `assets/ca.crt`。

## 环境要求

| 组件 | 版本 | 说明 |
|---|---|---|
| Flutter SDK | 3.47.6（Dart 3.13.5） | `flutter doctor` 应无错误；`pubspec.yaml` 要求 Dart `>=3.4.0 <4.0.0` |
| JDK | 17 | Gradle 与 Kotlin 均以 JVM 17 为目标（`sourceCompatibility` / `jvmTarget`） |
| Android SDK | platform 36、build-tools 36.0.0 | `compileSdk` / `targetSdk` 取 Flutter 默认值；构建出的 APK 为 API 24–36 |
| 手机或模拟器 | Android 7.0（API 24）及以上 | 真机需与 APK 的 ABI 匹配；x86_64 模拟器须用专用构建（见下） |
| Android platform-tools | 任意 | 提供 `adb` 与 `apkanalyzer` |
| Python + Pillow | Python 3.9+ | **仅**在重做图标时需要，日常构建不需要 |

## 构建与安装

### 1. 获取代码与依赖

```bash
git clone https://github.com/AKHYui/DSH-Remote-app.git
cd DSH-Remote-app
flutter pub get
```

### 2. 静态检查与测试

```bash
flutter analyze     # 期望输出：No issues found!
flutter test        # 246 个用例，不需要设备，也不访问网络
```

### 3. 构建 release APK

```bash
# 全量包（arm64-v8a / armeabi-v7a / x86_64）：用于真机
flutter build apk --release

# x86_64 专用包：用于 x86_64 模拟器（MuMu 等）
flutter build apk --release --target-platform android-x64
```

产物均为 `build/app/outputs/flutter-apk/app-release.apk`。

选择哪种包的判据是模拟器的**主 ABI**：

```bash
adb shell getprop ro.product.cpu.abi     # 例如 x86_64 或 arm64-v8a
```

若模拟器主 ABI 是 x86_64（部分模拟器即使宿主是 ARM 也如此），装全量包会走 ARM 翻译层，
可能启动后黑屏，日志出现 `Width is zero. 0,0`：此时必须使用 `--target-platform android-x64` 的构建。

### 4. 安装到手机

```bash
adb devices
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

没有 `adb` 时，把 APK 复制到手机后侧载即可。applicationId 未变，属覆盖安装，配对与设置都会保留。

### 5. 交付前自检

```bash
# 任意平台（Android SDK cmdline-tools 提供 apkanalyzer）
apkanalyzer manifest permissions build/app/outputs/flutter-apk/app-release.apk
apkanalyzer files list         build/app/outputs/flutter-apk/app-release.apk | grep '^/lib/'
```

```powershell
# Windows：同一套检查的脚本版（INTERNET 权限 + 实际 ABI 组合）
powershell -ExecutionPolicy Bypass -File tool/verify_apk.ps1 -Apk build/app/outputs/flutter-apk/app-release.apk
```

两项必查：清单中存在 `android.permission.INTERNET`，且 `lib/` 下包含目标设备的 ABI。

### 6. 签名

仓库中的 release 构建使用 **debug 签名**（`android/app/build.gradle.kts` 内
`signingConfig = getByName("debug")`），侧载自用足够。若要上架应用商店，请自备 keystore、
写入 `android/key.properties`，并把 `buildTypes.release` 指向你自己的 signingConfig。
`key.properties`、`*.jks`、`*.keystore` 已在 `.gitignore` 中，不会被提交。

### 7. 图标（可选）

```bash
python tool/make_icons.py     # 需要 Pillow
```

源图是 `tool/icon/app_icon.png`。脚本一次生成两套资源：`mipmap-{mdpi..xxxhdpi}/ic_launcher.png`
（旧式图标）与 `mipmap-*/ic_launcher_foreground.png` + `mipmap-anydpi-v26/ic_launcher.xml`
（API 26+ 自适应图标，背景色写在 `values/colors.xml`）。

## 首次配置

1. 在后端仓库签发手机令牌：

   ```bash
   python -m app.cli issue-device --name "my phone"     # 直接签发
   # 或者走配对：pair-start → 在服务器上 pair-approve <code> → 在 App 设置页认领配对码
   ```

2. 打开 App → **设置**，填写**中继地址**（例如 `https://relay.example.com:58443`）与**手机令牌**。
   地址也可只写 `host:port`，应用会规范化为 `https://host[:port]`。

3. 若中继使用自建内部 CA：**不需要**把 CA 装进系统信任库，它已随 APK 打包（`assets/ca.crt`），
   运行时读入 `SecurityContext`，公网 HTTPS 仍照常可用。设置页会显示该 CA 的 SHA-256 指纹，
   可与服务器上的 `certs/ca.crt` 核对。

令牌保存在系统 Keystore / Keychain（`flutter_secure_storage`），不写入 SharedPreferences，
也不进入仓库。

## 功能与限额

| 功能 | 说明 |
|---|---|
| 会话列表 | 按工作区分组列出会话；自动过滤子代理会话，以及从未发过消息的空任务 |
| 历史记录 | 会话快照按**字节**封顶（一个长回合就能占满整个窗口），所以往上滑会按 `session.page` 自动取更早的一页；列表顶部会显示「往上滑看更早的消息」/「正在加载更早的消息…」/「已经到开头了」 |
| 实时流 | 打开会话即订阅 `session.follow`：先取快照再收实时事件；断线自动重订阅，回到前台亦重订阅；**半开（静默死掉）的连接也能被发现并重开**，见「运维与排错」 |
| 发消息 | 文本发出即上屏（本地回声，收到持久事件后对账）；可中止当前回合 |
| 附件 | 图片内嵌在 `session.prompt`（image 块）；其它文件先上传换取 `receiptId`，再随消息发送 |
| 模型 | 会话内切换 provider / model，选项来自 `model.catalog` |
| 审批与提问 | 手机与电脑同时弹出，先作答的一方生效；手机作答后桌面上的窗口会自行消失 |
| 产物 | 展示 `present` 声明的交付文件（路径与说明），不下载、不显示文件内容 |
| 用量状态栏 | 会话底部显示与桌面同源的数字：`N 轮 M 步 · K tok/s · 累计 token · 缓存命中 · 已用上下文`；点一下展开明细（模式、权限、未缓存输入、缓存读/写、输出、上下文占用）。数据取自 DSH 的会话投影，公式与桌面一致 |
| 新建时选模式 | 新建任务时可选 DSH 的四种模式：**标准 / PTC / 极简 / 创造**（agent preset）。模式在会话启动后即锁定，所以只有创建时能选；上次选择会被记住并预选，任务明细里也显示当前模式 |
| 归档 | **长按**任务可「归档」（从列表里收起来，之后在抽屉底部的「已归档 N」里找回），对已归档的任务则是「取消归档」。任务还在跑时后端会**先拒绝**而不是直接杀掉，App 据此问你是否停掉它再归档 |

| 限额 | 值 |
|---|---|
| 单个附件 | **2 MiB**（原始字节；中继请求体上限为 4 MiB，base64 会放大 4/3） |
| 图片 | 原生侧压到长边 **2000 px**、质量 85；支持 PNG / JPEG / WebP / GIF |
| HEIC / HEIF | **不支持**：选中时即被拒绝，请先转换为 JPEG 或 PNG |
| 其它文件 | 类型不限，单个不超过 2 MiB |

## 运维与排错

| 现象 | 处理 |
|---|---|
| 电脑上已经答完，手机上仍转圈 / 不刷新 | 会话流是长连接，**断了不一定报错**：半开的 HTTP 响应既不报错也不结束。App 会自己发现并重开会话流——事件通道说这个会话有新动静、或本机发出的消息迟迟没被确认时，就重取一次权威快照；`adb logcat` 里会有一行 `[dsh-remote] re-opening the follow stream: …`。若 30 秒内仍未刷新，检查中继与桌面插件是否在线（设置页有事件通道状态） |
| 需要查看日志 | `adb logcat`（Flutter 输出在 `flutter` 标签下）；设置页会显示事件通道状态与最近一次错误 |
| release 包无法联网 | 主 manifest 缺少 `android.permission.INTERNET`。debug / profile 的 manifest 自带该权限，release 不带；用 `apkanalyzer manifest permissions` 核对 |
| 电脑上刚归档的会话仍出现在列表 | 打开抽屉会重新拉取列表；若仍然出现，确认桌面插件已重启（插件源码改动需重启 DSH 才生效） |
| 模拟器启动后黑屏，日志 `Width is zero. 0,0` | 该模拟器主 ABI 为 x86_64 而装入的是全量包；改用 `--target-platform android-x64` 重新构建 |
| 「提交回答」按钮一直为灰 | 答案不完整：有选项的提问需先选中，无选项的需填写文字；「交回电脑处理」始终可用 |
| 首次克隆后 Gradle 下载失败 | `android/gradle/wrapper/gradle-wrapper.properties` 指向腾讯镜像；换网络后可自行改回 `services.gradle.org` |
| 重复构建插件变慢 | `android/gradle.properties` 中的 `kotlin.incremental=false` 是有意设置（Kotlin 增量缓存会构建失败），代价是插件重复构建变慢 |

## 测试

```bash
flutter test                                    # 246 个用例：不需要设备，也不访问网络

# 对活中继的 9 项集成检查（需要真实中继与设备令牌）
export DSH_LIVE_RELAY='https://relay.example.com:58443'
export DSH_LIVE_TOKEN='<device-token>'
export DSH_LIVE_CA='assets/ca.crt'              # 可选，默认值即为此
flutter test test/live_relay_test.dart
```

Windows PowerShell 使用 `$env:DSH_LIVE_RELAY='…'` 的写法。未设置 `DSH_LIVE_RELAY` 与
`DSH_LIVE_TOKEN` 时，这组检查整体跳过。

## 仓库结构

```
lib/api/     中继 HTTP + SSE/WebSocket 客户端、数据模型、TLS 信任与 CA 指纹
lib/chat/    事件流 → 会话记录、Markdown 子集、附件契约（纯 Dart，重点测试对象）
lib/state/   设置（令牌进 Keystore）与应用状态
lib/ui/      配对、设备与任务列表、会话界面、设置页、附件选择
test/        246 个单测 / widget 用例，以及对活中继的 9 项检查
tool/        verify_apk.ps1（交付前自检）、make_icons.py 与 icon/（图标源图）
android/     Android 工程：applicationId、清单、启动器图标资源
assets/      ca.crt（中继的公开 CA 证书）
```

## 相关仓库

- 桌面插件：https://github.com/AKHYui/DSH-Remote-plugin
- 中继后端（线协议的权威定义）：https://github.com/AKHYui/DSH-Remote-backend
- 手机 App（本仓库）：https://github.com/AKHYui/DSH-Remote-app

## 许可

MIT，详见 [LICENSE](LICENSE)。
