# PricePolicyDSL —— 价格策略 JSON DSL v1 规格（商品取价）

> **状态：v1 规格（2026-09-29 收窄重写）✅ 阶段 A/B 已实现（2026-09-29 晚，用户「改写 ProductOperator 的 getprice 方法，逻辑为从 SysTenantExtension 取 PricePolicy，有匹配返回相应价格，没有匹配返回原始价格」）**：纯引擎 2026-09-29 落新类库 `Com.AiServe.Pricing`（§14.1），`ProductOperator.GetPrice` 已接线走引擎；验收 A1-A13 + P0-P10b 全过（探针 `.asr-test/BusinessProbe/`，证据 probe-run.txt）。**2026-09-30 落点修订（用户「不需要这个单独的项目，所有代码并入 Business」）**：独立类库已删，引擎并入 `Com.AIServe.Handlers.Business/Pricing/`（命名空间 `Com.AIServe.Handlers.Business.Pricing[.Models]`），行为零变化（探针复跑 61/61 全过，证据 probe-run-after.txt）。阶段 C（生成端）已先行完成 = `PricePolicyService`（docs/PricePolicyService.md）。
> 父文档 [`PricePolicy.md`](PricePolicy.md) 是需求与论证（为什么生成 JSON 不是 C#、50ms 性能口径、表达力边界、会员与购物车级的完整模型）。
> **本文只回答：策略 JSON 长什么样、每个字段什么语义、怎么求值、怎么校验、怎么回译给店长。**

## 0. 范围（2026-09-29 用户口径）

**v1 = 商品 × 条件 → 一个单价。** 表达「同一个菜在不同日期 / 时间 / 星期 / 节假日下取不同价」。

| | 在范围内 | 说明 |
|---|---|---|
| 商品维度 | ✅ | 单个商品（`dishUids`）或一批（`categories` / `tags`） |
| 时间维度 | ✅ | 星期 / 时段（含跨午夜）/ 固定日期 / 节假日标签 |
| 取价动作 | ✅ | 打折 / 固定价 / 减额 |
| **会员** | ❌ **整个不在引擎内** | 上下文里**没有**任何会员字段；引擎输出的是**非会员基础成交价**，会员折扣由程序另外的地方计算，谁先谁后、是否叠加由调用方决定 |
| 数量 qty | ❌ 「下一档」 | 第二份半价（按份分段）、按行减额 |
| 整单 / 购物车 | ❌ 「下一档」 | 满减、摊分（P2/P3） |
| 赠品 | ❌ 「下一档」 | |
| 审计留痕 | ❌ | 引擎只输出求值结果 + 命中规则 id；审计由外部调用方负责（用户 2026-09-11 口径） |

**三条硬约束不变**：缓存是准入条件、禁止请求路径惰性构建（版本变更 → 后台构建 → 原子换引用）、求值纯函数零 I/O。
求值配额 **< 1ms，硬上限 5ms**（父文档 §3：按钮点单「点菜 → 取数 → 加购物车 < 50ms」）。

**一句话契约边界**：引擎算的是**执行价格**（`listPrice` 经策略之后的成交单价），它**不知道会员存在**；做法加价、规格加价在进入引擎前已折算进 `listPrice`。

---

## 1. 结构总览

```
策略文档 (Policy Document)        ← 一个门店一份，版本化
  └─ 规则 Rule[]                  ← id / 开关 / 互斥组 / 优先级 / 条件 / 动作
       ├─ 条件 when = 条件树（all/any/not + 叶子谓词）
       └─ 动作 then = 闭集动作之一（3 型）
```

求值输入输出也是 JSON（`PriceContext` → `PriceQuote`），见 §7。
**词表封闭**：条件是 7 个字段的谓词代数，动作是 3 个算子；新增一项需 ≥3 个真实需求支撑（父文档 §4.4 纪律 1）。

---

## 2. 策略文档

```json
{
  "schemaVersion": 1,
  "storeId": 182801,
  "revision": 7,
  "validFrom": null,
  "validTo": null,
  "rules": [ /* Rule[]，见 §3 */ ]
}
```

