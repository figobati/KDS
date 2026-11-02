# PricePolicy NL → DSL 生成链路 — PRD v1.0

| 项 | 内容 |
|---|---|
| 版本 | v1.0 |
| 日期 | 2026-10-11 |
| 状态 | 待评审 |
| 前置文档 | `PricePolicy-DSL演示程序-PRD.md` v2.0（本 PRD 为其 §11「后续扩展方向」中「AI 生成规则接口」的正式展开） |
| 关联文档 | `PricePolicyDSL.md` v1 / `PricePolicy-字段与场景大全.md` / `PricePolicyService.md` |
| 定位 | 在**不修改** engine / validator / translator 的前提下，新增「自然语言 → JSON DSL」的反向生成链路 |

---

## 一、背景与目标

### 1.1 现状

现有演示程序已经完成**正向链路**：

```
JSON DSL  ──▶  RuleEngine（四阶段执行）  ──▶  执行结果 / 命中轨迹
JSON DSL  ──▶  Translator（回译）        ──▶  中文规则描述
JSON DSL  ──▶  Validator（12 项检查）    ──▶  校验报告
```

规则作者需要**手工编写 JSON**。对非技术背景的运营/店长而言，JSON 是门槛：字段名要记（`dateTags` 不是 `dateTag`）、闭集要记（`memberLevel` 只能是那 5 个值）、结构要记（`openTime` 是 `[["11:00","14:00"]]` 双层数组，不是 `["11:00","14:00"]`）。

### 1.2 目标

新增**反向链路**，让用户用嘴说、用手打字，就能产出可执行、可校验、可回读确认的规则：

```
自然语言输入               生成                验证               回译确认
（语音 / 文字）  ──▶  Slot  ──▶  JSON DSL  ──▶  三层校验  ──▶  中文规则  ──▶  用户点「确认入库」
```

**核心目标（按优先级）**：

| 优先级 | 目标 | 验收方式 |
|---|---|---|
| P0 | **闭环可用**：稻香 22 条内置规则，能把其人造语料「说回去」并生成等价 JSON | 22/22 条回译文案与原 `label` 语义一致 |
| P0 | **过程可视**：UI 三栏对照（原话 / 生成的 JSON / 回译），中间展示解析过程高亮 | 用户能在不读 JSON 的情况下判断「机器听懂没有」 |
| P0 | **错了能发现**：绝不静默产出错误规则 | 校验不通过或置信度低 → 必须拦截并追问，不许直接入库 |
| P1 | **零依赖离线**：沿用现有 `file://` 双击即用约定 | 双击 `index.html` 全流程可用，无网络请求 |
| P2 | **可换实现**：规则版与 LLM 版同一接口，切换零改动 | 换 `parser-llm.js` 后 composer/validator/translator 不动一行 |

### 1.3 核心价值主张

> **用户确认的对象不是 JSON，而是回译出来的中文话。**
> JSON 只是机器之间的中间表示；人只对「你看我说的这个意思对吧？」这个问句作判断。

这决定了本链路的设计重心：**回译不是附加功能，而是验证环节本身**。

### 1.4 技术栈确认

| 项 | 选型 | 说明 |
|---|---|---|
| 语言 | ES5 为主（`var` / `function`） | 与现有 `app.js` / `engine.js` 一致，不用可选链、不用 `??` |
| 模块规范 | UMD | 浏览器挂 `root.PricePolicyXxx`，Node 侧 `module.exports` |
| 依赖 | **零依赖** | 纯函数，不引第三方库 |
| 数据 | `data/parser-lexicon.json` | 词典是**数据**不是代码，运营可自行加词 |
| 通信 | 同步 `parse(rawText) -> Slot` | 规则版同步；LLM 版内部用 async，但对外仍返回 Promise 或改由 agent 层 await |
| 离线 | `file://` 直开 | 新增词典必须并入 `js/embed-data.js` |

### 1.5 版本范围

**v1.0 做：**

- 规则版 Parser（归一化 + 词典最长匹配 + 模板匹配 + 槽位产出）
- Composer（Slot → DSL 确定性组装）
- 三层校验（validator / semantic-check / engine 试算）
- 降级分流三态（追问 / 候选卡 / 能力清单）
- UI 三栏对照 + 解析过程高亮
- 稻香 22 条规则反推语料回归测试
- LLM 适配层**接口预留**（含空实现 `parser-llm.js` 骨架，不接真实模型）

**v1.0 不做（划清边界）：**

- 真实接大模型（仅留接口与配置文件开关）
- 多轮对话式澄清（v1 只做单轮追问，追问后用户重说）
- 语音识别（ASR）（由宿主 App 做完再传文本进来）
- 修改既有规则（v1 只做「新增规则」，不做「改规则」）
- 跨场景词典差异化（v1 用全局词典 + 场景别名覆盖）

---

## 二、总体架构

### 2.1 五格链路

整条链路切成**五格**，每格职责单一，中间用 `Slot` 作为唯一契约：

```
①  NL 输入          ②  NL → Slot        ③  Slot → DSL       ④  校验           ⑤  回译 & 确认
┌─────────────┐   ┌───────────────┐   ┌───────────────┐   ┌────────────┐   ┌──────────────┐
│  用户原话    │──▶│   Parser      │──▶│  Composer     │──▶│ 三层校验    │──▶│ SemanticCheck │
│  "周三凉菜   │   │ 归一化        │   │ 条件组装      │   │ validator   │   │ Translator    │
│   打八折"    │   │ 词典最长匹配   │   │ 动作组装      │   │ semantic    │   │ + 用户确认    │
│             │   │ 模板匹配      │   │ id/priority   │   │ engine试算  │   │              │
│             │   │ ↓             │   │ group 生成    │   │ ↓          │   │ ↓            │
│             │   │ Slot[]        │   │ ↓             │   │ 通过/失败  │   │ 中文 + diff  │
└─────────────┘   └───────────────┘   │ JSON DSL      │   └────────────┘   └──────────────┘
                                      └───────────────┘
       [可替换实现]     [必须确定性]      [必须确定性]      [必须确定性]       [必须确定性]
```

**关键结论：只有第 ② 格可以被 LLM 替换，其余四格必须确定性。**

理由：组装要做 id 唯一性、priority 推算、stage 反查；校验是现成闭集逻辑；回译必须逐字段确定性可复现；降级分流若由 LLM 决定「该不该追问」，用户会失去对系统的信任边界。

### 2.2 与现有模块的边界

**本链路新增模块，一律不修改既有文件：**

| 现有模块 | 本链路如何使用 | 是否修改 |
|---|---|---|
| `engine.js` | ① 借 `CONDITION_FIELDS` / `ACTION_TYPES` / `LINE_ACTIONS` / `ORDER_ACTIONS` / `MEMBER_LEVEL_CN` 等常量做闭集约束；② 调 `RuleEngine.validate()` 或 `static validate(policyDoc)`；③ 构造 `RuleEngine` 做单例试算 | **否** |
| `validator.js` | 生成的 DSL 走完整 `PricePolicyValidator`，把结构化 `{code, message, path}` 回灌给 Parser | **否** |
| `translator.js` | ① **字典反向复用**为 Parser 词典种子；② 回译生成规则供用户确认 | **否** |
| `scenario-manager.js` | 用 `loadJson` 读词典；用 `buildCatalogIndex` 建商品索引供「菜品名 → dishUids」解析 | **否** |
| `app.js` | 增量加一块「生成面板」+ 一个「生成过程」视图，复用现有 `jsonViewer` / `CodeMirror` 实例 | **增量** |
| `index.html` | 增量加 tab / 面板 DOM；脚本标签插入位置见 §11 | **增量** |
| `css/style.css` | 增量加生成面板样式，配色沿用 §8 规范 | **增量** |

### 2.3 新增文件清单

```
price-policy-demo/
├── data/
│   └── parser-lexicon.json          ★ 新增：领域词典（~300 条）
├── js/
│   ├── parser.js                    ★ 新增：NL → Slot（规则版，默认）
│   ├── parser-llm.js                ★ 新增：NL → Slot（LLM 版骨架，默认不启用）
│   ├── composer.js                  ★ 新增：Slot → JSON DSL
│   ├── semantic-check.js            ★ 新增：原话 vs 回译 结构化 diff
│   └── agent.js                     ★ 新增：五格链编排 + 降级分流
├── index.html                       ✎ 增量：生成面板 + 脚本标签
├── js/app.js                        ✎ 增量：生成面板逻辑
└── css/style.css                    ✎ 增量：生成面板样式
```

### 2.4 数据流（含回流边）

链路不是单向的，有**四条回流边**，这是「生成 ≠ 一次成功」的工程化保障：

```
                                 ┌──────────────── ④ 抽取低置信 → 结构化追问
                                 │
  ①NL ──▶ ②Parser ──▶ ③Composer ──▶ ④Validator ──▶ ⑤SemanticCheck ──▶ 用户确认
              ▲             ▲            │                │
              │             │            │                │
              │      ┌──────┴────────────┘                │
              │      │ ② validator 失败 → 带错误码重试抽取  │
              │      │   (code/path 精确定位到槽位)         │
              │      └───────────────────────────────────┘
              │                       │
              │                       └──── ③ 回译不一致 → 定位槽位重抽
              │
              └───────────────────────── ④ engine 试算异常 → 给替代建议
```

| 回流边 | 触发条件 | 动作 |
|---|---|---|
| ① → 追问 | `combine` 槽位 `confidence < 0.6`，或必填槽位缺失 | 抛结构化追问，不进组装 |
| ② → 重试 | validator 返回 `level: 'error'` | 把 `{code, path}` 回灌 Parser，命中错误码映射表 → 定向重抽该槽位 |
| ③ → 重抽 | `semantic-check` 发现原话关键项回译丢了 | 定位到对应字段，标记该槽位重新抽取 |
| ④ → 建议 | `RuleEngine` 试算抛异常或结果 `NaN` | 不静默，给「是不是想说 XX」替代句式 |

---

## 三、语义解析规格（Parser）

### 3.1 四层解析架构

```
输入原话："周三凉菜打八折"
   │
   ▼
┌─────────────────────────────────────────────────────────┐
│ L1  归一化层                                              │
│  · 全角 → 半角（１２３ → 123，" → "）                      │
│  · 口语数字 → 阿拉伯（八折 → 8折，三份 → 3份，两百 → 200）  │
│  · 中文标点 → 去除/切分（，。！？、→ 分隔符）               │
│  · 同义词预替换（打折→折扣，几折→折）                       │
│  产出：规范串 "周三凉菜打8折"                              │
└─────────────────────────────────────────────────────────┘
   │
   ▼
┌─────────────────────────────────────────────────────────┐
│ L2  词典层（最长匹配优先）                                 │
│  · 扫描规范串，从每个位置取「最长命中」的词条               │
│  · 命中即打标：{span, field, value, lexicon}              │
│  · 「凉菜」命中 cat_cold，但若「凉菜拼盘」在词典中则优先     │
│  产出：[cat_cold(2,4), discountRate=0.8(6,8), days=WED(0,2)]│
└─────────────────────────────────────────────────────────┘
   │
   ▼
┌─────────────────────────────────────────────────────────┐
│ L3  模板层（句式骨架匹配 + 自带 combine 语义）              │
│  · 用已命中的词条 span 位置，反推命中了哪条模板             │
│  · 模板自带 combine：如「{日期} {品类} {动作}」→ all       │
│  · 没命中任何模板 → 走降级（追问 / 候选 / 能力清单）        │
│  产出：模板 "tpl_time_dish_action" + 槽位绑定              │
└─────────────────────────────────────────────────────────┘
   │
   ▼
┌─────────────────────────────────────────────────────────┐
│ L4  组装层（产出 Slot）                                    │
│  · 每个槽位带 source 与 confidence                        │
│  · 模板 default 补的槽位 confidence 降档                   │
│  · combine 低置信时必须标 needsConfirm: true               │
│  产出：Slot 对象（见 §3.2）                                │
└─────────────────────────────────────────────────────────┘
```

### 3.2 Slot 契约（唯一接口）

**这是本 PRD 最重要的一段。** Parser 无论规则版还是 LLM 版，最终都必须产出这个形状：

```js
// Slot —— Parser 的唯一输出，Composer 的唯一输入
{
  rawText: "周三凉菜打八折",

  // 条件槽位（每个条件字段一个槽）
  conditions: [
    {
      field: "days",
      value: ["WED"],
      source: "lexicon",            // lexicon | template-default | infer
      confidence: 0.98,
      span: [0, 2],                 // 原话中的字符区间，用于 UI 高亮
      lexiconId: "day.wed",
      evidence: "周三"
    },
    {
      field: "categories",
      value: ["cat_cold"],
      source: "lexicon",
      confidence: 0.95,
      span: [2, 4],
      lexiconId: "cat.cold",
      evidence: "凉菜"
    }
  ],

  // 动作槽位（必有一个且仅一个主动作）
  action: {
    type: "discountRate",
    value: { rate: 0.8 },
    source: "lexicon",
    confidence: 0.97,
    span: [6, 8],
    evidence: "八折"
  },

  // 组合语义（critical，绝不默认）
  combine: {
    value: "all",                   // all | any | not
    source: "template-default",     // 关键：来自模板而非用户明说
    confidence: 0.72,
    needsConfirm: true,             // 低置信 → UI 必须显式确认
    reason: "句式未出现「或/都/任一」等连接词"
  },

  // 规则级选择语义（v2.1 新增，PRD §14.1 C 档；v2.2 收缩）——**可以缺省**
  // 与 combine 的区别：combine 管「同一条规则内多个条件怎么组合」；
  //                   select 管「多条并列候选规则之间怎么二选一」。
  // 只有出现「任选一个」这类词面时才产出。
  select: {
    group: "sg_line_tpl_date_cat_action",  // 并列组 id，同组规则互为候选
    mode: "manual",                        // v2.2：manual | priority（'best' 已移除）
    source: "lexicon",                     // 同 conditions 的三档语义
    confidence: 0.95,
    span: [9, 15],
    lexiconId: "select.mode.manual",
    evidence: "任选1个",
    needsConfirm: true,                    // 选择方式影响毛利，必须让人过一眼
    reason: "原话出现并列组选择词「任选1个」"
  },

  // v2.2 新增：候选集「取优意图」信号（**不是** select 模式）
  // 原话出现「哪个便宜用哪个」这类词面时产出：表达"这组要挑一条最优的"，
  // 但"最优"的口径（价格/毛利/客户等级/库存）不属于 DSL 可定义范围
  // → 交由程序侧对运行期 selectGroups[*].candidates 算法筛选。
  candidateHint: {
    kind: "algorithm-required",
    reason: "algorithm-required",
    source: "lexicon",
    span: [12, 20],
    lexiconId: "select.intent.algorithm",
    evidence: "哪个便宜用哪个",
    needsConfirm: true,
    note: "原话表达了「并列组内取优」意图，但"最优"口径不属于 DSL 可定义范围。"
  },

  // 元信息
  stage: "line",                    // 由 action.type 反查得出
  template: "tpl_date_cat_action",
  unmatchedTokens: [],              // 没吃下的片段，非空即需关注
  needsConfirm: false,              // 整体是否需追问（任一槽位低置信即 true）
  questions: []                     // 结构化追问项
}
```

