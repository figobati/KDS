# PricePolicy JSON DSL —— 字段大全与场景案例

> 配套文档：[PricePolicy.md](PricePolicy.md)（需求与论证）、[PricePolicyDSL.md](PricePolicyDSL.md)（v1 规格）
> 本文定位：**字段速查 + 案例驱动的语法手册 + 适用场景地图**。
> 目标：通过实际场景覆盖每一个字段、每一种语法结构，讲清楚这套 JSON DSL 能做什么、适合什么、边界在哪。

---

## 一、字段全景图

### 1.1 分层结构

```
策略文档（PolicyDocument）                         ← 一店一份，版本化
├─ schemaVersion    int       契约版本
├─ storeId          int       门店作用域
├─ revision         int       版本号（缓存 key）
├─ validFrom        date?     整包生效起始
├─ validTo          date?     整包生效截止
└─ rules            Rule[]    规则列表
     ├─ id          string    规则唯一标识
     ├─ label       string    中文短名（≤30字）
     ├─ enabled     bool      开关（默认 true）
     ├─ group       string    互斥组（同组取优先级最高）
     ├─ priority    int       优先级（0..9999，大的优先）
     ├─ when        Cond      条件树
     │   ├─ all     Cond[]    全部命中（AND）
     │   ├─ any     Cond[]    任一命中（OR）
     │   ├─ not     Cond      取反（NOT）
     │   ├─ days            星期（mon..sun）
     │   ├─ time            时段（支持跨午夜）
     │   ├─ dates           固定日期
     │   ├─ dateTags        节假日标签
     │   ├─ dishUids        商品 UID 列表
     │   ├─ categories      分类 UID 列表
     │   └─ tags            商品标签列表
     └─ then        Action    动作
         ├─ type = discountRate   rate ∈ [0,1]
         ├─ type = fixedPrice     price ≥ 0
         └─ type = discountAmount amount ≥ 0
```

### 1.2 字段统计表

| 层级 | 字段 | 类型 | 必填 | 缺省 | 闭集 | 所在章节 |
|---|---|---|---|---|---|---|
| 文档 | `schemaVersion` | int | ✅ | - | ✅（当前恒 1） | §2 |
| 文档 | `storeId` | int | ✅ | - | - | §2 |
| 文档 | `revision` | int | ➖ | 存储层生成 | - | §2 |
| 文档 | `validFrom` | date\|null | ➖ | null | - | §2 |
| 文档 | `validTo` | date\|null | ➖ | null | - | §2 |
| 文档 | `rules` | Rule[] | ✅ | - | - | §2 |
| 规则 | `id` | string | ✅ | - | 正则约束 | §3 |
| 规则 | `label` | string | ✅ | - | ≤30字 | §3 |
| 规则 | `enabled` | bool | ➖ | true | - | §3 |
| 规则 | `group` | string | ✅ | - | kebab-case | §3 |
| 规则 | `priority` | int | ✅ | - | 0..9999 | §3 |
| 规则 | `when` | Condition | ✅ | `{}` = 恒真 | - | §4 |
| 规则 | `then` | Action | ✅ | - | ✅ 3 型 | §5 |
| 条件 | `all` | Condition[] | ➖ | - | - | §4.1 |
| 条件 | `any` | Condition[] | ➖ | - | - | §4.1 |
| 条件 | `not` | Condition | ➖ | - | - | §4.1 |
| 条件 | `days` | 集合 | ➖ | - | ✅ mon..sun | §4.3 |
| 条件 | `time` | 段数组 | ➖ | - | HH:mm | §4.3 |
| 条件 | `dates` | 集合 | ➖ | - | YYYY-MM-DD | §4.3 |
| 条件 | `dateTags` | 集合 | ➖ | - | ✅ 节假日标签 | §4.3 |
| 条件 | `dishUids` | 集合 | ➖ | - | 32位hex | §4.3 |
| 条件 | `categories` | 集合 | ➖ | - | 分类 UID | §4.3 |
| 条件 | `tags` | 集合 | ➖ | - | 自由标签 | §4.3 |
| 动作 | `type` | string | ✅ | - | ✅ 3 型 | §5 |
| 动作 | `rate` | decimal | 当 type=discountRate | - | [0, 1] | §5 |
| 动作 | `price` | decimal | 当 type=fixedPrice | - | ≥ 0 | §5 |
| 动作 | `amount` | decimal | 当 type=discountAmount | - | ≥ 0 | §5 |

