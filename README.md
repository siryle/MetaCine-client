# MetaCine for iPhone

MetaCine 的原生 iPhone 客户端，使用 SwiftUI，最低支持 iOS 17。无需第三方运行时依赖、Apple 开发者账号或签名证书即可通过 GitHub Actions 构建未签名 IPA。

客户端直接调用现有 MetaCine HTTP API，不需要修改服务端，覆盖 `/api/resources/*`、`/api/re0/*`、`/api/hdhaven/*`、`/api/jobs/*`、`/api/auth/*`、`/api/session` 和 `/api/settings`。

## 已实现功能

| 页面 | 功能 |
| --- | --- |
| 发现 | 与后台一致的热门 / 流媒体 / 猫眼 / 豆瓣 / 腾讯视频榜单推荐、平台 / 分类 / 流媒体地区筛选、分榜单横向海报、缓存及部分失败提示、数字评分、资源徽标、一键订阅及已订阅状态、作品详情 |
| 搜索 | 仅提供 TMDB 片名搜索，统一查找电影和电视剧、分页加载、作品详情及订阅；详情内支持 RE0 / HDHaven / Telegram 资源搜索、来源筛选、原文、复制 / 分享、一键订阅、按来源获取链接、转存 / 离线下载 |
| 订阅 | 新增 / 编辑 / 删除、暂停 / 恢复、RE0 / HDHaven / Telegram / 全部来源、读取对应账号默认积分上限及按上限自动解锁、状态筛选、立即检查、版本和季数偏好、关联任务、前台定时刷新 |
| 历史 | 任务状态筛选、名称和消息搜索、进度、逐文件详情、异常提示、停止运行任务、删除结束后的任务记录 |
| 服务器 | 多服务器增删改切换、连接测试、账号密码 / 令牌登录、钥匙串凭据、连接状态和版本、服务端 TMDB / 代理 / 语言 / 图片 / 超时配置 |

界面支持浅色和深色，海报通过服务器代理请求，携带各自服务器的登录会话。不同连接使用独立的内存 Cookie、网络会话和内存图片缓存；磁盘海报缓存按服务器配置、地址和账号凭据摘要隔离，相同配置重新连接后可复用。切换服务器会取消旧请求并重置页面。账号密码和令牌仅写入设备钥匙串，服务器地址及显示名称保存在本机 UserDefaults。

发现页通过 `/api/resources/recommendations` 加载榜单；Netflix、HBO、Apple TV+、Disney+、Crunchyroll、Amazon Prime、Amazon 和 Hulu 使用 `/api/resources/rankings?source=re0`，需要后台配置 RE0。默认「热门」展示 IMDb 最热门电影、IMDb 最热门剧集、TMDB 趋势、AniList 热门和 Bangumi 今日动漫。每个平台支持全部榜单或指定分类，最多并行加载四个榜单，单个失败不影响其他榜单。下拉刷新会向后台传递 `refresh=1`。

海报直接使用榜单返回的 `image_url` / `poster`，分别走 catalog、豆瓣或 TMDB 图片代理；完整 TMDB 图片地址会规范化为代理路径，猫眼官方美团 / pipi 图片地址会统一 HTTPS、去除尺寸占位及裁剪参数。榜单按可见区域延迟加载图片，同一海报合并并发请求，优先读取内存和磁盘缓存，命中磁盘时不发图片网络请求；重启 App 或重新连接后可继续复用。磁盘缓存最多 200 MiB、保留 30 天，超限清理最早写入的条目，过期或损坏后重新下载，系统也可能清理缓存。TMDB 使用 `w342` 缩略图，后台解码并限制图片尺寸。原图缺失或加载失败时，通过后端已知 TMDB 详情或唯一作品匹配补全封面，并持久化成功补全的海报地址，避免反复查询；匹配不唯一时保留占位和重试，不套用其他作品海报。

搜索页只保留 TMDB 片库的片名搜索输入框和搜索结果，不展示默认热门作品，也不提供类型、分类、地区、年份或排序筛选。提交片名后通过 `/api/resources/explore?source=tmdb&q=...` 分别查询电影和电视剧并合并展示，支持继续加载和下拉刷新搜索结果。清空片名会清除结果并停止旧请求，不请求片库推荐。

豆瓣、AniList、Bangumi、IMDb、猫眼和腾讯的原生 ID 与 TMDB ID 分开处理；第三方海报通过后台对应代理加载。作品详情使用 `/api/resources/catalog/resolve` 匹配唯一 TMDB 条目，未匹配时保留榜单资料；新订阅会继承可靠的作品身份、年份和封面。修改名称或类型会清除原作品身份，防止订阅到错误作品。

