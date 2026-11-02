# PricePolicyService —— 价格策略生成服务（2026-09-29）

> 店长说一句话（「周六周日热菜打 8.9 折」）→ LLM 生成 **PricePolicy JSON DSL** → 服务端解析/校验/回译/菜名容错 → 落库（**门店分库 `SysTenantExtension`**，连接串经 `DataContextFactory`）。  
> **DSL 规格单一来源** = `docs/PricePolicyDSL.md`；**提示词与话术/回译模板单一来源** = `Skills/pricepolicy/skill.md`。  
> 本服务只做「话 → JSON → 库」，**不参与下单算价**（算价是阶段 A/B 的引擎，见 DSL §12）。

---

## 1. 协议（全 service 统一规范：method + storeId 走 querystring，内容走 postContent）

```
POST http://<host>/ApiService?action=AIService.PricePolicyService&method=<方法>&storeId=<门店号>
Content-Type: application/json
```

统一响应（`HandleResult`）：`ResultCode` / `Message` / `Data`（字符串，内容是 JSON）。  
`ResultCode=0` = 服务执行完成（**不代表落库成功**——看 `Data.saved`）；`ResultCode=1` = 协议/业务错误（方法名错、storeId 缺失、uid 不存在等）。

**⚠️ 2026-09-29 方法面收敛（用户定稿）**：`generate`/`save` **已移除**（语义并入 add/update）、`set_enabled` → **`setenabled`**。方法名走 querystring `method=`；**旧方法名一律「未知方法」硬切，无别名兼容**。

| method       | body                                                  | 说明                                                                                                                                                                                       |
| ------------ | ----------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `add`        | `{text? 或 document?, name?, dryRun?, activate?}`      | **新增策略**：text = 店长原话走 LLM 生成；document = 人工 JSON 直落（两者二选一）。**全新落库、不与已有规则合并**，落库后成为该店唯一启用版（旧版自动停用）                                                                                         |
| `update`     | `{uid, text? 或 document?, name?, dryRun?, activate?}` | **修改策略**：**uid 必填**（fail-closed，先 `get`/`list` 拿 uid 再改）＝该版本即基底。text = LLM 生成 delta 后在基底上**服务侧合并 + 条件继承**；document = 人工 JSON 直落新版本行（**缺 name / 档期从基底版本继承**，想清档期就显式写 `"validFrom": null`） |
| `delete`     | `{uid}`                                               | 删除指定版本                                                                                                                                                                                   |
| `get`        | `{uid?}`                                              | 取策略详情（`uid` 缺省 = 该门店当前启用版）                                                                                                                                                               |
| `list`       | `{}`                                                  | 该门店全部版本（轻量视图，不含 document）                                                                                                                                                                |
| `setenabled` | `{uid, enabled}`                                      | 启用/停用；**启用 = 同门店其他版本自动停用**（至多一行 Enabled=1）                                                                                                                                               |

`add` / `update` 公共参数：

- `text`（与 `document` 二选一必填）：店长原话（如「周六周日热菜打 8.9 折」/「改成 8 折」）。
- `document`（与 `text` 二选一必填）：完整策略文档（对象或 JSON 字符串；`schemaVersion/storeId/revision` 由服务端权威覆盖）。
- `dryRun=true`：只生成/校验/回译，不落库（预览用；也不消耗 revision）。
- `activate`：缺省 `true`（新版本即生效，旧版自动停用）；`false` = 存为草稿（Enabled=0）。
- `name`：缺省用模型给的 name，再缺省沿用基底策略名（update）/ 第一条规则 label。

**语义分工**：`add` = 「店里新定一份策略」——与已有规则无关、整份替换为启用版；`update` = 「改店里某份策略」——必须指明改哪个 uid，在其基础上合并/继承。**两者都落新版本行**（历史版本保留，revision = MAX+1）。

**storeId 必填**（fail-closed，缺失 → `ResultCode=1` + skill 话术）：与 TakeawayOrderService 的 `RunSide=local 可缺省` 不同——价格策略没有「全部门店」语义，`storeId=0` 只会把策略静默挂到不存在的门店上。

### 1.1 专用 LLM 覆盖（2026-09-29 用户定稿「在配置文件中给出 PricePolicy 使用的 LLM，这样可以灵活替换」）

`API/appsettings.json` → `PricePolicy:LLM:Provider`：

