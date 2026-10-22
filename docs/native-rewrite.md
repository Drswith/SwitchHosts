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
- fork 不修改上游文件。与 Tauri 无关的模块在 `crates/swh-core` 中原位编译（`#[path]` 指向 `src-tauri/src`）；与 Tauri 耦合的逻辑是 fork 自有副本，来源与同步基线记录在 `crates/upstream-sync.txt`。

## 代码布局与上游同步

- **与上游逐字一致**：`src-tauri/` 与 fork 所基于的上游提交逐字相同（目前是 `46b3bca7`），由 `footprint` 检查保证。Tauri 版使用上游自己的 `commands.rs`、`refresh.rs`、`http_api` 与 `AppState`（不是 `Arc<AppState>`），不依赖 `crates/swh-core`。
- **原位编译**：`crates/swh-core` 不保存上游模块的副本，用 `#[path]` 直接编译 `src-tauri/src` 中的源文件。`storage`、`hosts_apply`、`helper_proto`、`migration`、`dns`、`hosts_text` 直接挂在 crate 根；`http`、`import_export` 通过带目录 `#[path]` 的内联模块挂载（它们有同名子目录），并在 crate 根重新导出，使上游代码中的 `crate::storage::…` 等路径保持有效。
  - 上游对这些模块的修复无需移植，原生版直接获得；上游改了签名时，`swh-core` 编译失败，这就是同步信号。
  - `storage` 与 `hosts_apply` 直接挂在 crate 根，使上游两个按完整路径重跑测试二进制的测试（`storage::transaction::tests::…`、`hosts_apply::history::tests::…`）在 `swh-core` 中同样通过。
- **fork 自有**：与 Tauri 耦合的逻辑（命令、托管状态、事件）无法原位编译，只能在 `crates/swh-core/src` 中重新实现，不依赖 Tauri。上游改动需要手动移植：
  - `api.rs`、`apply.rs`（来自 `commands.rs`）、`refresh.rs`、`find.rs`、`events.rs`
  - `toggle.rs`（来自 `http_api/toggle.rs`；它的测试 `http_api/toggle/tests.rs` 用 `#[path]` 原位编译）
  - `http_api/{mod,routes,server}.rs`（来自 `http_api.rs`、`http_api/server.rs`）
  - `bootstrap.rs`：`AppState::bootstrap_at`，即 `AppState::bootstrap` 的显式数据根版本，作为 fork crate 中的 inherent impl 实现，因此 `storage/mod.rs` 不改动
  - `extra_tests.rs`：为上游模块补充的测试（`http.rs` 的代理路由、`storage/config.rs` 的语言）
- 每个 fork 自有文件的上游来源与已同步的上游提交记录在 `crates/upstream-sync.txt`。

同步上游：

1. `git fetch upstream`
2. 将 `upstream/master` 合并进 fork。用 merge，不 rebase 已发布的历史；`git config rerere.enabled true` 可减少重复冲突。
3. `crates/upstream-sync.sh check -p`：列出上游来源自基线以来有变化的 fork 文件，有则退出码为 1。
4. 把列出的改动移植到 fork 副本中。
5. 每个移植完的文件执行 `crates/upstream-sync.sh bump <fork 路径> [ref]`，记录新基线。
6. `crates/upstream-sync.sh footprint`：fork 改动了 `macos/`、`crates/`、`docs/native-*.md`、`rust-toolchain.toml`、`.gitignore` 之外的文件则失败。
7. 运行测试：`macos/scripts/run-tests.sh`。

## 里程碑

> 注：H0–H6 中描述 Tauri 侧委托内核或复用内核、以及模块「迁入」`crates/swh-core` 的条目，已被「代码布局与上游同步」取代：Tauri 版恢复为与上游一致，与 Tauri 无关的模块在 `crates/swh-core` 中原位编译，不再搬迁。以下条目保留作历史记录。

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

### H8 第二轮对照（5.0.2 的界面代码）

逐个对照 5.0.2 的渲染层组件（`src/renderer/components`、`pages`）后补齐的差异。每项都在真实窗口中确认过：测试副本使用独立的 bundle id（`net.oldj.switchhosts.native.check`）和隔离的 HOME，真实数据与 `/etc/hosts` 未改动。

