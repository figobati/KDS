# 第七部分：接口设计

## 10. 接口契约

### 10.1 接口总览

**契约方向：本文定义的接口即标准，由 KDS 制定并版本化；POS / 第三方适配器向此契约适配**（§9.0）。

标准化 **HTTP + WebSocket 混合接口**，局域网推送：

| 方向 | 通道 | 用途 |
|------|------|------|
| POS / 适配器 → Master | HTTP POST（或 MQTT，可配） | 订单新增、修改、退单、赠菜、菜品修改（临时菜改名）、桌台同步 |
| Master → POS / 适配器 | HTTP POST / MQTT（出站回执） | 菜品状态回调、整单完成、报损、心跳、错误 |
| Master ↔ 终端 | WebSocket（SignalR Hub）+ REST | 配置拉取、全量拉取、增量推送、操作提交、心跳 |
| Master → 总部 | HTTPS / MQTT | 终态订单批量上报（V1 保留能力，报表端 V2） |

**松耦合原则**：POS 不感知 KDS 内部状态，只推送事件；KDS 通过回执告知结果。
**契约纪律**：不因单个 POS 的字段习惯改动本契约；个别差异在适配器内部消化（§9.0）。

### 10.2 统一事件信封（POS ↔ KDS）

```json
{
  "EventId": "3f1c0b7e-8a2d-4c19-9f5a-6b7c8d9e0f11",
  "EventType": "Order.Create",
  "PosSource": "SelfPos01",
  "StoreId": "STORE-001",
  "Timestamp": "2026-09-30T10:30:00+08:00",
  "ProtocolVersion": "1.0",
  "Payload": {}
}
```

| 字段 | 类型 | 必填 | 说明 |
|------|------|:----:|------|
| `EventId` | Guid | 是 | **幂等键**。重复投递（同 `EventId`）直接返回首次处理结果，不重复执行 |
| `EventType` | string | 是 | 事件类型，见 §10.3 |
| `PosSource` | string | 是 | POS 来源标识 |
| `StoreId` | string | 是 | 门店标识 |
| `Timestamp` | datetimeoffset | 是 | 事件发生时间（POS 时钟，仅用于排序与展示） |
| `ProtocolVersion` | string | 是 | 协议版本，当前 `1.0` |
| `Payload` | object | 是 | 业务载荷，结构由 `EventType` 决定 |

### 10.3 入站事件（POS → KDS）

| `EventType` | 说明 | 幂等语义 |
|-------------|------|----------|
| `Order.Create` | 新建订单（含全部明细） | 同 `EventId` 幂等；同 `PosOrderNo` 且未归档时**合并/更新**而非新建 |
| `Order.Update` | 改单（加菜 / 改备注 / 改数量 / 改规格） | 明细按 `LineNo` 匹配：存在则更新，不存在则新增。**加菜必须用新 `LineNo`**（§4.6.1）；同 `LineNo` 增大 `Qty` 视为改数量（记 `Warning`）。**联台期间加菜同样走本事件、`PosOrderNo` 不变**（联台即同一订单，v6.98），新增行**必须带 `SourceTableId`** 指明归属桌台 |
| `Item.Remove` | 退菜（**按份**，`Payload.Qty` = 本次退份数） | 幂等键 `EventId`；`CancelledQty` 累加；超退返回 `CANCEL_EXCEEDS_REMAINING`；整行退幂等（`CancelledQty = Qty` 后重复事件忽略） |
| `Item.Rename` | 临时菜改名 | 更新 `OrderDetail.DishName`（进行中明细），历史归档不改 |
| `Order.Cancel` | 整单取消 | 非终态明细全部置 `Cancelled`；已归档明细仅日志 |
| `Order.Remind` | 催菜 | 置 `IsRemind=1` |
| `Order.Rush` | 加急 | 置 `IsRush=1` |
| `Order.Hold` | 等叫（**订单级便捷事件**） | 置 `IsHold=1`、`OrderHeader.IsHeld=1`；**扇出**到该单全部非终态明细 → `NotifyState=30`、`HoldCount+1`、**已用时长归 0**（§2.16.3，**不是"暂停"**） |
| `Order.Release` | 起菜 / 取消等叫（**订单级便捷事件**） | 置 `IsHold=0`、`IsFire=1`；**扇出**到全部非终态明细 → `NotifyState=20`、`LastFireAt=OccurredAt`、**从 0 重新计时** |
| `Order.Split` | 拆单 / 并台 / **换桌**（桌台归属变更） | **重建或删除受影响 `OrderTableRel`**，并把受影响明细改挂到新关联（同时刷新 `TableNo` / `TableSortOrder` 快照）；换桌后卡片按新关联迁移，旧卡消失 |
| `Menu.Sync` | 品项基础资料同步（含 `StagePath`、`StageStandardSeconds`） | 按 `ItemCode` upsert；**不修改进行中订单的快照字段** |
| `DiningTable.Sync` | 桌台基础资料同步（**必须携带桌台 `Uid`**） | 按 `Uid` upsert；同步 `TableCode` / `SortOrder` / `AreaName` / 启停状态；同时刷新关联 `OrderTableRel` 的快照字段；**改桌号不触发明细重投影**（关联 UID 未变） |
| `Station.Sync` | 档口基础资料同步 | 按 `StationCode` upsert |
| **`Item.Notify`** | **通知单状态**（单菜级，`NotifyState` 序号）——⚠️ **方向是 POS → KDS**：POS 用它告诉 KDS"这道菜已下单 / 已起菜 / 等叫 / 已出品"，**不是 KDS 告诉 POS** | 幂等键 `EventId`；按 `OccurredAt` 后到者生效；**未知序号忽略 + 告警，不拒收**（§2.16.6）。POS 不支持（`SupportsNotify=false`）时 KDS 按"`Order.Create` 即起菜"处理（`NotifyState` 恒 `20`），见 §10.9 |
| **`Item.Void`** | **报损**（POS 发起，如客人退已出品菜） | `VoidQty ≤ CompletedQty − 已报损`，超出返回 `VOID_EXCEEDS_COMPLETED`；原因序号未知归 `99` |
| **`Staff.Sync`** | **员工同步**（POS → KDS） | 按 `ExternalId`/工号 upsert；**只同步身份，绝不同步密码**；POS 删人 → 停用 + **撤销会话**（§13.11.11） |
| **`Item.SoldOut`** | **沽清状态结果**（POS → KDS） | 菜单动作非订单动作，**`PosOrderNo` 可缺省**；`Items[]` 批量；每项 `Status`：`Active`（生效）/ `Rejected`（POS 否决）/ `Ended`（已恢复）；KDS 据此清掉"申请中"或"已沽清"标记（§2.18.3） |

