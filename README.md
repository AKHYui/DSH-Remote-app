# app — Flutter 客户端（手机端的 DSH 遥控器）

> 三个仓库之一：[桌面插件](https://github.com/AKHYui/DSH-Remote-plugin) · [中继后端](https://github.com/AKHYui/DSH-Remote-backend) · **手机 App（本仓库）**

用手机远程驱动桌面上的 **DeepSeek Harness**：列会话、看实时流、发消息（**含图片与文件**）、
切模型、中止回合，并在电脑请求审批 / 提问时于手机上作答。

```
手机 App ──HTTPS/WSS──▶ 自建中继 ◀──出站 WSS── 桌面插件(DSH)
```

App 只跟中继说话，永远不直连桌面（所以家用 NAT 也能用）。完整的线协议与 HTTP 接口由**中继仓库**的
`docs/PROTOCOL.md` 定义；本仓库只用其中的：

| 用途 | 接口 |
|---|---|
| 列设备 / 列会话 / 读历史 | `GET /api/v1/devices`、`/devices/{id}/sessions`、op `session.list` / `session.page` |
| 实时流 | `POST /devices/{id}/stream`（SSE，op `session.follow`） |
| 发消息 / 中止 / 切模型 | op `session.prompt` / `session.cancel` / `session.selectModel` / `model.catalog` |
| 附件 | op `fileUploads.upload`（换 `receiptId`）；图片则内嵌进 `session.prompt` |
| 审批与提问 | `GET /api/v1/approvals` + `POST /api/v1/approvals/{askId}`；推送走 `WS /api/v1/events`（`approval.ask` / `question.ask` / `approval.settled` / `session.event` / `session.status` / `session.activity` / `device.status`） |

---

## 安装与运行

### 前置条件

| 组件 | 本项目验证过的版本 |
|---|---|
| Flutter SDK | 3.47.6（Dart 3.13.5） |
| JDK | Temurin 17 |
| Android SDK | platform 36 / build-tools 36.0.0 |

依赖（`pubspec.yaml`）：`http`、`flutter_riverpod`、`flutter_secure_storage`、`crypto`、`intl`、
`image_picker`（相册/拍照，原生侧压缩）、`file_picker`（任意文件，走 SAF，不需要权限）。

### 常用命令

```powershell
flutter pub get
flutter analyze                 # 必须 No issues found
flutter test                    # 233 个用例（不需要设备）

# 真机：全量包（arm64-v8a / armeabi-v7a / x86_64）
flutter build apk --release     # -> build/app/outputs/flutter-apk/app-release.apk

# MuMu 等模拟器：必须出 x86_64 专用包（原因见排错表）
flutter build apk --release --target-platform android-x64
```

装到手机：把 `app-release.apk` 拷过去侧载，或 `adb install -r <apk>`。首次打开进「设置」填中继地址与
手机令牌（见下一节）。

### 应用名、图标、版本

| 项 | 值 | 说明 |
|---|---|---|
| 启动器里的名字 | **DSH Remote** | `AndroidManifest.xml` 的 `android:label`（应用内标题本来就是这个） |
| applicationId | `com.dshremote.dsh_remote_app` | **故意没换**：换掉它就是装出一个**新应用**，而不是覆盖升级，而且配对令牌存在旧应用的私有存储里 |
| 图标 | `tool/icon/app_icon.png` 生成 | 见下 |
| 版本 | `0.2.0+5`（versionName `0.2.0`） | `pubspec.yaml` 的 `version:`，`+` 后面是 versionCode |

图标由一段脚本从**一张源图**生成，不手工改 PNG：

```powershell
python tool\make_icons.py     # 需要带 Pillow 的 Python（DSH 运行时自带）
```

它同时产出两半（缺一不可，理由见脚本内注释）：

- **legacy PNG**：`mipmap-{mdpi..xxxhdpi}/ic_launcher.png`（48…192px），给不认识自适应图标的启动器；
- **自适应图标**（API 26+）：每档密度的透明 `ic_launcher_foreground.png`（108dp 画布里的 70dp，稳在任何
  mask 形状内都不会切到角色）＋ `mipmap-anydpi-v26/ic_launcher.xml`，背景色从源图四角采样
  （`#FEFEFE`），于是前景那个白方块和背景**融为一体**，不会看到一圈边。

### 交付前必须检查产物

```powershell
# 本机执行策略默认禁止运行 .ps1，所以显式 bypass
powershell -ExecutionPolicy Bypass -File tool/verify_apk.ps1 -Apk build/app/outputs/flutter-apk/app-release.apk
```

它检查两件测试**看不见**的事：`android.permission.INTERNET` 在不在（Flutter 模板只在 debug/profile 的
manifest 里声明它，release 包会**完全没有网络权限**——历史上真的发过这样一个包），以及包里实际有哪些
ABI（"universal" 包偷偷只剩 x86_64 也发生过）。**交付的产物必须真的装到设备上跑过**，不是跑过测试就算。

---

## 配置与配对

| 项 | 说明 |
|---|---|
| 中继地址 | 如 `https://relay.example.com:58443`（自建、内部 CA 签发） |
| 手机令牌 | 由中继侧签发（一设备一令牌，可单独撤销）。存在 Keystore/Keychain（`flutter_secure_storage`），不进 `SharedPreferences` |
| CA | 打包进 APK 的 `assets/ca.crt`，运行时读进 `SecurityContext(withTrustedRoots: true)` |

**为什么自带 CA 而不是装进系统信任库**：Android 7+ 默认**不信任用户安装的 CA**，把 CA 塞进系统库里
在真机上会「连不上但对浏览器正常」，而且用户很难自查。把证书作为 asset 打包，HTTP 与 WebSocket 共用一个
client，Android / iOS / 桌面行为一致。`withTrustedRoots: true` 让公网 HTTPS 也照常可用。设置页会显示该
CA 的 **SHA-256 指纹**，便于核对它与你服务器上那份是否一致。

---

## 功能与边界

### 附件

发送区左侧的回形针 →「拍照 / 从相册选择 / 选择文件」。选中的东西以缩略图或文件名胶囊排在输入框上方，
每个都能单独删；有附件时即使一句话没写也能发。

| 类型 | 走哪条路 |
|---|---|
| 图片（PNG / JPEG / WebP / GIF） | 直接内嵌进 `session.prompt`：`{type:'image', mediaType, data:<base64>, name?}` |
| 其它文件 | 先 `fileUploads.upload` 换 `receiptId`，再发 `{type:'file', receiptId}` |

- 图片在**原生侧**就被压到长边 2000 px、质量 85（`image_picker` 的 `maxWidth/maxHeight/imageQuality`），
  所以不需要 Dart 图像库。
- 单个附件上限 **2 MiB**（原始字节；中继请求体 4 MiB，base64 放大 4/3）。
- 空文件、识别不出的图片格式、HEIC 都会在**选中时**被拒绝并说明原因。**绝不猜成 `image/png`**：
  猜错会让桌面端拒掉整条消息，把用户写的字一起弄丢。
- 上传失败时**不发**任何 prompt，草稿原样留着。

### Markdown

自己写的子集，不引第三方渲染库。原则：**认得的就渲染，不认得的原样输出**——悄悄改坏内容比不渲染更糟。

| 类别 | 支持 |
|---|---|
| 块 | `#`~`######` 标题、段落、围栏代码块（带语言标注）、引用 `>`、分隔线 `---`/`***`/`___` |
| 列表 | 无序（保留缩进）、**有序（保留 `1.` 编号）**、任务列表 `- [ ]` / `- [x]` |
| 表格 | **GFM 管道表**：表头 + 对齐行，有无外侧管道都认，行列不齐自动补齐/截断，`\|` 转义，代码块里的管道不作分隔符；单元格内的粗体/行内代码照常解析；**过宽时横向滚动**而不压扁列 |
| 行内 | `**粗体**`、`*斜体*`（按 CommonMark 左右侧翼规则，`2 * 3 * 4` 不会被吃）、`` `代码` ``、`~~删除线~~`、`[链接](url)` 显示为「标签 + 原文 URL」（没有 URL 打开器，做成看起来能点其实点不动更糟） |

### 对话流：谁说的话，一眼能分出来

手机端的对话流里其实混着**三种**「消息」，而它们在中继和宿主眼里都是同一个 `user/message` 事件：

| 看到的东西 | 事件的 `source.kind` | 渲染成 |
|---|---|---|
| 你自己发的（手机 / 电脑） | `user`（带 `rpcId`）、`user-question-reply` | **灰色气泡 + 左侧绿色竖线** |
| 子代理 / 别的 agent 发来的 | `agent-message`、`subagent-settled` | 白色卡片，**折成一行**，点开才看全文 |
| 宿主自己注入的上下文 | `model-selection`、`runtime-context`、`skill-catalog`、`compact-checkpoint` … | 同上 |

判据来自**宿主自己的权威定义**（`MessageSourceMap`，`dsh-api-session-controller`）：除了 `user` /
`user-question-reply` 之外全是机器写的。空 `kind` 当作人来处理——**把用户自己写的话藏起来，比漏折一条通知糟得多**。

另外三条与「刚发的消息看不见」直接相关，都是踩过坑的：

1. **发出去就立刻上屏**（`PendingUserBubble`）。发送成功那一刻本地先落一条，标着「已发出，等电脑确认…」；
   真正的 `user/message` 到达时再替换掉。之前完全依赖实时流，流一旦僵住，就只能重启 App 才看得到自己那句话。
   对账用 `requestId` —— 宿主把它记在 `source.rpcId` 里（已对活中继核对），所以**同一个 rpcId 才算同一条**，
   两句话字面一样也不会互相吞掉；没有 `rpcId` 时才退回按文本 FIFO 匹配。
2. **快照不吞未确认的回声**。`session.follow` 每次重订阅都会用快照重建整个时间轴；如果重建时把本地回声
   一起清掉，重连恰好落在「已接受」和「已入日志」之间就会让消息消失。现在快照重建后会保留快照里还没有的
   回声。
3. **发送成功后重订阅事件流，回到前台时也重订阅**。Android 会在后台掐掉 socket，而半死的 TCP 连接不一定
   报错——页面就一直停在旧内容上，唯一的恢复手段曾经是重启 App。`session.follow` 每次都以权威快照开头，
   重订阅是最便宜的确定性恢复。

### 产物：从远处看不到文件系统，所以把它列出来

远程驱动桌面时，唯一看不见的就是**文件系统**。`present` 是 agent 说「这些就是我做出来的东西」的方式，它落的
持久事件是 `deliverables/presented`（`{turn, callId, files:[{path, description?}]}`），于是手机能把
**有哪些产物、各自是干什么用的**列成一张卡片 —— 只列路径与说明，**不显示任何文件内容**（手机也打不开它，
做得像能点其实点不动更糟）。默认显示 4 行，更多折起来，点标题展开。

### 输入区：模型按钮和发送键同一排，名字还得看得全

**根因不是内边距**：胶囊和「回形针 / 发送」同排，而那一排里它旁边站着一个 `Spacer` —— 两个可伸缩子项会把
剩余宽度**对半分**，所以胶囊最多只用得到一半，真机 360dp 上模型名被从中间截断，平板（宽度够）看着正常。

改法三条，缺一不可：

1. **`spaceBetween` + 把按钮合成一个子项**，去掉那个 `Spacer`，胶囊因此可以用满按钮剩下的宽度（仍然和它们
   **同一排**——单独占一行虽然更宽，但整块输入区的比例会变，用户直接说「畸形」）。
2. **去掉胶囊前面的装饰图标**（约 21dp）。`DeepSeek V4 Flash Vision (exp)` 在真实字体下要 190.7dp，这一排
   一共只给得出那么多；胶囊底色 + 下拉箭头已经足够表达「这是可点的选择器」。
3. **标签套 `FittedBox(scaleDown)`**：万一以后出现更长的名字，它**轻微缩小**而不是被切成
   `DeepSeek V4 Flash Visi…`——模型名的省略号什么信息都没有，95% 的字号有。

`test/composer_layout_test.dart` 用**实测几何**钉住这三条：胶囊与按钮的垂直中心对齐（同一排）、胶囊一直延伸到
按钮左侧、并加载**真实字体**逐条测量 `model.catalog` 里最长的名字，断言缩放比例 **> 0.95**（当前实测全是
`1.000`，即完全不缩）。改之前那条最长名字只能拿到半排，约 0.91。

### 抽屉：只留能用的东西

抽屉右上角曾经常驻一个「● 实时」徽章。一个永远亮着的点只是装饰，**已经去掉**；连接状态本身没丢——它仍然
在设置页上，而且是一句话（`已连接（审批与状态实时推送）` / `断开，正在退避重连`），能说明「为什么没连上」。

**打开抽屉就会重新拉一次任务列表**（以前只在连上、以及某些动作之后才拉）。归档、新建都发生在电脑上，而
「列表是旧的」和「列表是对的」在界面上长得一模一样——用户报的「已归档的会话还显示在 App 上」就是这么来的。
回到前台时同样会重拉一次。

### 任务列表里不显示空任务

`blank` 是宿主自己的「这里从来没有被接受过 prompt」标记（`sessionInfo.blankBit` 初值为真，第一条 prompt 被
接受时清除）。手机上一个空任务是**一页白纸配一个没意义的 id**，而且几乎总是残留——每个验收脚本开的探针会话
都长这样。所以 `visibleSessions()` 一次剔掉两类行：**子代理会话**（点进去每个 op 都被拒）与**空任务**。
真正的对话在第一条消息被接受的那一刻自己就回来了。

### 审批与提问

- 电脑与手机**同时弹**，**谁先提交按谁的**；手机超时/断链/报错时一律回落到桌面原生应答器。
- **活着的提问必须走 `askId`**（`approval` 帧）。`userQuestions.answer` 只接受投影里已经 `continued`
  的提问，对活着的提问必然返回 `false`，所以对话流里的卡片会先找同一批问题的活提问、找到就走 `askId`，
  找不到才回落到 op。
- 答题卡片在答案**不完整**时禁用提交（有选项必须选一个、没选项必须填字），「交回电脑处理」永远可用。
- 会话列表**过滤掉子代理会话**：它们由父会话持有，harness 对它们一律回 `session/agent-busy`，
  列出来只会让人点进一个打不开的会话。
- 会话列表**也过滤掉空任务**（`blank`），理由见上一节。

---

## 调试

### 单元与 widget 测试

```powershell
flutter test                                  # 233 个用例（不需要设备、不碰网络）
flutter test test/markdown_test.dart          # 单个文件
```

覆盖：中继客户端的解析与错误映射、会话记录折叠（`lib/chat/transcript.dart`，含「哪些 `user/message` 是
人写的」「本地回声与持久事件的对账」两组）、Markdown 解析与渲染、附件契约（媒体类型嗅探、2 MiB 边界、
内容块形状）、审批卡片、提问路由、异常→人话的映射，以及**对话流外观**（`test/chat_surface_test.dart`：
绿线、折叠通知、发出即上屏，外加一张 golden）。

### 对活中继的集成检查

```powershell
$env:DSH_LIVE_RELAY = 'https://relay.example.com:58443'
$env:DSH_LIVE_TOKEN = '<手机令牌>'
# $env:DSH_LIVE_CA  = 'assets\ca.crt'   # 可选，默认就是这个（仓库内自带）
flutter test test/live_relay_test.dart
```

不设 `DSH_LIVE_RELAY` / `DSH_LIVE_TOKEN` 时整组跳过。**9 项检查**：健康检查、坏令牌被拒、设备列表解析、
客户端重建后仍可用（`IOClient` 所有权那个 bug 的回归）、事件通道订阅确认、模型目录可读可切、
ops 白名单与 SSE 流、**自己发的 prompt 从活流里回来（并核对 `source.rpcId`）**、以及**真实上传 64 KiB
拿回 `receiptId`**。它比单测更值钱：`session.list` 的 `_request` 参数名、`SocketException` 的真实形态这类
问题只有对着真中继才会出现。

### 在设备上调试

```powershell
flutter run -d <device>              # 日志直接打在终端
adb -s <serial> logcat               # 过滤 Flutter
adb -s <serial> shell screencap -p /sdcard/x.png ; adb -s <serial> pull /sdcard/x.png .
```

**截图是最重要的一种调试**：本项目有两处缺陷（时间轴卡片看不出边界、未选中的选项看起来像纯文本）
代码和测试都报不出来，**只有看图**才发现。改完界面顺手截一张。

异常到人话的映射集中在 `lib/ui/error_text.dart`，加新的错误码时请连同用例一起加。

---

## 排错

| 现象 | 原因与处理 |
|---|---|
| 配对成功后立刻 `Bad state: Client is closed` | `IOClient.close()` 会**连带关闭**传给它的 `HttpClient`；曾经把同一个实例共享给新旧两个客户端，重建时顺手把新的也弄死了。现在每个属主各有一个 `HttpClient`，只共享 `SecurityContext` |
| 事件通道永远停在「重连中」 | WebSocket 地址沿用了 `https://`，而 `WebSocket.connect` 要 `ws`/`wss`；失败被静默吞掉，看上去和「正在重试」一样。现在会记录并展示 `lastError` |
| `Connection closed before full header was received` | uvicorn 默认 5 秒关空闲连接，Dart `HttpClient` 默认保留 15 秒，于是复用了服务端已关闭的连接。两端都要对齐：客户端 `idleTimeout` 收到 3 秒（先关），服务端 `--timeout-keep-alive 75`，并对幂等 GET 重试一次（POST 绝不重试） |
| 所有会话都显示「刚刚」 | `session.list` 的 `updatedAt` 是**毫秒**，而中继自己的 `connectedAt`/`lastSeen` 是**秒**。同名概念在不同接口下单位可能不同，现在按数量级判别并容忍两种 |
| 打开会话看到的是**最早**的内容 | `ListView` 偏移 0 是列表顶部，而自动跟随只在「已在底部附近」时生效。改用 `reverse: true`：偏移 0 就是底部，打开即落在最新处，新内容自动出现，正在向上翻阅的人也不会被打断 |
| release 包报「网络不可达」，debug 包一切正常 | `INTERNET` 权限只在 debug/profile 的 manifest 里。见上文 `tool/verify_apk.ps1` |
| release 构建失败：`Dependency ':flutter_plugin_android_lifecycle' requires … compile against version 36` | 插件各自声明 `compileSdk`，`file_picker` 还写死 android-34。已在 `android/build.gradle.kts` 里对所有 Android 子项目抬到 36（注意 `evaluationDependsOn(":app")` 之后项目可能已 evaluate，`afterEvaluate` 会抛异常，所以用了 `state.executed` 分支） |
| `image_picker_android:compileReleaseKotlin` 报 `Could not close incremental caches` / `Storage … is already registered` | Kotlin 守护进程重复注册增量缓存；`flutter clean`、删 build 目录、杀守护进程都无效。已在 `android/gradle.properties` 设 `kotlin.incremental=false` |
| MuMu 上屏幕全黑，日志 `Width is zero. 0,0` | 全量包让 MuMu 把 ABI 选成 `arm64-v8a` 走 Houdini 翻译，Flutter 拿到零尺寸渲染表面。用 `--target-platform android-x64` 出 x86_64 专用包 |
| MuMu 上「提交回答」几个字挤在一起 | 模拟器缺某个字重的中文字形而回退；**真机上显示正常**（同一版 APK）。不需要改代码 |
| 提交按钮一直禁用 | 答案不完整（有选项没选、或没选项没填字）。提示就写在按钮下方 |
| 手机上发的消息**要重启 App 才看得到** | 发送路径完全依赖实时流把 `user/message` 推回来；后台被掐掉的 socket 不一定报错，页面就一直停在旧内容上。现在发出即上屏（本地回声，`rpcId` 精确对账）、发送成功后重订阅、回到前台也重订阅 |
| 看不出哪条是**自己发的** | 宿主注入的上下文也是 `user/message`，以前和用户消息渲染成一模一样的灰气泡。现在用户消息是**灰气泡 + 左侧 4px 绿线**，注入内容是**白卡 + 灰线、折成一行** |
| 满屏 `Agent <uuid> sent a message: …` | 那是子代理发给本会话的 `agent-message`（`source.kind` 判定，见上文「对话流」）。现在折成一行，点开才看全文 |
| `Cannot use "ref" after the widget was disposed` | `_subscribe()` 在 `await _subscription?.cancel()` 之后没有重新检查 `mounted`：发完消息立刻离开会话页就会踩到。已在 await 之后补上 `mounted` 与代次检查 |

---

## 测试与约定

233 个用例分三类：**纯 Dart 逻辑**（会话折叠、Markdown、附件契约、路由匹配——不需要设备，也最值得写）、
**widget**（卡片、输入区、表格布局与窄屏不溢出、对话流外观）、**对活中继的集成**（上面那 9 项）。

两条硬规矩，都是踩过坑换来的：

1. **交付的产物必须真的运行过。** release 包没有 `INTERNET` 权限那次，所有测试全绿、开发期间一直跑的是
   debug 包，直到装到设备上才暴露。
2. **任何会抛异常的动作都要保证状态被清掉。** 「点了没反应」曾经的真因是 `_busy` 停在 `true`：
   异常在 `try` 之外抛出，按钮永久禁用。现在所有动作走同一个包裹，异常必然重置按钮并给出人话提示。

## 许可

MIT。
