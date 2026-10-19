# macOS 原生重写：目标与里程碑

## 目标

把前端从 Tauri WebView 换成 macOS 原生 UI（SwiftUI / AppKit）。Rust 内核（`crates/swh-core`）保持逻辑不变，通过 C ABI（`crates/swh-ffi`）被 Swift 调用。

功能基线固定为 **5.0.2**（tag `v5.0.2`）。5.0.3-beta 的新增功能（DNS 检测、导入预览、数据恢复提示、端口可配、历史开关、覆盖层拖拽、另外 7 种语言）不在范围内。

## 总体验收标准

- 功能、快捷键和数据文件（`~/.SwitchHosts`）与 5.0.2 一致，两个版本可以互换使用同一份数据。
- 空闲内存显著低于 Tauri 版。目标值需先用活动监视器按进程加总测出当前基线后再定。
- `cargo test`（`crates/swh-core`、`crates/swh-ffi`、`src-tauri`）和 `swift test`（`macos/SwitchHostsNative`）全部通过。

## 已确定的决定

- 后端逻辑保持 Rust，前端换成原生。
- 桥接使用 C ABI + JSON：`invoke(command, args) -> envelope`，加一个事件回调。
- 特权 helper 保留 Rust 实现（`hosts_apply::helper_admin` 与 `helper_proto`）。
- 最低系统版本 macOS 13（SMAppService 所需）。
- 树的开关事务已在 Rust 中实现（`toggle`，原先用于 HTTP API），现提升为内核公共函数。
- 不做轻量模式。它是 Tauri 版为减少 WebView 内存而设计的，原生版没有 WebView，不需要。原生版不实现该设置，也不释放窗口内容；内核中的 `lightweight_mode` 配置键保留，Tauri 版继续使用。

## 里程碑

### H0 内核拆分与桥接

- [x] `crates/swh-core` 承载与 Tauri 无关的逻辑：storage、hosts_apply、dns、import_export、migration、helper_proto、http、apply、toggle、api、events。
- [x] 应用流水线与开关事务迁入内核。Tauri 侧只保留 `src-tauri/src/events.rs` 作为事件适配。
- [x] `api::dispatch` 统一命令表，覆盖 list、content、set_list、回收站列表、hosts 内容、配置读取、`toggle_item`。
- [x] `crates/swh-ffi` 提供 C ABI，头文件在 `crates/swh-ffi/include/swh.h`。
- [x] `swift test` 通过（5 个用例，链接 macOS 13 部署目标的 Rust 静态库）。

### H1 远程刷新进内核

- [x] `refresh.rs` 迁入 `crates/swh-core`，改用 `EventSink` 与 `&AppState`，不再依赖 Tauri。
- [x] 后台定时刷新改为可由宿主在任意运行时驱动的 `run_background_scanner` future；Tauri 与 FFI 都在打开数据根时启动它（数据根处于恢复状态时不启动）。
- [x] `refresh_remote_hosts` 与 `refresh_all_remote_hosts` 的实现抽到内核 `api`，Tauri 命令只做薄包装，FFI 命令表同名暴露。
- [x] Tauri 托管状态改为 `Arc<AppState>`，以便后台任务持有同一份状态。
- [x] 验证：内核 244、Tauri 库 73、FFI 4（含不联网的 `file://` 远程刷新与事件回调测试）、Swift 6 全部通过。
- [x] 代理（socks5）与 5.0.2 的对照：URL 的构造与使用点（远程刷新、URL 导入、检查更新）相同；HTTP 与 SOCKS5 的路由有内核测试（`proxy_routing_tests`）。

### H2 HTTP API 进内核与登录项

- [x] `http_api` 迁入 `crates/swh-core`：路由、开关事务与监听生命周期都在内核；宿主只通过 `ApiHost` 告知是否有渲染层。
- [x] Tauri 版改为薄宿主；FFI 句柄按保存的偏好拉起监听，并提供 `http_api_status` 与 `http_api_configure`。
- [x] 验证：FFI 端到端测试通过真实 TCP 访问 `/`、`/api/list`、`/api/toggle`（写模式为空时返回 `write mode not set.`，不写系统 hosts），并确认关闭后端口释放。
- [x] 登录项（SMAppService）与 Dock 图标（启动时按 `hide_dock_icon`）已在 Swift 侧实现；偏好界面的开关留给 H5。

### H3 原生主窗口