> **`Order.Hold` / `Order.Release` 与 `Item.Notify` 的分工（v6.81 定稿）**
> | 事件 | 粒度 | 用途 |
> |------|------|------|
> | `Order.Hold` / `Order.Release` | **订单级** | POS 的"整桌起菜 / 整桌等叫"动作，**KDS 收到后扇出到每条未完成明细** |
> | `Item.Notify` | **单菜级** | 精确控制某一道菜（§2.16） |
> **覆盖规则**：两者都到达时**按 `OccurredAt` 后到者生效**；`HoldCount` **只在"从非等叫进入等叫"时 +1**（重复等叫不累加）。

| `Heartbeat` | POS 心跳 | 不落业务表，仅更新连接状态 |

**`Order.Create` Payload 示例：**

```json
{
  "PosOrderNo": "T20260930001",
  "TableUids": ["7f1a2b3c-0000-0000-0000-000000000001"],
  "TableNo": "A05",
  "OrderType": "DineIn",
  "GuestCount": 4,
  "IsSharedTable": false,
  "OrderCreateTime": "2026-09-30T10:30:00+08:00",
  "ScheduledTime": null,
  "Remark": { "zh-CN": "客人过生日" },
  "Items": [
    {
      "LineNo": 1,
      "ItemCode": "FOOD001",
      "DishName": { "zh-CN": "宫保鸡丁", "en-US": "Kung Pao Chicken" },
      "TypeName": { "zh-CN": "热菜", "en-US": "Hot Dishes" },
      "Spec": "标准",
      "Taste": "少辣",
      "Method": "爆炒",
      "Qty": 2,
      "IsGift": false,
      "TableId": "7f1a2b3c-0000-0000-0000-000000000001",
      "SpecialFlags": ["Allergy-Peanut"],
      "TargetStationIds": [],
      "IsComboItem": false,
      "ComboNo": null,
      "ComboName": null,
      "ComboSeq": null,
      "ComboItemTotal": null
    }
  ],
  "Ext": {}
}
```

> **每行明细必须带 `TableId`（堂食）**：Master 据此把明细挂到对应的 `OrderTableRel`（同 `OrderId + TableId` 复用同一条关联记录，不存在则创建）。`TableCode` 由 Master 从 `DiningTable` 取，**POS 不必传桌号字符串**。
> **只传桌号不传 `TableId` 的事件按校验失败处理**（`VALIDATION_FAILED`）——不允许"用桌号兜底匹配"，否则改桌号 / 同号桌必然错乱。
> `TargetStationIds` 为可选**指定档口**（覆盖 §2.2 反选推导结果）；为空时由 Master 按反选规则推导。
> **外卖单**：无桌台时 `TableId` 传 `Guid.Empty`（全零 GUID），**不允许传 `null`**——业务唯一键与分组键都要求它非空；挂了桌台的外卖单则传真实 `TableId`。
> **拼桌**：同桌已有进行中订单时，POS 必须显式传 `IsSharedTable = true`，否则返回 `TABLE_OCCUPIED`（防叠台）。
> **套餐（§2.12）**：POS 必须**展开成子项**，每条子项一个 `LineNo`，`Qty` **已乘套餐份数**；同一套餐的子项共享 `ComboNo` 并各带 `ComboName` / `ComboSeq` / `ComboItemTotal`；**不得推送"套餐本体行"**（Master 忽略并记 `COMBO_HEADER_IGNORED`）。

**入站处理要求（必须实现）**：

1. **幂等**：同 `EventId` 重复投递 → 返回首次结果，`EventLog.ProcessStatus = Ignored`；
2. **顺序**：同 `PosOrderNo` 事件进同一分片串行处理（§6）；跨订单并行；
3. **时钟**：一切时长以 Master `ReceivedAt` 为基准，`Timestamp` 仅用于排序；
4. **落库优先**：先写 `EventLog` 再执行业务，保证可重放；
5. **失败可重试**：业务失败返回明确错误码，POS 可安全重试（幂等保证不重复生效）。

### 10.4 出站回执（KDS → POS）

| `EventType` | 触发时机 | Payload 要点 |
|-------------|----------|--------------|
| `Item.Complete` | 某明细某阶段划单完成（含**部分完成**） | `PosOrderNo` / `LineNo` / `Stage` / **`CompletedQty`（本次份数）** / **`Qty`（整行份数）** / **`RemainingQty`** / **`IsFullComplete`** / `TerminalId` / **`StationId`（当前阶段主档口，§2.2.1）** / `CompletedAt` / `StageElapsedSeconds` |
| **`Item.Cancelled`** | **仅 KDS 主动取消**（跨日清理等）；**POS 发起的退菜不回执**（v6.99） | `PosOrderNo` / `LineNo` / **`CancelledQty`（本次退数）** / **`Qty`** / **`RemainingQty`** / **`IsFullCancel`** / `Reason` / `CancelledAt` |
| `Order.Done` | 整单全部明细到达终态 | `PosOrderNo` / `CompletedAt` / `TotalElapsedSeconds` |
| `Item.Void` | 报损 | `PosOrderNo` / `LineNo` / `Reason` |

> **`IsFullComplete` 怎么读（v6.99 补注）**：它**只表示"本次划单后该行还剩不剩份数"**——`RemainingQty = 0` → `true`，否则 `false`。**不是**"KDS 每次都宣告整单完成"。字段在 `outbound.schema.json` 中为 `required`，部分完成时也必须发，POS 不得静默丢弃（§10.9 `SupportsPartialComplete`）。同理 `IsFullCancel` 看 `RemainingQty`。

