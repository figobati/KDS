# PricePolicy —— 门店菜品价格自定义（AI 生成价格策略）

> **状态：需求与论证已定稿；DSL v1 规格见 [`PricePolicyDSL.md`](PricePolicyDSL.md)（2026-09-29 收窄重写，待审）**。
> 本文是设计讨论记录 + 论证（为什么 JSON 不是 C#、50ms 性能口径、表达力边界、求值模型、上下文接口），
> 不是实现文档。
>
> **⚠️ 2026-09-29 范围收窄（用户口径）**：v1 只做**「不同条件下的商品取价」**——商品 × 日期 / 时间 / 星期 / 节假日 → **一个单价**。
> **会员折扣整个不在定价引擎内**（"会员折扣在程序另外的地方计算"）；**数量（第二份半价）、整单（满减/摊分 P2·P3）、赠品**同样移出 v1。
> 上述内容均为**已论证的下一档**（见 `PricePolicyDSL.md` §12），本文相应章节保留为论证记录；**v1 规格以 `PricePolicyDSL.md` 为准**。

## 0. 需求

一个餐厅有数量不等的菜品，不同情况下取不同价格，极端情况「周一至周日 + 节假日 + 不同时段」价格都不同。
传统做法靠各种设置表 → 配置系统复杂、运行期判断复杂。

**方案：用自然语言描述价格策略，由 AI 生成可执行的价格策略。**
运行时刻**绝不调 AI**（性能不可接受），AI 只在「策略录入/变更」时跑一次。

两种候选落地形式：

| | 生成 C# 代码 | 生成 JSON + 通用 Parser |
|---|---|---|
| 运行性能 | 编译态最快 | 预编译规则后同档 |
| 表达力 | 无上限 | 受词表限制 |
| 出错后果 | 编译失败当场炸 / 编译通过但**静默算错价** | schema 校验拦下，保留上一版 |
| 上线前验证 | 只能人工读代码 | **可回译成中文给店长确认** |
| 审计「当时为什么是这个价」 | 重放代码 | 规则 id + 命中条件 |
| 安全 | **生成代码 = 进程内任意执行**（见 §2.2） | JSON 是数据，引擎是可信代码 |

## 1. 结论（当前倾向）

**JSON DSL 为主，C# 只做「DSL 表达不了时」的离线兜底，且兜底不进运行时编译。**

理由不是性能（性能账见 §3，两方案在 50ms 预算下都够，但 C# 要额外补一堆东西），而是**价格算错要担责**（明码标价 / 客诉 / 稽核）：
JSON 能结构化校验、能回译给店长确认、能留版本审计，C# 这三样都做不到。

**决定性的一条**：自然语言描述定价本身就有歧义（「第二份半价」买 3 件怎么算？买 4 件？超出的恢复原价还是继续循环？）。
C# 路径下 LLM 替你把歧义**固化在没人看的代码里**；JSON 路径下歧义必须落成显式字段，并且能回译成
「买两件付 1.5 件的钱，第三件重新按全价算，请确认」——**这是 AI 定价能上线的前提条件**。

## 2. 关键事实（已核实）

### 2.1 现有代码接缝：`Com.AIServe.Handlers.Business/IProductOperator.cs`

```csharp
decimal GetPrice(int storeid, string productUid);
public static decimal ApplyPriceRule(string? dishUid, decimal salePrice, DateTime localTime);
```

- `ApplyPriceRule` 已是**纯函数**，`TimeProvider` 已可注入（测试可传假时间）→ 接缝设计得好，两条路都插得进来
- 取数链：`DataContextFactory.CanYinCenter` → `SysStoreInfo.GroupID` → `DataContextFactory.GetConnectionString(GroupID)` → `BaseDish`
- ⚠️ **这个签名最终不够用**：`GetPrice` 只能返回一个单价，装不下「第二份半价」（按数量分段）和「满 100 减 20」（整单级）。接口必须升级为 `Calculate(cart)`，见 §6

### 2.2 现有框架：`F:\AIProject\SmartDevice - 副本\Com.AIServe.Common.AIExtension\`

| 文件 | 作用 |
|---|---|
| `CodeBuilder.cs` | Roslyn 编译 + collectible ALC + 版本化缓存 + 显式卸载，租户隔离 cache key |
| `ExtensionManager.cs` | `SysTenantExtension` 表 + 60 秒定时刷新 + 版本变化联动卸载 + `GetTenantExtension` 两级回退 |
| `FunctionAopInterceptor.cs` | Castle AOP `Before / After / Replace` 三档拦截 |
| `ServiceHandlerFactory.cs` | handler 扫描注册 + 代理包装 |

