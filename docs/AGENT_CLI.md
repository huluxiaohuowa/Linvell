# Existing agent CLIs / 接入已有 Agent

Available in Linvell 0.2.4; concurrent sessions and corrected DSH titles are added in 0.2.5. Open the **Agents** sparkle button in the left activity bar or at the top right of the workspace, or search **Agents** in the command palette.

## 使用

打开项目后，点击左侧边栏或右上角 **Agents**（星光图标），或在命令面板中搜索 **Agents**。

1. 选择 Codex、OpenCode、Pi、Claude Code 或 DeepSeek Harness（DSH）。自动识别 PATH、常用用户安装目录、Node 版本管理器目录，以及 `/Applications`、`~/Applications` 内已知的桌面程序 CLI 路径。
2. 展开 **Agent 设置**，可从发现的安装中选择，也可点击 **选择 CLI…**，选择可执行文件或包含受支持 CLI 的桌面 `.app`。远程 CLI 可以直接输入绝对路径；不会运行桌面程序的 GUI 主进程。
3. 如果桌面版或 CLI 使用独立配置目录，填写相同的 **Agent 主目录**。Codex 对应 `CODEX_HOME`，Claude 对应 `CLAUDE_CONFIG_DIR`，Pi 对应 `PI_CODING_AGENT_DIR`，DSH 对应 `DSH_HOME`；留空保留默认环境。OpenCode 通过自己的 CLI 查询会话。
4. 面板会自动索引所选机器上、与当前目录匹配的会话。搜索后双击或点击 **继续会话**；也可以 **新建会话**。完整交互在已有 SwiftTerm 原生终端中运行，包括原 agent 的登录、权限确认和工具执行。
5. 已运行的会话在主界面顶部切换。每个会话拥有独立进程、终端输出、滚动记录和图片；运行中仍可新建会话、选择其他 Agent、刷新历史或继续另一个会话。继续已经在本实例运行的同一历史会话时直接切回原终端。**停止** 只作用于当前显示的会话，切换不会停止后台会话。退出工作区时统一确认并停止仍在运行的会话。
6. 终端中的文件链接按住 Command 点击，在当前 Linvell 工作区打开；普通路径可选中后点击 **打开选中文件**，支持相对路径及 `文件:行:列` 的行号定位。图片文件使用现有图片预览；支持 CLI 输出的 iTerm2、Kitty 和 Sixel 终端图片协议。远程路径沿所属会话的 SSH 连接或同步副本的远程路径映射打开。
7. Agent 保存的历史、压缩记录、分支、项目指令及其他上下文由该 agent 恢复。Linvell 不把不同产品的聊天记录拼成一个新会话，也不创建自己的 agent 引擎。

## 执行位置与安装引导（0.2.8）

切换 Agent 或 **本机／SSH 主机** 时，主界面同步切换到该组合上次选中的终端；没有已打开会话时显示空状态，原会话继续在后台运行。从顶部已打开会话菜单选择时，左侧 Agent 和执行位置也同步更新，菜单中标明本机或 SSH 主机名。

**新建会话** 不再因为缺少配置而无说明地变灰：未选择 CLI 时展开对应设置，DSH 未填写任务时给出说明并聚焦任务输入。本机 Agent 操作远程项目时，先通过 Mutagen 完成初次同步，再启动 CLI。

本机模式提供 Mutagen 可选依赖检测。未安装时显示安装命令；安装后显示绿色能力提示，连接后的同步状态单独显示：

```sh
brew install mutagen-io/mutagen/mutagen
```

无需文件系统驱动、开机启动项或修改启动安全设置。检测安装不启动同步进程。

## 项目切换（0.2.6）

工作台按“项目目录＋SSH 主机”隔离。打开 SSH 项目后，左侧会话列表和 CLI 设置切换到该远程项目，并显示 **本机／SSH 主机** 执行位置选择；新的远程工作台默认选择 SSH。选择本机时，在启动本机 CLI 前通过 Mutagen 同步该项目。

切换项目不会停止旧项目中的 Agent。回到原项目后恢复原工作台和同一个 PTY；关闭窗口或退出应用时统一确认并停止所有项目中仍在运行的会话。左侧 Session 列表、搜索、新建及继续会话入口继续保留。

## 会话来源与边界

| Agent | 本地索引 | 恢复方式 |
| --- | --- | --- |
| Codex | 优先使用官方 app-server `thread/list`，与 `resume` 同源的名称/预览，包含分页和存档；旧版本回退 JSONL 与 `session_index.jsonl` | `codex resume <id>` |
| Claude Code | agent home 中 `projects` 下的 JSONL，排除子 agent 会话 | `claude --resume <id>` |
| Pi | 默认或环境变量指定的 session 目录下 JSONL | `pi --session <file>`，保留原会话树 |
| OpenCode | `opencode session list --format json`，不读取私有数据库结构 | `opencode --session <id>` |
| DeepSeek Harness | `DSH_HOME/sessions` 中最新版本会话日志的 `session/title`，支持 `.jsonl.zstd`，读取完整标题事件 | `dsh web --no-open`，在内嵌界面按原始 session ID 打开 |