| 字段 | 必填 | 类型 | 语义 |
|---|---|---|---|
| `schemaVersion` | ✅ | int | 契约版本，当前恒 `1`。不认识的值 → **拒绝加载**（不猜） |
| `storeId` | ✅ | int | **作用域唯一来源**。规则级不设 storeId（两处作用域会互相矛盾且不可回译） |
| `revision` | ➖ | int | 版本号，装配器缓存 key 的一部分；缺省由存储层生成 |
| `validFrom` / `validTo` | ➖ | date / null | 整包档期。**在加载/校验期判断**（不在求值热路径）：不在档期 = 整包不加载，等同空策略 |
| `rules` | ✅ | Rule[] | 可为空数组（= 无任何优惠，全部按 `listPrice`） |

**多店 / 集团模板**：v1 不支持（一店一文档）。届时另立「模板 + 门店覆盖」两层，而不是把作用域塞进规则。

---

## 3. 规则对象

```json
{
  "id": "R-WEEKEND-HOT-89",
  "label": "周末热菜 8.9 折",
  "enabled": true,
  "group": "weekend",
  "priority": 100,
  "when": { "days": ["sat", "sun"], "categories": ["热菜"] },
  "then": { "type": "discountRate", "rate": 0.89 }
}
```

| 字段 | 必填 | 类型 | 语义 |
|---|---|---|---|
| `id` | ✅ | string | 文档内唯一，`[A-Za-z0-9_-]{1,32}`。回译、求值结果、界面展示都靠它 |
| `label` | ✅ | string | **中文短名**（≤30 字）。回译基准，用于与回译结果交叉校验（§9） |
| `enabled` | ➖ | bool | 默认 `true`。关掉的规则参与校验但不参与求值 |
| `group` | ✅ | string | **互斥组名**（kebab-case）。同组内只生效 `priority` 最高的一条 |
| `priority` | ✅ | int 0..9999 | 大者优先。**同组同 priority = 校验错误**（不许靠 id 排序蒙混） |
| `when` | ✅ | 条件树 | `{}` = 恒真（"这个商品的所有情况"）。见 §4 |
| `then` | ✅ | 动作 | 见 §5 |

**`group` 必填且无默认值**——强制作者回答"这条与谁互斥"。想表达"可叠加"就把两条放**不同组**（§6.2 的链式施加）。

---

## 4. 条件语法 `when`

### 4.1 组合子（布尔闭包）

```json
{ "all": [ /* 条件 */ ], "any": [ /* 条件 */ ], "not": { /* 条件 */ } }
```

- 三个键**可同时存在**，彼此是 **AND** 关系：`all ∧ any ∧ ¬not`
- `all: []` = 恒真；`any: []` = 恒假（校验器对后者**告警**——几乎总是笔误）
- 嵌套深度 ≤ 5（防生成端堆出无法回译的怪物）

### 4.2 叶子谓词

叶子形如 `{ "<字段>": <谓词> }`，**同一个对象里多个字段 = 隐式 AND**：

```json
{ "days": ["sat", "sun"], "categories": ["热菜"] }      // 周六或周日，且是热菜
```

### 4.3 字段表（7 个）

| 类别 | 字段 | 谓词形态 | 语义 |
|---|---|---|---|
| 时间 | `days` | 集合：`["sat","sun"]` \| `{"in":[…]}` \| `{"notIn":[…]}`。取值 `mon..sun` | 周几，任一命中。**由 `now` 派生**，调用方不重复传 |
| 时间 | `time` | 段数组：`[["11:00","14:00"],["22:00","02:00"]]`（任一命中）。单段可写 `["11:00","14:00"]` | **半开区间 `[起, 止)`**：`11:00–14:00` 不含 `14:00` 整——相邻段（如 `14:00–17:00`）不会双命中。**起 > 止 = 跨午夜** |
| 时间 | `dates` | 集合：`["2026-10-01"]` \| `{"in":[…]}` \| `{"notIn":[…]}`，格式 `YYYY-MM-DD` | 固定日期（店庆/开业），**不依赖节假日日历** |
| 时间 | `dateTags` | 集合：`["holiday"]` \| `["workday"]` \| `["spring-festival"]` | **装配器查节假日日历解析成标签**，引擎只做集合判定（日历是外部数据、一年一维护，不进引擎） |
| 范围 | `dishUids` | 集合：`["<32位hex>"]`（任一） | 商品 UID。做法组合点 / 规格行在库里各有独立 uid，同样适用 |
| 范围 | `categories` | 集合：**分类 UID** `["0f742fe074b04a11b172a4c22f6e8f8c"]`（任一） | 装配器拿 `BaseDish.TypeID` 直接比对。⚠️ **载荷里必须是 UID**（§13-2 已定）；中文名只在**输入侧**（模型/人手写）出现，生成/保存时由服务端解析成 UID |
| 范围 | `tags` | 集合：`["酒水","招牌"]` | 商品标签。⚠️ 来源待确认（§13-3）——**装配器填不出来时，含 `tags` 的规则在加载期被拒**，绝不静默填空集 |