**已为价格场景预留**：`ExtensionConstant.TrigerType_PricePolicy = "PricePolicy"`（另 `CodeType_JSON = 2` 与 `CodeType_H5` 同值，是遗留 bug，JSON 支路从未实现）。

**这套框架的资产在于存储/版本/刷新/租户隔离（~80%），问题只在「用编译执行当运行时」**。

⚠️ **三个硬伤（.NET 10 上）**：

1. **无法沙箱**。`CodeBuilder` 把 `AppDomain.CurrentDomain.GetAssemblies()` 全部作为 MetadataReference 给生成代码——含 `System.IO` / `System.Net.Http` / `System.Diagnostics.Process`，以及 `Com.AIServe.Common`（→ `DataContextFactory` → 数据库连接串）。
   而 **.NET Core 起已移除 CAS / AppDomain 沙箱**，进程内**没有**受支持的隔离手段。生成代码 = 以进程权限跑任意逻辑。
   威胁模型与「自己的开发写代码」不同：**输入是店长自然语言**，经 LLM 生成，无人工审代码环节。
   真要做不受限逻辑又要安全，只有**进程外隔离**或 **WASM 沙箱**（Wasmtime / Extism）。
2. **无失败兜底**。`CompileDelegate` 失败 `throw`，`FunctionAopInterceptor.Intercept` 调 `GetOrBuildPipeline` **无 try/catch** → 异常冒到业务调用。
   且缓存只存当前版本——**一版坏代码刷新后会顶掉上一版好代码**。
3. **请求内惰性编译**。`GetOrBuildPipeline` 是在请求路径上调的 → 策略一改，下一次点菜要吃 200–600ms Roslyn 编译（首次还要加载 Roslyn 本体 1–2s）。**直接爆 50ms 预算**（见 §3）。

⚠️ **与本仓既有决策冲突**：AIServeAgent 已于 2026-08-24 整体删除 AIExtension（commit `4392d9d`），
CLAUDE.md 决策 8 明确「勿重新引入 Castle/AOP」。**若定价模块落本仓，复用该框架会撞这条决策**（落点见 §7-Q4）。

## 3. 性能口径：50ms（用户 2026-09-10 修正）

⚠️ **不能用语音/LLM 链路的 ~1000ms 去算**。点单也可能是传统按钮点单：
**点击菜品 → 取数 → 加入购物车 < 50ms**，价格求值必须装进这个预算。

50ms 里已有 DB 取数（1–5ms）和购物车状态 → **价格求值合理配额 < 1ms，硬上限 5ms**。

| 方案 | 稳态单菜求值 | 购物车 20 项重算 | 版本变更后首次 | 能进 50ms |
|---|---|---|---|---|
| **JSON + 预编译规则** | 0.2–2 µs | 4–40 µs | 20–30 ms（解析一次） | ✅ 余量 ~1000× |
| JSON + **每请求现解析** | 20–50 ms | — | — | ❌ 独占整个预算 |
| C# 编译态（直调委托） | 50–200 ns | 1–4 µs | 200–600 ms | ⚠️ 必须预热 |
| C# 走现有 AOP | 2–5 µs | 40–100 µs | 200–600 ms（+ Roslyn 加载 1–2s） | ❌ |

**三条硬约束**：

1. **缓存是准入条件，不是优化项**。每请求解析 JSON = 20–50ms，光这一项吃干净预算。
   「版本变化时构建一次、之后只求值」必须写进设计。（反过来说：**如果能接受每请求现解析，那 C# 反而是对的**——这个选择真正依赖的是缓存。）
2. **禁止在请求路径上惰性构建**。版本变更 → 后台构建 → 原子换引用 → 释放旧的。JSON 构建只要 20ms，可直接在 60 秒定时器线程里做完；C# 的 200–600ms 必须预热。
3. **求值必须纯函数、零 I/O**。50ms 里没余量给规则求值再查库。会员等级 / 订单金额 / 节假日日历 / 分类标签必须在进入求值前备好（见 §6 装配器）。
   规则若需要上下文之外的数据，**那它不是规则，是流程**——schema 应明确拒绝，而不是让求值器去查库。