### 3.2.1 规则级选择语义 `select`（v2.1 新增；v2.2 收缩为两模式；v2.2.1 语义落定）

`select` 是 **C 档方案**的落地形态：**选择语义在生成端就写进 DSL**，而不是等运行期补救。

> **⚠️ v2.2.1 核心口径（用户原话）**：「manual 模式下只是给出候选结果，不直接做出选择，
> 所以**产出候选集合后，规则已经完成使命**。」
>
> 这条口径统一了两种模式：**候选规则不参与定价**。产出候选集后规则即退场 ——
> 引擎 **不**代替选择者挑一条去改价，**也 不**因"没人选"而挂起定价。
> ⇒ 两种模式对**定价路径**的影响**完全一致（都为零）**，差异只在**候选集的消费方**。

| 字段 | 取值 | 含义 |
|---|---|---|
| `select.group` | `sg_<stage>_<tplId>_<base36>` | 并列组标识。**同组规则互为候选** |
| `select.mode` | `manual` | 候选集交**收银员**（POS 侧）选择；选择结果由 POS 结算流程**自行应用** |
| | `priority` | 默认值。候选集交**程序侧算法**筛选（向后兼容） |

#### ⚠️ v2.2 为什么移除 `best`（重要设计决策）

v2.1 曾定义三模式（含 `best` = 组内自动比价取最优惠）。**v2.2 移除 `best`**，理由是它在 DSL 层存在**语义缺陷**：

> **规则产出的动作类型可能不一样** —— 折扣率（8 折）vs 固定金额（减 5 元）vs 赠品 vs 会员价。
> 「最优」没有统一可比较的口径：按让利金额算？按到手价算？赠品怎么折算？
> **把比价逻辑写进规则 = 让 DSL 承担它无法定义的语义。**

**改为：DSL 只负责"暴露候选活动集合"，"选哪条"由程序侧算法决定。**

| | v2.1（已废弃） | v2.2（现行） |
|---|---|---|
| DSL 声明 | `select: "best"` | 不声明；`candidateHint.kind = "algorithm-required"` |
| 比价者 | 引擎（按价格最低） | **调用方程序**（可按毛利/客户等级/库存/互斥关系任意口径） |
| 引擎职责 | 自动选一条并生效 | 只算清**每条候选各自会把这一行定到什么价**，暴露 `selectGroups[sg].candidates` |
| 参考口径 | 就是决策 | `isBest` / `bestPrice` 降级为**只读参考**（按价格最低排序），不参与定价 |

**引擎返回的候选活动集合形态**（`resolveLine` 返回体的 `selectGroups`）：

```js
selectGroups: {
  "sg_line_adhoc_xxx": {
    mode: "priority",          // 或 "manual"
    bestRuleId: "r_..._1",     // 只读参考：按价格最低
    bestPrice: 22.4,           // 只读参考
    chosenRuleId: null,        // 消费方告知所选时非空（**仅审计展示**）
    fromManual: false,
    suboptimal: false,         // 所选偏离参考最优 → true（供 UI 提示毛利影响）
    pending: false,            // ⚠️ v2.2.1 起**恒为 false**（不再有"挂起"语义）
    readonly: true,            // priority → true，表示"交程序侧算法筛选"
    candidates: [              // ← 消费方（程序算法 / 收银员）的输入面
      { ruleId, label, kind, price, priority, isBest, isChosen }
    ]
  }
}
```

`chosenMap`（`resolveLine(ctx, {chosen:{sg:ruleId}})`）**只是消费方告知"我选了哪条"**，
引擎记录并在候选集里标 `isChosen` 供展示/对比，**不**据此改写定价。

**两种模式的差异**（⚠️ 注意：**定价路径无差异**）：

| mode | `candidates` | 候选集消费方 | 对定价路径的影响 |
|---|---|---|---|
| `manual` | 有（`readonly: false`） | **收银员**（POS 侧） | **零** —— 本组不施加任何优惠；价格照原样走 |
| `priority` | 有（`readonly: true`） | **程序侧算法** | **零** —— 完全不影响既有 `group` 互斥 |

> ⚠️ **实现踩坑（已修两轮）**：
> ① 早期实现让 `priority` 也登记候选桶并走"待选"分支，导致规则明明没要求人工选，
>   价格却永远卡在 `pending` 上算不出来（`priority` 必须完全等同无 `selectGroup`）。
> ② v2.2 一度保留"manual 选中即 `applied.push` 生效"，与「规则完成使命」口径冲突 ——
>   v2.2.1 已移除：**候选规则永不入 `applied`**。

**与 `group` 的正交性**（易混点，必须分清）：

| 字段 | 语义 | 典型场景 |
|---|---|---|
| `group`（既有） | 同组**互斥**：命中多条时按优先级取一，其余作废 | 「会员价」组内只允许一个会员折扣 |
| `selectGroup`（新增） | 并列**候选**：同组多条摆出来让人选/比价，**语义上都是"可能生效"的** | 「八折 or 减5元，任选一个」 |

两者可同时存在：一条规则可以既属于互斥组 `group`，又属于并列组 `selectGroup`。

**⚠️ 与 `bestOf` 动作的区别**（同样易混）：

| 机制 | 层级 | 含义 |
|---|---|---|
| `then.type = "bestOf"` | **动作级** | **一条**规则内部，多个动作候选（85折/减8元/卖16.8元）比价取优 |
| `select.mode`（v2.2 仅 manual/priority） | **规则级** | **多条**规则之间**怎么选**（人选 / 按老逻辑） |
| `candidateHint` + `selectGroups[*].candidates` | **规则级 → 程序侧** | **多条**规则之间**选哪条**，交由程序算法决策 |

**⚠️ 词典层面的词面冲突（实现踩坑）**：`act.bestof` 与（v2.1 的）`select.mode.best` 曾有 3 个重词（`取最优惠`/`哪个便宜算哪个`/`自动取优`）。`scanLongest` 是 non-overlapping 且命中即 `break`，两条同词面时谁先命中取决于排序稳定性，会出现"随机行为"的静默 bug。**v2.2 的结论**：这几个词面归 `act.bestof`（动作级）独占；取优意图由新角色 `__selectintent__`（条目 `select.intent.algorithm`）承接，只收不可能出现在 bestOf 枚举语境的词面（如「选最便宜」「哪个…用哪个」）；同时 `buildLexiconIndex` 的同长度排序已加 `order` 稳定兜底。

### 3.3 `source` 三档语义

| source | 含义 | UI 表现 | 处理策略 |
|---|---|---|---|
| `lexicon` | 词典直接命中，用户明说了 | 绿色高亮 + 显示命中词条 | 直接用 |
| `template-default` | 用户**没说**，模板骨架补的默认值 | 黄色虚线下划线 + 「补」角标 | 置信度降档；低于阈值 → 必追问 |
| `infer` | 从上下文/其他槽位推理得出 | 蓝色点线 + 「推」角标 | 置信度最低；一律进入确认清单 |

### 3.4 `confidence` 三档规则

不追求精细概率，只分三档，便于 UI 与决策统一：

| 档位 | 区间 | 决策 |
|---|---|---|
| 高 | `>= 0.85` | 直接用，不打扰用户 |
| 中 | `0.60 ~ 0.85` | 用，但 UI 标黄 + 进确认清单（用户可跳过） |
| 低 | `< 0.60` | **不许用**。走降级：必填缺 → 追问；歧义 → 候选卡；超能力 → 能力清单 |

**置信度计算公式（规则版，确定性可复现）：**

```
base = 1.0
if source === 'lexicon'          base = 0.95
if source === 'template-default' base = 0.75
if source === 'infer'            base = 0.65

// 最长匹配加分：命中词条越长越可信
if 命中长度 >= 3字符: base += 0.03

// 未命中残留惩罚
base -= 0.05 * unmatchedTokenCount

// 模板完整度加分
if 模板所有必填槽位均已填: base += 0.05

confidence = clamp(base, 0, 1)
```

### 3.5 combine 的特殊地位

**这是全链路最容易出静默错误的地方，必须单独强调。**

中文口语里「和 / 或 / 都 / 任一」经常省略。用户说「会员或者周末」，机器若默认成 `all`，生成的规则**永不触发**（要求同时是会员且是周末），而回译文案「会员且周末」用户可能扫一眼就点了确认。

| 情况 | 错误做法 | 正确做法 |
|---|---|---|
| 原话有「或/或者/任一/其中之一」 | — | `combine = any`，`confidence` 高 |
| 原话有「都/且/同时/并且」 | — | `combine = all`，`confidence` 高 |
| 原话有「不/非/除…外」 | — | `combine = not`，`confidence` 高 |
| **原话无连接词** | ❌ 默认 `all` | ✅ `combine = all` 但 `source = 'template-default'`、`confidence <= 0.75`、`needsConfirm = true`，**UI 必须让用户明确点选 且 / 或** |

UI 上这三态必须做成**并列可点选**的卡片，而非一行小字：

```
┌──────────────────────────────────────────┐
│ ⚠ 我没听出连接关系，请确认是哪种？          │
│                                          │
│  ○ 全部满足（且）   会员 且 周末            │
│  ● 任一满足（或）   会员 或 周末            │
│  ○ 排除（非）       除 特价菜 外            │
└──────────────────────────────────────────┘
```

---

## 四、词典规格（`data/parser-lexicon.json`）

### 4.1 词典来源：复用 translator.js 的反向映射

`translator.js` 行 35-98 已有 5 张成熟的中文表，这是**零成本拿到的词典种子**：

| translator 常量 | 反向映射所得词典条目 | 条数 |
|---|---|---|
| `MEMBER_TAG_CN` | 生日当月→`memberTags:birthday`、新会员→`new_member`、黑金卡→`black`、学生/长者/员工/企业客户 | 8 |
| `DATE_TAG_CN` | 周末→`dateTags:weekend`、工作日→`workday`、节假日→`holiday`、会员日→`member_day`、店庆日→`store_anniversary`、双十一/元旦/春节/国庆 | 11 |
| `DISH_TAG_CN` | 特价菜→`tags:特价菜`、招牌菜、新品、不参与优惠、加购品、限时 | 6 |
| `ALLOCATE_CN` | 按行金额比例分摊→`byLineAmount`、按数量分摊→`byQty`、全部摊到最便宜的行→`toCheapest`、不减行→`none` | 4 |
| `TIME_FIELD_CN` | 时间/下单时间/开台时间/结账时间 | 4 |
| `RANGE_FIELD_INFO` | 单点N份以上→`lineQty:{min}`、订单共N份→`orderQty`、订单满N元→`orderAmount:{min}`、用餐N人→`guestCount`、商品单价N元→`priceRange` | 5 |

**再加两类必须手写的：**

| 类别 | 示例 | 来源 |
|---|---|---|
| 品类词 | 热菜→`cat_hot`、凉菜→`cat_cold`、点心→`cat_dim_sum`、烧烤→`cat_bbq`、汤品→`cat_soup`、主食→`cat_staple`、酒水→`cat_drink`、加购品→`cat_addon` | `dao-xiang-dishes.json` 的 `categories` |
| 会员等级 | 普通会员→`normal`、白银/白银卡→`silver`、黄金/金卡→`gold`、钻石→`diamond` | `MEMBER_LEVEL_CN` + `memberLevels` |
| 菜品名 | 水煮鱼→`dish_001`、虾饺→`dish_201`… | `dao-xiang-dishes.json` 的 `dishes`（36 条） |

### 4.2 条目结构

```json
{
  "version": "1.0",
  "source": "reverse-mapped from translator.js + dao-xiang catalog",
  "entries": [
    {
      "id": "cat.cold",
      "words": ["凉菜", "凉拌", "冷菜", "冷盘"],
      "field": "categories",
      "value": ["cat_cold"],
      "weight": 1.0,
      "note": "品类，最长匹配可被「凉菜拼盘」覆盖"
    },
    {
      "id": "rate.8zhe",
      "words": ["八折", "8折", "打八折", "80%"],
      "field": "__action__",
      "actionType": "discountRate",
      "value": { "rate": 0.8 },
      "weight": 1.0
    },
    {
      "id": "day.wed",
      "words": ["周三", "星期三", "礼拜三"],
      "field": "days",
      "value": ["WED"],
      "weight": 1.0
    },
    {
      "id": "combinator.or",
      "words": ["或者", "或", "任一", "其中之一", "任意一个"],
      "field": "__combine__",
      "value": "any",
      "weight": 1.0
    }
  ]
}
```

**特殊 `field` 约定：**

- `__action__`：命中即填 `Slot.action`
- `__combine__`：命中即填 `Slot.combine`（且 `source = 'lexicon'`、高置信）
- `__negate__`：命中「不/非/除…外」→ `combine.value = 'not'`

### 4.3 最长匹配算法

```
输入规范串 S，位置 i = 0
结果命中集 H = []
while i < len(S):
    # 从当前位置找最长命中
    best = null
    for each entry in lexicon:
        for each word in entry.words:
            if S.startsWith(word, i):
                if best === null || word.length > best.word.length:
                    best = { entry, word, start: i, end: i + word.length }
    if best !== null:
        H.push({ span:[best.start, best.end], ...best.entry })
        i = best.end          # 最长匹配，吞掉整个词
    else:
        i += 1                # 未命中，右移一格
```

**为什么必须最长匹配：** 若词典同时有「卡」（`memberLevel`）和「金卡」（`gold`），逐字扫描会先命中「卡」，导致「金卡会员」被解析成普通会员。最长匹配保证 `i` 直接跳到词尾。

**性能：** 词典 ~300 条，每条平均 3 个词面，一次解析 ~2000 次 `startsWith` 比较，原话长度 < 50，总比较量 < 10 万次，同步执行无感。

### 4.4 词典维护约定

- 词典是**数据**：运营可直接编辑 `data/parser-lexicon.json` 加词，无需改代码
- 词典是**离线加载**：改完必须跑 `cd Output && node build-embed.js` 重新生成 `js/embed-data.js`（与现有 `data/*.json` 同规则）
- 词典是**可审计**：`Slot.lexiconId` 记录命中的词条 id，UI 可显示「我是从『金卡』这个词认识 gold 的」

---

## 五、模板规格

### 5.1 模板的作用

词典层只知道「这句话里有哪些词」，不知道「这些词谁修饰谁」。模板层解决的是**结构**：哪个是条件、哪个是动作、多个条件之间什么关系。

**模板自带 combine 语义**——这是避免「默认 all」灾难的关键：模板不是中性的骨架，而是**带语义的骨架**。

### 5.2 模板定义

```js
{
  id: "tpl_date_cat_action",
  name: "日期 + 品类 + 动作",
  pattern: ["__date__", "__category__", "__action__"],   // 顺序槽位骨架
  combine: "all",                    // 骨架天然是「且」——因为修饰关系明确
  combineSource: "template-default", // 但仍标记为「模板补的」
  examples: ["周三凉菜打八折", "周末热菜8折"],
  stage: "line"
}
```

### 5.3 模板清单（覆盖稻香 22 条规则）