---

## 二、语法架构速览

### 2.1 核心设计原则

| 原则 | 含义 | 为什么 |
|---|---|---|
| **词表封闭** | 条件字段、动作类型都是固定清单，不可自定义 | 可校验、可回译、可审计 |
| **自由组合** | `all`/`any`/`not` 三组合子 + 叶子谓词 = 布尔闭包 | 用少量算子覆盖大量表达需求 |
| **纯函数求值** | 引擎零 I/O，输入 → 输出 可预测 | 性能 < 1ms；可测试；可重放 |
| **同组互斥 + 跨组链式** | 同 group 取最大 priority；不同组按优先级依次施加 | 把"撞车怎么办"从隐含顺序变成显式结构 |
| **Fail-Closed** | 校验失败 → 保留上一版，绝不静默降级 | 防止 AI 生成的坏策略上线算错价 |
| **可回译** | 任何规则都能渲染成业务人员看得懂的中文 | AI 生成的规则人能确认，这是上线前提 |

### 2.2 求值流程（6 步）

```
1. 候选筛选：档期内 + enabled + 商品维度命中
                ↓
2. 条件判定：when 条件树求值（基于原始输入价，防顺序依赖）
                ↓
3. 同组选优：每个 group 取 priority 最大的一条
                ↓
4. 跨组排序：按 (priority desc, id asc) 排成施加链
                ↓
5. 依次施加：state = listPrice → 逐规则改写 → Round(2) → Max(0, state)
                ↓
6. 输出：{ price, appliedRuleIds[] }
```

---

## 三、场景案例（由简到繁，覆盖全部字段）

> 所有案例用一个虚拟门店演示：**storeId = 99999**，以下商品分类关系：
>
> | 分类 UID | 分类名 | 代表商品 | UID | 原价 |
> |---|---|---|---|---|
> | `cat-hot-001` | 热菜 | 水煮鱼 | `dish-fish-001` | 68.00 |
> | `cat-cold-001` | 凉菜 | 凉拌黄瓜 | `dish-cucumber-001` | 18.00 |
> | `cat-drink-001` | 酒水 | 青岛啤酒 | `dish-beer-001` | 12.00 |
> | `cat-staple-001` | 主食 | 扬州炒饭 | `dish-rice-001` | 22.00 |

---

### 案例 1：最简单的规则 —— 单字段条件 + 单动作

**场景**：每周二凉菜 8 折。

```json
{
  "schemaVersion": 1,
  "storeId": 99999,
  "revision": 1,
  "validFrom": null,
  "validTo": null,
  "rules": [
    {
      "id": "R-TUE-COLD-80",
      "label": "周二凉菜 8 折",
      "enabled": true,
      "group": "weekday-cold",
      "priority": 100,
      "when": {
        "days": ["tue"],
        "categories": ["cat-cold-001"]
      },
      "then": {
        "type": "discountRate",
        "rate": 0.80
      }
    }
  ]
}
```

**覆盖字段**：`schemaVersion` `storeId` `revision` `validFrom` `validTo` `rules` `id` `label` `enabled` `group` `priority` `when` `then` `days` `categories` `type` `rate`

**验证**：

| 时间 | 商品 | 原价 | 命中 | 结果 |
|---|---|---|---|---|
| 周二 12:00 | 凉拌黄瓜（凉菜） | 18.00 | ✅ | 18 × 0.8 = **14.40** |
| 周三 12:00 | 凉拌黄瓜（凉菜） | 18.00 | ❌ days 不符 | **18.00** |
| 周二 12:00 | 水煮鱼（热菜） | 68.00 | ❌ categories 不符 | **68.00** |

---

### 案例 2：时段条件 —— 半开区间 + 跨午夜

**场景**：午市（11:00-14:00）和夜宵（22:00-次日 02:00）热菜每份减 3 元。

```json
{
  "id": "R-HEAT-LUNCH-NIGHT-M3",
  "label": "午市夜宵热菜减 3 元",
  "group": "heat-promo",
  "priority": 80,
  "when": {
    "categories": ["cat-hot-001"],
    "time": [["11:00", "14:00"], ["22:00", "02:00"]]
  },
  "then": {
    "type": "discountAmount",
    "amount": 3
  }
}
```