| `Heartbeat` | 定时 | `StoreId` / `SentAt` / 待发表积压数 |
| `Error` | 事件处理失败 | `EventId` / `ErrorCode` / `ErrorMessage` |
| **`Item.Undo`** | **撤销划单**（§2.19.6） | `PosOrderNo` / `LineNo` / **`UndoStage`**（被撤销的阶段）/ **`RestoredStage`**（回退到的阶段）/ `Qty` / `OccurredAt`；**越级撤销时中间跳过阶段不发事件**。⚠️ POS 不支持（`SupportsItemUndo=false`）时 **管理端 `EnableUndo` 强制禁用**（§10.9），不得单方面回退 |
| **`Item.UnableToCook`** | **沽清申请**（厨房做不了，请 POS 处理） | `PosOrderNo` / `LineNo` / `Reason` / `RequestedBy` / `RequestedAt`；**POS 收到后由服务员决定是否退菜**，KDS 不自行改数量。POS 不支持（`SupportsUnableToCook=false`）时**隐藏该按钮**（§10.9） |
| **`Item.SoldOutRequest`** | **沽清申请 / 沽清通知** | 菜单动作非订单动作，**`PosOrderNo` 可缺省**；**`Mode`**：`Request`（请 POS 确认后生效，对应 `PosConfirm`）/ `Notify`（KDS 已直接生效，请 POS 同步菜单，对应 `KdsDirect`）；`Items[]` 批量；`SoldOutType` / `LimitQty` / `EndAt` / `ReasonCode` / `RequestedBy`（§2.18.3） |

> **沽清为什么用两个事件**
> | 若合成一个 | 问题 |
> |---|---|
> | 出入站共用同名事件 | 适配器要按"我发的还是我收的"分支判断，易错 |
> | 只做出站申请、不收回执 | KDS 永远不知道"批准了还是拒了"，屏幕上的"申请中"消不掉 |
>
> **这两个事件的 `PosOrderNo` 是可选字段**——与其余入站/出站事件不同。因为沽清是**菜单动作**，不对应某一单；POS 方不要把它当成"漏填必填项"。

> ⚠️ **回执推断规则（POS 必须实现）**：KDS 在**手动流转模式（`FlowMode = Manual`，V2 实现）**下存在**越级完成**（§2.7.1 ②）；**V1 恒为 `Auto`，不存在越级完成**，POS 仍须实现该推断规则以兼容后续版本——例如制作屏直接把 `A` 状态的菜推到 `C`。此时 KDS **只发一条"当前阶段完成"**，**不补发前态回执**。
> **POS 侧约定**：**收到某阶段完成，即视为该阶段之前的所有阶段都已完成**；不得依赖逐级事件、不得因缺前态回执而判定"未完成"。这是对接验收项，写在契约测试用例中。

**`Item.Complete` 示例：**

```json
{
  "PosOrderNo": "T20260930001",
  "LineNo": 1,
  "DetailId": "a1b2c3d4-0000-0000-0000-000000000001",
  "Stage": "Cook",
  "TerminalId": "KDS-COOK-01",
  "StationId": "guid-station",
  "CompletedAt": "2026-09-30T10:35:12+08:00",
  "StagePrepSeconds": 312,
  "StageElapsedSeconds": 312
}
```

**可靠性要求（必须实现）**：

1. 回执**先落 `OutboxMessage` 再发送**（事务内），保证不丢；
2. 发送失败按 §9.14 指数退避重试，`IdempotencyKey = DetailId + Stage` 防重复；
3. 离线堆积上限（默认 10,000 条），超限告警并优先保留 `Order.Done`；
4. POS 不可达**不影响 KDS 业务**，仅积压在 Outbox。

### 10.5 终端 ↔ Master 接口

**SignalR Hub 地址与身份：**

```
/hub/KdsHub?terminalId=xxx&lang=en-US&deviceKey=xxx
```

> **鉴权（V1 必须）**：`deviceKey` 与 `TerminalConfig.DeviceKey` 比对，不匹配则拒绝连接（返回 `Unauthorized`）。无鉴权的局域网裸连等价于任何人可改单。

**Master → 终端 推送方法：**

| Hub 方法 | 说明 |
|----------|------|
| `OrderCreated` | 新菜品到达本屏 |
| `StageAdvanced` | 菜品推进到下一阶段（自动联动触发 / 手动划单推进） |
| `LineCompleted` | 某菜品某阶段划单 |
| `OrderUpdated` | 订单变更（改单 / 退菜 / 赠菜） |
| `OrderReminded` | 催菜 / 加急告警 |
| `OrderCancelled` | 订单取消 |
| `HoldChanged` | 等叫 / 起菜状态变更（携带 `NotifyState` 序号，§2.16） |
| `ConfigChanged` | 终端配置变更（带新 `ConfigVersion`，终端重载配置） |
| `RevisionGap` | 检测到 `Revision` 跳变，终端应主动全量拉取 |

> 推送内容已按屏幕配置**预筛选**（§2.10），菜品名 / 备注已按当前语言解析为单字符串（§9.16）。

**终端 → Master 调用：**

| Hub 方法 | Action | 说明 |
|----------|--------|------|
| `ReportAction` | `StageComplete` | 当前阶段划单 |
| `ReportAction` | `StageUndo` | **撤销一格**（`OperationLogUid` 定位操作记录），四条条件见 §2.19.1 |
| GET | `/api/Terminal/{terminalId}/MyOperations?businessDate=` | **【我的划单记录】抽屉**（§2.19.4）：默认**当前营业日**全量，含**当前状态**、实时可撤销判定与不可撤销原因 |
| GET | `/api/Terminal/{terminalId}/AllOperations?businessDate=` | **综合屏专用**（§2.19.11）：只读查看**全店**当日划单记录（无撤销按钮） |
| `ReportAction` | `OrderDone` | 整单出餐 |
| `ReportAction` | `ItemNotify`（带 `NotifyState` 序号） | 通知单状态变更（等叫 / 起菜 / 出品…，§2.16.7） |