## 4. 表达力：JSON 能不能装下

### 4.1 通用性来自「词表封闭 + 可组合」，不来自像编程语言

**条件（谓词代数，闭集）**

| 类别 | 字段 |
|---|---|
| 时间 | `days` / `time` 段 / `dates`（含排除，走节假日日历） |
| 范围 | `dishUids` / `categories` / `tags` / `storeIds` |
| 数量 | `lineQty` / `orderQty` |
| 金额 | `orderAmount` / `lineAmount` |
| 顾客 | `memberLevel` / `memberTags` |
| **已生效优惠** | `appliedPromotions` |
| 组合 | `all` / `any` / `not` |

**动作（闭集）**：`discountRate`（打折）| `discountAmount`（减额）| `fixedPrice`（定价）| `lineTier`（按份数分段）| `orderReduce`（整单减，带摊分）| `gift`（赠品）

`all` / `any` / `not` 的嵌套给了布尔闭包——**这一条就是「通用」的来源**。
参考：JSON Logic / Drools / OPA-Rego 都是这个路子——小而封闭的算子集 + 自由组合，换取可校验、可回译。

### 4.2 示例

```json
{
  "id": "R-SECOND-HALF", "priority": 100, "group": "dish-promo", "stage": "line",
  "when": { "dishUids": ["02c850049ee94f6d9672e4c81d69adf1"], "lineQty": { "gte": 2 } },
  "then": {
    "type": "lineTier", "repeat": true,
    "tiers": [ { "fromQty": 1, "toQty": 1, "rate": 1.0 },
               { "fromQty": 2, "toQty": 2, "rate": 0.5 } ]
  }
}
```

```json
{
  "id": "R-FULL100", "priority": 50, "group": "member-price", "stage": "order",
  "when": {
    "all": [ { "orderAmount": { "gte": 100 } },
             { "not": { "appliedPromotions": ["memberPrice"] } } ]
  },
  "then": { "type": "orderReduce", "amount": 20, "allocate": "byLineAmount" }
}
```

「不与会员价叠加」两种实现，取决于会员价是不是本引擎产生的：
- **是** → 同 `group` 互斥 + 优先级取一（声明式，最干净）
- **否**（会员价是 BaseDish 的列，已算进去）→ 上下文必须带 `appliedPromotions`，规则才看得见「已经优惠过了」

### 4.3 天花板（不是设计不够好，是它们本来就不是纯函数）

| 需求 | 为什么装不下 |
|---|---|
| 「同一会员每天限享一次」 | 需要**历史订单状态**，破坏纯函数 |
| 「套餐 A+B = 25 元」 | 需要对购物车做**子集匹配**，是算法问题不是数据问题 |
| 「所有优惠里让顾客付最少」 | 需要**搜索 / 组合优化**，不是首条命中 |
| 「第二份半价与满减撞车时第二份按原价重算」 | **多轮求值 / 跨规则依赖** |

这四类一旦要支持就是在写编程语言。**正确做法是明确拒绝**：LLM 判断「表达不了」时**不猜**，返回「需人工处理」→ 离线生成 C# + 人工审核 + 正常发版。

### 4.4 防「内部平台效应」三条纪律

1. **词表冻结**：v1 的条件/动作清单写死，新增一项需 ≥3 个真实需求支撑。
2. **回译必须全量**：**任何规则都必须能回译成店长看得懂的中文，回译不出来就不许进 DSL**。
   这条自动把边界卡在「业务能确认」范围内，也顺手挡住 §4.3 那四类。
3. **「表达不了」必须可观测**：统计比例。低于 20% 说明词表够用；持续升高才考虑扩词表。

## 5. 求值模型：P1 / P2 / P3

传整单后会出现 `整单优惠摊回行 → 行金额变 → 又影响整单判断` 的**循环依赖**。
挡它的办法是在 schema 里把阶段写死：

| 阶段 | 输入 | 输出 | 硬约束 |
|---|---|---|---|
| **P1 行级** | 单行 + 上下文 | 行单价 / 行折 | **不得读其他行** |
| **P2 整单级** | 全单（P1 结果） | 整单优惠项 | **不得改写行** |
| **P3 摊分** | P2 优惠项 | 行成交价 | **纯计算，无规则** |

规则声明 `stage: line | order`。P1 看不见别的行，P2 改不了行 → **循环依赖在结构上不可能发生**，无需检测机制。

