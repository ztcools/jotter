<div align="center">

# Jotter

**悬浮在桌面上的速记挂件** — 审查前端 UI、浏览网页时，随手把发现的问题记下来。

抱着本子的小猫 · 一键复制 · 一键导出 · 多卡片切换 · 全局快捷键 · 单文件 exe

</div>

---

## 它解决什么

看一个页面时你会连着发现七八个问题。切窗口去开记事本、开 issue、开飞书文档，注意力就断了。

Jotter 是桌面上一只抱着本子的小猫：点它一下，旁边就摊开一个本子，敲一行按回车，记下一条；记完点"复制"，整张卡片变成 Markdown 待办清单进剪贴板，直接贴进 issue 或聊天窗。

## 功能

| | |
|---|---|
| **小猫挂件** | 手绘二次元小猫（呼吸 / 眨眼 / 摇尾巴 / 按压回弹），常驻置顶、可拖动、位置跨重启记忆；角标显示未解决条目数 |
| **本子面板** | 独立窗口，贴在小猫旁边，尺寸取工作区的九分之一（每轴 1/3）；柔和圆角 + 深浅色自动跟随系统 |
| **多卡片** | 一张卡片对应一个页面 / 一条流程，标签条一键切换，双击重命名 |
| **条目** | 回车录入、点圆圈勾选已解决、点文字改错字、悬停删除 |
| **一键复制** | 输出 GitHub 风格任务清单 `- [ ] / - [x]`，可直接粘进 issue |
| **一键导出** | 原生保存对话框写 `.md` / `.txt`；按住 <kbd>Shift</kbd> 导出全部卡片 |
| **跟随移动** | 拖动小猫，本子实时跟着走；靠近屏幕边缘时改贴另一侧，不会跑到工作区外 |
| **收起策略** | 点击面板外自动收起；需要边看边记时点图钉固定 |
| **托盘 + 快捷键** | <kbd>Ctrl</kbd>+<kbd>Alt</kbd>+<kbd>J</kbd> 随时唤起/隐藏；托盘可直接新建卡片 |

### 快捷键

| 按键 | 作用 |
|---|---|
| <kbd>Ctrl</kbd>+<kbd>Alt</kbd>+<kbd>J</kbd> | 全局唤起 / 隐藏挂件 |
| <kbd>Enter</kbd> | 提交当前输入，输入框保持聚焦，可连续录入 |
| <kbd>Esc</kbd> | 收起本子 |
| <kbd>Ctrl</kbd>+<kbd>N</kbd> | 新建卡片 |
| <kbd>Ctrl</kbd>+<kbd>Tab</kbd> / <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>Tab</kbd> | 切换到下 / 上一张卡片 |

## 技术栈

**Tauri 2 (Rust) + Svelte 5 + TypeScript**

| 决策 | 理由 |
|---|---|
| Tauri 而非 Electron | 复用系统 WebView2，产物是单个 exe（数 MB 量级），内存占用约为 Electron 的十分之一。挂件是常驻进程，常驻成本就是它唯一重要的成本。 |
| 双窗口而非单窗口伸缩 | 小猫与本子各占一个窗口。单窗口要在展开时从 104px 长到面板大小，于是小猫窗口平时就顶着一大块透明矩形，把本该落到下层应用的点击全吞了；而且非 resizable 窗口的尺寸变更会被 `tao` 夹住。分成两个窗口同时解决这两件事，"卡片出现在球旁边"也就成了字面意义上的实现。 |
| 手绘 SVG 而非下载素材 | 小猫要能对状态起反应（按下时压扁、开本子时打勾），位图或第三方 Lottie 做不到，还要背许可与体积。整只猫是 4 KB 内联 SVG + CSS keyframes，走 GPU 合成，闲时 CPU 占用可忽略。 |
| Rust 主进程 | 窗口几何、托盘、全局快捷键、落盘全在原生侧，UI 线程只负责渲染。 |
| Svelte 5 而非 React/Vue | 编译期消解框架，几乎没有运行时。两个窗口的产物合计 80 KB JS + 16 KB CSS，其中小猫窗口只占 5 KB。 |
| WebView 做 UI | 柔和圆角、毛玻璃质感、过渡动画用 CSS 表达最省力，这正是需求的重点。 |
| 单 JSON 文档 + 原子写 | 数据量是 KB 级，嵌入式数据库带来的 C 依赖、迁移、连接管理都不划算。先写临时文件 → `fsync` → `rename` 覆盖，断电只会丢掉本次修改，不会得到半个文件。存取全部收敛在 [`store.rs`](src-tauri/src/store.rs)，要换后端只需改这一个文件。 |

### 架构

```
src-tauri/src/
├── model.rs      持久化数据结构 + 不变量（至少一张卡片、activeId 必然有效）
├── store.rs      唯一的磁盘出入口：原子写、损坏文件隔离而非丢弃
├── window.rs     两个窗口的全部几何与可见性：贴靠、跟随、边界收拢、位置记忆
├── commands.rs   IPC 边界：入参清洗 + 长度上限
├── tray.rs       托盘图标与菜单
└── lib.rs        装配：插件、事件、命令注册

ui/
├── index.html + src/ball.ts    小猫窗口
├── panel.html + src/panel.ts   本子窗口
└── src/
    ├── BallApp.svelte      拖动/点击判定、角标；不引入 workspace store，只持有一个数字
    ├── PanelApp.svelte     本子外壳：线圈书脊 + 纸面 + 页头
    ├── components/Cat.svelte  小猫本体（内联 SVG + CSS 动画）
    ├── lib/store.svelte.ts   UI 状态（Rust 是权威，这里是响应式镜像）
    ├── lib/ipc.ts            类型化命令封装，其余代码不直接 invoke
    ├── lib/errors.ts         前端未捕获异常回传 Rust，写进 Jotter.log
    └── lib/markdown.ts       复制/导出的渲染（放前端因为需要本地时区与 locale）
```