- [x] 回收站（移入、恢复、永久删除、清空）迁入内核 `api`，Tauri 命令委托。
- [x] 树（`OutlineGroup`）、选中加载与保存内容、新建、重命名、移入回收站、上移/下移（替代拖拽）。
- [x] 树的写入采用「读取 → 修改 → 带读取结果作为守卫写回」，内核在树已变化时拒绝写入（有测试）。
- [x] 系统 hosts 只读视图（`get_system_hosts` 迁入内核）。
- [x] 编辑器语法高亮（`NSTextView`：注释变灰、地址着色；只读模式用于系统 hosts）。
- [x] 导出备份（保存面板）、导入预览（打开面板 → 追加或替换）；导入的预览、rebase、丢弃、提交都在内核。
- [x] 文件夹设置（默认 / 单选 / 多选）：右侧面板改值，写入树的 `folder_mode`。
- [x] 折叠状态写入树（`is_collapsed`），与 5.0.2 一样随树保存；折叠不改变选中项。
- [x] 「移动到文件夹」菜单（含顶层，拒绝移入自身或子孙，有测试）。
- [x] 系统 hosts 历史：列表（新到旧）、内容查看、删除选中、清空、记录开关、上限（缩小时先确认再裁剪）。
- [x] 从 URL 导入：下载、复用文件导入的预览与追加 / 替换，失败时在底部显示核心的错误。
- [x] 拖拽排序：拖到条目上半部分放在前面，下半部分放在后面，文件夹中部放入其中；拖到自己的子孙中会被拒绝（有测试）。
- [x] 拖拽的界面路径已在真实窗口中验证（授权后用真实输入）：子项拖进文件夹、顶层条目拖到文件夹之前、子项拖到顶层条目之后，三种都写入了 `manifest.json`。之前用脚本注入时个别顶层条目拖不动，原因是输入方式（用 `left_click_drag` 而不是分步的鼠标移动）。

### H4 查找替换

- [x] 搜索、单个替换、全部替换与历史迁入 `crates/swh-core/src/find.rs`；Tauri 窗口代码保留在宿主，通过 `pub use` 复用。
- [x] 原生查找替换面板（⌘F）：关键字、正则、忽略大小写、逐条「显示」与「替换」、全部替换。
- [x] 正则语义：内核与 Tauri 版都使用 Rust `regex` crate，语义一致，不存在 JS/ICU 差异。
- [x] 查找与替换各有历史下拉（新到旧，去重，上限 20 条），与 5.0.2 的 `find.json` / `replace.json` 共用。
- [x] 「显示」选中条目并把编辑器的选区定位到匹配处；偏移是核心返回的 UTF-16 位置，与 `NSTextView` 的 `NSRange` 直接对应。

### H5 托盘、偏好、菜单、语言

- [x] 偏好设置（⌘,）为四个标签页，与 5.0.2 相同：
  - 通用：开机启动（SMAppService）、启动时隐藏、隐藏 Dock 图标、关闭主窗口时退出、主题、写入模式、选择模式、自动检查更新、检查更新、后台 helper。
  - 命令：应用后命令的文本，以及运行历史（查看、删除、清空）。
  - 代理：使用代理、协议（HTTP / HTTPS / SOCKS5）、主机、端口。
  - 高级：域名解析 DNS（含自定义 DoH 模板的校验）、启动时刷新远程方案、移除重复记录、托盘标题、切换文件夹时同步子项目、本地 HTTP API、数据目录（显示、更改并选择是否复制、重置、不可用时的提示）、hosts 文件位置。
  - 有意不提供或不同的设置及原因见 `native-parity-checklist.md`（语言、系统窗口边框、托盘快捷小窗、使用数据、面板布局）。
- [x] 配置写入经内核 `config_update` 持久化，失败时回滚（有测试）。
- [x] 启动行为：启动时刷新远程方案、启动时检查新版本（有提醒横幅，不自动下载）、启动时隐藏主窗口。关闭最后一个窗口时是否退出由 `AppDelegate` 读取偏好。
- [x] 数据目录：`get_data_dir_status`、`data_dir_plan`、`apply_data_dir`、`reset_data_dir` 在内核中实现（与 Tauri 版的逻辑相同，去掉了窗口几何的持久化与 Tauri 的重启）。切换后由 `AppRelaunch` 重新启动应用。内核测试只覆盖不写入指针文件的校验路径，指针文件位于用户的真实配置目录，测试不会修改它。
- [x] 菜单栏入口（`MenuBarExtra`，窗口样式）：同一棵树的开关，并可打开主窗口或退出；状态栏标题与 5.0.2 的规则一致（有测试）。
- [x] 本地化：`macos/scripts/sync-localizations.py` 从 5.0.2 字典与中文覆盖表生成 `Localizable.strings`，`.app` 打包后生效（已用中文环境截图确认）。
- [x] 应用菜单：应用（关于）、文件（新建本地 / 远程条目、导入备份、从 URL 导入、导出备份）、编辑（查找与替换、注释 / 取消注释）、帮助（反馈、主页）。
- [x] 语言只保留中文与英文（决定）。中文译文由 `macos/scripts/sync-localizations.py` 生成：来自 5.0.2 字典的 `KEYS` 映射加上 `OVERRIDES`。界面里的 Swift 字符串已逐条核对（有脚本检查未覆盖的字符串）。英文即代码中的文本。
- [x] 核心返回的用户可见错误（写入、导入、HTTP、TLS、DNS、刷新、存储）按英文原文作为键翻译（`CoreText.swift`；测试检查每个模板的占位符数量与中文译文一致）。
- [x] 开发者诊断信息已翻译：参数错误（`args[N] must be …`、`expected …`）、helper 的 payload 检查、桥接的兜底文本（`CoreText.swift` 与 `sync-localizations.py` 的 `OVERRIDES`；测试检查中文条目存在）。它们不出现在正常操作的界面中。
  - 仍保持原文，不计入此项：系统命令的原始输出（例如命令运行历史里的 stdout / stderr，是用户命令的输出，不是诊断信息），以及 serde 解析器给出的细节（`find_replace_one: invalid request:` 之后的部分）。