Codex、OpenCode 优先使用自身提供的列表接口。Claude Code 和 Pi 先读取 256 KiB 会话头，再流式读取标题及重命名事件；DSH 使用现有安装附带的 Node 解码 Zstandard 日志并读取正式标题事件。没有名称时使用首条用户消息摘要，空会话显示“未命名会话”，UUID 只在次要信息中缩略显示。损坏或未能解析的会话不会列出。列表包含当前工作目录及 Git 元数据中双向登记的同仓库 worktree（包括桌面程序创建的 worktree），不运行远程 Git 命令。未登记的其他目录与子目录不会自动合并。恢复时在会话原来的工作目录运行，避免把 worktree 中的工作误写到主检出目录；列表次要信息与运行状态会标明目录。无会话持久化的运行无法恢复。自定义会话存储设置、未来版本的格式变动可能需要适配，不能把列表称为所有服务商的完整会话档案。

**桌面会话**：与 CLI 共用上述存储的桌面会话会一起出现。云端、其他机器、桌面私有存储中的会话，需要先通过服务商的官方交接流程使其可以被 CLI 恢复。仅复制聊天文本不代表完整上下文已经接续。存档会话能否直接恢复也取决于所选 CLI 版本。避免同时在两个客户端编辑同一个会话。

## 远程项目

- **SSH 主机**：使用项目现有 SSH 连接，发现远程 CLI 和远程会话，并在项目目录启动远程 CLI。复用 SSH 配置、密钥和登录 shell；会话发现沿用现有 Python 3 要求，不安装常驻服务。
- **本机**：通过可选的 Mutagen，在 Linvell 私有目录建立远程项目的本机同步副本，供本机 CLI 读写。不使用 SSHFS/macFUSE，不修改系统启动安全设置。
- 未安装时，界面显示并可复制 `brew install mutagen-io/mutagen/mutagen`；安装后点击重新检测，显示绿色“已安装 Mutagen — 可使用本机 Agent 修改远程代码”。绿色只代表依赖可用，实际同步状态单独显示。
- 只打开项目、查看会话或检测安装不会启动同步进程。新建本机 Agent 会话时完成初次同步后再启动 CLI；“使用 Mutagen 连接”只执行一次同步检查。最后一个需要同步的本机会话结束或工作区关闭后，完成一次有时限的写回并停止 Linvell 自己的同步进程。切换服务商、会话或浏览文件不终止仍在运行的 Agent。
- 使用独立的 Mutagen 数据目录和应用托管进程，不注册开机启动，不使用用户的 `~/.mutagen` 会话。同步副本按 SSH 主机和项目隔离；停止同步后保留副本和会话状态，以免丢失未写回内容。应用异常退出时，托管进程的监督器也会停止同步进程。
- 使用 `two-way-safe` 双向同步；冲突不强制覆盖。界面显示同步、重连或冲突状态；初次同步失败或存在冲突时不启动新的本机 Agent。`.git` 等版本控制元数据与 `.DS_Store` 不同步。
- 本机模式列出本机副本路径对应的会话，SSH 模式列出远程存储中的会话。切换机器不会迁移会话或认证。**文件同步不等于远程命令执行**：本机 CLI 的 shell 命令仍在本机运行，远程编译和测试必须明确通过 SSH 执行。

Mutagen 按需由用户安装，不打包进 Linvell，也不会自动安装。Mutagen 会在远程用户目录缓存对应版本的同步辅助程序；同步连接结束后进程退出，不注册远程系统服务。界面使用 AppKit，交互终端复用已有 SwiftTerm。

## 文件更新与持续运行

Agent 直接读写所选执行位置的项目文件；远程项目的本机模式使用上述 Mutagen 同步副本。打开 Agent 面板后，会监测已打开文本文件及文件树中展开目录的元数据：本机约 1 秒一次，SSH 约 2 秒一次，网络请求和文件读取在后台完成。未修改的编辑缓冲区自动加载外部更改，同时保留光标、滚动位置和文件树展开状态；有未保存编辑时保留文本并显示冲突提示，暂停自动保存，原有保存校验继续阻止覆盖外部内容。Mutagen 写回需要一定时间，SSH 元数据检测约每 2 秒进行一次，因此不是零延迟协同编辑。同一文件的不同版本不会自动进行三方合并；可先将未保存内容另存副本，再比对、合并。两端已写盘的冲突由 Mutagen 保留，并在 Agent 面板显示冲突数和文件路径；点击“查看同步冲突…”可在当前 Linvell 实例打开本机副本与远程版本，分别比对并保存一致的合并结果，原有未保存缓冲区不会被重新打开操作替换。只监测可见目录和已打开文件，避免每秒全盘扫描项目。

