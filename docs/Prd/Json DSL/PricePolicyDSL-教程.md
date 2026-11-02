# 价格策略 JSON DSL 教程

> **本文简称**：文中「**JSON DSL**」即指本套**价格策略 JSON DSL**（也是引擎常量的命名空间 `PricePolicy`）——同一事物的两种叫法，下文统一用「JSON DSL」。  
> **面向读者**：其它研发 / AI 代码生成工具  
> **目标**：读完能独立写出**合法、可跑、语义正确**的 JSON DSL 策略文档，并能读懂引擎返回体。  
> **口径来源**：`OutputGen/js/engine.js`（内核单一真源）+ `OutputGen/js/validator.js`（校验闭集）+ `OutputGen/README.md`。  
> **文档版本**：对应 schemaVersion `"2.0"`，语义落定点 v2.2.1。  
> **最后校对**：以代码常量为准，本文档与代码不一致时**以代码为准**。

---

## 目录

- [第 0 章 JSON DSL 的适用场景（先读这章）](#第-0-章-json-dsl-的适用场景先读这章)
- [第 1 章 五分钟上手](#第-1-章-五分钟上手)
- [第 2 章 分层结构总览](#第-2-章-分层结构总览)
- [第 3 章 策略文档层字段](#第-3-章-策略文档层字段)
- [第 4 章 规则层字段](#第-4-章-规则层字段)
- [第 5 章 条件字段全量（18 个）](#第-5-章-条件字段全量18-个)
- [第 6 章 条件组合子与写法](#第-6-章-条件组合子与写法)
- [第 7 章 动作类型全量（8 型）](#第-7-章-动作类型全量8-型)
- [第 8 章 求值语义（四阶段）](#第-8-章-求值语义四阶段)
- [第 9 章 候选组语义（selectGroup）](#第-9-章-候选组语义selectgroup)
- [第 10 章 minRate 三级解析](#第-10-章-minrate-三级解析)
- [第 11 章 校验规则清单](#第-11-章-校验规则清单)
- [第 12 章 引擎返回体](#第-12-章-引擎返回体)
- [第 13 章 用例（cases）写法](#第-13-章-用例cases写法)
- [第 14 章 完整可运行示例](#第-14-章-完整可运行示例)
- [第 15 章 给 AI 的生成要点](#第-15-章-给-ai-的生成要点)
- [第 16 章 常见错误清单（正文待补）](#第-16-章-常见错误清单正文待补)

---

## 第 0 章 JSON DSL 的适用场景（先读这章）

> **一句话**：本文第 1 章往后都在讲「**怎么写**」JSON DSL；本章先讲清楚「**什么样的需求才该用它**」。
> 用错场景比写错语法代价大得多 —— 语法错 `validator.js` 会报错拦住你；场景错则是**规则全对但结果没人信**。

### 0.1 JSON DSL 的本质：它其实只是一张「条件 → 动作」查找表

剥掉所有字段名，这个 DSL 干的事就一件事：

```
一组 if-then：
  if（订单此刻长这样就……）{ 那就这样算钱 }
```

- **`when`** = 条件（只能用订单/商品/会员**当场可见**的字段判断）
- **`then`** = 动作（只会 8 种改价方式，不会算算术题）
- 多条 if 之间靠 **`group`（互斥）** 和 **`priority`（次序）** 协调

**它不是一门编程语言，是一份可校验的配置。** 这个认知决定了它的全部能力边界。

### 0.2 四个本质特征 —— 顺着用是「适用」，逆着用是「不适用」

| # | 特征 | 具体表现 | 顺着用 ✅ | 逆着用 ❌ |
| --- | --- | --- | --- | --- |
| 1 | **闭集** | 条件字段固定 18 个、动作固定 8 型、组合子 3 个、摊分策略 4 个（第 5/6/7 章） | 需求能落在这张表里 | 需要表外的新维度（成本、库存、实时汇率） |
| 2 | **声明式** | 只描述「什么条件 → 做什么」，不描述「怎么一步步算」 | 「满 3 件减 5 元」 | 「第 2 件半价、第 3 件起 7 折」这类**逐件递推** |
| 3 | **同步纯计算** | `resolveLine()` / `resolveOrder()` 是**同步函数、零 IO**，只吃内存里的 ctx | 给 ctx 就能立刻出价 | 需要**运行期查库/调接口**才能决定怎么打折 |
| 4 | **可校验·可回译·可审计** | `validator.js` 闭集校验、`translator.js` 回译中文、`applied` 链路可回放 | 规则要**多人协作、要审批、要追溯「这单为什么这么算」** | 一次性、用完即弃、没人复核的临时口径 |

> **判定口诀**：**四个特征全占上，就用 JSON DSL；有一个明显逆着，先想别的方案。**

### 0.3 适合用 JSON DSL 生成的场景（10 类）

判断这类场景的统一标准：**需求是不是「一批互不相干的 if-then，且条件只用订单当场可见的字段」。**

| # | 场景 | 典型需求原话 | DSL 落点 |
| --- | --- | --- | --- |
| 1 | **时段定价** | 「午市点心 9 折」「晚市 8 点后酒水 7 折」 | `openTime` / `time` + `categories` |
| 2 | **折扣类促销** | 「全场 8.8 折」「会员日再减 5 元」 | `discountRate` / `discountAmount` |
| 3 | **一口价 / 特价菜** | 「周三炒饭 9.9 元」 | `fixedPrice`（注意配合 `minRate`，见第 10 章） |
| 4 | **门槛型促销** | 「满 200 减 30」「满 3 件减 5 元」「4 人以上打 9 折」 | `orderAmount` / `lineQty` / `orderQty` / `guestCount` |
| 5 | **会员分层定价** | 「黄金会员 95 折」「黑金会员享会员价」 | `memberLevel` / `memberTags` + `memberPrice` |
| 6 | **品类 / 单品定向** | 「所有凉菜 9 折」「指定 3 道菜做活动」 | `categories` / `dishUids` / `tags` / `hasDish` |
| 7 | **互斥活动 + 叠加次序** | 「这些活动只能享一个」「会员折扣叠加在促销之上」 | `group`（互斥）+ `priority`（次序），第 4 章 |
| 8 | **只登记不定价（候选集）** | 「这三道菜让顾客挑一个，价高免单」 | `selectGroup` + `select: "manual"`，第 9 章 |
| 9 | **多门店模板复用** | 「总部出一套规则，各店换自己的菜品 UID」 | 平台规则不变 + 门店 `dishUids` / `categories` 词表重建 |
| 10 | **自然语言批量转规则** | 「把这些活动文案变成规则配置」 | `GenJsonDSL/` NL 生成链路，第 15 章 |

**这 10 类的共同点**：规则之间**互不相干**、条件**当场可判**、结果是**改价**而不是**算出一个新数**。

### 0.4 不适合用 JSON DSL 的场景（6 类，以及该怎么办）

| # | 不适合的场景 | 为什么不适合 | 该怎么办 |
| --- | --- | --- | --- |
| 1 | **任意计算公式** | 闭集里没有变量、循环、函数，`then` 只会 8 种改价 | 写代码算，用 DSL 的 `fixedPrice` 承接最终结果 |
| 2 | **依赖未建模维度** | 成本、库存、供应商、实时汇率都不在 18 字段里 | 这些维度先落库 → 折算成 `dishUids` / `categories` 再进 DSL |
| 3 | **运行期查库的动态定价** | `resolveLine()` 是同步函数，且收银链路对延迟极敏感；实时查库还会让**同一次会话前后半段用不同数据，行为不可复现** | 把结果**构建期**固化成词典/规则快照；确实要兜底查库，只放在**词典零命中**的那一次 |
| 4 | **「叠到用尽为止」的非互斥语义** | `group` 只能表达「同组只生效一条」，没有「能叠几条叠几条」 | 拆成多个不同 `group`（跨组可叠加） |
| 5 | **条件依赖其它规则的结果** | 条件判定一律基于**原始价**（第 8.5 节，防顺序依赖） | 重新设计规则，把依赖关系显式写进 `when` |
| 6 | **一次性、无审计需求的临时口径** | 写 JSON + 校验 + 回译的成本高于直接改代码 | 直接写代码，别为了「统一」硬套 DSL |

> ⚠️ **最容易踩的第 3 类**：想用「运行期查库」去弥补「快照过期」，结果同一次会话里前后半段用了不同数据 —— 出了客诉**没法复现、没法审计**。正确做法是让快照带版本号、会话开始即锁定。

### 0.5 30 秒判定速查

| 你的需求特征 | 结论 |
| --- | --- |
| 是「满足某些条件就打折/减免/送赠」 | ✅ 用 DSL |
| 需要区分会员等级、时段、品类、门槛 | ✅ 用 DSL |
| 要人工挑选/审核、要能追溯「这单为什么这么算」 | ✅ 用 DSL |
| 同一套规则要在多个门店复用 | ✅ 用 DSL |
| 要按「逐件递减 / 按成本加价 / 动态公式」算价 | ❌ 别用，写代码 |
| 条件里要判断「其它规则算完多少钱」 | ❌ 别用，条件只看原始价 |
| 每次算价都要查一次数据库或调一次接口 | ❌ 别用，先把数据固化进快照 |
| 只是临时改一次价、改完就忘 | ❌ 别用，直接改代码更快 |

**收口一句**：**JSON DSL 擅长的是「把一批业务人员能说清的定价规则，变成可校验、可审计、可复用的配置」；不擅长的是「算数」和「实时取数」。**

---

## 第 1 章 五分钟上手

一份最小可运行的策略长这样：

```json
{
  "schemaVersion": "2.0",
  "storeId": "demo_store",
  "name": "最小示例",
  "global": { "minRate": 0.5 },
  "rules": [
    {
      "id": "r_lunch_90",
      "label": "午市点心9折",
      "stage": "line",
      "group": "time_price",
      "priority": 80,
      "enabled": true,
      "when": {
        "all": [
          { "openTime": [["11:00", "14:00"]] },
          { "categories": ["cat_dim_sum"] }
        ]
      },
      "then": { "type": "discountRate", "rate": 0.9 }
    }
  ]
}
```

**读法**：午市时段（11:00–14:00）内，点心类菜品打 9 折。

三个必记的硬规则：

| 规则                                  | 说明                                             |
| ----------------------------------- | ---------------------------------------------- |
| `when` 里**只能**出现第 5 章列出的 18 个字段名    | 多一个字母即报 `FIELD_UNKNOWN` 错误                     |
| `then.type` **只能**是第 7 章列出的 8 个动作之一 | 其它值报 `ACTION_UNKNOWN`                          |
| `rate` 是**小数**不是百分数                 | 九折写 `0.9`，**不要**写 `90` 或 `9`（前者超范围报错，后者是「打一折」） |

---

## 第 2 章 分层结构总览

```
策略文档（PolicyDocument）
├── schemaVersion   "2.0"            版本标识
├── storeId         门店/租户标识
├── name / description / generatedAt 元信息
├── global                          全局参数（目前只有 minRate）
│   └── minRate     0.1             全局最低折扣钳制
└── rules[]                         规则列表（上限 500 条）
    ├── id          唯一标识（必填）
    ├── label       中文名（回译用）
    ├── enabled     开关
    │
    ├── 【作用位置】
    ├── stage       line | order      行级 / 整单级
    │
    ├── 【冲突消解】
    ├── group       "g_xxx"           互斥分组（同组只生效一条）
    ├── priority    0~10000           组内优先 + 跨组叠加次序
    │
    ├── 【候选集机制 · 可选】
    ├── selectGroup "sg_xxx"          并列候选组（与 group 正交）
    ├── select      manual | priority 候选集交给谁消费
    │
    ├── when        条件树            见第 4、5 章
    └── then        动作（对象或数组）  见第 7 章
```

**一句话记忆**：`group` 管「同一批规则里只让一条赢」，`priority` 管「谁赢 + 谁先叠加」，`stage` 管「在行级还是整单级生效」，`selectGroup` 管「这批规则只产出候选不参与定价」。

---

## 第 3 章 策略文档层字段

| 字段                   | 类型     | 必填    | 说明                                                                          |
| -------------------- | ------ | ----- | --------------------------------------------------------------------------- |
| `schemaVersion`      | string | 否     | 建议写明。合法格式为 `1.x` 或 `2.x`（正则 `^[12]\.\d+$`）。**注意是字符串**。缺失只告警不报错，按 `"2.0"` 处理 |
| `storeId`            | string | 否     | 门店标识，引擎不做强校验                                                                |
| `storeName`          | string | 否     | 门店名，仅展示                                                                     |
| `name`               | string | 否     | 策略名                                                                         |
| `description`        | string | 否     | 策略说明                                                                        |
| `generatedAt`        | string | 否     | ISO 8601 时间戳，仅展示                                                            |
| `global`             | object | 否     | 全局参数容器                                                                      |
| `global.minRate`     | number | 否     | 全局最低折扣率，值域 `[0,1]`。生效需引擎侧开关打开，见第 10 章                                        |
| `global.minRateNote` | string | 否     | 注释，仅展示                                                                      |
| `minRate`            | number | 否     | 兼容写法，等同 `global.minRate`，同样受 `[0,1]` 校验                                     |
| `rules`              | array  | **是** | 规则列表。非数组报 `RULES_TYPE`；空数组告警 `RULES_EMPTY`；超过 **500** 条报 `RULES_TOO_MANY`   |

> ⚠️ **`schemaVersion` 的历史坑**：`data/default-policy.json` 写的是 `"1.0"`，但它内部用了 `openTime` 这种 v2 字段——校验器照样放行。原因是**字段闭集是全集校验，不按版本收窄**。因此：版本号目前只是「标注」，不是「能力开关」。写 `"2.0"` 是最推荐的做法。

---

## 第 4 章 规则层字段

### 4.1 字段表

| 字段            | 类型      | 必填    | 默认           | 说明                                                    |                                         |
| ------------- | ------- | ----- | ------------ | ----------------------------------------------------- | --------------------------------------- |
| `id`          | string  | **是** | —            | 规则唯一标识。缺失报 `RULE_NO_ID`；全文重复报 `ID_DUPLICATE`          |                                         |
| `label`       | string  | 建议    | —            | 中文名。与 `name` 二者至少有一个，都缺则告警 `RULE_NO_LABEL`。回译会拿它做交叉校验 |                                         |
| `name`        | string  | 否     | —            | `label` 的别名                                           |                                         |
| `desc`        | string  | 否     | —            | 规则详细说明，仅展示                                            |                                         |
| `enabled`     | boolean | 否     | `true`       | 非布尔报 `ENABLED_TYPE`。`false` 的规则在装配阶段被跳过               |                                         |
| `stage`       | string  | 否     | `"line"`     | 取值 `line` / `order`，其它值报 `STAGE_INVALID`              |                                         |
| `group`       | string  | 否     | —            | 互斥组名。**同组内只有 `priority` 最大的一条生效**                     |                                         |
| `priority`    | number  | 否     | —            | 值域 `[0, 10000]`（含边界）。超范围报 `PRIORITY_RANGE`            |                                         |
| `selectGroup` | string  | 否     | —            | 并列候选组名，非空字符串。见第 9 章                                   |                                         |
| `select`      | string  | 否     | `"priority"` | 取值 `manual` / `priority`。**必须与 `selectGroup` 同时出现**   |                                         |
| `when`        | object  | 见下    | —            | 条件树。见第 4、5 章                                          |                                         |
| `then`        | object  | array | **是**        | —                                                     | 动作。缺失报 `THEN_MISSING`，空数组报 `THEN_EMPTY` |

### 4.2 `stage` 的约束（硬约束，会报错）

`stage` 决定这条规则能用哪一类动作：

| stage   | 允许的动作                                                                                  | 写了不允许的                    |
| ------- | -------------------------------------------------------------------------------------- | ------------------------- |
| `line`  | `discountRate` / `fixedPrice` / `discountAmount` / `bestOf` / `maxQty` / `memberPrice` | 报 `STAGE_ACTION_MISMATCH` |
| `order` | `orderReduce` / `gift`                                                                 | 报 `STAGE_ACTION_MISMATCH` |

**举例**：`stage: "line"` 配 `then: { type: "orderReduce", amount: 20 }` → 校验失败，因为整单立减只能在 `order` 阶段。

> **`gift` 为什么算整单级？** 赠品会往整单里追加一行，改变的是订单构成而非某一行价格，所以归到 `order`。

### 4.3 `group` 与 `selectGroup` 的关系（关键，易错）

两者**正交**，一条规则可以同时有：

```json
{
  "id": "r_a",
  "group": "g_promo",
  "selectGroup": "sg_dessert",
  "select": "manual",
  "when": { "categories": ["cat_dessert"] },
  "then": { "type": "discountRate", "rate": 0.8 }
}
```

区别：

|      | `group`          | `selectGroup`                                                        |
| ---- | ---------------- | -------------------------------------------------------------------- |
| 目的   | 互斥——同组只留一条**改价** | 并列——同组全部**保留为候选**                                                    |
| 是否改价 | **是**，获胜那条会改价    | **否**，候选规则一律不改价                                                      |
| 生效条件 | 无条件              | 配 `select: "manual"` 时才被拦下；`select: "priority"` 时行为等同无 `selectGroup` |

详细语义见第 9 章。

### 4.4 `priority` 的双重作用

`priority` 影响两件事，不要混淆：

1. **组内择优**：同一个 `group` 内，`priority` 最大者获胜（**同 priority 是校验错误**，见第 11 章 `GROUP_PRIORITY_DUP`）。
2. **跨组叠加次序**：不同组之间不是取最低，而是**按 `priority` 从大到小链式叠加**，即「高优先级规则先改写价格，低优先级规则在高优先级的**结果**上继续改写」。

> 举个例子：A 组 `rate 0.8`、B 组 `amount 5`，A 的 priority 更高 → 先打 8 折，再在折后价上减 5。  
> 若 B 的 priority 更高 → 先减 5，再在减后价上打 8 折。**结果不同**，所以优先级设计要谨慎。

### 4.5 `then` 写成数组

`then` 允许是数组，表示**同一条规则内按顺序叠加多个动作**：

```json
"then": [
  { "type": "discountRate", "rate": 0.9 },
  { "type": "discountAmount", "amount": 2 }
]
```

- 数组内动作**不互斥**，按书写顺序依次施加（先 9 折，再减 2 元）。
- 行级规则若写了 **>1 个价格型动作**，校验器告警 `MULTI_PRICE_ACTION`（提示「将按顺序叠加」），不阻止。
- **`maxQty` / `gift` 本身不改价**，只是记录限购/赠品信息；它们与价格型动作共存是正常用法。

---

## 第 5 章 条件字段全量（18 个）

以下 18 个字段名**构成闭集**（`engine.js` 的 `CONDITION_FIELDS`）。`when` 里出现闭集外的键，直接报 `FIELD_UNKNOWN`。集合按**分组**记忆：

### 5.1 时间维度（5 个）

| 字段          | 值形态  | 语义                                                               | 示例                                |
| ----------- | ---- | ---------------------------------------------------------------- | --------------------------------- |
| `days`      | 数组   | 星期。支持英文缩写 `mon`~~`sun`、中文 `周一`~~`周日`、数字 `0~7`（0/7=周日）、区间 `[1,5]` | `["mon","tue"]`、`[[1,5]]`、`[6,7]` |
| `time`      | 区间数组 | 通用时段判定                                                           | `[["11:00","14:00"]]`             |
| `orderTime` | 区间数组 | 下单时间                                                             | `[["18:00","20:00"]]`             |
| `openTime`  | 区间数组 | **门店营业/开市时间**（最常用）                                               | `[["11:00","14:00"]]`             |
| `closeTime` | 区间数组 | 收市时间                                                             | `[["21:00","23:00"]]`             |

**时间值的格式**（`TIME_FIELDS` 共用一套，由 `validateTimeValue` 校验）：

```json
"openTime": [["11:00", "14:00"]]
```

- 必须是「区间数组」`[[起, 止], ...]`，可以写多段：`[["11:00","14:00"], ["17:00","21:00"]]`
- 元素必须是二元组 `[起, 止]`，否则报 `TIME_SEG`
- 时间串必须是 `HH:mm`，否则报 `TIME_FMT`
- **半开区间 `[起, 止)`**：`["11:00","14:00"]` **不含** `14:00` 整点
- **起 > 止 = 跨午夜**，如 `["22:00","02:00"]` 表示晚 10 点到次日凌晨 2 点。校验器只给告警 `TIME_ORDER` 让你确认，不阻止
- 空数组告警 `TIME_EMPTY`（恒不命中）


### 5.2 商品维度（6 个）

| 字段           | 值形态  | 语义                     | 示例                         |
| ------------ | ---- | ---------------------- | -------------------------- |
| `dishUids`   | 数组   | 菜品 UID 白名单             | `["dish_204","dish_205"]`  |
| `categories` | 数组   | 菜品分类 UID 白名单           | `["cat_dim_sum"]`          |
| `tags`       | 数组   | 菜品标签                   | `["特价菜"]`、`["招牌"]`         |
| `hasDish`    | 数组   | 「订单中是否包含这些菜」——**整单视角** | `["dish_204"]`             |
| `lineQty`    | 范围对象 | **当前行**的数量             | `{ "min": 2 }`             |
| `priceRange` | 范围对象 | 价格区间                   | `{ "min": 10, "max": 50 }` |

> ⚠️ 注意：字段闭集里**没有** `dishUid` / `dishName` / `category` 单数形式，也没有 `basePrice`。商品维度只有上表 6 个。写单数形式会报 `FIELD_UNKNOWN`。

### 5.3 整单维度（4 个）

| 字段            | 值形态  | 语义            | 示例                      |
| ------------- | ---- | ------------- | ----------------------- |
| `orderAmount` | 范围对象 | 整单金额          | `{ "min": 200 }`        |
| `orderQty`    | 范围对象 | 整单总份数         | `{ "min": 5 }`          |
| `guestCount`  | 范围对象 | 就餐人数          | `{ "min": 4 }`          |
| `dateTags`    | 数组   | 日期标签（自定义日历标签） | `["holiday","weekend"]` |

### 5.4 会员维度（2 个）

| 字段            | 值形态 | 语义                                                             | 示例                   |
| ------------- | --- | -------------------------------------------------------------- | -------------------- |
| `memberLevel` | 数组  | 会员等级。字符串元素，引擎内置序：`normal < silver < gold < diamond < platinum` | `["gold","diamond"]` |
| `memberTags`  | 数组  | 会员标签                                                           | `["newUser","vip"]`  |

### 5.5 其它（1 个）

| 字段      | 值形态 | 语义      | 示例                            |
| ------- | --- | ------- | ----------------------------- |
| `dates` | 数组  | 具体日期白名单 | `["2026-01-01","2026-10-01"]` |

### 5.6 字段类型速查（决定值怎么写）

校验器把字段分成三类，**值形态写错会直接报错**：

| 类别      | 字段                                                                                            | 值必须是            | 错误码          |
| ------- | --------------------------------------------------------------------------------------------- | --------------- | ------------ |
| **列表型** | `days` `dates` `dateTags` `dishUids` `categories` `tags` `memberLevel` `memberTags` `hasDish` | 数组              | `LIST_TYPE`  |
| **范围型** | `lineQty` `orderQty` `orderAmount` `guestCount` `priceRange`                                  | `{min, max}` 对象 | `RANGE_TYPE` |
| **时间型** | `time` `orderTime` `openTime` `closeTime`                                                     | `[[起,止]]`       | `TIME_TYPE`  |

**范围对象的规则**（`validateRangeValue`）：

- 必须是对象 `{ "min": 2 }`，不能写成数字 `2`
- `min` / `max` **至少给一个**，都给才校验 `min <= max`
- 都不给报 `RANGE_EMPTY`；`min` 非数字报 `RANGE_MIN_TYPE`；`max` 非数字报 `RANGE_MAX_TYPE`
- `min > max` 报 `RANGE_INVALID`

**列表型的边界情况**：

- 空数组告警 `LIST_EMPTY`（提示「该条件恒不命中」）
- `days` 元素值域非法报 `DAY_INVALID`
- `memberLevel` 元素非字符串报 `MEMBER_LEVEL_INVALID`

### 5.7 「行级字段」出现在 order 规则里

`lineQty` / `dishUids` / `categories` / `tags` / `hasDish` / `priceRange` 是**行级字段**（`LINE_ONLY_FIELDS`）。如果一条 `stage: "order"` 的规则用了它们，校验器告警 `ORDER_STAGE_LINE_FIELD`：

> 「order stage 规则中使用了行级字段 X，可能导致逻辑混淆」

不阻止，但通常是设计错误 —— 整单级规则里「这一行」指哪一行是不明确的。

---

## 第 6 章 条件组合子与写法

### 6.1 三个组合子

| 组合子   | 含义               | 值类型           |
| ----- | ---------------- | ------------- |
| `all` | **AND**，全部子条件都满足 | 数组            |
| `any` | **OR**，任一子条件满足即可 | 数组            |
| `not` | **NOT**，子条件取反    | **对象**（不是数组！） |

### 6.2 ⚠️ 重要：`not` 必须嵌进 `all` / `any`，不要同行并列

**这是当前实现的一个缺陷，写错会让规则永不命中，且不报任何错。**

| 写法                                       | 结果                                 |
| ---------------------------------------- | ---------------------------------- |
| ❌ `{ "all": [...], "not": {...} }`       | **`all` 与 `not` 同时判 false**，规则永不命中 |
| ✅ `{ "all": [ ..., { "not": {...} } ] }` | 正常工作                               |

实测对照（条件均为「周六 + 热菜 + 不带特价标签」）：

```json
// ❌ 错误写法：四个场景全部 MISS
"when": {
  "all": [
    { "days": ["sat", "sun"] },
    { "categories": ["cat_hot"] }
  ],
  "not": { "tags": ["特价菜"] }
}
```

```json
// ✅ 正确写法：语义完全正确
"when": {
  "all": [
    { "days": ["sat", "sun"] },
    { "categories": ["cat_hot"] },
    { "not": { "tags": ["特价菜"] } }
  ]
}
```

正确写法的四种情况实测（`rate 0.5`，原价 ¥100）：

| 场景            | 期望   | 实测     |
| ------------- | ---- | ------ |
| 周六 + 热菜 + 非特价 | HIT  | ✅ HIT  |
| 周六 + 热菜 + 特价菜 | MISS | ✅ MISS |
| 周三 + 热菜 + 非特价 | MISS | ✅ MISS |
| 周日 + 热菜 + 非特价 | HIT  | ✅ HIT  |

> **结论：`not` 一律作为 `all` / `any` 数组的一个元素来写。**  
> 需要「A 且 非B」时，写成 `"all": [ A, { "not": B } ]`；  
> 需要「A 或 非B」时，写成 `"any": [ A, { "not": B } ]`。
>
> 好在 `data/select-group-policy.json` 里 `r_sg_bottom_line` 用的是 `{ "not": {...} }` 单独一条（没有 `all` 并列），所以不受影响——这也解释了为什么它一直是正常的。

### 6.3 组合子的语义

| 组合子   | 含义               | 值类型           |
| ----- | ---------------- | ------------- |
| `all` | **AND**，全部子条件都满足 | 数组            |
| `any` | **OR**，任一子条件满足即可 | 数组            |
| `not` | **NOT**，子条件取反    | **对象**（不是数组！） |

多个 `all` 子条件之间是 AND 关系。**`not` 的正确位置是数组元素，不是与 `all` 平级的键。**

### 6.4 嵌套与深度

组合子可以嵌套，构成条件树。**最大深度 5 层**（`MAX_CONDITION_DEPTH = 5`），超出报 `WHEN_DEPTH`。

```json
"when": {
  "all": [
    { "categories": ["cat_hot"] },
    {
      "any": [
        { "memberLevel": ["gold"] },
        { "all": [
            { "days": ["sat", "sun"] },
            { "orderAmount": { "min": 200 } }
        ]}
      ]
    }
  ]
}
```

读作：热菜 且 （是黄金会员 或 （周末 且 整单满 200））。

**组合子类型写错**：`all` / `any` 不是数组报 `COMBINATOR_TYPE`；`not` 不是对象报 `COMBINATOR_TYPE`。

### 6.5 空数组的语义（重要区别）

| 写法          | 语义                 | 校验器                   |
| ----------- | ------------------ | --------------------- |
| `"all": []` | **恒真**（没有任何条件需要满足） | 告警 `COMBINATOR_EMPTY` |
| `"any": []` | **恒假**（没有任何条件能满足）  | 告警 `COMBINATOR_EMPTY` |

这两个是**反直觉的坑**：`all` 空集在逻辑上是真，`any` 空集在逻辑上是假。写空了通常意味着生成时漏了内容，所以校验器都会告警。

### 6.6 集合谓词的写法

`dishUids` / `categories` / `tags` 等列表字段，历史上支持过四种写法。**当前推荐只用前一种简写**：

```json
// ✅ 推荐：简写，等价于 in
"categories": ["cat_hot", "cat_cold"]

// 兼容：显式 in
"categories": { "in": ["cat_hot"] }

// 兼容：显式 notIn
"categories": { "notIn": ["cat_hot"] }

// 兼容：显式 all（要求全部命中，主要用于 tags）
"tags": { "all": ["招牌", "新品"] }
```

生成器**统一输出简写数组形式**，可读性最好。

### 6.7 条件里不要写「金额」的直觉陷阱

条件判定**基于原始输入价**（见第 8.5 节），不基于已被其他规则改写过的价格。所以：

- 想表达「折后满 200 减 20」——DSL 里**做不到**。`orderAmount` 看的是原始整单金额。
- 想表达「基于某规则结果」的依赖——DSL 不提供跨规则引用。需要拆成不同的 `priority` 层次靠叠加次序实现。

---

## 第 7 章 动作类型全量（8 型）

动作类型闭集（`engine.js` 的 `ACTION_TYPES`，共 **8** 个）：

```
discountRate  discountAmount  fixedPrice  bestOf  maxQty  memberPrice   ← 行级（6 个）
orderReduce   gift                                                      ← 整单级（2 个）
```

> ⚠️ **纠正一处常见误解**：`allocate`（摊分策略）**不是**独立动作类型，它是 `orderReduce` 的一个参数。README 早期描述把它并列写出来容易误导。

### 7.1 行级动作（`stage: "line"`）

#### ① `discountRate` —— 打折

```json
{ "type": "discountRate", "rate": 0.9 }
```

| 字段     | 必填 | 值域                                                  |
| ------ | -- | --------------------------------------------------- |
| `rate` | 是  | `(0, 1]`，**开区间左侧**。`0` 报 `RATE_RANGE`，`1` 合法（等于不打折） |

语义：`新价 = 当前价 × rate`。  
**`rate: 1` 是「不改价」的标准占位手法**，常用于「只做标记/路由/可售状态」的规则。

#### ② `fixedPrice` —— 固定价（终态）

```json
{ "type": "fixedPrice", "price": 16.8 }
```

| 字段      | 必填 | 值域                              |
| ------- | -- | ------------------------------- |
| `price` | 是  | `>= 0`，非负数字。非法报 `PRICE_INVALID` |

语义：`新价 = price`（直接覆盖，不看当前价）。  
**关键特性**：`fixedPrice` 是**终态动作**。一旦某条规则施加了 `fixedPrice`，后续跨组规则**不再改写这一行**（引擎内部标记 `final: true`）。这叫「一价封顶」。

#### ③ `discountAmount` —— 减额

```json
{ "type": "discountAmount", "amount": 5 }
```

| 字段       | 必填 | 值域                               |
| -------- | -- | -------------------------------- |
| `amount` | 是  | `>= 0`，非负数字。非法报 `AMOUNT_INVALID` |

语义：`新价 = 当前价 - amount`。作用于**当前累计价**，不是原价。

#### ④ `bestOf` —— 多方案取最优（终态）

```json
{
  "type": "bestOf",
  "options": [
    { "type": "discountRate", "rate": 0.85 },
    { "type": "discountAmount", "amount": 8 },
    { "type": "fixedPrice", "price": 16.8 }
  ]
}
```

| 字段        | 必填 | 值域                                                  |
| --------- | -- | --------------------------------------------------- |
| `options` | 是  | 非空数组。空数组报 `BESTOF_EMPTY`；非数组报 `BESTOF_OPTIONS_TYPE` |

- `options` 内元素**只能是** `discountRate` / `fixedPrice` / `discountAmount`（`BESTOF_OPT_TYPES`）
- 引擎会把每个选项都算一遍，取**价格最低**的那个作为结果
- 只有一个选项时告警 `BESTOF_SINGLE`（退化为普通动作，建议直接写那个动作）
- 与 `fixedPrice` 一样是**终态**：结果即为该行定价终点
- 也**不参与同组互斥**（它是「取最优」本身，比的是选项之间，不是和别的规则比）

#### ⑤ `maxQty` —— 限购

```json
{ "type": "maxQty", "maxQty": 1 }
```

| 字段       | 必填        | 同义写法                       |
| -------- | --------- | -------------------------- |
| `maxQty` | 是（三个别名任选） | `maxQty` / `limit` / `qty` |

值必须为正数，否则报 `MAXQTY_INVALID`。

语义：**不改价**，只记录「这一行最多按促销价享受 N 份」。超出部分恢复原价。引擎内部会计算并记录 `limitApplied: { maxQty, qty, overQty, promoPrice }`。

配合同一条规则里的价格动作使用：

```json
"then": [
  { "type": "discountRate", "rate": 0.5 },
  { "type": "maxQty", "maxQty": 1 }
]
```

读作：半价，但每单最多一份享受半价。

#### ⑥ `memberPrice` —— 会员专属价

```json
{ "type": "memberPrice", "price": 88 }
```

| 字段                                  | 必填         | 说明                           |
| ----------------------------------- | ---------- | ---------------------------- |
| `price` **或** `rate` **或** `amount` | 三者**恰选一个** | 多给或少给报 `MEMBERPRICE_INVALID` |

三种模式：

| 写法                                       | 语义                           |
| ---------------------------------------- | ---------------------------- |
| `{ "type":"memberPrice", "price": 88 }`  | 会员一口价 88                     |
| `{ "type":"memberPrice", "rate": 0.85 }` | 会员额外 85 折（`rate` 需在 `(0,1]`） |
| `{ "type":"memberPrice", "amount": 10 }` | 会员再减 10 元                    |

### 7.2 整单级动作（`stage: "order"`）

#### ⑦ `orderReduce` —— 整单立减

```json
{ "type": "orderReduce", "amount": 20, "allocate": "byLineAmount" }
```

| 字段         | 必填 | 值域                                                   |
| ---------- | -- | ---------------------------------------------------- |
| `amount`   | 是  | `>= 0`，非负数字                                          |
| `allocate` | 否  | `byLineAmount`(默认) / `byQty` / `toCheapest` / `none` |

语义：整单减 `amount`，然后按 `allocate` 策略**摊分**到各订单行（P3 阶段）。


| `allocate` 值   | 摊分口径              |
| -------------- | ----------------- |
| `byLineAmount` | 按各**行金额占比**摊分（默认） |
| `byQty`        | 按各**行份数占比**摊分     |
| `toCheapest`   | 全部摊到**最便宜**的那行    |
| `none`         | 不摊分，只记在整单上        |

非法值报 `ALLOCATE_INVALID`。注意：整单有多条 `orderReduce` 时，摊分策略**取第一条**（引擎简化实现）。

#### ⑧ `gift` —— 赠品

```json
{ "type": "gift", "dishUid": "dish_801", "qty": 1 }
```

| 字段                         | 必填   | 说明                          |
| -------------------------- | ---- | --------------------------- |
| `dishUid` **或** `dishName` | 至少一个 | 都缺报 `GIFT_NO_DISH`          |
| `qty`                      | 否    | 默认 `1`，必须为正数，否则报 `GIFT_QTY` |
| `allocate`                 | 否    | 同 `orderReduce`             |

语义：**不改金额**，往整单里追加一行赠品。返回体的 `gifts[]` 数组会记录它。

### 7.3 简写写法：`value` 字段

所有单值动作都支持把专属字段写成 `value`，引擎会自动映射（`VALUE_FIELD`）：

| 动作               | 规范写法     | 简写      |
| ---------------- | -------- | ------- |
| `discountRate`   | `rate`   | `value` |
| `fixedPrice`     | `price`  | `value` |
| `discountAmount` | `amount` | `value` |
| `orderReduce`    | `amount` | `value` |
| `gift`           | `qty`    | `value` |
| `maxQty`         | `maxQty` | `value` |
| `memberPrice`    | `price`  | `value` |

所以 `{ "type":"discountRate", "value":0.9 }` 等价于 `{ "type":"discountRate", "rate":0.9 }`。

> **建议生成器统一输出规范写法**（`rate` / `price` / `amount`），可读性更好、不易被误读。

### 7.4 具名包装写法（兼容，不推荐）

引擎还兼容这种老写法：

```json
"then": { "bestOf": { "options": [ ... ] } }
```

即「单键包装」，键名就是动作名。校验器会给告警 `THEN_WRAPPED` 提示「建议写为标准 `{ type:"xxx", ... }`」。**新生成的策略请一律用标准写法。**

---

## 第 8 章 求值语义（四阶段）

这是「引擎拿到策略后到底怎么算」的权威描述。整条管线分 **5 个阶段**（P0~P3 加一个钳制步骤）：

```
P0  装配          编译规则 → 建倒排索引
 ↓
P1  行级定价       对每一行，跑 stage=line 的规则（同组互斥 + 跨组链式叠加）
 ↓
P1.5 钳制          minRate 兜底：行价不得低于原价 × minRate
 ↓
P2  整单级         跑 stage=order 的规则（orderReduce 累加、gift 收集）
 ↓
P3  摊分           把整单立减额按 allocate 策略摊回各订单行
```

### 8.1 P0 装配

`RuleEngine.fromDoc(doc, catalogIndex, options)` 时：

- 逐条编译规则（`compileRule`），归一化 `then`（数组化、`value` 映射、具名包装解包）
- 跳过 `enabled: false` 的规则
- 条件字段建**倒排索引**加速（注意：`not` 维度的索引处理有专门修复，否则会「永不命中」）

### 8.2 P1 行级定价

对**每一个订单行**：

**第一步：筛选候选规则**  
遍历所有 `stage: "line"` 且条件命中的规则。

**第二步：同组互斥（组内择优）**  
同一个 `group` 内，只保留 `priority` 最大的一条。同组有多条 priority 相同时是**校验错误**。

例外：

- `bestOf` 动作的规则**不参与同组互斥**
- `selectGroup` + `select: manual` 的规则在此被**拦下**，不进组内比较（见第 9 章）

**第三步：跨组链式叠加**  
剩余的「组冠军」按 `(priority 降序, id 升序)` 排序，然后**依次施加**：

```
价格从「行原始价」出发
  → 施加 priority 最高的规则  → 得到新价
  → 在新价基础上施加下一条    → 得到新价
  → ...
```

**注意**：不是「各组算出价格后取最低」，而是**真的按顺序一层层改写**。这带来两个必记结论：

1. **顺序敏感**：`先打8折再减5` ≠ `先减5再打8折`。
2. **`fixedPrice` 是终态**：一旦遇到 `fixedPrice`（或 `bestOf`）产生的结果，**链式叠加到此为止**，后面的规则不再改写这一行。

**第四步：限购处理**  
若规则带了 `maxQty`，超出份数按原价计。

### 8.3 P1.5 minRate 钳制

在行级定价**全部完成后、整单级开始前**，对每一行做兜底：

```
行最终价 = max(行定价结果, 行原始价 × minRate)
```

`minRate` 的来源优先级见第 10 章。

> 这个阶段位置很关键：钳制发生在行级之后、整单之前。所以整单立减后的价格**不会**再受行级 minRate 约束。

### 8.4 P2 整单级 + P3 摊分

- 跑 `stage: "order"` 的规则，同样走「同组互斥 + 跨组叠加」
- `orderReduce` 的 `amount` **累加**（多条立减叠加）
- `gift` 收集进 `gifts[]`
- P3 按 `allocate` 策略把总立减额摊到各行，写入每行的 `allocated` 字段

### 8.5 条件判定基于原始价（防顺序依赖）

**所有 `when` 的判定，用的都是「原始输入价 / 原始输入数量 / 原始整单金额」，不是被前面规则改写过的值。**

这条设计保证了：

- 交换规则顺序**不会**改变「哪条规则命中」的结论（只可能改变叠加后的价格）
- 不会出现「A 命中导致 B 不命中，B 不命中又让 A 不命中」的循环依赖

举个直观例子：`orderAmount: { min: 200 }` 看的是顾客原始消费 200，而不是打完折后的 160。

---

## 第 9 章 候选组语义（selectGroup）

### 9.1 它解决什么问题

有些业务场景里，同一个菜品会同时挂着**多个互不相同的优惠方案**，需要**把方案清单交出去让别人挑**，而不是由引擎自己定：

- 「虾饺皇今天有 8 折、减 5 元、固定价 35 三种活动，请收银员选一个」
- 「这个菜有 4 个可用活动，交给程序侧算法按业务规则筛一个」

`group` 做不到这件事——它只会「挑一条赢」。所以有了 `selectGroup`。

### 9.2 核心口径（务必记住）

> **候选规则只负责「产出候选集合」，不参与定价。产出候选集后规则即完成使命。**

这句话包含三层含义：

|            | 含义                             |
| ---------- | ------------------------------ |
| ✗ 不代替选择    | 引擎**不会**替你从候选里挑一条去改价           |
| ✗ 不据选择改价   | 就算外面传回「选了 B」，引擎也**不会**因为这条回告改价 |
| ✗ 不因没人选而挂起 | 不存在「没人选所以这单算不出来」的状态            |

### 9.3 两种 `select` 模式

| 模式               | 候选集交给谁            | 是否改价                            | 是否走既有同组互斥       |
| ---------------- | ----------------- | ------------------------------- | --------------- |
| `"manual"`       | **收银员**（POS 侧人工挑） | **不改**                          | **不走**——规则被完全拦下 |
| `"priority"`（默认） | **程序侧算法**         | 按无 `selectGroup` 时的既有口径**照常改价** | **走**           |

关键区别：

- `manual` = 「这条规则只登记候选，别拿它算钱」
- `priority` = 「这条规则正常算钱；另外顺手把候选集也暴露出来给程序参考」

所以 **`priority` 是向后兼容的**：给老策略加上 `selectGroup` + `select: "priority"` 后，定价结果**完全不变**，只是返回体里多了候选集信息。

### 9.4 写法

```json
{
  "id": "r_sg_dimsun_a",
  "label": "虾饺皇 8 折",
  "stage": "line",
  "selectGroup": "sg_dimsun_manual",
  "select": "manual",
  "priority": 100,
  "when": { "dishUids": ["dish_204"] },
  "then": { "type": "discountRate", "rate": 0.8 }
}
```

同一 `selectGroup` 的多条规则构成一组候选：

```json
[
  { "id":"r_sg_dimsun_a", "selectGroup":"sg_dimsun_manual", "select":"manual", "priority":100, "then":{"type":"discountRate","rate":0.8} },
  { "id":"r_sg_dimsun_b", "selectGroup":"sg_dimsun_manual", "select":"manual", "priority":90,  "then":{"type":"discountAmount","amount":5} },
  { "id":"r_sg_dimsun_c", "selectGroup":"sg_dimsun_manual", "select":"manual", "priority":80,  "then":{"type":"fixedPrice","price":35} }
]
```

### 9.5 校验约束

| 情况                                   | 结果                                                       |
| ------------------------------------ | -------------------------------------------------------- |
| `select` 值不在 `manual` / `priority` 内 | 报错 `SELECT_MODE_INVALID`                                 |
| 写了 `select` 但没写 `selectGroup`        | 报错 `SELECT_WITHOUT_GROUP`（`select` 描述的是候选组内的选择方式，脱离组无意义） |
| `selectGroup` 不是非空字符串                | 报错 `SELECT_GROUP_TYPE`                                   |
| 只写 `selectGroup` 不写 `select`         | 合法，默认按 `priority`                                        |

### 9.6 引擎返回的候选集结构

`resolveLine` 返回体的 `selectGroups` 是一个「组名 → 候选组对象」的映射：

```json
{
  "sg_dimsun_manual": {
    "mode": "manual",
    "readonly": false,
    "bestRuleId": "r_sg_dimsun_a",
    "bestPrice": 33.6,
    "chosenRuleId": null,
    "fromManual": false,
    "suboptimal": false,
    "pending": false,
    "candidates": [
      { "ruleId":"r_sg_dimsun_a", "label":"虾饺皇 8 折",   "kind":"discountRate",  "price":33.6, "priority":100, "isBest":true,  "isChosen":false },
      { "ruleId":"r_sg_dimsun_b", "label":"虾饺皇 减 5 元", "kind":"discountAmount", "price":37.0, "priority":90,  "isBest":false, "isChosen":false },
      { "ruleId":"r_sg_dimsun_c", "label":"虾饺皇 固定价 35","kind":"fixedPrice",     "price":35.0, "priority":80,  "isBest":false, "isChosen":false }
    ]
  }
}
```

字段含义：

| 字段                         | 说明                                                                      |
| -------------------------- | ----------------------------------------------------------------------- |
| `mode`                     | 该组的 `select` 模式                                                         |
| `readonly`                 | `true` 表示程序侧只读参考（`priority` 组），`false` 表示可交互选择（`manual` 组）              |
| `bestRuleId` / `bestPrice` | **只读参考口径**：按价格最低算出的最优候选。**不代表引擎会采用它**                                   |
| `chosenRuleId`             | 外部回告的选择结果。没回告时为 `null`。**引擎只记录，不改价**                                    |
| `fromManual`               | 该选择是否来自人工回告                                                             |
| `suboptimal`               | 选的那条不是价格最优 → `true`（仅审计提示）                                              |
| `pending`                  | **恒为 `false`**（v2.2.1 已废除「挂起」语义）                                        |
| `candidates[]`             | 候选清单，每条含 `ruleId`/`label`/`kind`/`price`/`priority`/`isBest`/`isChosen` |

### 9.7 外部回告选择结果的入参格式

若 POS 侧收银员选了「8 折」，回告给引擎的形式是：

```js
// resolveLine(ctx, sel) 的第二个参数
{
  chosen: { sg_dimsun_manual: "r_sg_dimsun_a" },
  choices: { /* 其它选择态 */ }
}
```

引擎会把它反映到 `chosenRuleId` / `isChosen` / `suboptimal` 上，**但价格不变**。

### 9.8 实测对照（`select-group` 场景）

| 用例   | 输入              | finalPrice    | applied                | 说明                   |
| ---- | --------------- | ------------- | ---------------------- | -------------------- |
| sg01 | 虾饺皇（manual 组）   | **42.00**（原价） | `["r_sg_bottom_line"]` | 三条候选全保留，**不改价**      |
| sg02 | 酸梅汤（priority 组） | **10.80**     | `["r_sg_drink_a"]`     | 照常按同组互斥定价（9 折）       |
| sg03 | 流沙包（普通规则）       | 18.00         | —                      | 无 `selectGroup`，正常改价 |
| sg04 | 虾饺皇 + 兜底并存      | 42.00         | `["r_sg_bottom_line"]` | 兜底规则 `rate:1` 不改价    |
| sg06 | 多行混合整单          | 88.80         | —                      | 42 + 36 + 10.80      |

**看 sg01 和 sg02 的对比就理解了**：同样是「一组并列候选」，`manual` 组的行价格纹丝不动（42），`priority` 组照常打折（10.8）。

### 9.9 设计动机：为什么 `best` 模式被移除了

早期有过 `select: "best"`（让引擎自动在候选里比价取最优），v2.2 移除。原因值得抄下来给 AI 看：

> 候选规则产出的动作类型可能完全不同——折扣率、固定金额、赠品、会员价。**「最优」在 DSL 层没有统一可比较的口径**。把比价逻辑写进规则，等于让 DSL 承担它无法定义的语义。
>
> 正确做法：引擎只**暴露候选集**，比价由**程序侧**按业务口径算法筛选。`bestPrice` 只是「按价格最低」的只读参考。

---

## 第 10 章 minRate 三级解析

`minRate` 是「最低折扣率」钳制——最终行价不得低于 `原价 × minRate`。它有**三个来源**，按优先级解析：

| 优先级  | 来源                            | 说明                   |
| ---- | ----------------------------- | -------------------- |
| ① 最高 | **商品目录** `dish.minRate`       | **权威值**。写在菜品数据里，一菜一率 |
| ② 中  | **引擎选项** `options.minRate`    | 调用 `fromDoc` 时传入     |
| ③ 最低 | **策略文档** `doc.global.minRate` | 写在 JSON DSL 里        |

### 10.1 第 ③ 级需要显式开关

`global.minRate` **不是自动生效的**。要让它起作用，调用时必须传：

```js
RuleEngine.fromDoc(policyDoc, catalogIndex, { useGlobalMinRate: true });
```

不传 `useGlobalMinRate: true`（或传 `false`），`global.minRate` 会被忽略。

### 10.2 实践建议

| 场景       | 建议写法                                         |
| -------- | -------------------------------------------- |
| 单店统一折扣底线 | 用 `global.minRate` + 调用时开 `useGlobalMinRate` |
| 不同菜有不同底线 | 用 `dish.minRate`（写商品目录）                      |
| 演示/临时覆盖  | 用 `options.minRate`                          |

### 10.3 值域

`global.minRate` 和顶层 `minRate` 都必须在 `[0, 1]`，否则报 `MINRATE_RANGE`。

### 10.4 返回体里的体现

行级结果会带 `dishMinRate` 字段，告诉你这一行实际用了哪个 minRate 值。

---

## 第 11 章 校验规则清单

校验器 `validatePolicy(doc)` 返回 `{ ok, errors, warnings, checks, summary }`。**`ok === false` 时策略不允许启用**（fail-closed：保留上一版策略，新版进草稿态）。

### 11.1 错误（errors）——阻断

| 错误码                                                                                        | 触发条件                              |
| ------------------------------------------------------------------------------------------ | --------------------------------- |
| `DOC_TYPE`                                                                                 | 策略文档不是对象                          |
| `SCHEMA_INVALID`                                                                           | `schemaVersion` 不匹配 `^[12]\.\d+$` |
| `RULES_TYPE`                                                                               | `rules` 不是数组                      |
| `RULES_TOO_MANY`                                                                           | 规则数 > 500                         |
| `ID_DUPLICATE`                                                                             | 规则 `id` 重复                        |
| `RULE_TYPE` / `RULE_NO_ID`                                                                 | 规则非对象 / 缺 `id`                    |
| `STAGE_INVALID`                                                                            | `stage` 不是 `line`/`order`         |
| `PRIORITY_RANGE`                                                                           | `priority` 不在 `[0, 10000]`        |
| `ENABLED_TYPE`                                                                             | `enabled` 非布尔                     |
| `SELECT_GROUP_TYPE` / `SELECT_MODE_INVALID` / `SELECT_WITHOUT_GROUP`                       | 见第 9.5 节                          |
| `WHEN_DEPTH`                                                                               | `when` 嵌套 > 5 层                   |
| `COMBINATOR_TYPE`                                                                          | 组合子类型错（`all`/`any` 非数组、`not` 非对象） |
| `FIELD_UNKNOWN`                                                                            | 条件字段不在 18 个闭集内                    |
| `LIST_TYPE` / `RANGE_TYPE` / `TIME_TYPE`                                                   | 值形态与字段类型不符                        |
| `LIST_EMPTY`(warn) / `RANGE_EMPTY` / `RANGE_INVALID` / `RANGE_MIN_TYPE` / `RANGE_MAX_TYPE` | 见 4.6 节                           |
| `TIME_SEG` / `TIME_FMT`                                                                    | 时间区间结构/格式错                        |
| `DAY_INVALID`                                                                              | `days` 值非法                        |
| `MEMBER_LEVEL_INVALID`                                                                     | `memberLevel` 元素非字符串              |
| `THEN_MISSING` / `THEN_EMPTY` / `ACTION_TYPE`                                              | `then` 缺失/空/非对象                   |
| `ACTION_UNKNOWN`                                                                           | 动作类型不在 8 个闭集内                     |
| `STAGE_ACTION_MISMATCH`                                                                    | `stage` 与动作不匹配                    |
| `RATE_RANGE`                                                                               | `rate` 不在 `(0,1]`                 |
| `PRICE_INVALID` / `AMOUNT_INVALID`                                                         | 价格/金额非法                           |
| `ALLOCATE_INVALID`                                                                         | `allocate` 非法                     |
| `GIFT_NO_DISH` / `GIFT_QTY`                                                                | 赠品缺菜品 / `qty` 非正数                 |
| `MAXQTY_INVALID`                                                                           | `maxQty` 非正数                      |
| `MEMBERPRICE_INVALID`                                                                      | `memberPrice` 未恰选一个字段             |
| `BESTOF_OPTIONS_TYPE` / `BESTOF_EMPTY`                                                     | `bestOf.options` 类型/空             |
| `JSON_SYNTAX`                                                                              | 对象无法序列化                           |
| `MINRATE_RANGE`                                                                            | `minRate` 不在 `[0,1]`              |


### 11.2 告警（warnings）——不阻断但要看

| 告警码                         | 含义                                   |
| --------------------------- | ------------------------------------ |
| `NO_SCHEMA`                 | 缺 `schemaVersion`，按 2.0 处理           |
| `RULES_EMPTY`               | 规则列表为空                               |
| `RULE_NO_LABEL`             | 规则缺 `label`（影响回译可读性）                 |
| `GROUP_STAGE_MIX`           | **同 `group` 名下有不同 `stage` 的规则**，建议分组 |
| `ORDER_STAGE_LINE_FIELD`    | order 规则用了行级字段                       |
| `COMBINATOR_EMPTY`          | `all`/`any` 为空数组                     |
| `TIME_EMPTY` / `TIME_ORDER` | 时间空 / 跨夜起点晚于终点                       |
| `LIST_EMPTY`                | 列表字段空数组                              |
| `THEN_WRAPPED`              | 用了具名包装写法                             |
| `MULTI_PRICE_ACTION`        | 行级规则有多价格型动作，将顺序叠加                    |
| `BESTOF_SINGLE`             | `bestOf` 只有一个选项                      |

### 11.3 特别关注：`GROUP_STAGE_MIX`

同名的 `group` 里混了 `line` 和 `order` 两种 stage，是非常常见的语义事故。虽然只告警，但几乎总是设计错误——同组互斥的前提是它们「竞品关系」，跨 stage 的规则根本不在一起比较。**生成器应主动避免。**

---

## 第 12 章 引擎返回体

### 12.1 行级 `resolveLine(ctx, sel?)`

实测返回体的顶层键（`Object.keys`）：

```js
{
  context: { ... },            // 归一化后的判定上下文（含 dish / lineQty / date 等）
  basePrice: 48,               // ⚠️ 行「单价」，不是 单价×数量
  linePrice: 48,               // 行级定价后的价格（未钳制前）
  finalPrice: 48,              // 行最终价（钳制后）
  clamped: false,              // 是否被 minRate 钳制
  clampedBy: null,             // 被哪一级 minRate 钳制（dish / options / global）
  beforeClamp: 48,             // 钳制前的价格
  floorPrice: null,            // 钳制下限（原价 × minRate）
  chain: [ ... ],              // 逐步叠加轨迹
  applied: [ ... ],            // 实际生效的动作记录数组（对象，不是 id 字符串）
  evaluated: [ ... ],          // 所有被评估过的规则及命中情况
  candidatesCount: 7,          // 候选规则数
  selectGroups: { ... },       // 候选组（见第 9.6 节）
  pendingSelectGroups: []      // 恒为空数组（v2.2.1）
}
```

> ⚠️ **`basePrice` 是单价**。行数量 `lineQty` 只作为**条件**参与判定，不参与价格乘法。要算行总额需自己 `finalPrice × lineQty`。

### 12.2 `applied` 的真实结构

`applied` 是**对象数组**，不是规则 id 数组：

```js
applied: [
  {
    rule: { id: "r_qty_3_off_5", label: "满3件减5元", group: "g_qty",
            stage: "line", priority: 40, when: {...}, then: {...} },
    kind: "discountAmount",
    price: 43,
    delta: -5,
    finalFlag: false,
    meta: { amount: 5, basedOn: "currentPrice" },
    conditionResult: { pass: true, details: [ ... ] }
  }
]
```

| 键                 | 说明                                        |
| ----------------- | ----------------------------------------- |
| `rule`            | 完整规则对象（含 `id` / `label` / `priority` 等）   |
| `kind`            | 生效的动作类型                                   |
| `price`           | 该动作**施加后**的价格                             |
| `delta`           | 相对上一级的变化额                                 |
| `finalFlag`       | 是否为终态动作（`fixedPrice` / `bestOf` → `true`） |
| `meta`            | 动作的参数与内部记录（如 `amount`、`limitApplied`）     |
| `conditionResult` | 条件判定明细                                    |

**要取规则 id，用 `applied[i].rule.id`。**

### 12.3 整单级 `resolveOrder({ orderInfo, lines })`

```js
{
  lines: [ { ..., 含 finalPrice / allocated } ],
  orderTotal: 88.8,
  orderReduce: { total: 0, allocations: [...], strategy: "byLineAmount" },
  gifts: [ { dishUid: "dish_801", qty: 1 } ],
  chain: [ ... ],
  finalPrice: 88.8
}
```

### 12.4 关键字段的读法

| 想知道什么        | 看哪个字段                                  |
| ------------ | -------------------------------------- |
| 这一行最后多少钱     | `finalPrice`                           |
| 被钳制了吗        | `clamped` / `clampedBy` / `floorPrice` |
| 哪条规则真的改价了    | `applied[].rule.id`（**候选规则不在里面**）      |
| 有哪些活动可选      | `selectGroups[sg].candidates`          |
| 为什么价格是这样     | `chain`                                |
| 哪些规则被评估了但没命中 | `evaluated`                            |

> **`applied` 是判断「规则是否生效」的唯一权威字段。** 候选组规则虽然出现在 `selectGroups` 里，但**不会**出现在 `applied` 里。

---

## 第 13 章 用例（cases）写法

用例文件与策略文件配套，用于验证策略行为。结构：

```json
{
  "schemaVersion": "2.0",
  "storeId": "demo_store",
  "name": "用例集",
  "description": "说明",
  "cases": [ /* 用例数组 */ ]
}
```

### 13.1 用例字段

| 字段                  | 说明                               |
| ------------------- | -------------------------------- |
| `id`                | 用例标识                             |
| `name`              | 用例名                              |
| `scenario`          | 验证意图                             |
| `group`             | 用例分组（仅用于界面归类）                    |
| `kind`              | **`line`**（行级）或 **`order`**（整单级） |
| `expect`            | 期望结果的文字描述                        |
| `expectPrice`       | 期望行价格（`kind: "line"` 用）          |
| `expectRuleIds`     | 期望生效的规则 id 列表                    |
| `expectOrderReduce` | 期望整单立减额（`kind: "order"` 用）       |
| `expectAllocate`    | 期望摊分策略（`kind: "order"` 用）        |
| `expectDetail`      | 补充说明                             |
| `input`             | 输入数据，形态随 `kind` 变化               |

### 13.2 行级用例的 `input`

```json
"input": {
  "dish": {
    "uid": "dish_204",
    "name": "虾饺皇",
    "categoryUid": "cat_dim_sum",
    "basePrice": 42
  },
  "lineQty": 1,
  "context": {
    "date": "2025-06-09",
    "time": "12:30",
    "dateTags": ["workday"],
    "memberLevel": "normal",
    "memberTags": []
  }
}
```

| 键         | 说明                                                              |
| --------- | --------------------------------------------------------------- |
| `dish`    | 菜品信息（`uid` / `name` / `categoryUid` / `basePrice` / 可选 `tags`）  |
| `lineQty` | 该行数量 ← 对应条件字段 `lineQty`                                         |
| `context` | 上下文：`date` / `time` / `dateTags` / `memberLevel` / `memberTags` |

### 13.3 整单用例的 `input`

```json
"input": {
  "orderInfo": {
    "date": "2025-06-11",
    "time": "18:30",
    "dateTags": ["workday"],
    "memberLevel": "normal"
  },
  "lines": [
    { "uid": "dish_002", "name": "宫保鸡丁", "categoryUid": "cat_hot", "basePrice": 48, "lineQty": 3 },
    { "uid": "dish_101", "name": "凉拌黄瓜", "categoryUid": "cat_cold", "basePrice": 28, "lineQty": 2 }
  ]
}
```

整单用例里 `lines` 的每一项，键名用 `uid`（不是 `dish.uid`），注意与行级用例的区别。

### 13.4 关于 `useGlobalMinRate`

演示程序 `app.js` 的 `buildEngine()` 调用 `fromDoc(doc, catalog, {})`，**不带** `useGlobalMinRate`。因此演示场景里 `global.minRate` 不生效，期望价格是按「不应用全局 minRate」算出来的。若你的期望值对不上，先检查这一项。

---

## 第 14 章 完整可运行示例

下面这份策略覆盖了 8 类典型场景，可直接保存为 JSON 跑通。

```json
{
  "schemaVersion": "2.0",
  "storeId": "tutorial_store",
  "storeName": "教程演示店",
  "name": "教程完整示例",
  "description": "覆盖时段折扣 / 分类折扣 / 会员价 / 数量优惠 / 固定价 / 减额 / 组合条件 / 整单满减 / 赠品 / 候选组",
  "generatedAt": "2026-01-01T00:00:00+08:00",
  "global": { "minRate": 0.5 },
  "rules": [
    {
      "id": "r_lunch_dim_sum_90",
      "label": "午市点心9折",
      "desc": "11:00-14:00 点心类 9 折",
      "stage": "line",
      "group": "g_time_price",
      "priority": 80,
      "enabled": true,
      "when": {
        "all": [
          { "openTime": [["11:00", "14:00"]] },
          { "categories": ["cat_dim_sum"] }
        ]
      },
      "then": { "type": "discountRate", "rate": 0.9 }
    },
    {
      "id": "r_lunch_special_168",
      "label": "午市5款特价16.8",
      "desc": "与上条同组，priority 更高 → 组内获胜",
      "stage": "line",
      "group": "g_time_price",
      "priority": 120,
      "enabled": true,
      "when": {
        "all": [
          { "openTime": [["11:00", "14:00"]] },
          { "dishUids": ["dish_202"] }
        ]
      },
      "then": { "type": "fixedPrice", "price": 16.8 }
    },
    {
      "id": "r_member_gold_95",
      "label": "黄金会员95折",
      "desc": "跨组链式叠加：在时段价基础上再打 95 折",
      "stage": "line",
      "group": "g_member",
      "priority": 60,
      "enabled": true,
      "when": { "memberLevel": ["gold", "diamond", "platinum"] },
      "then": { "type": "memberPrice", "rate": 0.95 }
    },
    {
      "id": "r_qty_3_off_5",
      "label": "满3件减5元",
      "stage": "line",
      "group": "g_qty",
      "priority": 40,
      "enabled": true,
      "when": { "lineQty": { "min": 3 } },
      "then": { "type": "discountAmount", "amount": 5 }
    },
    {
      "id": "r_weekend_hot_85",
      "label": "周末热菜85折",
      "desc": "展示 days + categories + not 的组合；注意 not 必须嵌在 all 数组内",
      "stage": "line",
      "group": "g_weekend",
      "priority": 70,
      "enabled": true,
      "when": {
        "all": [
          { "days": ["sat", "sun"] },
          { "categories": ["cat_hot"] },
          { "not": { "tags": ["特价菜"] } }
        ]
      },
      "then": { "type": "discountRate", "rate": 0.85 }
    },
    {
      "id": "r_limit_half_1",
      "label": "乳鸽半价限1份",
      "desc": "展示 maxQty：半价但每单限 1 份",
      "stage": "line",
      "group": "g_addon",
      "priority": 90,
      "enabled": true,
      "when": {
        "all": [
          { "dishUids": ["dish_702"] },
          { "orderAmount": { "min": 200 } },
          { "guestCount": { "min": 4 } }
        ]
      },
      "then": [
        { "type": "discountRate", "rate": 0.5 },
        { "type": "maxQty", "maxQty": 1 }
      ]
    },
    {
      "id": "r_bestof_dim_sum",
      "label": "点心取最优",
      "desc": "三个方案里自动取价格最低的",
      "stage": "line",
      "priority": 85,
      "enabled": true,
      "when": {
        "all": [
          { "openTime": [["11:00", "14:00"]] },
          { "dishUids": ["dish_204"] }
        ]
      },
      "then": {
        "type": "bestOf",
        "options": [
          { "type": "discountRate", "rate": 0.85 },
          { "type": "discountAmount", "amount": 8 },
          { "type": "fixedPrice", "price": 16.8 }
        ]
      }
    },
    {
      "id": "r_sg_dessert_a",
      "label": "甜品活动A（8折）",
      "desc": "manual 候选组：只登记候选，不改价",
      "stage": "line",
      "selectGroup": "sg_dessert",
      "select": "manual",
      "priority": 100,
      "enabled": true,
      "when": { "categories": ["cat_dessert"] },
      "then": { "type": "discountRate", "rate": 0.8 }
    },
    {
      "id": "r_sg_dessert_b",
      "label": "甜品活动B（减6元）",
      "stage": "line",
      "selectGroup": "sg_dessert",
      "select": "manual",
      "priority": 90,
      "enabled": true,
      "when": { "categories": ["cat_dessert"] },
      "then": { "type": "discountAmount", "amount": 6 }
    },
    {
      "id": "r_order_full_300_minus_30",
      "label": "整单满300减30",
      "stage": "order",
      "group": "g_order_reduce",
      "priority": 100,
      "enabled": true,
      "when": { "orderAmount": { "min": 300 } },
      "then": { "type": "orderReduce", "amount": 30, "allocate": "byLineAmount" }
    },
    {
      "id": "r_order_gift_soup",
      "label": "满4人赠例汤",
      "stage": "order",
      "group": "g_order_gift",
      "priority": 80,
      "enabled": true,
      "when": { "guestCount": { "min": 4 } },
      "then": { "type": "gift", "dishUid": "dish_901", "qty": 1 }
    }
  ]
}
```


### 14.1 走查这份策略（行级）

**场景：2025-06-08（周日）12:30，黄金会员，点 3 份辣子鸡（热菜，¥48/份）**

先记住一个关键事实：**`basePrice` 是「单价」而不是「行总额」**。数量 3 通过 `lineQty` 字段参与**条件判定**，但**不参与价格乘法**。所以本行的起算价是 `48`，不是 `144`。

1. **命中检测**（条件基于原始输入价，与后续叠加无关）：
   - `r_weekend_hot_85` → 命中（周日 + `cat_hot` + 无「特价菜」tag），归入 `g_weekend`，成为该组冠军
   - `r_member_gold_95` → 命中（`gold` 在 `["gold","diamond","platinum"]` 内），归入 `g_member`，冠军
   - `r_qty_3_off_5` → 命中（`lineQty: {min:3}`，数量 3 满足），归入 `g_qty`，冠军
   - `r_lunch_dim_sum_90` → 不命中（分类不是 `cat_dim_sum`）
   - `r_limit_half_1` → 不命中（不是 `dish_702`；且行级上下文没有整单字段）
   - `r_bestof_dim_sum` → 不命中（不是 `dish_204`）
   - `r_sg_dessert_a/b` → 不命中（不是甜品）；即使命中，它们只登记候选、不改价
2. **跨组链式叠加**（按 `priority` 降序，逐级改写 `currentPrice`）：
   | 步 | 规则                 | priority | 动作                      | 计算             | 价格      |
   | - | ------------------ | -------- | ----------------------- | -------------- | ------- |
   | 1 | `r_weekend_hot_85` | 70       | `discountRate 0.85`     | `48 × 0.85`    | `40.80` |
   | 2 | `r_member_gold_95` | 60       | `memberPrice rate 0.95` | `40.80 × 0.95` | `38.76` |
   | 3 | `r_qty_3_off_5`    | 40       | `discountAmount 5`      | `38.76 − 5`    | `33.76` |
3. **P1.5 钳制**：底线 `48 × 0.5 = 24`；`33.76 > 24`，不触发，`clamped = false`
4. **整单级**：`resolveLine` 只看行级规则，整单规则不在此处生效（见 13.2）

**实测结果**：

```
basePrice(单价) = 48    finalPrice = 33.76    clamped = false
applied = ["r_weekend_hot_85@40.8", "r_member_gold_95@45.6", "r_qty_3_off_5@43"]
```

> **两个容易看错的细节：**
>
> ① `applied[i].price` 是该条规则**动作执行后**的价格（如 `r_member_gold_95` 的 `price=45.6` = `48 × 0.95`），而 `delta` 才是相对的减额（`-2.4`）。上表第 1 步用的 `40.80` 是 `r_weekend_hot_85` 执行后的价，所以 `applied[0].price = 40.8` —— 两者一致，只是视角不同：`price` 是规则自己的动作价，`finalPrice` 是整条链的结果。
>
> ② 第 3 条 `r_qty_3_off_5` 是**减额类**动作，`price = 43` 表示「若只应用这一条，结果是 43」。它和 `discountRate` 类叠加时**不是相乘而是相加**，这正是 priority 顺序会真正影响最终价格的地方 —— 如果 `g_qty` 的 priority 排到 `g_weekend` 前面，就会先 `48 − 5 = 43`、再 `× 0.85 = 36.55`、再 `× 0.95 = 34.72`，与 `33.76` 不同。**这就是 priority 设计的要害：乘法可交换，加减法不可交换。**

### 14.2 走查这份策略（整单级）

**场景：2025-06-08（周日）12:30，黄金会员，5 人，辣子鸡 ¥48×5 份 + 虾饺皇 ¥42×2 份，整单原价 ¥324**

用 `resolveOrder` 求值（行级 + 整单级一起算）。下面**两种传法的结果都列出**，因为它们的差异正是 13.2 要讲的那个缺陷：

**传法 A：把日期/会员等平铺到顶层（正确，能拿到全部行级优惠）**

```
originalAmount    = 324.00     ← 整单原价
afterLineAmount   = 168.80     ← 行级规则全部应用后的小计
totalReduce       = 0          ← 整单级「减额」合计（orderReduce）
finalAmount       = 168.80     ← 最终应付

line[1] 辣子鸡  basePrice=48  finalPrice=33.76  ← 三条行级规则全命中
        applied = ["r_weekend_hot_85","r_member_gold_95","r_qty_3_off_5"]
line[2] 虾饺皇  basePrice=42  finalPrice=42     ← 无命中
orderApplied = ["r_order_gift_soup"]   ← 整单级 5 人 → 赠例汤
```

**传法 B：只把上下文塞进 `orderInfo`（当前实现的行为，行级优惠大量丢失）**

```
originalAmount    = 324.00
afterLineAmount   = 215.00     ← 只应用了「满3件减5元」
totalReduce       = 0
finalAmount       = 215.00

line[1] 辣子鸡  basePrice=48  finalPrice=43   ← 只命中 r_qty_3_off_5
line[2] 虾饺皇  basePrice=42  finalPrice=42
orderApplied = ["r_order_gift_soup"]
```

**为什么辣子鸡这次没吃上「周末85折」和「会员95折」？**

因为 **`resolveOrder` 目前只把 `orderInfo` 内部的字段当作整单级上下文，并没有把它们透传到每一行的行级求值上下文里**。看 `engine.js` 第 1967-1971 行：

```js
var lineResults = lines.map(function (l) {
  var merged = self._mergeCtx(l, orderCtx);   // ← 只合并了 orderCtx 的顶层键
  delete merged.lines;
  delete merged.orderInfo;                    // ← orderInfo 被整个删掉了
  merged.lineQty = ...;
```

`_mergeCtx` 只做一层浅拷贝：`orderCtx` 顶层的 `lines` / `orderInfo` 被搬进 `merged`，然后 `lines`、`orderInfo` 又被 `delete`。于是 `orderInfo: { date, time, dateTags, memberLevel }` 里的**日期、时段、日期标签、会员等级全部丢失**，`merged` 的顶层只剩行自己的字段：

```
merged keys = ["uid","name","categoryUid","categories","basePrice","lineQty","tags"]
merged.date = undefined    merged.memberLevel = undefined    merged.dateTags = undefined
```

结果就是：**依赖日期/时段/会员等级的行级规则在这条路径上全部判不中**。

- `r_weekend_hot_85` 需要 `days`（来自 `date`）→ `dayIndex=null` → 不命中
- `r_member_gold_95` 需要 `memberLevel` → `undefined` → 不命中
- `r_qty_3_off_5` 只需要 `lineQty`（行自带）→ **照常命中**

所以整单场景里辣子鸡只吃到「满3件减5元」：`48 − 5 = 43`。

**这是当前实现的一个真实缺陷，会造成金额算错。** 同一份订单、同一份策略，两种传法结果差 ¥46.20：

| 传法                        | 行级命中                | 行价      | 行小计      |
| ------------------------- | ------------------- | ------- | -------- |
| `orderInfo` **平铺到顶层**（正确） | 3 条全命中              | `33.76` | `168.80` |
| `orderInfo` **嵌套**（当前实现）  | 只命中 `r_qty_3_off_5` | `43`    | `215.00` |

`215 − 168.80 = 46.20` —— **嵌套传法会让顾客多付 ¥46.20。**

**为什么既有回归测试没发现？** 因为现有整单用例的 `orderInfo.memberLevel` 全是 `"normal"`，会员规则本来就不该命中，日期/时段类规则又恰好没被这些用例覆盖到，缺陷被掩盖了。这也提醒我们：**回归用例必须覆盖「依赖会员/日期/时段的规则 × 整单场景」这个交叉组合。**

> **给使用者的建议：** 在缺陷修复前，调用 `resolveOrder` 时把日期/时段/会员等上下文字段**平铺到顶层**，不要只塞进 `orderInfo`，例如：
>
> ```js
> engine.resolveOrder({
>   date: '2025-06-08', time: '12:30', dateTags: ['weekend'],
>   memberLevel: 'gold', guestCount: 5,          // ← 平铺，别嵌套
>   orderInfo: { date: '2025-06-08', memberLevel: 'gold', guestCount: 5 },  // 保留一份给整单级规则
>   lines: [ ... ]
> })
> ```
>
> 正确修法是在 `engine.js` 第 1968 行附近，把 `orderCtx.orderInfo` 的内容也一起并入 `merged`：
>
> ```js
> var merged = self._mergeCtx(l, orderCtx);
> if (orderCtx.orderInfo && typeof orderCtx.orderInfo === 'object') {
>   for (var k in orderCtx.orderInfo) {
>     if (Object.prototype.hasOwnProperty.call(orderCtx.orderInfo, k)) merged[k] = orderCtx.orderInfo[k];
>   }
> }
> delete merged.lines;
> delete merged.orderInfo;
> ```
>
> （修复后需重跑全场景回归，并补充上表那类交叉用例。）

> **注意 `r_order_full_300_minus_30` 为什么没命中？**
>
> 这里要区分两种传法：
>
> - **传法 A（平铺，行级优惠全命中）**：`afterLineAmount = 168.80`，远低于 300 → 满减不命中。
> - **传法 B（嵌套，行级只命中满3件减5元）**：`afterLineAmount = 215.00`，同样低于 300 → 满减也不命中。
>
> 两种传法下满减都没触发，但**原因不同**：传法 A 是因为行级确实把 324 优惠到了 168.80；传法 B 是因为行级优惠丢了、只降到 215.00，看起来「省得少」反而离 300 更近。
>
> 关键结论：**整单级条件里的 `orderAmount` 判定的是「行级优惠已经应用之后」的金额**（即 `afterLineAmount`），不是 `originalAmount`。源码见 `engine.js` 第 2003-2006 行 —— `_buildOrderCtx(orderCtx, lineResults, { originalAmount, afterLineAmount })`，而 `orderAmount` 取的是 `afterLineAmount`。
>
> **这条语义对写策略影响很大**：「满 300 减 30」在行级折扣已经把金额打到 300 以下的单子上**永远不会触发**。设计这类「折后满减」时务必拿真实用例回归一次。
>
> 另外，`r_order_gift_soup` 的 `guestCount` 是从 `orderInfo` 读的 —— 整单级求值走的是 `_buildOrderCtx`，会正确读到 `orderInfo` 里的字段，所以**整单级规则不受 13.2 那个缺陷影响**，赠品正常命中。

---

## 第 15 章 给 AI 的生成要点

### 15.1 生成前必须拿到的信息

要让 AI 生成正确策略，至少提供：

| 信息               | 为什么需要              | 缺失后果              |
| ---------------- | ------------------ | ----------------- |
| **菜品/分类 UID 清单** | DSL 用 UID 不用中文名    | AI 会编造 UID，规则永不命中 |
| **业务规则的中文描述**    | 转成 `when` + `then` | —                 |
| **各活动的互斥关系**     | 决定 `group` 怎么分     | 该互斥的不互斥，会重复打折     |
| **各活动的优先次序**     | 决定 `priority`      | 叠加次序错，价格算错        |
| **折扣底线（如有）**     | 决定是否配 `minRate`    | 可能出现折上加折到 1 折     |

### 15.2 生成时的固定动作

```
1. 先读第 5 章 18 个条件字段闭集、第 7 章 8 个动作闭集
   —— 只能用这些名字，不得自创
2. 中文名 → UID 的映射必须来自给定的清单，不得推断
3. 折扣率一律转成小数：八折 → 0.8，九折 → 0.9
4. 互斥的活动放同一 group；同组必须 priority 不同
5. 不互斥的活动放不同 group，用 priority 表达叠加次序
6. 只登记不定价的活动 → selectGroup + select: "manual"
7. 输出后自检（见 14.4）
```

### 15.3 中文业务语义 → DSL 的映射表

| 业务描述          | DSL 写法                                                                   |
| ------------- | ------------------------------------------------------------------------ |
| 午市 11 点到 14 点 | `"openTime": [["11:00","14:00"]]`                                        |
| 周末            | `"days": ["sat","sun"]`（或 `[[6,7]]`）                                     |
| 点心类           | `"categories": ["cat_dim_sum"]`                                          |
| 这个菜           | `"dishUids": ["dish_204"]`                                               |
| 满 2 件         | `"lineQty": { "min": 2 }`                                                |
| 整单满 200       | `"orderAmount": { "min": 200 }`                                          |
| 4 人以上         | `"guestCount": { "min": 4 }`                                             |
| 黄金及以上会员       | `"memberLevel": ["gold","diamond","platinum"]`                           |
| 不带特价标签        | `"not": { "tags": ["特价菜"] }`                                             |
| 打 8 折         | `{ "type":"discountRate", "rate":0.8 }`                                  |
| 减 5 元         | `{ "type":"discountAmount", "amount":5 }`                                |
| 一口价 16.8      | `{ "type":"fixedPrice", "price":16.8 }`                                  |
| 半价但限 1 份      | `[{ "type":"discountRate","rate":0.5 }, { "type":"maxQty","maxQty":1 }]` |
| 整单减 30        | `{ "type":"orderReduce", "amount":30 }`（`stage: "order"`）                |
| 送一份例汤         | `{ "type":"gift", "dishUid":"dish_901" }`（`stage: "order"`）              |
| 三个活动里最便宜的     | `{ "type":"bestOf", "options":[ ... ] }`                                 |

### 15.4 生成后自检清单

AI 输出策略后，逐条过一遍：

- [ ] 每个 `when` 里的键都在 18 个字段内？**没有单数形式**（`dishUid`/`category`）？
- [ ] 每个 `then.type` 都在 8 个动作内？
- [ ] 所有 `rate` 都在 `(0, 1]`？**没有把 0.8 写成 8 或 80**？
- [ ] `fixedPrice` / `orderReduce` / `discountAmount` / `gift` / `maxQty` 的 `stage` 对不对？（整单动作必须 `stage: "order"`）
- [ ] 同一 `group` 内的 `priority` **两两不同**？
- [ ] 同一 `group` 内的 `stage` **一致**？（避免 `GROUP_STAGE_MIX`）
- [ ] `select` 有没有单独出现（必须配 `selectGroup`）？
- [ ] 列表字段是数组、范围字段是 `{min,max}` 对象、时间字段是 `[[起,止]]`？
- [ ] 所有 UID 都来自给定清单？
- [ ] `when` 嵌套没超过 5 层？

### 15.5 推荐的提示词骨架

```text
你是价格策略 JSON DSL 生成器。请把下面的中文业务规则转成 JSON DSL（格式见下）。

【硬约束】
- 条件字段只能是这 18 个：days, time, dates, dateTags, dishUids, categories,
  tags, hasDish, lineQty, priceRange, orderAmount, orderQty, guestCount,
  memberLevel, memberTags, orderTime, openTime, closeTime
- 动作类型只能是这 8 个：discountRate, discountAmount, fixedPrice, bestOf,
  maxQty, memberPrice, orderReduce, gift
- 折扣率一律用小数（八折 = 0.8）
- 列表字段写数组，范围字段写 {min,max}，时间字段写 [["HH:mm","HH:mm"]]
- lineQty/dishUids/categories/tags/hasDish/priceRange 只能用于 stage="line"
- orderReduce/gift 只能用于 stage="order"
- 互斥的活动放同一个 group，priority 必须两两不同
- 只登记候选、不参与定价的活动：加 selectGroup 与 select:"manual"

【可用的菜品与分类 UID】
（在此粘贴清单）

【业务规则】
1. ...
2. ...

【输出】
只输出 JSON，不要解释。
```

### 15.6 关于「中文名 → UID」

这是 AI 生成最容易出错的地方。DSL 全程使用 UID，AI **无法凭空知道** `点心类` 对应的是 `cat_dim_sum` 还是 `cat_1001`。

两种应对：

1. **AI 只出骨架**：生成时中文名占位（如 `"categories": ["<点心类>"]`），由程序侧做名称解析后再替换。
2. **先给词典**：把 `dish-catalog.json` / `dao-xiang-dishes.json` 的映射直接放进提示词。

项目里的 NL 生成链路（`GenJsonDSL/`）走的是第 2 种——它在 `parser-lexicon.json` 里维护词表，由 `parser.js` 做解析，`composer.js` 做组装，`validator.js` 做校验，形成「自然语言 → DSL」的完整闭环。


## 附录 A 全部闭集速查

**18 个条件字段**  
`days` `time` `dates` `dateTags` `dishUids` `categories` `tags` `hasDish` `lineQty` `priceRange` `orderAmount` `orderQty` `guestCount` `memberLevel` `memberTags` `orderTime` `openTime` `closeTime`

**8 个动作类型**  
`discountRate` `discountAmount` `fixedPrice` `bestOf` `maxQty` `memberPrice` `orderReduce` `gift`

**3 个组合子**：`all` `any` `not`

**2 个选择模式**：`manual` `priority`

**4 个摊分策略**：`byLineAmount` `byQty` `toCheapest` `none`

**动作数值字段**：`discountRate.rate` `fixedPrice.price` `discountAmount.amount` `orderReduce.amount` `gift.qty` `maxQty.maxQty` `memberPrice.price|rate|amount`

**时间字段**：`time` `orderTime` `openTime` `closeTime`

**范围字段**：`lineQty` `orderQty` `orderAmount` `guestCount` `priceRange`

---

## 附录 B 与实现对应的源码位置

| 内容                 | 位置                                                                 |
| ------------------ | ------------------------------------------------------------------ |
| 条件字段 / 动作闭集 / 选择模式 | `OutputGen/js/engine.js` L31-84                                    |
| 动作实现               | `OutputGen/js/engine.js` L621-722                                  |
| 规则编译（P0）           | `OutputGen/js/engine.js` L733+                                     |
| 行级求解（P1）           | `OutputGen/js/engine.js` `resolveLine` L1270+                      |
| 候选组归集与构造           | `OutputGen/js/engine.js` L1318-1523                                |
| 整单求解（P2/P3）        | `OutputGen/js/engine.js` `resolveOrder` L1660+/2050+               |
| 校验器主流程             | `OutputGen/js/validator.js` L540-700                               |
| 动作校验               | `OutputGen/js/validator.js` `validateThen` L324+                   |
| 回译器                | `OutputGen/js/translator.js`                                       |
| v1 原始规格            | `设计/PricePolicyDSL.md`                                             |
| 字段与场景全集            | `设计/PricePolicy-字段与场景大全.md`                                        |
| 演示程序说明             | `OutputGen/README.md`                                              |
| NL 生成链路            | `GenJsonDSL/`（`parser.js` / `composer.js` / `parser-lexicon.json`） |

**修改 `data/*.json` 后须重新生成内嵌副本**：`node build-embed.js`（否则 `file://` 打开时读到的是旧数据）。

---

## 附录 C v1 与 v2 差异对照

| 维度              | v1      | v2（当前）                                                |
| --------------- | ------- | ----------------------------------------------------- |
| `schemaVersion` | `1`（数字） | `"2.0"`（字符串，校验器接受 `1.x`/`2.x`）                        |
| 条件字段            | 7 个     | **18 个**                                              |
| 动作类型            | 3 个     | **8 个**                                               |
| 阶段              | 仅行级     | 四阶段 + 钳制                                              |
| 数量/整单维度         | 无       | `lineQty` / `orderQty` / `orderAmount` / `guestCount` |
| 会员维度            | 无       | `memberLevel` / `memberTags`                          |
| 候选组             | 无       | `selectGroup` / `select`                              |
| `minRate`       | 未定义     | 三级解析                                                  |

> v1 策略仍可被 v2 引擎直接加载（`isV2 = !!caseObj.kind` 分流），属向后兼容。

---

**文档结束。** 有疑问或发现与代码不符之处，以 `OutputGen/js/engine.js` 与 `validator.js` 的常量为准。