| 值             | 行为                                                                                   |          |        |           |          |                                                                                                         |
| ------------- | ------------------------------------------------------------------------------------ | -------- | ------ | --------- | -------- | ------------------------------------------------------------------------------------------------------- |
| 空（缺省）         | 走**全局** `ProviderFactory.SharedLlm`（「所有 LLM 一个配置」默认不破，现状零变化）                         |          |        |           |          |                                                                                                         |
| `deepseek`（等） | **仅价格策略**用该 provider 的专用实例；其余服务（意图识别/点餐/预订/外卖）仍走全局 LLM。词汇表与 `LLM:Provider` 相同（\`auto | deepseek | openai | localqwen | llamacpp | simulated`），各 provider 参数读 `LLM:<名字>`子节（如`LLM:DeepSeek\` 的 ApiKey/Model/Endpoint；无 ApiKey 回退 Simulated） |

实现：`ProviderFactory.CreateLlmByName(config, name)`（引擎按名创建，业务中立——覆盖键由业务侧解析传入）+ `PricePolicyCore.PolicyLlm`（进程级 Lazy 单例，改配置后重启 API 生效）。

⚠️ 三个口径：① 专用实例**不套**全局 failover 装饰器（显存看护 / 可达性降级是 SharedLlm 专属包装——llama 挂了专用 DeepSeek 不受影响，反之亦然）；② `deepseek`/`openai` 通道**无 json_schema 语法约束**（`IJsonSchemaLlm` 仅 llamacpp 家族）——协议闸门/校验器/回译准入即为无约束通道的防线；③ DeepSeek 通道 `temperature=0.7` / `max_tokens=4096` 为 provider 内固定值。

**实测（2026-09-29 晚）**：`deepseek` 下 G1（周末分类 8.9 折）与 G2（国庆 kkk 9.9）**一次全对**——`days`/`dateTags` 这两个 1.5B 最常丢的槽位都写全，无示例粘连（对照：1.5B 同日 4 轮里丢过 days/dateTags、抄过示例菜名）；单次 652-862ms（同提示词命中 DeepSeek 上下文缓存）；日志证据 `[PricePolicy] 专用 LLM: Provider=deepseek` + `llm=DeepSeek`，同刻点餐链路仍 `LLM config: Provider=llamacpp`（隔离性实证）。⚠️ curl 命令行发中文 body 会因 git bash argv ANSI 转码乱码（DeepSeek 收到乱码诚实拒答「无法识别」，1.5B 则会幻觉）——测试务必 `--data-binary @文件`。

### 响应示例（add 成功）

```json
{"saved": true, "uid": "23b0ed76…", "name": "周末热菜折扣", "revision": 22, "enabled": true,
 "summary": "门店 182801 共 2 条规则（2 条启用）\nR-WEEKEND-HOT-89 周末热菜 8.9 折  [组 weekend · 优先级 200]\n  当：每周六或每周日 且 分类属于「热菜」\n  则：按当前价 8.9 折（× 0.89）\n\nR-ALL-9 全场9折  [组 all · 优先级 100]\n  当：每周一\n  则：按当前价 9 折（× 0.9）",
 "document": {"schemaVersion": 1, "storeId": 182801, "validFrom": null, "validTo": null, "revision": 22, "rules": [ … ]},
 "errors": [], "warnings": [], "message": "（= summary，给客户端/语音播报）"}
```

**`summary` 是权威口径**（服务端确定性回译，不是模型写的 label）——店长确认页与语音播报都用它；`errors` 非空即 `saved=false`，**旧策略原样保留**（校验失败绝不写库）。

---

## 2. 落库表：分库里的 `SysTenantExtension`

**2026-09-29 用户定稿**：「沿用 SysTenantExtension，但是放到**分库**中（测试库 `CommonCanYinSimple1813`）」+「数据库的连接**一律从 DataContextFactory 取**」。

- **放哪** = 门店**自己的业务库**（与 `BaseDish` 同库），不是 AI 中心库/AIDb。
- **连接串** = `PricePolicyStore.ConnectionStringFor(storeId)` → `DataContextFactory.GetConnectionString((int)storeId)`，  
  本服务**没有自己的连接串键**（旧的 `PricePolicy:Table:ConnectionString` 已删）。  
  RunSide=local → `ConnectionStrings:LocalDbConnectionString`；server 形态 → 中心库 `SysGroupInfoExtra` 按门店建库。  
  解析不出 → 抛（带两条排查提示），**不静默换库**。
- **⚠️ 不是**重新引入 AIExtension 框架（决策 8：2026-08-24 已整体删除，勿回退）——**只用它的表与列语义**，  
  Roslyn 动态编译 / Castle AOP / `ExtensionManager` 定时刷新一律没有，SQL 全部手写在 `PricePolicyStore`。

列映射（旧框架列语义原样沿用）：

| 列                                                                        | 存什么                                                                                       |
| ------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------- |
| `UID` varchar(40) PK                                                     | `Guid.NewGuid().ToString("N")`                                                            |
| `StoreID` int                                                            | 门店号（**每条读写都带这个过滤**，见下）                                                                    |
| `Name` nvarchar(100)                                                     | 策略名                                                                                       |
| `Summary` nvarchar(max)                                                  | **中文回译**（店长确认页看的正是它；含容错命中的「⚠️ 菜名核对」提示）                                                    |
| `Code` nvarchar(max)                                                     | 策略 JSON 全文（缩进 + 不转义中文）                                                                    |
| `Version` int                                                            | 同门店递增版本号（`MAX+1`），对外叫 `revision`                                                          |
| `Enabled` bit                                                            | 开关（**同门店至多一行 = 1**）                                                                       |
| `StartTime` / `EndTime` datetime                                         | 档期（取自 `validFrom`/`validTo`；无档期 = `1970-01-01` / `2099-12-31 23:59:59` 哨兵，对外视图映射成 `null`） |
| `TrigerType` varchar(50)                                                 | 恒 `'PricePolicy'`（旧框架 `TrigerType_PricePolicy`）                                           |
| `CodeType` int                                                           | 恒 `2`（旧框架 `CodeType_JSON`）                                                                |
| `RunSide` int                                                            | 缺省 `2`（旧框架 `Runside_Server`；仅存档语义，`PricePolicy:Table:RunSide` 可改）                         |
| `GroupID` / `Location` / `ParentUID` / `RefNamespaces` / `RefAssemblies` | 空；**`GroupID` 刻意留 0**（旧框架必填、本场景不适用；分库本身已确定归属）                                             |
| `AddTime` / `AddUser` / `UpdateTime` / `UpdateUser`                      | 审计                                                                                        |

**⚠️ 作用域是硬要求**：`SysTenantExtension` 是**共用扩展表**（同库还可能有别的 TrigerType 行，RunSide=local 下还可能混着别的门店行），  
故**每一条 SELECT/UPDATE/DELETE 都带 `StoreID=@store AND TrigerType='PricePolicy'`**；少了它会把别人的扩展一起读/改掉。

建表：旧框架 `ExtensionManager.cs` 的 DDL **逐列照抄**（仅 `text`→`nvarchar(max)`，text 已废弃、读写语义等价）+ 同名索引  
`IX_SysTenantExtension(GroupID, StoreID, CodeType, TrigerType, Location)`；`IF OBJECT_ID(...) IS NULL` 守卫 = 幂等，  
**分库里若已有旧框架那张表则一个字节都不动**。表存在性按连接串键控缓存（一进程可服务多个门店分库）。  
`PricePolicy:Table:AutoCreateTable=false` 可关掉自动建表走 DBA。

---

## 3. 处理链路（`PricePolicyCore.AddAsync` / `UpdateAsync`）

```
add / update ──► 入口校验（storeId 必填；add = text/document 二选一；update = uid 必填 + 二选一）
update ──► 取基底：Store.GetAsync(uid)（不存在/不属于该门店 → 拒收）
text ──► 组装提示词（skill.md：DSL 词表 / 生成规则 / 示例 / 输出协议 + 今天日期
     │   + [已有规则]（add 恒空；update = 基底版本 uid/修订号 + 全文）+ 门店真实分类名）
     ──► LLM（ProviderFactory.SharedLlm；有 IJsonSchemaLlm 走 json_schema 约束通道）
     ──► 解析 PricePolicyLlmOutput（supported=false → 话术返回，不落库）
     ──► 服务侧合并（update：delta 按 id / (group, Canonical(when)) / **(group, priority)** 命中 → 原地替换
     │                 + **未提到的条件维度从旧规则继承**，未提到的旧规则原样保留；add 无此步）