**覆盖字段**：`time`（段数组、跨午夜） `discountAmount` `amount`

**关键点**：
- 半开区间 `[起, 止)` —— `14:00` 整不命中，避免相邻时段双命中
- 起 > 止 = 跨午夜 —— `22:00-02:00` 在 `01:30` 命中、`21:59` 不命中

**验证**：

| 时间 | 商品 | 原价 | 命中 | 结果 |
|---|---|---|---|---|
| 周一 11:00 | 水煮鱼 | 68.00 | ✅ 午市起点 | 68 - 3 = **65.00** |
| 周一 13:59 | 水煮鱼 | 68.00 | ✅ | **65.00** |
| 周一 14:00 | 水煮鱼 | 68.00 | ❌ 不含 14:00 整 | **68.00** |
| 周一 23:30 | 水煮鱼 | 68.00 | ✅ 跨午夜段 | **65.00** |
| 周一 01:30 | 水煮鱼 | 68.00 | ✅ 凌晨仍属夜宵段 | **65.00** |
| 周一 02:00 | 水煮鱼 | 68.00 | ❌ 不含 02:00 整 | **68.00** |

---

### 案例 3：固定日期 —— 店庆日全场打折

**场景**：11 月 8 日店庆，全场 7.8 折。

```json
{
  "id": "R-ANNIV-78",
  "label": "店庆日全场 7.8 折",
  "group": "anniversary",
  "priority": 300,
  "when": {
    "dates": ["2026-11-08"]
  },
  "then": {
    "type": "discountRate",
    "rate": 0.78
  }
}
```

**覆盖字段**：`dates`

**注意**：`dates` 是固定日期，不依赖节假日日历。每年的店庆需要每年维护（也可以用 `dateTags` 加自定义标签实现"每年店庆日"，但 v1 未支持自定义标签）。

---

### 案例 4：节假日标签 —— 节假日招牌菜固定价

**场景**：节假日（国庆、春节等）期间，招牌水煮鱼特价 49.9 元。

```json
{
  "id": "R-HOLIDAY-FISH-499",
  "label": "节假日水煮鱼 49.9 元",
  "group": "holiday-special",
  "priority": 200,
  "when": {
    "dateTags": ["holiday"],
    "dishUids": ["dish-fish-001"]
  },
  "then": {
    "type": "fixedPrice",
    "price": 49.9
  }
}
```

**覆盖字段**：`dateTags` `dishUids` `fixedPrice` `price`

**关键点**：
- `dateTags` 由装配器查节假日日历解析，引擎只做集合判定
- `dishUids` 是单品精确定位（对比 `categories` 是批量定位）
- `fixedPrice` 覆盖式定价，不看原价多少

---

### 案例 5：组合子 all / any / not —— 周末热菜 8 折，酒水除外

**场景**：周六日热菜 8.9 折，但酒水类（即使属于热菜分类也打了"酒水"标签的）不参与。

```json
{
  "id": "R-WEEKEND-HOT-89",
  "label": "周末热菜 8.9 折（酒水除外）",
  "group": "weekend",
  "priority": 100,
  "when": {
    "all": [
      { "days": ["sat", "sun"] },
      { "categories": ["cat-hot-001"] }
    ],
    "not": {
      "tags": ["酒水"]
    }
  },
  "then": {
    "type": "discountRate",
    "rate": 0.89
  }
}
```

**覆盖字段**：`all` `not` `tags`

**等价逻辑**：`days ∈ {sat, sun} AND categories ∈ {热菜} AND NOT(tags 包含 "酒水")`

**补充：`any` 的用法**

场景：午市或夜宵时段（任一时段命中）凉菜减 2 元。

```json
{
  "id": "R-LUNCH-NIGHT-COLD-M2",
  "label": "午市夜宵凉菜减 2 元",
  "group": "cold-promo",
  "priority": 50,
  "when": {
    "categories": ["cat-cold-001"],
    "any": [
      { "time": [["11:00", "14:00"]] },
      { "time": [["22:00", "02:00"]] }
    ]
  },
  "then": {
    "type": "discountAmount",
    "amount": 2
  }
}
```

