# PricePolicy JSON DSL 演示程序 — PRD v2.0

> 版本：v2.0  
> 日期：2026-10-11  
> 状态：待评审  
> 基于：稻香需求整理.xlsx + PricePolicyDSL.md v1

---

## 一、项目概述

### 1.1 项目目标

构建一个**纯前端、零依赖后端、完全离线可用**的 PricePolicy JSON DSL 可视化演示程序，用于：

- 演示和验证 JSON DSL 引擎的正确性（v1 + v2）
- 可视化调试规则命中过程
- 作为 DSL 语法教学/培训工具
- 作为非技术人员理解规则的桥梁（回译器）
- **验证稻香项目 12 个适用场景的 DSL 落地可行性**

### 1.2 核心价值

| 价值 | 说明 |
|---|---|
| **可视化验证** | 改 JSON → 实时看结果，比跑单元测试直观 |
| **调试友好** | 命中轨迹 + 中间值 + 阶段明细，排查规则冲突一目了然 |
| **回译确认** | JSON ↔ 中文双向映射，非技术人员也能看懂 |
| **性能可视化** | 批量测试面板直观展示 100 个菜全量定价的耗时，消除"点菜页会不会卡"的疑虑 |
| **完全离线** | 双击即跑，不依赖任何网络或后端 |
| **稻香场景验证** | 内置 12 个稻香典型场景 + 完整规则集 + 用例，开箱即可演示给产品看 |

### 1.3 技术栈确认

| 层 | 技术 | 来源 | 体积 |
|---|---|---|---|
| 前端框架 | Vue 3 (Composition API) | 本地 JS 文件 | ~40KB gzip |
| JSON 编辑器 | CodeMirror 6 | 本地 JS + CSS | ~80KB gzip |
| 样式 | 手写 CSS（高对比度大按钮风格） | 内联 | ~15KB |
| 引擎 | 纯 JS 实现（v1 + v2 规格） | 内联 | ~25KB |
| 回译器 | 纯 JS 实现（确定性回译） | 内联 | ~12KB |
| 数据持久化 | localStorage | 浏览器原生 | — |

**交付形态**：一个目录，双击 `index.html` 即运行。

### 1.4 版本范围

| 版本 | 内容 | 状态 |
|---|---|---|
| **v1 引擎** | 时间 × 商品维度 + 3 种动作 + 行级单阶段 | ✅ 已设计完成 |
| **v2 引擎** | 会员维度 + 数量/金额维度 + 整单级 + 多阶段 + 多时间字段 + 最低折扣钳制 + bestOf | 🔥 本次新增 |

---

## 二、功能规格

### 2.1 整体布局

```
┌───────────────────────────────────────────────────────────────────────────────┐
│  顶部工具栏                                                                     │
│  [Logo] PricePolicy DSL 演示器 v2   [场景选择▼] [导入] [导出] [重置] [主题]    │
├──────────────┬─────────────────────────┬───────────────────────────────────────┤
│              │                         │                                       │
│  规则列表    │   规则编辑区            │   用例与执行结果                        │
│  (左栏)      │   (中栏)                │   (右栏)                               │
│              │                         │                                       │
│  搜索框       │  [引擎版本 v1/v2 切换]  │  场景选择（稻香场景快捷入口）           │
│  ───────     │                         │  ┌──────────────────────┐ ▼            │
│  📁 日常折扣  │  [规则元信息表单]       │  └──────────────────────┘              │
│    规则1 ●   │  id / label / group     │                                       │
│    规则2 ○   │  priority / enabled     │  用例选择                               │
│  📁 时段促销  │  stage (行级/整单级)    │  ┌──────────────────────┐ ▼            │
│    规则3 ●   │                         │  └──────────────────────┘              │
│  📁 会员权益  │  [条件 when 编辑器]     │                                       │
│    ...       │  (CodeMirror)           │  上下文 Context 展示                    │
│              │                         │  ┌──────────────────────────────────┐  │
│  [+ 新增规则] │  [动作 then 编辑器]     │  │ now / orderTime / openTime      │  │
│  [- 删除]    │  (CodeMirror)           │  │ dishUid / basePrice / qty        │  │
│              │                         │  │ categories / tags                │  │
│              │  [回译预览]             │  │ dateTags / memberLevel           │  │
│              │  ▼ 中文描述              │  │ orderAmount / guestCount (v2)   │  │
│              │  ⚠ label不一致          │  └──────────────────────────────────┘  │
│              │                         │                                       │
│              │  [校验结果]             │  [▶ 执行计算]                         │
│              │  ✓ 校验通过 / ✗ 错误    │                                       │
│              │                         │  执行结果（分阶段展示）                 │
│              │                         │  ┌──────────────────────────────────┐  │
│              │                         │  │ 🔥 最终价格：¥ 26.60              │  │
│              │                         │  │    原价：¥ 38.00  省 ¥ 11.40      │  │
│              │                         │  │                                    │  │
│              │                         │  │ 【P1 行级定价】                    │  │
│              │                         │  │  ① 店庆8折       -¥7.60  → ¥30.40│  │
│              │                         │  │  ② 周末8.9折     -¥3.34  → ¥27.06│  │
│              │                         │  │  【会员价钳制】                    │  │
│              │                         │  │  minRate 0.7     已生效           │  │
│              │                         │  │                                    │  │
│              │                         │  │ 命中规则：2 条                     │  │
│              │                         │  │ 耗时：0.05 ms                      │  │
│              │                         │  └──────────────────────────────────┘  │
│              │                         │                                       │
│              │                         │  命中轨迹（调试视图，可折叠）           │
│              │                         │  ┌──────────────────────────────────┐  │
│              │                         │  │ ☑ r_anniv_80    ✓ 命中           │  │
│              │                         │  │   dates✓ 全品类✓                  │  │
│              │                         │  │ ☑ r_weekend_89   ✓ 命中           │  │
│              │                         │  │   days✓ categories✓               │  │
│              │                         │  │ ☐ r_lunch_minus3 ✗ 未命中         │  │
│              │                         │  │   time 不匹配(12:30不在11-14)     │  │
│              │                         │  └──────────────────────────────────┘  │
│              │                         │                                       │
└──────────────┴─────────────────────────┴───────────────────────────────────────┘
```

### 2.2 顶部工具栏

| 功能 | 说明 |
|---|---|
| Logo + 标题 | "PricePolicy DSL 演示器 v2" |
| 场景选择下拉 | 快速切换预设场景包：通用演示 / 稻香餐饮 / 打印路由 / 售卖时间 |
| 导入 | 导入 JSON 策略文档（.json 文件） |
| 导出 | 导出当前策略为 JSON 文件 |
| 重置默认 | 恢复到当前场景的内置默认规则集（确认弹窗） |
| 主题切换 | 亮色 / 深色主题切换（偏好持久化） |

