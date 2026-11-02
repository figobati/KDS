# 事件契约清点表（Schema 编写前置）

> 版本：v6.81　依据：§10.2 信封 / §10.3 入站 / §10.4 出站 / §2.16 / §2.17 / §4.7.2 / §13.11.11
> 用途：**写 schema 之前先把"到底有哪些事件"钉死**。本表是 schema 的唯一来源。
> 状态：✅ **4 处缺口已全部确认并回填**（缺口 ① 选 **方案 A**）；``schema/inbound.schema.json`` 与 ``schema/outbound.schema.json`` 已据此生成。

---

## 1. 入站事件（POS → KDS）：**17 个**

| # | `EventType` | 说明 | 定义位置 | 状态 |
|:-:|---|---|---|:--:|
| 1 | `Order.Create` | 新建订单（含全部明细） | §10.3 | ✅ |
| 2 | `Order.Update` | 改单（加菜/改备注/改数量/改规格） | §10.3 | ✅ |
| 3 | `Item.Remove` | 退菜（按份） | §10.3 / §4.7.2 | ✅ |
| 4 | `Item.Rename` | 临时菜改名 | §10.3 | ✅ |
| 5 | `Order.Cancel` | 整单取消 | §10.3 | ✅ |
| 6 | `Order.Remind` | 催菜 | §10.3 | ✅ |
| 7 | `Order.Rush` | 加急 | §10.3 | ✅ |
| 8 | ~~`Order.Hold`~~ | 等叫 | §10.3 | ⚠️ **见缺口 ①** |
| 9 | ~~`Order.Release`~~ | 起菜/取消等叫 | §10.3 | ⚠️ **见缺口 ①** |
| 10 | `Order.Split` | 拆单/并台/**换桌** | §10.3 | ✅ |
| 11 | `Menu.Sync` | 品项基础资料同步 | §10.3 | ✅ |
| 12 | `DiningTable.Sync` | 桌台基础资料同步 | §10.3 | ✅ |
| 13 | `Station.Sync` | 档口基础资料同步 | §10.3 | ✅ |
| 14 | **`Item.Notify`** | **通知单状态**（`NotifyState` 序号） | §2.16.7 | ⚠️ **§10.3 未收录** |
| 15 | **`Staff.Sync`** | **员工同步**（POS → KDS） | §13.11.11 | ⚠️ **§10.3 未收录** |
| 16 | **`Item.Void`（入站）** | **报损**（POS 发起，如客人退已出品菜） | §4.7.2 / §2.17.4 | ✅ 已补 |
| **17** | **`Item.SoldOut`** | **沽清状态结果**（POS → KDS：生效/拒绝/恢复） | §2.18.3 / §10.3 | ✅ 已补 |

## 2. 出站事件（KDS → POS）：**9 个**

| # | `EventType` | 触发时机 | 定义位置 | 状态 |
|:-:|---|---|---|:--:|
| 1 | `Item.Complete` | 某明细某阶段划单完成（含部分完成） | §10.4 | ✅ |
| 2 | `Item.Cancelled` | 退菜（含部分退） | §10.4 | ✅ |
| 3 | `Order.Done` | 整单全部明细到终态 | §10.4 | ✅ |
| 4 | `Item.Void` | 报损（KDS 管理端发起） | §10.4 | ✅ |
| 5 | `Heartbeat` | 定时 | §10.4 | ✅ |
| 6 | `Error` | 事件处理失败 | §10.4 | ✅ |
| 7 | **`Item.Undo`** | **撤销划单**（`UndoStage` + `RestoredStage`） | §2.19.6 | ⚠️ **§10.4 未收录** |
| 8 | **`Item.UnableToCook`** | **沽清申请**（厨房做不了，请 POS 处理） | §4.7.2 | ✅ 已补 |
| **9** | **`Item.SoldOutRequest`** | **沽清申请 / 沽清通知**（`Mode`：`Request`/`Notify`） | §2.18.3 / §10.4 | ✅ 已补 |

> **总计：入站 17 + 出站 9 = 26 个事件**（§10.3/§10.4 最初只写了 13 + 6 = 19，**此前漏 5 个**，本次再补 **2 个沽清事件**）。

---

## 3. 4 处缺口：**已全部确认并回填**

> ⚠️ **另发现第 5 处缺口（v6.83 发现 / v6.84 补齐）**：§2.18 的沽清流程依赖 **2 个事件**（出站 `Item.SoldOutRequest`、入站 `Item.SoldOut`），但 §10.3 / §10.4 与最初的 24 个清单**都没有收录**。已补入，现为 **入站 17 + 出站 9 = 26 个事件**。详见 §3.5。

### 缺口 ① `Order.Hold` / `Order.Release` 与 `Item.Notify` 冲突 → ✅ **采纳方案 A**

**回填结果**（已写入 §10.3）：

| 事件 | 粒度 | 语义（v6.81 定稿） |
|------|------|------|
| `Order.Hold` / `Order.Release` | **订单级便捷事件** | KDS 收到后**扇出**到该单全部非终态明细：`Order.Hold` → `NotifyState=30`、`HoldCount+1`、**已用时长归 0**（不是"暂停"）；`Order.Release` → `NotifyState=20`、`LastFireAt=OccurredAt`、**从 0 重新计时** |
| `Item.Notify` | **单菜级精确控制** | 直接写 `NotifyState`（§2.16） |

**覆盖规则**：两者都到达时**按 `OccurredAt` 后到者生效**；`HoldCount` **只在"从非等叫进入等叫"时 +1**（重复等叫不累加）。

> **为什么选 A**：POS 的"整桌起菜"是常见动作，要求它循环发 N 条明细事件不友好；而"只让一道菜等叫、其他先做"也是真实需求。A 两个都满足，代价只是多一条扇出规则。

### 缺口 ② 入站 `Item.Void` 缺失 → ✅ 已补

| 方向 | 含义 | 关键字段 |
|---|---|---|
| 入站（POS → KDS） | **告知 KDS**"这份菜已作废" | `LineNo` / `VoidQty` / **`VoidReasonCode`** / `VoidRemark` / `OccurredAt` |
| 出站（KDS → POS） | **告知 POS**"我在管理端把这份菜作废了" | 同上 + `VoidedBy` / `VoidedAt` |

### 缺口 ③ `Item.Notify` / `Staff.Sync` 未收录 §10.3 → ✅ 已补

### 缺口 ④ `Item.Undo` / `Item.UnableToCook` 未收录 §10.4 → ✅ 已补

### 缺口 ⑤（v6.83 发现 / v6.84 补齐）**沽清的 2 个事件缺失** → ✅ 已补入 §10 与 schema

| 事件 | 方向 | 语义 | 关键字段 |
|------|:----:|------|----------|
| **`Item.SoldOutRequest`** | **出站**（KDS → POS） | 厨房申请沽清：**请把这道菜从菜单关掉** | `DishItemId`/`ItemCode` · `SoldOutType`（`UntilManual`/`UntilTime`/`LimitedQty`） · `LimitQty` · `EndAt`（`UntilTime` 时） · `ReasonCode` · `Remark` · `RequestedBy` · **`Mode`**（`Request`=请确认 / `Notify`=我已生效请同步，对应 `KdsDirect`） |
| **`Item.SoldOut`** | **入站**（POS → KDS） | POS 的沽清状态结果 | `DishItemId`/`ItemCode` · **`Status`**（`Active`/`Rejected`/`Ended`） · `SoldOutType` · `LimitQty` · `StartAt` · `EndAt` · `EndReason` · `ReasonCode` · `ApprovedBy` |

**为什么是两个事件而不是一个**

| 若合成一个 | 问题 |
|---|---|
| 出站入站共用 `Item.SoldOut` | 同一名字两个方向，适配器要按"我发的还是我收的"分支判断，易错 |
| 只做出站申请、不收回执 | KDS 无法知道"申请是被批准了还是被拒了"，屏幕上的"申请中"永远消不掉 |

> **`Mode = Notify` 的用途**：`SoldOutMode = KdsDirect` 时，KDS 点沽清**立即本地生效**，同时用 `Item.SoldOutRequest`（`Mode = Notify`）告知 POS"我已经关了，请同步菜单"。语义从"请求"变成"通知"，但仍走同一事件类型——**避免为一种模式再造一个事件**。

---

## 4. 写 schema 前必须一起钉死的 6 条约束

| # | 约束 | 出现在哪些事件 | schema 表达方式 |
|:-:|---|---|---|
| 1 | **`EventId` 幂等**（同 ID 重复投递返回首次结果） | 全部入站 | 信封必填 `uuid`；**语义靠服务端**，schema 只保证格式 |
| 2 | **`OccurredAt` vs `Timestamp`** | `Item.Notify` / `Item.Void` 用 `OccurredAt`；其余用信封 `Timestamp` | **统一**：schema 里两者都允许，但**时长计算一律用 `OccurredAt`（缺则回落 `Timestamp`）** |
| 3 | **`IsFullComplete` / `IsFullCancel` 必填** | `Item.Complete` / `Item.Cancelled` | 出站 schema **`required`**，漏了直接 schema 报错 |
| 4 | **`NotifyState` 只接受号段值** | `Item.Notify` | `enum: [0,10,20,30,40,50,60,70]`（**预留值不在 enum 内** → 未知值走"忽略 + 告警"而非 schema 拒绝） |
| 5 | **`VoidQty ≤ CompletedQty − 已报损`** | 入站 `Item.Void` | 跨字段断言，**schema 表达不了** → 放"不变量断言"清单，由契约测试覆盖 |
| 6 | **金额与数量精度** | 全部 | `decimal(18,3)` 数量、`decimal(18,4)` 金额 → schema `multipleOf: 0.001` / `0.0001` |

> **第 4 条要特别注意**：schema 的 `enum` 会把"POS 推了预留值（如 35）"判为非法，而设计上是"**忽略但记录告警、不崩**"（§2.16.6）。所以 **`NotifyState` 在 schema 里只约束 `type: integer` + `minimum: 0`，不写 `enum`**；号段校验放在**业务层**（这样未知值才能被"忽略"而不是"拒收整单"）。

---

## 5. 进度

| 步 | 内容 | 状态 |
|:-:|---|:--:|
| 1 | 确认 §3 的 5 处缺口（缺口 ① 选 **A**） | ✅ |
| 2 | 回填 §10.3 / §10.4 事件表（补 7 个事件、修正 Hold/Release 语义） | ✅ |
| 3 | 生成 `common.schema.json` + `inbound.schema.json` + `outbound.schema.json` | ✅ |
| 4 | 接 G1 构建门禁 + 契约测试用例集 + `fixtures/` 样例 | ⏳ 待做 |

### 已生成的 schema 文件

| 文件 | 事件数 | 说明 |
|------|:------:|------|
| `common.schema.json` | — | 信封、号段枚举、`DishLine`、`SoldOutTarget`、错误码闭集 |
| `inbound.schema.json` | **17** | `oneOf` 判别联合，`EventType` 用 `const` 锁定 |
| `outbound.schema.json` | **9** | 同上；`additionalProperties: true`（出站宽松） |

> **下一步（P0-A 剩余部分）**：① 为每个事件写一份 `fixtures/*.json` 合法样例 + 一份非法样例；② 接进 G1 门禁（`ajv-cli` 或 `NJsonSchema`）；③ 与 §9.0 的契约测试用例集对齐（13 条）。