| # | 模板 id | 句式骨架 | combine 语义 | 对应稻香规则 |
|---|---|---|---|---|
| 1 | `tpl_time_cat_action` | 时段 + 品类 + 动作 | all | r_lunch_dim_sum_90、r_tea_time_dim_sum、r_dinner_hot_88、r_late_night_bbq |
| 2 | `tpl_time_dish_action` | 时段 + 菜品 + 动作 | all | r_lunch_5specials、r_addon_winter_melon |
| 3 | `tpl_date_cat_action` | 日期/星期 + 品类 + 动作 | all | r_weekend_cold_80、r_workday_cold_85 |
| 4 | `tpl_datetag_dish_action` | 日期标签 + 菜品 + 动作 | all | r_holiday_fish_49 |
| 5 | `tpl_date_only_action` | 具体日期 + 动作 | — | r_store_anniv_78 |
| 6 | `tpl_memberlevel_cat_action` | 会员等级 + 品类 + 动作 | all | r_member_gold_price、r_member_silver_price |
| 7 | `tpl_membertag_action` | 会员标签 + 动作 | — | r_member_birthday_85 |
| 8 | `tpl_datetag_action` | 日期标签 + 动作 | — | r_member_day_extra_95 |
| 9 | `tpl_time_dish_condition_action` | 时段 + 指定菜品 + 就餐人数/金额 + 加购菜 + 动作 | all | r_addon_pigeon |
| 10 | `tpl_bestof` | 品类/菜品 + 「取最优」+ 多个候选动作 | — | r_dim_sum_best_of |
| 11 | `tpl_not_tag` | 「排除/不参与」+ 标签 + 动作 | not | r_no_promo_exclude |
| 12 | `tpl_order_amount_reduce` | 订单满 N 元 + 减 M 元 | — | r_order_full_200_minus_20、r_order_full_500_minus_80 |
| 13 | `tpl_order_amount_gift` | 订单满 N 元 + 赠 X | — | r_order_gift_peanut |
| 14 | `tpl_member_order_gift` | 会员等级 + 订单满 N 元 + 赠 X | all | r_order_member_gift |
| 15 | `tpl_lineqty_discount` | 单点 N 份以上 + 动作 | — | （扩展） |
| 16 | `tpl_ordercount_discount` | 订单共 N 份以上 + 动作 | — | （扩展） |
| 17 | `tpl_pricerange_action` | 单价 N 元以上 + 动作 | — | （扩展） |
| 18 | `tpl_guestcount_action` | 用餐 N 人及以上 + 动作 | — | （扩展） |
| 19 | `tpl_hasdish_action` | 点了某菜 + 动作 | — | （扩展） |
| 20 | `tpl_maxqty` | 限 N 份 | — | r_addon_pigeon |

### 5.4 模板匹配算法

模板匹配在词典命中**之后**做。因为模板骨架里写的是**语义槽**（`__date__` / `__category__` / `__action__`），而词典命中结果正好带 `field`，于是可以做**位置序匹配**：

```
词典命中序列（按 span.start 排序）：
  [ {field:'days',  span:[0,2]},        // 周三
    {field:'categories', span:[2,4]},   // 凉菜
    {field:'__action__', span:[6,8]} ]  // 八折

→ 映射为语义类型序列： [date, category, action]

遍历模板清单，找 pattern 完全匹配的模板：
  tpl_date_cat_action  pattern = [__date__, __category__, __action__]  ✅ 命中

→ 取模板的 combine 语义：all（source = template-default）
```

**匹配失败的处理（三种降级）：**

| 失败形态 | 判断依据 | 降级动作 |
|---|---|---|
| 有命中但结构不成型 | 语义序列非空但无模板匹配 | 抛**候选卡**：列出「你可能是想……」，给 2-3 个最接近模板的填空预览 |
| 几乎无命中 | 命中数 == 0 | 抛**能力清单**：列出本系统支持的句式示例 |
| 有结构但动作缺失 | 匹配到部分模板，缺 `__action__` | 抛**追问**：「那要怎么优惠？」 |

---

## 六、组装规格（Composer）

### 6.1 职责：Slot → DSL，纯确定性

Composer **不做任何语义判断**，只做机械映射。同一份 Slot 永远产出同一份 JSON（除 `id` 的时间戳外）。

### 6.2 条件组装

Slot 的 `conditions` 数组 + `combine` 槽 → `rule.when`：

```
conditions.length == 1
  → when = { [field]: value }                    // 单条件不包 combine

conditions.length > 1 && combine == 'all'
  → when = { all: [ {f1:v1}, {f2:v2}, ... ] }

conditions.length > 1 && combine == 'any'
  → when = { any: [ {f1:v1}, {f2:v2}, ... ] }

conditions.length > 1 && combine == 'not'
  → when = { not: { [field]: value } }           // not 只取单一主体，其余作前置
```

**注意嵌套深度：** engine 最大支持 5 层。v1 单句生成最多 3 个条件，天然不会超限；若未来多句合并需加深度检查（用 validator 的 `WHEN_DEPTH` 错误码拦截）。

**口径对照（关键，容易写错）：**

| Slot 槽位值（内部规范） | DSL 输出 | 备注 |
|---|---|---|
| `days: ["WED"]` | `"days": ["WED"]` | 大写英文缩写，与 engine `DAY_INDEX` 一致 |
| `openTime: [["17:00","21:00"]]` | `"openTime": [["17:00","21:00"]]` | **双层数组**（可多时段） |
| `orderAmount: { min: 200 }` | `"orderAmount": {"min": 200}` | 范围对象，字段名是 `min`/`max` |
| `guestCount: { min: 4 }` | `"guestCount": {"min": 4}` | 同上 |
| `memberLevel: ["gold"]` | `"memberLevel": ["gold"]` | 小写英文，非中文 |
| `dateTags: ["weekend"]` | `"dateTags": ["weekend"]` | 同上 |
| `dates: ["10-28"]` | `"dates": ["10-28"]` | `MM-DD` 格式 |
| `dishUids: ["dish_001"]` | `"dishUids": ["dish_001"]` | 由菜品名经商品索引转 uid |

### 6.3 动作组装

| Slot `action.type` | Slot `action.value` | DSL 输出 | stage |
|---|---|---|---|
| `discountRate` | `{ rate: 0.8 }` | `{"type":"discountRate","rate":0.8}` | line |
| `fixedPrice` | `{ price: 49.9 }` | `{"type":"fixedPrice","price":49.9}` | line |
| `discountAmount` | `{ amount: 8 }` | `{"type":"discountAmount","amount":8}` | line |
| `maxQty` | `{ qty: 1 }` | `{"type":"maxQty","qty":1}` | line |
| `memberPrice` | `{ rate: 0.9 }` | `{"type":"memberPrice","rate":0.9}` | line |
| `bestOf` | `{ options: [...] }` | `{"type":"bestOf","options":[...]}` | line |
| `orderReduce` | `{ amount: 20, allocate: "byLineAmount" }` | `{"type":"orderReduce","amount":20,"allocate":"byLineAmount"}` | **order** |
| `gift` | `{ dishUid, dishName, qty }` | `{"type":"gift","dishUid":"dish_703","dishName":"椒盐花生米","qty":1}` | **order** |

**stage 由 action.type 反查，不由用户指定：**

```js
stage = LINE_ACTIONS.indexOf(actionType) >= 0 ? 'line'
      : ORDER_ACTIONS.indexOf(actionType) >= 0 ? 'order'
      : 'line';   // 兜底
```

这是为了让「用户说满200减20」不需要知道 `orderReduce` 属于 order stage——**把领域知识固化在系统里，而不是逼用户学**。

### 6.4 元字段生成

| 字段 | 生成规则 |
|---|---|
| `id` | `'r_gen_' + Date.now().toString(36) + '_' + seq`，保证唯一且可追溯来源 |
| `label` | **取回译文案**（由 Translator 反算）作为 human-readable label；与语义 diff 交叉校验 |
| `stage` | 由 action.type 反查（见 6.3） |
| `group` | 由 action.type + 条件特征映射到 `GROUP_CN` 中的分组键；无法判定时给 `'custom'`（app.js 需补一个中文名） |
| `priority` | **默认 100**。规则冲突（同 group 同 stage）时提示用户手动调，v1 不自动推算 |
| `enabled` | `true` |

**group 映射表（v1）：**

| 动作类型 | 主要条件特征 | group |
|---|---|---|
| discountRate / fixedPrice | 含 `openTime` | `time_price` |
| discountRate | 含 `days`（工作日） | `daily_discount` |
| fixedPrice | 含 `dateTags: holiday` | `holiday_special` |
| discountRate | 含 `memberLevel` | `member_price` |
| discountRate | 含 `memberTags` | `member_benefit` |
| fixedPrice / maxQty | 含 `hasDish` + `dishUids`（加购品） | `addon_deal` |
| bestOf | — | `best_of_demo` |
| discountRate（rate=1） | 含 `not` | `exclusion` |
| orderReduce | — | `order_promo` |
| gift | — | `order_gift` |

**⚠️ group 的实体边界（对齐 PricePolicyService §3「合并匹配键三级」）：** 本链路产出的 `group` 不是自由文本，它要能被服务端的合并逻辑（`id` → `(group, Canonical(when))` → `(group, priority)` 三级键）识别成「修改同一份策略里的同一条规则」。因此：

1. **group 必须从 `GROUP_CN` 的闭集里取**（12 个键），不能生成新键——生成 `'custom'` 时 `app.js` 需补中文名，且该 key 不参与语义合并。
2. **同一句原话的多次生成，group 必须稳定**。上表是「动作类型 + 条件特征」的确定性映射，不含任何随机成分——这是「同一份 Slot 必产出同一份 JSON」的前提。
3. **priority 默认 100 是 v1 的安全选择**：服务端第三级合并键是 `(group, priority)`，若本链路自动推算 priority，可能**误撞**店里已有规则的同组同优先级 → 被服务端当成「修改」而**继承旧条件**（静默合并，范围扩大）。固定 100 使碰撞面最小，碰撞时由服务端 `rule.inherit_uncheckable` 提示店长核对，符合「不确定就问人」纪律。

**⚠️ `group` 与 `selectGroup` 的边界（v2.1，正交性）：** 这两个字段名字像、层级也像，但语义**完全正交**，不可互相替代：

| | `group`（§6.4，既有） | `selectGroup`（§14.1 C 档，新增） |
|---|---|---|
| 语义 | 同组**互斥** | 同组**并列候选** |
| 命中多条时 | 按优先级取一，其余**作废** | 摆在一起**比价取优**或**挂起等人选** |
| 默认值 | 必须有（从 `GROUP_CN` 闭集取） | 可缺省（缺省 = 不构成并列组，走老行为） |
| 取值来源 | 「动作类型 + 条件特征」确定性映射表（上表） | 生成端由并列句切分产出，命名 `sg_<stage>_<tplId>_<base36>` |
| 校验规则 | 同组同 stage | 引用同一 `selectGroup` 的规则**必须同 stage**；有 `select` 必须有 `selectGroup` |

**关键纪律**：`selectGroup` **不参与**服务端三级合并键（`id` → `(group, Canonical(when))` → `(group, priority)`）的判定——它是运行期的**选择提示**，不是合并键。因此：

1. 并列组内的候选规则**仍各自有独立的 `group`**（可为同一个也可不同），互斥关系照旧生效；
2. 是否「并列」由 `selectGroup` 决定，是否「互斥」由 `group` 决定，两条链路**互不干扰**；
3. 老文档（无 `selectGroup`）走 `select = priority` 的缺省分支，行为**字节级不变**——这是 C 档能安全落地的底线。

### 6.5 整体输出

```json
{
  "rules": [
    { "id": "r_gen_...", "label": "...", "stage": "line", "group": "...", "priority": 100, "enabled": true,
      "when": { ... }, "then": { ... } }
  ],
  "global": { "minRate": 0.7, "minRateNote": "全局最低折扣钳制：最终行价不得低于原价 × 0.7。" }
}
```

`global.minRate` **默认 0.7 不由 Parser 决定**，而是从当前场景策略文档（如 `dao-xiang-policy.json` 的 `global`）继承。用户若要改，走单独的输入（如「最低折扣别低于六折」→ 更新 `global.minRate = 0.6`）。

### 6.6 语义等价动作的收敛口径（对齐 PricePolicyService §3）

同一个「打折」意图，`translator.js` 能回译出「打八折」，但 DSL 层面有**两种等价写法**：`discountRate{rate:0.8}`（按当前价乘）与 `discountAmount{amount:X}`（减固定额）。**Composer 必须收敛到唯一一种，否则同一句话可能产出两份语义不同、回译相同、diff 为空但算价不同的规则。**

**收敛规则（写死，不做语义判断）：**

| 用户表述形态 | Composer 产出 | 理由 |
|---|---|---|
| 「打X折」「X折」「打折到X%」——比率语义 | `discountRate{rate}` | 与 `translator.rateToCn` 双向可逆 |
| 「减X元」「便宜X元」「立减X」——绝对额语义 | `discountAmount{amount}` | 与 `RANGE_FIELD_INFO.orderAmount` 单位一致 |
| 「卖X元」「定价X元」「X元一份」——终价语义 | `fixedPrice{price}` | 用户给了终价就不要再换算成折扣（换算会引入尾数） |

**⚠️ 禁止的推算：** 不允许 Composer 把「减8元」倒算成 `discountRate`（需要知道商品原价，而原价是行级运行期数据，组装期不可得）。也不允许把「打八折」倒算成 `discountAmount`。**用户在哪个语义层说，就落在哪个语义层**——这条和 PricePolicyService §3「理解活归模型/结构活归服务端」是同一纪律：需要上下文才能算的值，一律不猜。

---

## 七、三层校验规格

### 7.1 第一层：Validator（闭集合法性）

直接调 `PricePolicyValidator.validate(policyDoc)`，13 项 CHECKLIST 全跑：

```
'JSON 语法正确' / 'schemaVersion 合法' / '规则 ID 唯一性' / '条件字段闭集校验'
'动作类型闭集校验' / 'stage 与动作匹配' / '数值值域合法' / '时间格式正确'
'范围对象格式正确' / 'bestOf 选项非空' / '同组同 stage' / 'minRate 值域 [0,1]'
'selectGroup / select 合法'     ← v2.1 新增（PRD §14.1 C 档）
```

**关键：错误码回灌机制。** validator 返回的都是结构化 `{code, message, path, level}`，`path` 精确定位到出错的字段（如 `rules[0].when.openTime`）。把它映射回 Slot，就能**定向重抽**而不是整体重来：

| validator 错误码 | Slot 定位 | 重抽动作 |
|---|---|---|
| `FIELD_UNKNOWN` | `conditions[i].field` | 该槽位字段名非法 → 去掉，回到词典层找该 span 的其它可能 |
| `RANGE_INVALID` | `conditions[i].value` | 范围对象非法（如 `min > max`）→ 重新解析数字 |
| `RANGE_MIN_TYPE` / `RANGE_MAX_TYPE` | 同上 | 值不是数字 → 归一化层数字转换有问题 |
| `TIME_FMT` / `TIME_SEG` | `conditions[i].value` | 时间格式错 → 回 L1 归一化 |
| `MEMBER_LEVEL_INVALID` | `conditions[i].value` | 会员等级不在闭集 → 词典条目配错了 |
| `ACTION_UNKNOWN` | `action.type` | 动作类型非法 → 词典 `actionType` 写错 |
| `STAGE_ACTION_MISMATCH` | `stage` + `action.type` | 组装层 stage 反查逻辑有 bug |
| `MINRATE_RANGE` | `global.minRate` | 用户说的折扣率超范围 → 追问 |
| `BESTOF_EMPTY` / `BESTOF_OPT_INVALID` | `action.value.options` | 候选动作没抽全 → 追问 |