document ──► 人工 JSON（update 时缺 name/档期从基底继承）
     ──► 通配归一化（"全场" → 去掉商品条件）+ 空壳条件清理（"全天" → `time:[]`/`all:[]` 一律丢掉）
     ──► dishNames → dishUids（两级：精确层 → 向量容错层，见 §3.1）
     │   categories 名 → 分类 UID（见 §3.2；解析不出 → fail-closed 拒收）
     │   解析后 **`dishNames` 从文档里删掉**（只留 uid），模型写的 `dishUids` 在合并前就剥掉
     ──► 结构校验（PricePolicyValidator，闭集/数值域/交叉校验）
     ──► 回译（PricePolicyRenderer，确定性中文 + uid→分类名映射；缺模板键 → 拒绝落库）
     ──► 落库（DataContextFactory 取分库连接；新版本行 + 同门店旧版自动停用）
```

### 分工原则：**结构活归服务端，理解活归模型**

LLM 只做「一句话 → 规则体」；下面这些**一律不交给模型**（1.5B 实测做不对，见 §5）：

| 事项            | 谁做                                               | 为什么                                                                                 |
| ------------- | ------------------------------------------------ | ----------------------------------------------------------------------------------- |
| 合并已有规则        | 服务端 `MergeRules`                                 | 模型拿到全量 `[已有规则]` 也照丢（输出只剩本轮新规则 = 静默删掉店里其他优惠）                                         |
| 改写时「未提到的维度」   | 服务端 `InheritConditions`（继承旧值，见下）                 | 「周末经典冷菜改成 8 折」模型只给 `then`，条件整块丢 → 不继承就变成**全场 8 折**（静默扩大范围，比不生效更坏）                   |
| 「全场 / 全天」通配   | 服务端 `NormalizeWildcards` + `DropEmptyConditions` | 模型会写 `"categories":["all"]`（门店没这个分类）→ 规则**静默永不生效**；也会写 `"time":[]`/`"all":[]` 这类空壳键 |
| 菜名 → uid      | 服务端查知识库（**两级容错**，见 §3.1）                         | 折扣挂到模型猜的菜上 = 静默错价                                                                   |
| 分类名 → 分类 ID   | 服务端查分库 `BaseDishType`（见 §3.2）                    | 同「全场」：分类名写错/写了个本店没有的名字 = 规则静默永不生效                                                   |
| 版本/档期存储值/中文回译 | 服务端                                              | 确定性函数，无幻觉空间                                                                         |

**合并匹配键三级**（依次尝试，命中即视为「修改」而非新增）：

1. `id` 相同；
2. **(group, Canonical(when)) 完全相同**——`Canonical` 忽略空数组/空组合子键；
3. **(group, priority) 相同**——模型说「改成 X」时**不会复用原 id**（实测另起 `R-WEEKEND-CLASSIC-COLD-8`），也常把条件写残，前两级都可能落空；同组同优先级在 DSL 语义下不可能有两条独立生效的规则（同组互相取代 + 同条件高优先级恒胜），所以它**只能是修改**。

⚠️ 第 2、3 级本身都是「猜」，所以命中后一律走 **`InheritConditions`**：delta 里**非空**的条件维度覆盖旧值，**没提到的维度从旧规则继承**（`dishNames`/`dishUids` 算同一个商品维度）；命中的是第 3 级、或旧规则用了 `all/any/not` 组合子（语义无法逐字段比对）时，回译里追加 `rule.inherit_uncheckable` 提示让店长自己核对。继承/覆盖过的维度也会列出（模板键 `rule.inherit`）。

**模型写的 `dishUids` 一律剥掉**（`StripModelDishUids`，在合并**之前**执行）：模型没有 uid 可写，写出来的一律是编的（会把示例里的 uid 抄过来）；而剥除必须在继承**之前**，否则继承到的旧 uid 会被一起抹掉。

### 3.1 菜名两级解析（2026-09-29 用户：「客户表达不一定很精确，对商品名要有容错——不是精确匹配，而是要进行向量查询」）

```
dishName ──① 精确层──► KnowledgeService.product_match（name / pinyin / pinyin_initials 三层）
                │  命中且 layer 是精确层 → 直接采用（静默，无提示）
                │  ├ dish_zuofa 命中 → 挂到本体菜 match.DishUid（做法不改价，算价按本体菜取价）
                │  │                   → 回译提示 dish.resolve_zuofa
                │  └ 其余 → 采用 match.Uid
                │  ✗ layer == "llm" → 不算命中（模型猜的菜名，绝不采用；决策 4 的「llm 层命中不算命中」同口径）
                ▼
             ② 容错层（向量）──► product_search（topK=8，minScore=0 不做服务端截断）
                取「最相似」top1：必须是 productType=="dish" 且有 uid
                再取 runnerUp = **原始候选表**里第一条 uid ≠ top1 的
                ┌ 采纳条件（两条都要）：
                │    top1.Score        ≥ MinScore（缺省 0.65）
                │    top1.Score − runnerUp ≥ MinMargin（缺省 0.08）
                └ 采纳 → 采用 top1.Uid，**并强制写一条人工核对提示**（见下）
                    拒绝 → 报错进 result.Errors（不落库），文案带上最近似的候选与相似度
