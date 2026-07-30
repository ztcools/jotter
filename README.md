<div align="center">

# Jotter

**悬浮在桌面上的速记挂件** — 审查前端 UI、浏览网页时，随手把发现的问题记下来。

一键复制 · 一键导出 · 多卡片切换 · 全局快捷键 · 单文件 exe

</div>

---

## 它解决什么

看一个页面时你会连着发现七八个问题。切窗口去开记事本、开 issue、开飞书文档，注意力就断了。

Jotter 是桌面右下角一颗悬浮球：点一下展开一个小本子，敲一行按回车，记下一条；记完点"复制"，整张卡片变成 Markdown 待办清单进剪贴板，直接贴进 issue 或聊天窗。

## 功能

| | |
|---|---|
| **悬浮球** | 常驻置顶、可拖动、位置跨重启记忆；角标显示未解决条目数 |
| **本子面板** | 368×476，柔和圆角 + 深浅色自动跟随系统 |
| **多卡片** | 一张卡片对应一个页面 / 一条流程，标签条一键切换，双击重命名 |
| **条目** | 回车录入、点圆圈勾选已解决、点文字改错字、悬停删除 |
| **一键复制** | 输出 GitHub 风格任务清单 `- [ ] / - [x]`，可直接粘进 issue |
| **一键导出** | 原生保存对话框写 `.md` / `.txt`；按住 <kbd>Shift</kbd> 导出全部卡片 |
| **收起策略** | 点击面板外自动收起为球；需要边看边记时点图钉固定 |
| **托盘 + 快捷键** | <kbd>Ctrl</kbd>+<kbd>Alt</kbd>+<kbd>J</kbd> 随时唤起/隐藏；托盘可直接新建卡片 |

### 快捷键

| 按键 | 作用 |
|---|---|
| <kbd>Ctrl</kbd>+<kbd>Alt</kbd>+<kbd>J</kbd> | 全局唤起 / 隐藏挂件 |
| <kbd>Enter</kbd> | 提交当前输入，输入框保持聚焦，可连续录入 |
| <kbd>Esc</kbd> | 收起为悬浮球 |
| <kbd>Ctrl</kbd>+<kbd>N</kbd> | 新建卡片 |
| <kbd>Ctrl</kbd>+<kbd>Tab</kbd> / <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>Tab</kbd> | 切换到下 / 上一张卡片 |

## 技术栈

**Tauri 2 (Rust) + Svelte 5 + TypeScript**

| 决策 | 理由 |
|---|---|
| Tauri 而非 Electron | 复用系统 WebView2，产物是单个 exe（数 MB 量级），内存占用约为 Electron 的十分之一。挂件是常驻进程，常驻成本就是它唯一重要的成本。 |
| Rust 主进程 | 窗口几何、托盘、全局快捷键、落盘全在原生侧，UI 线程只负责渲染。 |
| Svelte 5 而非 React/Vue | 编译期消解框架，几乎没有运行时。整个前端构建产物 74 KB JS + 12 KB CSS。 |
| WebView 做 UI | 柔和圆角、毛玻璃质感、过渡动画用 CSS 表达最省力，这正是需求的重点。 |
| 单 JSON 文档 + 原子写 | 数据量是 KB 级，嵌入式数据库带来的 C 依赖、迁移、连接管理都不划算。先写临时文件 → `fsync` → `rename` 覆盖，断电只会丢掉本次修改，不会得到半个文件。存取全部收敛在 [`store.rs`](src-tauri/src/store.rs)，要换后端只需改这一个文件。 |

### 架构

```
src-tauri/src/
├── model.rs      持久化数据结构 + 不变量（至少一张卡片、activeId 必然有效）
├── store.rs      唯一的磁盘出入口：原子写、损坏文件隔离而非丢弃
├── window.rs     全部窗口几何与可见性：球 ↔ 面板、边界收拢、位置记忆
├── commands.rs   IPC 边界：入参清洗 + 长度上限
├── tray.rs       托盘图标与菜单
└── lib.rs        装配：插件、事件、命令注册

ui/src/
├── lib/store.svelte.ts   UI 状态（Rust 是权威，这里是响应式镜像）
├── lib/ipc.ts            类型化命令封装，其余代码不直接 invoke
├── lib/markdown.ts       复制/导出的渲染（放前端因为需要本地时区与 locale）
└── components/           Ball · Panel · CardTabs · ItemList · Composer · Toolbar
```

几个不显眼但影响手感的细节：

- **悬浮球不漂移** — 面板从球所在的角落展开；靠近屏幕边缘时会被收回可见区域，但收起时球回到原位，而不是被收拢后的位置。否则在右下角反复开关，球会一路往左上"爬"。
- **拖动与点击不冲突** — 指针位移超过 4px 才交给系统开始拖窗口，否则算点击。直接调 `startDragging` 会让系统拖拽循环吞掉所有点击。
- **导出时面板不消失** — 原生保存对话框会抢焦点，而失焦本来要触发自动收起。导出前后用 `suspend_auto_collapse` 括起来。
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
make lint             # cargo fmt --check + clippy -D warnings
make icons            # 从 scripts/gen-icons.mjs 重新生成全部图标
make dev              # 热重载（需要本地 WebView 与 Rust 工具链）
```

> `make dev` 在 WSL 内需要 `webkit2gtk-4.1` 等 GTK 依赖；仅做 Windows 交付时不必安装，用 `make windows` 即可。

改 CSS 时不必起 Rust 侧：`ui/preview.html` 用桩掉的 IPC 层跑真实组件，浏览器直接打开
`http://localhost:1420/preview.html?state=panel`（`state=ball` 看悬浮球），窗口尺寸与 Rust 给的一致，
可直接截图比对。

图标不是二进制资产：`scripts/gen-icons.mjs` 用带符号距离场把矢量定义渲染成全套 PNG 与 DIB 格式 ICO，因此改一处定义即可重出所有尺寸，CI 也会校验图标与生成器一致。

## 数据存放

```
%APPDATA%\com.ztcools.jotter\workspace.json
```

纯文本 JSON，可直接备份、diff 或手改。字段见 [`model.rs`](src-tauri/src/model.rs)。

## 许可

MIT
