# KDS 契约 Schema（POS 对接用）

> 版本：**v1.0**（对应文档 v6.81）　依据：§10 接口契约 / §2.16 通知单状态 / §2.17 报损 / §13.11.11 员工同步
> **本目录是 POS 契约的机器可读真值**。文档（`.md`）说明"为什么"，schema（`.json`）说明"允不允许"。

---

## 1. 文件清单

| 文件 | 内容 | 谁看 |
|------|------|------|
| `EVENT-INVENTORY.md` | **事件清点表**（**入站 17 + 出站 9 = 26**）+ 缺口记录 | 双方架构师 |
| `common.schema.json` | 信封、枚举号段、共用类型、错误码闭集 | 双方开发 |
| `inbound.schema.json` | POS → KDS 的 **17** 个事件载荷 | **POS 方必读** |
| `outbound.schema.json` | KDS → POS 的 **9** 个事件载荷 | **POS 方必读** |

---

## 2. 三个使用约定（不遵守会在联调时踩坑）

### ① 校验分两层：**schema 管格式，业务层管语义**

| 层 | 校验什么 | 失败表现 |
|----|----------|----------|
| **Schema**（本目录） | 字段存在性、类型、格式、精度、闭集枚举 | **拒收整条报文**（`VALIDATION_FAILED`） |
| **业务层** | 跨字段不变量（`VoidQty ≤ 已出品`）、状态可达性、幂等、号段未知值 | **按 §2.16.6 忽略并告警**，不拒收 |

> **典型例子**：`NotifyState` 在 schema 里只约束 `integer ≥ 0`，**不写 `enum`**。
> 因为 POS 升级先于 KDS 时会推 `35` 这种预留值，设计上要求"**忽略 + 告警 + 不崩**"（§2.16.6）；若 schema 用 `enum` 卡死，就会变成"整单被拒"，比不认这个状态更糟。

### ② 未知字段的容忍度**按方向不同**

| 方向 | `additionalProperties` | 理由 |
|------|:----------------------:|------|
| **入站（POS → KDS）** | **`false`**（严格） | POS 多发字段说明理解有偏差，早发现比晚发现好 |
| **出站（KDS → POS）** | **`true`**（宽松） | KDS 加字段不应打断 POS；POS 忽略未知字段即可 |

> 这是**故意不对称**的：入站从严、出站从宽。若某 POS 确实需要带私有字段，走 `Payload.Extra`（预留 `object`），**不要塞到顶层**。

### ③ 时钟：**时长一律用 Master 的接收时间**

- 报文里的 `Timestamp` / `OccurredAt` 只用于**排序与展示**；
- 若 `OccurredAt` 与 Master 时间**偏差 > 5 分钟**，KDS 记 `POS_CLOCK_SKEW` 告警并**改用接收时间**（防止 POS 时钟错乱导致全屏误报超时）。

---

## 3. 怎么用（POS 方）

### 3.1 离线校验（推荐在适配器开发期就接）

```bash
# 必带 -r 注册被引用的 common.schema.json
npx ajv-cli validate -s schema/inbound.schema.json -r schema/common.schema.json -d your-event.json
npx ajv-cli validate -s schema/outbound.schema.json -r schema/common.schema.json -d your-receipt.json

# Python（jsonschema 自动处理同目录 $ref）
python -m jsonschema -i your-event.json schema/inbound.schema.json
```

### 3.2 生成代码

| 语言 | 工具 | 命令 |
|------|------|------|
| C# | `NJsonSchema` | `dotnet njsonschema schema/inbound.schema.json -o Models.cs` |
| Java | `jsonschema2pojo` | `jsonschema2pojo -s schema/inbound.schema.json` |
| TypeScript | `json-schema-to-typescript` | `npx json-schema-to-typescript schema/inbound.schema.json` |

> **生成的代码只是脚手架**。契约测试用例集（见 §5）才是验收门槛。

### 3.3 契约测试（交付前必须全过）