**超过 2 次重试仍失败** → 不静默，直接展示原始错误信息 + 「我理解成这样了，你看哪里不对」，把控制权交还用户。

### 7.2 第二层：SemanticCheck（原话 vs 回译 结构化 diff）

这一层是**本链路的灵魂**。Validator 只查「JSON 是否合法」，不查「JSON 是否表达了用户想说的意思」。合法但错误，才是真正的坑。

**做法：把原话和回译都抽成「语义指纹」，做集合 diff。**

```
原话："周三凉菜打八折"
  → 指纹： { days: WED, categories: cat_cold, action: discountRate 0.8 }

回译（Translator 输出）："每周三，凉菜，打八折"
  → 指纹： { days: WED, categories: cat_cold, action: discountRate 0.8 }

diff = {}  ✅ 完全一致，放行
```

```
原话："会员或者周末凉菜都八折"
  → 指纹： { memberLevel: *, days: {SAT,SUN}, categories: cat_cold, action: 0.8, combine: any }

回译（若 combine 被误判为 all）："会员且周末，凉菜，打八折"
  → 指纹： { memberLevel: *, days: {SAT,SUN}, categories: cat_cold, action: 0.8, combine: all }

diff = { combine: { 原话: any, 回译: all } }  ❌ 拦截，定位到 combine 槽位
```

**diff 输出驱动 UI：**

| diff 类型 | UI 表现 |
|---|---|
| 回译**多**了东西 | 标红「我多加了一个条件，是不是多余？」 |
| 回译**少**了东西 | 标红「你提到的『周末』我好像漏了」 |
| 值不一致 | 标黄并列展示两个值，让用户选 |
| 仅顺序不同 | 忽略（不影响语义） |

**失败时的处理：** 不阻断，但**必须在确认按钮旁显示醒目的 diff 卡片**，用户看到后才能点确认。

### 7.3 第三层：Engine 试算（真跑一遍）

前两层都是静态检查，这层是**真跑**：

1. 用生成的规则构造临时 `RuleEngine`（或把规则合并进当前场景的 policyDoc）
2. 从当前场景用例集中挑若干条**可能相关**的用例跑 `resolveLine` / `resolveOrder`
3. 观察：是否抛异常？`price` 是否 `NaN`？钳制是否被触发（说明折扣压太狠）？

| 试算结果 | 处理 |
|---|---|
| 正常出价 | 通过 |
| 抛异常 / `NaN` | 拦截，展示异常 + 给替代建议 |
| 钳制触发（`clamped: true`） | **警告不拦截**：「这条规则算出来的价比最低折扣线还低，实际会被钳到 ¥XX，确定吗？」 |
| 规则永不命中（所有用例 `appliedRules` 都没有它） | 警告：「这条规则在现有用例里一次都没生效，是不是条件写太严了？」 |

最后一条尤其重要——**它正是「combine 默认 all」灾难的兜底网**。

### 7.4 第四层（可选）：LLM 语义复核 —— 只报不改

**先说定位：这一层不是校验，是「第二双眼睛」。** 它**不替代**前三层，**不参与判定**，只在「前三层全过、但看着可疑」时举手示警。

#### 7.4.1 为什么前三层不够，又为什么不能靠 LLM 补

前三层各有明确边界：

| 层 | 保证什么 | **不保证什么** |
|---|---|---|
| Validator | 「这是一个**合法**的 DSL 文档」 | 值填得对不对 |
| SemanticCheck | 「回译和原话**字面语义**一致」 | 前提是「回译本身正确」 |
| Engine 试算 | 「能跑出价、不崩、不太离谱」 | 出的价是不是用户要的 |

**⚠️ SemanticCheck 有一个关键盲区：它是拿「回译」当基准的，而回译是由「同一批 Slot」生成的。** 即：如果槽位本身抽错了，回译会忠实地把错误复述一遍，diff 反而是空的（它是在**自证**）。典型例子：

| 原话 | Slot 抽错成 | 回译 | diff | 实际后果 |
|---|---|---|---|---|
| 黄金会员热菜9折 | `memberLevel:["silver"]` + rate 0.95 | 「白银会员，热菜，9.5折」 | ⚠️ **非空**（等级和折扣都不同）| 能被抓 |
| 满200减20 | `orderReduce{amount:2}` | 「满200减¥2」 | ⚠️ **非空** | 能被抓 |
| 「除了特价菜，其他都打折」 | `discountRate{rate:1}` + `not:{tags:["特价菜"]}` | 「特价菜不参与」 | **空**（两者等价叙述） | ✅ 正确 |
| 「会员日**叠加**95折」 | 漏抽了「叠加」（应为 `member_stack` 语义） | 「会员日，打9.5折」 | ⚠️ 非空（少了「叠加」） | 能被抓 |
| 「大概打个八折左右」 | rate 抽成 0.8，confidence 0.55 | 「打八折」 | **空** | ❌ **漏网**——「大概/左右」的模糊性丢了 |

**结论：** SemanticCheck 能抓「值不同」，抓不住「**模糊性被抹平**」。最后一类是 LLM 唯一有优势的场景——它擅长判断「这句话的口气是否被完整传达」。

#### 7.4.2 触发条件（收得很紧）

**不是每次都调。** 只有同时满足「确定性检查全过」+ 任一可疑信号，才触发：

```js
function shouldLlmReview(slot, diffResult, engineResult) {
  if (!diffResult.ok) return false;              // diff 已经报错了，不需要 LLM 再看
  if (engineResult.blocked) return false;        // 试算已经拦了

  var minConf = minConfidenceOf(slot);           // 所有槽位里最低的
  if (minConf < 0.7) return true;                // ① 有槽位置信度偏低
  if (slot.needsConfirm) return true;            // ② 存在未消解的歧义标记
  if (slot.unmatchedTokens.length > 0) return true; // ③ 有没吃进去的片段
  if (hasVagueWord(slot.rawText)) return true;   // ④ 原话含「大概/左右/差不多/尽量」等模糊词
  return false;
}
```

第 ④ 条是**专为上面那张表最后一行的漏网 case 设计的**：原话含模糊词时，即使 diff 为空也送 LLM 复核一次。

#### 7.4.3 权限边界（最小权限，只报不改）

| 允许 ✅ | 禁止 ❌ |
|---|---|
| 返回 `{suspect: true, reason: "...", 可疑字段: "memberLevel"}` | 直接改 JSON |
| 建议「这里可能是 gold 而非 silver」 | 生成或修正 Slot |
| 标记 `needsHumanConfirm: true` | 让校验自动通过 |
| 返回 `{suspect: false}` 表示无异常 | 输出任何 DSL 字段 |

**即使 LLM 幻觉，代价也只是多一次人工确认**——不会把错 JSON 静默放行。这个界面的物理实现方式：LLM 返回的 JSON Schema 里**根本没有** `dsl` / `slot` 这两个字段，跟 §10.4 给 Slot 技能收窄 Schema 是同一手法。

#### 7.4.4 复核结果的 UI 展示

| 复核结论 | UI |
|---|---|
| `suspect: true` | 确认按钮旁加一个橙色提示条：「⚠️ 复核提示：{reason}。请确认『{可疑字段}』是否说对了。」**不阻断确认**，但强制展开 diff 卡片 |
| `suspect: false` | **什么都不显示**——不要加「AI 已复核 ✓」这种字样。一次「通过」不等于正确，加上去只会制造虚假安心，还会让用户对真正的提示脱敏 |
| 调用失败 / 超时 | 静默降级，等同未启用（**绝不可因为 LLM 挂了就阻断主链路**）|

#### 7.4.5 四层职责的最终边界（一张表说清）

```
             可复现                不可复现
        ┌──────────────────┬──────────────────────┐
  闭集   │  Validator       │   ❌ 不要在这里用 LLM │
  检查   │  ✓ 主力           │                      │
        ├──────────────────┼──────────────────────┤
  开放   │  SemanticCheck   │  LLM 语义复核         │
  语义   │  ✓ 主力（diff）   │  仅示警 · 可选        │
        ├──────────────────┼──────────────────────┤
  运行期 │  Engine 试算      │   ❌ 不要在这里用 LLM │
        │  ✓ 主力           │                      │
        └──────────────────┴──────────────────────┘
```

**一句话：能用确定性方法做的检查，一律不用 LLM；LLM 只接确定性方法有结构性盲区的那一小块，且只报不改。**

---

---

## 八、降级分流（三态）

Parser 不是万能的，遇到搞不定的输入，**必须给出有用的回应，而不是报错或瞎猜**。

### 8.1 三态判定与 UI

| 态 | 触发条件 | UI 形态 | 用户出路 |
|---|---|---|---|
| **缺信息** | 模板命中但必填槽位缺失（如只有条件没动作） | **结构化追问**：一个明确问题 + 快捷选项 | 补一句话重说，或点选项 |
| **歧义** | 词典命中 2+ 种解释，或 combine 低置信 | **并列候选卡**：2-3 个完整填空预览 | 点选一个 |
| **超能力** | 词典命中数为 0，或语义序列不匹配任何模板 | **能力清单**：可支持的句式示例，每条可点即试 | 照抄示例改 |

### 8.2 三种 UI 的具体形态

**（1）结构化追问**

```
┌─────────────────────────────────────────┐
│ 🤔 还差一个信息                            │
│                                         │
│  你说的：  周三 凉菜 ____                  │
│                                         │
│  请问：要怎么优惠？                        │
│  [ 打折    ]  [ 特价    ]  [ 减钱    ]     │
│  [ 赠品    ]  [ 限购    ]                  │
└─────────────────────────────────────────┘
```

**（2）并列候选卡**

```
┌─────────────────────────────────────────┐
│ 🤔 我有点不确定，是下面哪个意思？            │
│                                         │
│  ○ 周三 且 凉菜 → 打八折     （全部满足）    │
│  ● 周三 或 凉菜 → 打八折     （任一满足）    │
│                                         │
│  [ 都不是，我重说 ]                        │
└─────────────────────────────────────────┘
```

**（3）能力清单**

```
┌─────────────────────────────────────────┐
│ 🙇 这句话我没听懂                           │
│                                         │
│  目前我能听懂这种句式（点一下直接试）：       │
│  · 周三凉菜打八折                          │
│  · 晚市热菜八八折                          │
│  · 满200减20                              │
│  · 会员满200送甜品                         │
│  · 节假日水煮鱼特价49.9                     │
│                                         │
│  你说的：「给老客户撒点钱」  ← 未识别        │
└─────────────────────────────────────────┘
```

### 8.3 未识别片段的兜底显示

无论走哪一态，`Slot.unmatchedTokens` 里的残留片段都必须在 UI 上**原样标出**（灰色删除线），让用户一眼看到「哪些我吃掉了、哪些我漏了」：

```
原话：周三凉菜打八折 给老客户
      └──────┬──────┘ └──┬───┘
         ✅ 已理解      ❌ 没听懂
```

---

## 九、UI 规格

### 9.1 布局：在现有三栏基础上加一栏

现有布局：左栏规则列表 / 中栏规则编辑 / 右栏用例与执行。

新增「生成」页签，进入**四栏对照**（继承 §8 配色规范）：

```
┌───────────────────────────────────────────────────────────────────────────┐
│  ① 原话                ② 解析过程            ③ 生成的 JSON      ④ 回译确认    │
│ ┌──────────────────┐  ┌──────────────────┐  ┌──────────────┐  ┌──────────┐│
│ │ 你说的：          │  │ 词典命中：        │  │ {            │  │ 中文规则  ││
│ │                  │  │ ✅ 周三 → days    │  │   "rules":[  │  │          ││
│ │ 周三凉菜打八折     │  │ ✅ 凉菜 → cat_cold │  │     {...}    │  │ 每周三，  ││
│ │ ↑高亮已识别        │  │ ✅ 八折 → 0.8     │  │   ]          │  │ 凉菜，    ││
│ │ ？未识别片段       │  │                  │  │ }            │  │ 打八折    ││
│ │                  │  │ 模板命中：         │  │              │  │          ││
│ │ [🎤 语音] [清空]   │  │ tpl_date_cat_...  │  │ [复制]       │  │ ⚠ 差异:无 ││
│ │                  │  │                  │  │              │  │          ││
│ │ [ 开始解析 ]       │  │ 置信度：0.96 ✅   │  │              │  │ [确认入库]││
│ └──────────────────┘  └──────────────────┘  └──────────────┘  └──────────┘│
└───────────────────────────────────────────────────────────────────────────┘
```

### 9.2 各栏规格

**① 原话栏**

- 输入框（`textarea`，3 行），支持回车提交
- 解析后原话**保留展示**，按 `span` 做高亮：
  - `source: lexicon` → 绿色背景
  - `source: template-default` → 黄色虚线下划线
  - `source: infer` → 蓝色点线
  - 未命中 → 灰色删除线
- 语音按钮（v1 只占位，调宿主 ASR；无 ASR 时置灰 + tooltip 说明）

**② 解析过程栏**（本 PRD 新增，最关键的信任来源）

- 分区展示：
  1. **归一化结果**（原话 → 规范串，展示差异）
  2. **词典命中列表**：`原词 → 字段 → 值 → 命中词条 id`，可点击回看词典条目
  3. **模板命中**：模板名 + pattern 骨架 + 各槽位填充情况（填/空）
  4. **置信度总览**：每个槽位一个色块（绿/黄/红）
  5. **未命中片段**：灰字列出
- 用户可在此栏「为什么是这个意思」一目了然

**③ JSON 栏**

- 复用现有 `CodeMirror` 只读实例（`cmViewer` 模式）
- 生成的 JSON 实时格式化，可复制
- 若用户手动改了 JSON，**回译栏实时刷新**（利用现有 translator 的响应式）

**④ 回译确认栏**

- 大号中文规则描述（`translator.translateRule` 输出）
- **语义 diff 卡片**（SemanticCheck 结果）：
  - 无差异 → 绿色「✅ 与你的原话一致」
  - 有差异 → 黄/红卡片，逐条列出差异项
- **确认入库按钮**（主按钮，44px 高）
- 「重新说」「改为候选」副按钮

### 9.3 配色（沿用现有 §8 规范）

| 用途 | 亮色 | 深色 |
|---|---|---|
| 主色 / lexicon 高亮 | `#1677FF` | `#1677FF` |
| 模板补（template-default） | `#FAAD14` | `#FAAD14` |
| 推理（infer） | `#722ED1` | `#722ED1` |
| 置信低 / 错误 | `#FF4D4F` | `#FF7875` |
| 成功 / 无 diff | `#52C41A` | `#52C41A` |
| 未命中灰 | `#BFBFBF` | `#595959` |
| 面板底 | `#F5F7FA` | `#1F1F1F` |
| 主背景 | `#FFFFFF` | `#141414` |
| 边框 | `#D9D9D9` | `#303030` |

