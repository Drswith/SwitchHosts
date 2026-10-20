# 原生版验收清单（手工）

对应 5.0.2 的 9 个 e2e spec（见 `native-parity-checklist.md`）。界面自动化：`macos/UITests/SwitchHostsUITests.xcodeproj` 已建立（隔离的临时 HOME，只读的检查）。运行它需要先开启 Automation Mode：`sudo automationmodetool enable-automationmode-without-authentication`（系统安全设置，需要你自己执行），然后运行 `xcodebuild -project macos/UITests/SwitchHostsUITests.xcodeproj -scheme SwitchHostsUITests -destination 'platform=macOS' test`。下层的自动化由 `macos/scripts/run-tests.sh` 覆盖。

## 准备

1. 用隔离的 `HOME` 运行，避免改动真实数据和真实 `/etc/hosts`：

   ```bash
   export TEST_HOME="$(mktemp -d)"
   HOME="$TEST_HOME" macos/build/SwitchHosts.app/Contents/MacOS/SwitchHosts
   ```

2. 在 `$TEST_HOME/.SwitchHosts/internal/config.json` 中写入 `{"write_mode": ""}`。这样开关只会被拒绝，不会写入 `/etc/hosts`。需要验证真实写入时，请在你确认后再改成 `append`。
3. 每一项通过后在括号里打勾。失败时记录现象和 `$TEST_HOME` 中相关文件的内容。

## 1. local-hosts：本地条目

- [ ] 列表栏右上「新建」→「新建本地条目」，输入名称，「创建」后条目出现在列表中并被选中。
- [ ] 编辑内容，不点任何按钮（没有保存按钮和 ⌘S）：停止输入约 0.6 秒后，`$TEST_HOME/.SwitchHosts/entries/<id>.hosts` 与编辑器一致；切换到其他条目、窗口失焦、关窗或退出时立即保存。重新打开后内容一致。
- [ ] 选中多行，⌘/ 注释；再按一次取消注释。空行不受影响。
- [ ] 保存失败时底部出现错误提示条；此时切换条目会询问「放弃未保存的更改？」，选择「取消」后留在原条目。

## 2. hosts-entry-management：增删改、移动、排序

- [ ] 右键「重命名…」修改标题，`manifest.json` 中的 `title` 随之变化。
- [ ] 右键「上移」「下移」，列表与 `manifest.json` 的顺序一致。
- [ ] 右键「移到文件夹」→ 某个文件夹，条目进入该文件夹；选「顶层」可移回。
- [ ] 拖拽（「全部方案」或文件夹视图）：把条目拖到另一行的上半部分（放在它前面）、下半部分（后面），位置以目标所在的文件夹为准。「已启用」「远程」视图中不能排序。
- [ ] 拖拽到侧栏：拖到某个文件夹 = 移入该文件夹；拖到「全部方案」= 移到顶层。侧栏里的文件夹之间可以拖动排序（上下四分之一）和嵌套（中部）。拖进自己或子孙时不显示落点并被拒绝。
- [ ] 右键「移入回收站」，条目从列表中消失，在侧栏「回收站」中可见。

## 3. folder-choice-mode：文件夹的单选与多选

- [ ] 在侧栏选中文件夹，列表栏标题右侧出现「选择模式」弹出菜单（默认 / 单选 / 多选）和文件夹开关，切换后 `manifest.json` 中的 `folder_mode` 随之变化（0 / 1 / 2）。
- [ ] 偏好设置「选择模式」（单选 / 多选）的值写入 `config.json` 的 `choice_mode`。
- [ ] 在写入模式未设置时开关条目被拒绝，树的状态不变（内核测试 `testToggleReportsUnsetWriteModeWithoutTouchingSystemHosts` 已覆盖）。单选规则的完整验证需要写入模式，请在隔离环境并确认后进行。

## 4. system-hosts：系统 hosts 只读视图与历史

- [ ] 点击侧栏「系统 Hosts」，列表第一行「当前」显示系统文件内容，编辑器为只读。
- [ ] 「当前」下面是历史快照，按时间从新到旧；选中快照显示其内容和「这是写入 /etc/hosts 时保存的快照，只读。」提示条。
- [ ] 提示条的「删除快照…」二次确认后删除；「更多」菜单或侧栏右键的「清除历史记录…」确认后清空。
- [ ] 偏好设置「高级」中的「记录历史」开关关闭后，历史不再增加；「最大记录数」缩小时先显示保留与删除的数量，确认后才裁剪。

## 5. trashcan：回收站

- [ ] 侧栏底部「回收站」列出被移入的条目（类型 · 删除时间），选中后只读显示内容。
- [ ] 详情右上「恢复」后条目回到原位置（`manifest.json` 中的父子关系与移入前一致）。
- [ ] 「彻底删除…」与「清空回收站」在确认后执行；`trashcan.json` 相应变化。

## 6. data-transfer：导出、导入、URL 导入

- [ ] 工具栏「导出备份」保存 JSON，文件格式为 `switchhosts-backup`。
- [ ] 「导入备份」选择该文件，预览显示顶层条目数；「追加」后树增加条目，「替换」后树与备份一致。
- [ ] 「导入」→「从 URL 导入…」输入 `http://` 地址（例如本机用 `python3 -m http.server` 提供的备份文件），底部显示「正在下载备份…」，随后出现同样的预览。
- [ ] 输入不存在的地址（404）：底部显示「服务器返回了 HTTP 404。」并出现「重试」按钮；点击重试会再次请求。
- [ ] 输入非 http(s) 地址时「导入」按钮不可用。

## 7. remote-hosts：远程条目

- [ ] 「新建远程条目」选择「URL」，输入 `file://` 地址（指向一个文本文件）后，刷新成功，编辑器显示该文件内容，并显示「上次刷新」时间。
- [ ] 修改来源或刷新间隔后保存，`manifest.json` 中的 `url`、`source`、`refresh_interval` 随之变化。
- [ ] 把文件删除后刷新：底部显示错误，编辑器仍显示上一次的内容。
- [ ] 远程条目的编辑器为只读，工具栏「刷新」按钮可用。
- [ ] 偏好设置「代理」：开启并填写本机代理后，远程刷新经过代理（内核测试 `http_proxy_receives_the_absolute_url`、`socks5_proxy_carries_the_request_to_the_origin` 已覆盖协议层）。

## 8. preferences：偏好设置

- [ ] 「开机启动」「隐藏 Dock 图标」「主题」「在菜单栏显示已开启的条目」即时生效，并写入 `config.json`。
- [ ] 「写入模式」「移除重复记录」保存后，下次开关条目时按新设置执行（不在本清单中实际写入）。
- [ ] 「本地 HTTP API」开启后，`curl http://127.0.0.1:<端口>/api/list` 返回列表；关闭后端口不再监听。端口超出范围时显示「端口须在 1 到 65535 之间。」
- [ ] 「检查更新」显示最新版本或「已是最新版本」，不下载任何文件。
- [ ] 「特权 helper」：在未签名或证书不匹配的构建中，安装会失败并显示原因（已知限制，见 `native-rewrite.md`）。

## 9. titlebar：自绘标题栏

- [ ] 不适用：原生版使用系统标题栏。

## 其它

- [ ] 菜单栏「查找与替换」（⌘F）：搜索结果显示位置；「显示」选中条目并定位到匹配处；替换后内容更新；关键字与替换文本历史可从下拉中选择。
- [ ] 菜单「文件」「编辑」「帮助」的条目与 5.0.2 对应；中文界面下没有残留的英文文案（错误信息中的系统原因除外）。