```

**容错命中一律带人工核对提示**（写进 `result.Warnings` + 追加到 `summary` 末尾 ⇒ 店长确认页与语音播报都看得到，模板键 `dish.resolve_soft`）：

> ⚠️ 菜名核对：「花生米」按语义理解为菜品「椒盐花生米」（相似度 0.73）——如与您说的不是同一道菜，请在此改正菜名后重新提交。

**⚠️ 两个 runnerUp 陷阱（实测踩过，勿回退）**：

1. **runnerUp 必须取自「原始候选表」**，不能先按 `productType=="dish"` 过滤再取——同一道菜的多个**做法组合点**（`dish_zuofa`，payload 带 `dish_uid`、名字是「本体名 (做法)」）会与本体菜挤在一起，过滤掉它们会让 runnerUp 掉到很远，margin 被虚高（麻婆豆腐→香椿豆腐 0.5953 就是这样混过 0.45 阈值的第一版）。
2. **检索调用必须 `minScore: 0`**——服务端截断会让「被拒」时拿不到真正的最近似候选，报错文案就没法写「最近似「香椿豆腐」（相似度 0.60）」，店长也就无从判断是打错字还是菜没启用。

**阈值标定**（`.asr-test/PricePolicy/probe-margin.py` → `probe-margin.txt`，门店 182801 / 74 point 知识库）：

| 带           | 样本                                                 | top1 相似度  |
| ----------- | -------------------------------------------------- | --------- |
| 应采纳（店长口语近似） | 花生米→椒盐花生米 / 老醋花生→云南老醋七彩花生 / 牛肉→盐帮五香牛肉 / 椒盐花生→椒盐花生米 | 0.66–0.91 |
| 应拒绝（本店没这道菜） | 宫保鸡丁 / 凉拌黄瓜 / 飞天拉面 / 麻婆豆腐                          | 0.50–0.63 |


两带只差 ~0.03，**单靠向量分不开**（"宫保鸡丁"与"黄瓜炒鸡丁"的向量距离就是比"牛肉"与"盐帮五香牛肉"近——短中文菜名以共享字/词为主信号，语义近似度不可靠）。故取**保守下限 0.65**（宁可问人、不误绑——错绑 = 静默错价，问人多一句 = 一行提示）+ **强制核对提示**兜住误采纳。两个键都可在 `API/appsettings.json` → `PricePolicy:Match` 调：

```json
"PricePolicy": { "Match": { "MinScore": 0.65, "MinMargin": 0.08 } }
```

⚠️ 换 embedding 模型或知识库规模大幅变化后**必须重跑标定**（阈值是相对量，不是绝对量）。

### 3.2 分类名 → 分类 ID（2026-09-29 用户：「不管是 category 还是 dish，都应该明确写出 id，而不是 name，这样程序才好解析」）

与菜名同性质、同口径（**只多一层包含匹配，没有向量层**——分类是短名字典，向量在这上面只会帮倒忙）：

```
分类名 ──① 已经是本店分类 ID ──► 原样保留（幂等：get 拿到的文档再喂回来不会出错）
       ──② 精确名（去空白/忽略大小写）──► 换成 ID，静默
       ──③ 包含匹配且唯一候选（「冷菜」→「经典冷菜」）──► 换成 ID + 强制核对提示（category.resolve_soft）
       ──④ 包含匹配多候选（「水饺」同时撞 大娘水饺/手工水饺/大娘水饺1..3）──► 失败：请说清楚是哪一个，不许猜
       ──⑤ 无候选 ──► 失败：报「最近似（Levenshtein）+ 可用分类列表」，店长照着改
```

- 数据源 = **门店分库 `BaseDishType`**（`StoreID=@store AND IsEnable=1`，`#` 开头的系统内部类型再挡一道——否则「规格」会包含匹配到「#规格」而静默绑错分类），连接串同样**一律经 `DataContextFactory`**；结果按连接串做进程内 **TTL 5 分钟缓存**（字典数据、低频变更）。
- **提示词里带上本店真实分类名**（上限 30 个，防分类极多的门店撑爆提示词）——模型照着抄就不会凭空发明「热菜」这种本店没有的分类；skill.md 的示例也刻意不写任何门店真实分类之外的词（示例里的分类名会被 1.5B 照抄，见 §6-5）。
- **解析不出 = 拒收，绝不落库**：分类名写错（「热莱」）或本店没启用该分类时，存中文名的后果是**规则静默永不生效**——比报错更坏（店长以为谈好了折扣、实际一单不减）。失败文案给最近似 + 可用分类，闭环比"帮它猜一个"强。
- **回译是反向映射**：渲染时注入 `uid → 分类名`（`RenderDocument(document, categoryNames)`），店长确认页看到的仍是「分类属于「经典冷菜」」——**程序解析只认 UID，人看到的是名字**，两端各取所需（DSL §13-2 由此定案）。
- **兜底救回**：菜名解析失败时先试着当分类名解一次（模型会把「经典冷菜」写进 `dishNames`，实测 G5 首轮就是），命中即挪进 `categories` 并给 `dish.moved_to_category` 提示；反之不成立（分类不会写成菜名）。
- ⚠️ **探测失败不许污染文档**（实测踩过）：早先的写法无论成不成都先建一个 `categories: []` 再填，救回失败时留下**空数组** = 恒假（该规则永不命中），校验器只能报警告、规则已经错了。现在先判谓词形态、确认命中才建节点。