### 2.3 左栏：规则列表

#### 2.3.1 搜索与筛选栏（顶部）

| 功能 | 说明 |
|---|---|
| 搜索框 | 按 id / label 模糊过滤，实时匹配 |
| **Stage 筛选** | 切换按钮：全部 / 行级 / 整单级，点击快速过滤 stage |
| **动作类型筛选** | 下拉多选：打折 / 减额 / 固价 / bestOf / 满减 / 赠品 / 其他 |
| **分组筛选** | 下拉选择：全部 / 或指定 group 名 |
| **状态筛选** | 切换按钮：全部 / 已启用 / 已禁用 |
| **标签筛选** | 点击标签云（时段 / 会员 / 数量 / 节假日 / 菜品）快速按条件维度过滤 |

- 所有筛选条件**叠加生效**（AND 关系）
- 筛选结果实时更新，右侧显示「共 N 条 / 匹配 M 条」计数
- 搜索框支持快捷键 `/` 聚焦

#### 2.3.2 规则列表主体

| 功能 | 说明 |
|---|---|
| 分组展示 | 按 group 分组折叠/展开，组名前加图标，组标题显示组内规则数 |
| 规则条目 | 显示：启用状态圆点 + label + priority 数字 + stage 标签（line/order）+ 动作类型小标签 |
| 点击选中 | 点击规则 → 中栏加载该规则 JSON |
| 新增规则 | 底部按钮，选择模板（空规则 / 时段折扣 / 会员价 / 满减 / ...） |
| 删除规则 | 选中规则后可删除（确认弹窗） |
| 启用/禁用切换 | 每条规则左侧圆点点击切换 enabled |
| 排序 | 组内按 priority 降序；组间按组内最高 priority 降序 |
| 高亮 | 当前选中规则高亮 + 左侧竖线指示 |

### 2.4 中栏：规则编辑区

#### 2.4.1 规则元信息（表单形式）

| 字段 | 类型 | v1/v2 | 说明 |
|---|---|---|---|
| id | 输入框 | v1 | 唯一标识，自动生成可修改 |
| label | 输入框 | v1 | 中文描述，用于回译交叉校验 |
| group | 输入框 | v1 | 互斥组标识，必填 |
| priority | 数字输入 | v1 | 优先级 0-9999，数字越大越优先 |
| enabled | 开关 | v1 | 是否启用 |
| stage | 下拉选择 | v2 | `line`（行级）/ `order`（整单级），默认 line |
| schemaVersion | 只读 | — | 继承自文档 |

#### 2.4.2 条件编辑器（CodeMirror）

- 编辑 `when` 字段的 JSON 对象
- 实时语法高亮
- 实时 JSON 语法错误标红
- 实时 DSL 语义校验（字段闭集、数值域、格式等）
- v2 条件字段语法提示（悬停显示字段说明）

#### 2.4.3 动作编辑器（CodeMirror）

- 编辑 `then` 字段的 JSON 对象
- 实时语法高亮 + 错误标红
- v2 动作类型支持（bestOf / orderReduce / gift 等）

#### 2.4.4 回译预览区

- 实时显示当前规则的中文回译结果
- 与 `label` 字段交叉比对，不一致时标黄提醒
- 回译失败时标红并说明原因
- **v2 支持多阶段回译**（行级 + 整单级分别翻译）

#### 2.4.5 校验结果

- JSON 语法校验结果
- DSL 语义校验结果（v1 + v2 所有校验项）
- 通过 / 失败 + 具体错误信息 + 字段路径
- 警告（非致命，如 any:[] 恒假、time 段重叠）

### 2.5 右栏：用例与执行

#### 2.5.1 场景快捷入口

- 稻香场景快速切换按钮组
- 每个场景自动加载对应规则集 + 用例集

#### 2.5.2 用例选择与筛选

| 功能 | 说明 |
|---|---|
| **用例类型筛选** | 切换按钮：全部 / 行级 / 整单级 / 批量性能 |
| **场景标签筛选** | 标签云：时段价 / 会员 / 满减 / 赠品 / 互斥叠加 / 钳制 / bestOf / 沽清，点击快速过滤 |
| **用例列表** | 列表形式展示，不是下拉；每条显示名称 + 简短描述 + 预期结果摘要 |
| 用例数据在独立文件中 | 支持导入自定义用例 JSON |

- 搜索框：按用例名称模糊搜索
- 选中用例后自动加载 Context 并执行（可配置自动执行开关）
- 用例条目右侧显示「预期结果徽章」（如"8.5折"、"减20元"、"赠甜品"），一眼看出用例测试什么

#### 2.5.3 Context 展示（可编辑）

v1 字段 + v2 扩展字段：

| 字段 | v1/v2 | 说明 |
|---|---|---|
| now | v1 | 计算时间（门店本地墙钟） |
| orderTime | v2 | 下单时间（时段价依据之一） |
| openTime | v2 | 开台时间（时段价依据之二） |
| dishUid | v1 | 商品 UID |
| dishName | — | 商品名（仅展示） |
| basePrice | v1 | 基准单价 |
| lineQty | v2 | 当前行数量 |
| categories | v1 | 分类 UID 列表 |
| tags | v1 | 标签列表 |
| dateTags | v1 | 日期标签（装配器传入） |
| memberLevel | v2 | 会员等级（null=非会员） |
| memberTags | v2 | 会员标签数组 |
| orderAmount | v2 | 当前订单总金额（整单级规则用） |
| orderQty | v2 | 当前订单总数量 |
| guestCount | v2 | 用餐人数 |
| minRate | v2 | 最低折扣率（钳制用，如 0.7 = 最低7折） |
| storeId | v1 | 门店 ID |

#### 2.5.4 执行按钮

- 大号按钮，点击执行计算
- 快捷键：Ctrl + Enter
- 自动执行开关（默认开启：Context 变化后 300ms 防抖自动重算）

#### 2.5.5 执行结果（分阶段展示）

| 部分 | 内容 |
|---|---|
| **最终价格** | 大号醒目显示，红色 |
| **原价 + 优惠** | 原价、优惠金额、优惠幅度 |
| **P1 行级定价明细** | 每条行级规则的施加顺序、动作、前后价格 |
| **钳制信息**（v2） | 最低折扣是否触发、钳制前/后价格 |
| **P2 整单级结果**（v2） | 整单优惠项、分摊方式、分摊后行价 |
| **赠品**（v2） | 赠品行列表 |
| **命中规则列表** | 按施加顺序排列，显示 id + label + 动作说明 |
| **执行耗时** | 微秒级精度 |