在发现或片库作品详情点击「搜索资源」，会带入片名及作品身份，独立并发查询 RE0、HDHaven 和 Telegram；各来源分别显示加载、错误及结果，支持查看全部来源或按来源筛选。RE0 / HDHaven 请求带入已知 TMDB ID；未匹配 TMDB 的原生榜单仍会请求服务端按片名匹配，修改片名后不沿用旧身份。结果过滤不匹配的类型、ID、电影年份及季数。资源结果先显示资源，再通过服务器已有的 TMDB 接口补全海报和作品资料，同一作品合并查询，最多并行查询三个作品。仅在片名 / 原名、已知年份及 TMDB ID 匹配且候选唯一时显示海报；服务器未配置 TMDB、匹配不唯一或接口失败时保留海报占位，不影响资源操作。

发现页、片库、作品详情及资源结果支持一键创建订阅，默认搜索全部来源并启用自动解锁。新订阅先从 `/api/re0/unlock/config` 读取 RE0 账号的每资源积分上限，HDHaven 专属订阅改从 `/api/hdhaven/config` 读取，再保存 `source`、`auto_unlock` 和 `max_points`；读取失败会提示重试。订阅设置可修改上限或恢复账号默认值；编辑、暂停和恢复保留已保存的来源和上限，不会覆盖为当前账号默认值。上限为 0 或关闭自动解锁时仅使用免费或已解锁资源。仅 Telegram 的订阅不依赖 RE0 配置，RE0 / HDHaven 专属订阅需要准确的 TMDB ID。

RE0 / HDHaven 资源可先确认积分消耗，再通过各自接口获取链接；HDHaven 解锁同时携带 TMDB ID 与媒体类型。积分未知且未解锁的资源不会发起解锁。获取链接成功后需另行确认转存 / 离线下载。未获取链接时复制和分享的是对应来源的资源页，获取后保留完整下载地址及提取码。

## 首次使用

1. 在「服务器」中添加连接，填写 **MetaCine 服务的运行地址**，例如 `http://192.168.1.10:8080`。Gitea 仓库地址不是运行地址。
2. 选择账号密码或访问令牌。账号密码对应 `METACINE_USERNAME` / `METACINE_PASSWORD`；令牌对应可选的 `METACINE_AUTH_TOKEN`。
3. 点击「测试连接」，成功后保存。首次连接局域网时允许 iOS 本地网络权限。
4. 在服务端 Web 界面配置资源频道和 Telegram 授权、115 账号、整理目标，以及所需的 STRM / Emby 设置。客户端可以管理订阅，但资源获取和入库仍由服务器执行。
5. 在「发现」海报右下角点击「订阅」即可使用默认偏好一键订阅（全部来源、允许按 RE0 账号默认积分上限解锁、全部资源类型、全部季、每 60 分钟检查）。已订阅的作品显示「已订阅」，包括已暂停或指定季的订阅。作品详情的「一键订阅」直接保存，「订阅设置」可调整偏好；资源结果长按订阅按钮也可进入设置。服务器会持续检查，不依赖 App 在后台运行。

支持 `https://host/cinema` 形式的反向代理子路径，也接受末尾带 `/api` 的地址并自动规范化。默认校验 HTTPS 证书，不接受自签名证书绕过。对于受信任局域网中的 IP 地址 HTTP 服务，Info.plist 已配置 ATS 和本地网络说明。

## GitHub Actions 构建与 Releases

此仓库以 Gitea 为源、自动镜像到 GitHub。工作流只在 GitHub 上执行，构建不连接局域网 Gitea 或 MetaCine 服务器。确认 Gitea 推送镜像包含分支和版本标签，并在 GitHub 仓库开启 Actions。

工作流位置：`.github/workflows/ios.yml`。

| 触发方式 | 结果 |
| --- | --- |
| 推送任意分支（含 `main`） | iPhone 模拟器测试 → Release 真机编译 → 上传未签名 IPA 与 SHA-256 为 Actions artifact，并自动发布到独立的 GitHub 预发布 Release |
| 针对 `main` 的 Pull Request | 执行同样的测试与构建，不发布 Release |
| 推送 `v1.0.0` 等版本标签 | 测试及构建通过后自动创建 GitHub Release，上传 IPA 和 SHA-256 |
| 手动 Run workflow | 填写版本号；默认仅上传 artifact，可选发布对应提交的预发布 Release |

正式发布示例：

```bash
git add .
git commit -m "Build native MetaCine iPhone client with unsigned IPA releases"
git push origin main
git tag v1.0.0
git push origin v1.0.0
```

Gitea 镜像将版本标签同步至 GitHub 后触发发布。只有模拟器测试和真机构建都成功才会发布。主版本号使用三个数字段（如 `1.0.0`）；`v1.1.0-beta.1` 形式的标签会产生 iOS 版本号 `1.1.0` 和 GitHub 预发布版本。构建号使用 GitHub Actions 的运行编号。