- [x] 主题在启动时生效（`AppTheme`）。此前只在偏好窗口里切换时才应用。已确认：系统为深色时，以浅色主题启动的窗口直接是浅色。
- [x] 组合（group）条目只读：右侧列出它包含的本地与远程条目，「信息」面板显示类型「组合」与所含条目；不再被当成本地条目编辑。
- [x] 回收站的永久删除与清空前先确认（文案来自 5.0.2：「要彻底删除本项吗？」「确实要清空回收站吗？」）。已确认取消不会删除、确认后清空。
- [x] 统一的新建与编辑窗口（对应 5.0.2 的编辑抽屉）：新建本地、远程、组合、文件夹四种类型；编辑时类型不可改（与 5.0.2 相同），可改标题和该类型的字段，并有「移入回收站」。菜单与工具栏的「新建」都有四项。远程条目的自动刷新间隔与 5.0.2 相同：从不、1 / 5 / 15 分钟、1 小时、1 天、7 天。
- [x] 文件夹行也有开关（5.0.2 中所有非系统行都有开关，切换规则在内核）。
- [x] 多选：⌘ / ⇧ 选中多行，最后加入的一行显示在编辑器中；工具栏或右键菜单的「移入回收站」作用于所有选中行（内核 `move_many_to_trashcan`）。
- [x] 回收站中选中条目会只读显示它的内容。
- [x] 数据目录失效时，启动即询问：使用默认位置、选择新文件夹或退出（对应 5.0.2 的恢复窗口）。已确认：记录指向不存在的文件夹时出现询问，选择「使用默认位置」后记录被清除并重新启动。
- [x] 查找结果：行号改为直接使用内核的值（内核从 1 计数，此前多加了 1）；显示匹配前后的文字；非本地条目标「只读」，其「替换」按钮禁用，「替换所有」只在有可替换结果时可用。
- [x] 写入模式为空时打开开关会先询问写入模式（追加 / 覆盖 / 取消），选择后再执行开关。已确认取消时什么也不写。
- [x] 修正：新建条目或右键操作改变选中项时，编辑器此前仍显示上一个条目的内容；现在通过 `select` 载入新选中条目自己的内容。

### H9 其余差异与界面整理

- [x] 顶栏（工具栏左侧）：当前条目的图标、标题、非本地条目的「只读」标记、本地条目未保存时的「未保存」标记；侧栏隐藏时显示该条目的开关。启动时选中系统 Hosts，与 5.0.2 相同。
- [x] 关于窗口：5.0.2 的主页、源码链接与致谢名单。帮助菜单的主页改为 5.0.2 的地址。
- [x] 托盘：两个菜单栏窗口底部有显示主窗口、显示/隐藏 Dock 图标、版本号、退出；文件夹也有开关。应用图标与托盘图标使用 5.0.2 的图片（`make-app.sh` 复制到包内）。
- [x] 修正侧栏点击无法选中：行的拖拽改用 `itemProvider`（`onDrag` 会吞掉 List 行的普通点击）；选中项在点击时同步更新，内容随后载入。真实窗口中确认点击、⌘ 多选与拖拽都正常。
- [x] 窗口不能小于内容的最小尺寸（`windowResizability(.contentMinSize)`），侧栏底部与提示条不再被裁掉。
- [x] 界面整理：侧栏使用系统的侧栏图标着色、较小的开关、底部回收站入口与数量；编辑器 13 pt 等宽字体、行距与内边距、带分隔线的行号栏（含末尾空行的行号）；只读条目在编辑器上方显示来源条；右侧信息面板改为卡片；文件夹与组合面板有标题区与卡片；提示条改为浮动的圆角卡片并可关闭；所有弹出窗口使用统一的标题、卡片与底部操作栏；菜单栏窗口有应用标题、紧凑的行与菜单样式的按钮。浅色与深色外观都在真实窗口中核对过。
- [x] 托盘窗口的新样式已在真实窗口中确认（从菜单栏溢出区打开）：应用标题、各条目与开关（含文件夹）、显示主窗口、隐藏/显示任务栏图标（点击后 Dock 图标消失、再点恢复）、退出与版本号。