---

## 4. 文件清单

| 文件                                                     | 职责                                                                                                    |
| ------------------------------------------------------ | ----------------------------------------------------------------------------------------------------- |
| `Com.AIServe.Handlers.AIService/PricePolicyService.cs` | `IServiceHandler`（action 路由 / 6 个 method（add·update·delete·get·list·setenabled）/ storeId 门控 / 详情视图）   |
| `…/Models/PricePolicyModels.cs`                        | 请求响应 DTO + `PricePolicySchemas.OutputSchema`（json_schema）                                             |
| `…/Services/PricePolicy/PricePolicyCore.cs`            | 生成/保存主流程（提示词组装、合并+条件继承、通配归一化、uid 解析、落库；**专用 LLM 单例 `PolicyLlm`** 见 §1.1）                              |
| `AgentEngine/ProviderFactory.cs`                       | `CreateLlmByName(config, name)`（2026-09-29 新增——per-service 专用 LLM 的按名创建入口，引擎保持业务中立）                   |
| `…/Services/PricePolicy/PricePolicyCategories.cs`      | 门店分类字典（分库 `BaseDishType` → 名/ID 解析，TTL 缓存；见 §3.2）                                                     |
| `…/Services/PricePolicy/PricePolicySkill.cs`           | skill 装载（`SkillLibrary.Load("pricepolicy")` + 前缀取节 + `- key: 文本` 解析）                                  |
| `…/Services/PricePolicy/PricePolicyValidator.cs`       | 结构校验（闭集 / 数值域 / 唯一性 / 交叉校验）                                                                           |
| `…/Services/PricePolicy/PricePolicyRenderer.cs`        | 确定性中文回译（准入闸门）                                                                                         |
| `…/Services/PricePolicy/PricePolicyStore.cs`           | 存储（建表 / 版本 / 启用位 / 增删查；**连接串唯一来源 = `DataContextFactory`**）                                            |
| `…/Skills/pricepolicy/skill.md`                        | **提示词 + 话术 + 回译模板单一来源**（改源文件后重建即同步 bin 副本；容错核对提示键 `dish.resolve_soft`/`dish.resolve_zuofa` 也在「回译模板」节） |
| `API/appsettings.json` → `PricePolicy:Table`           | 表名 `SysTenantExtension` / `RunSide` / 自动建表（**无连接串键**）                                                 |
| `API/appsettings.json` → `PricePolicy:Match`           | 容错阈值 `MinScore` / `MinMargin`                                                                         |
| `API/appsettings.json` → `PricePolicy:LLM`             | 专用 LLM 覆盖 `Provider`（缺省空 = 全局，见 §1.1）                                                                 |

约定：C# 侧**零硬编码提示词**（全部经 `PricePolicySkill.Keyed` 取，缺键大声告警 + 降级）；消费者按**前缀**取节（skill.md 节标题带括号注解）。

---

## 5. 验收（2026-09-29，`.asr-test/PricePolicy/`）

`bash .asr-test/PricePolicy/run-accept.sh`（S 套件，add/生命周期/协议 + update 门控与落库）+ `bash run-generate.sh`（G 套件，LLM 生成——add/update 双方法）+ `run-fuzzy.sh`（容错）。  
证据：`accept-report.txt` / `gen-report.txt` / `fuzzy-report.txt` / `probe-margin.txt` / `db-check*.txt`。

**⚠️ 2026-09-29 晚 fixture 重指向**：门店 182801 的知识库被 data_upload 测试垃圾数据覆盖（菜品变 storm -dddjfaerwae / kkk / cs1 / 3333…、分类变 点点心意 / 总部总部2 / 娃哈哈哈哈哈…、`SysTenantExtension` 里旧版本行清空），今晨口径（椒盐花生米/经典冷菜）全部失效。经用户确认「按当前数据更新 fixture」：菜名精确命中改用 **kkk**（product_match 实证 layer=name）、分类改用 **点点心意 / 粤式风味**、容错采纳对改用 **kk→kkk(0.84) / 333→3333(0.94)**、拒绝项宫保鸡丁换成毛血旺（宫保鸡丁已被容错层**正确采纳**——菜单里真有「红烧宫保鸡丁」，是数据变更后的正确行为不是缺陷）。真菜单恢复后 fixture 与 G 套件常量需再重指向。

**S 套件 16 项全过**（方法面收敛后重跑，落库全部落在分库 `CommonCanYinSimple1813.dbo.SysTenantExtension`）：S1 add 合法文档落库（两条分类名→ID 解析；ID 原样透传方向由 S14 覆盖——get 回的文档已含 ID）、S2 dishNames 含假菜名 → 拒收（kkk 正常解析 + 假名拒收）、S3 非法文档 9 项错误 + 缺回译模板键 → 拒收且不写、S4 list、S5 get（缺省启用版）、S6 dryRun 不消耗 revision、S7 未知方法、S7b **旧方法硬切**（generate/save/set_enabled → 未知方法）、S8 storeId 缺失 → no_store 话术、S9 setenabled 启用旧版 + 原启用版自动停用（断言启用行数=1）、S10 delete、S11/S12 不存在 uid → 报错、S13 **update 缺 uid / 不存在 uid / text+document 同给 → 全部 ResultCode=1 拒收**（uid 不存在 = 协议级硬拒，与 get/delete/setenabled 同模式，不是「saved=false 软失败」）、S14 **update(uid+document) 落库新版本行**（新 uid、revision=基底+1、唯一启用、列表最新行即新版本）、S14b **document 缺 name → 继承基底名；validFrom/To 显式 null → 清档期不继承**。