**覆盖字段**：`any`

**注意**：`time` 本身已经支持多段数组（段之间是 OR 关系），上面用 `any` 包两个 `time` 只是为了演示 `any` 的语法。实际写的时候可以直接写 `"time": [["11:00","14:00"], ["22:00","02:00"]]`，效果一样。

---

### 案例 6：同组互斥 —— 会员日两个档位取最高档

**场景**：每月 8 号会员日，凉菜有两个优惠档位：满 3 份以上 7 折（更优）、2 份以上 8 折。**同组内取优先级最高的一条，不累加。**

> 注：v1 没有数量条件（`lineQty` 是下一档），这里用"不同分类"模拟同组互斥逻辑。
> 实际场景：同一条菜在会员日有两个档位，取更高优惠的那个。

```json
{
  "id": "R-MEMBER-DAY-COLD-80",
  "label": "会员日凉菜 8 折",
  "group": "member-day-cold",
  "priority": 100,
  "when": {
    "dates": ["2026-10-08"],
    "categories": ["cat-cold-001"]
  },
  "then": {
    "type": "discountRate",
    "rate": 0.80
  }
},
{
  "id": "R-MEMBER-DAY-COLD-70",
  "label": "会员日凉菜 7 折（高优先级）",
  "group": "member-day-cold",
  "priority": 200,
  "when": {
    "dates": ["2026-10-08"],
    "categories": ["cat-cold-001"],
    "tags": ["会员专享"]
  },
  "then": {
    "type": "discountRate",
    "rate": 0.70
  }
}
```

**覆盖概念**：`group`（互斥组） `priority`（优先级）同组互斥

**结果**：
- 打了"会员专享"标签的凉菜 → 两条都命中 → 同组取 priority 高的（200 > 100）→ 7 折
- 普通凉菜 → 只命中 8 折那条 → 8 折
- **绝不会出现 8 折后再打 7 折**（同组互斥，取最高档）

> ⚠️ **同组同 priority = 校验错误**——不许靠 id 排序蒙混过关。

---

### 案例 7：跨组链式叠加 —— 周末 + 店庆双重优惠

**场景**：店庆日刚好是周日，周末热菜 8.9 折 + 店庆全场 7.8 折可以叠加。

```json
{
  "id": "R-WEEKEND-HOT-89",
  "label": "周末热菜 8.9 折",
  "group": "weekend-heat",
  "priority": 100,
  "when": {
    "days": ["sat", "sun"],
    "categories": ["cat-hot-001"]
  },
  "then": {
    "type": "discountRate",
    "rate": 0.89
  }
},
{
  "id": "R-ANNIV-78",
  "label": "店庆日全场 7.8 折",
  "group": "anniversary",
  "priority": 300,
  "when": {
    "dates": ["2026-11-08"]
  },
  "then": {
    "type": "discountRate",
    "rate": 0.78
  }
}
```

**覆盖概念**：跨组链式叠加

**结果（2026-11-08 是周日，水煮鱼 68 元）**：
- 两条都命中，不同组 → 按 priority 从高到低依次施加
- 施加顺序：`R-ANNIV-78`（300） → `R-WEEKEND-HOT-89`（100）
- 计算：68 × 0.78 × 0.89 = **47.21**（四舍五入到 2 位）

**重要：条件判定基于原始价**

`R-WEEKEND-HOT-89` 的 `when` 判定看的是 **原价 68**，不是店庆折扣后的 53.04。
为什么？防止顺序依赖 —— 避免"A 先跑就命中、B 先跑就不命中"的情况。

---

### 案例 8：enabled 开关 —— 暂不启用的规则

**场景**：双 11 活动提前配置好，但还没到时间，先关掉。

```json
{
  "id": "R-DOUBLE11-ALL-85",
  "label": "双 11 全场 8.5 折",
  "enabled": false,
  "group": "double11",
  "priority": 250,
  "when": {
    "dates": ["2026-11-11"]
  },
  "then": {
    "type": "discountRate",
    "rate": 0.85
  }
}
```

**覆盖字段**：`enabled`

**说明**：`enabled: false` 的规则参与校验但不参与求值——配置写好了，到点再打开就行，不用重新生成。也可以用 `validFrom`/`validTo` 控制整包档期，看场景需要。