**副作用（正面）——同时解决「价格漂移」**：
顾客看到水煮鱼 38，加了道菜触发满减，回头发现那道菜变 35 了（真实客诉来源）。
分阶段模型下：**菜单和购物车每行价格来自 P1**（稳定、可独立展示），**P2 的整单优惠以独立优惠行呈现**（"满减 -20"），摊分只在结算/打印小票时算。
→ **行的价格永远不因购物车里别的东西而跳变**。

## 6. 上下文与接口

> ⚠️ **2026-09-29 收窄**：本节含购物车级（整单）与会员上下文，**v1 不实现**（§5 的 P2/P3 同）。
> v1 的上下文/接口见 `PricePolicyDSL.md` §7 / §11：`PriceContext { storeId, now, dateTags, dishUid, category, tags, listPrice }` → `PriceQuote { price, appliedRuleIds }`，**无任何会员字段**。
> 本节保留为下一档的论证记录（会员价的三种模型、"传判定结果不传档案"、装配器负责 I/O 等结论届时直接复用）。

```csharp
CartPricing Calculate(CartContext cart);      // 取代 GetPrice(storeid, productUid)
```

```
CartContext {                                  // 值对象，纯输入
  StoreId, GroupId, Now(门店本地时间), Holiday,
  Member { Uid?, Level, Tags[], Flags[] },     // ← 判定结果，零 PII
  Lines  [ { LineId, DishUid, Category, Tags, UnitPrice, MemberPrice?, Qty,
             MethodUid, AppliedPromotions[] } ],
  Totals { OrderAmount, OrderQty }
}

CartPricing {
  Lines           [ { LineId, UnitPrice, LineAmount, AllocatedDiscount, FinalAmount } ],
  OrderDiscounts  [ { RuleId, Amount, Allocate } ],
  AppliedRules    [ RuleId... ]                // 审计：「这单为什么是这个价」
}
```

**装配器负责 I/O，引擎保持纯函数**：

```
CartContextAssembler
  ├─ 购物车       ← 已在内存
  ├─ 会员信息     ← 查一次，会话级缓存；**建单/开台时冻结**
  └─ 节假日日历   ← 加载一次，进程级缓存
        ↓
  CartContext（值对象） → Calculate(cart)  ← 纯函数零 I/O
```

**会员信息：传「判定结果」，不传会员档案**
- 需要的其实很少：`Level`（0 = 非会员）/ `Tags[]` / `Flags[]`（如 `storedValue`、`birthdayToday`）/ `Uid`（审计）
- **不传**手机号、余额、消费记录、储值明细。价格引擎要把规则回译给店长看、要写审计日志、可能经 LLM 之手 → PII 一旦进来就会顺这些通道外流。
  原则：**能由装配器判定的就别传原始数据**（传 `IsBirthdayToday` 而非生日日期）。
- **非会员态必须显式**（`Level = 0` 而非 `null`），否则非会员点单会掉进会员分支。
- **限次信息不能进上下文**（见 §4.3，需历史订单）。

**会员价的三种模型（先选，决定字段放哪）**

| 模型 | 数据位置 | 落地方式 |
|---|---|---|
| **菜品会员价** | BaseDish 的会员价列 | **在 P1 上下文里**——每行多一个 `MemberPrice`，不是规则 |
| **等级折扣率** | 会员等级表 | 规则 `when.memberLevel` → `discountRate` |
| **等级专属规则** | 规则表 | 同上，条件更细 |

**会员信息带来的连带影响（会外溢到引擎之外）**：
- 菜单展示要按会员渲染（POS / 小程序 / 前台三端）
- 行级缓存 key 要带会员维度（原价可按 `dish+time` 缓存，会员价不行）
- 代点 / 分享场景：A 会员的链接被 B 打开，算谁的价

## 7. 待拍板

> ⚠️ **2026-09-29 收窄后**：Q1–Q3 已改属「下一档」（会员不在引擎内 / 购物车级），**v1 只剩 `PricePolicyDSL.md` §13 的四项**——
> `MinZheKou` 是否进引擎 / `categories` 命名口径 / `tags` 来源 / 落地位置。

**2026-09-11 用户已定 Q1（三条口径）**（会员维度整体移出引擎后，前两条转为装配器与会员模块的口径，第三条仍有效）：

