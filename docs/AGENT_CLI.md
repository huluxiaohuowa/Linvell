# Existing agent CLIs / 接入已有 Agent

Available in Linvell 0.2.4; concurrent sessions and corrected DSH titles are added in 0.2.5. Open the **Agents** sparkle button in the left activity bar or at the top right of the workspace, or search **Agents** in the command palette.

## 使用

打开项目后，点击左侧边栏或右上角 **Agents**（星光图标），或在命令面板中搜索 **Agents**。

1. 选择 Codex、OpenCode、Pi、Claude Code 或 DeepSeek Harness（DSH）。自动识别 PATH、常用用户安装目录、Node 版本管理器目录，以及 `/Applications`、`~/Applications` 内已知的桌面程序 CLI 路径。
2. 展开 **Agent 设置**，可从发现的安装中选择，也可点击 **选择 CLI…**，选择可执行文件或包含受支持 CLI 的桌面 `.app`。远程 CLI 可以直接输入绝对路径；不会运行桌面程序的 GUI 主进程。
3. 如果桌面版或 CLI 使用独立配置目录，填写相同的 **Agent 主目录**。Codex 对应 `CODEX_HOME`，Claude 对应 `CLAUDE_CONFIG_DIR`，Pi 对应 `PI_CODING_AGENT_DIR`，DSH 对应 `DSH_HOME`；留空保留默认环境。OpenCode 通过自己的 CLI 查询会话。
4. 面板会自动索引所选机器上、与当前目录匹配的会话。搜索后双击或点击 **继续会话**；也可以 **新建会话**。完整交互在已有 SwiftTerm 原生终端中运行，包括原 agent 的登录、权限确认和工具执行。
5. 已运行的会话在主界面顶部切换。每个会话拥有独立进程、终端输出、滚动记录和图片；运行中仍可新建会话、选择其他 Agent、刷新历史或继续另一个会话。继续已经在本实例运行的同一历史会话时直接切回原终端。**停止** 只作用于当前显示的会话，切换不会停止后台会话。退出工作区时统一确认并停止仍在运行的会话。
6. 终端中的文件链接按住 Command 点击，在当前 Linvell 工作区打开；普通路径可选中后点击 **打开选中文件**，支持相对路径及 `文件:行:列` 的行号定位。图片文件使用现有图片预览；支持 CLI 输出的 iTerm2、Kitty 和 Sixel 终端图片协议。远程路径沿所属会话的 SSH 连接或挂载映射打开。
7. Agent 保存的历史、压缩记录、分支、项目指令及其他上下文由该 agent 恢复。Linvell 不把不同产品的聊天记录拼成一个新会话，也不创建自己的 agent 引擎。

## 会话来源与边界

| Agent | 本地索引 | 恢复方式 |
| --- | --- | --- |
| Codex | 优先使用官方 app-server `thread/list`，与 `resume` 同源的名称/预览，包含分页和存档；旧版本回退 JSONL 与 `session_index.jsonl` | `codex resume <id>` |
| Claude Code | agent home 中 `projects` 下的 JSONL，排除子 agent 会话 | `claude --resume <id>` |
| Pi | 默认或环境变量指定的 session 目录下 JSONL | `pi --session <file>`，保留原会话树 |
| OpenCode | `opencode session list --format json`，不读取私有数据库结构 | `opencode --session <id>` |
| DeepSeek Harness | `DSH_HOME/sessions` 中最新版本会话日志的 `session/title`，支持 `.jsonl.zstd`，读取完整标题事件 | `dsh headless --session-id <id> -- <task>` |

Codex、OpenCode 优先使用自身提供的列表接口。Claude Code 和 Pi 先读取 256 KiB 会话头，再流式读取标题及重命名事件；DSH 使用现有安装附带的 Node 解码 Zstandard 日志并读取正式标题事件。没有名称时使用首条用户消息摘要，空会话显示“未命名会话”，UUID 只在次要信息中缩略显示。损坏或未能解析的会话不会列出。列表包含当前工作目录及 Git 元数据中双向登记的同仓库 worktree（包括桌面程序创建的 worktree），不运行远程 Git 命令。未登记的其他目录与子目录不会自动合并。恢复时在会话原来的工作目录运行，避免把 worktree 中的工作误写到主检出目录；列表次要信息与运行状态会标明目录。无会话持久化的运行无法恢复。自定义会话存储设置、未来版本的格式变动可能需要适配，不能把列表称为所有服务商的完整会话档案。

**桌面会话**：与 CLI 共用上述存储的桌面会话会一起出现。云端、其他机器、桌面私有存储中的会话，需要先通过服务商的官方交接流程使其可以被 CLI 恢复。仅复制聊天文本不代表完整上下文已经接续。存档会话能否直接恢复也取决于所选 CLI 版本。避免同时在两个客户端编辑同一个会话。

## 远程项目

- **SSH 主机**：使用项目现有 SSH 连接，发现远程 CLI 和远程会话，并在项目目录启动远程 CLI。复用 SSH 配置、密钥和登录 shell；会话发现沿用现有 Python 3 要求，不安装常驻服务。
- **本机**：本机 CLI 需要对远程文件的真实文件系统访问。点击 **挂载 SSH 目录…**，调用已安装的 SSHFS；或者 **选择挂载目录…** 选择已有挂载。Linvell 校验系统挂载表中的主机、远程目录、本机挂载点和可写性，再允许启动本机 agent。普通副本、其他主机、其他目录和失效挂载会被拒绝。
- 自动挂载位置固定在本机 Application Support 下，按主机和目录隔离，映射关系仅存在本机偏好设置。挂载保留以便继续使用会话；结束后可通过系统卸载该目录。Linvell 不在会话仍运行时自动卸载目录。
- 本机模式列出本机存储中以挂载路径为工作目录的会话，SSH 模式列出远程存储中的会话。**切换执行机器不会迁移会话或认证**。Git 和所有文件工具也在所选执行机器上运行；远程项目中的挂载文件读写直接作用于远程文件。