#### 2.5.6 命中轨迹（调试视图）

- 列出所有规则的命中状态
- 命中：绿色 ✓ + 详细条件命中情况
- 未命中：灰色 ✗ + 第一个未命中的条件原因
- 同组互斥：标注"被同组更高优先级规则覆盖（rule_xxx, priority N）"
- 整单行级分开展示
- 可折叠/展开

#### 2.5.7 性能测试面板（新增）

> 展示引擎在真实批量场景下的性能水平，验证"100 个菜会不会卡"的疑虑。

**入口**：右栏底部 Tab 切换「执行结果 / 命中轨迹 / 性能测试」，默认在执行结果。

**功能**：

| 项 | 说明 |
|---|---|
| **菜品数量滑块** | 10 / 50 / 100 / 300 / 500 / 1000，拖动模拟不同规模门店 |
| **规则数量** | 自动读取当前策略的规则总数 |
| **运行按钮** | 点击后执行 `resolveBatch` 批量求值 |
| **性能数据展示** | 总耗时(ms) / 单菜平均耗时(µs) / 时间过滤后规则数 / 平均候选规则数 / 缓存命中 |
| **优化层级对比** | 分别显示「无优化（遍历全部）」和「L1+L2+L3 全优化」的耗时对比，用条形图直观展示加速比 |
| **60fps 参考线** | 标注 16ms 参考线，直观判断是否在一帧内完成 |
| **缓存测试** | 重复执行时显示缓存命中，0ms 出结果 |

**设计目的**：
- 直观展示引擎性能水平，消除"点菜页会不会卡"的疑虑
- 验证索引、批量、缓存各层优化的实际效果
- 作为技术演示，向产品/运营证明 DSL 方案的性能可行性

---

## 三、引擎规格（v1 + v2）

### 3.1 v1 引擎（已确定）

**行级单阶段，时间 × 商品维度**

- 文档层：schemaVersion / storeId / validFrom / validTo / label / rules
- 规则层：id / label / enabled / group / priority / when / then
- 条件层（7 个）：days / time / dates / dateTags / dishUids / categories / tags
- 组合子：all / any / not（嵌套 ≤ 5 层）
- 动作层（3 型）：discountRate / fixedPrice / discountAmount
- 冲突解决：同组取最高 priority，跨组按 (priority desc, id asc) 链式叠加
- 求值基准：条件一律基于原始价（basePrice）
- 结算：四舍五入到 2 位小数（AwayFromZero），下限 0

### 3.2 v2 引擎（本次扩展，基于稻香需求）

#### 3.2.1 v2 新增条件维度

| 条件字段 | 类型 | 说明 | 稻香需求来源 |
|---|---|---|---|
| `memberLevel` | 集合（in 语义） | 会员等级：`"gold" / "silver" / "normal"` 等 | 会员价折上折 |
| `memberTags` | 集合 | 会员标签数组，如 `["birthday", "new_member"]` | 精准营销 |
| `lineQty` | 范围对象 `{min, max}` | 当前行数量（单品份数） | 低价活动限制 |
| `orderQty` | 范围对象 | 订单总数量 | 满额赠送 |
| `orderAmount` | 范围对象 | 订单总金额（元） | 满额赠送 / 满减 |
| `guestCount` | 范围对象 | 用餐人数 | 低价活动（2人半份/4人一份） |
| `orderTime` | 时段数组 | 下单时间（替代 v1 的 `time` 基于 `now`） | 时段价 / 点心折扣 |
| `openTime` | 时段数组 | 开台时间 | 时段价（开台口径） |
| `closeTime` | 时段数组 | 结账时间 | 时段价（结账口径） |
| `hasDish` | 集合 | 订单中是否包含指定菜品（in 语义） | 低价加购（点指定菜才能加购） |
| `priceRange` | 范围对象 | 商品价位区间（如高端菜 vs 平价菜） | 会员价折上折（不同价位规则不同） |

**范围对象格式**：
```json
{ "min": 100, "max": 200 }   // 闭区间 [100, 200]
{ "min": 100 }                // [100, +∞)
{ "max": 50 }                 // [0, 50]
```

**多时间字段说明**：
- v1 的 `time` 隐式基于 `now`，v2 显式支持 `orderTime` / `openTime` / `closeTime` 三个时间字段
- 语义和 `time` 完全一致：半开区间段数组、支持跨午夜、格式 HH:mm
- 三个字段彼此独立，可以同时出现在条件里（如"开台在午市且结账在午市"）

#### 3.2.2 v2 新增动作类型

| 动作 | 字段 | 说明 | 稻香需求来源 |
|---|---|---|---|
| `bestOf` | `options: [动作列表]` | 从多个动作中取对顾客最优惠的一个 | 点心折扣（同品多优惠取最优） |
| `orderReduce` | `amount` + `allocate` | 整单减金额，按规则分摊到行 | 满减 / 满额赠送（金额型） |
| `gift` | `dishUid` + `qty` + `allocate` | 赠品（整单级动作） | 满额赠送（赠菜） |
| `maxQty` | `qty` | 限购数量（行级，超过部分恢复原价） | 低价活动（每单限点1份） |
| `memberPrice` | `price` 或 `rate` | 会员专属价（同 fixedPrice/discountRate，但阶段独立） | 会员价 |

**bestOf 动作详解**：
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
- 在运行时，对每个商品分别计算每个 option 的结果，取最低价
- **同组内 bestOf 视为一条规则**，不参与同组互斥（bestOf 内部自己选最优）
- 回译：「享 8.5 折 / 减 8 元 / 固定价 16.8 元，取最优惠者」

**orderReduce 动作详解**：
```json
{
  "type": "orderReduce",
  "amount": 20,
  "allocate": "byLineAmount"
}
```
- `allocate` 分摊方式：`byLineAmount`（按行金额比例）/ `byQty`（按数量）/ `toCheapest`（全摊到最便宜行）/ `none`（不减行，作为优惠项单独列）
- 整单级动作，在 P2 阶段执行

#### 3.2.3 v2 阶段机制（解决循环依赖）

```
P0 装配器：查询商品/会员/日历 → 构造 Context
   ↓
P1 行级定价（line stage）：
   - 输入：单行 + Context（基于原始价判断条件）
   - 输出：行成交价（行级规则叠加后的价格）
   - 约束：不得读其他行、不得改订单级数据
   ↓
P1.5 钳制：
   - 最低折扣（minRate）/ 最低价格 限制
   - 输出：钳制后的行价 + clamped 标记
   ↓
P2 整单级（order stage）：
   - 输入：全单行（P1.5 结果）+ Context
   - 输出：整单优惠项 + 赠品
   - 约束：不得改写行价（整单优惠独立成行或走分摊）
   ↓
P3 摊分（纯计算，无规则）：
   - 整单优惠按 allocate 方式分摊到行
   - 输出：行最终成交价 + 整单优惠明细
```