---

### 案例 9：整包档期 validFrom / validTo

**场景**：整个夏季促销策略（6 月-8 月），9 月自动失效。

```json
{
  "schemaVersion": 1,
  "storeId": 99999,
  "revision": 3,
  "validFrom": "2026-06-01",
  "validTo": "2026-08-31",
  "rules": [
    {
      "id": "R-SUMMER-BEER-99",
      "label": "夏季啤酒特价 9.9",
      "group": "summer-beer",
      "priority": 150,
      "when": {
        "categories": ["cat-drink-001"]
      },
      "then": {
        "type": "fixedPrice",
        "price": 9.9
      }
    }
  ]
}
```

**覆盖字段**：`validFrom` `validTo`

**关键点**：档期判断在**加载/校验期**做，不在求值热路径。不在档期 = 整包不加载，等同空策略（全部按原价）。
**含当天**：`validTo` 为 8 月 31 日 → 8 月 31 日当天仍生效。

---

### 案例 10：集合谓词的四种写法

```json
// 写法 1：简写，任一命中（= in）
{ "categories": ["cat-hot-001", "cat-cold-001"] }

// 写法 2：显式 in，与写法 1 等价
{ "categories": { "in": ["cat-hot-001", "cat-cold-001"] } }

// 写法 3：notIn，排除
{ "categories": { "notIn": ["cat-drink-001"] } }   // 非酒水类

// 写法 4：all，同时包含全部（主要用于 tags）
{ "tags": { "all": ["招牌", "辣"] } }               // 同时是招牌菜和辣菜
```

**覆盖语法**：集合谓词四种形态（`in`/`notIn`/`all` + 简写）

---

### 案例 11：完整策略文档 —— 一家店的全部定价规则

**场景**：一家中型川菜馆，配置以下所有优惠：

| 规则 | 条件 | 动作 | 组 | 优先级 |
|---|---|---|---|---|
| 周末热菜 8.9 折 | 周六日 + 热菜分类 + 非酒水 | ×0.89 | weekend-heat | 100 |
| 午市凉菜减 2 元 | 11-14 点或 22-02 点 + 凉菜 | -2 元 | lunch-cold | 50 |
| 节假日水煮鱼 49.9 | 节假日 + 水煮鱼单品 | 固定价 49.9 | holiday-fish | 200 |
| 店庆全场 7.8 折 | 11 月 8 日 | ×0.78 | anniversary | 300 |
| 夏季啤酒特价 9.9 | 6-8 月 + 酒水 | 固定价 9.9 | summer-beer | 150 |

完整 JSON：

```json
{
  "schemaVersion": 1,
  "storeId": 99999,
  "revision": 5,
  "validFrom": "2026-06-01",
  "validTo": "2026-12-31",
  "rules": [
    {
      "id": "R-WEEKEND-HOT-89",
      "label": "周末热菜 8.9 折（酒水除外）",
      "enabled": true,
      "group": "weekend-heat",
      "priority": 100,
      "when": {
        "all": [
          { "days": ["sat", "sun"] },
          { "categories": ["cat-hot-001"] }
        ],
        "not": { "tags": ["酒水"] }
      },
      "then": { "type": "discountRate", "rate": 0.89 }
    },
    {
      "id": "R-LUNCH-COLD-M2",
      "label": "午市夜宵凉菜减 2 元",
      "enabled": true,
      "group": "lunch-cold",
      "priority": 50,
      "when": {
        "categories": ["cat-cold-001"],
        "time": [["11:00", "14:00"], ["22:00", "02:00"]]
      },
      "then": { "type": "discountAmount", "amount": 2 }
    },
    {
      "id": "R-HOLIDAY-FISH-499",
      "label": "节假日水煮鱼 49.9 元",
      "enabled": true,
      "group": "holiday-fish",
      "priority": 200,
      "when": {
        "dateTags": ["holiday"],
        "dishUids": ["dish-fish-001"]
      },
      "then": { "type": "fixedPrice", "price": 49.9 }
    },
    {
      "id": "R-ANNIV-78",
      "label": "店庆日全场 7.8 折",
      "enabled": true,
      "group": "anniversary",
      "priority": 300,
      "when": { "dates": ["2026-11-08"] },
      "then": { "type": "discountRate", "rate": 0.78 }
    },
    {
      "id": "R-SUMMER-BEER-99",
      "label": "夏季啤酒特价 9.9",
      "enabled": true,
      "group": "summer-beer",
      "priority": 150,
      "when": {
        "time": [["10:00", "23:00"]],
        "categories": ["cat-drink-001"]
      },
      "then": { "type": "fixedPrice", "price": 9.9 }
    }
  ]
}
```