**G 套件 6/7**（llama.cpp / Qwen2.5-1.5B Q8_0，add/update 双方法；G6 为模型方差失败，非协议回归）：G1 add（分类 ID + days）、G4 update 追加（原规则保留 + 新规则）、G5 update 修改（(group,priority) 认成修改 + 条件继承）、G2 add（菜名→uid、dishNames 不进落库文档）、G3 不支持表达、G7 分类条件（部分词→兜底迁入路径实证 moved_to_category）全过；**G6 失败原因**：带「每周一 + 7 点到 11 点」的话术与 skill 示例「每周一上午 7 点到 11 点椒盐花生卖 3 元」同构，1.5B **必抄示例菜名「椒盐花生」**（已不在菜单，3/3 被服务端拒收 = fail-closed 正常），故 G6 裁剪为「kkk 每周一售价 3 元」后仍被抄（「每周一+3 元」语义即触发示例粘连）；时段管线已在中间轮落库实证（模型把中文数「十一点」误读成 10:00 属另一类方差）。真菜单恢复后把 G6 改回原句式即可。

⚠️ **分类解析上线后 S1/S6 的 fixture 改过**：原来用「热菜/凉菜」，本店没有这两个分类 → 现在会**拒收并列出可用分类**（这正是设计行为，见 §3.2），fixture 改成真实分类「招牌特色 / 经典冷菜」。

**分库落库取证**（`db-check.txt` / `db-check2.txt`，sqlcmd 连 `CommonCanYinSimple1813`；**下表是验收当刻的快照**，重跑套件只会追加新版本行）：

| UID       | StoreID | GroupID | RunSide | CodeType | TrigerType  | Version | Enabled | StartTime / EndTime            |
| --------- | ------- | ------- | ------- | -------- | ----------- | ------- | ------- | ------------------------------ |
| 3e41f7eb… | 182801  | 0       | 2       | 2        | PricePolicy | 2       | 0       | 1970-01-01 / 2099-12-31（无档期哨兵） |
| 29a33f8c… | 182801  | 0       | 2       | 2        | PricePolicy | 3       | 0       | 2026-10-01 / 2026-10-31（国庆档期）  |
| b8df412d… | 182801  | 0       | 2       | 2        | PricePolicy | 4       | **1**   | 同档期                            |

`Code` 757 字符 / `Summary` 373 字符（回译文本，非空）、`ParentUID`/`Location`/`RefNamespaces` 长度全 0；`Name` 中文**按 UTF-16 存对**（`0xB95B1995EF8D845F8C9A3665` = 6 个汉字，正是「容错路径验收」——`db-check.txt` 里显示的乱码是 **sqlcmd 控制台 GBK 码页**，不是库里的值）。三行版本递增、只有最新行 `Enabled=1`（与 `setenabled` 的「同门店至多一行」断言互证）。

**⚠️ 以下为上午口径（真菜单数据）的历史记录**——门店数据 2026-09-29 晚被 data_upload 垃圾数据覆盖后 fixture 已重指向，晚间结果见本节开头。

**容错套件 5 项符合设计（上午口径）**（`run-fuzzy.sh`）：

- 应采纳 2/2 —— `花生米`→椒盐花生米（0.73）、`牛肉`→盐帮五香牛肉（0.66），两条都落库成功且 `summary` 末尾各带一条「⚠️ 菜名核对」；
- 应拒绝 4/4 —— `麻婆豆腐`（最近似香椿豆腐 0.60）/`宫保鸡丁`（黄瓜炒鸡丁 0.60）/`凉拌黄瓜`（黄瓜炒鸡丁 0.63）/`飞天拉面`（飞天茅台 0.60）全部 `saved=false`，报错文案带最近似候选 + 分数，**一条都没写库**（`revision=0`）。

**G 套件 7 项全过（上午口径）**（llama.cpp / Qwen2.5-1.5B Q8_0，单次 0.4-2.1s；断言看**落库文档**）：

| #  | 店长原话                           | 结果                                                                                                                                      |
| -- | ------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------- |
| G1 | 周六周日经典冷菜打 8.9 折（add）           | `days:[sat,sun]` + `categories:["0f742fe0…"]`（**分类 ID，不是名字**）+ `rate:0.89` ✓                                                            |
| G4 | 每周一全天全场 9 折（update，基底=G1 启用版）  | 2 条：原规则逐字保留 + `{days:[mon]}`（「全天/全场」不落成空壳键）✓                                                                                            |
| G5 | 周末经典冷菜改成 8 折（update，基底=G4 启用版） | 模型另起新 id + 条件写残 → 被 **(group,priority)** 认成修改，`days`/`categories` 从旧规则**继承回来**，仍 2 条 ✓                                                  |
| G2 | 国庆节期间椒盐花生米 9 块 9（add）          | `dateTags:[holiday]` + `dishUids:02c8500…`（**`dishNames` 不出现在落库文档里**）+ `fixedPrice 9.9` ✓                                               |
| G3 | 第二份半价（add）                     | `supported=false` + 原因 + **一条规则都没生成** ✓                                                                                                 |
| G6 | 椒盐花生每周一上午 7 点到 11 点售价 3 元（add） | `days:[mon]` + `time:[["07:00","11:00"]]` + `dishUids:…` + `fixedPrice 3` ✓（回归项：曾因 `when` 无 required 把 `dishNames` 整键省掉 → 静默变成「全场 3 元」） |
| G7 | 每周六冷菜 8 折（add）                 | 包含匹配「冷菜」→「经典冷菜」（唯一候选）+ 核对提示；`categories:["0f742fe0…"]` ✓（**attempts=2**：首轮模型漏了 `days`，被 `CheckLabelWeekdays` 拦下 = fail-closed 生效，重试通过）  |