每次分支 push 成功构建后都会生成 `v<版本>-build.<运行编号>` 预发布 Release，附带本次 IPA 和 SHA-256，不需要再推送版本标签或手动点击发布。连续 push 不会自动取消之前的构建。PR 不发布 Release，测试或构建失败也不发布。

`.github/workflows/cleanup.yml` 在 iOS 工作流结束后自动清理历史：按运行编号保留最近 3 次已完成的 iOS 构建（含失败记录），删除更早记录及其 artifacts / 日志；正在运行或排队的构建会继续执行。Releases 按发布时间保留最近 3 个包含 IPA 的已发布版本，正式版和预发布版共同计数，删除更早的 Release 及全部附件。草稿和不含 IPA 的 Release 不参与清理。清理工作流独立运行，避免并行构建完成顺序影响保留数量，也可手动执行。

测试通过后还会实际安装并启动模拟器 App，上传 `iPhone-launch-preview` 截图 artifact，供检查首次启动界面。

分支自动发布和手动发布都使用 `v<版本>-build.<运行编号>` 标签，并绑定本次构建的准确提交；Release 说明包含来源分支或标签、提交 SHA 和 Actions 链接。同一次运行重试会复用该 Release 并更新附件；已有同名标签指向其他提交时会停止发布。正式版本仍从 Gitea 推送 `v1.0.0` 等标签，保持镜像两端一致。

产物：

```text
MetaCine-1.0.0-unsigned.ipa
MetaCine-1.0.0-unsigned.ipa.sha256
```

Release 上传和历史清理由工作流的 `GITHUB_TOKEN` 完成。发布任务授予 `contents: write`，清理任务授予 `contents: write` 和 `actions: write`，无需额外配置 Personal Access Token。清理脚本只从默认分支检出和执行。构建流程不使用 p12、mobileprovision、Apple ID 或签名 secrets。

**未签名 IPA 无法直接点击安装到普通 iPhone。** 下载后需要使用自己的 Apple 签名或兼容的侧载工具重新签名。GitHub Actions 构建未签名安装包不等于 App Store / TestFlight 发布。

## 本地开发

使用 Xcode 16 或更高版本，打开 `MetaCine.xcodeproj`，选择 `MetaCine` scheme 和 iPhone 模拟器。若使用真机运行，需要在 Xcode 中选择自己的 Team 并配置唯一 Bundle Identifier。默认 Bundle Identifier 为 `app.metacine.ios`。

Xcode 项目和共享 scheme 已提交，打开即可使用。新增或删除 Swift 文件后，使用已安装的 Node.js 运行：

```bash
node scripts/generate-project.mjs
```

生成器只使用 Node.js 标准库，输出稳定，不依赖 XcodeGen、CocoaPods 或 Swift Package Manager 包。

测试和打包：

```bash
bash scripts/test-ios.sh
APP_VERSION=1.0.0 BUILD_NUMBER=1 bash scripts/build-unsigned-ipa.sh
```

`test-ios.sh` 自动选择已安装的 iPhone 模拟器，也可通过 `SIMULATOR_ID` 指定设备。`build-unsigned-ipa.sh` 使用 `CODE_SIGNING_ALLOWED=NO` 真机编译，打包 `Payload/MetaCine.app`，校验 ZIP 并生成 SHA-256。

仅验证项目结构（无需 Xcode）：

```bash
node scripts/generate-project.mjs
python3 scripts/validate-project.py
```

图标已经包含在资源目录。如需按同一设计重新生成，可以使用 Python 3 标准库运行 `python3 scripts/generate-icon.py`。

## 测试与验收

`MetaCineTests` 包含实际 API 字段兼容、榜单平台及地区切换、TMDB 片名搜索合并与分页、空关键词不发请求、原生榜单 / TMDB 身份隔离、原名订阅匹配、海报代理 / 请求合并 / 缩略图 / 缺图回退、URL 子路径及查询编码、RE0 / Telegram 搜索与解锁契约、订阅默认积分读取及编辑保留、UTF-8 字节限制、任务摘要和纳秒时间戳、401 重新登录及重试、认证失败不循环、服务端错误展示与旧连接失效测试。测试通过本地 `URLProtocol` 模拟 HTTP，不需要线上账号，也不依赖局域网服务器。

真机验收清单及支持范围见 `docs/ACCEPTANCE.md`。

## 项目结构

```text
MetaCine/
  App/                    应用入口、五个 Tab
  Core/                   API、模型、连接状态、钥匙串
  Features/
    Discover/             榜单与作品详情
    Search/               TMDB 片库、详情内资源搜索及转存
    Subscriptions/        订阅列表和编辑
    History/              历史与任务详情
    Servers/              多服务器与服务端设置
  UI/                     共享界面组件
  Resources/              Info.plist、颜色、图标
MetaCineTests/            模型与网络契约测试
scripts/                  工程生成、结构验证、测试、未签名打包
.github/workflows/        GitHub CI 和 Releases
```