**集合谓词的四种写法**：

```json
{ "categories": ["热菜", "凉菜"] }              // 任一（= in）
{ "categories": { "in": ["热菜"] } }            // 同上的显式写法
{ "categories": { "notIn": ["酒水"] } }         // 不含任一
{ "tags": { "all": ["酒水", "进口"] } }         // 同时包含全部
```

> 上面为**输入侧**写法（中文名，便于阅读）；**落库/交付给引擎的文档里 `categories` 一律是分类 UID**（§13-2 已定：名字→UID 的解析是生成/保存服务端的职责，回译时再由渲染器查表映射回中文名）。

**日期 / 星期 / 时段三者正交**：`days` 是"每周六日"，`dates` 是"这一天"，`dateTags` 是"任何节假日"，`time` 是"每天的这个时段"——组合写进 `all` 即 AND：

```json
{ "all": [ { "days": ["sat","sun"] }, { "time": [["11:00","14:00"]] } ] }   // 周末午市
```

**典型写法**（"周六日的热菜 8 折，酒水除外"）：

```json
{ "all":  [ { "days": ["sat","sun"] }, { "categories": ["热菜"] } ],
  "not":  { "tags": ["酒水"] } }
```

---

## 5. 动作语法 `then`（闭集 3 型）

| 动作 | 字段 | 语义 |
|---|---|---|
| `discountRate` | `rate` ∈ [0,1] | 按**当前价** × rate。⚠️ 8.9 折写 `0.89`——写 `89` 校验期直接拒（拦住最常见的静默错价） |
| `fixedPrice` | `price` ≥ 0 | 覆盖为固定价（每份价格，无第二种口径） |
| `discountAmount` | `amount` ≥ 0 | 每份减 `amount`，不低于 0 |

```json
{ "type": "discountRate",   "rate": 0.89 }
{ "type": "fixedPrice",     "price": 9.9 }
{ "type": "discountAmount", "amount": 2 }
```

**刻意没有 `per` 字段**：本阶段上下文里没有 qty，"每份/每行"无从区分；等数量维度进来时 `per` 才成为必填（那时它正是"减 5 元"歧义的落点）。
**宁缺勿滥**——格式里不放引擎算不出来的字段。

---

## 6. 求值算法

### 6.1 步骤

1. **候选**：文档在档期（加载期已判）+ 规则 `enabled` + 商品维度命中（`dishUids` / `categories` / `tags`）
2. **判条件**：规则内所有条件 AND；`any` 提供 or
3. **冲突解决**：同组取一 → 跨组链式（§6.2）
4. **依次施加**（§6.3）
5. **结算**：`decimal.Round(x, 2, MidpointRounding.AwayFromZero)`（与现有 `ApplyPriceRule` 一致），下限 0
6. **输出**：`price` + `appliedRuleIds[]`（顺序 = 施加顺序）

### 6.2 冲突解决：同组互斥 + 跨组链式

- **同 `group` 只生效 `priority` 最大者**——"取最高档、不累加"就靠这条（同组同 priority 在**校验期**已报错）
- **不同组按 `(priority desc, id asc)` 依次施加 = 可叠加**：周末 8 折 + 节假日 8.9 折同时命中 → `×0.8×0.89`

**叠加必须是作者的显式选择**：想排斥就放进同一组。这条把"两条规则撞车时怎么办"变成一个**能被回译、能被店长确认**的结构，而不是靠代码里的施加顺序。

### 6.3 施加语义

```
state = 输入单价（listPrice）

discountRate   → state = Round(state × rate, 2)
fixedPrice     → state = price                     // 覆盖；之后若有规则继续，从它之上算
discountAmount → state = Max(0, state − amount)
```

### 6.4 ⚠️ 条件判定一律基于**原始输入价**，不看前序规则改写后的价