**每例最多 3 次尝试**（`run-generate.py`，attempts 打印在标题里）：1.5B 偶发漏槽位，服务侧一律 fail-closed 拒绝，重试模拟的是「店长再说一遍」——**attempts>1 是有价值的信号，不许用重试把模型的不稳定藏掉**。

---

## 6. 实测驱动的加固（勿回退）

1. **json_schema 的 `when` 必须进 required 且声明属性**——只写 `{"type":"object"}` 时 grammar 允许整键缺席，1.5B 每次生成都把最难的条件整块省掉（实测两轮 id/label/then 全对、`when` 直接没有）。同理 `unsupportedReason` 进 required 后，模型才开始给「不支持」的具体原因（此前只给一句空话术）。
2. **不确定生成 = 不许落库**：闸门看 `result.Errors` **全量**（含 uid 解析错误、回译缺键），只看校验器自己的错误列表会让「菜名没解析出来」的策略照常落库（静默丢掉菜品条件 = 错价，实测踩过）。
3. **回译缺模板键 → 拒绝落库**：缺 `dishUids.in` 时回译输出的是「当：节假日」——**看起来完整、其实漏掉了「只对某道菜生效」**。回译是店长确认页的唯一依据，漏条件必须大声失败（`PricePolicyRenderer.LastMissingKeys`）。
4. **中文编码**：`JsonNode.ToJsonString()` 默认 encoder 把非 ASCII 转义成字面 `周末`（库里存过这种行，是历史证据）——渲染/校验统一走 `Str()` 助手。
5. **示例会被 1.5B 照抄**：模型把「午市夜宵凉菜减 2 元」示例的时间窗原样挪给了「第二份半价」。故：示例节加了「数字只属于该例」声明，**输出协议置末**（recency）+ 首条即「第 0 步先判断能不能表达」。
6. **提示词模板也在 skill.md**（`## 提示词模板` 节）——Core 只做占位符替换（`PromptTpl`），与 TakeawayCore 同规矩。
7. **容错解析的 margin 必须取「原始候选表」的次名**——先按 `productType=="dish"` 过滤会剔除同族做法组合点，margin 被虚高（麻婆豆腐 0.5953 混过第一版 0.45 阈值）；且检索要 `minScore: 0`，否则拒绝文案拿不到真正的最近似候选（见 §3.1）。
8. **分库共用表的作用域过滤是硬要求**——`SysTenantExtension` 同库里可能有别的 TrigerType 行、RunSide=local 下还可能混着别的门店行，**每条 SELECT/UPDATE/DELETE 都带 `StoreID=@store AND TrigerType='PricePolicy'`**；漏了会读/改别人的扩展。
9. **本机连接串要 `lpc:`**（`Server=lpc:(local)`）——本机 SQL Server **TCP 1433 与命名管道均禁用**，只开共享内存；`Server=127.0.0.1` 会报 "Named Pipes Provider, error 40" / Win32Exception(5)。这不是本服务的特殊要求，而是 `DataContextFactory` 给出什么就用什么，本机 `ConnectionStrings:LocalDbConnectionString` 已改 `lpc:`（`CanYinCenter*` 那几条同理；GBK 控制台/`sqlcmd` 显示的乱码是码页问题、库里的值是对的，见 §5）。
10. **容错判定的边界**：只有 `productType=="dish"` 的 top1 才可能被采纳（桌台/做法组合点不能被绑成菜品），`layer=="llm"` 一律不算命中（同决策 4），且采纳必然伴随人工核对提示——**容错的安全网是人工确认，不是阈值**。
11. **空壳条件键必须丢掉**（`DropEmptyConditions`）：模型会把「全天/全场」落成 `{"time":[],"all":[]}`——**空的正条件集 = 恒假**（该规则永不命中），空组合子 = 恒真，而店长的意思两者都不是（= 不限制）。也见过 `not:{}`。「没说的维度」的正确形态是**键不存在**，不是空数组。（实测 G4 首轮两版都是空壳键 + 顺手把 `days` 丢了，被 `CheckLabelWeekdays` 拦下。）
12. **模型写的 `dishUids` 一律剥掉，且必须在合并之前剥**（`StripModelDishUids`）：模型没有 uid 可写，写出来的一律是抄示例的编造值；而剥除若放在合并**之后**，会把刚继承来的旧 uid 一起抹掉（第一版就写错了层）。剥离只动 delta，不碰 `existing`。
13. **修改路径的第三级键 =(group, priority)，命中后必须继承未提到的条件维度**：模型说「改成 X」时既不复用 id、也常把条件写残（G5 首轮只剩 `then`）——不继承就变成**全场 8 折**（扩大范围比不生效更坏）。delta 里非空的维度覆盖、未提到的从旧的继承（`dishNames`/`dishUids` 算同一维度）；旧规则含 `all/any/not` 时语义无法逐字段比对 → 不猜，改发 `rule.inherit_uncheckable` 让店长核对。
14. **`JsonNode` 只能有一个 parent**——`arr.Clear()` **不解除**子节点的 parent，就地重填必须 `JsonValue.Create(...)` 建新节点（否则抛 `The node already has a parent`，实测 G1/G7 直接 500）；而**整体换数组也不行**——`categories` 有四种谓词形态（数组 / `{in:[]}` / `{notIn:[]}` / `{all:[]}`），把 `{notIn:[…]}` 整块换成数组会**把规则反转**成「属于这些分类」。
15. **探测/兜底失败不许污染文档**：菜名救回为分类时，先判谓词形态、确认命中才建 `categories` 节点——早先写法无论成不成都先建 `categories: []`，救回失败就留下空数组（= 恒假，见 11）。