Agent 直接运行在主工作区：左侧 Agents 侧栏选择服务商、安装和会话，右侧显示运行终端，不另开窗口。切回文件管理器、打开其他文件或切换侧栏都不会重建 CLI 或 PTY；再次点击 Agents 会回到同一个进程和终端。切换项目不会暗中改变运行中 Agent 的目录。点击“停止”或退出工作区才会停止进程。

DSH 使用安装中自带的官方 Web 交互界面，内嵌在 Agent 工作区。无需另装 TUI，也无需先输入任务：新建直接创建空白会话，双击历史项按原始 session ID 恢复。已有 DeepSeek 账号登录通过 DSH 自身的凭据服务复用；创建前调用官方默认模型初始化，避免把账号登录误当成缺少 API key。CLI、账号与 API key 的策略仍由 DSH 管理。SSH 模式通过 SSH 本地端口转发访问远端 Web 界面，认证使用远端账号；本次真实账号验收覆盖本机，未覆盖真实远端 DSH。压缩会话读取优先复用 DSH 桌面程序自带的 Node，其他安装需要其已有 Node 支持 Zstandard；不额外打包运行时。

## English

Open **Agents** from the left activity bar, toolbar or command palette. Choose an existing Codex, OpenCode, Pi, Claude Code or DeepSeek Harness installation, or select a CLI executable / supported desktop app. Optional agent-home overrides must match the configuration used by that provider. Select a project session and resume it in the native terminal (DSH uses its embedded official Web UI); the provider restores its own context and applies its own authentication and permission policy.

Local and SSH execution have separate session stores. Shared desktop/CLI stores are indexed together; cloud-only or private desktop sessions require the provider's handoff. Registered worktrees of the same repository are included by reading Git metadata without running Git remotely. Resuming uses the original session directory. Saved titles are read from each provider, including later rename events; unnamed sessions use the first user task as a preview. Indexing does not guarantee compatibility with every provider version or custom storage configuration.

For SSH projects, **SSH Host** runs the installed remote CLI. **This Mac** uses an optional Mutagen synchronized replica. Install only when needed with `brew install mutagen-io/mutagen/mutagen`; recheck shows a green availability indicator. Synchronization starts only for an explicit connection check or a local agent session on an SSH project. The last dependent local session stopping shuts down Linvell’s isolated daemon; no login item is registered. Two-way-safe mode preserves conflicting changes, and pending edits remain in the replica. VCS metadata is excluded. Shell commands remain local unless explicitly executed through SSH.

## Validation

Focused tests cover metadata parsing, project isolation, duplicate/archive records, incomplete JSONL, official OpenCode JSON, desktop GUI/CLI distinction, replica identity rules, local/remote probe consistency and launching/resuming a fixture CLI in the native terminal. Automated fixtures do not make model API calls. A separate ephemeral read-only installed Codex execution also verified one real model reply. Additional tests cover late title changes across providers, official Codex list pagination, compressed DSH logs, file/tree refresh, dirty-buffer protection and preserving the same agent PID while switching files. Live local Codex `thread/list` and native title rendering were verified, and the installed DSH CLI was detected in the UI. Real CLI authentication, provider context restoration, SSH execution and Mutagen synchronization need live acceptance on the intended installations; no claim of five-provider end-to-end acceptance is made here.

Provider references: [OpenCode CLI](https://opencode.ai/docs/cli/), [Pi sessions](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/sessions.md), [Pi session format](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/session-format.md), [Claude desktop handoff](https://code.claude.com/docs/en/desktop#continue-in-another-surface). Codex resume arguments were also checked against the locally installed CLI's `codex resume --help`.


## Session design references (0.2.5)

Reviewed [CloudCLI's session-keyed store](https://github.com/siteboon/claudecodeui/blob/main/src/modules/chat/hooks/useSessionStore.ts), [Orca's session lifecycle](https://www.onorca.dev/docs/model/agents-sessions), and [Orca's file-link ownership](https://github.com/stablyai/orca/blob/main/src/renderer/src/components/native-chat/native-chat-file-link.ts). Linvell uses its existing native SwiftTerm PTYs: each runtime retains its terminal and launch context; selection changes the visible runtime. No source code or runtime from these projects is incorporated. Agent Deck and Claude Squad also informed the separation between creating, attaching and stopping a session.

DSH's Zstandard files contain concatenated frames. The Node codec previously returned only the first frame (the header), losing subsequent title events. Discovery now consumes each complete frame using the codec's consumed-byte count, keeps the latest title, and tolerates an unfinished final frame while DSH writes. Installed DSH acceptance found five project sessions and read five saved titles; private title content is excluded from logs and fixtures.

Concurrent-session acceptance and remaining live-test limits: [verification record](validation/2026-10-30-agent-concurrent-sessions.md).

DeepSeek Harness opens blank conversations and restores history without a task or an extra TUI installation. Its own credential service reuses the configured login; Linvell initializes the default model through the official account flow rather than demanding a separate API key. SSH DSH uses a loopback tunnel and remote credentials; live DSH acceptance in this release covers the local installation.