1. **`MemberPrice = 0` = 无会员价**（走 `SalePrice`，负价非法）
2. **会员价 = 输入价**——装配器决定有效单价（`MemberPrice > 0 ? MemberPrice : SalePrice`）写进 `lines[].unitPrice`，**引擎不认识"会员价"这个概念**；会员价生效时装配器在 `appliedPromotions` 里塞 `"memberPrice"`，规则用 `not: {appliedPromotions:["memberPrice"]}` 表达"不与会员价叠加"（§4.2 的原路）。
   ⚠️ 2026-09-29 起：会员折扣由**程序另外的地方**计算，本引擎的输入输出里都没有会员
3. **引擎不做审计留痕**——审计由外部调用方负责；引擎输出只保求值结果 + 触发规则 id（界面展示用）✅ 仍有效

| # | 问题 | 状态 |
|---|---|---|
| **Q1** | 会员价用哪个模型 | ↔️ **移出引擎**（2026-09-29）：会员折扣在程序另外的地方计算；上三条口径留给会员模块 / 装配器复用 |
| **Q2** | 摊分语义 | 🅿️ **下一档**（购物车级）：规格已给四值，默认 `byLineAmount` |
| **Q3** | 价格漂移口径 | 🅿️ **下一档**（购物车级）：按行价锁定（P1 稳定展示 + P2 独立优惠行） |
| **Q4** | 落地位置 | ✅ **已定（2026-09-30）：② `Com.AIServe.Handlers.Business` 内**（用户「不需要这个单独的项目，所有代码并入 Business」）——引擎落 `Pricing/` 子目录（namespace `Com.AIServe.Handlers.Business.Pricing`），接入侧 `ProductOperator`/`StorePolicyCache` 在同项目根；**代价照单接受**：引擎被拖进 DB 依赖（该项目引 `Com.AIServe.Common`，取数用 SqlClient），纯净性靠目录约定而非编译边界。（2026-09-29 晚曾定 ① 独立类库 `Com.AiServe.Pricing` 并实现验收，2026-09-30 已删并入；③ `AIService` 内、④ SmartDevice 侧复用 `SysTenantExtension`（⚠️ 撞决策 8）两条仍不采纳） |

## 8. 下一步

1. ✅ **范围收窄定稿（2026-09-29）**：v1 = 商品取价（时间条件）；会员 / 数量 / 整单 / 赠品 = 下一档
2. ✅ **DSL v1 规格已按收窄口径重写 → `docs/PricePolicyDSL.md`**（策略文档 / 规则 / 7 字段条件谓词 / 3 型动作 / `PriceContext`·`PriceQuote` / 求值 / 校验 / 回译 / 完整示例与走查 + **§13 待确认 4 项** + **§14 文件清单 · 实现顺序 · 验收标准 A1–A13**）
3. 用户审 v1 规格 → 定 §13 四项 → 实现阶段 A（纯离线引擎 + 验收）→ 阶段 B（接线 `IProductOperator`）→ 阶段 C（生成端 skill + handler）

## 附：本文讨论演化（备查）

1. 用户提问「生成 C# 还是生成 JSON」→ 初步分析倾向 JSON
2. **用户修正性能口径**：「点单不一定走语音 LLM，按钮点单 点击→取数→加购物车 < 50ms，要用这个算」→ 重算后结论不变但前提变硬（§3）
3. 用户追问「第二份半价 / 满 100 减 20 且不与会员价叠加，JSON 能设计得这么通用吗」→ 得出：能，条件是**谓词代数 + 闭集动作 + 上下文带 `appliedPromotions` + 返回值从单价升级为「行金额 + 折扣项」**（§4）
4. 用户追问「整个订单和当前菜品一起传入 parser，是否解决更多场景」→ 能显著扩大射程，但引入三个新问题：**阶段划分 / 价格漂移 / 摊分语义**（§5）
5. 用户追问「会员信息是否也要传入」→ 传，但传判定结果不传档案；I/O 归装配器（§6）
6. **2026-09-29 用户收窄范围**：「首先是设计一个 JSON 的数据表达格式，可以表示不同条件下的商品价格……不涉及会员折扣这类，会员折扣在程序另外的地方计算」→ v1 砍到「商品 × 时间条件 → 一个单价」；会员 / 数量 / 整单 / 赠品整块降为下一档（DSL 文档 §0 / §12），全文按此重写