### H10 界面重做（1c）

按 `1c 三栏方案`（设计稿 `SwitchHosts macOS Redesign.dc.html` 的 4a 定稿）重做原生前端。Rust 内核、FFI、`src-tauri` 与 `SwitchHostsCore` 的 Swift 接口没有改动，所有数据操作仍走原有命令；视图状态（侧栏选中）存在 UserDefaults，不写内核配置，数据与 5.0.2 互通。

- [x] 主题：`Theme.swift` 的 `Brand` 定义 accent / accentSoft / accentInk、IP、注释、行号、关闭的开关、搜索高亮，各有浅色与深色值，accent 设为主窗口、偏好、菜单栏窗口与弹窗的 tint。`Card`、`PaneHeader`、`SheetLayout` 去掉了彩色图标块和描边；新增 `Tag`（类型、状态等小标签）与列表行用的 `BrandSwitchStyle`。
- [x] 编辑器：IP 紫、注释暖灰、`SWITCHHOSTS_CONTENT_START/END` 两行用 accent；行高 1.55；行号栏宽 56、无分隔线，行号按每行基线对齐（空行的字形位置比正文低 3 pt，所以不用字形位置）；停止输入 0.6 秒后回调（`Debouncer`，有测试）。
- [x] 自动保存：`HostsModel` 按顺序写入 `set_hosts_content`（后发的不会被先发的覆盖）；停止输入、切换条目、窗口失焦、关窗时立即保存，退出前有未保存内容时等写完再退出（`applicationShouldTerminate`）。删除了保存按钮与 ⌘S、「未保存」标记。保存失败时显示原有的错误提示条，此时切换条目会询问是否放弃。
- [x] 模型：侧栏选中（system / all / active / remote / folder(id) / trash）存在 UserDefaults 的 `SidebarSelection`；`Library` 计算各视图的行（全部 = 树的深度优先顺序中的非文件夹条目，已启用 = 其中 `isOn` 的，远程 = 远程条目，文件夹 = 直接子项）、标题搜索与计数。首次启动选中「系统 Hosts → 当前」，以后恢复上次的视图。
- [x] 主窗口：`NavigationSplitView` 三列。侧栏（212）有「资源库」「文件夹」两组，嵌套文件夹每层缩进 16，回收站固定在底部，选中为 accentSoft 底 + accentInk；列表（300）的标题与副标题在工具栏中，行是两行文字加开关，选中为实心 accent，系统 Hosts 列出「当前」与历史快照，回收站列出已删除项；详情为 22 pt 标题与一排标签，远程有来源条，快照有只读提示条与「删除快照…」，回收站为「彻底删除…」（红字，需确认）与「恢复」，组合显示所含条目。删除了 `EntryInfoPanel`、`TrashSheet`、`HistorySheet` 与它们的入口，保留右键菜单与 ⌘ / ⇧ 多选移入回收站；列表支持 ↑↓ 与 Delete 键。
- [x] 拖拽：全部复用 `drop(_:onto:placement:)` 与「移动到文件夹」。「全部方案」与文件夹视图中，拖到行的上半 / 下半放在目标（在其父级中）之前 / 之后；「已启用」「远程」视图不能排序；拖到侧栏文件夹移入该文件夹，拖到「全部方案」移到顶层（已在该处时不变）；侧栏文件夹之间可排序与嵌套；拖进自己或子孙时悬停不显示落点，落下也会被内核规则拒绝。
- [x] 其余界面：菜单栏窗口宽 300，头部为图标、名称、「N 个方案生效」与打开主窗口按钮，已启用的条目加粗，底部为菜单样式按钮与版本号；偏好设置四页都是 `Form(.grouped)`，开关为 accent，主题改为分段控件，历史的「记录历史」与「最大记录数」移到「高级」；新建 / 编辑顶部为四个类型方块（编辑时禁用），下面为分组表单，底部「取消 / 创建」；查找替换的「.*」「Aa」在输入框内，结果按条目分组并高亮匹配，只读条目带标记、不可替换，底部「完成 / 查找 / 全部替换（N）」。
- [x] 本地化：新字符串加入 `sync-localizations.py` 的 `OVERRIDES`。新增 `macos/scripts/check-localizations.sh`：用编译器的 `-emit-localized-strings` 取出源码中的全部键，与生成的中文对比；当前 265 个键，0 个缺失（产品名、协议名、路径与示例地址按原文保留，列在 `KEEP_AS_IS`）。
- [x] 系统设计（2026-10-21 补）：SwiftPM 经 `swiftc` 链接时给 clang 的是 `--sysroot` 而不是 `-isysroot`，链接器把部署目标 13.0 记成了 SDK 版本（`LC_BUILD_VERSION` 中 `sdk 13.0`，实际编译用的是 27.0 SDK）。macOS 按这个 SDK 版本决定是否使用当前的系统设计，所以应用此前一直以兼容模式运行：菜单栏面板是旧式窗口，里面的开关却是新控件，面板变成直角并在上下多出透明条。`make-app.sh` 现在用 `vtool -set-build-version macos 13.0 <SDK 版本> -replace` 写入实际的 SDK 版本，菜单栏面板与主窗口都使用当前设计（macOS 26 起为大圆角玻璃面板）。随之修正：
  - 行号栏：macOS 14 起视图默认不裁剪到自身边界，行号栏按脏区域填充背景时会盖住正文与上方的标题，改为只填自身范围并开启 `clipsToBounds`。
  - 兼容模式下的两处绕行已去掉：侧栏「资源库」标题回到滚动区内（兼容模式下滚动区的绘制与点击位置错开），回收站的「恢复」改回系统的 `.glassProminent`（macOS 26 起）/ `.borderedProminent`。
  - 侧栏与列表的行加了辅助功能动作，VoiceOver 等可以像点击一样选中（此前只有「按钮」特性，按下没有反应）。