### 9.4 字体（沿用）

- 正文 14px
- 分区标题 16-20px
- 回译规则描述 20px（要能一眼扫完）
- 按钮最小 44px 高（触摸友好）

### 9.5 交互细节

- 解析**同步**执行（规则版 < 10ms），无需 loading，直接出结果
- LLM 版（未来）需 loading，UI 加骨架屏
- 确认入库后，新规则**插入左栏规则列表顶部**并高亮 3 秒
- 生成面板的 JSON 若与当前策略文档冲突（如 id 撞了），入库前弹确认

---

## 十、LLM 适配层（可选增强）

### 10.1 定位：LLM 不是运行时组件，是开发期工具

**结论先说：v1 不接 LLM 也能完成闭环。** LLM 的价值不在「让链路跑起来」，而在三块：

| 价值块 | 说明 | 优先级 |
|---|---|---|
| **A. 词典扩充器（最大价值）** | 离线跑批：把线上「没听懂」的原话收集起来，让 LLM 逐条产出「这句话该抽成什么 Slot」，人工审核后**转成新词典条目/新模板**。跑一轮，规则版的覆盖率就涨一截 | ★★★ |
| **B. 长尾句式兜底** | 规则版没匹配到模板时**才**调 LLM，且产出仍走同一套三层校验 + 回译确认 | ★★ |
| **C. 多轮澄清对话** | 交互层增强，把「追问」做成自然对话，不改链路 | ★ |

### 10.2 为什么只有「NL → Slot」这一格能换

| 格 | 能否用 LLM | 理由 |
|---|---|---|
| ① NL 输入 | — | 不可换（是输入） |
| ② NL → Slot | ✅ **可换** | 这正是 LLM 擅长的：理解模糊语言 |
| ③ Slot → DSL | ❌ 必须确定性 | 要保证 id 唯一、priority 推算、stage 反查；LLM 会幻觉出非法字段 |
| ④ 校验 | ❌ 必须确定性 | 现成闭集逻辑，LLM 判「合不合法」不如代码可靠 |
| ⑤ 回译确认 | ❌ 必须确定性 | 回译必须**可复现**，否则用户这次看到的是 A，下次看到 B，无法建立信任 |

### 10.3 三条红线

1. **LLM 只产出 Slot，绝不产出 DSL。** 一旦让它直接写 JSON，闭集约束就失效了（它会写出 `dishName` 这种不存在的字段）。
2. **Slot 必带 `source` 与 `confidence`。** 用户必须知道「这句话是机器听出来的，还是它猜的」，否则丧失确认权。
3. **保留重放日志。** 每次解析记录 `{rawText, slot, dsl, validatorResult, userDecision}`，这是 A 方案的原料，也是回归测试的语料库。

### 10.4 接口设计

```js
// js/parser.js（规则版，默认）
root.PricePolicyParser = {
  parse: function (rawText, ctx) { /* 同步返回 Slot */ },
  version: 'rule-1.0'
};

// js/parser-llm.js（LLM 版，骨架）
root.PricePolicyParserLLM = {
  parse: function (rawText, ctx) { /* 返回 Promise<Slot> */ },
  version: 'llm-1.0'
};
```

### 10.4.1 Slot 技能规范（LLM 实现的形态要求）

若要用 LLM 实现 `parser-llm.js`，**推荐做法不是「写一段提示词」，而是把它做成一个受 Schema 约束的技能**。三种形态的取舍：

| 形态 | 做法 | 取舍 |
|---|---|---|
| A. 提示词模板 | Slot schema + 词典摘要 + few-shot 塞进 system prompt，要求输出严格 JSON | ✅ 可用，零新增基建；但约束是「软」的，模型可能输出自由文本 |
| B. **函数调用 / tool_choice**（推荐） | 把 Slot schema 注册成 tool，强制走 function call | ✅✅ **首选**。多了**结构性约束**，模型物理上无法返回非结构化内容，schema 由运行时校验 |
| C. MCP Server / 独立技能包 | 封装成可复用的外部服务 | ⚠️ 过度设计。当前只被内部 agent 调用，多一个进程 = 多一个失败点 |

**推荐 A+B 组合：** 「技能」的实体就是**一份 JSON Schema + 一组 few-shot**——它天然是数据不是代码，跟词典同一个待遇，可随 `data/` 一起版本化。

#### Slot 技能的输出 Schema（关键：字段收窄）

```jsonc
{
  "type": "object",
  "required": ["intent", "conditions", "action", "combine"],
  "properties": {
    "intent":     { "enum": ["line_pricing", "order_promo", "unknown"] },
    "conditions": { "type": "array", "items": {
        "type": "object",
        "required": ["field", "value", "source", "confidence"],
        "properties": {
          "field":      { "enum": ["days","time","dates","dateTags","dishUids","categories","tags",
                                   "memberLevel","memberTags","lineQty","orderQty","orderAmount",
                                   "guestCount","orderTime","openTime","closeTime","hasDish","priceRange"] },
          "value":      { "type": ["string","number","array","object"] },
          "source":     { "enum": ["lexicon","template-default","infer"] },
          "confidence": { "type": "number", "minimum": 0, "maximum": 1 },
          "span":       { "type": "array" },
          "evidence":   { "type": "string" }
        }}},
    "action":     { "type": "object", "required": ["type","value","source","confidence"],
        "properties": {
          "type": { "enum": ["discountRate","fixedPrice","discountAmount","bestOf","maxQty",
                             "memberPrice","orderReduce","gift"] },
          "value": { "type": ["number","object"] },
          "source": { "enum": ["lexicon","template-default","infer"] },
          "confidence": { "type": "number", "minimum": 0, "maximum": 1 }
        }},
    "combine":    { "type": "object", "required": ["op","confidence"],
        "properties": {
          "op": { "enum": ["all","any","not", null] },
          "confidence": { "type": "number", "minimum": 0, "maximum": 1 },
          "reason": { "type": "string" }
        }}
  }
}
```

**四个设计要点，每个都对应一个已知的坑：**

| # | 设计 | 堵住的坑 |
|---|---|---|
| ① | **Schema 里没有 `rules`/`then`/`stage`/`id`/`priority`/`group`** | 模型看不见这些字段，物理上无法编造 —— 比「提示它不要编」可靠得多（对齐红线 1） |
| ② | `combine.op` 的 enum **允许 `null`，且不设 default** | Schema 层面不存在「滑向 all」的可能。模型必须显式声明或显式留空，**留空即触发追问**（对齐 §3.5 最高风险项） |
| ③ | `field` / `action.type` 用 **enum 闭集**（从 engine.js 常量生成，不手写） | 模型不可能产出 `dishName` 这种不存在的字段（对应 PricePolicyService §6-1 的实测教训） |
| ④ | `confidence` 强制 required | 低置信是 §8 降级分流的唯一触发依据，不能让它缺省（对齐红线 2） |

#### 技能的输入：给「粗筛过的词典 + 真实 few-shot」

- **不给全量词典。** ~300 条塞进提示词会稀释注意力。做法是：规则版零命中才调 LLM，且只把**粗筛后的候选词条**（按字面相似度取 top 20）塞进提示词。
- **few-shot 不要手写，从现有资产反推。** 最优质的素材是 **22 条规则的 `label` 字段 + 16 条用例**——它们是**已人工确认过的「自然语言 ↔ DSL」配对**。例如：

```
用户原话："周末凉菜八折"
对应规则 label："周末凉菜8折"    ← translator 已能确定性生成
期望 Slot：{ conditions:[{field:"days",value:["SAT","SUN"]},{field:"categories",value:["cat_cold"]}],
            action:{type:"discountRate",value:{rate:0.8}}, combine:{op:"all"} }
```

**这是项目里质量最高的示例素材，不要浪费。**

#### 级联结构：LLM 是兜底闸门，不是第一道闸门

```
rawText ──► [规则版 parser] ──命中──► Slot（零 LLM 调用，快且可复现）
                │
                └──零命中──► [LLM 技能 (Schema + few-shot + 粗筛词典)] ──► Slot
                                    │
                                    └── 无论哪条路径产出的 Slot，都走同一套 §6 组装 + §7 四层校验
```

**⚠️ 关键纪律：两条路径产出的 Slot 必须走完全相同的下游。** 不允许 LLM 路径有任何「绿色通道」——这是「可换实现」验收项（§12.2 第 8 项）的真正含义。


**切换方式：** 不硬编码。`app.js` 里一个配置项：

```js
var PARSER_IMPL = 'rule';   // 'rule' | 'llm'
var parser = PARSER_IMPL === 'llm' ? PricePolicyParserLLM : PricePolicyParser;
```

agent.js 内做 `Promise.resolve(parser.parse(...))`，同步版自动被包成 resolved Promise，**两条实现无需改 agent 以外的任何代码**。

### 10.5 词典扩充器工作流（A 方案）——推荐的 LLM 落地方式

```
线上重放日志（jsonl）
   │  筛出 needsConfirm=true 或 unmatchedTokens.length>0 的 case
   ▼
LLM 批量标注（离线，非实时）
   │  输入：rawText + 现有 Schema 说明 + 词典快照
   │  输出：建议的新词典条目（供人工审核，不直接入库）
   ▼
人工审核（UI 上一个 diff 界面：新增词条列表）
   │  勾选通过 → 合并进 data/parser-lexicon.json
   ▼
重跑 build-embed.js + 全量回归测试
   │
   ▼
规则版覆盖率提升（长期曲线向上）
```

**这条路的妙处：LLM 的产出是「新的确定性规则」而不是「一次性的答案」，价值可累积。**

### 10.6 与生产实现 `PricePolicyService.md` 的对照（重要）

项目里已有一份**跑通了的生产实现** —— `设计/PricePolicyService.md`（C# + LLM，2026-09-29 验收通过）。它不是竞争方案，而是**同一条链路的服务端版本**。逐项比对如下：

#### 10.6.1 完全吻合的部分（可直接互相印证）

| 设计点 | 本 PRD（前端演示器） | PricePolicyService（服务端生产） | 判定 |
|---|---|---|---|
| **LLM 只做「话 → 规则体」** | 红线 1：LLM 只产 Slot 不产 DSL | §3「分工原则：结构活归服务端，理解活归模型」 | ✅ **完全一致** |
| **回译是权威口径，不回译不放行** | §7.2 回译即验证环节本身 | §3 回译缺模板键 → **拒绝落库**；`summary` 是权威口径 | ✅ **完全一致**（我们的实现更宽松些，见下） |
| **不确定不许入库** | 降级三态，宁追问不默认 | §6-2「不确定生成 = 不许落库」；`errors` 非空即 `saved=false`，旧策略原样保留 | ✅ **完全一致** |
| **空壳条件必须删掉** | §8.3 未识别片段兜底；combine 不默认 all | §6-11 `DropEmptyConditions`：「空的正条件集 = 恒假，该规则永不命中」 | ✅ **同一条实测教训**，两边都踩过 |
| **词表/模板集中管理** | 词典放 `data/parser-lexicon.json`，运营可加词 | §4 `skill.md` 是「提示词 + 话术 + 回译模板单一来源」，C# 侧零硬编码 | ✅ **同一思路**（可考虑未来共享同一份词表） |
| **菜名/分类名要转成 uid** | §6.2 口径对照表 `dishUids` 由商品索引转 | §3.1 两级容错（精确层 + 向量层）、§3.2 分类名→ID | ✅ **一致**，我们简化了（见 10.6.3） |
| **合并匹配键三级** | §6.4 group 稳定性 + priority 固定 100 | §3 三级键 `id` → `(group, Canonical(when))` → `(group, priority)` | ✅ **已对齐**（本轮补充） |
| **保留重放日志** | 红线 3 | §3 `attempts` 打印、「attempts>1 是有价值的信号」 | ✅ **完全一致** |
| **每例最多 3 次尝试 = 模拟「店长再说一遍」** | §2.4 四条回流边（带错误码重抽） | §5「attempts 打印在标题里；不许用重试把模型的不稳定藏掉」 | ✅ **同一机制** |

**结论：九项核心设计全部吻合，没有冲突。** 这说明前端演示器的链路设计方向是对的。

#### 10.6.2 生产已踩过的坑 —— 本 PRD 必须提前吸收（新增进风险表）

`PricePolicyService.md` §6「实测驱动的加固（勿回退）」15 条，其中 **6 条直接适用于本链路**，应视为**已付学费的经验**：

| # | 生产教训（§6） | 对本链路的对应动作 |
|---|---|---|
| 1 | **`when` 必须进 required 且声明属性**——只写 `{"type":"object"}`，模型每次都把最难的条件整块省掉 | ✅ 已落 §10.4.1：`conditions` 在 `required` 里，且 `field` 是 enum 闭集 |
| 2 | **闸门看全量错误**（含 uid 解析错误、回译缺键），只看校验器的错误列表会漏掉「菜名没解析出来」 | ✅ 已落 §7.1 + §2.4：四层任一不过都要回流，不能只看 validator |
| 3 | **回译缺模板键 → 拒绝**（缺 `dishUids.in` 时回译输出「当：节假日」，看起来完整其实漏了「只对某道菜生效」） | ⚠️ **本 PRD 未覆盖**——已补进 §10.6.4（新增要求） |
| 4 | **示例会被模型照抄**（数字只属于该例的声明也拦不住 1.5B 抄菜名） | ✅ 已落 §10.4.1：few-shot 用真实 label；且触发条件是「规则版零命中」，天然低频 |
| 5 | **修改路径的第三级键 =(group, priority)，命中后必须继承未提到的条件维度** | ⚠️ **本 PRD 未覆盖**——已补进 §10.6.4 |
| 6 | **探测/兜底失败不许污染文档**（先建 `categories:[]` 再填 → 失败时留空数组 = 恒假） | ✅ 已落 §8.3；**这条与我们的「空壳条件」是同一个坑的两种写法** |

#### 10.6.3 本工程简化掉的部分（演示器定位，刻意不做）

| 生产能力 | 本 PRD | 理由 |
|---|---|---|
| **菜名向量容错**（向量检索 + `MinScore`/`MinMargin` 双阈值 + 强制核对提示） | ❌ 不做，只做**精确名 + 最长匹配** | ① 演示器离线、零依赖，没有 embedding 服务；② 稻香目录仅 36 菜，重名靠最长匹配足够；③ 容错的安全网是「人工确认」，而本链路**每一步都要人工确认**，容错收益低 |
| **分类包含匹配**（「冷菜」→「经典冷菜」+ 核对提示） | ⚠️ 部分做：最长匹配能处理前缀关系（「凉菜」→`cat_cold`），但**不做模糊包含** | 同上；且模糊匹配有「静默绑错分类」风险，与「不确定就问人」纪律冲突 |
| **多版本/revision/落库/档期** | ❌ 不做（无后端） | 演示器只产出 JSON，导入导出现有机制已够 |
| **专用 LLM 覆盖配置**（`PricePolicy:LLM:Provider`） | ❌ 不做 | 本链路 v1 默认不接 LLM |
| **分类/菜名的 fail-closed 拒收** | ⚠️ 降级到「歧义态候选卡」 | 前端没有「可用分类列表」的拒收话术位；候选卡能让用户点选，效果等价 |