**规则声明 `stage: "line" | "order"`**，在结构上禁止循环依赖。

#### 3.2.4 v2 最低折扣钳制（minRate）

- Context 传入 `minRate`（如 0.7 = 最低 7 折）
- P1 结束后检查：如果行价 < basePrice × minRate，则钳制到 basePrice × minRate
- 输出中标记 `clamped: true` + `clampedBy` + `beforeClamp` 价格
- **钳制不影响条件判定**：条件仍然基于原始价判断（防止钳制后影响其他规则）
- 来源：BaseDish 的 MinZheKou 字段（稻香数据中已存在）

#### 3.2.5 v2 求值基准说明

| 阶段 | 条件判定基准 | 动作施加基准 |
|---|---|---|
| P1 行级（前 v1 行为） | 原始价 basePrice | 链式，前一条结果作为后一条输入 |
| P1.5 钳制 | — | 与 minRate 比较 |
| P2 整单级 | P1.5 之后的行价合计 | 整单级独立动作（不回写行） |
| P3 分摊 | — | 纯计算 |

### 3.3 性能优化体系（引擎内置）

#### 3.3.1 四层性能优化策略

引擎内置四级优化，按需启用，保证 1000 菜 × 100 规则场景下仍在 5ms 以内。

```
L1 时间前置过滤        L2 维度倒排索引      L3 批量求值         L4 结果缓存
─────────────────    ───────────────    ──────────────    ──────────────
规则加载时，按时间     按商品维度建倒排     一次传 N 个菜      key = 规则版本
维度预筛选，减少       索引，求值时先       进去，时间过滤     + 时间片(5min)
运行时比较量           查索引拿候选，       + 索引构建只做     + 全局维度
                      不遍历全部规则       一次，减少重复     (memberLevel等)
                                            开销
    ↓ 5~10x            ↓ 5~20x             ↓ 2~3x            ↓ 10~100x
```

#### 3.3.2 L1：时间前置过滤

**原理**：调用时 `now` 是确定的，加载期把规则按时间维度预分类，运行时直接取对应时间片的规则子集。

- 预分类维度：`days` / `dates` / `dateTags` / `orderTime` / `openTime` / `closeTime`
- 生效时机：`constructor` 编译阶段建立时间索引，`resolve` 时按当前时间剪枝
- 典型收益：日均规则数从 22 条降到 5-8 条，减少 60-75% 的规则比较

#### 3.3.3 L2：维度倒排索引

**原理**：把规则按商品维度（dishUids / categories / tags）建立倒排索引，求值时按菜品属性查索引拿候选规则，不遍历全部。

```
倒排索引结构：
  dishIndex      = { dishUid → [ruleA, ruleB] }
  categoryIndex  = { categoryUid → [ruleC, ruleD] }
  tagIndex       = { tag → [ruleE, ruleF] }
  globalRules    = [ruleG, ...]   // 没有任何商品维度限制的规则（全品类）
```

- 候选规则 = `dishIndex[dishUid] ∪ categoryIndex[cat] ∪ tagIndex[...tags] ∪ globalRules`
- 非命中菜品通常只需要比对 2-5 条候选，而不是全部规则
- 典型收益：100 条规则下，单菜比较量从 100 → 3-5，加速 20-30 倍

#### 3.3.4 L3：批量求值接口 resolveBatch

**原理**：一次传入 N 个菜品，时间过滤 + 索引构建只做一次，减少重复开销。

- 适用场景：点菜页全量展示、报表批量计算、菜单同步
- 调用方式：`engine.resolveBatch(dishContexts[], globalCtx)`
- 内部实现：
  1. 一次性做时间前置过滤（只算一次）
  2. 遍历所有菜品，复用索引
  3. 输出数组，顺序与输入一致
- 典型收益：减少 80-90% 的函数调用和重复初始化开销

#### 3.3.5 L4：结果缓存（可选）

**原理**：相同输入维度下，直接返回缓存结果。

```
缓存 key 构成：
  policyVersion + timeSlot(5分钟粒度) + memberLevel + memberTagsHash + dateTagsHash
```

- 缓存粒度：整批结果（一次 resolveBatch 的全部输出）
- 缓存策略：LRU，最多 8 个条目
- 适用场景：短时间内反复打开菜单（同一桌点菜）
- 典型收益：第二次打开 0ms（直接读缓存）

#### 3.3.6 性能指标承诺

| 场景 | 规则数 | 菜品数 | 优化前 | L1+L2+L3 | L4（缓存命中） |
|---|---|---|---|---|---|
| 小店（典型） | 20 | 100 | ~0.5ms | ~0.03ms | 0ms |
| 大店 | 50 | 300 | ~5ms | ~0.2ms | 0ms |
| 极限 | 100 | 1000 | ~50ms | ~3ms | ~0.01ms |

> 硬上限：任何场景下单次调用 ≤ 5ms（满足 60fps 单帧预算）

### 3.4 引擎 API

```js
class RuleEngine {
  constructor(policyDoc, options = {}) {
    // 编译策略文档，建立时间索引 + 维度倒排索引
    // options: { enableCache: true, debugTrace: false }
  }

  // —— 单品求值（v1 兼容）——
  resolveLine(ctx) {
    return {
      dishUid: String,
      basePrice: Number,
      price: Number,              // 最终行价（钳制后）
      clamped: Boolean,           // 是否被最低折扣钳制
      clampedBy: String|null,     // 钳制原因
      beforeClamp: Number,        // 钳制前价格
      appliedRules: [             // 命中的行级规则，按施加顺序
        { ruleId, label, group, priority, actionType, actionValue, beforePrice, afterPrice, savedAmount }
      ],
      hasActivity: Boolean,       // 是否有活动（前端角标用）
      activityLabel: String|null, // 活动标签（回译器生成，展示用）
      trace: [ /* 全量轨迹 */ ],
      durationMs: Number
    }
  }

  // —— 批量求值（v2 新增，点菜页用）——
  resolveBatch(dishCtxList, globalCtx) {
    // dishCtxList: [{ dishUid, basePrice, categoryUid, tags, qty? }, ...]
    // globalCtx: { now, dateTags, memberLevel?, memberTags?, guestCount?, minRate? }
    return {
      results: [ /* 每个 dish 对应一个 resolveLine 输出 */ ],
      activityCount: Number,      // 有活动的菜品数量
      stats: {
        totalDishes: Number,
        candidateRulesPerDish: Number,  // 平均候选规则数（索引效果）
        timeFilteredRules: Number,      // 时间过滤后剩余规则数
        cacheHit: Boolean               // 是否命中缓存
      },
      durationMs: Number
    }
  }

  // —— 整单求值（v2）——
  resolveOrder(orderCtx) {
    return {
      lines: [ /* 每行 resolveLine 结果 */ ],
      orderDiscounts: [           // 整单优惠项
        { ruleId, label, actionType, amount, allocate, allocation: [{ lineIdx, amount }] }
      ],
      gifts: [                    // 赠品
        { ruleId, dishUid, qty, label }
      ],
      orderTotal: Number,         // 订单合计（行价合计 - 整单优惠 + 赠品0元）
      orderSaved: Number,         // 总共优惠金额
      trace: [ /* 全量轨迹 */ ],
      durationMs: Number
    }
  }

  // —— 缓存管理 ——
  clearCache() {}          // 清空缓存（规则变更后调用）
  getCacheStats() {}       // 获取缓存命中率统计

  // —— 校验策略文档 ——
  static validate(policyDoc) {
    return { valid: boolean, errors: [{path, message, severity}], warnings: [...] }
  }
}
```