**综合走查表**：

| # | 场景 | 命中规则 | 计算 | 结果 |
|---|---|---|---|---|
| 1 | 2026-06-15（周一）12:30，凉拌黄瓜 18 元（凉菜） | R-LUNCH-COLD-M2 | 18 - 2 | **16.00** |
| 2 | 2026-07-04（周六）18:00，水煮鱼 68 元（热菜） | R-WEEKEND-HOT-89 | 68 × 0.89 | **60.52** |
| 3 | 2026-10-01（国庆·周四）19:00，水煮鱼 68 元 | R-HOLIDAY-FISH-499 | 固定价 | **49.90** |
| 4 | 2026-11-08（店庆·周日）12:30，水煮鱼 68 元 | R-ANNIV-78 + R-WEEKEND-HOT-89（跨组叠加） | 68 × 0.78 × 0.89 | **47.21** |
| 5 | 2026-07-15（周三）20:00，青岛啤酒 12 元（酒水） | R-SUMMER-BEER-99 | 固定价 | **9.90** |
| 6 | 2026-05-01（5 月不在档期）任何商品 | 整包不加载 | 原价 | **原价** |

---

## 四、输入与输出（PriceContext / PriceQuote）

### 4.1 PriceContext（求值输入）

```json
{
  "storeId": 99999,
  "now": "2026-09-29T12:30:00",
  "dateTags": ["workday"],
  "dishUid": "dish-cucumber-001",
  "category": "cat-cold-001",
  "tags": [],
  "listPrice": 18.00
}
```

| 字段 | 来源 | 说明 |
|---|---|---|
| `storeId` | 调用方 | 门店 id，匹配策略文档 |
| `now` | 门店本地墙钟 | `days`/`dates`/`time` 都从这个派生（纯函数） |
| `dateTags` | 装配器查节假日日历 | I/O 在装配器，引擎只做集合判定 |
| `dishUid` | 装配器读 BaseDish | 匹配 `dishUids` 条件 |
| `category` | 装配器读 BaseDish.TypeID | 匹配 `categories` 条件（存的是 UID） |
| `tags` | 装配器读商品标签 | 匹配 `tags` 条件（v1 待接） |
| `listPrice` | 装配器读 BaseDish.SalePrice | 基准价，做法/规格加价已折算进来 |

**设计原则**：能由装配器派生的就不放进上下文，减少调用方填错的可能。
- `days` 从 `now` 派生 → 调用方不用传
- `date` 从 `now` 派生 → 调用方不用传
- 但 `dateTags` 传结果不传日历 → 引擎零 I/O

### 4.2 PriceQuote（求值输出）

```json
{
  "dishUid": "dish-cucumber-001",
  "listPrice": 18.00,
  "price": 16.00,
  "appliedRuleIds": ["R-LUNCH-COLD-M2"]
}
```

| 字段 | 用途 |
|---|---|
| `dishUid` | 回传标识，调用方对齐用 |
| `listPrice` | 原始基准价，方便展示对比 |
| `price` | 成交单价（非会员价） |
| `appliedRuleIds` | 命中的规则 id 列表（施加顺序），界面展示"本价格来自：周末热菜 8.9 折" |

> 注意：`appliedRuleIds` 是**展示用**，不是审计用。审计由外部调用方负责。

---

## 五、校验与回译（两道安全闸）

### 5.1 校验器（8 条检查）