否则又会出现"A 先跑就命中、B 先跑就不命中"的顺序依赖（父文档 §5 要挡的正是这个）。
即：第 5 条规则的 `when` 判定，与它在链上排第几无关。

### 6.5 性能

- **规则预编译**：文档解析一次 → 编译成强类型规则树，缓存 key = `(storeId, revision)`；**禁止在请求路径上解析 JSON**（父文档 §3 硬约束 2）
- 求值只做：条件判定（集合/数值/时间比较）+ 几次乘法 → 远低于 1ms

---

## 7. 输入与输出 JSON

### 7.1 `PriceContext`（求值输入，**值对象，纯输入零 I/O**）

```json
{
  "storeId": 182801,
  "now": "2026-09-29T12:30:00",
  "dateTags": ["workday"],
  "dishUid": "02c850049ee94f6d9672e4c81d69adf1",
  "category": "凉菜",
  "tags": [],
  "listPrice": 18.00
}
```

- `now` = **门店本地墙钟**（不带时区）。`dayOfWeek` / `date` **由引擎从 `now` 派生**（纯函数）——少一个能填错的字段
- `dateTags` 由装配器查节假日日历得出（**I/O 在装配器**）
- `listPrice` = 商品的当前基准价（`SalePrice`；做法/规格加价已折算进来）
- `category` 由装配器解出（`BaseDish.TypeID` 与 `categories` 里的 **UID** 直接比对；名字→UID 已在上游解析掉，见 §13-2）；`tags` 见 §13-3
- **没有任何会员字段**（§0）

### 7.2 `PriceQuote`（求值输出）

```json
{
  "dishUid": "02c850049ee94f6d9672e4c81d69adf1",
  "listPrice": 18.00,
  "price": 16.00,
  "appliedRuleIds": ["R-LUNCH-COLD-M2"]
}
```

- `price` = 成交单价（**非会员价**；会员折扣在其后由别处施加）
- `appliedRuleIds` 是求值副产品（界面显示"本价格来自：周末热菜 8.9 折"）。**不是审计**（§0）

---

## 8. 校验（生成时 + 加载时都要跑）

**闭集检查**：任何未知字段 / 未知 `type` / 未知 `field` → **拒绝**，不做向后兼容的宽容解析。

| # | 检查 | 例子 |
|---|---|---|
| 1 | 字段名闭集（7 条件字段 / 3 组合子 / 3 动作型 / 规则元字段） | `"weekdays"` → 拒绝（应为 `days`） |
| 2 | 动作字段闭集与数值域：`rate ∈ [0,1]`、`price/amount ≥ 0`、`priority ∈ [0,9999]` | `rate: 89`（应为 0.89） |
| 3 | `id` 唯一；`group` 非空（kebab-case）；**同组同 `priority`** | 两条 `weekend/100` |
| 4 | `days` 取值闭集 `mon..sun` | `"monday"` → 拒绝 |
| 5 | `time`：`HH:mm` 格式、起 ≠ 止、**同规则内段重叠告警**；跨午夜（起>止）合法 | `["11:00","11:00"]` |
| 6 | `dates`：`YYYY-MM-DD` 格式合法 | `"2026/10/1"` |
| 7 | 嵌套深度 ≤ 5；`any: []` 告警（恒假） | |
| 8 | 装配器能力核对：装配器填不出来的字段（如标签）出现在规则里 → **拒绝加载该文档** | 不静默填空集 |

**校验失败 → 保留上一版策略**（不顶掉上一版好策略），新版本进草稿态等人工确认。

**不进 schema 的外部约束**：商品/分类 UID 是否存在、`MinZheKou` 最低折扣钳制（§13-1）、沽清、权限——它们在装配器 / 保存侧兜。

---

## 9. 回译（中文渲染，**确定性，不用 LLM**）

每条规则必须能渲染成店长看得懂的中文；**渲染不出来的规则不许进 DSL**（父文档 §4.4 纪律 2）。时段要显式写出半开边界——"歧义必须落成显式文字"。