> **划单动作只有 `StageComplete`**（无 `StageAccept`）：终端不需要接单，划单即完成。

```json
{
  "Action": "StageComplete",
  "OrderId": "guid-order",
  "DetailId": "guid-detail",
  "Stage": "Cook",
  "Version": 3,
  "ClientEventId": "guid-client",
  "OccurredAt": "2026-09-30T10:35:12+08:00"
}
```

> `ClientEventId` 为**客户端幂等 ID**（离线补发去重）；`Version` 为客户端已知的明细版本号，用于乐观锁冲突检测。

**`Poll` 返回示例（三种情形）：**

```json
// a. 无变化（绝大多数轮询，响应体极小）
{ "RevChanged": false, "ServerRevision": 10241, "ServerNow": "2026-09-30T10:35:12+08:00" }

// b. 窗口内增量
{
  "RevChanged": true, "ServerRevision": 10288, "ServerNow": "...",
  "UpsertDetails": [ { "DetailId": "guid", "Version": 4, "WorkflowStage": "Cook", "StageStatus": "Completed", "...": "..." } ],
  "DeletedDetails": ["guid-detail-2"],
  "UpsertHeaders": [ { "OrderId": "guid", "Version": 2, "...": "..." } ],
  "RequiredFullSync": false
}

// c. 差异过大 / Revision 缺失 → 终端应立刻全量
{ "RevChanged": true, "ServerRevision": 10288, "RequiredFullSync": true, "ServerNow": "..." }
```

**REST 接口：**

| 方法 | 路径 | 说明 |
|------|------|------|
| POST | `/api/Terminal/Bind` | **终端首次绑定 / 重装重绑**：入参 `TerminalCode` + 管理员口令 → 返回 `TerminalId` + `DeviceKey`（终端本地保存，§5.1） |
| GET | `/api/Terminal/{terminalId}/Config` | 拉终端配置（角色、绑定档口、视图、联动、语言包、超时阈值、`ConfigVersion`、`IsEnabled`） |
| GET | `/api/Terminal/{terminalId}/ActiveItems` | 拉当前本屏全量菜品（初始化 / 重连 / 轮询要求全量），返回 `Revision` 与 `ServerNow` |
| GET | `/api/Terminal/{terminalId}/Poll?sinceRevision={n}` | **本机轻量轮询**（§2.10.2）：无变化只返回 `RevChanged=false`；窗口内返回增量；窗口外返回 `RequiredFullSync=true` |
| POST | `/api/Terminal/{terminalId}/Heartbeat` | 心跳：上报 `LastAppliedRevision` + `AppliedConfigVersion`；Master **只更新内存中的在线状态与已应用版本**（`LastHeartbeatAt` / `LastAppliedRevision` **不落库**，§5.1 / §9.2） |
| POST | `/api/Terminal/{terminalId}/Action` | 操作提交（含离线补发，语义同 `ReportAction`） |
| GET | `/api/Admin/Stations` | 档口列表 |
| PUT | `/api/Admin/Stations/{stationId}` | 档口配置（含角色、反选规则、超时阈值） |
| POST | `/api/Admin/Stations/{stationId}/MatchPreview` | **档口匹配可视化预览**（反向）：给定档口，列出它当前能接哪些品项 |
| GET | `/api/Admin/Routing/Trace?itemCode={code}` | **品项可见性追溯**（§2.11.1）：给定品项，按阶段返回命中档口、接收屏幕与规则来源 |
| GET | `/api/Admin/Routing/SelfCheck` | **路由自检**（§2.11.2）：全量扫描，返回问题清单（含严重度、影响品项数） |
| GET | `/api/Admin/Routing/Matrix?keyword=&typeIds=&stationIds=&role=&onlyAbnormal=&page=` | **全品项路由总表**（§2.11.4）：分页返回品项 × 档口三态（`Active` / `Skipped` / `None` / `ActiveNoScreen`） |
| GET | `/api/Admin/Routing/Matrix/Export` | 导出 CSV（当前筛选条件下的全量结果） |
| GET | `/api/Print/Jobs?terminalId=&max=` | **执行端领取打印任务**（原子 claim + 租约，§16.6） |
| POST | `/api/Print/Jobs/{jobId}/Result` | 执行端回执：`Success` / `Failed` + 错误码 + 耗时 |
| GET | `/api/Admin/Print/Printers` | 打印机列表与在线状态 |
| POST | `/api/Admin/Print/Printers/{id}/Test` | **打印测试页 / 连通性自检**（§16.7） |
| POST | `/api/Admin/Print/Preview` | **模板预览**（按模板 + 样例数据渲染成 PNG，所见即所打） |
| GET | `/api/Admin/Print/Jobs` | 打印记录查询（时间 / 状态 / 打印机 / 终端 / 桌号） |
| POST | `/api/Admin/Print/Jobs/{jobId}/Reprint` | **补打**（新建 `PrintIndex + 1` 任务，需 `EnableReprint` 权限） |
| GET | `/api/Admin/Print/SelfCheck` | 打印自检（连通性 / 无执行端 / 规则缺打印机 / 编码 / 积压 / DeadLetter） |
| GET | `/api/Admin/I18n/SelfCheck` | **语言包自检**（§11.7）：各语言 key 差集、占位符不匹配、空值、无效覆盖 |
| GET | `/api/Admin/Health/SelfCheck` | **统一健康检查出口**：汇总路由 / 打印 / 语言包三类自检结果（统一 `Code` / `Level` / `Category` 模型） |
| GET | `/api/Admin/Config/Snapshot/Export` | **导出配置快照**（`ConfigSnapshot.json`，剔除 `DeviceKey` 等敏感字段，§11.7.6） |
| POST | `/api/Admin/Config/Snapshot/Import` | 导入配置快照（用于 CI / 新店复制参考配置；需冲突确认） |
| GET | `/api/Admin/Health/SelfCheck/Report` | 导出自检报告（CSV / PDF，供现场签收留档） |
| GET | `/api/Admin/Outbox/Stats` | **Outbox 监控**：按状态/目标分组计数 + 最老滞留时长（§9.14.1） |
| POST | `/api/Admin/Outbox/Replay` | **死信批量重放**（筛选条件 → 重置为 `Pending`，上限 500 条/次） |
| POST | `/api/Admin/Outbox/{id}/Close` | 单条死信人工关闭（置 `Sent` 并记原因） |
| GET | `/api/Admin/Reports/Daily?from=&to=&dim=` | **运营报表查询**：当日走明细实时算，历史查 `DailyStoreStat` / `DailyDimStat`（§13.6.3） |
| GET | `/api/Admin/Archive/List` | 归档文件列表（按月，含日期区间、行数、大小） |
| GET | `/api/Admin/Archive/Query?posOrderNo=` | **历史查询**：自动挂载对应月份归档库（只读 ATTACH）按单号 / 桌台检索 |
| POST | `/api/Admin/Archive/Export` | 按日期区间导出归档数据（CSV / NDJSON，供财务核对） |
| GET | `/api/Admin/Hq/Stats` | **云端上报统计**（§14.2.8）：待传/成功/失败/死信、最老滞留、能力协商结果 |
| POST | `/api/Admin/Hq/Test` | 测试云端连通性 + 能力协商（配置页"测试连通性"按钮） |
| POST | `/api/Admin/Hq/Resend` | 手动补传（按日期区间 / 数据类型，上限 1,000 条/次） |
| GET | `/api/Admin/Reports/Dashboard` | **报表首页聚合**：KPI（出品/退单/催单/超时）+ 较前 7 营业日对比 + 4 个 Top10 榜单（§13.6.7） |
| GET | `/api/Admin/Reports/Details?type=&from=&to=&mealPeriod=&keyword=&page=&export=` | **五类明细表**（`Cancel` / `Remind` / `Timeout` / **`Void`（报损）** / 通用），含**全量合计行**、跨归档自动切换、`export=csv` 全量导出 |
| GET | `/api/Admin/VoiceTemplates` | **语音模板列表**（§3.5.4）：按场景 × 语言，含内置默认值 |
| PUT | `/api/Admin/VoiceTemplates/{kind}/{lang}` | 保存模板（**强校验变量白名单**，超 60 字仅警告） |
| POST | `/api/Admin/VoiceTemplates/Preview` | **试播**：样例数据渲染 + 可选实际出声，不落库 |
| GET | `/api/Admin/CrossDay/List?mode=Open\|Closed` | **跨营业日未完成清单**（§2.14.4）：按挂的天数排序 |
| POST | `/api/Admin/CrossDay/Close` | 批量清理（置 `Closed` + 记原因 + 回执 POS `Item.Cancelled`） |
| POST | `/api/Admin/CrossDay/Resume` | **恢复**被清理的明细回原阶段（误清兜底，不物理删除） |
| GET / PUT | `/api/Admin/Items/{itemUid}/StagePath` | 查询 / 设置品项流转路径 |
| POST | `/api/Admin/Items/BatchStagePath` | 批量设置品项流转路径（按品类） |
| GET / PUT | `/api/Admin/Terminals/{terminalId}` | 终端配置读写 |
| GET / PUT | `/api/Admin/StoreConfig` | 门店配置读写（流转双开关等） |
| GET | `/api/Admin/Health` | 健康检查（DB / Outbox 积压 / 连接数） |
| GET | `/api/Admin/Logs` | 操作日志 / 事件日志查询 |