| # | 检查项 | 典型错误 | 后果 |
|---|---|---|---|
| 1 | 字段名闭集 | 把 `days` 写成 `weekdays` | 拒绝 |
| 2 | 动作数值域 | `rate: 89`（应为 0.89） | 拒绝 |
| 3 | id 唯一 / 同组同 priority | 两条同 group 同 priority | 拒绝 |
| 4 | days 取值闭集 | 写了 `monday` 而非 `mon` | 拒绝 |
| 5 | time 格式 + 段重叠告警 | `["11:00","11:00"]` | 拒绝 / 告警 |
| 6 | dates 格式合法 | `"2026/10/1"` | 拒绝 |
| 7 | 嵌套深度 ≤ 5 / `any: []` 告警 | 6 层嵌套 | 拒绝 / 告警 |
| 8 | 装配器能力核对 | 规则用了 `tags` 但标签表未接 | 拒载整个文档 |

**校验失败 → 保留上一版策略**，新版本进草稿态等人工确认。

### 5.2 回译器（确定性中文渲染）

示例回译输出：

```
R-WEEKEND-HOT-89 周末热菜 8.9 折（酒水除外）    [组 weekend-heat · 优先级 100]
  当：每周六或周日 且 分类属于「热菜」 且 不包含标签「酒水」
  则：按当前价 8.9 折（× 0.89）

R-HOLIDAY-FISH-499 节假日水煮鱼 49.9 元         [组 holiday-fish · 优先级 200]
  当：节假日 且 商品是「dish-fish-001」
  则：固定价 49.9 元
```

**交叉校验机制**：生成端同时给出 `label` 与 JSON → 渲染器从 JSON 产出中文 → **`label` 与渲染首行不一致 → 进人工确认**。
作用：防止"JSON 写的是 9 折、label 写的是 8 折"这类静默错价。

---

## 六、这套设计适合哪些具体场景

### 6.1 核心判定标准

满足以下特征的业务，**高度适合**用 JSON DSL + AI 生成的方式：

| 特征 | 说明 | 价格场景的对应 |
|---|---|---|
| **条件 → 动作**型逻辑 | 业务规则本质是"满足某些条件 → 执行某个动作" | 满足时间/商品条件 → 改价格 |
| **条件维度有限且封闭** | 条件种类不多（< 20 个），可以穷举成词表 | 7 个字段（时间/商品两大类） |
| **动作类型有限且封闭** | 动作种类不多（< 10 个），可以穷举成词表 | 3 种（打折/固定价/减额） |
| **需要人确认** | 规则错误有后果（钱、合规、客诉），必须人能看懂 | 价格算错要担责 |
| **高频变更** | 规则经常变（活动、促销、策略调整），需要快速迭代 | 餐饮定价每周/每月调 |
| **性能要求高** | 求值必须快（毫秒级或微秒级），不能调 AI / 不能查库 | 点单 < 50ms，价格求值 < 1ms |
| **需要审计追溯** | 出了问题要能回答"当时为什么是这个结果" | "为什么这道菜今天是这个价" |
| **非技术人员录入** | 规则由业务人员（店长、运营）用自然语言描述 | 店长说"周末热菜打 8 折" |

### 6.2 适合的具体场景（餐饮行业）

| 场景 | 条件维度 | 动作类型 | 适配度 |
|---|---|---|---|
| **菜品定价**（已实现） | 时间/日期/节假日/商品/分类/标签 | 打折/固定价/减额 | ⭐⭐⭐⭐⭐ |
| **库存上下限** | 星期/时段/门店/分类/销量等级 | 调整上限/下限/补货量 | ⭐⭐⭐⭐⭐ |
| **会员权益（等级折扣）** | 会员等级/标签/时间/分类 | 折扣/积分倍率/专属价 | ⭐⭐⭐⭐ |
| **促销赠品** | 时间/金额/数量/分类 | 赠某商品 | ⭐⭐⭐⭐ |
| **排班规则** | 星期/时段/门店/岗位 | 人数上限/薪资倍率 | ⭐⭐⭐⭐ |
| **打印策略** | 单据类型/金额/支付方式/时段 | 打印份数/选择打印机 | ⭐⭐⭐⭐⭐ |
| **沽清预警** | 库存水平/时段/日销量 | 触发预警/自动下架 | ⭐⭐⭐⭐ |
| **推荐菜排序** | 时间/销量/利润率/标签 | 调整推荐权重/排序 | ⭐⭐⭐ |
| **外卖配送费** | 金额/距离/时段/天气标签 | 减免/固定额 | ⭐⭐⭐⭐ |

### 6.3 适合的具体场景（跨行业通用）