```
R-WEEKEND-HOT-89 周末热菜 8.9 折          [组 weekend · 优先级 100]
  当：每周六或周日 且 分类属于「热菜」
  则：按当前价 8.9 折（× 0.89）

R-LUNCH-COLD-M2 午市与夜宵凉菜每份减 2 元  [组 lunch · 优先级 50]
  当：11:00–14:00（不含 14:00）或 22:00–次日 02:00（不含 02:00）
  则：每份减 2 元（不低于 0）

R-HOLIDAY-PEANUT-99 节假日椒盐花生米 9.9 元  [组 holiday · 优先级 200]
  当：节假日 且 商品是「椒盐花生米」
  则：固定价 9.9 元
```

交叉校验：生成端同时给出 `label` 与 JSON → 渲染器从 JSON 产出中文 → **`label` 与渲染首行不一致 → 进人工确认**（防"JSON 写的是 9 折、label 写的是 8 折"这类静默错价）。

---

## 10. 完整示例与走查

```json
{
  "schemaVersion": 1, "storeId": 182801, "revision": 7,
  "rules": [
    { "id": "R-WEEKEND-HOT-89", "label": "周末热菜 8.9 折", "group": "weekend", "priority": 100,
      "when": { "days": ["sat","sun"], "categories": ["热菜"] },
      "then": { "type": "discountRate", "rate": 0.89 } },

    { "id": "R-LUNCH-COLD-M2", "label": "午市与夜宵凉菜每份减 2 元", "group": "lunch", "priority": 50,
      "when": { "any": [ { "time": [["11:00","14:00"]] },
                         { "time": [["22:00","02:00"]] } ] },
      "then": { "type": "discountAmount", "amount": 2 } },

    { "id": "R-HOLIDAY-PEANUT-99", "label": "节假日椒盐花生米 9.9 元", "group": "holiday", "priority": 200,
      "when": { "dateTags": ["holiday"], "dishUids": ["02c850049ee94f6d9672e4c81d69adf1"] },
      "then": { "type": "fixedPrice", "price": 9.9 } },

    { "id": "R-ANNIV-80", "label": "店庆日全场 8 折", "group": "anniversary", "priority": 300,
      "when": { "dates": ["2026-11-08"] },
      "then": { "type": "discountRate", "rate": 0.8 } }
  ]
}
```

| # | 场景 | 命中 | 结果 |
|---|---|---|---|
| 1 | 2026-09-29（周二）12:30，椒盐花生米（凉菜）18 元 | `R-LUNCH-COLD-M2`（午市，分类匹配） | 18 − 2 = **16.00** |
| 2 | 2026-10-01（国庆·holiday·周四）18:30，椒盐花生米 18 元 | `R-HOLIDAY-PEANUT-99`（节假日 + uid）。午市规则时段不符 → 不命中 | **9.90** |
| 3 | 2026-10-03（holiday·周六）12:30，某热菜 38 元 | `R-WEEKEND-HOT-89`（周六 + 热菜）；午市规则分类不符 → 不命中 | 38 × 0.89 = **33.82** |
| 4 | 2026-11-08（店庆·周日）12:30，某热菜 38 元 | `R-WEEKEND-HOT-89`（100）+ `R-ANNIV-80`（300）**跨组叠加** | 38 × 0.89 × 0.8 = **27.06** |

---

## 11. 接口与既有接缝

```csharp
// 新引擎（纯函数，零 I/O）
PriceQuote Resolve(PriceContext ctx);
```

正好套住既有接缝 `Com.AIServe.Handlers.Business/IProductOperator.cs`：

```csharp
decimal GetPrice(int storeid, string productUid);                                              // 对外入口不变
public static decimal ApplyPriceRule(string? dishUid, decimal salePrice, DateTime localTime);   // ← 现为 3 参纯函数
```

改造后：

```
GetPrice(storeid, productUid)
  ├─ 读 BaseDish（SalePrice / TypeID / UID）                       ← I/O，装配器
  ├─ 装配 PriceContext（分类名、节假日日历标签、商品标签）           ← I/O，装配器
  └─ PricePolicyEngine.Resolve(ctx) → quote.price                  ← 纯函数，零 I/O
```

`ApplyPriceRule` 由 3 参升级为 `ctx`，**仍是纯函数、仍可注入假时间**（现有测试方式不变）；原「周一 8 折椒盐花生米」的硬编码规则改由策略文档表达（见 §14 验收 A13）。

---

## 12. 下一档（刻意不做，格式留好扩展位）

下列内容在 2026-09-11 版规格里已设计完整（见 git 历史 / 父文档 §4·§5），本阶段**整块移出 v1**：