### 3.4 v3 架构预留（设计时同步考虑，功能不实现）

#### 3.4.1 设计思想

v1→v2 是「加字段加动作」，引擎核心结构不动；v2→v3 是**量变到质变的拐点**——涉及套餐识别、组合优化、限次限购、多轮依赖、外部动作副作用等，这些都会触及引擎的核心假设（纯函数、封闭词表、单轮求值）。

**策略：架构预留，功能分期。** v3 的扩展点在 v2 引擎设计时就埋好，但具体功能等需求明确了再做。预估多花 0.5 天，避免 v3 来了推翻重写。

#### 3.4.2 五个预留扩展点

| 扩展点 | v2 怎么预留 | v3 典型用法 | 不预留的后果 |
|---|---|---|---|
| **谓词注册制** | 条件谓词不用 switch-case，用 `registerPredicate(name, handler)` 注册 | v3 加「套餐已点」「已享用次数」等新谓词，注册即用 | 加一个条件谓词就要改引擎核心代码，越改越乱 |
| **动作注册制** | 动作处理器用 `registerAction(name, handler)` 注册，不在引擎内硬编码 | v3 加「发券」「加积分」「推送消息」等副作用动作 | 动作类型多了后 switch-case 膨胀，耦合重 |
| **阶段可插拔** | 阶段用数组定义 `['line', 'clamp', 'order', 'allocate']`，支持 `registerStage(name, logic, position)` 插入新阶段 | v3 加 P0 套餐识别 / P4 后处理（发券），插进去就行 | 阶段是写死的，插不进去，要重写调度逻辑 |
| **状态注入点** | Context 之外留 `stateProvider` 可选参数，引擎只读不写，通过它查询「已享次数」「剩余库存」等 | v3 做限次限购、库存检查，传一个 stateProvider 进来 | 要改引擎签名和纯函数假设，牵一发动全身 |
| **引擎命名中性化** | 类名不叫 `PricePolicyEngine`，叫 `RuleEngine`；输出不绑定价格概念 | v3 做打印路由、推荐策略、库存策略，复用同一引擎骨架 | 类名和语义绑定价格，跨场景用的时候尴尬，不如一开始就中性 |

#### 3.4.3 预留后的引擎核心骨架（示意）

```js
class RuleEngine {
  constructor(policyDoc, options = {}) {
    this.schemaVersion = policyDoc.schemaVersion
    this.doc = policyDoc

    // 可插拔的谓词、动作、阶段
    this.predicates = {}   // name → handler(ctx, value) => boolean
    this.actions = {}      // name → handler(priceCtx, actionValue) => newPrice
    this.stages = []       // [{ name, run(ctx) }]

    // 状态注入点（v3 用），v2 为空
    this.stateProvider = options.stateProvider || null

    // 注册 v1+v2 内置谓词、动作、阶段
    this._registerBuiltins()

    // 编译（时间过滤 + 索引构建）
    this._compile()
  }

  // —— 扩展 API（v3 用）——
  registerPredicate(name, handler) { ... }
  registerAction(name, handler) { ... }
  registerStage(name, logic, position = 'after') { ... }

  // —— 求值 API ——
  resolveLine(ctx) { ... }
  resolveOrder(orderCtx) { ... }
  resolveBatch(lines, ctx) { ... }

  // —— 校验 API ——
  static validate(policyDoc) { ... }
}
```

#### 3.4.4 v3 明确不做的边界（防止范围蔓延）

以下内容 v2 阶段**只预留架构，不实现功能**，等 v3 需求明确了再做：

- 套餐组合识别算法
- 优惠组合优化求解器
- 限次限购的持久化方案
- 具体的 v3 动作类型（发券、积分等）
- 多轮求值 / 规则间依赖的具体语义

> 原则：**架构上留门，功能上关门。** 预留扩展点是为了不推翻重写，不是为了现在就把 v3 做出来。

### 3.5 v2 校验器新增规格

| 校验项 | 说明 | 级别 |
|---|---|---|
| stage 取值 | 只能是 line 或 order | 错误 |
| order stage 规则的动作 | 只能是 orderReduce / gift / 其他整单动作 | 错误 |
| line stage 规则的动作 | 不能是 orderReduce / gift | 错误 |
| bestOf.options 非空 | 至少有一个选项 | 错误 |
| bestOf 选项类型闭集 | 只能是行级动作类型 | 错误 |
| 范围对象格式 | min/max 至少有一个，min ≤ max | 错误 |
| 时间字段格式 | orderTime/openTime/closeTime 同 time 校验 | 错误 |
| order stage 规则条件 | 条件中出现 lineQty/dishUids 等行级字段告警 | 警告 |
| 同组同 stage | 同 group 的规则必须同 stage | 错误 |
| minRate 值域 | [0, 1] | 错误 |

---

## 四、回译器规格（v1 + v2）

### 4.1 设计原则（不变）

- **确定性**：相同输入 → 相同输出，纯函数
- **可读性优先**：用自然中文，不是 JSON 直译
- **与 label 交叉校验**：回译结果和 label 字段的语义必须大致吻合
- **失败可观测**：回译不出来的返回具体错误，不猜

### 4.2 v2 新增条件回译

| 条件 | 回译示例 |
|---|---|
| `memberLevel: ["gold"]` | 「**黄金会员**」 |
| `memberTags: ["birthday"]` | 「**生日当月**的会员」 |
| `lineQty: { min: 2 }` | 「**单点 2 份以上**」 |
| `orderAmount: { min: 200 }` | 「**订单满 ¥200**」 |
| `guestCount: { min: 4 }` | 「**用餐 4 人及以上**」 |
| `orderTime: [["11:00","14:00"]]` | 「**下单时间在 11:00-14:00**」 |
| `hasDish: ["dish_001"]` | 「**已点指定菜品**（水煮鱼等）」 |
| `priceRange: { min: 50 }` | 「**单价 ¥50 以上**的菜品」 |