**`Config` 返回示例：**

```json
{
  "TerminalId": "guid-terminal",
  "TerminalType": "Station",
  "Role": "Cook",
  "StationIds": ["guid-station-1", "guid-station-2"],
  "BaseGroupMode": "TableMode",
  "DefaultView": "BaseGroupView",
  "ItemView_SortMode": "TableFirst",
  "SingleView_SortMode": "WaitDuration",
  "SingleView_HideCancelled": false,
  "Merge_DiffOrder": true,
  "Merge_DiffFlavor": true,
  "Merge_DineInTakeaway": true,
  "Merge_ComboAndNormal": true,
  "Merge_Timeout": true,
  "Merge_Rush": true,
  "Merge_Hold": true,
  "Merge_LinkedTable": false,
  "Merge_LinkedTable_CrossArea": false,
  "ItemView_DetailMode": "SinglePortion",
  "TableView_SortMode": "TableOrder",
  "EnableOperate": true,
  "EnableVoice": true,
  "EnableWorkflowState": true,
  "FlowMode": "Auto",                  // Auto（V1 唯一）/ Manual（设计保留，V2）
  "CurrentLang": "en-US",
  "ConfigVersion": 7,
  "UiPack": { "NewOrder": "New Order", "Complete": "Complete" },
  "TotalTimeoutSeconds": 1200,
  "WarnRatio": 0.8,
  "Sync": {
    "PollingIntervalSeconds": 15,
    "PushSilenceSeconds": 30,
    "DataStaleSeconds": 90,
    "RevisionHistorySize": 300,
    "ServerRevision": 10241
  }
}
```

### 10.6 错误码表