- [x] 行号栏已在真实窗口中验证：第一行显示 1，与文本行对齐。之前栏内没有数字，原因是文本被替换时没有触发重绘，现已修复。

### H6 特权 helper、更新、打包

- [x] helper 的状态与安装/修复/卸载命令迁入内核 `api`；Tauri 版的同名命令委托内核。
- [x] 只读的更新检查：查询 GitHub 最新发布，有新版本时由用户点击打开发布页，不自动下载或安装。
- [x] `macos/scripts/make-app.sh` 生成 `SwitchHosts.app`（bundle id `net.oldj.switchhosts.native`，与 Tauri 版可并存）。自动使用本机的 Apple Development 证书签名（`SIGN_IDENTITY` 可覆盖），`codesign --verify --deep --strict` 通过。只复制 `Resources` 中当前语言的 `.lproj`。
- 已知限制（你决定暂缓公证）：Developer ID 签名与公证需要证书，当前环境没有。Apple Development 证书只能在本机运行。SMAppService 的 helper 绑定了团队 J5J6USUX2F，用本机证书无法安装 helper，偏好里的 helper 安装会失败。
- 已知限制（按你的选择记录）：不做自动安装更新（Sparkle 等需要签名更新源），仅保留手动检查。

### H7 行为验收

- [x] 对照清单已写入 `docs/native-parity-checklist.md`，逐项对照 5.0.2 的 9 个 e2e spec（注意：5.0.2 实际是 9 个，此前文档写的 11 个有误）。有意不同的设置单独列出。
- [x] 手工验收清单：`docs/native-acceptance.md`，按 9 个 spec 列出步骤和期望结果，并说明隔离环境的准备。
- [x] 自动化：`macos/scripts/run-tests.sh` 运行全部 Rust 与 Swift 测试，并检查 `/etc/hosts` 的托管标记在测试前后没有变化。
- [x] XCUITest 工程：`macos/UITests/SwitchHostsUITests.xcodeproj`，目标 `SwitchHostsUITests`，共享 scheme 已建。测试用隔离的临时 HOME 启动 `macos/build/SwitchHosts.app`，只做读取与选择（列表、选择文件夹、⌘, 打开设置）。
- 已知限制（你决定暂不开启）：XCUITest 未运行。本机的 Automation Mode 处于关闭状态，开启它是系统安全设置，需要管理员认证。UI 测试 runner 目前是临时签名的，Gatekeeper 会报「已损坏」。日后要运行时，两件事都需要处理。
- [x] 界面确认（授权后，真实窗口）：拖拽、行号栏、数据目录的更改与重置（经由 NSOpenPanel 与 NSAlert，在隔离的 HOME 中完成，指针文件与复制后的数据均已核对，真实数据未改动）。
- [x] 真实窗口中已确认：「信息」面板（修复了英文状态与类型的本地化）、语言切换（跟随系统 / English，经重新启动后整个界面变为英文）。
- [x] 托盘快捷小窗关闭时的紧凑列表已在真实窗口中确认（你手动打开并截图两次）：列出条目与开关，底部有「Open SwitchHosts」「Quit SwitchHosts」，文字正常显示。

## 最新验证

`macos/scripts/run-tests.sh` 的最近一次完整运行全部通过，`/etc/hosts` 的托管标记数量前后均为 1：