---

## 7. 未决 / 下一步

- **⚠️ CheckLabelWeekdays 的盲区（2026-09-29 晚 G4 实测暴露，修法待定）**：「每周一全天全场 9 折」偶发生成 `when:{}` 且 **label 里没有周几字样**（如「全场9折」）——现有检查按 **label** 判周几，label 没提就看不见 → 落库成「每天全场 9 折」= 静默错价（当天 G 套件 4 轮里出现 1 次，其余 3 轮模型正确写了 days）。修法候选：服务端**有请求原文**，可把原文的周几词（周[一二三四五六日天末]/星期*/周末/工作日）与最终规则集的 days 做交叉校验——但「除了周一」「周末的规则改成…」这类否定/间接说法有误报风险，口径待定（与 CheckLabelWeekdays 同族，建议同轮实施）。
- **模型对 skill 示例的粘连（2026-09-29 晚 G6 实测）**：话术与示例「每周一上午 7 点到 11 点椒盐花生卖 3 元」语义同构时，1.5B 必抄示例菜名「椒盐花生」（该菜已不在当前菜单 → 3/3 被服务端拒收，fail-closed 正常）；「每周一 + 3 元」即触发，与句式无关。真菜单恢复（或换门店）后 G6 改回原句式重跑；示例菜名随门店漂移是 skill 单一来源的固有边界（示例已声明「数字只属于该例」，但 1.5B 照抄菜名无法靠声明阻止）。
- **模型中文数字误读（同日 G6 中间轮实测）**：「七点到十一点」被 1.5B 写成 `07:00–10:00`——时间话术用数字（7点到11点）可规避。
- **⚠️ 门店 182801 数据已被 data_upload 垃圾数据覆盖（2026-09-29 晚发现，非本服务行为）**：KB 菜品变 storm -dddjfaerwae / kkk / cs1 / 3333…、分类变 点点心意 / 总部总部2 / 娃哈哈哈哈哈…、`SysTenantExtension` 旧版本行清空。fixture 与 G 套件常量已按当前数据重指向（§5）；**真菜单恢复后需回指**（save1/save2/fuzzy-* 的分类菜名、run-generate.py 的 COLD/PEANUT 与话术）。
- **阶段 A（引擎）**：本服务产出的 JSON 交给谁算价——**已落 `Com.AIServe.Handlers.Business/Pricing/`**（2026-09-30，DSL §13-4/§14.4；原独立类库 `Com.AiServe.Pricing` 方案已废）；`tags` 来源、MinZheKou 是否进引擎、摊分与行价锁定口径，见 `docs/PricePolicyDSL.md` §13（余下 3 项待确认）与 `docs/PricePolicy.md` §7。`categories` 一项**已定案 = 分类 UID**（§3.2 / DSL §13-2）。
- **分类字典的时序边界**（原「分类名合法性未校验」已闭环，见 §3.2，余下这些是新暴露的）：① 分类 uid 稳定但**名字会改**——已落库的规则存的 uid 不受影响，但回译显示的是**当前**名字（改名后历史版本的 summary 是旧名快照，不改写）；② 分类被**停用/删除**后，规则里的 uid 仍在、只是永不命中（加载期能查出「该 uid 已不在 BaseDishType」并报警，但本服务不做——属阶段 A 装配器的事）；③ 分类字典有 **5 分钟进程内缓存**，新建分类后最长滞后这么久才可被 `generate` 解析。
- **`list` 会随版本数线性增长**（一店多版本、每版都带 `Code` 全文与 `Summary`）——实测 51 个版本时响应 ~30KB，且已把验收脚本的 shell 参数撑爆（改 `@文件` 传参绕过）。门店长期使用后建议加「只返回最近 N 版 / 分页」或「清理旧版本」的口子；阈值与保留策略待用户定（**服务目前无清理方法，属新功能——按仓库惯例先出设计文档**）。
- **验收遗留版本已清（2026-09-29 用户「可以清理历史不再使用的版本内容」）**：测试库 `CommonCanYinSimple1813` 里 StoreID=182801 / TrigerType='PricePolicy' 的验收残留 **50 版 → 保留最新 2 版（rev 53/54，均 Enabled=0）**，删 48 版；操作脚本 `.asr-test/PricePolicy/cleanup-versions.sql`（事务内先 `SELECT * INTO dbo.SysTenantExtension_PricePolicyBak_20260929` 备份全部 50 行再删，`Version < MIN(最新两版)` 定界），**还原 = `INSERT INTO dbo.SysTenantExtension SELECT * FROM <bak>`**（列序一致）。保留 2 版是刻意的——`run-accept.sh` 的 S9（启用唯一性）需要列表里 ≥2 个版本，否则打印「S9 跳过：版本不足 2 条」。清后实测：`list` 响应 30KB→**1485 字节**（items=2）、`get` 无启用版时 ResultCode=1「门店 182801 当前没有启用的价格策略」（干净话术非报错）。
- **容错阈值是相对量**：`MinScore`/`MinMargin` 由本机 74 点知识库标定（§3.1），**换 embedding 模型、或门店知识库规模/菜名风格差别大时需重跑 `probe-margin.py` 重标**；现取的是保守档（宁可问人），若门店反馈「该认的没认」，先看拒绝文案里的相似度离 0.65 差多少再决定降不降。
- **容错命中的「改正后重提」闭环未接 UI**：核对提示给的是「请在此改正菜名后重新提交」，走 `update`（uid + 人工改 document 里的 `dishUids`）或重跑 `add`（把话说准）都能达成，但客户端按钮还没做。
- 权限：**不校验登录**（同 AgentService 口径），门店部署若要收紧需另加。
- 未接 UI/语音：`add`/`update` 的 `message`/`summary` 已按播报口径给全（含容错核对提示），接客户端时直接用。