| 错误码 | HTTP | 含义 | 处理建议 |
|--------|:----:|------|----------|
| `OK` | 200 | 成功 | — |
| `DUPLICATE_EVENT` | 200 | 事件已处理（幂等命中） | 视为成功，勿重试 |
| `VALIDATION_FAILED` | 400 | 载荷校验失败 | 修正后重试 |
| `QTY_EXCEEDS_REMAINING` | 409 | 本次划单份数超过剩余份数 | 刷新后按 `RemainingQty` 重试 |
| `QTY_STEP_MISMATCH` | 400 | 份数不符合 `QtyStep`（如 0.5 步长传了 0.3） | 按步长重新提交 |
| `WEIGHED_ITEM_NOT_SPLITTABLE` | 409 | 称重菜不允许分份划单 / 部分退 | 必须整行处理 |
| `CANCEL_EXCEEDS_REMAINING` | 409 | 退菜份数超过剩余待制作份数（已出品的份不可退，应走报损） | 刷新后按 `RemainingQty` 重试 |
| `DETAIL_CLOSED` | 409 | 该明细已被跨营业日清理（`WorkflowStage = Closed`） | 需先在管理端【恢复】才能操作（§2.14.3） |
| `UNDO_WINDOW_EXPIRED` | 409 | 撤销时间窗已过（`UndoWindowSeconds`，默认 **120s**，可调 30~1800） | 刷新历史列表，该行已不可撤 |
| **`UNDO_STATE_ADVANCED`** | 409 | **该明细状态已被推进**（不再是本操作产生的状态），不能跳状态撤销（§2.19.1） | 越界保护：只能撤"未被越过的那一格" |
| `UNDO_ALREADY_REVERTED` | 409 | 该操作已被撤销过一次 | 刷新后重试 |
| `UNDO_CONFLICT` | 409 | 该明细在此期间被他人修改（`Version` 变化） | 刷新后确认最新状态 |
| `ORDER_NOT_FOUND` | 404 | 订单不存在 | 检查 `PosOrderNo` |
| `DETAIL_NOT_FOUND` | 404 | 明细不存在（退菜 / 改单无法定位） | 检查 `LineNo` / `DetailId` |
| `STAGE_MISMATCH` | 409 | 阶段不匹配（如已推进到 Cook 却提交 Prep 完成） | 终端应刷新全量 |
| `DETAIL_ALREADY_COMPLETED` | 409 | 明细该阶段已完成 | 视为成功并刷新 |
| `VERSION_CONFLICT` | 409 | 乐观锁冲突 | 刷新该条明细后重试 |
| `DETAIL_CANCELLED` | 409 | 已退菜，禁止划单 | 刷新并提示 |
| `TABLE_OCCUPIED` | 409 | **叠台**：该桌台已有进行中订单，且事件未声明拼桌 | POS 确认是否为拼桌（`IsSharedTable=true`）后重推 |
| `TERMINAL_NOT_ALLOWED` | 403 | 终端无划单权限（`EnableOperate=false`） | 隐藏按钮，勿提交 |
| `TERMINAL_NOT_BOUND` | 403 | 终端未绑定该档口 | 检查终端配置 |
| `UNAUTHORIZED` | 401 | `deviceKey` 无效 | 重新绑定终端 |
| `TERMINAL_DISABLED` | 403 | 终端已在管理端停用（`IsEnabled = 0`） | 屏上提示"本终端已被停用，请联系管理员" |
| `WORKFLOW_DISABLED` | 409 | 流转未开启却提交阶段操作 | 降级为二态划单 |
| `INTERNAL_ERROR` | 500 | 服务内部错误 | 可重试（幂等保证） |

### 10.7 并发与一致性要求（V1 必须实现）

| 场景 | 要求 |
|------|------|
| 多终端同时划同一明细 | 乐观锁（`OrderDetail.Version`）：`UPDATE ... WHERE DetailId=@id AND Version=@v`，影响行数 0 → 返回 `VERSION_CONFLICT` |
| 批量划单部分失败 | 返回**逐条结果数组**：`{ DetailId, Qty, Success, ErrorCode, ErrorMessage }`；前端按条回滚显示，**不做整体事务回滚**（避免一条冲突导致整批失败） |
| **部分划单并发（两屏同时划同一条的不同份数）** | 乐观锁 `OrderDetail.Version`：`UPDATE ... SET CompletedQty = CompletedQty + @q, Version = Version + 1 WHERE DetailId=@id AND Version=@v AND CompletedQty + @q <= Qty`。影响行数 0 → 返回 `VERSION_CONFLICT` 或 `QTY_EXCEEDS_REMAINING`（按失败原因区分），前端刷新后重试 |
| **部分划单幂等** | 以 `ClientEventId` 去重；重复到达不得重复累加 `CompletedQty`（离线补发场景必现） |
| **部分划单与退菜竞态** | 退菜累加 `CancelledQty` 后若 `RemainingQty = 0`，任何划单请求返回 `DETAIL_CANCELLED`；划单与退菜同源乐观锁，先提交者生效 |
| **部分退菜并发** | 条件更新：`UPDATE ... SET CancelledQty = CancelledQty + @q, Version = Version + 1 WHERE DetailId=@id AND Version=@v AND CompletedQty + CancelledQty + @q <= Qty`；影响行数 0 → `VERSION_CONFLICT` 或 `CANCEL_EXCEEDS_REMAINING` |
| 广播模式并发划单 | 双方都能看到 → 乐观锁（`OrderDetail.Version`）判定，后到者返回 `VERSION_CONFLICT` 并收到 `LineCompleted` 推送自动移除该行 |
| 屏幕关机 / 断网 | 广播模式下**天然无影响**：其他屏都持有同一份菜品，继续可做（这正是广播相对指派模式的容错优势） |
| 重复投递 | `EventLog.EventId` 唯一索引 + 处理前查重 |
| **叠台（同桌多单）** | 新建 `OrderTableRel` 前查 `IX_OrderTableRel_Table (TableId, Status='Active')` 且 `TableId <> Guid.Empty`：<br>• 命中且事件 `IsSharedTable = true`（拼桌）→ 允许，新建一条关联；<br>• 命中且未声明拼桌 → 拒绝，返回 `TABLE_OCCUPIED`；<br>• 未命中 → 正常新建。**并发下由业务唯一键 `UX_OrderTableRel_Order_Table (OrderId, TableId)` 兜底**，捕获冲突后重查 |
| **同订单同桌台重复建关联** | 业务唯一键 `UX_OrderTableRel_Order_Table (OrderId, TableId)`；重复事件复用已有记录，不新建 |
| 乱序投递 | 同订单分片串行；`Revision` 单调递增，终端丢弃旧序号消息 |
| 断电 / 重启恢复 | 未完成明细状态与时长按墙钟继续；`Outbox` 未发送项启动后继续重试；`Revision` 从库中最大值继续递增 |
| 时钟漂移 | 一切时长以 Master 时钟为准；`ServerNow` 随全量拉取与 `Poll` 下发给终端用于本地自增校准 |
| Worker 本地缓存 | 断网只读；重连后**全量替换**本地视图（不做增量合并），保证权威一致 |
| 推送与轮询同时到达 | 终端按 `DetailId` upsert 应用，重复收到同一变更不产生重复行（幂等，§2.10.4-6） |
| 漏推自愈 | 本机轮询以 `Revision` 比对发现落后 → 补增量；窗口外 → 全量；详见 §2.10 |