| 升档 | 加什么 | 关键设计（已定，勿重新推导） |
|---|---|---|
| 数量维度 | `lineQty` 条件 + `lineTier` / `discountAmount.per: "line"` 动作 | 「第二份半价」用 `tiers[{fromQty,toQty,rate}]`；末档有上界时 **`repeat` 必填**（循环 vs 超出按 `overflowRate`）——买 3 件买 4 件必须显式回答，这是"歧义落成显式字段"的样板 |
| 整单维度 | `orderAmount`/`orderQty`/`order*` 条件 + `orderReduce` 动作 + P2/P3 阶段 | 规则加 `stage: line\|order`（**防循环依赖的结构性保证**）；满减阶梯不引入新动作——同组两条用 `priority` 编码档位（取最高档、不累加）；摊分 `allocate` 四值（`byLineAmount`/`byQty`/`toCheapest`/`none`），尾差归最后一行；**行价不漂移**（行价来自 P1，整单优惠独立成行） |
| 赠品 | `gift` 动作（新增 0 价行 + `giftOf`） | 落地要购物车/库存/成本侧配合 |
| 会员维度 | `memberLevel`/`memberTags` 条件 + `appliedPromotions` | 会员价仍是**输入价**（装配器算好写进 `listPrice`/`unitPrice`），引擎不认识"会员价"；"不与会员价叠加"靠 `appliedPromotions` + `not` |

**扩展方式**：加字段、`schemaVersion` 递增；已定形的部分不动，旧文档继续可加载。

---

## 13. 待确认

| # | 项 | 现状 / 推荐 |
|---|---|---|
| 1 | **`MinZheKou`（BaseDish 的 `int` 列）是否进引擎** | **2026-09-29 晚已取证**（SQL 已运行，实测 182801 非零样本：90/80/60/52——形似「最低折扣百分值」如 80=最低 8 折，但 52 样本存疑，语义仍不完全确定）。**v1 引擎未进**（用户本轮指令未含 MinZheKou，GetPrice = 策略匹配 → 价格 / 不匹配 → 原价）；推荐后续按 §13-1 原案：`PriceContext` 加 `minRate`，结算后钳制 + `PriceQuote.Clamped` 标记 |
| 2 | **`categories` 存中文名还是分类 UID** | ✅ **已定（2026-09-29 用户「不管是 category 还是 dish，都应该明确写出 id，而不是 name，这样程序才好解析」）：存分类 UID**。输入侧（LLM 只可能写中文名，它不知道 uid；人工 save 同样允许）→ 服务端解析成 UID 落库（`BaseDishType.UID`，IsEnable=1、`#` 开头系统类型排除；精确名 → 唯一包含匹配 → 多候选报错 → 未命中报错并列出可用分类，一律 fail-closed）。回译（店长确认页）由渲染器注入 uid→名映射渲成中文名——**两端都要各自可读，但程序解析只认 UID**。实现见 `docs/PricePolicyService.md` §3.2。**引擎侧已接线**：装配器读 `BaseDish.TypeID`（实测列存在，varchar(32)）→ `PriceContext.CategoryUid` 与规则 uid 直接比对 |
| 3 | **`tags` 来源** | `BaseDish.DescTagUIDs varchar(500)` 存在，**且 2026-09-29 晚发现 `BaseDishTag` / `BaseDishTagRelation` 两表存在**（uid→名链路可能在，语义与关联列待取证）。未确认前维持原案：装配器声明能力（`PricePolicyCapabilities.TagsSupported=false`），**含 `tags` 的规则加载期拒绝整个文档**（§8-8，已实现并验收 P7） |
| 4 | **落地位置** | ✅ **已定（2026-09-30 修订）：并入 `Com.AIServe.Handlers.Business` 的 `Pricing/` 子目录**（接入侧 = `ProductOperator` + `StorePolicyCache`，同项目根目录）——用户定稿「不需要这个单独的项目」。（2026-09-29 晚原定：本仓新增独立类库 `Com.AiServe.Pricing`，纯引擎零 ProjectReference；该库已于 2026-09-30 删除并入 Business，文件按 `Pricing/` 目录隔离，**引擎仍写成纯函数零 I/O，但不再由编译边界强制**。两条路线都不引入 Roslyn/AOP，不撞决策 8） |