### 4.3 v2 新增动作回译

| 动作 | 回译示例 |
|---|---|
| `bestOf` | 「享 **8.5 折 / 减 ¥8 / 固定价 ¥16.8**，取最优惠者」 |
| `orderReduce` | 「**整单立减 ¥20**（按行金额比例分摊）」 |
| `gift` | 「赠送 **椒盐花生米 1 份**」 |
| `maxQty: 1` | 「**每单限购 1 份**（超出部分恢复原价）」 |
| 钳制触发 | 「⚠ 已触发**最低 7 折**限制」 |

### 4.4 交叉校验（v1 基础上扩展）

新增关键词校验：
- 会员等级关键词（黄金/白银/普通）
- 数量/金额关键词（满 X/限 X 份）
- 人数关键词
- 赠品关键词
- 阶段关键词（行级/整单）

---

## 五、默认规则集（内置，稻香场景）

### 5.1 策略文档概览

```
门店：稻香演示店（dao_xiang_demo）
schemaVersion: "2.0"
规则数：22 条（行级 18 + 整单级 4）
覆盖场景：时段价 / 点心折扣 / 会员价 / 低价加购 / 满赠 / 优惠互斥 / 每日菜单 / 限时供应
```

### 5.2 规则清单（22 条）

#### 行级规则（line stage，18 条）

| # | 规则 ID | 名称 | 条件 | 动作 | group | priority | 覆盖字段 |
|---|---|---|---|---|---|---|---|
| 1 | r_lunch_dim_sum_90 | 午市点心9折 | 下单11-14点 + 点心类 | 9折 | time_price | 80 | orderTime, categories, discountRate |
| 2 | r_lunch_5specials | 午市5款特价16.8 | 下单11-14点 + 指定5款 | 固定价16.8 | time_price | 120 | orderTime, dishUids, fixedPrice |
| 3 | r_tea_time_dim_sum | 下午茶点心85折 | 下单14-17点 + 点心类 | 85折 | time_price | 70 | orderTime, categories, discountRate |
| 4 | r_dinner_hot_88 | 晚市热菜88折 | 下单17-21点 + 热菜类 | 88折 | time_price | 75 | orderTime, categories, discountRate |
| 5 | r_late_night_bbq | 夜宵烧烤88折 | 下单22-02点 + 烧烤类 | 88折 | time_price | 65 | orderTime(跨午夜), discountRate |
| 6 | r_weekend_cold_80 | 周末凉菜8折 | 周六日 + 凉菜类 | 8折 | daily_discount | 100 | days, categories, discountRate |
| 7 | r_workday_cold_85 | 工作日凉菜85折 | 周一五 + 凉菜类 | 85折 | daily_discount | 80 | days, categories, discountRate |
| 8 | r_holiday_fish_49 | 节假日水煮鱼特价 | dateTags含holiday + 水煮鱼 | 固定价49.9 | holiday_special | 250 | dateTags, dishUids, fixedPrice |
| 9 | r_store_anniv_78 | 店庆全场78折 | 10月28日 + 全品类 | 78折 | holiday_special | 300 | dates, discountRate |
| 10 | r_member_gold_price | 黄金会员价 | memberLevel=gold + 热菜 | 9折 | member_price | 150 | memberLevel, discountRate |
| 11 | r_member_silver_price | 白银会员价 | memberLevel=silver + 热菜 | 95折 | member_price | 120 | memberLevel, discountRate |
| 12 | r_member_birthday_85 | 生日当月特惠 | memberTags含birthday | 85折 | member_benefit | 200 | memberTags, discountRate |
| 13 | r_member_day_extra_95 | 会员日折上95折 | dateTags含member_day + 已享折扣 | 再95折 | member_benefit | 180 | dateTags, discountRate(叠在会员价上) |
| 14 | r_addon_winter_melon | 冬瓜1元加购 | 晚餐时段 + 已点指定主菜 + 人数≥2 | 加购价1元 | addon_deal | 220 | orderTime, hasDish, guestCount, fixedPrice |
| 15 | r_addon_pigeon | 一元乳鸽 | 晚餐时段 + 订单满200 + 人数≥4 | 加购价1元(限购1份) | addon_deal | 230 | orderAmount, guestCount, orderTime, maxQty |
| 16 | r_dim_sum_best_of | 点心最优价（同组取优演示） | 午市 + 指定点心 | bestOf(9折/减5元/16.8) | best_of_demo | 100 | bestOf |
| 17 | r_no_promo_exclude | 特价菜不参与 | not: 标签"特价菜" | —（条件排除演示） | — | — | not, tags |
| 18 | r_double11_disabled | 双11预热（禁用） | 11月1-10日 + 全品类 | 9折 | — | 50 | enabled=false |

#### 整单级规则（order stage，4 条）

| # | 规则 ID | 名称 | 条件 | 动作 | group | priority | 覆盖字段 |
|---|---|---|---|---|---|---|---|
| 19 | r_order_full_200_minus_20 | 满200减20 | orderAmount≥200 | orderReduce 20元 byLineAmount | order_promo | 200 | orderAmount, orderReduce |
| 20 | r_order_full_500_minus_80 | 满500减80 | orderAmount≥500 | orderReduce 80元 byLineAmount | order_promo | 250 | orderAmount, orderReduce |
| 21 | r_order_gift_peanut | 满300赠花生米 | orderAmount≥300 | gift 椒盐花生米×1 | order_gift | 180 | orderAmount, gift |
| 22 | r_order_member_gift | 会员满赠甜品 | memberLevel≥silver + orderAmount≥200 | gift 杨枝甘露×1 | order_gift | 210 | memberLevel, orderAmount, gift |

---

## 六、默认用例集（内置，稻香场景）

### 6.1 行级用例（12 个）