---


### 10.8 管理端 / 认证 / 运维接口补充清单（**v6.95 新增**）

> **为什么补这一节**：§10.5 的 REST 表只覆盖"终端 ↔ Master"与部分管理端查询，**认证、账号、初始化向导、沽清、主数据启停、备份监盘六类端点缺席**——而 UI 清单 B-01/B-02/B-09/B-10/B-14/B-15/B-16/B-20/B-21/B-22 都是 V1 屏，没有契约就没法并行开发。本节按**屏号一一对应**补齐，与 §10.5 合计构成完整 REST 清单。
> **计数口径**：一个"方法 + 路径"算一条。§10.5 表内 `GET / PUT` 合并行按 2 条计。

#### 10.8.1 认证与会话（§13.11；A-01 / B-01 / B-15）

| 方法 | 路径 | 对应屏 | 说明 |
|:---|:---|:--:|:---|
| POST | `/api/Auth/Login` | B-01 | 管理端账号登录（`UserName` + `Password`）→ 返回会话令牌 + 角色。失败按 `LoginLockoutCount` 锁定 |
| POST | `/api/Auth/DeviceLogin` | A-01 | **屏无感登录**：`{ deviceToken, terminalCode, deviceKey }` → 换发新令牌（轮转，旧令牌立即作废）；失败返回具体原因码（`TOKEN_EXPIRED` / `SESSION_REVOKED` / `ACCOUNT_DISABLED` / `TERMINAL_MISMATCH`） |
| POST | `/api/Auth/ScreenLogin` | A-01 | 屏**首次登录**（账号 + PIN 或密码）→ 返回 `TerminalId` + `DeviceKey` + 首个 `deviceToken`；此后走 `DeviceLogin` |
| POST | `/api/Auth/Logout` | 两端 | 撤销当前会话（`UserSession.RevokedAt`）。**这是唯一需要重新登录的动作**（§13.11.3），禁止"假退出" |
| GET | `/api/Auth/Me` | 两端 | 当前身份、角色、权限位（`CanOperate` / `CanManageUndo` / `CanConfig`） |
| POST | `/api/Auth/ChangePassword` | 两端 | 自助改密（校验旧密码 + 口令策略 §13.11.8）；成功后**该账号其他会话全部失效** |
| GET | `/api/Admin/Sessions` | B-15 | 在线会话列表（终端/账号/类型/最后活动/到期） |
| DELETE | `/api/Admin/Sessions/{sessionUid}` | B-15 | **强制下线**（仅 `Owner`；Manager 只读） |
| POST | `/api/Admin/Terminals/{terminalId}/ResetDeviceKey` | B-08 | 重置设备密钥（换机 / 重装 / 疑似泄漏）→ 该终端所有屏会话立即失效 |

#### 10.8.2 账号与员工（§13.11.10；B-14）

| 方法 | 路径 | 说明 |
|:---|:---|:---|
| GET | `/api/Admin/Users?accountType=&role=&keyword=&page=` | 账号列表（管理账号 + 屏账号两类同表 §9.15d） |
| POST | `/api/Admin/Users` | 新建账号（初始密码强制首登修改） |
| PUT | `/api/Admin/Users/{uid}` | 修改账号（姓名/角色/启停/是否上花名册）；**停用即撤销该账号全部会话** |
| DELETE | `/api/Admin/Users/{uid}` | 删除（软删；有历史操作记录时只允许停用） |
| POST | `/api/Admin/Users/{uid}/ResetPassword` | 重置密码（`Owner` 权限；返回一次性初始密码） |
| POST | `/api/Admin/Users/SyncFromPos` | **从 POS 拉员工**（`StaffSource` / `PosRoleMapJson`，§13.11.11）；返回新增/更新/停用条数 |
| GET | `/api/Admin/LoginLogs?from=&to=&userName=&success=` | 登录日志（失败/锁定排查） |

#### 10.8.3 初始化向导（§13.12；B-02 / C-01）

| 方法 | 路径 | 说明 |
|:---|:---|:---|
| GET | `/api/Admin/Setup/Status` | 是否已初始化 + 已完成到第几步（未初始化时前端强制跳向导） |
| POST | `/api/Admin/Setup/TestDb` | 数据库连通性与权限自检（`DbSetup.exe` 同款检测项 §13.10.3） |
| POST | `/api/Admin/Setup/Init` | 写入门店信息 + 首个 `Owner` 账号 + `StoreConfig` 默认值（**幂等**：已初始化则返回 `ALREADY_INITIALIZED`） |
| POST | `/api/Admin/Setup/Complete` | 收尾：建种子数据（默认档口/打印模板/语言包校验）+ 标记初始化完成 |

#### 10.8.4 沽清（§2.18；B-16）

| 方法 | 路径 | 说明 |
|:---|:---|:---|
| GET | `/api/Admin/SoldOuts?businessDate=&status=` | 沽清记录（`SoldOutLog`：类型/限量/原因/申请审批/营业日） |
| POST | `/api/Admin/SoldOuts` | 发起沽清。按 `SoldOutMode` 分流：`PosConfirm` → 置 `Requested` 等 POS 确认；`KdsDirect` → 直接生效；`PosOnly` → 拒绝（`SOLD_OUT_POS_ONLY`） |
| POST | `/api/Admin/SoldOuts/{uid}/Approve` | 审批通过（`Requested` → `Active`） |
| POST | `/api/Admin/SoldOuts/{uid}/Release` | 恢复售卖（`Active` → `Released`，记 `EndAt`） |

#### 10.8.5 主数据只读与启停（B-09 / B-10）

> 主数据权威在 POS（`Menu.Sync` / `DiningTable.Sync` / `Station.Sync` 入站推送，§10.3）；管理端只做**查看与启停**，不新增/改价格——避免两套主数据打架。