- `crates/swh-core`：278 个用例，包括代理路由（HTTP 与 SOCKS5）、命令历史、数据目录的校验路径，以及 `tests/data_dir_roundtrip.rs`（在隔离的 HOME 中完成复制、重启、重置的完整流程）。
- `crates/swh-ffi`：5 个用例。
- `src-tauri --lib`：54 个用例。
- `swift test`（`macos/SwitchHostsNative`）：56 个用例通过。离屏渲染用例（5 个）在未设置 `SWH_SHOTS_DIR` 时跳过；设置后全部通过，并生成截图。覆盖拖放、折叠、文件夹模式、远程刷新、历史与命令历史的桥接、核心消息的本地化（含开发者诊断信息的中文条目）、解码、拖放的 payload 往返。

真实窗口中的检查（授权后，用真实输入，隔离的 HOME，真实数据未改动）：

- 拖拽：子项拖进文件夹、顶层条目拖到文件夹之前、子项拖到顶层条目之后，三种都写入 `manifest.json`。
- 编辑器行号栏：第一行显示 1，与文本行对齐。
- 数据目录：经由 NSOpenPanel 选择文件夹，选择「复制数据并重新启动」，重启后的界面显示新目录，指针文件与复制的数据已核对；再点「重置」后指针被清除，默认目录重新生效。
- 设置窗口：通用、高级两个标签页显示正常，标签与选项均已本地化。

内存（空闲，同一份数据，Release，各取一次 `vmmap --summary` 的 Physical footprint）：

| 版本 | 进程 | footprint |
|---|---|---|
| 原生 Release | SwitchHosts | 40.1 MB（无子进程，最新构建） |
| Tauri Release | switchhosts 主进程 | 37.3 MB |
| Tauri Release | WebKit WebContent | 73.2 MB |
| Tauri Release | WebKit GPU | 13.0 MB |
| Tauri Release | WebKit Networking | 6.1 MB |
| Tauri Release | 合计 | 129.5 MB |

每项只取了一次样本，没有做长时间的对比。原生版与 Tauri 版的主进程大小接近，差距主要来自 WebKit 的三个子进程。

## 与 Tauri 版的当前差异

- 树的开关规则在 Rust（`storage::manifest::set_on_state_of_item`）和 TypeScript（`src/common/hostsFn.ts`）中各有一份。TypeScript 版继续服务 Tauri 渲染层，直到 Tauri 版下线。
- 数据目录的切换逻辑在核心与 Tauri 中各有一份：Tauri 版保留了窗口几何的持久化与自身的重启流程。
- Tauri 版的 `src-tauri/src/http_api/` 只是薄宿主，实际逻辑在内核（H2）。

## 验证命令

```bash
macos/scripts/run-tests.sh
```

该脚本依次运行 `crates/swh-core`、`crates/swh-ffi`、`src-tauri --lib` 的 `cargo test`，构建 Rust 静态库，运行 `swift test`，并检查 `/etc/hosts` 的托管标记在测试前后没有变化。

## H0 的目标条件（用于 `/goal`）

> 完成 H0：`cargo test` 在 crates/swh-core、crates/swh-ffi、src-tauri 下全部通过；`macos/scripts/build-core.sh` 成功；`swift test`（macos/SwitchHostsNative）全部通过；docs/native-rewrite.md 中 H0 没有未勾选项。

## H0 验证记录

- 前端：`npm run typecheck` 通过；`npm run test:unit` 27 个文件、314 个用例通过；Playwright e2e（Chromium，针对渲染层 mock）98 个用例通过。
- 内核：`cargo test` 覆盖 `crates/swh-core`（219）、`crates/swh-ffi`（3）、`src-tauri --lib`（98）全部通过。
- 原生桥接：`swift test` 6 个用例通过，其中包括 toggle 在写模式未设置时被拒绝且不修改已保存状态的用例（测试不写真实 `/etc/hosts`）。
- 真实 Tauri 应用（隔离 `HOME`）：启动后经 core 列出数据，树结构与文件夹正确显示；点击条目后编辑器加载对应内容（`get_hosts_content`）；编辑内容后磁盘文件被更新（`set_hosts_content`）。
- 原生 SwiftUI 应用（隔离 `HOME`）：树结构正确渲染；开关点击经 `HostsModel.toggle` 调到 core，返回 `write mode is not set`，未改动系统 hosts。
- 内存（空闲、同一份数据）：Tauri 应用合计 footprint 约 232 MB（主进程 45.6 MB + WebKit 子进程约 186 MB）；原生 Release 版 footprint 约 25 MB。注意原生版功能远少于 Tauri 版，这不是功能对等的对比。
- 未覆盖：Tauri 版的 toggle 应用到系统 hosts 的路径（为避免改动真实 `/etc/hosts` 而未执行）；回收站与恢复的真实后端流程；原生版的错误条视觉截图（窗口焦点问题未能截取，仅靠日志与单元测试验证）。