| # | 用例 | 期望 |
|:-:|------|------|
| 1 | 同 `EventId` 重复投递 | 返回首次结果，**不重复落库** |
| 2 | 乱序投递（`Timestamp` 倒序） | 按业务规则正确处理，不覆盖较新状态 |
| 3 | 必填缺失 | `VALIDATION_FAILED`，**带字段名** |
| 4 | 拼桌（一桌多单） | 正常合并展示，不串单 |
| 5 | 联台（一单多桌） | 组卡正确，撤台只影响对应关联 |
| 6 | 换桌（`Order.Split`） | 卡片迁移，旧卡消失 |
| 7 | 退菜（整行 / 按份） | `CancelledQty` 正确累加；超退返回 `CANCEL_EXCEEDS_REMAINING` |
| 8 | 驳回部分退（POS 不支持时） | 必须显式声明降级策略，**不允许静默丢弃** |
| 9 | 通知单状态链路 `10→20→30→20→40` | **计时在第二次起菜时归零重算**（§2.16.3） |
| 10 | 通知单状态推预留值（如 `35`） | **忽略 + 告警，不拒收** |
| 11 | 报损（入站）超额 | `VOID_EXCEEDS_COMPLETED` |
| 12 | 员工同步（离职） | 账号停用 + **会话立即失效** |
| 13 | 员工角色未映射 | **该人不同步** + `POS_ROLE_UNMAPPED` |
| **14** | **沽清申请被 POS 否决** | 入站 `Item.SoldOut`（`Status=Rejected`）→ 屏幕"申请中"标记清除，菜品仍可点 |
| **15** | **`KdsDirect` 模式直接沽清** | 出站 `Item.SoldOutRequest`（`Mode=Notify`）→ 本地已生效，POS 同步菜单 |
| **16** | **限量沽清卖完第 N 份** | `Status` 自动转 `Active`、`EndReason=LimitReached`，并推 POS |
| **17** | **`UntilTime` 沽清跨营业日** | 自动失效（`EndReason=CrossDay`），**昨天的"卖完了"不影响今天** |
| **18** | **沽清期间又推来该菜的新单** | **接受 + 标黄 `ITEM_SOLDOUT`**，**绝不静默拒单** |
| **19** | **沽清与退菜不联动** | 点沽清后已点的单**照常制作**；要取消必须另发 `Item.Remove` |
| **20** | **联台期间加菜**（v6.98） | `Order.Update` 带**新 `LineNo`** + `SourceTableId` → **同一 `OrderId`** 下新增行、挂到对应桌台关联，**组卡不裂**；缺 `SourceTableId` 时按空 GUID 兜底并记 `Warning` |
| **21** | **联台加菜误用旧 `LineNo`** | 同 `LineNo` 改数量（`Qty` 增大）→ 更新原行、**不新增行**，记 `Warning`（§4.6.1） |
| **22** | **部分完成降级声明**（v6.99） | POS 声明 `SupportsPartialComplete=false` → KDS 仍发 `IsFullComplete=false`，POS **累计**至整行为 `true`；**不得静默丢弃**，否则整行永远等不到 `true` |
| **23** | **POS 不支持撤销**（v6.99） | `SupportsItemUndo=false` → 管理端 `EnableUndo` **强制置灰**、屏上不渲染撤销入口；**禁止** KDS 单方面回退（防账实不符） |
| **24** | **报损原因由 KDS 填**（v6.99） | POS 发 `Item.Void` **不带** `VoidReasonCode` → KDS 接受并落 `0 未指定`，操作人在管理端补选原因后报表可按原因分组 |

---

## 4. CI 集成（KDS 侧）

```yaml
# 并入 G1 构建门禁（§11.7.6）
- name: Validate event schemas
  run: |
    npx ajv-cli compile -s schema/inbound.schema.json -r schema/common.schema.json
    npx ajv-cli compile -s schema/outbound.schema.json -r schema/common.schema.json
- name: Validate fixtures
  run: |
    npx ajv-cli validate -s schema/inbound.schema.json  -r schema/common.schema.json -d "schema/fixtures/inbound/*.json"
    npx ajv-cli validate -s schema/outbound.schema.json -r schema/common.schema.json -d "schema/fixtures/outbound/*.json"
```

| 门禁 | 检查 |
|------|------|
| **G1 构建** | schema 本身语法合法 + 每个事件的 `fixtures` 样例能通过校验 |
| **G2 发布** | 有新增/改名事件但 `EVENT-INVENTORY.md` 未同步 → **失败** |
| **G3 现场** | 用 POS 真实报文回放 `fixtures`（可选） |

---

## 5. 变更规则

| 变更类型 | 版本 | 要求 |
|----------|------|------|
| 新增**可选**字段 | `1.x` | POS 忽略未知字段即可，**无需改代码** |
| 新增**必填**字段 | `1.x`（需公告） | **提前一个版本周期并行支持** |
| 新增事件类型 | `1.x` | 未实现方**忽略未知 EventType**（不要报错崩） |
| 删除字段 / 改语义 / 改类型 | **`2.0`** | 破坏性变更，必须并行支持旧版 |

> **号段只增不改**：`NotifyState` / `VoidReasonCode` / 错误码，一经发布**永久固定**。重排会让已对接的 POS 全部错位（§2.16.1）。