---

## 14. 文件清单 / 实现顺序 / 验收标准

### 14.1 文件清单（按 §13-4 推荐落点：独立类库）

> ⚠️ **2026-09-30 落点修订**：本节写于 2026-09-29（独立类库方案）；此后用户定稿**不单独建项目**，独立类库已删、引擎并入 `Com.AIServe.Handlers.Business/Pricing/`（§13-4）。下表与下方目录树里的 `Com.AiServe.Pricing/` 一律读作 `Com.AIServe.Handlers.Business/Pricing/`；实际落成见 §14.4。

```
Com.AiServe.Pricing/                         ← 新增类库（net10.0，零 ProjectReference）
  Models/PricePolicyDocument.cs              ← schemaVersion/storeId/revision/validFrom/validTo/rules
  Models/PriceRule.cs                        ← id/label/enabled/group/priority/when/then
  Models/Condition.cs                        ← 组合子 + 7 字段叶子
  Models/PriceAction.cs                      ← discountRate / fixedPrice / discountAmount
  Models/PriceContext.cs / PriceQuote.cs     ← 输入 / 输出值对象
  PricePolicyValidator.cs                    ← §8 的 8 条（错误文本可回喂生成端）
  PricePolicyCompiler.cs                     ← 文档 → 预编译规则树；缓存 key=(storeId, revision)
  PricePolicyEngine.cs                       ← Resolve(ctx) 纯函数
  PricePolicyRenderer.cs                     ← §9 回译（确定性中文）

Com.AiServe.Handlers.Business/               ← 接入侧（本仓现有项目）
  PriceContextAssembler.cs                   ← 新增：BaseDish(SalePrice/TypeID) + 分类名 + 节假日日历
  IProductOperator.cs                        ← GetPrice 内部接装配器 + 引擎；ApplyPriceRule 3 参 → ctx
```

### 14.2 实现顺序

1. **阶段 A（纯离线，可独立验收）**：模型 → 校验器 → 编译 + 引擎 → 回译 → 表格驱动验收（A1–A12）
2. **阶段 B（接入）**：装配器 + `IProductOperator` 接线 → 用策略文档替换现有「周一 8 折」硬编码（A13）
3. **阶段 C（生成端，另立文档）**：`Skills/price_policy/skill.md` + `AIService.PricePolicyService`（自然语言 → JSON，生成时跑校验 + 回译交叉校验 → 草稿态/人工确认）

### 14.3 验收标准（阶段 A/B）

| # | 用例 | 判据 |
|---|---|---|
| A1 | 星期条件 | 周六/周日命中，周五不命中 |
| A2 | 时段边界（半开 + 跨午夜） | `11:00` 命中、`14:00` 整**不**命中、`10:59` 不命中；`22:00–02:00` 在 `01:30` 命中、`21:59` 不命中 |
| A3 | 固定日期 | 店庆日命中，其他日期不命中 |
| A4 | 节假日标签 | 装配器给 `holiday` → 命中；同一文档在 `workday` 不命中 |
| A5 | 单商品 vs 分类 | `dishUids` 规则与 `categories` 规则各自只命中自己的范围 |
| A6 | 冲突 | 同组两条 → 取 `priority` 大者；跨组两条 → 依次施加（0.8 × 0.89） |
| A7 | 判定基准 | 构造 A 规则改写价格后落到 B 规则区间外，**B 仍按原始输入价命中**（§6.4） |
| A8 | 取整与下限 | `18 × 0.89 = 16.02`；`discountAmount` 超过单价 → `0.00` 不为负 |
| A9 | 校验拒绝集 | 未知字段 / `rate: 89` / 同组同 priority / 嵌套 6 层 / `time` 格式错 / `dates` 格式错 → 全部拒绝，错误文本含字段路径 |
| A10 | 回译 | JSON → 中文与 `label` 一致；不一致进人工确认 |
| A11 | 性能与缓存 | 单商品求值 < 1ms（硬上限 5ms）；同 `revision` 不重复解析 |
| A12 | 档期 | `validTo` 过期 → 等同空策略（全部按 `listPrice`） |
| A13 | 接线回归 | 「周一 8 折椒盐花生米」改用策略文档表达后，`GetPrice` 返回值与旧 `ApplyPriceRule` 逐值一致 |