验证（真实窗口，测试副本 `net.oldj.switchhosts.native.check`，隔离的 HOME，写入模式为空，真实数据与 `/etc/hosts` 未改动）：

- 三种拖拽都写入了 `manifest.json`：列表条目拖到侧栏文件夹（进入）、列表内拖到另一行上半部分（排到前面）、条目拖到「全部方案」（移到顶层）；侧栏文件夹拖到另一文件夹中部（嵌套）。把文件夹拖进自己的子文件夹时不显示落点，松开后树不变。
- 「远程」视图中拖动条目不显示落点，顺序不变。
- 自动保存：编辑后不点任何按钮，约 1.5 秒内文件已更新；输入后立即点另一行，内容已保存；退出再打开，内容一致；列表行与标题下的行数随编辑实时变化。
- 计数随树实时变化（移动、恢复、移入回收站后侧栏数字即时更新）。开关会写入 `/etc/hosts`，所以开关后的计数与「已启用」列表由模型测试覆盖（`SidebarModelTests.testCountsAndTheActiveListFollowTheTree`：模拟开关提交后的 `manifest.json` 并 `reload`）。
- ⌘ 点击多选、侧栏点击、↑↓ 切换均正常。

截图：`macos/build/screenshots-1c/`（本地生成，不提交：「当前」视图显示的是本机的 `/etc/hosts`；2026-10-21 在修正 SDK 版本后重拍）。主窗口按 浅色 / 深色 × 英文 / 中文 各 8 张：`all`、`active`、`remote`、`folder`、`system-current`、`system-snapshot`、`trash`、`empty`（空文件夹），文件名为 `<light|dark>-<en|zh-Hans>-<视图>.png`；另有 `light-zh-Hans-menubar.png` 与 `dark-zh-Hans-menubar.png`。偏好设置、新建条目与查找替换没有重拍。

与规范不一致的地方及原因：