| 方法 | 路径 | 说明 |
|:---|:---|:---|
| GET | `/api/Admin/DishItems?typeId=&keyword=&enabled=&page=` | 品项列表（含类型、售卖模式、超时阈值、沽清状态） |
| GET | `/api/Admin/DishTypes` | 品类树（含 `ParentTypeId` 层级） |
| GET | `/api/Admin/DiningTables?area=&keyword=` | 桌台列表（含区域、排序号、启用状态） |
| PUT | `/api/Admin/DishItems/{uid}/Enabled` | 启停品项（`IsEnabled`；正在制作的订单不受影响） |
| PUT | `/api/Admin/DiningTables/{uid}` | 修改桌台展示属性（排序号 / 区域 / 别名；**不改 `TableCode`**，它是 POS 对齐键） |

#### 10.8.6 运维：备份 / 监盘 / 诊断（B-20 / B-21 / B-22）

| 方法 | 路径 | 说明 |
|:---|:---|:---|
| GET | `/api/Admin/Db/Status` | 数据库只读检测（引擎/版本/文件大小/页数/碎片率/最后备份时间，§13.10.3） |
| POST | `/api/Admin/Backup` | 触发备份（SQLite 在线备份 API / SQL Server BACKUP），返回文件路径与校验和（§13.8） |
| POST | `/api/Admin/Restore` | 还原（**需二次确认 + Owner 口令**；执行前强制自动备份当前库） |
| GET | `/api/Admin/Diagnostics/Package` | 生成诊断包（配置快照 + 近期日志 + 自检报告 + 库状态，敏感字段脱敏，§13.9.1） |

#### 10.8.7 终端侧补充

| 方法 | 路径 | 说明 |
|:---|:---|:---|
| PUT | `/api/Terminal/{terminalId}/Config` | **屏端设置页保存**（A-12 / A-13，§17.6）：只允许改本屏可改的槽位（列数/行数/字号档/排序/开关）；越权字段返回 `FORBIDDEN_FIELD`。保存后 `ConfigVersion` 递增 |
| GET | `/api/Admin/CallLogs?businessDate=&tableId=` | 叫号记录（`CallLog`：桌号/渲染文本/播报结果/冷却判定），用于排查"没叫出声" |

> **计数（v6.95 实测，以本表为准）**：§10.5 **50 行**（其中 3 行为 `GET / PUT` 合并 → 53 条方法）+ §10.8 **35 行**（无合并 → 35 条方法）= **REST 85 个端点 / 88 条方法**；Hub 推送方法 **9 个**（§10.5）。README 与 13 号文件的接口口径以此为准，勿再沿用旧的"46 个"。

---

### 10.9 POS 能力声明表（对接必填，v6.99 新增）

> **为什么需要这张表**：附录 B-11 / B-12 / B-13 的本质都是"**POS 侧能力不一致**"。与其在文档里反复猜"POS 支不支持"，不如让 POS 在对接时**显式声明**，KDS 按声明**自动降级或禁用功能**——功能要么真能用，真不能用就在界面上藏掉，绝不出现"按了没反应"或"账实不符"。

**声明位置**：适配器配置（`PosAdapterConfig.Capabilities`），管理端「POS 对接」页展示与编辑；**未声明的项按"不支持"处理**（保守优先，宁可少功能不可错账）。

| # | 能力键 | 含义 | 支持的后果 | **不支持的降级** |
|:-:|:---|:---|:---|:---|
| 1 | `SupportsPartialComplete` | 能否按份记账（`IsFullComplete=false`） | 每次划单 POS 立即按份更新出餐状态 | **POS 自行累计**份数，直到整行为 `true`（§4.7.3 方案 B）；KDS 侧无变化 |
| 2 | `SupportsNotify` | 能否发**入站** `Item.Notify`（通知单状态） | KDS 完整支持起菜 / 等叫 / 出品状态与计时 | **KDS 按"已下单即起菜"处理**：`NotifyState` 恒为 `20`，不计"等叫"；`Order.Hold` / `Order.Release` 一并失效（本就不发） |
| 3 | `SupportsItemUndo` | 能否接收**出站** `Item.Undo`（撤销划单） | 撤销后 POS 出餐状态退回一格 | ⚠️ **管理端 `EnableUndo` 强制置灰并提示"POS 不支持撤销"**——不允许 KDS 单方面回退，否则 POS 认定已出餐、账单与出品账实不符 |
| 4 | `SupportsUnableToCook` | 能否接收**出站** `Item.UnableToCook`（做不了，请 POS 处理） | 屏上「做不了」按钮可用，POS 弹给服务员决定是否退菜 | **隐藏「做不了」按钮**；厨房改用沽清申请（若 #5 支持）或口头通知服务员。**KDS 不会静默改数量**，故不影响账务 |
| 5 | `SupportsSoldOut` | 能否收发沽清事件（`Item.SoldOutRequest` ↔ `Item.SoldOut`） | 沽清可推 POS、状态可回传 | 沽清**只在 KDS 侧生效**（屏上标"已沽清"），不通知 POS 菜单；`KdsDirect` 模式不可用，仅 `PosConfirm` 降级为本地提示 |
| 6 | `VoidReasonByKds` | 报损原因由谁填（§2.17.4） | — | 本项 **V1 恒为 `true`（由 KDS 填）**；POS 发 `Item.Void` 时 `VoidReasonCode` 可缺省；若 POS 主动填了合法序号，KDS 直接采用 |

**降级原则（三条）**

1. **能不藏就不藏，藏了要说明**——降级导致功能消失时，管理端配置页必须显示原因（如"该功能需 POS 支持撤销事件"），不能让运维以为是自己配错了。
2. **账务相关的降级必须"禁用"而非"降质"**——#3 撤销 是唯一必须**禁用**的项：让用户在屏上撤销、KDS 本地回退、POS 却认为已出餐，是最坏的组合。宁可没有撤销功能。
3. **未声明 = 不支持**——避免"以为支持"。

> **与附录 B 的关系**：本表落地后，附录 B-11 / B-12 / B-13 三条**全部关闭**——它们问的"POS 接不接受"，现在由 POS 自己填表回答，而且是**逐项独立**的，不再需要一个笼统的"支不支持新增事件"。