### 14.4 实现记录（2026-09-29 晚，验收全过）

**文件（实际落点 = §14.1 计划；路径列为 2026-09-30 并入后的现状）**：

| 文件 | 内容 |
|------|------|
| `Com.AIServe.Handlers.Business/Pricing/Models/PricePolicyModels.cs` | 编译后强类型：Document/CompiledRule/CondNode（AllOf·AnyOf·Not·DayIs·TimeIn·DateIs·StringSet）/TimeSegment/PriceAction/PriceContext/PriceQuote/PricePolicyCapabilities |
| `Com.AIServe.Handlers.Business/Pricing/PricePolicyValidator.cs` | §8 的 8 条（闭集/数值域/id 唯一/同组同 priority/days 闭集/time 格式与重叠告警/dates 格式/嵌套 ≤5/any:[] 告警/**能力核对 tags·dateTags 拒载**），错误文本带字段路径 |
| `Com.AIServe.Handlers.Business/Pricing/PricePolicyCompiler.cs` | JSON → 校验 → 编译树（纯函数，无缓存——缓存归接入侧按 (storeId, revision) 管） |
| `Com.AIServe.Handlers.Business/Pricing/PricePolicyEngine.cs` | `Resolve(policy, ctx)` 纯函数零 I/O：档期逐次判断（含当天）→ enabled+条件命中 → 同组取 priority 大者 → 跨组 (priority desc, id asc) 链式施加 → Round(2, AwayFromZero) 下限 0 → PriceQuote(appliedRuleIds) |
| `Com.AIServe.Handlers.Business/IProductOperator.cs` | `GetPrice` 重写：ReadDish（+TypeID）→ PriceContext → StorePolicyCache + Engine；接口签名不变；TimeProvider 注入不变；菜品/门店不存在仍抛 |
| `Com.AIServe.Handlers.Business/StorePolicyCache.cs` | 活跃行读取（SysTenantExtension `Enabled=1` 最大 Version，作用域 StoreID+TrigerType）+ 编译缓存（revision 变化单店锁内编译一次、无启用行/拒载 → null=原价）+ `StoreConnection.Resolve` |

**2026-09-30 结构变更**：上述前 4 行原属独立类库 `Com.AiServe.Pricing`（namespace `Com.AiServe.Pricing[.Models]`），随用户定稿并入 `Com.AIServe.Handlers.Business`——新 namespace = `Com.AIServe.Handlers.Business.Pricing[.Models]`（**除 namespace 外零代码改动**）；项目目录同批修正大小写 `Com.AiServe.Handlers.Business` → `Com.AIServe.Handlers.Business`（与 `Com.AIServe.Common` / `Com.AIServe.Handlers.AIService` 一致）。复跑验收 **61/61 PASS**（`.asr-test/BusinessProbe/probe-run-after.txt`，与改前逐行一致，仅 A11 计时 0.088→0.121ms 属机器噪声）。

**验收（探针 `.asr-test/BusinessProbe/`，`probe-run.txt`）**：**A1-A12 离线全过**（含 A2 半开与跨午夜边界、A6 同组互斥+跨组链式+施加顺序、A9 八类拒载、A11 单次求值 0.099ms、A12 档期含当天）+ **P0-P10b 走库全过**（P1=A13 与旧 ApplyPriceRule 逐值一致 20.00/25.00/43.00、P2 分类 TypeID 比对、P3 时段、P4 固定价、P5 链式、P6 非法文档拒载按原价、P7 tags/dateTags 能力拒载、P8 档期过期、P9 版本切换缓存立即生效、P10 停用语义=上一启用版继续算价 + P10b 全停用→原价）+ 异常路径（菜品/门店不存在仍抛）。探针直插 SysTenantExtension（pprobe 前缀）并自清理。

**v1 已知简化（勿当缺陷）**：① 编译在版本变更瞬间于调用线程做（§6.5 目标态是后台构建+原子换引用——GetPrice 本身每次已做 2 次库查询，POS 批量取价接线时再迁）；② 回译器未入 Pricing 库（生成端的回译/交叉校验已由 PricePolicyService 的 Renderer 承担，A10 口径在那边）；③ `dateTags`/`tags` 条件加载期拒载（日历/标签表待接，§13-1/§13-3）；④ MinZheKou 未进引擎（§13-1）。