#### 10.6.4 本轮补充（生产经验反哺，必须实现）

**补 1：回译缺模板键要显式暴露（对应生产教训 3）**

`translator.js` 已有 `checkLabelMismatch`，但**没有**「回译过程中缺模板键」的显式报告机制。新增要求：

```js
// js/semantic-check.js 内
// 回译时若某个字段没有对应的中文模板（translator 内部返回兜底值/undefined），
// 必须记录到 result.missingTemplateKeys，并在 UI 上醒目展示
// 不允许「静默回译出一个看起来完整、实际漏条件的句子」
```

这是**回译即验证**这条纪律的必然推论：回译漏了东西，验证就失效了。

**补 2：group 稳定性 + priority 固定（对应生产教训 5）**

已在 §6.4 补充「group 的实体边界」三条规则。核心是：**固定 `priority = 100` 不是偷懒，是降低误撞服务端合并键的概率**。

**补 3：`label` 的双向校验（新增）**

生产 §3 明确 `summary` 是**服务端确定性回译**、**不是模型写的 label**。本链路同理：

```
❌ 错误做法：把 LLM 写的 label 直接当规则名
✅ 正确做法：规则 label = Translator 对生成 JSON 的回译结果
            （LLM 若给了 suggestedLabel，只作为 diff 的对照项，不落库）
```

**理由：** label 是店长在确认页唯一能看懂的东西。若它来自模型，模型可以「说得好听但和 JSON 不符」——这等于绕过了回译验证。**label 必须是从 JSON 反算出来的，不是被填进去的。**

#### 10.6.5 一个可复用的对照结论

生产的「**结构活归服务端，理解活归模型**」这句话，可以直接作为本链路的总纪律映射：

| 生产（C# 服务端） | 本链路（前端） |
|---|---|
| 理解活 → LLM | 理解活 → Parser（规则版 / LLM 版） |
| 结构活 → 服务端确定性代码 | 结构活 → Composer + Validator + SemanticCheck + Engine 试算 |
| 落库前 fail-closed | 确认前 fail-closed（宁追问不默认） |

**两边是同一套哲学的两种部署形态**，未来若要打通（前端生成 → 服务端落库），`Slot` 和 DSL 就是天然的交界点——**Slot 走前端、DSL 落库**，直接用现有 `add`/`update` 的 `document` 参数即可，无需改协议。

---

## 十一、文件结构（变更清单）

### 11.1 完整结构

```
price-policy-demo/
├── index.html                       ✎ 增量：生成面板 DOM + 脚本标签
├── README.md                        ✎ 增量：补「自然语言生成」章节
├── data/
│   ├── scenarios.json               （不动）
│   ├── dao-xiang-policy.json        （不动）
│   ├── dao-xiang-cases.json         （不动）
│   ├── dao-xiang-dishes.json        （不动）
│   ├── default-policy.json          （不动）
│   ├── default-cases.json           （不动）
│   ├── dish-catalog.json            （不动）
│   └── parser-lexicon.json          ★ 新增：领域词典
├── js/
│   ├── engine.js                    （不动）
│   ├── translator.js                （不动）
│   ├── validator.js                 （不动）
│   ├── scenario-manager.js          （不动）
│   ├── embed-data.js                ✎ 增量：由 build-embed.js 重新生成
│   ├── parser.js                    ★ 新增：NL → Slot（规则版）
│   ├── parser-llm.js                ★ 新增：NL → Slot（LLM 骨架）
│   ├── composer.js                  ★ 新增：Slot → DSL
│   ├── semantic-check.js            ★ 新增：原话 vs 回译 diff
│   ├── agent.js                     ★ 新增：五格链编排 + 降级分流
│   └── app.js                       ✎ 增量：生成面板逻辑
├── css/
│   └── style.css                    ✎ 增量：生成面板样式
└── lib/                             （不动）
```

### 11.2 模块依赖（在原依赖图基础上扩展）

```
data/parser-lexicon.json ─┐
data/*.json              ─┴─▶ ┌──────────────┐
                               │ 静态数据      │
                               └──────┬───────┘
                                      ▼
        ┌──────────┐  ┌──────────┐  ┌──────────────┐  ┌────────────────┐
        │engine.js │  │validator │  │translator.js │  │scenario-manager│
        │（纯函数） │  │ .js      │  │（纯函数）     │  │（数据管理层）   │
        └────┬─────┘  └────┬─────┘  └──────┬───────┘  └───────┬────────┘
             │             │               │                  │
             │  ┌──────────┴───────────────┴──────────────────┘
             │  │
             ▼  ▼
        ┌────────────────────────────────────────────┐
        │  parser.js / parser-llm.js  （NL → Slot）   │
        │  composer.js                （Slot → DSL）  │
        │  semantic-check.js          （diff）        │
        │  agent.js                   （编排，依赖上面三个 + engine/validator/translator）
        └───────────────────┬────────────────────────┘
                            ▼
                      app.js (Vue) ──▶ index.html
```

**依赖方向严格单向**：`agent.js` 是唯一同时依赖 engine / validator / translator / parser / composer / semantic-check 的模块；其他新模块之间不互相依赖（parser 不依赖 composer，composer 不依赖 semantic-check）。

### 11.3 `index.html` 脚本加载顺序

现有（行 659-673）：

```html
<script src="lib/vue/..."></script>
<script src="lib/codemirror/..."></script>
<script src="js/engine.js"></script>
<script src="js/validator.js"></script>
<script src="js/translator.js"></script>
<script src="js/scenario-manager.js"></script>
<script src="js/embed-data.js"></script>
<script src="js/app.js"></script>
```

**插入位置（在 `embed-data.js` 之后、`app.js` 之前）：**

```html
<script src="js/embed-data.js"></script>
<!-- ↓ 新增：NL → DSL 生成链路 -->
<script src="js/parser.js"></script>
<script src="js/parser-llm.js"></script>
<script src="js/composer.js"></script>
<script src="js/semantic-check.js"></script>
<script src="js/agent.js"></script>
<!-- ↑ 新增 -->
<script src="js/app.js"></script>
```

顺序约束：`parser/composer/semantic-check` 只依赖 `engine/validator/translator`（已在其前），`agent.js` 依赖前四者，故排在最后。

### 11.4 数据更新提醒

**新增 `data/parser-lexicon.json` 后，必须重新生成嵌入数据：**

```bash
cd Output && node build-embed.js
```

否则 `file://` 双击打开时词典读不到（`scenario-manager.loadJson` 优先读 `__PP_EMBEDDED__`，回退 `fetch`；`file://` 下 `fetch` 会被 CORS 拦截）。这是现有项目已知的坑，README 行 292-300 有说明。

---

## 十二、开发排期与验收

### 12.1 排期（增量，v1.0）

| Phase | 内容 | 交付物 | 工时 |
|---|---|---|---|
| P1 | 词典构建 | `data/parser-lexicon.json`（~300 条，从 translator 反映射 + 稻香目录） | 0.5 天 |
| P2 | Parser 核心 | `js/parser.js`（归一化 + 最长匹配 + 模板匹配 + Slot 产出） | 2 天 |
| P3 | Composer | `js/composer.js`（条件/动作组装 + id/priority/group/stage 生成） | 1 天 |
| P4 | SemanticCheck | `js/semantic-check.js`（语义指纹 + diff） | 0.5 天 |
| P5 | Agent 编排 | `js/agent.js`（五格链 + 四条回流边 + 三态降级） | 1.5 天 |
| P6 | UI 生成面板 | `index.html` / `app.js` / `style.css` 增量（四栏对照 + 高亮 + 确认） | 2 天 |
| P7 | 回归语料 | 稻香 22 条规则反推测试语料 + 自动化断言脚本 | 1 天 |
| P8 | LLM 骨架 | `js/parser-llm.js` 空实现 + 配置开关 + 三条红线注释 + **Slot Schema 定义（§10.4.1）** | 0.5 天 |
| P8.5 | **LLM 语义复核（可选层）** | `js/semantic-check-llm.js` 骨架 + 触发条件 + 「只报不改」边界（§7.4） | 0.5 天 |
| P9 | 打磨与联调 | 边界 case、深色主题、响应式、文档 | 1 天 |
| | **合计** | | **10.5 天** |

### 12.2 验收标准

| # | 验收项 | 判定 |
|---|---|---|
| 1 | **22 条规则回译一致** | 用稻香 22 条规则反推语料，生成的 JSON 其 `translateRule` 输出与原始 `label` 语义一致（人工判定 + 语义指纹 diff 为空） |
| 2 | **闭环可视化** | 四栏同时可见，原话高亮、词典命中、模板命中、置信度、diff 全部展示 |
| 3 | **combine 不静默** | 构造 10 条「有歧义连接词」的输入，100% 触发确认，无一条默认 `all` 直接入库 |
| 4 | **错误能拦截** | 构造 10 条非法输入（字段名错、时间格式错、值超范围），全部被 validator 拦截并给出可读提示 |
| 5 | **降级三态可达** | 缺信息 / 歧义 / 超能力各构造 3 条，全部走到对应 UI，无「白屏/报错」 |
| 6 | **零依赖离线** | 断网状态下 `file://` 双击 `index.html`，全流程可用 |
| 7 | **不污染现有功能** | 现有规则列表 / 编辑 / 执行 / JSON 查看器 / 回译功能回归通过 |
| 8 | **可换实现** | 把 `PARSER_IMPL` 改成 `'llm'`，除 `parser-llm.js` 外零改动（骨架版走 mock 返回） |
| 9 | **Slot Schema 会拦非法产出** | 构造 10 条「应该产出非法字段」的 mock LLM 响应（如 `field:"dishName"`、`combine.op` 缺省），Schema 校验层 100% 拦截（§10.4.1） |
| 10 | **回译缺模板键会暴露** | 构造 3 条会触发缺模板键的输入，`missingTemplateKeys` 非空且 UI 醒目展示，不允许静默回译（§10.6.4 补 1） |
| 11 | **label 来自回译而非模型** | 断言生成的 `rule.label` 恒等于 `translator.translateRule(json)` 的输出；LLM 若给 `suggestedLabel` 不得落入该字段（§10.6.4 补 3） |
| 12 | **LLM 复核只报不改** | mock LLM 返回 `suspect:true` 时，断言 JSON 未被修改、仅 UI 多一个提示条；mock 超时时主链路正常走完（§7.4.3） |
| 13 | **模糊词触发复核** | 「大概打个八折左右」这类输入，即使 diff 为空也必须触发 LLM 复核路径（或在其未启用时给出模糊性提示）（§7.4.2 第 ④ 条） |

### 12.3 与生产实现的对齐验收

| # | 验收项 | 判定 |
|---|---|---|
| 1 | **group 稳定性** | 同一句原话连续生成 3 次，`group` 与 `priority` 完全一致（§6.4 规则 2） |
| 2 | **priority 恒为 100** | 断言生成规则的 `priority` 恒等于 100，不随输入变化（§6.4 规则 3） |
| 3 | **动作语义不跨层倒算** | 「减8元」产出 `discountAmount{8}` 而非 `discountRate`；「打八折」产出 `discountRate{0.8}` 而非 `discountAmount`（§6.6） |
| 4 | **Slot 路径无绿色通道** | 规则版与 mock LLM 版产出同一份 Slot 时，生成的 JSON 逐字节一致（§10.4.1 级联纪律） |

### 12.4 回归语料构造方式

从 `dao-xiang-policy.json` 的 22 条规则，**逐条反写一句自然口语**，例如：

| 规则 | 反写语料 | 期望 Action |
|---|---|---|
| r_weekend_cold_80 | 「周末凉菜八折」 | discountRate 0.8 + days[SAT,SUN] + cat_cold |
| r_order_full_200_minus_20 | 「满200减20」 | orderReduce 20 + orderAmount{min:200} |
| r_order_gift_peanut | 「满300送花生米」 | gift dish_703 + orderAmount{min:300} |
| r_member_birthday_85 | 「生日当月打八五折」 | discountRate 0.85 + memberTags[birthday] |

每条语料断言三点：① 生成的 JSON 合法（validator 通过）；② `translateRule` 回译语义指纹与原语料指纹一致；③ `SemanticCheck` diff 为空。

**⚠️ 反向断言（负样本）也要构造：** 除「能生成」外，必须构造「**不该生成**」的语料 —— 见 §10.6.2 风险 12 的照抄问题。例如原话「给老客户撒点钱」不得生成任何规则（超能力态）；原话「每周一全场九折」生成结果里 `dates`/`dishUids` 若出现，必须能在原话里找到对应词面。

---

## 十三、风险与应对

| # | 风险 | 影响 | 应对 |
|---|---|---|---|
| 1 | **combine 误判为 all**（最高风险） | 规则永不触发，且表面看不出 | ① 低置信强制追问；② UI 并列候选可点选；③ Engine 试算的「永不命中」警告兜底；④ 验收项 3 专门覆盖 |
| 2 | 中文口语歧义（「打个折」「优惠点」） | 无法确定具体动作 | 归入「缺信息」态，结构化追问具体折扣 |
| 3 | 词典覆盖率不足 | 长尾句式匹配失败 | ① 复用 translator 全部字典；② 稻香目录 36 菜品 + 8 品类全收；③ 走「能力清单」给示例；④ A 方案（LLM 离线扩充）持续补 |
| 4 | 最长匹配性能 | 词典增大后变慢 | 词典 < 1000 条时同步无感；超阈值可加首字索引（按 `words[0]` 分桶），接口不变 |
| 5 | 菜品重名（「虾饺」vs「虾饺皇」） | 匹配错菜品 | 最长匹配天然处理（虾饺皇 3 字 > 虾饺 2 字）；歧义时走候选卡让用户选 |
| 6 | 生成的 id 与现有规则冲突 | 覆盖用户规则 | id 用 `r_gen_` 前缀 + 时间戳 + 序号；入库前查重，冲突则重生成 |
| 7 | priority 冲突（同 group 同 stage） | 执行顺序不确定 | v1 默认 100，冲突时提示用户手动调；不自动推算（避免引入不确定性） |
| 8 | **LLM 幻觉出非法字段** | 生成非法 JSON | 三条红线：只产 Slot 不产 DSL；Slot 必过 validator；重放日志可审计 |
| 9 | 回译文案与实际语义偏差 | 用户被误导后确认 | SemanticCheck 结构化 diff 交叉校验；diff 非空必须醒目展示 |
| 10 | 改 `data/` 忘了跑 `build-embed.js` | `file://` 下词典读不到 | 开发脚本内加校验：若 `parser-lexicon.json` 比 `embed-data.js` 新则报警 |
| 11 | 范围蔓延（把 v1 做成对话系统） | 排期失控 | 严格区分「接口预留」与「功能实现」：v1 只做单轮、不做 ASR、不做改规则 |
| 12 | **模型照抄 few-shot 内容**（生产 §6-4/§6-5 实测） | 生成与用户意图无关的菜名/日期 | ① few-shot 避免与常见句式「同构」；② 断言生成结果里的 `dishUids`/`dates` 必须能在原话里找到对应词面，找不到即降级追问 |
| 13 | **`when` 整块被省略**（生产 §6-1 实测） | 条件全丢 → 静默变成「全场」 | `conditions` 进 Schema `required`；且「条件为空但有动作」必须走「缺信息」态追问，不允许静默通过 |
| 14 | **`label` 来自模型而非回译** | 模型可「说得好听但和 JSON 不符」，绕过回译验证 | §10.6.4 补 3：`label` 恒由 `translateRule` 反算；验收项 11 覆盖 |
| 15 | **LLM 复核本身幻觉** | 虚假警报 / 虚假安心 | ① 权限收到最小（只报不改，Schema 里没有 dsl/slot 字段）；② `suspect:false` 时**不显示任何字样**，避免脱敏；③ 超时静默降级 |
| 16 | **前端语义与生产端漂移** | 两侧 group/priority 口径不一致，未来打通时静默合错 | §10.6 对照表作为「口径基线」；新增 group 或改 priority 策略时**必须同轮更新该节** |