| # | 用例名称 | 场景描述 | 商品 | 时间 / dateTags | 会员 | 预期结果 |
|---|---|---|---|---|---|---|
| 1 | 周末中午点心9折 | 验证时段价 + 分类折扣 | 虾饺(点心, ¥38) | 周六 12:00 下单 / weekend | 非会员 | 9折 → ¥34.20 |
| 2 | 午市5款特价 | 验证同组取优（特价>折扣） | 豉汁凤爪(点心, ¥32) | 周三 12:30 下单 / workday | 非会员 | 特价16.8（priority 120 > 80） |
| 3 | 下午茶点心 | 验证多时段 | 蛋挞(点心, ¥18) | 周二 15:00 下单 / workday | 非会员 | 85折 → ¥15.30 |
| 4 | 夜宵烧烤跨午夜 | 验证跨午夜时段 | 烤羊排(烧烤, ¥98) | 周六 01:30 下单 / weekend | 非会员 | 88折 → ¥86.24 |
| 5 | 节假日水煮鱼特价 | 验证节假日固定价 | 水煮鱼(热菜, ¥88) | 国庆 12:00 / holiday,festival | 非会员 | 固定价 ¥49.90 |
| 6 | 店庆日叠加周末 | 验证跨组叠加（店庆+周末凉菜） | 凉拌黄瓜(凉菜, ¥28) | 10月28日周六 / store_anniversary,weekend | 非会员 | 先78折再8折 → ¥17.47 |
| 7 | 黄金会员热菜价 | 验证会员维度 | 宫保鸡丁(热菜, ¥48) | 周四 18:00 / workday | 黄金会员 | 9折 → ¥43.20 |
| 8 | 会员生日特惠 | 验证会员标签 | 任意热菜 ¥68 | 周五 19:00 / workday | 白银+生日月 | 生日85折 → ¥57.80 |
| 9 | 会员日折上折 | 验证折上折（2层叠加） | 热菜 ¥68 | 会员日周六 / member_day,weekend | 黄金会员 | 9折 × 95折 → ¥58.14 |
| 10 | 冬瓜1元加购 | 验证加购规则（多条件组合） | 冬瓜(加购品, ¥12) | 周六 18:30 下单 / 已点水煮鱼 / 3人 | 非会员 | 1元（hasDish + guestCount） |
| 11 | 点心取最优演示 | 验证 bestOf 动作 | 某点心 ¥42 | 周一 12:30 / workday | 非会员 | bestOf 计算 → 取最低价 |
| 12 | 最低折扣钳制 | 验证 minRate 触发 | 热菜 ¥100 | 店庆日 + 会员日 | 黄金会员+生日 | 多重叠加后被7折钳制到 ¥70 |

### 6.2 整单用例（4 个）

| # | 用例名称 | 场景描述 | 订单内容 | 总金额 | 预期结果 |
|---|---|---|---|---|---|
| 13 | 满200减20 | 验证整单满减 | 热菜×3 + 凉菜×2 | ¥268 | 减 20 元，按金额分摊 |
| 14 | 满500减80（更高档） | 验证同组取优（满减档位） | 热菜×8 + 点心×4 | ¥620 | 减 80 元（priority 250 > 200） |
| 15 | 满300赠花生米 | 验证赠品 | 热菜×4 + 凉菜×2 | ¥356 | 赠花生米×1 |
| 16 | 会员满赠甜品 + 满减 | 验证跨组叠加（赠+减） | 热菜×5 + 点心×3 | ¥456 / 白银会员 | 减 20 + 赠杨枝甘露×1 |

### 6.3 批量性能测试数据集（点菜页场景）

> 用于性能测试面板，模拟真实点菜页 100~1000 个菜的全量定价场景。

| 项 | 说明 |
|---|---|
| **模拟数据生成** | 按真实餐饮比例生成虚拟菜品：热菜 40% / 凉菜 15% / 点心 20% / 烧烤 10% / 汤品 5% / 主食 5% / 酒水 5% |
| **价格分布** | ¥8-¥168，正态分布，均值 ¥38 |
| **活动覆盖率** | 约 15-20% 的菜品有活动（符合真实场景比例） |
| **可调规模** | 10 / 50 / 100 / 300 / 500 / 1000 六个档位 |
| **输出指标** | 总耗时 / 单菜均耗时 / 候选规则数 / 加速比 / 缓存命中率 |
| **对比项** | 无优化（遍历全部规则） vs L1+L2+L3 全优化 vs 缓存命中 |

### 6.4 用例数据结构

每个用例对象包含以下字段，用于分类筛选和执行：

```js
{
  id: "case-001",
  name: "午市点心8.5折",
  description: "验证工作日午市时段点心折扣",
  type: "line",              // line / order / batch
  tags: ["时段价", "点心"],   // 用于标签筛选
  expected: "8.5折",          // 预期结果摘要，列表徽章显示
  
  // 执行输入
  context: { ... },          // 行级用例：单个 context
  // 或
  orderContext: { ... },     // 整单用例：完整订单 context
  
  // 预期断言（可选，用于批量测试）
  asserts: {
    price: 32.30,
    appliedRuleCount: 1,
    clamped: false
  }
}
```

### 6.5 Context 结构（单品行用例）

```js
{
  // 时间字段（v1 + v2）
  now: "2026-10-11T12:30:00",
  orderTime: "2026-10-11T12:05:00",
  openTime: "2026-10-11T11:50:00",
  
  // 商品字段（v1）
  dishUid: "dish_shrimp_dumpling",
  dishName: "虾饺",
  basePrice: 38.00,
  categories: ["cat_dim_sum"],
  tags: [],
  
  // 日期标签（v1，装配器传入）
  dateTags: ["weekend"],
  
  // 会员字段（v2）
  memberLevel: null,
  memberTags: [],
  
  // 数量/金额（v2）
  lineQty: 1,
  orderQty: 5,
  orderAmount: 268.00,
  guestCount: 3,
  
  // 其他（v2）
  hasDish: ["dish_fish"],   // 已点的菜品（加购判断用）
  minRate: 0.7,             // 最低折扣（钳制）
  priceRange: { min: 30 },  // 价位区间
  
  storeId: "dao_xiang_demo"
}
```

### 6.4 Order Context 结构（整单用例）

```js
{
  orderInfo: {
    orderTime: "...",
    openTime: "...",
    guestCount: 4,
    orderAmount: 456.00,
    orderQty: 12,
    memberLevel: "silver",
    memberTags: [],
    dateTags: ["workday"],
    storeId: "dao_xiang_demo"
  },
  lines: [
    { dishUid, dishName, basePrice, qty, categories, tags },
    // ...
  ]
}
```

---

## 七、文件结构