几个不显眼但影响手感的细节：

- **窗口可见性只有一份权威** — 前端从不维护"面板是否打开"的布尔量，只调 `toggle_panel`；开合状态在 Rust，变化后由 `panel-state` 事件广播。两个窗口各自记一份，迟早会对不上。
- **小猫不漂移** — 本子贴在小猫旁边而不是反过来；本子被工作区边界夹住时，小猫留在原处。否则在角落反复开关，小猫会一路往屏幕中间"爬"。
- **拖动与点击不冲突** — 指针位移超过 4px 才交给系统开始拖窗口，否则算点击。直接调 `startDragging` 会让系统拖拽循环吞掉所有点击。
- **失焦收起不会自己弹回** — 点小猫时面板先失焦收起，紧接着的点击又会要求打开。窗口事件与 IPC 之间有 320ms 的守卫窗口把这次重开吞掉。
- **导出时面板不消失** — 原生保存对话框会抢焦点，而失焦本来要触发自动收起。导出前后用 `suspend_auto_collapse` 括起来。
- **打开就能敲** — 本子窗口是隐藏而非销毁，所以挂载时那一次 `focus()` 落在还不可聚焦的 webview 上被拒，之后再也不会挂载第二次。光标改由 `panel-state` 打开事件取回，窗口重新获得焦点时再补一次；正在改错字时不抢。
- **数据永不静默丢失** — JSON 解析失败时，原文件改名为 `workspace.corrupt-<时间戳>` 保留，而不是覆盖。

## 构建

### 容器化交叉编译（推荐，无需 Windows 机器）

```bash
make windows          # → dist-win/Jotter.exe
```

`cargo-xwin` 在容器内拉取 MSVC CRT 与 Windows SDK 头文件，驱动 clang-cl / lld-link 产出 MSVC 目标的 exe。产物是**免安装单文件**，拷到 Windows 上双击即可。WebView2 运行时由 Windows 10 20H2 及以后版本自带。

### 在 Windows 上原生构建（额外产出 NSIS 安装包）

需要 Rust 工具链与 MSVC Build Tools：

```powershell
pnpm install
pnpm tauri build       # → src-tauri/target/release/{jotter.exe, bundle/nsis/*.exe}
```

### 开发

```bash
make check            # 前端类型检查
make lint             # cargo fmt --check + clippy -D warnings（需要本地 Rust）
make lint-docker      # 同上，但在构建容器里跑，本机无需装 Rust
make fmt-docker       # 在容器里格式化 Rust 源码
make icons            # 从 scripts/gen-icons.mjs 重新生成全部图标
make dev              # 热重载（需要本地 WebView 与 Rust 工具链）
```

> `make dev` 在 WSL 内需要 `webkit2gtk-4.1` 等 GTK 依赖；仅做 Windows 交付时不必安装，
> 用 `make windows` + `make lint-docker` 即可，二者共用同一个镜像。

改 CSS 时不必起 Rust 侧：`ui/preview.html` 用桩掉的 IPC 层跑真实组件，浏览器直接打开
`http://localhost:1420/preview.html?state=panel`（`state=ball` 看小猫），窗口尺寸与 Rust 给的一致，
可直接截图比对。

### 验收

`cargo build`、clippy、svelte-check 全绿的产物，照样可能是一个开着
`ERR_CONNECTION_REFUSED` 的窗口——它们都不运行这个 exe。
[`scripts/acceptance.ps1`](scripts/acceptance.ps1) 运行它，并独立核验：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\acceptance.ps1 -Exe .\Jotter.exe
```

| 手段 | 断言 |
|---|---|
| CDP（`--remote-debugging-port`） | 两个 webview 都加载自内嵌 bundle（`tauri.localhost`）、都挂载出了内容、都没有前端异常 |
| Win32 `EnumWindows` + DPI 感知 | 小猫窗口是 104 逻辑像素、本子是工作区每轴 1/3（面积 1/9）、置顶、透明、不越界 |
| CDP `Input.dispatchMouseEvent` | 真实指针按下/抬起（而非 `.click()`，那会绕过点击与拖动的判定）→ 本子在旁边打开、光标落在录入行（首开与重开各断言一次）、再点一次收起 |
| `SetWindowPos` + workspace.json | 移动小猫，本子跟随；新位置落盘 |
| 跨窗口事件 | 在本子里加一条，小猫角标随之变化（store hook → 事件 → 另一个 webview 的 DOM），随后自动清理 |
| 屏幕截取像素差 | 遮/显同一矩形对比：透明置顶窗口即使什么都没画，对所有 API 也仍然"健康" |

图标不是二进制资产：`scripts/gen-icons.mjs` 用带符号距离场把矢量定义渲染成全套 PNG 与 DIB 格式 ICO，因此改一处定义即可重出所有尺寸，CI 也会校验图标与生成器一致。

## 数据存放

```
%APPDATA%\com.ztcools.jotter\workspace.json
```

纯文本 JSON，可直接备份、diff 或手改。字段见 [`model.rs`](src-tauri/src/model.rs)。

日志（含前端回传的未捕获异常）：

```
%LOCALAPPDATA%\com.ztcools.jotter\logs\Jotter.log
```

## 许可

MIT