---

## 十四、后续扩展方向（v2+）

| 方向 | 说明 |
|---|---|
| **多轮澄清对话** | 把追问做成自然对话（LLM 增强），支持「不对，改成八五折」这种修正 |
| **多句合并** | 「周三凉菜八折，周末热菜九折」→ 一次产出两条规则 |
| **改规则** | 「把那条周三的改成八五折」→ 定位 + patch 而非新增 |
| **语音直连** | 接 ASR 流式识别，边说边解析 |
| **词典自动扩充** | A 方案工程化：线上日志 → LLM 标注 → 人工审核 → 自动合并 + 回归 |
| **规则解释问答** | 「这条为什么这么算」→ 用 trace 回答（复用现有命中轨迹） |
| **跨场景词典** | 场景专属词典覆盖全局词典（如 print-route 场景有专属词汇） |
| **与生产服务对接** | 前端生成的 DSL 直接调 `PricePolicyService` 的 `add`/`update`（`document` 参数），打通「演示器验证 → 门店落库」。交界点已明确：Slot 走前端、DSL 落库（§10.6.5） |
| **共享词表** | 前端 `data/parser-lexicon.json` 与服务端 `Skills/pricepolicy/skill.md` 词表合并为单一来源，避免两侧词表漂移 |
| **回译器的缺键报告** | 向 `translator.js` 增加 `LastMissingKeys`（对齐生产 `PricePolicyRenderer.LastMissingKeys`），使本 PRD §10.6.4 补 1 有原生支持 |
| **菜名容错（向量层）** | 若将来需要，可在 `parser.js` 的 L2 后加一层可选向量检索（对齐生产 §3.1 的 `MinScore`/`MinMargin` 双阈值 + 强制核对提示） |
| **规则级候选集与人选/机选** | 见 §14.1 —— **C 档已落地（v2.1），并于 v2.2 收缩为两模式**：新增规则级 `selectGroup` / `select`（`manual`/`priority`），选择语义**从生成端写入 DSL**；"组内取优"**不进 DSL**，改由程序侧对引擎暴露的候选活动集合算法筛选（`candidateHint`）。`generateParallel` 支持并列句切分 + 主语继承 + 整组入库。A 档 `candidateGroups`（互斥落选可见）仍待补 |

### 14.1 规则级候选集：现有定义的支持边界（v1 已核实）

> 起因：若要「返回多个命中规则让收银员手动选一个」，或「从多个中按算法选最优」，现有 JSON DSL 定义是否支持？
> 结论：**动作级支持，规则级不支持。** 以下为对 `GenJsonDSL/js/engine.js` 的实测核实结果。

**14.1.1 现有三层选择机制**

| 层次 | 机制 | 现状 | 关键实现 |
|---|---|---|---|
| ① 动作级取优 | 一条规则内 `bestOf.options` 比价取最低 | ✅ 支持 | `engine.js` L655-676；`meta.final=true` 令其结果成为该行定价终态 |
| ② 同组互斥 | 同 `group` 取 `priority` 高者；`priority` 相同取价格低者 | ✅ 支持，但**确定性自动**，无人工介入点 | `engine.js` L1272-1294 `groupWinners` |
| ③ 跨组叠加 | 按 `(priority desc, id asc)` 链式递进改写当前行价 | ✅ 支持，未命中即不进 `applied` | `engine.js` L1296-1329 |

实测（4 条规则同时命中，分属不同组）：`applied` 返回 4 条生效规则，但**同组落选的 `r_x` 完全消失**——`groupWinners` 是局部变量，落选者在此处被结构性丢弃。

**14.1.2 三个缺口**

| # | 缺口 | 证据 |
|---|---|---|
| 1 | 无「候选集」输出契约 | `resolveLine` 返回体仅 `context / basePrice / linePrice / finalPrice / clamped / clampedBy / beforeClamp / floorPrice / chain / applied / evaluated / candidatesCount`；无 `candidates` / `alternatives` / `lost` / `selectGroup`。`evaluated` 是诊断轨迹（`lean` 模式返回 `null`），且不标注「与谁竞争、为何落选」 |
| 2 | `group` 语义与「选择组」冲突 | 现有 `group` 是**互斥**语义（同组只活一条、引擎自动裁决）；人工选择需要**并列**语义（全部保留、交人工）。共用同一字段会与 validator 的 `GROUP_STAGE_MISMATCH` 校验及 §6.4 group 稳定性约定冲突 |
| 3 | 无 `select` 语义声明 | DSL 中没有任何字段声明「本组是自动取优还是人工选择」 |

**14.1.3 三轮扩展方案**

**A 档 · 最小改动（0.5 天，推荐先做）—— 补 `candidateGroups`**

不动 DSL、不改引擎算法，只把 `groupWinners` 丢弃的落选者改为归集返回：

```js
// engine.js _resolveLineCore 内：groupWinners 保留（决定 applied），另增 groupBuckets 收集全部命中者
var groupBuckets = Object.create(null);   // group → [entry, ...]
// ...命中处两侧都 push groupBuckets[rule.group]
return {
  basePrice: base, price: money(cur), applied: applied, chain: chain, evaluated: evaluated,
  candidateGroups: Object.keys(groupBuckets).map(function (g) {
    var win = groupWinners[g];
    return {
      group: g,
      winnerId: win ? win.rule.id : null,
      candidates: groupBuckets[g].map(function (e) {
        return { ruleId: e.rule.id, label: e.rule.label, kind: e.kind, price: e.price,
                 priority: e.rule.priority, lost: e !== win };
      })
    };
  })
};
```

- 好处：**纯新增字段，零破坏性**（所有既有调用方不受影响），UI 层立刻可渲染「候选卡片」（对齐 §8.2 并列候选卡形态）。
- 附带收益：`agent.js` 的 `runTrial` 目前靠 `shadowedRules` 摘掉同组规则来绕过「被同组遮蔽导致 hits 恒 0」（见 `agent.js` L195-203 注释）。有了 `candidateGroups` 即可直接向用户展示「你的规则被这 3 条同组规则挤掉」，比只报 ID 列表有用得多。
- 局限：只能「看」不能「改」——收银员选了 `r_x`，价格仍是引擎算的那条。

**B 档 · 加人工选择入口（1.5 天）—— 两阶段重算**

```js
engine.resolveLine(ctx, { chosenRuleIds: { g_wocai: 'r_x' } });
// 或 engine.resolveLine(ctx, { selectMode: 'manual' });
```

配合 A 档 `candidateGroups` 即可实现「先返回候选 → 收银员点选 → 带选择重算」。
⚠️ **v2.2.1 修正**：C 档落地后，"带选择重算"**不再由引擎做** —— 引擎只暴露候选集，
"按所选活动定价"由 **POS 侧结算流程**自行应用（见下方 §14.1.3 的拍定说明）。

**⚠️ 该语义问题已于 v2.2.1 拍定（用户口径）**：收银员手动选了**非最优**活动时，
引擎**两者皆非** —— 它根本**不参与定价决策**：
> 「manual 模式下只是给出候选结果，不直接做出选择，所以产出候选集合后，规则已经完成使命。」

⇒ 引擎只负责**算清每条候选各自会把这一行定到什么价**并暴露候选集；
「选哪条、要不要按所选生效」由 **POS 侧结算流程**自行应用。
引擎额外回报 `suboptimal: true` 供 UI 提示毛利影响，但**不**据此改写价格。

这同时消解了 §13 风险表的担忧：不存在"人工选择绕过最优策略导致毛利失控"——
因为引擎从不按候选集定价，毛利影响由 POS 侧的选择流程自己把关。

**C 档 · DSL 层正式声明（2 天）—— 新增 `selectGroup` / `select`**

```json
{
  "id": "r_liangcai_pool", "stage": "line",
  "selectGroup": "sg_liangcai",
  "select": "manual",
  "priority": 100,
  "when": { "dishUids": ["d_liangcai"] },
  "then": { "type": "discountRate", "rate": 0.8 }
}
```

`select` 取 `"manual" | "priority"`（默认 `"priority"` 保持向后兼容）。

⚠️ **v2.2 收缩**：原 `"best"` 已移除。"组内取优"不再作为**规则级声明**写入 DSL —— 因为规则产出的动作类型可能不同（折扣率 / 固定金额 / 赠品 / 会员价），"最优"在 DSL 层没有统一可比较的口径。取而代之：DSL 只负责**暴露候选活动集合**，引擎在 `selectGroups[*].candidates` 返回候选集，**选哪条由程序侧算法决定**（`candidateHint = {kind:'algorithm-required'}` 即为该信号）。详见 §3.2.1。

⚠️ **C 档必须同步四处**，否则触发 §10.6.4 补 1 的 `missingTemplateKeys`：
1. `validator.js` —— 新增 `selectGroup` / `select` 校验，`CHECKLIST` 从 12 项增至 13 项
2. `translator.js` —— 回译须能表达「以下 N 个活动任选其一，取最优惠」，否则回译缺键
3. `engine.js` —— 新增 `select` 分支（`manual` 走候选返回 + 未选挂起，`priority` 走**只读候选集** + 既有互斥定价）
4. 本 PRD §3.2 规则字段表 + §6.4 group 边界规则

**14.1.4 实施顺序建议**

A 档 → B 档语义决策 → C 档。理由：现在连「有哪些候选」都看不到，谈人工选优没有数据基础；且 A 档完全向后兼容，可作为 v1.1 的独立小版本先行落地。

> **【用户已决策】实际选择了 C 档** —— 原话：「我选 C 档，最彻底，从生成端就确定动作」。
> 理由：C 档不是在**运行期**补救已有的互斥行为，而是让**选择语义从生成端就写进 DSL**。
> 这样「多个命中活动怎么处置」是**规则作者/运营的显式意图**，不是引擎的隐式裁决——与 §1「闭集 + 可复现 + 确定就问人」的整套纪律一致。

**14.1.5 C 档实现状态（v2.1，已完成）**

七处代码全部落地，四套测试全绿：

| # | 文件 | 改动 | 状态 |
|---|---|---|---|
| 1 | `js/engine.js` | `compileRule` **透传** `selectGroup`/`select`；`_resolveLineCore` 新增「选择阶段」（排序 → 记参考最优（只读）→ 读 chosenMap 作审计 → 暴露候选集）；返回体新增 `selectGroups`/`pendingSelectGroups`；新增 3 条校验。**v2.2**：`SELECT_MODES` 收窄为 `['manual','priority']`。**v2.2.1**：候选规则**永不入 `applied`**（完成使命即退场）、`pendingSelectGroups` 恒空、`chosenMap` 降级为审计展示 | ✅ |
| 2 | `js/validator.js` | 3 条规则级校验（`SELECT_GROUP_TYPE`/`SELECT_MODE_INVALID`/`SELECT_WITHOUT_GROUP`）；`CHECKLIST` 12 → **13 项** | ✅ |
| 3 | `js/translator.js` | `translateSelect(rule)` 三模式文案；`translateRule` 追加 select 句；`checkLabelMismatch` 增 9 条选择语义 sceneHints | ✅ |
| 4 | `js/composer.js` | `readSelect(slot)`（标准形态 + 简写兼容）；`composeRule` 写入 `selectGroup`/`select`（**无 select 时不写字段，保持旧文档字节级一致**） | ✅ |
| 5 | `js/parser.js` + `data/parser-lexicon.json` | `selectHits` 收集 `__select__`；Slot 组装 `select` 槽位；同句多次命中 **manual 优先**；词典新增两条目（词面为 **L1 归一化后**形态） | ✅ |
| 6 | `js/agent.js` | **`generateParallel(rawText, opts)`**（分句 + 主语继承 + 编组）+ **`commitMany(results)`**（整组入库，整体成功或整体不落库） | ✅ |
| 7 | `js/app.js` | 并列候选 UI：`renderParallel` / `renderJsonParallel` / `renderRightParallel` / `pickCandidate` / `doCommitParallel`；新增第 13 条演示用例 | ✅ |

**两条语义口径**（第一条为 v2.2.1 用户拍定，第二条为 AI 选定）：

1. **⚠️ 候选规则"产出候选集即完成使命"，不参与定价**（v2.2.1 用户口径，原 (a)/(b) 之争作废）。
   引擎 **不**代替选择者挑一条改价、**不**因"没人选"而挂起。两种模式对定价路径影响**恒为零**。
   `chosenMap` 仅作**审计展示**（记录 `chosenRuleId`/`fromManual`/`isChosen`），**不**触发改价；
   `suboptimal: true` 供 UI 提示毛利影响，同样不干预定价。
   实测：虾饺皇 ¥28，两条候选（八折 22.4 / 减5元 23）；告知"选了减5元"后
   → `finalPrice` 仍 **28**（引擎不改价）、`fromManual=true`、`suboptimal=true`、
   候选集内恰 1 条标 `isChosen`、`bestRuleId` 仍指向八折那条（只读参考）。
2. **并列句默认 `manual`，不是 `priority`**。没有明说「取最优」时，不替用户做「自动省钱」的决定——默认把选择权交回人。
   **v2.2 补充**：若原话**明说了**「取最优」类词组（`哪个便宜用哪个` / `取最优惠的` …），也**不再**落成任何 `select` 模式，而是产出 `groupSelectIntent = 'algorithm-required'`，并把 `mode` 落为 `priority`（交程序侧筛选）——因为"最优"的口径 DSL 定义不了，只能把候选集交给程序侧。

**分句的两条硬约束**（实现踩坑，见 §14.1.6）：

- **顿号（、）不是并列分隔符**。它更常是 `bestOf` 的枚举候选价（「85折、减8元、卖16.8元」），误判会抢走单条链路。
- **尾随选择词组必须从最后一段摘出去**。「虾饺皇八折；或者减5元，**取最优惠的**」切分后第二段会变成 `减5元，取最优惠的`，污染该段动作解析；须把 `取最优惠的` 摘出来作为**组级** mode 依据。

**14.1.6 C 档实现踩到的坑（供后续维护者避雷）**