```
price-policy-demo/
│
├── index.html                  # 主入口页面
├── README.md                   # 使用说明
│
├── data/                       # 数据文件（独立配置，可修改）
│   ├── scenarios.json          # 场景配置（通用/稻香/打印/售卖时间）
│   ├── dao-xiang-policy.json   # 稻香策略文档（22条规则）
│   ├── dao-xiang-cases.json    # 稻香用例集（16个）
│   ├── dao-xiang-dishes.json   # 稻香商品目录
│   ├── default-policy.json     # 通用演示策略（v1 10条）
│   ├── default-cases.json      # 通用演示用例（10个）
│   └── dish-catalog.json       # 通用商品目录
│
├── js/                         # JavaScript 模块
│   ├── engine.js               # 价格策略引擎（v1 + v2，纯函数）
│   ├── translator.js           # 回译器（v1 + v2，纯函数）
│   ├── validator.js            # 校验器（v1 + v2，纯函数）
│   ├── scenario-manager.js     # 场景管理器（加载切换）
│   └── app.js                  # Vue 应用入口
│
├── css/
│   └── style.css               # 主样式（高对比度大按钮风格）
│
└── lib/                        # 第三方库（本地文件，无CDN）
    ├── vue/
    │   └── vue.esm-browser.prod.js
    └── codemirror/
        ├── codemirror.min.js
        ├── codemirror.min.css
        └── lang-json.min.js
```

### 模块依赖关系

```
data/*.json  ←  静态数据，可独立维护
    ↓
engine.js     →  纯函数，零依赖
validator.js  →  纯函数，零依赖
translator.js →  纯函数，零依赖
scenario-manager.js → 数据管理层
    ↓
app.js (Vue)  →  调用引擎/校验/回译/场景，渲染UI
    ↓
index.html    →  页面骨架 + 样式 + 引入
```

---

## 八、UI 设计规范

### 8.1 设计风格

- **高对比度**：深色字 / 浅色背景（或反过来，深色模式）
- **大按钮**：最小 44px 高度，圆角适中
- **紧凑布局**：信息密度高，不浪费空间
- **极简风格**：按钮无图标，纯文字
- **大字体**：正文 14px，标题 16-20px，价格数字 28-36px
- **阶段分色**：P1 行级蓝色系、P2 整单级紫色系、钳制橙红色

### 8.2 配色方案（亮色主题）

| 用途 | 颜色 |
|---|---|
| 主背景 | #FFFFFF |
| 面板背景 | #F5F7FA |
| 主文字 | #1A1A1A |
| 次要文字 | #666666 |
| 边框 | #E4E7ED |
| 主色（按钮等） | #1677FF |
| 成功绿（命中/优惠） | #52C41A |
| 警告黄（label不一致） | #FAAD14 |
| 错误红（校验失败） | #FF4D4F |
| 价格红（最终价/省了多少） | #F5222D |
| 行级阶段色 | #1677FF |
| 整单级阶段色 | #722ED1 |
| 钳制色（最低折扣） | #FA8C16 |
| 未命中灰 | #BFBFBF |

### 8.3 配色方案（深色主题）

| 用途 | 颜色 |
|---|---|
| 主背景 | #141414 |
| 面板背景 | #1F1F1F |
| 主文字 | #FFFFFF |
| 次要文字 | #8C8C8C |
| 边框 | #303030 |
| 主色 | #1677FF |
| 成功绿 | #52C41A |
| 警告黄 | #FAAD14 |
| 错误红 | #FF4D4F |
| 价格红 | #FF7875 |
| 行级阶段色 | #4096FF |
| 整单级阶段色 | #9254DE |
| 钳制色 | #FFA940 |
| 未命中灰 | #595959 |

---

## 九、开发排期（v2 版）

| 阶段 | 内容 | 预估工时 |
|---|---|---|
| **Phase 1：引擎核心 v1** | engine.js (v1) + validator.js (v1) + 单元测试 | 1.5 天 |
| **Phase 2：引擎扩展 v2** | 多时间字段 / 会员 / 数量 / bestOf / minRate / 整单级 / 多阶段 | 2 天 |
| **Phase 2.3：v3 架构预留** | 谓词注册制 / 动作注册制 / 可插拔阶段 / 状态注入点 / 引擎命名中性化 | 0.5 天 |
| **Phase 2.5：性能优化体系** | L1 时间前置过滤 + L2 维度倒排索引 + L3 resolveBatch + L4 结果缓存 + 性能测试 | 1 天 |
| **Phase 3：回译器 v1+v2** | translator.js + 交叉校验 + 单元测试 | 1.5 天 |
| **Phase 4：UI 框架** | Vue 布局 + 三栏结构 + 主题切换 + 场景管理 | 1 天 |
| **Phase 5：规则编辑** | 规则列表（筛选+分组+搜索）+ 元信息表单 + CodeMirror 集成 + 回译预览 | 2 天 |
| **Phase 6：执行与调试** | 用例筛选列表 + Context 编辑 + 分阶段结果展示 + 命中轨迹 + 整单视图 + 性能测试面板 | 2 天 |
| **Phase 7：数据与导入导出** | 场景数据加载 + localStorage + 导入导出 + 重置 | 0.5 天 |
| **Phase 8：打磨与测试** | Bug 修复 + 交互优化 + 22 条规则 + 16 个用例全验证 | 1.5 天 |
| **合计** | | **13.5 天** |

---

## 十、风险与应对

| 风险 | 影响 | 应对 |
|---|---|---|
| CodeMirror 6 本地化配置复杂 | 中 | 先做最简集成（语法高亮+错误标红），高级功能后加 |
| Vue 3 ESM 在 file:// 下有 CORS 问题 | 高 | 用 IIFE 版本或附带本地启动脚本说明 |
| v2 整单级逻辑复杂度高 | 中 | 先做行级 v2，再上整单级；整单级先做 orderReduce，再做 gift |
| 回译器对复杂组合可读性差 | 中 | 限制嵌套深度，超深时给出"条件较复杂"提示 |
| bestOf 与 group 冲突语义模糊 | 低 | 文档明确：bestOf 内部自选最优，不参与同组互斥 |
| 倒排索引构建复杂度 | 低 | 按 category/dish/tag 三维度建索引，其余走 global，80% 场景够了 |
| 批量数据生成失真 | 低 | 按真实餐饮品类比例生成，价格正态分布，确保活动覆盖率 ~15% |
| v3 范围蔓延 | 中 | 严格区分「架构预留」和「功能实现」，v3 功能一律不进 v2 排期，只留扩展点 |

---

## 十一、后续扩展方向（v3+）

| 方向 | 内容 |
|---|---|
| **可视化编辑器** | 拖拽式条件构建器，不用写 JSON |
| **多规则对比** | 两条规则并排对比差异 |
| **规则优化建议** | 检测冗余规则 / 冲突规则 / 永假规则 / 可合并规则 |
| **批量测试** | 一次跑全部用例，输出通过率报告 + 红/绿看板 |
| **策略版本管理** | 多版本策略对比与回滚 |
| **打印路由场景包** | 平移 DSL 骨架，换条件换动作，验证跨场景复用 |
| **售卖时间场景包** | available/visible 动作，电子菜牌场景 |
| **AI 生成规则接口** | 接入大模型，自然语言 → JSON 规则 → 校验 → 回译确认 |

---

*— PRD 完 —*
