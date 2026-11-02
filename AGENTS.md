# AGENTS.md — KDS 项目记忆

> **蒸馏层**：只放稳定结论，≤200 行。流水账写 `.hermes/journal/`。
> PM 维护，coder / tester / architect 只读。跨项目通用事实放 profile memory，不放这里。

## 这是什么

KDS 厨房显示系统：替代后厨纸质小票，订单数字化分流、多阶段制作状态可视、前后厅联动。
部署门店局域网，对接自有/第三方 POS（**松耦合标准契约**：KDS 定标准、POS 适配）。

核心链路：`POS 事件接入 → 档口路由/分片队列 → 工作流引擎（划单流转）→ 三视图分屏 → 回执 POS`。

## 技术栈

| 层 | 选型 |
|---|---|
| 语言/运行时 | .NET 10（LTS）/ C# 14 |
| 数据访问 | EF Core 10（写+迁移）+ Dapper（读/报表/批量） |
| 数据库 | SQLite（门店默认）/ SQL Server 2016+（推荐，最低 2012；**2008 不实现**） |
| 传输 | SignalR（默认）/ MQTT，JSON 强制 PascalCase |
| 终端 | Win10 1809+ WPF+WebView2；Win7 只能 Edge 109 浏览器；MAUI 评估后启用 |
| 测试 | xUnit + Moq/NSubstitute + FluentAssertions + coverlet |

## 解决方案结构（PRD §15 定，**代码待建**）

```
Kds.sln
├── src/
│   ├── Kds.Core/            领域模型、事件契约、状态机、档口匹配
│   ├── Kds.App/             Windows 一体客户端（Master 本地 UI）
│   ├── Kds.Api/             Master 内嵌服务端（Kestrel）
│   ├── Kds.Infrastructure/  EF Core、MQTT、SignalR
│   ├── Kds.Workflow/        工作流引擎（StagePath、联动、档口筛选）
│   ├── Kds.Printing/        打印子系统（模板渲染、ESC/POS、任务队列）
│   ├── Kds.Terminal.Maui/   Android/iOS Worker（评估后启用）
│   └── Kds.Web/             Web 前端（BS 终端 + 管理端）
└── tests/
    ├── Kds.Core.Tests/      档口匹配、StagePath、状态机单测
    ├── Kds.Workflow.Tests/  引擎规则与边界
    └── Kds.Api.Tests/       接口契约与幂等
```

**架构要点**：一个程序多角色（Master / Worker / Browser）；Worker 只跑 UI、**不碰数据库**；同订单哈希分片队列串行、跨订单并行；配置全在 Master `TerminalConfig`，终端只持只读缓存。

## 文档位置（PRD v6.99 定稿）

| 路径 | 内容 |
|---|---|
| `docs/Prd/KDS-README-文档索引.md` | **先读这个**——文件清单、按角色阅读路径、高频速查 |
| `docs/Prd/` | PRD 拆分版：00–13 号文件 + `schema/`（契约真值）+ `Json DSL/` + `prototype/` |
| `docs/Prd/schema/` | 契约 schema（入站 17 + 出站 9 = 26 事件），机器可读真值 |
| `docs/Design/` | 语言包 761 条、验收矩阵 M1–M15、审计 |

**改 PRD 规则**：只改拆分文件、不回首改合并版；口径冲突以 §1.6 D 表为准；变更只在 00 号文件追加一行。

## 关键口径（实现前必读，冲突以 PRD §1.6 为准）

| 编号 | 议题 | 口径 |
|---|---|---|
| D1 | 档口反选 | `(类型命中 AND NOT 黑名单) OR (类型未命中 AND 白名单)`，黑名单优先 |
| D2 | 流转 | 两层：总开关 `EnableWorkflowState` + `FlowMode`；触发**恒为屏上划单** |
| D3 | 合菜归集 | 按名字（不按 UID），`MergeKey` 由 7 项合并条件决定，默认全开 |
| D4 | 二态降级 | 关闭流转走「待出/已划单」二态 |
| D5 | 划单 | 品项到屏即可划单，**无接单步骤**；防重复靠广播+实时移除+乐观锁 |
| D10 | 卡片分组键 | 桌台视图按业务键 `(OrderId, TableId)`（一条关联=一卡），**禁字符串分组** |
| D12 | 契约方向 | KDS 定标准，POS 适配；不为 POS 改领域模型 |
| D13 | 行粒度 | 一行=一个 POS `LineNo`，不合并同品项多行；`RemainingQty=0` 才推进阶段 |
| D14 | 退菜 | 仅 POS 发起；部分完成 POS 选择性接受（`SupportsPartialComplete`） |

全表 17 条见 01 号文件 §1.6；状态 8 态见 03 号文件 §2.15。

## 命名强制（PRD §1.5）

- JSON/DB/C# 统一 **PascalCase**；表主键统一 `Uid`（GUID）；布尔 `Is/Enable/Has` 前缀；时间 `Time/At` 结尾（DB `datetimeoffset`）
- **领域命名中性**，禁止 POS 别名（`OrderInfo`/`BaseZhuoTai` 等一律禁用）
- 术语分层：技术文档=「品项」`DishItem`；界面=「菜品」/自然语言（判定规则见 §1.5）

## 常用命令

```bash
# 构建（CI 门禁：零警告；TreatWarningsAsErrors 对 Core/Workflow 生效）
dotnet build Kds.sln -c Release

# 测试（交付必须附原始输出，不接受截图/摘要）
dotnet test Kds.sln -c Release

# 契约 schema 校验（G1 构建门禁）
npx ajv-cli compile -s schema/inbound.schema.json -r schema/common.schema.json
npx ajv-cli compile -s schema/outbound.schema.json -r schema/common.schema.json
```

## 红线（PRD 写死，违反=返工）

1. **热路径不查库**：屏幕数据来自 Master 内存，推送过程 0 次 DB 查询（专项《数据库性能设计》）
2. 状态机推进走七步写路径；乐观锁用单条 UPDATE（`ExecuteUpdate`）
3. **契约号段只增不改**：`NotifyState`/`VoidReasonCode`/错误码永久固定
4. 入站 schema **严格**（`additionalProperties:false`）、出站**宽松**（`true`）
5. SQL Server 2008 不做；主代码**不允许 `if(isSql2008)` 分支**
6. 终端不直连数据库、不把配置存 localStorage

## 协作约定

- 只改任务卡指定的文件；动契约外文件先在卡上申请
- 核心模块（Kds.Core/Workflow）行覆盖 ≥70%；状态机/部分划单/MergeKey/档口反选/乐观锁/幂等 **每类至少 1 正 + 1 反用例**
- 干完一张卡，往 `.hermes/journal/<年>-<月>.md` 当天小节追加 3~5 行
- 一次只干一件事；重构与功能改动分开

## 变更记录

- `2026-11-02` PM 建立：读 PRD v6.99，建本文件；工作目录绑定 `/home/tommy/software/kds`