| # | 坑 | 现象 | 根因 | 处置 |
|---|---|---|---|---|
| 1 | **词典词面冲突** | `select.intent.algorithm` 命中不稳定 | `act.bestof` 与原 `select.mode.best` 共享 3 个词面（`取最优惠`/`哪个便宜算哪个`/`自动取优`）；`scanLongest` non-overlapping + 命中即 `break`，同词面时谁先命中取决于排序稳定性 | 词面归 `act.bestof` 独占；取优意图条目（v2.2 改名 `select.intent.algorithm`，`field` 改 `__selectintent__`）只收不冲突的词面；`buildLexiconIndex` 同长度排序加 `order` 稳定兜底 |
| 2 | **词典词面必须归一化** | 词典里写「任选一个」永远匹配不上 | L1 `normalize()` 规则 (5) 已把「一个」→「1个」 | 词典词面一律写归一化后形态（`任选1个`） |
| 3 | **顿号误当并列** | 三个套件回归（`_test_ui` 76→75、`_test_browser` 45→44） | 分句正则含 `、`，把 bestOf 枚举句切成 3 段 | 分句正则移除顿号；新增「是否并列句」前置判断（`PLAIN_SEP`/`SELECT_HINT` 皆无则退回单条） |
| 4 | **陈旧追问未清** | 后段继承条件后仍返回 `state='ask'`、`recompose` 早退 | `judgeDegradation` 读 `slot.questions` 非空即返回 `ask`，parse 期留下的追问没清 | 继承分支里显式 `slot.questions = []` |
| 5 | **`compileRule` 白名单构造** | `selectGroup`/`select` 被静默丢弃 | 原实现是白名单式字段拷贝 | 改为显式透传新字段 |
| 6 | **候选桶双重 push / `priority` 被当待选挂起 / 候选规则入 `applied`** | ①`entry` 被 push 两次、`applied` 重复；②`priority` 组永远卡在 `pending`，价格算不出来；③候选规则被"选中"后改写定价，与「规则完成使命」口径冲突 | ①分流条件写成 `!!(rule.selectGroup && !lean)`，把 `priority` 也算进去了；②选择阶段把 `priority` 桶当成 manual 待选清单；③保留 `applied.push(effective)` | ①改为 `&& selMode !== 'priority'`；②**v2.2**：候选桶**两种模式都登记**（价值就是暴露候选集），但引入 `isManual` 分流，仅 manual 才谈挂起；③**v2.2.1**：**彻底移除 `applied.push`** —— 候选规则永不参与定价，`pending` 恒 `false`、`pendingSelectGroups` 恒空数组 |
| 7 | **`when` 形态** | 探针取 `when.conditions.dishUids` 恒 `undefined` | composer 产出**扁平** `when`（`{dishUids:[...]}`），非 `{conditions:{...}}` | 探针统一读 `rule.when.dishUids` |
| 8 | **`commitMany` 半截入库** | 并列组只落了一半 | 逐条 `commit` 时某条失败即中断 | 整批先校验、再统一落库；同批内 id 也去重（`genRuleId` 时间基可能同秒碰撞） |
| 9 | **旧文档行为口径误判** | 以为旧文档是「八折叠减5元 = 17.4」 | 引擎既有口径是**同优先级折扣类互斥取优**，非叠加 | 断言改为 `28×0.8 = 22.4` |

**回归基线（v2.1）**：

| 套件 | 结果 |
|---|---|
| `_test_pipeline.js`（含新增 §6 选择语义 41 项） | **106 / 0** |
| `_test_ui.js` | **76 / 0** |
| `_probe_parallel.js`（九段验证） | **38 / 0** |
| `_probe_select_roundtrip.js` | 5 段全过 |
| `_test_browser.js`（含并列候选 15 项） | **58 / 0** |

**14.1.7 A 档 / B 档的关系（C 档落地后仍需不应做）**

C 档落地后 A 档的 `candidateGroups` **仍然有价值**，但定位变了：

- A 档是**引擎级诊断**——把「同 `group` 落选者」归集返回，用于解释「你的规则为什么没生效」；
- C 档是**规则级意图**——`selectGroup` 声明「这几条是并列候选」，是作者主动写的。

两者**不冲突、可叠加**：`selectGroup` 解决"并列候选"，`candidateGroups` 解决"互斥落选可见"。A 档仍未实现，建议作为 v1.1 独立小版本补上（纯新增字段、零破坏性）。

B 档的 `chosenRuleIds` 在 C 档里已以 `sel.chosen = { [selectGroup]: ruleId }` 的形式实现 —— 但 **v2.2.1 起它只是"消费方告知所选"的审计通道**，引擎不再据此改价（无需单独再做定价分支）。

---

## 附录 A：Slot 契约速查

```js
{
  rawText:           String,
  conditions:        Array<{field, value, source, confidence, span, lexiconId, evidence}>,
  action:            {type, value, source, confidence, span, evidence},
  combine:           {value:'all'|'any'|'not', source, confidence, needsConfirm, reason},
  select:            {group, mode:'manual'|'priority', source, confidence, span,
                      lexiconId, evidence, needsConfirm, reason},   // v2.1，可缺省；v2.2 收缩
  candidateHint:     {kind:'algorithm-required', source, confidence, span, lexiconId,
                      evidence, needsConfirm, reason},              // v2.2 新增，可缺省
  stage:             'line' | 'order',
  template:          String,
  unmatchedTokens:   Array<String>,
  needsConfirm:      Boolean,
  questions:         Array<{slot, question, options}>
}
```

## 附录 B：错误码 → 重抽映射速查

| validator code | 重抽目标 |
|---|---|
| `FIELD_UNKNOWN` | 该 span 的字段归属 |
| `RANGE_INVALID` / `RANGE_MIN_TYPE` / `RANGE_MAX_TYPE` | 范围数值 |
| `TIME_FMT` / `TIME_SEG` | 时间字符串 |
| `MEMBER_LEVEL_INVALID` | 会员等级词典条目 |
| `ACTION_UNKNOWN` | 动作类型词典条目 |
| `STAGE_ACTION_MISMATCH` | 组装层 stage 反查 |
| `MINRATE_RANGE` | `global.minRate` |
| `BESTOF_EMPTY` / `BESTOF_OPT_INVALID` | 候选动作列表 |
| `SELECT_MODE_INVALID` | 选择模式（须为 `manual`/`priority`；`best` 已于 v2.2 移除） |
| `SELECT_GROUP_TYPE` | `selectGroup` 须为非空字符串 |
| `SELECT_WITHOUT_GROUP` | 有 `select` 必须有 `selectGroup`（反之不成立） |

## 附录 C：核心常量引用来源（全部来自现有模块，不另立）

| 常量 | 来源模块 | 用途 |
|---|---|---|
| `CONDITION_FIELDS`（18 项） | `engine.js` 行 37-43 | 词典 `field` 合法性校验 |
| `COMBINATORS`（all/any/not） | `engine.js` 行 46 | combine 槽位闭集 |
| `ACTION_TYPES`（8 项） | `engine.js` 行 49-52 | 词典 `actionType` 合法性校验 |
| `LINE_ACTIONS`（6 项） | `engine.js` 行 55 | stage 反查 |
| `ORDER_ACTIONS`（2 项） | `engine.js` 行 58 | stage 反查 |
| `TIME_FIELDS` | `engine.js` 行 61 | 时间字段白名单 |
| `DAY_INDEX` / `DAY_CN` | `engine.js` 行 64-68 | 星期中英互转 |
| `MEMBER_LEVEL_ORDER` / `MEMBER_LEVEL_CN` | `engine.js` 行 71-77 | 会员等级词典与比较 |
| `MEMBER_TAG_CN` | `translator.js` 行 35-40 | 词典种子 |
| `DATE_TAG_CN` | `translator.js` 行 41-47 | 词典种子 |
| `DISH_TAG_CN` | `translator.js` 行 48-53 | 词典种子 |
| `RANGE_FIELD_INFO` | `translator.js` 行 54-67 | 范围句式词典种子 |
| `ALLOCATE_CN` | `translator.js` 行 68-73 | 摊分词典种子 |
| `TIME_FIELD_CN` | `translator.js` 行 74-79 | 时间字段词典种子 |
| `GROUP_CN` | `app.js` 行 56-61 | group 生成映射（需补 `custom`） |
| 商品索引（uid/name/category/price） | `dao-xiang-dishes.json` + `buildCatalogIndex` | 菜品名 → dishUids |
| 品类索引（cat_*） | `dao-xiang-dishes.json` `categories` | 品类词词典 |

## 附录 D：三段式开场示例（供 UI 演示用）

**示例 1：最简单**

```
原话：周三凉菜打八折

解析过程：
  归一化：周三凉菜打8折
  词典：周三→days[WED] | 凉菜→categories[cat_cold] | 打8折→discountRate{rate:0.8}
  模板：tpl_date_cat_action（日期+品类+动作）命中
  置信度：days 0.98 / categories 0.95 / action 0.97 / combine 0.72(模板默认)

生成的 JSON：
  {"rules":[{"id":"r_gen_...","stage":"line","group":"daily_discount","priority":100,
    "when":{"all":[{"days":["WED"]},{"categories":["cat_cold"]}]},
    "then":{"type":"discountRate","rate":0.8}}]}

回译：每周三，凉菜，打八折
语义 diff：✅ 与原话一致
```

**示例 2：combine 歧义（必追问）**

```
原话：会员或者周末凉菜八折

解析过程：
  词典：会员→memberLevel | 或者→__combine__:any | 周末→dateTags[weekend] | 凉菜→cat_cold | 八折→0.8
  模板：无语料命中（两个前置条件 + 显式连接词）
  置信度：combine 0.95（用户明说「或者」）

生成的 JSON：combine = any（无误）

回译：会员 或 周末，凉菜，打八折
语义 diff：✅

对比 —— 若用户说「会员周末凉菜八折」（无连接词）：
  模板：tpl_?... 不匹配（两个前置条件但无连接词）
  → 降级为「歧义」态，抛并列候选卡，用户点选 且/或
  → 绝不默认 all 直接入库
```

**示例 3：超能力（给能力清单）**

```
原话：给老客户撒点钱

解析过程：
  词典命中：0 条
  模板：无语料序列可匹配
  → 降级为「超能力」态

UI 输出：
  🙇 这句话我没听懂
  目前我能听懂这种句式：周三凉菜打八折 / 满200减20 / 会员满200送甜品 ...
  你说的：「给老客户撒点钱」 ← 未识别
```

---

## 附录 E：开发落地顺序（给实现者的 Checklist）

- [ ] 1. 建 `data/parser-lexicon.json`：先把 translator.js 五张表反映射成条目，再补品类/菜品/会员等级
- [ ] 2. 写 `js/parser.js` L1 归一化层（全半角 + 口语数字），写单测
- [ ] 3. 写 L2 最长匹配，写单测（重点测「金卡 vs 卡」「虾饺皇 vs 虾饺」）
- [ ] 4. 写 L3 模板匹配（先做 5 个核心模板：时段+品类、日期+品类、会员等级+品类、整单满减、整单满赠）
- [ ] 5. 写 L4 组装层，产出 Slot（含 source/confidence/span）
- [ ] 6. 写 `js/composer.js`（条件组装 + 动作组装 + stage 反查 + group 映射）
- [ ] 7. 写 `js/semantic-check.js`（语义指纹 + diff）
- [ ] 8. 写 `js/agent.js`（编排 + 四条回流边 + 三态降级）
- [ ] 9. 跑 `node build-embed.js`，让词典进入 `embed-data.js`
- [ ] 10. 改 `index.html` / `app.js` / `style.css`，做四栏 UI
- [ ] 11. 用稻香 22 条规则反写语料，跑回归（验收项 1）
- [ ] 12. 构造 combine 歧义 10 条（验收项 3）+ 非法输入 10 条（验收项 4）+ 降级三态各 3 条（验收项 5）
- [ ] 13. 写 `js/parser-llm.js` 骨架（配置开关 + 三条红线注释 + **Slot Schema 定义 §10.4.1**）
- [ ] 13b. 写 `js/semantic-check-llm.js` 骨架（触发条件 §7.4.2 + 「只报不改」边界 §7.4.3，mock 即可）
- [ ] 13c. 给 `semantic-check.js` 加 `missingTemplateKeys` 记录（§10.6.4 补 1）
- [ ] 13d. 断言 `rule.label` 恒等于 `translateRule(json)`（§10.6.4 补 3，验收项 11）
- [ ] 14. 更新 `README.md`，补「自然语言生成规则」章节
- [ ] 15. **对照 `PricePolicyService.md` 复核口径**：group 闭集、priority 恒 100、动作不倒算、Slot 路径无绿色通道（§12.4 四项）

---

## 附录 F：与现有 PRD 的对应关系

| 本 PRD 章节 | 对应现有 PRD | 关系 |
|---|---|---|
| §1 背景与目标 | `PricePolicy-DSL演示程序-PRD.md` §11 | 本 PRD 是 §11「AI 生成规则接口」的正式展开 |
| §2 总体架构 | 现有 PRD §7 模块依赖图 | 在原依赖图基础上向下扩展一层（新增 5 模块） |
| §6.3 stage 反查 | 现有 PRD §3.5 校验器「stage 取值」 | 复用同一闭集（`LINE_ACTIONS`/`ORDER_ACTIONS`） |
| §6.6 动作收敛 | `PricePolicyService.md` §3 | 新增：禁止跨语义层倒算 |
| §7.1 校验 | 现有 PRD §3.5 校验器 12 项 | 直接调用，不改 |
| §7.2 语义 diff | 现有 PRD §4.4 交叉校验 | 复用 `checkLabelMismatch` 的思路，扩展为「原话 vs 回译」 |
| §7.4 LLM 语义复核 | `PricePolicyService.md` §3、§6-2 | 新增：只报不改的可选第四层 |
| §9 UI | 现有 PRD §8 UI 设计规范 | 完全沿用配色/字体/按钮规范 |
| §10.4.1 Slot 技能规范 | `PricePolicyService.md` §6-1 | 新增：Schema 级收窄 + 级联触发 |
| §10.6 生产实现对照 | `PricePolicyService.md` 全文 | 新增：九项吻合 + 六条教训吸收 + 三项补充 |
| §11.3 脚本顺序 | 现有 PRD §7 文件结构 | 在 `embed-data.js` 后、`app.js` 前插入 |
| §12 排期 | 现有 PRD §9 排期（13.5 天） | 本链路另计 10.5 天，可与原排期并行（互不阻塞） |
| §12.3 对齐验收 | `PricePolicyService.md` §3、§6 | 新增：四项跨端口径断言 |

---

## 附录 G：生产实现（`PricePolicyService.md`）速查索引

若需回看生产端原始依据，按下表定位：

| 主题 | `PricePolicyService.md` 位置 |
|---|---|
| 分工原则「结构活归服务端，理解活归模型」 | §3 开头表格 |
| 合并匹配键三级 + 条件继承 | §3「合并匹配键三级」 |
| 菜名两级容错（精确层 + 向量层、双阈值） | §3.1 |
| 分类名 → 分类 ID（五分支） | §3.2 |
| 提示词/话术/回译模板单一来源 `skill.md` | §4 文件清单 |
| 验收套件与 attempts 纪律 | §5 |
| **15 条实测加固（勿回退）** | §6 |
| 未决项（CheckLabelWeekdays 盲区等） | §7 |

**其中 §6 第 1、2、3、5、11、15 条与本链路直接相关，已在 §10.6.2 逐条映射。**

---

*— PRD 完 —*