SSHFS 及其 macOS 文件系统支持是可选的外部前提，需要用户自行安装；不安装也可以直接使用远程 agent。本次没有增加包依赖、嵌入 WebView、Node/Python 运行时、模型、agent 程序或文件系统驱动。界面使用 AppKit，交互终端复用已有 SwiftTerm。

## 文件更新与持续运行

Agent 直接读写项目文件，不使用 Linvell 的文本副本。打开 Agent 面板后，会监测已打开文本文件及文件树中展开目录的元数据：本机约 1 秒一次，SSH 约 2 秒一次，网络请求和文件读取在后台完成。未修改的编辑缓冲区自动加载外部更改，同时保留光标、滚动位置和文件树展开状态；有未保存编辑时保留文本并显示冲突提示，原有保存校验继续阻止覆盖外部内容。只监测可见目录和已打开文件，避免每秒全盘扫描项目。

Agent 直接运行在主工作区：左侧 Agents 侧栏选择服务商、安装和会话，右侧显示运行终端，不另开窗口。切回文件管理器、打开其他文件或切换侧栏都不会重建 CLI 或 PTY；再次点击 Agents 会回到同一个进程和终端。切换项目不会暗中改变运行中 Agent 的目录。点击“停止”或退出工作区才会停止进程。

DSH 本机版本只有官方 `headless` 任务接口。选择 DSH 后填写任务输入框，再新建或继续所选会话；每次完成一个任务并退出，下次通过同一 session ID 继续，完整上下文仍归 DSH 管理。没有假定用户已经安装第三方 TUI profile。压缩会话读取优先复用 DSH 桌面程序自带的 Node，其他安装需要其已有 Node 支持 Zstandard；不额外打包运行时。

## English

Open **Agents** from the left activity bar, toolbar or command palette. Choose an existing Codex, OpenCode, Pi, Claude Code or DeepSeek Harness installation, or select a CLI executable / supported desktop app. Optional agent-home overrides must match the configuration used by that provider. Select a project session and resume it in the native terminal; the provider restores its own context and applies its own authentication and permission policy.

Local and SSH execution have separate session stores. Shared desktop/CLI stores are indexed together; cloud-only or private desktop sessions require the provider's handoff. Registered worktrees of the same repository are included by reading Git metadata without running Git remotely. Resuming uses the original session directory. Saved titles are read from each provider, including later rename events; unnamed sessions use the first user task as a preview. Indexing does not guarantee compatibility with every provider version or custom storage configuration.

For a local CLI working on an SSH project, mount the exact remote directory with an already installed SSHFS, or choose its existing mount. Linvell validates the live mount before launch. SSHFS and its filesystem support are optional external prerequisites, never bundled. Remote execution uses system SSH and the existing Python 3 file-protocol requirement. No agent engine, model runtime or package dependency has been added. DSH uses its official headless task interface and its existing Node runtime for compressed metadata. The left Agents sidebar selects the provider and session; its terminal runs in the main workspace without a separate window. File browsing leaves the agent process and terminal intact, and returning to Agents reattaches the same view and PTY. Open clean text files reload external edits automatically; unsaved edits retain conflict protection. Local metadata is checked about once per second, SSH about every two seconds.

## Validation

Focused tests cover metadata parsing, project isolation, duplicate/archive records, incomplete JSONL, official OpenCode JSON, desktop GUI/CLI distinction, live-mount identity rules, local/remote probe consistency and launching/resuming a fixture CLI in the native terminal. Automated fixtures do not make model API calls. A separate ephemeral read-only installed Codex execution also verified one real model reply. Additional tests cover late title changes across providers, official Codex list pagination, compressed DSH logs, file/tree refresh, dirty-buffer protection and preserving the same agent PID while switching files. Live local Codex `thread/list` and native title rendering were verified, and the installed DSH CLI was detected in the UI. Real CLI authentication, provider context restoration, SSH execution and SSHFS mounting need live acceptance on the intended installations; no claim of five-provider end-to-end acceptance is made here.

Provider references: [OpenCode CLI](https://opencode.ai/docs/cli/), [Pi sessions](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/sessions.md), [Pi session format](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/session-format.md), [Claude desktop handoff](https://code.claude.com/docs/en/desktop#continue-in-another-surface). Codex resume arguments were also checked against the locally installed CLI's `codex resume --help`.


## Session design references (0.2.5)

Reviewed [CloudCLI's session-keyed store](https://github.com/siteboon/claudecodeui/blob/main/src/modules/chat/hooks/useSessionStore.ts), [Orca's session lifecycle](https://www.onorca.dev/docs/model/agents-sessions), and [Orca's file-link ownership](https://github.com/stablyai/orca/blob/main/src/renderer/src/components/native-chat/native-chat-file-link.ts). Linvell uses its existing native SwiftTerm PTYs: each runtime retains its terminal and launch context; selection changes the visible runtime. No source code or runtime from these projects is incorporated. Agent Deck and Claude Squad also informed the separation between creating, attaching and stopping a session.

DSH's Zstandard files contain concatenated frames. The Node codec previously returned only the first frame (the header), losing subsequent title events. Discovery now consumes each complete frame using the codec's consumed-byte count, keeps the latest title, and tolerates an unfinished final frame while DSH writes. Installed DSH acceptance found five project sessions and read five saved titles; private title content is excluded from logs and fixtures.

Concurrent-session acceptance and remaining live-test limits: [verification record](validation/2026-10-30-agent-concurrent-sessions.md).