- 列表行的开关是 `Toggle` 加自定义的 `BrandSwitchStyle`（辅助功能仍是开关），不是系统的 `.switch`：系统开关不能设置关闭态颜色，也不能做出选中行上的「白色轨道 + accent 滑块」。文件夹开关与之一致；菜单栏窗口与偏好设置用系统 `.switch` 加 accent。
- 侧栏与列表的行是自绘的（`ScrollView` 加自定义行），不是 `List` 的系统选中样式：系统 List 的选中色跟随系统强调色，做不出 accentSoft 底或实心 accent 行。键盘的 ↑↓、Delete 与 ⌘ / ⇧ 多选已补上；macOS 13 上列表获得焦点时会显示焦点环（14 起已隐藏）。
- 「使用系统窗口边框」关闭时不再隐藏标题文字，因为列表栏的标题与副标题就是窗口标题；该偏好仍决定内容是否延伸到标题栏下。
- 历史快照的副标题是「N 行 · 大小」，不是设计稿的「应用 basic, shared」：Swift 侧的 `ApplyRecord` 没有对应字段，按约束不改 `SwitchHostsCore` 接口。「当前」的副标题是 `/etc/hosts · 追加 / 覆盖`（写入模式，未设置时只显示路径）。
- 启动时恢复上次的侧栏视图（规范要求存在 UserDefaults），只有首次启动或上次在「系统 Hosts」时选中「当前」。
- 侧栏文件夹不能折叠（设计稿没有折叠），`is_collapsed` 原样保留。
- 「清除历史记录…」放在详情的「更多」菜单与侧栏「系统 Hosts」的右键菜单，「清空回收站」放在回收站视图列表栏的工具栏与侧栏右键菜单；规范没有指定位置。
- 在「已启用」「远程」视图中新建条目后切到「全部方案」（新条目默认关闭，原视图显示不了它）；文件夹视图中新建的条目进入该文件夹。
- macOS 26 起，回收站的「恢复」单独放在一块玻璃上（`sharedBackgroundVisibility(.hidden)`），否则会与「彻底删除」共用一块、显示为普通按钮。
- 查找替换保留了「查找」按钮（设计稿底部只有「完成 / 全部替换」），因为「只换样式，功能不变」。「Aa」按下表示区分大小写，对应内核的 `is_ignore_case = false`。
- 偏好「命令」页的「清除历史记录」改为红字，但没有新增确认（只换样式）。
- 只在 macOS 27 上实际运行过；macOS 13–15 的工具栏与侧栏外观未实测。

## 最新验证

`macos/scripts/run-tests.sh` 的最近一次完整运行全部通过，`/etc/hosts` 的托管标记数量前后均为 1：

- `crates/swh-core`：278 个单元用例（其中约 210 个是原位编译的上游模块自带的测试）加 1 个集成用例，包括代理路由（HTTP 与 SOCKS5）、命令历史、数据目录的校验路径，以及 `tests/data_dir_roundtrip.rs`（在隔离的 HOME 中完成复制、重启、重置的完整流程）。
- `crates/swh-ffi`：5 个用例。
- `src-tauri --lib`：317 个用例（与上游一致的 Tauri 版自带测试）。
- `swift test`（`macos/SwitchHostsNative`）：96 个用例通过（H10 新增 32 个：`LibraryTests` 13、`SidebarModelTests` 10、`AutosaveTests` 5、`DebouncerTests` 4）。离屏渲染用例（5 个）在未设置 `SWH_SHOTS_DIR` 时跳过；设置后全部通过，并生成截图。覆盖拖放、折叠、文件夹模式、新建文件夹与组合、组合包含的条目、远程刷新、刷新间隔的文案、历史与命令历史的桥接、核心消息的本地化（含开发者诊断信息的中文条目）、解码（含查找结果的前后文与只读、数据目录恢复的路径）、拖放的 payload 往返。

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
- Tauri 版的 HTTP API（`src-tauri/src/http_api.rs` 及 `src-tauri/src/http_api/`）与上游一致，不再是薄宿主；原生版的 HTTP API 在 `crates/swh-core/src/http_api/`，是 fork 自有副本（见「代码布局与上游同步」）。

## 验证命令

```bash
macos/scripts/run-tests.sh
```

该脚本依次运行 `crates/swh-core`、`crates/swh-ffi`、`src-tauri --lib` 的 `cargo test`，构建 Rust 静态库，运行 `swift test`，并检查 `/etc/hosts` 的托管标记在测试前后没有变化。

本地化是否有遗漏（先运行 `macos/scripts/sync-localizations.py`）：

```bash
macos/scripts/check-localizations.sh
```

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