| 行业 | 场景 | 条件维度 | 动作类型 |
|---|---|---|---|
| **零售** | 商品促销定价 | 时间/会员等级/分类/品牌 | 打折/减额/买赠 |
| **电商** | 运费策略 | 金额/重量/地区/时段 | 免运费/减运费/固定额 |
| **SaaS** | 计费规则 | 用量/套餐/地区/企业规模 | 单价调整/阶梯价/封顶 |
| **物流** | 运费计算 | 重量/体积/距离/时效/燃油标签 | 单价/附加费/折扣 |
| **金融** | 利率定价 | 期限/金额/信用等级/产品类型 | 利率调整/点数加减 |
| **教育** | 学费优惠 | 课程类型/学员等级/报名时段/团报 | 折扣/减额/奖学金 |
| **医疗** | 费用减免 | 患者类型/保险/项目分类/时段 | 折扣/自付比例调整 |

### 6.4 不适合的场景（明确边界）

| 场景 | 为什么不适合 | 正确做法 |
|---|---|---|
| **需要历史状态的**（如"同一会员每天限享一次"） | 破坏纯函数，需要 I/O 查历史订单 | 移到装配器或业务流程层 |
| **需要组合优化的**（如"所有优惠里让顾客付最少"） | 不是首条命中/链式施加，是搜索问题 | 专用优化算法 |
| **需要子集匹配的**（如"套餐 A+B=25 元"） | 对购物车做子集匹配是算法问题 | 专用匹配引擎（如背包问题求解器） |
| **需要多轮求值的**（如"第二份半价与满减撞车时重算"） | 跨规则依赖，循环依赖 | 分阶段模型（P1/P2/P3）能解一部分，但复杂的不行 |
| **条件/动作维度极多且开放的**（超过 20-30 个） | 词表封闭的优势消失，维护成本反超代码 | 直接写代码 + 代码审查 |
| **逻辑本质是流程的**（如"先判断 A，再根据 A 的结果去查 B，再..."） | 不是规则，是流程 | 工作流引擎 / 状态机 |
| **需要实时查外部系统的**（如"调用库存接口判断是否有货"） | 破坏纯函数，性能不可控 | I/O 移到装配器，把结果当上下文传入 |

> **经验法则**：如果你能把规则写成"当 [条件] 时，做 [动作]"这样的句子，而且条件和动作都能列成一个 20 项以内的清单 —— 那就适合。否则，可能不适合。

---

## 七、扩展路径（v1 → v2 → v3 怎么升）

v1 只做了"商品 × 时间条件 → 单价"，但架构预留了扩展位，升档方式是**加字段 + schemaVersion 递增**，旧文档继续可加载。

| 升档 | 新增条件字段 | 新增动作类型 | 关键设计 |
|---|---|---|---|
| **数量维度**（v2） | `lineQty` / `orderQty` | `lineTier`（按份分段）、`discountAmount.per` | `tiers[{fromQty,toQty,rate}]` + `repeat`（循环 vs 超出按 overflowRate）—— 买 3 件买 4 件必须显式回答 |
| **整单维度**（v2） | `orderAmount` / `orderQty` | `orderReduce`（整单减，带摊分） | 规则加 `stage: line\|order`，防循环依赖；满减阶梯用同组 + priority 编码档位 |
| **赠品**（v2） | - | `gift` | 新增 0 价行 + `giftOf` 标记 |
| **会员维度**（v2） | `memberLevel` / `memberTags` / `appliedPromotions` | -（复用现有动作） | 会员价是输入价（装配器算好），引擎不认识"会员价"；不叠加用 `appliedPromotions` + `not` |
| **多门店模板**（v3） | - | - | 模板 + 门店覆盖两层，不把作用域塞进规则 |

---

## 八、一句话总结

> **JSON DSL = 封闭词表的条件 + 封闭词表的动作 + 布尔组合子 + 纯函数求值 + 可回译确认**。
> 它不是编程语言的替代品，而是"规则类业务"的专用表达形式 —— 牺牲一部分表达力，换来可校验、可确认、可审计、高性能、AI 可生成这一堆好处。
> 价格是第一个场景，但这套范式能平移到任何"条件 → 动作"型、规则高频变更、出错有代价的业务。
