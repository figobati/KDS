# 第六部分：数据库设计

## 8. 数据库总体约定

1. **所有表主键统一 `Uid`（`uniqueidentifier`），不用复合主键**；需要"业务唯一"的，另建**业务唯一键**（唯一索引）并在文档中注明，例：`OrderTableRel (OrderId, TableId)`；
   > **两处例外（历史命名，为兼容已有引用而保留）**：`OrderHeader` 主键是 **`OrderId`**、`OrderDetail` 主键是 **`DetailId`**（这两列在全文中被高频引用，改名会波及几十处口径与接口字段）。DDL 中仍按这两列名建主键，**语义与 `Uid` 完全等价**（单列 GUID 主键）。
   > **两个"业务键列"不要误当主键（v6.95 澄清）**：`StoreConfig` 与 `TerminalConfig` 的主键都是 `Uid`；`StoreId` / `TerminalId` 是**业务唯一键**（前者被各表作门店逻辑外键引用；后者**就是 `TerminalConfig.Uid` 的语义名**，其他表的 `TerminalId` 列逻辑指向它，不另建列）。
   > 主键与业务键分工不同：**主键**回答"这一行是谁"（FK 引用、审计、事件定位），**业务键**回答"这一行代表哪一业务对象"（幂等 upsert、语义约束）。**分组键**可以等于业务键（由终端自行拼出），但**不等于主键**。
2. 字符串字段 PascalCase；枚举以 **PascalCase 字符串**存储（便于排查，不使用 int）；
3. **审计字段（所有业务表必备）**：`CreatedAt datetimeoffset`、`CreatedBy nvarchar(64)`、`UpdatedAt datetimeoffset`、`UpdatedBy nvarchar(64)`、`IsDeleted bit`（软删除，默认 0）；
4. **并发字段**：`OrderHeader.Version`、`OrderDetail.Version`（int，每次状态变更 +1），用于乐观锁；
5. 时间字段统一 `datetimeoffset`；
6. **主库（门店运行库）支持双引擎：SQLite（默认）或 SQL Server**；总部汇总库为 SQL Server。差异与抽象见 §8.2；
7. JSON 字段统一 `nvarchar(MAX)` / `TEXT`，内容为 UTF-8 JSON，结构在字段说明中给出。

### 8.1 类型映射表（SQLite ↔ SQL Server）

| 逻辑类型 | SQLite | SQL Server | C# |
|----------|--------|------------|-----|
| GUID 主键 | `TEXT`（36 字符，小写带横线） | `uniqueidentifier` | `Guid` |
| 短字符串 | `TEXT` | `nvarchar(200)` | `string` |
| 长字符串 / JSON | `TEXT` | `nvarchar(MAX)` | `string` |
| 布尔 | `INTEGER`（0/1） | `bit` | `bool` |
| 整数 | `INTEGER` | `int` | `int` |
| 小数 | `REAL` | `decimal(18,3)` | `decimal` |
| 时间 | `TEXT`（ISO 8601 带时区） | `datetimeoffset` | `DateTimeOffset` |

> ⚠️ SQLite 中 GUID **必须**统一为小写带横线格式（`D` 格式小写）写入，否则字符串比较会失配；仓储层统一转换，不依赖数据库默认值。
> ⚠️ SQL Server 的 `uniqueidentifier` **排序规则不是字符串序**（按字节分组比较），若业务要求"按 GUID 排序"，必须显式 `CAST(Uid AS nvarchar(36))` 或在应用层排序。

### 8.2 主库双引擎：SQLite / SQL Server

> **为什么主库也要能是 SQL Server**：连锁/多终端密度高的门店、已有 SQL Server 运维体系的客户、需要多进程并发写（如同时跑后台报表任务）的场景，SQLite 的单写者模型会成为瓶颈。**产品不能只支持一种引擎。**

**引擎选择与适用场景**

| 引擎 | 推荐场景 | 并发写 | 备份 | 部署 |
|------|----------|:------:|------|------|
| **SQLite（默认）** | 单店、单 Master、≤20 屏 | 单写者（WAL 下读写不互斥） | 复制文件 | 零安装，随程序目录 |
| **SQL Server** | 高并发写、多进程、已有 DBA 体系 | 多写者 | `BACKUP DATABASE` | 需实例（Express 版即可） |

> **建库与初始化不靠人手敲脚本**：**SQLite 全自动**（首次启动建库 + 迁移 + 种子）；**SQL Server 走图形化向导**（指定连接 → **12 项检测** → 自动建库或使用已有库 → 建库时自动设 `SIMPLE`/`MAXSIZE`/`RCSI`）。详见 **§13.10**（10 号文件）。

**必须抽象的三处差异（其余全部走 EF Core 统一）**

| 差异点 | SQLite | SQL Server | 抽象方式 |
|--------|--------|------------|----------|
| **归档 MOVE** | `ATTACH` + `INSERT INTO a.x SELECT …`（跨库事务在 WAL 下不原子，见 §13.6.4） | 同实例**三部分命名** `INSERT INTO ArchiveDB.dbo.OrderHeader SELECT … FROM KdsDb.dbo.OrderHeader`，**跨库事务在单实例内是原子的** | `IArchiveStore` 接口，两套实现（见下） |
| **归档只读挂载** | `ATTACH 'file:...?mode=ro'` | 独立只读库 + 只读用户，或 `RESTORE` 到只读文件组 | 同上 |
| **分页语法** | `LIMIT n OFFSET m` | `OFFSET m ROWS FETCH NEXT n ROWS ONLY` | EF Core `Skip/Take` 自动适配；原生 SQL 处统一用包装方法 |

**`IArchiveStore` 接口（两套实现，业务层不感知引擎）**

```csharp
public interface IArchiveStore
{
    Task<ArchiveVolume> OpenOrCreateAsync(string month, CancellationToken ct);   // 建卷/打开卷
    Task<MoveBatchResult> MoveBatchAsync(MoveBatchRequest req, CancellationToken ct); // 幂等写卷 + 校验
    Task SealAsync(ArchiveVolume vol, CancellationToken ct);                     // 建索引+校验+封卷
    Task<int> DeleteBatchAsync(MoveBatchRequest req, CancellationToken ct);      // 删主库（后置）
    IAsyncEnumerable<T> QueryAsync<T>(DateRange range, CancellationToken ct);     // 只读查询
}
```

| 实现 | 说明 |
|------|------|
| `SqliteArchiveStore` | MOVE = `ATTACH` + 两段事务 + 水位补偿（§13.6.4 ③）；只读 = `mode=ro` ATTACH |
| `SqlServerArchiveStore` | MOVE = **同实例跨库事务一步完成**（可真正原子，无需水位补偿，但保留水位以支持断点与审计）；卷 = 每自然月一个**归档数据库** `KdsArchive_2026_10`；只读 = 该库授权只读账号 + 连接串 `ApplicationIntent=ReadOnly` |

> **两条实现路径的取舍**：SQL Server 可以做到"移动原子"，SQLite 做不到。但**接口与补偿流程保持一致**（都用"幂等写 → 校验 → 删 → 水位"），这样上层逻辑只有一份，避免两套归档代码各长各的 bug。

**其他需注意（跨引擎通用）**

| 项 | 规则 |
|----|------|
| 枚举存储 | 统一 **PascalCase 字符串**，不用 int（两库一致，避免映射差异） |
| `datetimeoffset` | SQLite 存 ISO 8601 带 offset 文本；跨库比较与聚合在**应用层**统一换算门店时区，不依赖数据库时区函数 |
| 标识符大小写 | SQL Server 可能不区分大小写（取决于 collation），SQLite 标识符不区分；**字段名一律 PascalCase 且不得仅靠大小写区分** |
| 迁移 | 一套 EF Core Migration，**同时适用两引擎**（避免两套脚本漂移）；迁移前自动备份（§13.8） |
| 事务隔离 | SQLite 用 `BEGIN IMMEDIATE` 避免写冲突升级为死锁；SQL Server 用默认 `READ COMMITTED` + 需要时 `UPDLOCK` |

### 8.3 SQL Server 版本要求（**最低 2012；2008 暂不实现，后期再评估**）

**决策（v6.70 修订）**

| 档位 | 最低版本 | 技术路线 | 状态 |
|------|----------|----------|------|
| **A 推荐** | **SQL Server 2016** | EF Core + Dapper | ✅ **主推** |
| **B 底线** | **SQL Server 2012** | EF Core + Dapper | ✅ **支持的最低版本** |
| C 老库 | SQL Server 2008 / 2008 R2 | **保持 EF Core 10，只约束"不用 `Skip/Take`"**（§8.3.5，**+10~15%**） | ⏸️ **暂不实现；后期绕不开再评估** |
| D 门店默认 | **SQLite** | EF Core + Dapper | ✅ 默认形态，无版本问题 |
| ❌ 不支持 | SQL Server 2005 / 2000 | — | 缺 `datetimeoffset` 与 `nvarchar(max)`，技术上不可能 |

#### 8.3.1 分页语法：`OFFSET … FETCH` 干什么用、影响面有多大

**它是什么**：T-SQL 的标准分页语法，对应 EF Core 的 `.Skip(n).Take(m)`。

```sql
SELECT * FROM OrderDetail WHERE BusinessDate = @d ORDER BY DetailId
OFFSET 40 ROWS FETCH NEXT 20 ROWS ONLY;   -- 跳过 40 取 20 = 第 3 页（每页 20）
```

**在 KDS 里只用在管理端/报表，不影响热路径**

| 用处 | 是否需要它 |
|------|:----------:|
| 明细报表翻页（`/api/Admin/Reports/Details`） | ✅ |
| **【我的划单记录】**（当天几百条） | ✅ |
| Outbox 待发表列表 / 打印任务记录 / 审计日志页 | ✅ |
| **后厨屏幕数据** | ❌ **完全不用**（走内存全量推送，不分页） |

**EF Core 与它的关系（关键，这里要精确）**

EF Core 2.x 有 `UseRowNumberForPaging`，可为 SQL 2008 生成 `ROW_NUMBER()` 分页；**EF Core 3.0 移除了该选项**（[EF Core 3.x 重大变更](https://learn.microsoft.com/zh-tw/ef/core/what-is-new/ef-core-3.x/breaking-changes)、[dotnet/efcore#16400](https://github.com/dotnet/efcore/issues/16400)）。EF Core 3.0+ **固定生成 `OFFSET … FETCH NEXT`**。

> **精确表述**：`OFFSET … FETCH` **只在 LINQ 使用 `Skip()` / `Take()` 时才生成**；不用就不生成。
> 而按 §8.4 的分工，**报表查询本来就走 Dapper**——所以报表分页**根本不经过 EF Core**。
> → **结论**：2008 的语法障碍很窄，**不是"技术上不可能"**，而是下面 8.3.6 说的"约束隐形、易违约"。


#### 8.3.2 2008 缺什么、不缺什么（本设计对照）

| 本设计用到 | 引入版本 | 2008 R2 | 结论 |
|------------|:--------:|:-------:|------|
| `datetimeoffset`（全库时间字段） | 2008 | ✅ | 不缺 |
| `nvarchar(max)` | 2005 | ✅ | 不缺 |
| `ROW_NUMBER()` / CTE / 窗口函数 | 2005 | ✅ | 不缺 |
| 筛选索引 `CREATE INDEX … WHERE` | 2008 | ✅ | 不缺（三处部分索引不用改） |
| `uniqueidentifier` + `NEWSEQUENTIALID()` | 2005 | ✅ | 不缺 |
| **`OFFSET … FETCH`** | **2012** | ❌ | **唯一硬缺**，需改 `ROW_NUMBER() BETWEEN` |
| JSON / `AT TIME ZONE` | 2016 | ❌ | 不用（本项目 JSON 只在应用层解析） |
| `IIF` / `TRY_CONVERT` / `CONCAT` | 2012 | ❌ | 报表 SQL 改 `CASE` |
| `STRING_AGG` | 2017 | ❌ | 用 `FOR XML PATH` |

**关键结论**：2008 **只缺一个分页语法**，其他都够用。所以问题不在"数据库能力"，也不在"完全不可行"，而在"**约束隐形**"（见 8.3.6）。

#### 8.3.3 为什么不用「降 EF Core 到 2.x」来支持 2008

技术上成立（EF Core 2.2 的 `UseRowNumberForPaging` 正好解决分页），但**代价远大于收益**：

| # | 问题 | 具体影响 |
|:-:|------|----------|
| 1 | **EF Core 2.2 已于 2019-12 停止支持** | 永久无安全补丁；数据访问层是所有 SQL 的入口，一旦有 CVE 无法修 |
| 2 | **没有 `ExecuteUpdate` / `ExecuteDelete`**（EF Core 7 才引入） | 本设计 §8.5.2 规定"乐观锁**必须**单条 UPDATE，禁止读-改-写"→ **EF Core 2.x 做不到**，只能退回读-改-写（两次往返 + 锁竞争），或改成裸 SQL（等于放弃 EF 的价值） |
| 3 | **与 .NET 10 是"能加载但不被支持"的组合** | EF Core 2.x 目标 `netstandard2.0`，运行时能引用，但微软不测、不修、不背书；出问题只能自己扛 |
| 4 | **迁移工具链版本错配** | `dotnet-ef` 2.x 与新 SDK 冲突，需 `global.json` 锁老 SDK → **整个解决方案被迫跟着降级** |
| 5 | 缺 `AsSplitQuery`、批量 `AddRange` 性能差、`FromSql` 参数化不完善 | 报表与批量写入都要额外绕路 |
| 6 | **两个 EOL 组件叠加** | SQL Server 2008（2019-07 EOL）+ EF Core 2.2（2019-12 EOL）= **风险相乘不相消**，且都拿不到补丁 |

> **一句话**：**降 EF Core 换来的只是一个分页开关，付出的却是整套现代能力与安全基线。**

> ⚠️ **注意区分两件事**：
> 　**(a) 降 EF Core 到 2.x** —— 不可取，理由如上表。
> 　**(b) 保持 EF Core 10、只在代码里不用 `Skip/Take`** —— **是另一回事，技术上勉强可行**，详见 8.3.5 与 8.3.6。

#### 8.3.4 如果将来真遇到 2008 客户，怎么办

按优先级：

| 方案 | 说明 | 成本 |
|------|------|:----:|
| **① 门店改用 SQLite**（首选） | 门店侧本来就不需要 SQL Server——这是本设计默认形态。数据库版本问题在门店侧根本不存在 | **0** |
| **② 给 KDS 单装免费的 Express 2019/2022** | 独立实例，不动 POS；单库 10GB / 内存 1GB / 4 核，单店够用。**比改造代码划算得多** | 低 |
| ③ 升级该客户的 SQL Server 到 2012+ | 一次性投入，之后永久受益 | 低 |
| ④ 改造代码支持 2008（见 8.3.5） | **保持 EF Core 10**，只约束"不用 `Skip/Take`"，报表分页改 `ROW_NUMBER` | **+10~15%**（不是 +40%） |
| ❌ 降 EF Core 到 2.x | 见 §8.3.3，不采用 | — |

> **红线**：**不允许在主代码里出现 `if (isSql2008)` 分支**。若真要做④，必须走接口替换（`IKdsRepository` 两个实现）+ CI 守护（8.3.6），否则主路径会被老库约束拖死。

#### 8.3.5 支持 2008 的真实成本（**修正：+10~15%，不是 +40%**）

> **修正说明（v6.70）**：此前按"全量替换数据访问层为纯 Dapper"估算为 +40%，**口径错了**。真实情况是：`OFFSET/FETCH` 只影响分页，而**报表分页本来就走 Dapper**，所以不需要替换整个数据访问层。

| 工作项 | 内容 | 量级 |
|--------|------|:----:|
| ① 报表分页 SQL 改 `ROW_NUMBER()` | 约 **6~8 个查询**（明细报表、我的划单记录、Outbox 列表、打印记录、审计日志），**本来就在 Dapper 里** | 小 |
| ② **架构守护（必须）** | CI 中静态检查：`Kds.Infrastructure` 里不得出现 `.Skip(` / `.Take(`；或加自定义 Roslyn 分析器 | 中 |
| ③ 兼容性回归 | 集成测试增加"SqlServer 2008 语法白名单"校验；报表分页断言 | 中 |
| ④ 客户侧风险签字 | 2008/R2 已于 2019-07 终止扩展支持，无安全补丁；TLS 1.2 需 SP3+ 补丁 | — |

**合计约 +10~15%**，仅在该客户项目内承担。

#### 8.3.6 为什么仍建议 2012 底线（**理由已从"不可行"改为"承约束"**）

| # | 理由 |
|:-:|------|
| 1 | **约束隐形、易违约**：哪天有人写了个 `.Skip(20)`，在开发机（SQL 2019）上一切正常，**到客户 2008 现场才炸**，报错是"`OFFSET` 附近有语法错误"，排查方向容易跑偏 |
| 2 | **EOL 与合规**：SQL Server 2008/R2 无安全补丁，多数等保/合规场景过不了；出问题只能自担 |
| 3 | **性价比低**：客户若卡在 2008，**装个免费 Express 或门店用 SQLite 的成本**远低于长期维护一条隐形约束 |
| 4 | **约束会蔓延**：今天禁 `Skip/Take`，明天可能又发现某个 EF Core 生成物用到了别的 2012+ 语法，逐步变成"这个不能用、那个不能用" |

> **当前决定（v6.70）**：**维持 2012 底线，暂不实现 2008 支持。**
> **若后期某个项目确实绕不开 2008**，按 §8.3.5 的 +10~15% 方案改，并**必须同时落地 CI 守护**；届时再评估。


### 8.4 EF Core 与 Dapper 的分工（**边界必须写死**）

> **结论：EF Core 10 为主（写 + 迁移），Dapper 为辅（读 / 报表 / 批量）。**

**为什么不能只用一种**

| 只用 EF Core 的问题 | 只用 Dapper 的问题 |
|---------------------|--------------------|
| 报表聚合 SQL 复杂（多维分组 + P90 + 跨表），LINQ 表达力弱且易生成低效 SQL | **没有 Migration**——26 张表双引擎 DDL 要手工维护，必然漂移 |
| 跨库 `INSERT … SELECT`（归档 MOVE）用 LINQ 表达不了 | **没有乐观锁**——本项目的 `Version` 并发控制要手写每处 `WHERE Version=@v` |
| 大批量更新（如 `CompletedQty += q`）需 EF Core 7+ 的 `ExecuteUpdate` 才行 | **没有变更追踪**——手写 CRUD 易漏字段、易漏审计字段 |
| 启动慢（大模型构建） | 字段改名**编译期不报错**，运行期才发现 |

**分工表**

| 场景 | 用哪个 | 理由 |
|------|--------|------|
| 领域实体 CRUD（订单/明细/配置） | **EF Core** | 变更追踪 + 审计字段自动填充 + 导航属性 |
| **乐观锁并发更新**（划单、部分退菜） | **EF Core**（`ConcurrencyToken`） | `Version` 令牌原生支持，冲突自动抛 `DbUpdateConcurrencyException` |
| **Migration（双引擎）** | **EF Core** | 一套迁移同时产出 SQLite / SQL Server 差异脚本 |
| 报表查询（§13.6.7 五张明细表 + Dashboard） | **Dapper** | SQL 完全可控、可精确命中索引、无变更追踪开销 |
| **归档卷 MOVE**（跨库 `INSERT … SELECT` + 行数校验） | **Dapper** | EF Core 无法表达跨库语句 |
| 批量写入（EventLog / PrintJob / OperationLog 高频插入） | **Dapper**（或 EF Core `AddRange` 分批） | 避免逐条 `SaveChanges` |
| 统计聚合（L3 落库） | **Dapper** | 一条 `INSERT … SELECT … GROUP BY` 搞定 |
| 启动预热 / 健康检查 | **Dapper** | 只读、轻量 |

**混用的四条硬规则（不遵守必然出 bug）**

| # | 规则 | 原因 |
|:-:|------|------|
| 1 | **所有写操作走 EF Core**，除"归档 MOVE / 批量日志 / 统计落库"三类明确例外 | 否则 `Version` 乐观锁失效，多屏并发会互相覆盖 |
| 2 | **Dapper 查询必须复用 EF Core 的同一连接与事务**：`_db.Database.GetDbConnection()` + `CurrentTransaction` | 各自开连接会导致"读不到未提交数据"或死锁 |
| 3 | **禁止用 Dapper 绕过乐观锁写 `OrderDetail`** | 必须显式 `WHERE Version=@v AND ...`，且成功后手动 `Version+1`，否则状态不一致 |
| 4 | **实体与 SQL 的列名映射集中在 `DbSchema` 常量类** | 避免字段改名时 Dapper SQL 静默失配 |

> **一句话**：**写走 EF Core（保一致性），读走 Dapper（保性能），跨界只有三类明确例外。**

### 8.5 性能设计规范（**热路径不查库**）

> **最重要的一条先放在最前面**：**屏幕数据来自 Master 内存，不来自数据库。**
> 库是**持久化层**，屏是**内存层**。一次变更 → 内存投影更新 → 推送 N 块屏；**推送过程 0 次数据库查询**。
> 如果实现时图省事"每块屏收到请求就查一次库"，20 屏 × 15s 轮询 = 1.3 QPS 看着不多，但**推送放大**后（一次变更推 20 屏 × 每次查库）会立刻打满 SQLite 单写者。

#### 8.5.1 分层与查询预算

| 层 | 数据来源 | 允许查库？ | 目标耗时 |
|----|----------|:----------:|----------|
| **屏幕推送 / 增量同步** | Master 内存投影 | ❌ **禁止** | 单次推送 < 50ms |
| **屏幕全量重同步** | 内存快照（分批） | ❌ 禁止 | 300 条 < 200ms |
| **划单 / 退菜 / 撤销等写操作** | DB（EF Core） | ✅ 必须 | P95 < 100ms |
| **报表查询** | DB（Dapper） | ✅ | 单页 < 500ms |
| **日统计聚合** | DB（Dapper 单条 SQL） | ✅ | < 3s（凌晨跑） |
| **归档 MOVE** | DB（Dapper 跨库） | ✅ | 按卷，可后台 |

#### 8.5.2 EF Core 的七条性能纪律

| # | 纪律 | 原因 |
|:-:|------|------|
| 1 | 只读查询**必须** `AsNoTracking()` | 省状态快照，内存降 30~50%，大结果集尤其明显 |
| 2 | 列表查询**必须**投影到 DTO（`Select(x => new Dto{...})`），禁止加载整实体 | 少取列 = 少 IO + 少分配 |
| 3 | **禁用懒加载**（不装 `Microsoft.EntityFrameworkCore.Proxies`） | 懒加载必然 N+1，且在异步场景会抛异常 |
| 4 | 批量更新用 `ExecuteUpdate` / `ExecuteDelete` | 避免"读 300 行改 300 行再 Save" |
| 5 | **禁止在循环里 `SaveChanges`**，一次事务一次提交 | 每次 SaveChanges 一个事务 + fsync，SQLite 上尤其慢 |
| 6 | 分页**一律服务端**（`Skip/Take`），禁止 `ToList()` 后内存分页 | 内存分页在大表上等于全表拉取 |
| 7 | 动态拼接的查询用 `EF.CompileQuery` 或预定义查询；避免运行时拼 `Expression` 破坏查询缓存 | 查询缓存失效 = 每次重新编译表达式树 |

**乐观锁的正确写法（避免读-改-写）**

```csharp
// ✅ 单条 UPDATE 带 Version 条件，一次往返
var affected = await _db.OrderDetails
    .Where(d => d.DetailId == id && d.Version == expectedVersion)
    .ExecuteUpdateAsync(s => s
        .SetProperty(d => d.CompletedQty, d => d.CompletedQty + qty)
        .SetProperty(d => d.Version, d => d.Version + 1)
        .SetProperty(d => d.StatusUpdatedAt, now), ct);

if (affected == 0) throw new ConcurrencyException();  // 冲突，不是失败

// ❌ 反例：先查、再改、再 SaveChanges（多一次往返 + 中间可能被改）
```

#### 8.5.3 SQLite 专项调优（门店默认库，最需要调）

```sql
PRAGMA journal_mode = WAL;        -- 读写不互斥（关键）
PRAGMA synchronous = NORMAL;      -- WAL 下足够安全，性能好一个量级
PRAGMA busy_timeout = 5000;       -- 避免瞬时 SQLITE_BUSY 直接报错
PRAGMA cache_size = -32000;       -- 32MB 页缓存（负数=KB）
PRAGMA mmap_size = 268435456;     -- 256MB 内存映射
PRAGMA temp_store = MEMORY;       -- 临时表放内存（报表排序用）
PRAGMA foreign_keys = ON;
```

| 项 | 规则 |
|----|------|
| **单写者串行** | SQLite 同时只允许一个写事务。**所有写操作走同一个写连接 + 进程内 `SemaphoreSlim(1)`**，禁止多连接并发写（否则大量 `SQLITE_BUSY` 重试，性能雪崩） |
| **多读者并行** | WAL 下读不阻塞写。**读连接可与写连接分离**（读用独立连接池） |
| **维护窗口** | `VACUUM` / `ANALYZE` **只能在维护窗口跑**（§2.13 营业日边界后），营业中跑会锁库几十秒 |
| **页大小** | 建库时定 `page_size = 4096`（创建后不可改）；`auto_vacuum = INCREMENTAL` 需建库前设 |
| **避免大事务** | 一次事务别超过几千行；归档 MOVE 分批提交（每 5000 行一次），防 WAL 无限膨胀 |

#### 8.5.4 SQL Server 专项

| 项 | 规则 |
|----|------|
| **`READ_COMMITTED_SNAPSHOT ON`** | 读写不互斥，避免报表查询阻塞划单写入（**强烈建议开启**） |
| 连接池 | 默认已池化；Max Pool Size 按屏数 × 2 估（20 屏 → 60 足够） |
| 统计信息 | 日统计落库后 `UPDATE STATISTICS`（或开启自动更新） |
| 索引 | 报表查询验证执行计划，确认走覆盖索引（§9 已按查询路径设计） |
| 参数嗅探 | 报表参数差异大时加 `OPTION (RECOMPILE)`（仅报表，不要全库加） |

#### 8.5.5 Dapper 的纪律

| 规则 | 说明 |
|------|------|
| **必须传 `commandTimeout`** | 报表类 30s、日常 5s；不设会用默认 30s，长查询卡死连接池 |
| 参数化查询 | 一律参数化，禁止字符串拼接（注入 + 执行计划复用） |
| 多结果集用 `QueryMultiple` | 一次往返取"合计 + 明细"，别查两次 |
| 大结果集流式读 | 导出 CSV 用 `QueryUnbuffered`，避免一次全载入内存 |
| **复用 EF Core 的连接与事务** | 见 §8.4 硬规则 2 |

#### 8.5.6 性能验收指标（与 §13 的 NFR 对齐）

| 场景 | 指标 | 说明 |
|------|------|------|
| 划单响应 | **P95 < 100ms** | 含乐观锁更新 + 回执入队（不含 POS 网络） |
| 推送到达 | < 500ms | 从 Master 变更到屏显示 |
| 三视图切换 | **< 200ms** | 纯本地分组，不发请求（§3.0.3） |
| 全量重同步 | 300 条 < 2s | 含网络传输 |
| 日报查询 | 单日 < 1s | 走 `DailyStoreStat`，不扫明细 |
| 明细报表单页 | < 500ms | 走 `(BusinessDate, xxx)` 覆盖索引 |
| **并发写冲突率** | 记录并告警 | 冲突率高说明同一菜被多屏同时划，是流程问题 |

### 8.6 EF Core 落地清单（双引擎 Migration 的具体工作）

> 目标：**一套模型定义，两套迁移产物（SQLite / SqlServer），模型永不漂移。**

#### 8.6.1 工程结构

```
Kds.Infrastructure/
├── Persistence/
│   ├── KdsDbContext.cs                    # 主库上下文
│   ├── ArchiveDbContext.cs                # 归档卷上下文（同实体，不同连接串）
│   ├── KdsDbContextFactory.cs             # IDesignTimeDbContextFactory（迁移用）
│   ├── Configurations/                    # 26 个 IEntityTypeConfiguration，一表一文件
│   │   ├── OrderHeaderConfiguration.cs
│   │   ├── OrderDetailConfiguration.cs
│   │   └── ...
│   ├── Converters/                        # 值转换器
│   │   ├── LocalizedTextConverter.cs      # JSON ↔ LocalizedText
│   │   ├── EnumToStringConverter（内建）
│   │   └── GuidListConverter.cs           # 逗号分隔 Id 列表
│   ├── Interceptors/
│   │   ├── AuditSaveChangesInterceptor.cs # 自动填 CreatedAt/By、UpdatedAt/By
│   │   └── SlowQueryInterceptor.cs        # 慢查询日志（> 200ms 记 Warning）
│   └── Migrations/
│       ├── Sqlite/                        # 迁移 A（SQLite provider）
│       └── SqlServer/                     # 迁移 B（SqlServer provider）
└── Seed/
    └── SeedData.cs                        # 幂等种子（StoreConfig / 5 语音模板 / 3 打印模板）
```

#### 8.6.2 具体要做的事（九项）

| # | 工作 | 产物 | 注意点 |
|:-:|------|------|--------|
| 1 | **26 个实体类** | `Kds.Domain/Entities/*.cs` | 纯 POCO，无 EF 注解（配置全在 Fluent API） |
| 2 | **26 个 `IEntityTypeConfiguration`** | 一表一文件 | 表名、列名、类型、精度、默认值、索引、外键、筛选条件 |
| 3 | **值转换器** | `LocalizedText`、Id 列表、枚举 | **枚举统一存 PascalCase 字符串**（§8.2） |
| 4 | **并发令牌** | `OrderDetail.Version`、`OrderHeader.Version` | `IsConcurrencyToken()`；配合 §8.5.2 的单条 `ExecuteUpdate` |
| 5 | **审计拦截器** | 自动填四个审计字段 | 避免每个写操作手填遗漏 |
| 6 | **两套 Migrations** | `Migrations/Sqlite`、`Migrations/SqlServer` | **同一模型、两个 provider 各生成一套**；`--output-dir` 区分 |
| 7 | **设计时工厂** | `KdsDbContextFactory` | 迁移命令需要一个能构造 DbContext 的入口；用假连接串，不连真库 |
| 8 | **幂等种子** | `SeedData.cs` | 判断"已存在则跳过"，不用 `HasData`（Guid/时间戳每次重算会导致模型变更） |
| 9 | **验证测试** | 双引擎集成测试 | 见 8.6.3 |

#### 8.6.3 双引擎最容易踩的五个坑

| # | 坑 | 处理 |
|:-:|----|------|
| 1 | **SQLite 不支持多数 `ALTER TABLE`**（改列类型、删列、加约束） | EF Core 会自动**重建表 + 拷数据**；这意味着**改列类型在生产库上是"整表重写"**，大表要评估时长。**V1 尽量避免后期改类型** |
| 2 | **`decimal` 在 SQLite 存 TEXT** | EF Core 会警告精度丢失。**金额/数量比较一律在 SQL 里用 `CAST` 或应用层换算**，不要依赖 SQLite 的实数比较 |
| 3 | **`DateTimeOffset` 在 SQLite 存 TEXT** | 排序是字符串序——**ISO 8601 带 offset 的字符串序不等于时间序**（不同 offset 会错）。**规定：入库前统一换算成门店时区的 `DateTimeOffset`，offset 固定**，这样字符串序 = 时间序 |
| 4 | **两套迁移的模型快照必须一致** | `dotnet ef migrations has-pending-model-changes` 加进 CI；任一 provider 有未提交的模型变更就失败 |
| 5 | **筛选索引语法差异** | `HasFilter("...")` 两引擎都支持，但 SQL 片段不同（SQLite 用 `[IsDeleted] = 0`？不，SQLite 用 `IsDeleted = 0`，SQL Server 用 `[IsDeleted] = 0`）→ **按 provider 分支写**，抽到常量 |

#### 8.6.4 验收标准（可执行）

| 验收项 | 方法 | 通过标准 |
|--------|------|----------|
| **DDL 等价** | `dotnet ef migrations script -o sqlite.sql` / `-o sqlserver.sql`，与手写 `KDS-DDL-*.sql` 逐表对比 | 表 26 / 索引 63 数量一致，列名类型一致 |
| 迁移可空库跑通 | 两个空库各跑一次 `database update` | 无错误，`__EFMigrationsHistory` 有记录 |
| 幂等重跑 | 再跑一次 `database update` | **无变更、无报错** |
| 模型不漂移 | `has-pending-model-changes` | 返回"no changes" |
| 乐观锁有效 | 两线程同时更新同一 `DetailId` | 一个成功、一个抛并发异常 |
| 种子幂等 | 连跑两次种子 | 数据不重复 |
| 关键查询走索引 | SQLite `EXPLAIN QUERY PLAN` / SQL Server 执行计划 | 报表查询无 `SCAN TABLE`（全表扫） |



### 9.0 与外部 POS 的边界：**KDS 定契约，POS 来适配**

> **一句话原则：接口标准由 KDS 制定，不因任何 POS 的字段习惯而修改。** 外部 POS（或其独立适配器）负责把自己的数据翻译成 KDS 标准契约；KDS 侧不出现任何"为某个 POS 特设的字段/分支"。

**为什么是这个方向**

| 反向（POS 定标准，KDS 迁就） | 本方案（KDS 定标准，POS 适配） |
|------------------------------|-------------------------------|
| 每接一个 POS 就往 KDS 领域模型加字段 | 领域模型稳定，接 10 个 POS 也不变 |
| 屏幕渲染要判断"这个 POS 来的是桌号还是桌台 ID" | 渲染层只认 KDS DTO，无分支 |
| 升级 KDS 要回归所有 POS | 契约版本化管理，适配器各自对齐 |

**分层**

```
① 自有 POS       ──直接实现──┐
② 第三方 POS A   ──适配器 A──┤
③ 第三方 POS B   ──适配器 B──┼──► KDS 标准契约（本文 §10 定义，唯一入口）
                             │        │
                             │        ▼
                             │   Master 适配层（校验 + 幂等 + ID 落地）
                             │        ▼
                             └──► KDS 领域模型（§9 定义）
                                       ▼
                                  屏幕渲染
```

- **① 自有 POS**：直接按 §10 契约开发，零转换。
- **② / ③ 第三方 POS**：**做独立适配器**（独立进程 / 独立服务 / POS 侧插件均可），职责只有"翻译 + 重试"，不允许把第三方字段透传进 KDS。
- KDS 的 **Master 适配层只做三件事**：契约校验、幂等、外部标识落地；**不做业务妥协**。

**契约里 KDS 要求什么（POS / 适配器必须提供）**

| KDS 要求 | 落在 | 说明 |
|----------|------|------|
| 门店标识 | `StoreId` | 事件信封必填 |
| POS 订单号 | `OrderHeader.PosOrderNo` | **幂等键**（`StoreId + PosOrderNo` 唯一） |
| **桌台标识** | `DiningTable.Uid`（POS 侧可用自己的 ID） | 明细必须能指明"这条菜属于哪张桌"。翻译成 KDS 桌台由**适配器负责**，见下 |
| **是否拼桌** | `OrderHeader.IsSharedTable` | 同桌已有进行中订单时必须显式声明，否则 `TABLE_OCCUPIED` |
| 品项编码 | `DishItem.ItemCode` | 菜单通过 `Menu.Sync` 先行同步 |

**外部桌台标识怎么进 KDS（适配器职责，不是 KDS 妥协）**

1. 适配器维护 **外部桌台 ID ↔ KDS `DiningTable.Uid`** 的映射表；
2. 首次出现时调用 `DiningTable.Sync` 建立主数据（`ExternalTableId` 存外部 ID）；
3. 若适配器只能拿到桌号，则由**适配器自己**按 `TableCode` 匹配并写入映射——**这一步发生在适配器内，不发生在 KDS 内**。

> **防御性兜底（保留但不作为契约能力）**：若事件只给桌号且匹配不到，Master 仍会建一条 `DiningTable`（`IsAutoCreated = 1`）以保证**不漏单**，同时打 `Warning` 并进"待补全桌台"列表。这是**防漏单的最后一道防线**，不写入对接承诺——对接验收仍要求适配器保证桌台映射正确。

**契约版本化**

| 项 | 规则 |
|----|------|
| 版本字段 | 事件信封 `ProtocolVersion`（当前 `1.0`） |
| 向后兼容 | 新增字段 = 小版本（`1.1`），POS 忽略未知字段即可 |
| 破坏性变更 | 必须升主版本，且**提前一个版本周期并行支持**新旧两版 |
| 契约测试 | KDS 提供 **契约测试用例集**（幂等、乱序、必填校验、拼桌、联台、换桌、退菜），适配器交付前必须全过 |
| 变更权 | **契约变更由 KDS 单方面决定并公告**，不因单个 POS 的临时需求修改；个别特殊需求走适配器内部消化 |

**KDS 必须交付给对接方的东西（对接包）**

| 交付物 | 内容 | 用途 |
|--------|------|------|
| 契约文档 | 本文 §10 全量（事件、字段、必填、错误码） | 唯一依据 |
| 示例报文 | 每个 `EventType` 一份完整请求 + 回执 | 免去猜测 |
| **契约测试用例集** | 幂等重投、乱序、必填缺失、拼桌、联台、换桌、退菜、赠菜、改名 | 适配器验收门槛 |
| **POS 模拟器** | 可回放上述用例的假 POS | 无真实 POS 时也能联调 KDS |
| 错误码表 | §10.6 | 失败可定位 |

> 对接验收标准：**适配器跑通契约测试用例集全部通过**，才允许上门店试点。

## 9. 核心表清单

| # | 表名 | 用途 | 章节 |
|---|------|------|------|
| 1 | `StoreConfig` | 门店配置（流转开关等） | §9.1 |
| 2 | `TerminalConfig` | 终端屏幕配置 | §9.2 |
| 3 | `OrderHeader` | 订单主表 | §9.3 |
| 4 | `OrderDetail` | 订单明细（菜品实例） | §9.4 |
| 5 | `DishItem` | 品项基础资料 | §9.5 |
| 6 | `DishType` | 品项类型 / 品类 | §9.6 |
| 7 | `DiningTable` | 桌台主数据 | §9.7 |
| 8 | `OrderTableRel` | **订单-桌台关联**（主键 `Uid`；业务键 `(OrderId, TableId)` = 卡片分组键） | §9.8 |
| 9 | `Station` | 档口主配置（含反选三字段，见 §9.10） | §9.9 |
| 10 | `Workflow` | 品项自定义工序流程 | §9.11 |
| 11 | `OperationLog` | 操作日志 | §9.12 |
| 12 | `EventLog` | 原始事件日志 | §9.13 |
| 13 | `OutboxMessage` | 出站回执待发表 | §9.14 |
| 14 | `ScreenLangPack` | 终端语言包覆盖（可选） | §9.15 |
| 14a | `VoiceTemplate` | **语音播报模板（可编辑，场景 × 语言）** | §9.15a |
| 15 | `PrinterConfig` | 打印机配置（网络 / USB / 蓝牙） | §9.17 |
| 16 | `PrintRule` | 打印规则（阶段 × 档口 → 打印机 + 模板） | §9.18 |
| 17 | `PrintTemplate` | 打印模板（单菜 / 多菜，按语言） | §9.19 |
| 18 | `PrintJob` | 打印任务（每执行终端独立队列） | §9.20 |
| 19 | `TerminalPane` | **屏内分区（V1.1 功能预留；V1 建空表、不开配置入口）** | §9.21 |
| 20 | `DailyStoreStat` | **门店日统计（L3 统计层，永久保留）** | §9.22 |
| 21 | `DailyDimStat` | **维度日统计：档口 / 档口×阶段 / 品项 / 时段** | §9.23 |
| 22 | `ArchiveVolume` | **本地历史卷登记（L5 历史层）** | §14.1.5 |
| 23 | `OrderDetailStageLog` | **明细阶段时间线（每阶段进入/离开时刻，算前态↔后态间隔）** | §9.21a |
| 24 | `SoldOutLog` | **沽清记录**（类型/限量/原因/申请审批/营业日） | §9.15b |
| 25 | `CallLog` | **叫号记录**（桌号/渲染文本/播报结果/冷却判定） | §9.15c |
| 26 | `UserAccount` | **账号**（管理端登录账号 + 作业屏人员名单，一张表两类） | §9.15d |
| 27 | `LoginLog` | **登录日志**（成功/失败/锁定/来源 IP） | §9.15e |
| 28 | `UserSession` | **会话**（屏无感登录令牌哈希 + 终端绑定 + 撤销） | §9.15f |

### 9.1 StoreConfig 门店配置表（**全库唯一权威定义**）

> ⚠️ **单一来源约定（SSOT）**：`StoreConfig` 的**完整字段定义只在本节**。
> §13.6.5（保留与清理）与 §14.2.7（上云）只列**相关子集 + 业务理由**，**不重复定义类型与默认值**；三处冲突时**以本节为准**。

| 字段 | 类型 | 可空 | 默认 | 说明 |
|------|------|:----:|------|------|
| `Uid` | Guid | 否 | — | 主键（§8.1 统一主键） |
| `StoreId` | Guid | 否 | — | 门店业务 UID，**业务唯一键**；其余表以本列作**逻辑外键**引用（DDL 不建物理 FK） |
| `StoreCode` | nvarchar(64) | 否 | — | 门店编码（业务唯一，唯一索引） |
| `StoreName` | nvarchar(200) | 否 | — | 门店名称 |
| `EnableWorkflowState` | bit | 否 | 1 | **是否启用三态流转**（V1 默认开启） |
| `FlowMode` | Enum | 否 | `Auto` | **流转模式**：`Auto`（自动模式，**V1 实现**）/ `Manual`（手动模式，**设计保留、V2 实现**）。仅 `EnableWorkflowState=1` 时可编辑；V1 引擎遇 `Manual` 按 `Auto` 运行并记 `Warning`（§2.7 / §4.2） |
| `DefaultTotalTimeoutSeconds` | int | 否 | 1200 | **门店默认总超时（秒，默认 20 分钟）**：从**起菜**（`LastFireAt`）到**制作完成（待传菜）**的总时长阈值（§4.4.1）。任何菜品未单独配置时用它 |
| `WarnRatio` | decimal(5,2) | 否 | 0.80 | **预警比例**：预警阈值 = 超时阈值 × 本值（不单独配预警时间，避免两套数字打架） |
| `HeartbeatThresholdSeconds` | int | 否 | 60 | 终端在线判定阈值（秒），用于在线看板与离线告警 |
| `BusinessDayStartHour` | int | 否 | **6** | **营业日边界小时**（0~23，§2.13.1）。`BusinessDate(ts)` 若 `time(ts) < 本值` 则日期减 1 天；左闭右开 `[D 06:00, D+1 06:00)` |
| `MealPeriods` | nvarchar(MAX) | 是 | — | **餐段定义 JSON**（§2.13.3）：`[{"Code":"Breakfast","Start":"06:00","End":"10:30"},…]`；必须覆盖整个营业日，歇市时段显式标 `Closed` |
| `FirstBusinessDate` | date | 是 | — | **门店首个营业日**（用于报表"新店 <3 天不对比"判定，§13.6.8 ⑦） |
| `CompareDivisorMode` | Enum | 否 | `EffectiveDays` | **7 日均值分母**（§13.6.8 ②）：`EffectiveDays`（前 7 个营业日中有数据的天数）/ `FixedSeven`（严格 ÷7） |
| `CrossDayHandleMode` | Enum | 否 | `MarkOnly` | **跨营业日未完成处理**（§2.14.2）：`MarkOnly`（只标记）/ `AutoClose`（自动关闭）/ `Prompt`（生成待办清单） |
| `CrossDayAutoCloseDays` | int | 否 | 1 | `AutoClose` 模式下跨几个营业日关闭（0 = 不自动关） |
| `CrossDayPromptOnSwitch` | bit | 否 | 1 | 营业日切换时是否弹汇总提示 |
| `MaintenanceWindowStartMinute` | int | 否 | 30 | 维护窗口起点：**营业日结束后 N 分钟**开始聚合（§2.13.4） |
| `HoldPauseCounting` | bit | 否 | 1 | **已废弃（保留兼容）**：等叫改为"清零重算"（§2.16.3），不再需要"暂停/累计"开关 |
| `TreatPlacedAsFired` | bit | 否 | 1 | **POS 未推起菜时的兜底**（§2.16.3）：1 = 视为"下单即起菜"（`LastFireAt = OrderCreateTime`）；0 = 必须等 POS 明确 `Fired` 才计时 |
| `SoldOutMode` | Enum | 否 | `PosConfirm` | **沽清生效方式**（§2.18.3）：`PosConfirm`（KDS 申请 → POS 确认）/ `KdsDirect`（KDS 直接生效）/ `PosOnly`（仅 POS 可沽清） |
| `AllowKitchenCancel` | bit | 否 | 0 | **是否允许厨房屏直接退菜**（§2.18.9）。默认 0；开启后 `Item.Cancelled` 带 `Source = Kitchen`，且**退菜与沽清仍为两个独立事件，绝不隐式联动** |
| `EnableUndo` | bit | 否 | 1 | **撤销总开关**（§2.19.7）；关闭则历史仍可看但不可撤销 |
| `UndoWindowSeconds` | int | 否 | **120** | **撤销时间窗（秒）**，默认 **2 分钟**（划错通常 10 秒内发现；窗口太长时菜可能已被传菜），可调 **30~1800**；详见 §2.19.7 |
| `UndoScope` | Enum | 否 | `PerDetail` | `PerDetail`（每条明细独立判断，推荐）/ `LastActionOnly`（仅本屏最后一次可撤） |
| `UndoRequireSameOperator` | bit | 否 | 1 | 是否要求同一操作人才能撤销（共用屏可置 0） |
| `UndoPrintVoidSlip` | bit | 否 | 0 | 撤销时是否补打"作废单"（有打印的门店置 1，§2.19.5）；开启后撤销会**弹二次确认**（§2.19.9） |
| `EnableManageUndo` | bit | 否 | 0 | **允许综合屏在口令解锁后跨屏撤销**（§2.19.11，V1.1 可选，默认关） |
| `DefaultLang` | nvarchar(16) | 否 | `zh-CN` | 终端默认语言 |
| `MainLang` | nvarchar(16) | 否 | `zh-CN` | **归集主语言**：`MergeBaseName` 取值依据（§2.3.3），**与 `DefaultLang` 分开**——它决定"用哪种语言的名字做归集"，不决定显示语言 |
| **`TtsProvider`** | Enum | 否 | `Console` | **TTS 实现（门店级）**：`Console`（仅日志）/ `LocalSapi` / `Http`（云端，预留）。**v6.95 起归 `StoreConfig`**（原误置于 `TerminalConfig`）：TTS 引擎是整店一套，单屏只做开/关（`TerminalConfig.EnableVoice` / `EnableCall`） |
| **`TtsVolume`** | int | 否 | 100 | **全局播报音量**（0~100，门店级） |
| **`TtsRate`** | int | 否 | 0 | **全局语速**（-10~10，门店级） |
| **`CallCooldownSeconds`** | int | 否 | 30 | **同桌叫号冷却**（秒），防连点刷屏（门店级） |
| **`CallQuietHours`** | nvarchar(50) | 是 | — | **静音时段**，如 `14:00-17:00`；静音时仍记 `CallLog`，只是不播报 |
| **`CallAutoOnAllExpo`** | bit | 否 | 0 | **整桌全部进入 `Expo` 时自动叫号**（§3.5.2，默认关，防误报） |
| `OrderRetentionDays` | int | 否 | 90 | **主库明细保留天数**（L1，§13.6.5）；到期后**移入历史库**（非删除） |
| `OrderHeaderRetentionDays` | int | 否 | 365 | 主库订单头保留天数（L2） |
| `AutoCleanupEnabled` | bit | 否 | 1 | **归档/清理任务总开关**（0 = 门店自行处理） |
| `ArchiveEnabled` | bit | 否 | 1 | 归档开关；**关闭时禁止从主库移除任何订单数据**（只允许清日志/Outbox） |
| `StatAggregateHour` | int | 否 | 3 | T+1 预聚合执行小时 |
| `CleanupHour` | int | 否 | 4 | 清理任务执行小时 |
| `DbSizeWarnMb` | int | 否 | 2048 | DB 文件超此大小告警 |
| `LogRetentionDays` | int | 否 | **30** | **文件日志保留天数**（最小 7，§13.9.1） |
| `LogMaxTotalMb` | int | 否 | **2048** | **日志目录总容量上限**，超限从最老删 |
| `LogCompressAfterDays` | int | 否 | **7** | 超过 N 天压缩为 `.zip` 归档 |
| `CrashLogRetentionDays` | int | 否 | **90** | 崩溃日志保留天数（比常规日志长） |
| `LogLevel` | Enum | 否 | `Information` | 生产默认；调 Debug 后 **24h 自动回落** |
| `SlowQueryThresholdMs` | int | 否 | **200** | 慢查询日志阈值 |
| `DbLogWarnMb` | int | 否 | **2048** | **数据库日志（LDF / WAL）告警阈值**（§13.9.2 / §13.9.3） |
| `SqlServerRecoveryMode` | Enum | 否 | `SIMPLE` | 记录建库时设定的恢复模式，供健康检查核对；**KDS 不自动改**（§13.9.2） |
| `ScreenSessionDays` | int | 否 | **30** | **屏无感登录令牌有效期（天）**；**0 = 永久直到手动退出**（§13.11.2） |
| `ScreenTokenRotation` | bit | 否 | **1** | 每次自动登录是否轮转令牌（推荐开，旧令牌立即作废） |
| `AdminSessionIdleMinutes` | int | 否 | **30** | 管理端会话闲置超时（分钟，5~120，滑动续期） |
| `AdminSessionAbsoluteHours` | int | 否 | **12** | 管理端会话绝对上限（小时） |
| `AllowScreenPinLogin` | bit | 否 | **1** | 屏账号允许 **4~6 位纯数字 PIN**（关闭则要求 ≥8 位含字母） |
| `LoginLockoutCount` | int | 否 | **5** | 连续失败几次锁定（0 = 不锁） |
| `LoginLockoutMinutes` | int | 否 | **15** | 锁定时长（分钟） |
| `PasswordMinLength` | int | 否 | **8** | 密码最小长度（8~32；PIN 模式单独按 4~6 校验） |
| `PasswordRequireComplex` | bit | 否 | **1** | 是否要求字母 + 数字（PIN 模式跳过） |
| `StaffSource` | Enum | 否 | **`Local`** | 员工维护模式（§13.11.11）：`Local` / `Pos` / `PosWithLocalExtra` |
| **`PosRoleMapJson`** | nvarchar(MAX) | 是 | — | **POS 角色 → KDS 角色映射** JSON，如 `{"厨师":"Operator","店长":"Owner"}`；未映射的角色不同步 |
| `PosStaffSyncIntervalMinutes` | int | 否 | **60** | POS 员工同步兜底拉取间隔（分钟，0 = 只靠推送） |
| `HqUploadEnabled` | bit | 否 | 0 | **上云开关**（§14.1）：0 = 纯本地部署 |
| `HqUploadScope` | Enum | 否 | `StatOnly` | 上报档位：`StatOnly`（仅聚合 L3）/ `StatAndDetail`（+明细）/ `StatAndArchiveFile`（+归档卷） |
| `LocalHistoryMode` | Enum | 否 | `MoveToArchive` | 本地保留模式（§14.1.3）：`MoveToArchive`（默认，历史卷永久）/ `MoveAndDeleteAfterUpload` / `DeleteAfterUpload` |
| `LocalBufferDaysAfterUpload` | int | 否 | 30 | 上传成功后再保留天数（仅 Delete 类模式生效） |
| `HqEndpoint` | nvarchar(500) | 是 | — | 云端基址（§14.2.7），如 `https://hq.example.com/kds` |
| `HqStoreToken` | nvarchar(500) | 是 | — | 门店密钥，**加密存储**（DPAPI / AES），配置快照导出时剔除 |
| `HqApiVersion` | int | 否 | 1 | 上报契约版本 |
| `HqBatchSize` | int | 否 | 500 | 每批记录数，实际取 `min(本值, 云端 MaxBatchRecords)` |
| `HqTimeoutSeconds` | int | 否 | 30 | 单请求超时（秒） |
| `HqCompress` | bit | 否 | 1 | 是否 gzip 压缩 |
| `HqRetryMaxCount` | int | 否 | 10 | 上报重试上限（与 Outbox 一致） |
| `HqUploadIntervalMinutes` | int | 否 | 5 | 订单增量上报间隔（分钟） |
| `HqInsecureTransportAllowed` | bit | 否 | 0 | 允许明文 HTTP（仅内网/VPN，开启即健康检查告警 `INSECURE_TRANSPORT`） |
| `PollingIntervalSeconds` | int | 否 | 15 | **本机轮询间隔（秒）**，客户端实际间隔 × (0.8~1.2) 抖动（§2.10） |
| `PushSilenceSeconds` | int | 否 | 30 | **推送静默看门狗**：超过此时长未收到推送即触发一次轻量轮询（§2.10.2） |
| `DataStaleSeconds` | int | 否 | 90 | **数据滞后阈值**：超过此时长无权威数据到达，界面挂"数据可能滞后"提示条（§2.10.2） |
| `RevisionHistorySize` | int | 否 | 300 | Master 保留的 Revision 变更集数量；超出窗口的客户端强制全量（§2.10.4） |

### 9.2 TerminalConfig 终端屏幕配置表

| 字段 | 类型 | 可空 | 默认 | 说明 |
|------|------|:----:|------|------|
| `Uid` | Guid | 否 | — | **主键（§8.1）**；**业务语义名 = `TerminalId`（屏幕唯一标识）**。其他表的 `TerminalId` 列（`ScreenLangPack` / `TerminalPane` / `OperationLog` / `UserSession` / `PrintJob.ExecutorTerminalId`）**逻辑外键均指向本列**，故 `TerminalConfig.TerminalId` 与 `TerminalConfig.Uid` 指同一列，不另建列 |
| `StoreId` | Guid | 否 | — | 门店 UID，关联 `StoreConfig` |
| `TerminalCode` | nvarchar(64) | 否 | — | 终端编码（门店内唯一，用于绑定与排查） |
| `TerminalName` | nvarchar(200) | 否 | — | 屏幕名称（综合屏 / 切配屏1 / 制作屏2） |
| `TerminalType` | Enum | 否 | `Station` | `Station`（档口屏） / `Composite`（综合屏） |
| `Role` | Enum | 是 | — | `Prep` / `Cook` / `Expo`；综合屏可为空（跨角色） |
| `StationIds` | nvarchar(MAX) | 是 | — | 绑定档口 GUID 逗号分隔（统一补前后逗号 `,a,b,`） |
| `BaseGroupMode` | Enum | 否 | `TableMode` | **基础分组模式（配置页二选一，屏幕端不可改）**：`TableMode`（桌台）/ `OrderMode`（订单，V2 预留，V1 不可选） |
| `DefaultView` | Enum | 否 | `BaseGroupView` | **首次启动默认视图**：`BaseGroupView`（基础分组）/ `MergeMode`（合菜）/ `SingleMode`（单菜） |
| `LastActiveView` | Enum | 是 | — | **上次所在视图**（终端上报，便于运维排查与重启恢复参考；终端侧亦本地持久化） |
| `ItemView_DetailMode` | Enum | 否 | `SinglePortion` | **合菜视图**右侧明细策略：`SinglePortion` / `TableGroup` |
| `ItemView_SortMode` | Enum | 否 | `TableFirst` | **合菜视图**明细排序：`TableFirst`（桌台优先）/ `WaitDuration` |
| `SingleView_SortMode` | Enum | 否 | `WaitDuration` | **单菜视图**排序：`WaitDuration`（等待时长倒序，默认）/ `TableOrder`（按桌台排序号） |
| `SingleView_HideCancelled` | bit | 否 | 0 | **单菜视图**是否隐藏退菜行（默认显示，置红删除线） |
| `TableView_SortMode` | Enum | 否 | `TableOrder` | **桌台 / 订单视图**排序：`TableOrder`（按桌台排序号，默认）/ `WaitDuration` |
| **`SearchBumpWholeTable`** | bit | 否 | **0** | 搜索框索引划单。**必为两步确认**：回车只定位选中该桌卡，再回车或点【划菜】才执行（§17.6）。一次输入绝不直接改数据 |
| **`DisplayStyle`** | Enum | 否 | `DishSummary` | **主界面显示样式**（屏端设置页）：`DishSummary` 菜品汇总 / `SingleShow` 单品显示 / `SingleSplit` 单品拆分 / `MergedKeepTaste` **菜品合并（不同做法口味不合并）**。⚠️ **V1 只存值不驱动视图**（视图仍由 `ActiveView` 决定），两者关系留 V2 |
| **`DishColumns`** | int | 否 | **8** | **桌台模式整屏列数**（2~12）；与 `DishRows` 共同决定每格尺寸，**铺满整屏不滚动**（§17.1） |
| **`DishRows`** | int | 否 | **6** | **桌台模式整屏行数**（1~10） |
| **`FixDishPosition`** | bit | 否 | 0 | **菜品位置是否固定**：1 = 新菜到达不重排（位置稳定，便于师傅形成肌肉记忆） |
| **`FontScale`** | Enum | 否 | **`M`** | **字号三级**：`S`（菜名 24px）/ **`M`（28px，默认）** / `L`（**32px，上限**）；**不开放任意像素值、不设超大档**——菜名 ≤32px、桌号 ≤40px 为硬上限（§17.1） |
| **`OrderColumns`** | int | 否 | **2** | **订单模式整屏列数**（2~12），附建议值提示 |
| **`OrderRows`** | int | 否 | **2** | **订单模式整屏行数**（1~10） |
| **`CardSize`** | Enum | 否 | `S` | **订单模式卡片大小**：`S` / `M` / `L`（影响内边距与菜名行数，与 `FontScale` 独立） |
| **`DishSortMode`** | Enum | 否 | `OrderSeq` | **品项显示顺序**（桌台/订单模式共用）：`OrderSeq` **下单顺序** / `ItemTypeSeq` **品项类型顺序**（先按 `DishType.SortOrder`，再按下单时间） |
| **`ShowCompleted`** | bit | 否 | 1 | 是否显示已划明细 |
| **`ConfirmWholeTable`** | bit | 否 | **1** | 整桌划是否弹框提示 |
| **`HoldFireCountdown`** | bit | 否 | 0 | 等叫桌台**叫起计时**（等叫期间是否继续累计） |
| **`CallRepeatCount`** | int | 否 | 1 | 叫号**重复播报次数**（1~5） |
| **`SndNewOrder`** | bit | 否 | 1 | 新订单提示音 |
| **`SndFire`** | bit | 否 | 1 | 起菜提示音 |
| **`SndRemind`** | bit | 否 | 1 | 催菜提示音 |
| **`SndBumpSuccess`** | bit | 否 | 1 | 划单成功提示音 |
| **`SndCall`** | bit | 否 | 1 | 取餐叫号提示音 |
| **`PrintItemSlipOnBump`** | bit | 否 | 0 | **划单时打印制作单**（等价于 `PrintRule.Trigger = OnStageComplete` 的快捷开关） |
| `EnableOperate` | bit | 否 | 1 | 屏幕是否允许划单（**综合屏默认 false**） |
| `IsEnabled` | bit | 否 | 1 | **终端是否启用**（配置权威在 Master，§5.1）。置 0 后拒绝连接并提示"本终端已被停用"，用于撤场 / 换机时不误接单 |
| `EnablePrint` | bit | 否 | 0 | **是否允许本终端执行打印任务**（USB / 蓝牙打印机）。**浏览器终端默认 false**，需原生端或本地打印代理（§16.2） |
| `EnableReprint` | bit | 否 | 0 | 是否允许在本屏**补打**（综合屏默认 false） |
| `PrintPriority` | int | 否 | 0 | 同档口多台本地打印机时，选执行终端的优先级（大者优先，默认按 `TerminalId` 升序兜底） |
| `StaffName` | nvarchar(64) | 是 | — | **送单人 / 操作员**（打印票样"送单人"字段来源；为空时回退终端名，§16.4.1） |
| `PaneLayout` | Enum | 否 | `Single` | **分屏布局（V1.1 功能预留）**：`Single` / `Split2` / `Split3`；**V1 恒为 `Single` 且无配置入口**（§9.21）；非 `Single` 时锁定 `ActiveView = SingleMode`（§3.7） |
| `Merge_DiffOrder` | bit | 否 | 1 | 合并条件①：不同订单合并 |
| `Merge_DiffFlavor` | bit | 否 | 1 | 合并条件②：不同口味 / 做法合并 |
| `Merge_DineInTakeaway` | bit | 否 | 1 | 合并条件③：堂食外卖合并 |
| `Merge_ComboAndNormal` | bit | 否 | 1 | 合并条件④：套餐品项与普通菜合并 |
| `Merge_Timeout` | bit | 否 | 1 | 合并条件⑤：超时菜与未超时菜合并 |
| `Merge_Rush` | bit | 否 | 1 | 合并条件⑥：催菜 / 加急与正常菜合并 |
| `Merge_Hold` | bit | 否 | 1 | 合并条件⑦：等叫菜与正常菜合并 |
| `Merge_LinkedTable` | bit | 否 | **0** | **联台组卡**：是否把多桌订单合并成一张卡（仅桌台视图生效，§3.1.4） |
| `Merge_LinkedTable_CrossArea` | bit | 否 | **0** | 跨区域联台是否合并；关闭时按 `AreaName` 各自成组卡（仅上一开关为 1 时有效） |
| `EnableVoice` | bit | 否 | 1 | 是否开启语音播报（综合屏默认 false） |
| `EnableCall` | bit | 否 | 1 | 是否显示【叫号】按钮（§3.5.2；无 TTS 时仍可作视觉提示） |
| `CurrentLang` | nvarchar(16) | 否 | `zh-CN` | 当前语言（单屏独立） |
| `PageSize` | int | 否 | 12 | 卡片分页大小 |
| `DeviceKey` | nvarchar(128) | 是 | — | 设备密钥（终端鉴权，见 §10.5） |
| **`AppliedConfigVersion`** | int | 否 | 0 | **终端已应用的配置版本**（终端上报；Master 比对 `ConfigVersion` 判断该屏配置是否过期，过期则下发全量配置，§2.10.4） |
| `ConfigVersion` | int | 否 | 1 | 配置版本号，变更时递增，终端据此重载配置 |

> **不落库的运行时状态（§5.1 铁律）**：`LastAppliedRevision`（终端已应用的数据 `Revision`）与 `LastHeartbeatAt`（最后心跳）**均不入库**——它们属"运行时状态 → 终端本地 / Master 内存"，高频刷新写库会拖垮 SQLite 单写者。在线看板与离线告警由 Master 内存字典维护，进程重启后由首轮心跳重建。`ConfigVersion` / `AppliedConfigVersion` 例外落库：它们是**低频**握手字段，用于断线重连后判定配置是否需重推。
>
> **约束**：`TerminalType = Composite` 时 `EnableOperate` 默认 0；`BaseGroupMode` 只在管理端可改（改后递增 `ConfigVersion`），`ActiveView` 由屏幕运行时切换且**不递增 `ConfigVersion`**；7 个 `Merge_*` 开关仅在**合菜视图**中生效（其余视图不读取，但保留存储）；`Role` 为空的终端按绑定的 `StationIds` 取并集展示。

### 9.3 OrderHeader 订单主表（POS 推送订单头部）

| 字段 | 类型 | 可空 | 默认 | 说明 |
|------|------|:----:|------|------|
| `OrderId` | Guid | 否 | — | **KDS 内部订单唯一 ID，主键；也是订单视图的分组键** |
| `PosOrderNo` | nvarchar(64) | 否 | — | POS 原始订单号（外部业务单号），与 `StoreId` 组唯一索引 |
| `StoreId` | Guid | 否 | — | 门店 UID，关联 `StoreConfig` |
| `TableUids` | nvarchar(MAX) | 是 | — | **冗余投影**：本订单涉及的桌台 UID 列表（GUID 逗号分隔），由 `OrderTableRel` 同步维护。**仅用于订单详情展示与整单操作，不参与卡片分组**（分组键是业务键 `(OrderId, TableId)`） |
| ~~`TableNo`~~ | — | — | — | **不落库（v6.95）**：桌号显示值由 `OrderTableRel` + `DiningTable` **运行时拼装**（联台为逗号拼接 `A05,A06`），避免快照与主数据不一致；**不参与分组** |
| `OrderType` | Enum | 否 | `DineIn` | `DineIn`（堂食）/ `Takeaway`（外卖）/ `Banquet`（宴会，V2） |
| `GuestCount` | int | 是 | — | 用餐人数（外卖为空） |
| `OrderCreateTime` | datetimeoffset | 否 | — | POS 下单时间，**仅用于排序**（计时以 Master 时钟为准，见 §4.4.1） |
| `OrderStatus` | Enum | 否 | `Normal` | `Normal`（正常）/ `PartlyCancelled`（部分退）/ `AllCancelled`（全退）/ `Archived`（归档） |
| `Remark` | nvarchar(MAX) | 是 | — | 订单备注（LocalizedText JSON，见 §9.16） |
| `PosSource` | nvarchar(64) | 是 | — | POS 来源标识 |
| `IsHeld` | bit | 否 | 0 | 是否等叫（Hold）状态（§4.4.1-4） |
| `IsSharedTable` | bit | 否 | 0 | **是否为拼桌单**（POS 声明）。同桌已有进行中订单时，只有该标记为 1 才允许再建 `OrderTableRel`，否则返回 `TABLE_OCCUPIED`（§10.7） |
| **`ReceivedAt`** | datetimeoffset | 否 | — | **Master 接收时刻**（计时与 SLO 基准；与 POS 的 `OrderCreateTime` 区分，§4.4.1） |
| **`CompletedAt`** | datetimeoffset | 是 | — | **整单完成时刻**（全部明细到 `Completed` 或清理关闭时写入） |
| **`BusinessDate`** | date | 否 | — | **营业日快照**（§2.13.1）：入库时按 `BusinessDate(OrderCreateTime)` 计算，**永不重算**；报表 / 归档 / "今日" 一律以此为准 |
| **`MealPeriod`** | Enum | 是 | — | **餐段快照**（§2.13.3）：`Breakfast` / `Lunch` / `Dinner` / `LateNight` / `Closed`；与 `BusinessDate` 同源同快照 |
| `Version` | int | 否 | 0 | **版本号，乐观锁**，订单变更递增 |
| **`HqUploadedAt`** | datetimeoffset | 是 | — | **上云回执时刻**（§14.1.2）；空 = 待上传，`IX_OrderHeader_HqPending` 过滤索引据此扫描 |
| `CreatedAt` / `UpdatedAt` | datetimeoffset | 否 | — | 审计字段 |
| `IsDeleted` | bit | 否 | 0 | 软删除 |

**索引**（与 DDL 逐名一致）：`UX_OrderHeader_Store_PosNo (StoreId, PosOrderNo) UNIQUE`；`IX_OrderHeader_BusinessDate (BusinessDate)`；`IX_OrderHeader_HqPending (HqUploadedAt) WHERE HqUploadedAt IS NULL`（上云待传扫描）。

### 9.4 OrderDetail 订单明细表（菜品实例，最小业务单元）

| 字段 | 类型 | 可空 | 默认 | 说明 |
|------|------|:----:|------|------|
| `DetailId` | Guid | 否 | — | 明细行唯一 UID，**划单、流转操作的主键**，主键 |
| `OrderId` | Guid | 否 | — | 关联 `OrderHeader.OrderId` |
| `TableId` | Guid | 否 | — | **桌台 ID —— 与 `OrderId` 组成卡片分组业务键**（每条明细必须归属一张桌台；**无桌台填 `Guid.Empty`**，不可为 NULL） |
| `LineNo` | int | 否 | — | POS 行号（用于与 POS 对账，`OrderId + LineNo` 唯一） |
| `DishItemId` | Guid | 是 | — | 关联 `DishItem` 品项基础资料（临时菜可为空） |
| `DishName` | nvarchar(200) | 否 | — | 菜品名称（POS 推送，临时菜改名后更新此字段） |
| `Spec` | nvarchar(100) | 是 | — | 规格 |
| `Taste` | nvarchar(200) | 是 | — | 口味 |
| `Method` | nvarchar(200) | 是 | — | 做法 |
| `Qty` | decimal(18,3) | 否 | 1 | 份数（支持小数，如 0.5 份），**一个 POS `LineNo` 一行，不合并**（§4.6.1） |
| `CompletedQty` | decimal(18,3) | 否 | 0 | **已划单份数**（部分划单，§4.6.2） |
| `CancelledQty` | decimal(18,3) | 否 | 0 | **已退份数**（部分退菜，§4.7）；`RemainingQty = Qty - CancelledQty - CompletedQty` |
| `QtyStepSnapshot` | decimal(18,3) | 否 | 1 | 下单时的数量步长快照（1 / 0.5 / 0.1），用于分份校验与份格展示 |
| `Unit` | nvarchar(16) | 否 | `份` | **计量单位**（份 / 例 / 只 / 斤…），POS 可传；打印与屏幕均显示（§16.4.1 票样的"单位"列） |
| `TableNo` | nvarchar(64) | 是 | — | 桌号**渲染快照**（由 `OrderTableRel.TableCodeSnapshot` 带下）；**不参与分组**，仅省一次 join |
| `TableSortOrder` | int | 是 | — | 桌台排序号快照（由 `OrderTableRel.SortOrderSnapshot` 带下），用于稳定排序 |
| `IsGift` | bit | 否 | 0 | 是否赠菜 |
| `IsComboItem` | bit | 否 | 0 | **是否套餐内子项**（合并条件④ `Merge_ComboAndNormal` 用，§2.12） |
| `ComboNo` | nvarchar(64) | 是 | — | **套餐实例号**：同一套餐的多个子项共享，用于聚类排序与齐套核对 |
| `ComboName` | nvarchar(200) | 是 | — | 套餐名（如"双人商务餐"），用于屏幕标注与打印 |
| `ComboSeq` | int | 是 | — | 套内序号（1 开始），打印/标注 `2/4` 的分子 |
| `ComboItemTotal` | int | 是 | — | 套内子项总数，打印/标注 `2/4` 的分母 |
| `IsCancel` | bit | 否 | 0 | **派生冗余**：`IsCancel = (CancelledQty = Qty)`，仅表示"**整行**已退"，用于红删除线与快速查询；**部分退以 `CancelledQty` 为准**（§4.7） |
| `IsRush` | bit | 否 | 0 | 是否加急 |
| `IsRemind` | bit | 否 | 0 | 是否催菜 |
| `WaiterName` | nvarchar(64) | 是 | — | **点菜服务员**（POS 推送；报表"服务员"列、按服务员统计，§13.6.7） |
| `UnitPrice` | decimal(18,4) | 是 | — | **单价**（POS 推送。KDS **只透传展示，不做任何金额计算**，权威在 POS） |
| `Amount` | decimal(18,4) | 是 | — | **小计**（POS 推送；退菜金额报表用，§13.6.7） |
| `RemindCount` | int | 否 | 0 | **催单次数**（多次催菜累加） |
| `RemindAt` | datetimeoffset | 是 | — | **最近一次催单时间**（报表"催单时间"列） |
| `RemindBy` | nvarchar(64) | 是 | — | **催单人**（POS 推送事件中的操作员） |
| `CancelAt` | datetimeoffset | 是 | — | **退菜时间**（首次退份时间；`CancelledQty = 0` 时为空） |
| `CancelBy` | nvarchar(64) | 是 | — | **退菜人** |
| `CancelReason` | nvarchar(200) | 是 | — | **退菜原因**（`Item.Remove.Reason`，如"客人反馈不好吃""上菜超时"） |
| **`VoidQty`** | decimal(18,3) | 否 | **已报损份数**（已出品后作废的份数；§4.7 出品后退菜一律走报损） |
| **`VoidReasonCode`** | int | 是 | **报损原因序号**（§2.17，KDS 定义，10 间隔）：`0` 未指定 / `10` 做错菜 / `20` 客人不满意 / `30` 超时太久 / `40` 打翻掉落 / `50` 质量问题 / `60` 客人已离开 / `70` 操作失误 / `99` 其他 |
| **`VoidRemark`** | nvarchar(200) | 是 | 报损补充说明（自由文本，仅展示与日志） |
| **`VoidAt`** | datetimeoffset | 是 | **报损时刻** |
| **`VoidBy`** | nvarchar(64) | 是 | **报损操作人** |
| `SkippedStages` | nvarchar(50) | 是 | — | **被跳过的阶段**（手动模式越级完成时记录，如 `B,C`；§2.7.1 ⑤），用于统计时不虚增产量 |
| **`NotifyState`** | int | 否 | 0 | **通知单状态序号**（§2.16.1，KDS 定义）：`0` 未知 / `10` 待叫起 / `20` 已起菜 / `30` 等叫 / `40` 已出品 / `50` 已退菜 / `60` 已报损 / `70` 已清理。**只存序号，不存文本** |
| **`NotifyFlags`** | int | 否 | 0 | **通知单标记位**（§2.16.2）：`1` 催菜 / `2` 加急 / `4` 赠菜 / `8` 预订 |
| **`FirstFireAt`** | datetimeoffset | 是 | — | **首次起菜时刻**（只写一次，分析用） |
| **`LastFireAt`** | datetimeoffset | 是 | — | **最近一次起菜时刻**——**超时计时的起点**（等叫后重新起菜会更新，§2.16.3） |
| **`HoldCount`** | int | 否 | 0 | **等叫次数** |
| **`HoldAccumSeconds`** | int | 否 | 0 | **等叫累计时长**（仅分析，不计入超时） |
| `IsHold` | bit | 否 | 0 | **派生**：`NotifyState = 30`（等叫中） |
| `IsFire` | bit | 否 | 0 | **派生**：`NotifyState = 20`（已起菜） |
| `SpecialFlags` | nvarchar(MAX) | 是 | — | 特殊标记（如过敏原），JSON 数组字符串 |
| `WorkflowStage` | Enum | 否 | `Pending` | 流转阶段：`Pending` / `Prep` / `Cook` / `Expo` / `Done` / `Cancelled` / `Void` / **`Closed`（跨营业日清理关闭，§2.14）**（**仅 `EnableWorkflowState=1` 时取中间值**） |
| `IsCrossDay` | bit | 否 | 0 | **跨营业日标记**（§2.14）：`BusinessDate < 当前营业日` 且未终态时为 1 |
| `CrossDayDays` | int | 否 | 0 | **已跨营业日天数**（当前营业日 - `BusinessDate`），屏幕显示"跨日 N 天" |
| `ClosedAt` | datetimeoffset | 是 | — | **被清理关闭的时间**（`WorkflowStage = Closed` 时） |
| `ClosedReason` | nvarchar(200) | 是 | — | 清理原因（`CrossDayAutoClose` / 店长手动关闭） |
| `StatusUpdatedAt` | datetimeoffset | 否 | — | **当前状态最近一次变更时刻**（每次 `WorkflowStage` 或 `StageStatus` 变化即刷新），用于"最后动过是什么时候"与停滞检测 |
| `StageStatus` | Enum | 否 | `Waiting` | 阶段状态：`Waiting` / `Doing` / `Completed` / `Skipped`（无 `Accepted`，§1.6-D5） |
| `StagePathSnapshot` | nvarchar(50) | 否 | `Prep,Cook,Expo` | **下单时快照**的品项流转路径（后续品项配置变更不影响进行中订单） |
| `StageStandardSeconds` | nvarchar(MAX) | 是 | — | 阶段标准工时 JSON（**仅用于瓶颈分析，不参与超时判定**，§4.4.1） |
| `StageBeginTime` | datetimeoffset | 是 | — | 当前工序开始时间（阶段计时，**仅统计用**） |
| `StageCompleteTime` | datetimeoffset | 是 | — | 当前工序完成时间 |
| `TotalWaitBeginTime` | datetimeoffset | 否 | — | **点菜时刻副本** = `OrderCreateTime`（POS 点菜时间）；**仅作"下单→起菜"的前置时长分析**，不参与超时判定（超时从 `LastFireAt` 起算，§2.16.3） |
| **`BusinessDate`** | date | 否 | — | **营业日**（§2.13.1）：入库时按 `BusinessDate(OrderCreateTime)` 计算的**快照**，**永不重算**。所有统计 / 报表 / 归档 / "今日" 口径以它为准 |
| **`MealPeriod`** | Enum | 是 | — | **餐段快照**（§2.13.3）：`Breakfast` / `Lunch` / `Dinner` / `LateNight` / `Closed`；与 `BusinessDate` 同源同快照 |
| `StageElapsedSeconds` | int | 是 | — | 本阶段实际耗时（秒，划单时计算落库，**仅统计用，不参与超时判定**） |
| **`TotalTimeoutSeconds`** | int | 否 | — | **总超时阈值快照**（下单时按 §4.4.2 取值：菜品 `TotalTimeoutSeconds` 或门店 `DefaultTotalTimeoutSeconds`） |
| **`ProducedAt`** | datetimeoffset | 是 | — | **制作完成时刻** = 进入待传菜（`Expo`）那一刻；**计时终点**，写入即定格（§4.4.1） |
| **`ProducedSeconds`** | int | 是 | — | **总出品时长**（秒）= **`ProducedAt - LastFireAt`**（只算最后一次起菜之后，§2.16.3）；界面与报表权威口径 |
| **`IsTimeout`** | bit | 否 | 0 | **是否超时**：`ProducedSeconds > TotalTimeoutSeconds`，制作完成时定格 |
| **`TimeoutSeconds`** | int | 是 | — | **超时时长**（秒）= `ProducedSeconds - TotalTimeoutSeconds`（未超时为空） |
| `CurrentStationId` | Guid | 是 | — | **当前阶段的主档口 ID**（§2.2 反选推导结果，取命中集合中 `Station.SortOrder` 最前者）。**每次阶段推进必须重算更新**（§2.6.4）；语义辨析见 §2.2.1 |
| `Version` | int | 否 | 0 | **明细行乐观锁版本号**，每次状态变更 +1 |
| `CreatedAt` / `UpdatedAt` | datetimeoffset | 否 | — | 审计字段 |
| `IsDeleted` | bit | 否 | 0 | 软删除 |

**索引建议**：`UX_OrderDetail_LineNo (OrderId, LineNo) UNIQUE`；`IX_OrderDetail_Stage (WorkflowStage, StageStatus)`；`IX_OrderDetail_Station (CurrentStationId, WorkflowStage)`；`IX_OrderDetail_Table (TableId)`；`IX_OrderDetail_Combo (OrderId, ComboNo)`（套餐聚类与齐套核对）。

> **分组键原则（重要）**：**桌台视图按 `TableId` 分组、订单视图按 `OrderId` 分组，绝不用桌号 / 订单号这类业务编号分组，也不用 `TableUid` 分组**。
>
> 为什么不用 `TableUid`：**一张桌台同一时刻可能挂多个订单（拼桌）**，按 `TableUid` 分组会把不同订单的菜混在一张卡里，结账、退菜、整桌划的边界就全乱了。按 `OrderTableRel` 分组，一条关联 = 一卡 = 一个订单在某张桌上的一份，边界天然清晰。
>
> **快照原则**：`DishName` / `Spec` / `Taste` / `Method` / `StagePathSnapshot` / `StageStandardSeconds` / `TableNo` / `TableSortOrder` 均为**下单时快照**。主数据（`DishItem` / `Workflow` / `DiningTable`）后续变更**不影响进行中订单与历史归档**。这是"临时菜改名 KDS 不追溯历史"的落库依据（§2.3）。

### 9.5 DishItem 品项基础表

| 字段 | 类型 | 可空 | 默认 | 说明 |
|------|------|:----:|------|------|
| `Uid` | Guid | 否 | — | 主键 |
| `StoreId` | Guid | 否 | — | 门店 UID |
| `ItemCode` | nvarchar(64) | 否 | — | 品项业务编码（对接 POS，门店内唯一） |
| `ItemName` | nvarchar(MAX) | 否 | — | 品项名称，**LocalizedText JSON**（见 §9.16；必含主语言 key = `StoreConfig.MainLang`）。**v6.95 起不再单列 `ItemNameI18n`**——单字段存 JSON 即覆盖全部语言，避免两份名称打架 |
| `DishTypeId` | Guid | 否 | — | 所属品项类型 / 品类，关联 `DishType` |
| `SaleMode` | Enum | 否 | `ByPiece` | **售卖模式**：`ByPiece`（按份）/ `ByWeight`（**称重菜**，§4.5.1）。称重菜恒不参与合并、不做展示拆分 |
| `QtyStep` | decimal(18,3) | 否 | 1 | **数量步长 / 起订量**（1 / 0.5 / 0.1），用于入站校验与显示精度（§4.5.2）；**KDS 不据此拆分** |
| `Unit` | nvarchar(16) | 是 | — | 计量单位（份 / 例 / 斤 / 公斤）；为空时按 `SaleMode` 取默认（`ByPiece`→"份"，`ByWeight`→"斤"） |
| `DefaultSpec` | nvarchar(100) | 是 | — | 默认规格 |
| `Price` | decimal(18,3) | 是 | — | 单价（仅展示用，KDS 不做金额计算） |
| `IsSoldOut` | bit | 否 | 0 | 是否沽清（数据来源见附录待确认项 3） |
| ~~`AutoFlowStages`~~ | ~~nvarchar(100)~~ | — | — | **已废止（v6.96）**：划单是唯一流转触发，不存在"免划边"；两份 DDL 已去列，不得再加回 |
| **`TotalTimeoutSeconds`** | int | 是 | — | **该品项的总超时阈值**（秒，起菜→制作完成，§4.4.2）；空 = 用 `StoreConfig.DefaultTotalTimeoutSeconds` |
| **`StageStandardSeconds`** | nvarchar(MAX) | 是 | — | **阶段标准工时 JSON**（如 `{"Prep":180,"Cook":300}`）；**仅用于瓶颈分析，不参与超时判定**（§4.4.1） |
| **`IsEnabled`** | bit | 否 | 1 | **品项是否启用**（停用后不参与路由；进行中订单不受影响） |
| **`SortOrder`** | int | 否 | 0 | 展示排序（管理端列表 / 品项类型内排序用） |
| `CreatedAt` / `UpdatedAt` | datetimeoffset | 否 | — | 审计字段 |
| `IsDeleted` | bit | 否 | 0 | 软删除 |

**索引建议**：`UX_DishItem_Code (StoreId, ItemCode) UNIQUE`；`IX_DishItem_Type`。

### 9.6 DishType 品项类型 / 品类表

| 字段 | 类型 | 可空 | 默认 | 说明 |
|------|------|:----:|------|------|
| `Uid` | Guid | 否 | — | 主键 |
| `StoreId` | Guid | 否 | — | 门店 UID |
| `TypeCode` | nvarchar(64) | 否 | — | 类型编码 |
| `TypeName` | nvarchar(MAX) | 否 | — | 类型名称，**LocalizedText JSON**（见 §9.16；v6.95 起不再单列 `TypeNameI18n`） |
| **`ParentTypeId`** | Guid | 是 | — | **父类型**（品类树；空 = 顶级） |
| `DefaultStagePath` | nvarchar(50) | 是 | — | 品类默认 StagePath（品项未配置时继承，§2.4） |
| `DefaultStageStandardSeconds` | nvarchar(MAX) | 是 | — | 品类默认阶段标准工时 JSON |
| `SortOrder` | int | 否 | 0 | 排序 |
| `CreatedAt` / `UpdatedAt` | datetimeoffset | 否 | — | 审计字段 |
| `IsDeleted` | bit | 否 | 0 | 软删除 |

### 9.7 DiningTable 桌台主数据表

> 桌台主数据（物理/逻辑桌位），由 POS 通过 `DiningTable.Sync` 同步（§10.3），KDS 侧只读。
> **注意：本表不是卡片分组键**——卡片按业务键 `(OrderId, TableId)` 分组（§9.8）；无桌台场景（外卖）**不建本表记录**，直接用 `TableId = Guid.Empty`。

| 字段 | 类型 | 可空 | 默认 | 说明 |
|------|------|:----:|------|------|
| `Uid` | Guid | 否 | — | 桌台 UID，主键 |
| `StoreId` | Guid | 否 | — | 门店 UID |
| `ExternalTableId` | nvarchar(64) | 是 | — | **外部 POS 的桌台 ID**（适配层对齐用）；同门店内唯一 |
| `TableCode` | nvarchar(64) | 否 | — | 桌号 / 编码（**可改**，仅展示与检索；`StoreId + TableCode` 唯一） |
| `TableName` | nvarchar(200) | 是 | — | 桌台显示名（多语言 JSON，见 §9.16）；为空时显示 `TableCode` |
| `AreaName` | nvarchar(200) | 是 | — | 区域 / 楼层（用于跨区联台判断与排序辅助，V1 不做独立区域表） |
| `SeatCount` | int | 是 | — | 座位数（人数以订单 `GuestCount` 为准） |
| `SortOrder` | int | 否 | 0 | **桌台排序号**（管理端可配）。卡片默认按此排序，避免 `ka10 < ka2` 的字符串排序问题 |
| `IsEnabled` | bit | 否 | 1 | 是否启用（停用后不再接受新单，已存在的 `OrderTableRel` 不受影响） |
| `IsAutoCreated` | bit | 否 | 0 | **是否由适配层自动创建**（POS 只给了桌号、未同步桌台主数据时自动建）；管理端可据此提示"请补全桌台资料" |
| `CreatedAt` / `UpdatedAt` | datetimeoffset | 否 | — | 审计字段 |
| `IsDeleted` | bit | 否 | 0 | 软删除 |

**索引建议**：`UX_DiningTable_Code (StoreId, TableCode) UNIQUE`；`IX_DiningTable_Sort (StoreId, SortOrder)`；`UX_DiningTable_External (StoreId, ExternalTableId) UNIQUE`（`ExternalTableId` 非空时）。

**关键约定**：

1. **改桌号不影响进行中订单**：POS 改桌号推 `DiningTable.Sync`，KDS 更新 `TableCode`；卡片标题随之刷新，但分组键 `(OrderId, TableId)` 不变，卡片不会重排或丢失。
2. **停用 / 删除桌台**：已存在的 `OrderTableRel` 与明细照常展示；主数据缺失时标题回退到 `OrderTableRel.TableCodeSnapshot`，不会出现空标题。
3. **无桌台场景不建主数据**：外卖 / 自提 / 外带使用 **`TableId = Guid.Empty`**（全零 GUID）作为固定哨兵，**无需在主数据里造"虚拟桌台"记录**。理由见 §9.8 的"无桌台约定"。

### 9.8 OrderTableRel 订单-桌台关联表（**卡片分组键**）

> **核心关系**：
> ```
> OrderHeader 1 ── N OrderTableRel（一单可占多桌 = 联台）
> DiningTable 1 ── N OrderTableRel（一桌可挂多单 = 拼桌；业务上限制同一时刻尽量只有 1 条，避免非拼桌叠台）
> OrderTableRel 1 ── N OrderDetail（每条明细归属唯一一条关联）
> ```
> **卡片 = 一条 `OrderTableRel`**。这样"联台"天然拆成多卡、"拼桌"天然是多卡，不需要额外判断。

**主键：独立 `Uid`（GUID）；业务唯一键 / 分组键：`(OrderId, TableId)` 复合。**

> **为什么要分开**：
> - **主键 `Uid`** 保持全库统一约定（§8：所有表主键统一 `Uid`），便于 FK 引用、审计、事件重放时定位，也避免复合主键在 ORM / 迁移工具上的额外复杂度；
> - **业务唯一键 `(OrderId, TableId)`** 负责"一单一桌只有一条"的语义约束与幂等 upsert；
> - **分组键**由 `OrderId` + `TableId` 拼出（如 `"{OrderId}:{TableId}"`），这两列在 `OrderDetail` 上本来就有，**终端可自行计算，无需 Master 下发 `Uid`**。
>
> 三者分工：`Uid` 管"这一行是谁"，`(OrderId, TableId)` 管"这一行代表哪一单一桌"，分组只依赖业务键。

| 字段 | 类型 | 可空 | 说明 |
|------|------|:----:|------|
| `Uid` | Guid | 否 | **主键**（独立 GUID） |
| `OrderId` | Guid | 否 | **业务键①**：所属订单，关联 `OrderHeader` |
| `TableId` | Guid | 否 | **业务键②**：关联 `DiningTable.Uid`；**无桌台（外卖 / 自提 / 外带）填 `Guid.Empty`**，不允许 NULL |
| `TableCodeSnapshot` | nvarchar(64) | 是 | 桌号**显示快照**；无桌台时为空，标题改用外卖单号 |
| `SortOrderSnapshot` | int | 是 | 桌台排序号快照（来自 `DiningTable.SortOrder`）；无桌台时为空 |
| `AreaNameSnapshot` | nvarchar(200) | 是 | 区域快照（跨区联台判断与标题提示用） |
| `Status` | Enum | 否 | `Active`（进行中）/ `Closed`（该桌台部分已结账或撤台）；`Closed` 后不再接收新明细，但已有明细仍要展示到终态 |
| `CreatedAt` / `UpdatedAt` | datetimeoffset | 否 | 审计字段 |
| `IsDeleted` | bit | 否 | 软删除 |

**主键与索引**：

- `PK_OrderTableRel (Uid)` —— 主键；
- `UX_OrderTableRel_Order_Table (OrderId, TableId) UNIQUE` —— **业务唯一键**：保证一单一桌只有一条，也是幂等 upsert 的落点；
- `IX_OrderTableRel_Table (TableId, Status)` —— 查某桌台当前挂了几单（拼桌检测）；
- `IX_OrderTableRel_Order (OrderId)` —— 判断是否联台（`count > 1`）。

**无桌台约定（外卖 / 自提 / 外带）**

| 项 | 规则 |
|----|------|
| 取值 | `TableId = Guid.Empty`（`00000000-0000-0000-0000-000000000000`） |
| 为什么不用 NULL | `(OrderId, NULL)` 在 `=` 比较中结果是 UNKNOWN，会让分组与唯一约束失效；用哨兵值可让两库行为一致 |
| 为什么不需要"虚拟桌台"主数据 | 外卖**不会联台**，一个订单最多只有一条 `(OrderId, Guid.Empty)` 记录，**天然唯一、不产生歧义**；造一条假的桌台主数据反而要维护它的排序号、区域、启停状态，纯属负担 |
| 外卖单有时关联桌台 | 关联了就填真实 `TableId`（如电话订餐挂在某桌），分组键随之带上桌台；**同一外卖单不会同时出现"有桌台 + 无桌台"两组**（业务不变式：外卖不联台） |
| 展示 | `TableId == Guid.Empty` 时卡片标题显示**外卖单号**（`OrderHeader.PosOrderNo`）；否则显示桌号 |
| 校验 | 非外卖订单（`OrderType = DineIn`）的明细若带 `Guid.Empty` → 拒绝（`VALIDATION_FAILED`），防止把堂食单误标成无桌台而漏送 |

**关键约定**：

1. **联台判定**：`该 OrderId 下 Status='Active' 的 OrderTableRel 数量 > 1` → 联台订单。
2. **拼桌判定**：`同一 TableId 下 Status='Active' 的 OrderTableRel 数量 > 1` → 该桌拼桌（`Guid.Empty` 不参与拼桌判定）。
3. **叠台防护**：新建 `OrderTableRel` 时若该 `TableId`（非空桌台）已有 `Active` 记录，按 §10.7 返回 `TABLE_OCCUPIED`（除非 POS 显式声明拼桌 `IsSharedTable=true`）。
4. **部分结账**：POS 结清某桌台的部分 → 置 `Status = Closed`；其明细若已全部终态则卡片消失，否则继续展示直到终态。
5. **`Uid` 不作为分组键**：分组一律用 `(OrderId, TableId)`；`Uid` 只在需要"单行引用"的场景使用（日志、审计、事件定位）。这样即使换桌导致业务键变化，也能通过 `Uid` 追踪同一行记录的历史。

### 9.9 Station 档口主配置表

| 字段 | 类型 | 可空 | 默认 | 说明 |
|------|------|:----:|------|------|
| `Uid` | Guid | 否 | — | 主键 |
| `StoreId` | Guid | 否 | — | 门店 UID |
| `StationCode` | nvarchar(64) | 否 | — | 档口编码 |
| `Name` | nvarchar(200) | 否 | — | 档口名（多语言 JSON，见 §9.16） |
| `Role` | Enum | 否 | — | `Prep` / `Cook` / `Expo` |
| `IncludeTypeIds` | nvarchar(MAX) | 是 | — | **类型纳入集合**：GUID 逗号分隔，规范格式 `,g1,g2,`（见 §9.10） |
| `ExcludeItemIds` | nvarchar(MAX) | 是 | — | **单品剔除集合**（黑名单）：GUID 逗号分隔 |
| `IncludeItemIds` | nvarchar(MAX) | 是 | — | **单品追加集合**（白名单，仅类型未命中时生效）：GUID 逗号分隔 |
| ~~`StageTimeoutSeconds`~~ | — | — | — | **已废弃（v6.55），V1 不建列（v6.95）**：超时改为"起菜 → 制作完成"的总时长判定（§4.4.1 / §4.4.2），档口级阶段超时**不参与任何判定**。V1 为新建库、无历史数据，故**两份 DDL 均已删列**；勿再引用 |
| **`IsEnabled`** | bit | 否 | 1 | **档口是否启用**（停用后不参与路由匹配；进行中订单仍按快照 `CurrentStationId` 走完） |
| `EnableVoice` | bit | 否 | 1 | 本档口是否启用语音 |
| `SortOrder` | int | 否 | 0 | 排序（管理端展示用） |
| `CreatedAt` / `UpdatedAt` | datetimeoffset | 否 | — | 审计字段 |
| `IsDeleted` | bit | 否 | 0 | 软删除 |

**索引建议**：`UX_Station_Code (StoreId, StationCode) UNIQUE`；`IX_Station_Role`。

### 9.10 档口反选字段（`Station` 表内）

反选配置直接存在 `Station` 表内，三个字段（均为 GUID 逗号分隔字符串，统一存储为 `,uid1,uid2,` 前后补逗号的格式）：

| 字段 | 类型 | 可空 | 默认 | 说明 |
|------|------|:----:|------|------|
| `IncludeTypeIds` | nvarchar(MAX) | 是 | — | **类型纳入集合**（白名单-类型） |
| `ExcludeItemIds` | nvarchar(MAX) | 是 | — | **单品剔除集合**（黑名单-单品） |
| `IncludeItemIds` | nvarchar(MAX) | 是 | — | **单品追加集合**（白名单-单品，仅在类型未命中时生效） |

**存储格式约定（必须严格遵守）**：

```
规范格式：,guid1,guid2,guid3,        ← 首尾都有逗号，小写 D 格式
写入时：  由实体属性 setter 统一规范化（Split → Trim → ToLower → 去空 → 去重 → 重新拼接）
读取时：  Master 启动加载后投影为 HashSet<Guid> 常驻内存，不再反复解析字符串
```

**为空 / null 的处理**：视为**空集合**（不是"全部"），即该档口不纳入任何类型 —— 在管理端保存时给出提示，避免管理员误以为空=全部。

**性能与隐患（逗号字段存储必须接住的代价，已给对策）**：

| 隐患 | 对策 |
|------|------|
| 字符串 LIKE 查询无法走索引，品项量上千时每次全扫 | 该查询**只在两处执行**：① 管理端匹配预览（低频）；② `Menu.Sync` 后批量重算品项-档口归属（低频、批量）。**运行期推屏不走 SQL**，直接读内存中的归属结果 |
| 逗号拼接易出现 `uid=12` 命中 `uid=123` 的子串误匹配 | 强制前后补逗号（`,uid,`）+ GUID 定长 36 字符，二者叠加可消除误匹配 |
| 无法外键约束，脏 GUID（已删类型的 ID）会残留 | 管理端保存时校验存在性；运行时解析跳过不存在项并记 `Warning` |
| 大字符串（上千 GUID）每次解析开销 | 加载一次投影为 `HashSet<Guid>`，仅在配置变更（`ConfigVersion` 递增）时重建 |

**内存投影模型（Master 侧，V1 实现口径）**：

```
StationIndex（单例，配置变更时重建）：
  Dictionary<Guid /*StationId*/, StationRule>
  StationRule {
      HashSet<Guid> IncludeTypeIds;
      HashSet<Guid> ExcludeItemIds;
      HashSet<Guid> IncludeItemIds;
  }

归属判定（§2.2 的等价实现，全部在内存完成）：
  bool BelongsTo(StationRule r, DishItem item) =>
      (r.IncludeTypeIds.Contains(item.DishTypeId) && !r.ExcludeItemIds.Contains(item.Uid))
      || (!r.IncludeTypeIds.Contains(item.DishTypeId) && r.IncludeItemIds.Contains(item.Uid));
```

> 这样既满足"数据结构不动"的要求，又把匹配从"每次查询扫字符串"降为"哈希查表"，性能与维护成本都可控。§2.2 的 SQL 片段**仅用于管理端校验与批量重算**，不再作为推屏主路径。

### 9.11 Workflow 品项自定义工序流程定义表

| 字段 | 类型 | 可空 | 默认 | 说明 |
|------|------|:----:|------|------|
| `Uid` | Guid | 否 | — | 主键 |
| `StoreId` | Guid | 否 | — | 门店 UID |
| `Scope` | Enum | 否 | `Item` | `Item`（品项级）/ `Type`（品类级） |
| `ScopeId` | Guid | 否 | — | `DishItem.Uid` 或 `DishType.Uid` |
| `StagePath` | nvarchar(50) | 否 | `Prep,Cook,Expo` | 阶段序列，逗号分隔：`Prep` / `Cook` / `Expo` 的组合 |
| `StageStandardSeconds` | nvarchar(MAX) | 是 | — | 阶段标准工时 JSON（**仅瓶颈分析用，不参与超时判定**，§4.4.1） |
| ~~`AutoFlowStages`~~ | ~~nvarchar(100)~~ | — | — | **已废止（v6.96）**：同上，见 §9.5 |
| `IsEnabled` | bit | 否 | 1 | 是否启用（关闭流转开关时本表失效但不删除） |
| `CreatedAt` / `UpdatedAt` | datetimeoffset | 否 | — | 审计字段 |
| `IsDeleted` | bit | 否 | 0 | 软删除 |

**索引建议**：`UX_Workflow_Scope (StoreId, Scope, ScopeId) UNIQUE`（同一范围内唯一）。

**配置优先级**：`Workflow(Scope=Item)` > `Workflow(Scope=Type)` > `DishType.DefaultStagePath` > 系统默认 `Prep,Cook,Expo`。

### 9.12 OperationLog 操作日志表

| 字段 | 类型 | 可空 | 默认 | 说明 |
|------|------|:----:|------|------|
| `Uid` | Guid | 否 | — | 主键 |
| `StoreId` | Guid | 否 | — | 门店 UID |
| `TerminalId` | Guid | 是 | — | 操作来源终端（POS 触发的操作为空） |
| `OperatorName` | nvarchar(64) | 是 | — | 操作人（如有登录） |
| `Action` | Enum | 否 | — | `StageComplete` / `StageUndo` / `OrderDone` / **`ItemVoid`（报损）** / **`ItemUnableToCook`（沽清申请）** / `ItemNotify`（通知单状态变更，带 `NotifyState` 序号）/ `ConfigChange`。**无 `ItemCancel`**：退菜只能 POS 发起（§4.7.2） |
| `OrderId` | Guid | 是 | — | 关联订单 |
| `DetailId` | Guid | 是 | — | 关联明细 |
| `Stage` | Enum | 是 | — | 操作时所在阶段 |
| **`FromStage`** | Enum | 是 | — | **操作前阶段**（撤销的目标，§2.19.2；无阶段变化的操作为空） |
| **`ToStage`** | Enum | 是 | — | **操作后阶段**（撤销判定：当前状态必须等于它才可撤，§2.19.1） |
| `FromStatus` | Enum | 是 | — | 操作前 `StageStatus` |
| `ToStatus` | Enum | 是 | — | 操作后 `StageStatus`（撤销判定依据之一） |
| **`Qty`** | decimal(18,3) | 是 | — | 本次操作份数（部分划单撤销时回扣用） |
| **`VersionAt`** | int | 是 | — | 操作时该明细的 `Version`（撤销时比对，判断是否被他人改过） |
| **`IsUndoable`** | bit | 否 | 0 | **写入时预判是否可撤销**（读取时仍须**实时复核**四条条件） |
| **`RevertedAt`** | datetimeoffset | 是 | — | **被撤销的时间**（非空 = 已撤销过，不可再撤） |
| **`RevertedBy`** | nvarchar(64) | 是 | — | 撤销操作人 |
| **`BusinessDate`** | date | 否 | — | **营业日快照**（按 `CreatedAt` 换算，§2.13.1）；【我的操作】抽屉与日报按此列过滤，避免跨日串数据 |
| `ClientEventId` | Guid | 是 | — | 客户端幂等 ID（离线补发去重用） |
| `BeforeState` | nvarchar(200) | 是 | — | 变更前状态摘要（`Stage + StageStatus`） |
| `AfterState` | nvarchar(200) | 是 | — | 变更后状态摘要 |
| `Result` | Enum | 否 | `Success` | `Success` / `Rejected`（含拒绝原因码） |
| `Remark` | nvarchar(MAX) | 是 | — | 备注 / 拒绝原因 |
| `OccurredAt` | datetimeoffset | 否 | — | 操作发生时间（客户端时间） |
| `CreatedAt` | datetimeoffset | 否 | — | 服务端接收时间 |

**索引建议**：`IX_OperationLog_Order (OrderId, CreatedAt)`；`UX_OperationLog_ClientEventId`；`IX_OperationLog_Terminal (TerminalId, CreatedAt)`；**`IX_OperationLog_Undo (TerminalId, CreatedAt, IsUndoable, RevertedAt)`** —— 支撑屏幕【我的操作】抽屉的可撤销清单查询（§2.19.4）。

### 9.13 EventLog 原始事件日志表

| 字段 | 类型 | 可空 | 默认 | 说明 |
|------|------|:----:|------|------|
| `Uid` | Guid | 否 | — | 主键 |
| `EventId` | Guid | 否 | — | 事件幂等 ID（**唯一索引**，重复投递据此丢弃） |
| `StoreId` | Guid | 否 | — | 门店 UID |
| `EventType` | nvarchar(64) | 否 | — | `Order.Create` / `Order.Update` / `Item.Remove` / `Order.Cancel` / `Order.Remind` / `Order.Hold` / `Order.Release` / `Order.Split` / `Menu.Sync` / `DiningTable.Sync` / `Station.Sync` |
| `PosSource` | nvarchar(64) | 是 | — | POS 来源 |
| `ProtocolVersion` | nvarchar(16) | 否 | `1.0` | 协议版本 |
| `SourceTimestamp` | datetimeoffset | 是 | — | 事件内声明的发生时间（POS 时钟） |
| `ReceivedAt` | datetimeoffset | 否 | — | Master 接收时间（**计时基准**） |
| `Payload` | nvarchar(MAX) | 否 | — | 原始 payload JSON（**全量留存，供重放与排障**） |
| `ProcessStatus` | Enum | 否 | `Pending` | `Pending` / `Processed` / `Failed` / `Ignored`（幂等丢弃） |
| `ErrorCode` | nvarchar(64) | 是 | — | 处理失败错误码 |
| `ErrorMessage` | nvarchar(MAX) | 是 | — | 失败详情 |
| **`TraceId`** | nvarchar(64) | 是 | — | **链路追踪 ID**（入站事件 → 处理的关联键，排障时用它串起 EventLog / OperationLog / 出站回执） |
| **`ProcessedAt`** | datetimeoffset | 是 | — | **处理完成时刻**（`ProcessStatus` 由 `Pending` 转出时写入，用于算处理耗时与积压） |

**索引**（与 DDL 逐名一致）：`UX_EventLog_EventId (EventId) UNIQUE`；`IX_EventLog_Type_Time (EventType, ReceivedAt)`。
> ⚠️ **性能待办**：`ProcessStatus` 尚无索引，积压巡检退化为按 `ReceivedAt` 扫描（日志量 30 天可控）。若上线后积压查询变慢，再加 `(ProcessStatus, ReceivedAt)`（增量迁移，不影响本版 DDL）。
**保留策略**：默认保留 30 天，到期由定时任务清理；清理策略见 §13.6。
### 9.14 OutboxMessage 出站回执待发表

| 字段 | 类型 | 可空 | 默认 | 说明 |
|------|------|:----:|------|------|
| `Uid` | Guid | 否 | — | 主键 |
| `StoreId` | Guid | 否 | — | 门店 UID |
| `TargetKind` | Enum | 否 | `Pos` | `Pos`（回执 POS）/ `Hq`（上报总部） |
| `EventType` | nvarchar(64) | 否 | — | `Item.Complete` / `Order.Done` / `Item.Void` / `Heartbeat` / `Error` |
| `Payload` | nvarchar(MAX) | 否 | — | 出站 payload JSON |
| `IdempotencyKey` | nvarchar(128) | 否 | — | 幂等键（如 `DetailId + Stage`），**唯一索引**防重复回执 |
| `Status` | Enum | 否 | `Pending` | `Pending` / `Sent` / `Failed` / `DeadLetter` |
| `RetryCount` | int | 否 | 0 | 已重试次数 |
| `NextRetryAt` | datetimeoffset | 是 | — | 下次重试时间（指数退避） |
| `LastError` | nvarchar(MAX) | 是 | — | 最后失败原因 |
| `CreatedAt` | datetimeoffset | 否 | — | 创建时间 |
| `SentAt` | datetimeoffset | 是 | — | 发送成功时间 |

**索引**（与 DDL 逐名一致）：`UX_Outbox_IdempotencyKey (IdempotencyKey) UNIQUE`；`IX_Outbox_Status (Status, NextRetryAt)`；`IX_Outbox_DeadLetter (Status, CreatedAt)`（死信巡检；`Sent` 清理扫描复用本索引的 `Status` 前缀）。
**重试策略**：最多 10 次，指数退避（1s/2s/4s…上限 5 分钟），超限转 `DeadLetter` 并告警。

#### 9.14.1 定期维护（必须实现，不是可选）

> **为什么必须有一节**：Outbox 是"只增不减"的表，如果没人清，SQLite 单库几个月就会涨到几个 G，后厨屏全量拉取和 DB 备份都会变慢。而清理策略如果写错（比如连带清掉 `DeadLetter`），失败的回执就永久消失、无法补发。

**四个状态各自的归宿**

| 状态 | 含义 | 保留期 | 处置 |
|------|------|--------|------|
| `Pending` | 待发送 / 等待重试 | **不清理** | 由发送器消费；积压超阈值告警 |
| `Failed` | 一次失败、待下次重试 | **不清理** | 随重试推进；超 10 次转 `DeadLetter` |
| `Sent` | 已成功送达 | **7 天** | 定时物理删除（保留 7 天用于对账/排查） |
| **`DeadLetter`** | 重试超限，需人工介入 | **90 天** | **不自动删；先告警，人工排查后重放或手工关闭** |

**定时任务清单**

| 任务 | 周期 | 动作 | 实现要点 |
|------|------|------|----------|
| **清理已发送** | 每日 1 次（默认 04:00） | 删除 `Status = Sent` 且 `SentAt < now - 7d` | **批量删除**（每批 1,000 条，循环至清空），避免长事务锁库 |
| **死信巡检** | 每 10 分钟 | 统计 `DeadLetter` 数量，超阈值告警 | 进统一健康检查（`OUTBOX_DEADLETTER`） |
| **积压巡检** | 每 1 分钟 | 统计 `Pending` 条数 + 最老一条的滞留时长 | 超阈值告警（`OUTBOX_BACKLOG`） |
| **过期死信归档** | 每月 1 次 | `DeadLetter` 超 90 天 → 导出 CSV 后删除 | **导出必须先成功**，否则跳过（数据不可静默丢） |
| **SQLite 空间回收** | 每周 1 次（清理后） | `PRAGMA optimize`；每季度 `VACUUM` | **SQLite 删除不释放文件空间**，不做 VACUUM 则 DB 文件只涨不跌 |

**积压告警阈值（默认值，可配）**

| 指标 | 阈值 | 含义 |
|------|------|------|
| `Pending` 条数 | > **500** | 告警（POS 长时间不可达的典型表现） |
| 最老 `Pending` 滞留 | > **10 分钟** | 告警（若 POS 在线却积压，说明回执接口出错或地址配错） |
| `DeadLetter` 条数 | > **0** | 告警（死信必须有人看，否则等于静默丢回执） |
| `Hq` 目标积压 | > **5,000** | 独立阈值（总部上报跨网，允许更长积压，但不能无上限） |

> **`TargetKind = Hq` 单独阈值**：总部上报在门店断外网时必然积压，用 POS 的阈值会天天误报；但也不能不设上限——极端情况下会占满 SQLite 空间。

**死信处置（人工闭环）**

```
告警 → 管理端"待发回执"页面筛选 Status = DeadLetter
     ├─ 查看 LastError（如 POS 地址配错、认证失败、payload 不合法）
     ├─ 修正后【重放】：Status → Pending，RetryCount 归零，NextRetryAt = now
     └─ 或【关闭】：Status → Sent（标记已人工处理，避免反复告警），记 OperationLog
```

| 操作 | 接口 | 说明 |
|------|------|------|
| 列表 / 统计 | `GET /api/Admin/Outbox/Stats` | 按状态、目标、事件类型分组计数 + 最老滞留时长 |
| 批量重放 | `POST /api/Admin/Outbox/Replay` | 入参筛选条件（状态/时间/事件类型），逐条重置为 `Pending`；**上限 500 条/次**，避免一次压垮 POS |
| 单条关闭 | `POST /api/Admin/Outbox/{id}/Close` | 人工确认已处理，置 `Sent` 并记原因 |

> **重放必须校验幂等键**：重放时若发现同 `IdempotencyKey` 已有更新的成功记录，应跳过（避免给 POS 重复发同一回执）。

**一个必须讲清的取舍：幂等窗口 = 7 天**

`UX_Outbox_IdempotencyKey` 唯一索引能防重复回执，但**已发送记录 7 天后被清理，唯一约束也随之消失**。这意味着：

- **7 天内**：同一 `IdempotencyKey` 的重复生成会被数据库挡住（真正幂等）；
- **7 天后**：理论上可能生成一条重复回执。

**为什么可以接受**：入站事件幂等由 `EventLog.EventId` 保证（30 天），重复的**入站事件**根本不会产生新的划单，因此也不会产生新的回执；**只有"同一个划单动作被重复提交"才可能触发**，而那有 `OrderDetail.Version` 乐观锁兜底（第二次提交`VERSION_CONFLICT`）。所以 7 天窗口 + 两道前置幂等，实际不会漏。

### 9.15a VoiceTemplate 语音播报模板表（可编辑）

> 规则见 §3.5.4。核心：**文案不写死**，门店自行维护；**变量强校验**，防止手误导致播报变成大括号原文。

| 字段 | 类型 | 可空 | 默认 | 说明 |
|------|------|:----:|------|------|
| `Uid` | Guid | 否 | — | 主键 |
| `StoreId` | Guid | 否 | — | 门店 UID |
| **`TemplateKind`** | Enum | 否 | — | `Call`（叫号）/ `AllDone`（整桌齐）/ `Timeout`（超时）/ `Remind`（催菜）/ `SoldOut`（沽清） |
| **`Lang`** | nvarchar(16) | 否 | `zh-CN` | BCP-47 语言码 |
| **`Body`** | nvarchar(500) | 否 | — | 模板正文（含 `{变量}`）；**留空 = 该场景不播报** |
| `Variables` | nvarchar(200) | 是 | — | 使用的变量清单（保存时自动解析写入，便于检索与校验） |
| `Version` | int | 否 | 1 | 版本号（每次保存 +1，支持回滚） |
| `IsEnabled` | bit | 否 | 1 | 是否启用（关闭则回退内置默认） |
| `UpdatedBy` | nvarchar(64) | 是 | — | 最近修改人（审计） |
| `CreatedAt` / `UpdatedAt` | datetimeoffset | 否 | — | 审计字段 |

**业务唯一键**：`UX_VoiceTemplate (StoreId, TemplateKind, Lang)`。

**索引**：无额外索引（数据量极小，几十行）。

**保存校验（必须实现）**

| 校验 | 规则 | 失败处理 |
|------|------|----------|
| 变量白名单 | 解析 `{X}`，X 必须在 §3.5.4 白名单内 | **拒绝保存**，返回可用变量列表 |
| 变量与场景匹配 | 如 `Timeout` 才允许 `{DishName}`，`Call` 用 `{DishNames}` | 拒绝保存并提示 |
| 长度 | > 60 字 | **仅警告**（不阻止），提示预计播报秒数 |
| 花括号配对 | 未闭合的 `{` 或 `}` | 拒绝保存 |
| 空值 | `Body = ""` | **允许**（表示该场景不播报） |

**回退链**：`门店配置(当前语言) → 门店配置(默认语言) → 内置默认模板(当前语言) → 内置默认模板(zh-CN) → 空(不播报)`。




### 9.15 ScreenLangPack 终端语言包覆盖表（可选）

| 字段 | 类型 | 可空 | 默认 | 说明 |
|------|------|:----:|------|------|
| `Uid` | Guid | 否 | — | 主键 |
| `StoreId` | Guid | 否 | — | 门店 UID（多门店隔离；门店级默认包也必须带本列） |
| `TerminalId` | Guid | 是 | — | 为空表示门店级默认语言包 |
| `Lang` | nvarchar(16) | 否 | — | 语言代码（`zh-CN` / `en-US`） |
| `PackJson` | nvarchar(MAX) | 否 | — | 键值对 JSON（见 §11.1） |
| `Version` | int | 否 | 1 | 版本号 |
| `UpdatedAt` | datetimeoffset | 否 | — | 更新时间 |

> V1 可不建此表，语言包以**文件（内嵌资源）**方式随程序发布；此表用于门店级文案覆盖的后续扩展。

### 9.15b SoldOutLog 沽清记录表

> 规则见 §2.18。一次沽清 = 一行；`LimitedQty` 卖完自动结束时更新 `EndAt` 与 `Status`。

| 字段 | 类型 | 可空 | 默认 | 说明 |
|------|------|:----:|------|------|
| `Uid` | Guid | 否 | — | 主键 |
| `StoreId` | Guid | 否 | — | 门店 UID |
| `DishItemId` | Guid | 否 | — | 沽清品项 |
| `DishTypeId` | Guid | 是 | — | 品类级沽清时记录（品项级为品类快照） |
| `DishNameSnapshot` | nvarchar(200) | 是 | — | 品项名快照（改名后历史可读） |
| **`SoldOutType`** | Enum | 否 | `UntilManual` | `UntilManual` / `UntilTime` / `LimitedQty` |
| **`LimitQty`** | decimal(18,3) | 是 | — | 限量份数（仅 `LimitedQty`） |
| **`SoldQty`** | decimal(18,3) | 否 | 0 | 沽清期间已售份数（限量扣减用） |
| **`ReasonCode`** | int | 否 | 0 | 沽清原因号段（§2.18.6）：`0` 未指定 / `10` 食材售罄 / `20` 设备故障 / `30` 产能不足 / `40` 质量不合格 / `50` 临时停售 / `99` 其他 |
| `Remark` | nvarchar(200) | 是 | — | 补充说明 |
| **`StartAt`** | datetimeoffset | 否 | — | 沽清开始时间 |
| `EndAt` | datetimeoffset | 是 | — | 结束时间（恢复/限量售完/跨日失效时写入） |
| `EndReason` | Enum | 是 | — | `Manual`（人工恢复）/ `AutoTime`（到点）/ `LimitReached`（限量售完）/ `CrossDay`（跨营业日失效） |
| **`Status`** | Enum | 否 | `Requested` | `Requested`（申请中）/ `Active`（生效中）/ `Rejected`（POS 拒绝）/ `Ended`（已结束） |
| **`RequestedBy`** | nvarchar(64) | 是 | — | 申请方（`TerminalId` 或用户名；POS 发起时为空） |
| `RequestedFrom` | Enum | 否 | `Kds` | `Kds` / `Pos` |
| `ApprovedBy` | nvarchar(64) | 是 | — | POS 确认人（`PosConfirm` 模式） |
| `ApprovedAt` | datetimeoffset | 是 | — | 确认时间 |
| **`BusinessDate`** | date | 否 | — | **营业日**（§2.13，跨日失效判定与报表口径） |
| `CreatedAt` / `UpdatedAt` | datetimeoffset | 否 | — | 审计字段 |
| `IsDeleted` | bit | 否 | 0 | 软删除 |

**索引建议**：
`IX_SoldOutLog_Item_Active (StoreId, DishItemId, Status)` —— 查某品项当前是否沽清（热路径，每次新单校验）；
`IX_SoldOutLog_Biz (StoreId, BusinessDate)` —— 日报统计；
`IX_SoldOutLog_Status_End (Status, EndAt)` —— 定时恢复扫描（`UntilTime` 到点）。

### 9.15c CallLog 叫号记录表

> 规则见 §3.5.2 / §3.5.3。**只增不改**（除 TTS 结果更新），用于排查"到底喊没喊"。

| 字段 | 类型 | 可空 | 默认 | 说明 |
|------|------|:----:|------|------|
| `Uid` | Guid | 否 | — | 主键 |
| `StoreId` | Guid | 否 | — | 门店 UID |
| **`OrderId`** | Guid | 是 | — | 关联订单（叫号通常针对某桌，联台时为 `OrderId`） |
| `TableId` | Guid | 是 | — | 桌台关联（`OrderTableRel.TableId`） |
| `TableCodeSnapshot` | nvarchar(64) | 是 | — | 桌号快照 |
| **`TerminalId`** | Guid | 是 | — | 发起叫号的屏幕 |
| `OperatorName` | nvarchar(64) | 是 | — | 操作人（如有登录） |
| **`TriggerSource`** | Enum | 否 | `Manual` | `Manual`（点【叫号】）/ `AutoAllExpo`（整桌齐自动，`CallAutoOnAllExpo`） |
| **`RenderedText`** | nvarchar(500) | 是 | — | **渲染后的播报文本**（含变量已替换，便于排查"喊了什么"） |
| `TemplateKind` | Enum | 是 | — | 使用的模板场景（`Call` / `AllDone`） |
| `Lang` | nvarchar(16) | 是 | — | 播报语言（取屏幕 `CurrentLang`） |
| `TtsProvider` | nvarchar(32) | 是 | — | 实际使用的 TTS 实现 |
| **`SpeakResult`** | Enum | 否 | `Skipped` | `Success` / `Failed` / `Skipped`（静音时段 / 无 TTS / 空模板） |
| `ErrorMessage` | nvarchar(200) | 是 | — | 失败原因 |
| **`BusinessDate`** | date | 否 | — | 营业日（报表口径） |
| `CreatedAt` | datetimeoffset | 否 | — | 叫号时间 |

**索引建议**：
`IX_CallLog_Cooldown (StoreId, TableId, CreatedAt)` —— **同桌冷却判定**（§3.5.3 的 30 秒防刷，热路径）；
`IX_CallLog_Biz (StoreId, BusinessDate)` —— 日报统计。

### 9.15d UserAccount 账号表（**两类人共用一张表**）

> 规则见 §13.11。**一张表装两种人**：管理端登录账号（`AccountType = Admin`）与作业屏人员名单（`AccountType = Operator`）。
> **为什么要合并**：避免"账号表"和"师傅名单表"两处维护同一个人，改名/离职要改两个地方，必然不一致。

| 字段 | 类型 | 可空 | 默认 | 说明 |
|------|------|:----:|------|------|
| `Uid` | Guid | 否 | — | 主键 |
| `StoreId` | Guid | 否 | — | 门店 UID |
| **`UserName`** | nvarchar(64) | 否 | — | 登录名 / 屏上选人标识（**不区分大小写**，唯一） |
| `DisplayName` | nvarchar(64) | 否 | — | 显示名（屏上"张师傅"、报表"操作人"） |
| **`AccountType`** | Enum | 否 | `Admin` | **`Admin`（可登录管理端）/ `Operator`（仅屏上选人，不可登录）** |
| **`Role`** | Enum | 是 | — | `Owner` / `Manager` / `Viewer`；`AccountType = Operator` 时为空 |
| `PasswordHash` | nvarchar(256) | 是 | — | **PBKDF2-HMAC-SHA256（≥10 万次）或 Argon2id**；`Admin` 与 `Operator` **均需密码**（§13.11.2 屏登录） |
| `PasswordSalt` | nvarchar(64) | 是 | — | 每账号独立盐（若算法输出内含盐则空） |
| `PasswordIterations` | int | 是 | — | 迭代次数（便于日后升级算法时兼容旧哈希） |
| `MustChangePassword` | bit | 否 | 0 | 首登强制修改（Owner 重置后置 1） |
| `PasswordUpdatedAt` | datetimeoffset | 是 | — | 上次改密时间 |
| **`IsEnabled`** | bit | 否 | 1 | 停用后立即踢下线且不可登录 |
| `IsRosterVisible` | bit | 否 | 1 | 是否出现在作业屏【换人】列表 |
| `Phone` | nvarchar(32) | 是 | — | 联系方式（可选） |
| **`Position`** | nvarchar(32) | 是 | — | **岗位**（切配/制作/传菜/打荷…；仅 `Operator`，用于人员维度统计与换人列表分组） |
| **`Source`** | Enum | 否 | **`Local`** | **账号来源**：`Local`（KDS 手工建）/ `Pos`（从 POS 同步，§13.11.11） |
| **`ExternalId`** | nvarchar(64) | 是 | — | **POS 员工 ID**（`Source = Pos` 时必填，同步匹配键） |
| `SyncedAt` | datetimeoffset | 是 | — | 最后一次从 POS 同步的时间 |
| **`RoleOverriddenByAdmin`** | bit | 否 | 0 | 角色被管理端手工改过（同步时**不覆盖**，列表标"已手工调整"） |
| **`FailedLoginCount`** | int | 否 | 0 | 连续失败次数（成功即清零） |
| **`LockedUntil`** | datetimeoffset | 是 | — | 锁定到期时间（§13.11.3：5 次失败锁 15 分钟） |
| `LastLoginAt` | datetimeoffset | 是 | — | 最后登录时间 |
| `Remark` | nvarchar(200) | 是 | — | 备注 |
| `CreatedAt` / `CreatedBy` | datetimeoffset / nvarchar(64) | 否 / 是 | — | 审计 |
| `UpdatedAt` / `UpdatedBy` | datetimeoffset / nvarchar(64) | 否 / 是 | — | 审计 |
| `IsDeleted` | bit | 否 | 0 | 软删除（离职不硬删，保审计可追溯） |

**业务唯一键**：`UX_UserAccount_Name (StoreId, UserName)` —— 唯一索引 + **collation 不区分大小写**（或用 `UserNameLower` 归一化列，避免依赖 DB collation）。

**索引**：`IX_UserAccount_Type (StoreId, AccountType, IsEnabled)` —— 屏上【换人】列表查询；`IX_UserAccount_Role (StoreId, Role)`。

**事件：`Staff.Sync`（POS → KDS，§13.11.11）**

```json
{
  "EventType": "Staff.Sync",
  "Payload": {
    "SyncMode": "Incremental",            // Full / Incremental
    "Staff": [
      { "ExternalId": "E1024", "StaffNo": "A05", "Name": "张师傅",
        "PosRole": "厨师", "Position": "炒锅", "IsActive": true },
      { "ExternalId": "E1025", "StaffNo": "A06", "Name": "李四",
        "PosRole": "传菜员", "Position": "传菜", "IsActive": false }
    ]
  }
}
```

| 字段归属（**同步时以 POS 为准**） | 说明 |
|------------------------------------|------|
| `UserName` / `DisplayName` / `Position` / `IsEnabled` | **POS 覆盖**；KDS UI 置灰不可改 |
| `PasswordHash` / `Salt` / `Iterations` | **KDS 独占**，同步绝不覆盖 |
| `IsRosterVisible` | KDS 独占 |
| `Role` | 由 `PosRoleMapJson` 映射；若 `RoleOverriddenByAdmin = 1` 则不覆盖 |

| 同步规则 | 说明 |
|----------|------|
| 匹配键 | `ExternalId` 优先，回退 `工号`；都不匹配 → **新建**（`Source = Pos`，`MustChangePassword = 1`） |
| POS 删人 | **不物理删除**：`IsEnabled = 0` + **撤销该账号所有 `UserSession`** |
| POS 角色未映射 | **不同步该人**，并进健康检查（`POS_ROLE_UNMAPPED`），避免把服务员误升为 Owner |
| POS 不可达 | 同步失败**不影响营业**；继续用上次数据，健康检查报 Warn |
| 增量 vs 全量 | 增量按 `ExternalId` upsert；**全量不删本地 `Source = Local` 的账号** |



| 规则 | 说明 |
|------|------|
| `AccountType = Operator` → **`PasswordHash` 必填**、`Role` 可为空 | **屏账号能登录作业屏**（§13.11.5），但**不能登录管理端** |
| `AccountType = Admin` → `PasswordHash` / `Role` 必填 | — |
| 至少保留 **1 个启用的 `Owner`** | 否则没人能改配置（删除/停用前校验） |

### 9.15e LoginLog 登录日志表

> 只追加。用于安全审计与"谁在什么时候登过"的排查。保留 180 天（§13.6 L4）。

| 字段 | 类型 | 可空 | 默认 | 说明 |
|------|------|:----:|------|------|
| `Uid` | Guid | 否 | — | 主键 |
| `StoreId` | Guid | 否 | — | 门店 UID |
| **`UserName`** | nvarchar(64) | 否 | — | 尝试登录的账号（可能不存在——用于识别撞库） |
| `UserId` | Guid | 是 | — | 匹配到的账号（不存在则为空） |
| **`Success`** | bit | 否 | — | 是否成功 |
| **`FailReason`** | Enum | 是 | — | `BadPassword` / `NoSuchUser` / `Disabled` / `LockedOut` / `MustChangePassword`（**对外统一提示，仅内部记录**） |
| `IpAddress` | nvarchar(45) | 是 | — | IPv4/IPv6 |
| `UserAgent` | nvarchar(300) | 是 | — | 浏览器标识 |
| `SessionId` | nvarchar(64) | 是 | — | 成功时生成的会话标识（便于追溯后续操作） |
| `OccurredAt` | datetimeoffset | 否 | — | 时间 |

**索引**：`IX_LoginLog_User_Time (StoreId, UserName, OccurredAt)` —— 查某账号登录史/锁定判定；`IX_LoginLog_Fail (StoreId, Success, OccurredAt)` —— 异常登录排查。

### 9.15f UserSession 会话表（**屏无感登录的落地点**）

> 规则见 §13.11.2 / §13.11.7。**只存令牌哈希，不存明文**；令牌与终端绑定，拷到别的机器无效。

| 字段 | 类型 | 可空 | 默认 | 说明 |
|------|------|:----:|------|------|
| `Uid` | Guid | 否 | — | 主键 |
| `StoreId` | Guid | 否 | — | 门店 UID |
| **`UserId`** | Guid | 否 | — | 关联 `UserAccount` |
| **`TokenHash`** | nvarchar(64) | 否 | — | **令牌的 SHA256（十六进制）**；明文只在客户端，服务端不存 |
| **`SessionType`** | Enum | 否 | — | **`Screen`（长期无感）/ `Admin`（短会话）** |
| **`TerminalId`** | Guid | 是 | — | **绑定的终端**（`Screen` 必填；`Admin` 可空） |
| `DeviceKey` | nvarchar(200) | 是 | — | 绑定时的设备指纹（终端重置后失配 → 会话失效） |
| **`ExpiresAt`** | datetimeoffset | 是 | — | **绝对有效期**（`ScreenSessionDays = 0` 即"永久"时为空） |
| `LastSeenAt` | datetimeoffset | 否 | — | 最后活动时间（管理端"在线会话"展示） |
| **`RevokedAt`** | datetimeoffset | 是 | — | 撤销时间（手动退出 / 踢下线 / 停用 / 改密） |
| `RevokedReason` | Enum | 是 | — | `Logout` / `KickedByAdmin` / `Disabled` / `PasswordChanged` / `RoleChanged` / `TerminalReset` |
| `RotationCount` | int | 否 | 0 | 轮转次数（每次自动登录成功 +1，便于识别异常频繁轮转） |
| `IpAddress` | nvarchar(45) | 是 | — | 最近一次来源 IP |
| `UserAgent` | nvarchar(300) | 是 | — | 最近一次 UA |
| `CreatedAt` | datetimeoffset | 否 | — | 创建时间 |

**索引**：
`UX_UserSession_TokenHash (TokenHash)` —— **自动登录校验热路径**（每次开屏查一次）；
`IX_UserSession_User (UserId, RevokedAt)` —— 停用/改密时批量撤销、管理端按人查；
`IX_UserSession_Terminal (TerminalId, RevokedAt)` —— 终端会话列表、重置 `DeviceKey` 时批量撤销。

**生命周期规则**

| 事件 | 会话处理 |
|------|----------|
| 屏一次登录成功 | 插入一条 `Screen` 会话（`TerminalId` 必填） |
| 屏自动登录成功 | **轮转**：旧会话置 `RevokedAt`，插入新会话（`RotationCount + 1`） |
| 手动退出 | 该会话 `RevokedAt` + `RevokedReason = Logout` |
| Owner 踢下线 | `RevokedReason = KickedByAdmin` |
| 账号停用 / 改密 / 改角色 | **该用户所有会话**立即撤销 |
| 终端重置 `DeviceKey` / 删除终端 | 该终端所有 `Screen` 会话撤销 |
| 后台清理 | 已撤销且超 30 天的会话行可物理删除（保留期与 `LoginLog` 一致 180 天） |

### 9.16 LocalizedText JSON 约定

所有多语言文本字段（`OrderHeader.Remark`、`Station.Name`、`DishItem.ItemName`、`DishType.TypeName` 等）统一结构：

```json
{
  "zh-CN": "宫保鸡丁",
  "en-US": "Kung Pao Chicken"
}
```

**解析规则**：

1. 取当前屏幕 `CurrentLang` 对应值；
2. 缺失 → 取 `StoreConfig.DefaultLang`；
3. 仍缺失 → 取对象中**任意一个非空值**（按 key 字典序）；
4. 全空 → 展示**空字符串**，不展示 key 名（避免界面出现 `zh-CN` 之类噪音）；
5. 兼容**纯字符串**输入（POS 可能直接传字符串而非对象），此时视为单语言值直接使用。

### 9.17 PrinterConfig 打印机配置表

| 字段 | 类型 | 可空 | 默认 | 说明 |
|------|------|:----:|------|------|
| `Uid` | Guid | 否 | — | 主键 |
| `StoreId` | Guid | 否 | — | 门店 UID |
| `PrinterName` | nvarchar(200) | 否 | — | 打印机名称（管理端显示） |
| `Model` | nvarchar(100) | 是 | — | 型号（用于兼容清单标识） |
| `ConnectionType` | Enum | 否 | `Network` | `Network`（TCP） / `Usb` / `Bluetooth` |
| `PrinterHost` | nvarchar(64) | 是 | — | IP（`Network` 必填） |
| `PrinterPort` | int | 是 | 9100 | 端口（`Network`） |
| `ExecutorTerminalId` | Guid | 是 | — | **执行终端**（`Usb` / `Bluetooth` 必填；`Network` 为空表示由 Master 执行） |
| `OwnerStationId` | Guid | 是 | — | 归属档口（路由用；见 §16.3） |
| `PaperWidth` | Enum | 否 | `Mm58` | `Mm58` / `Mm80` |
| `Encoding` | nvarchar(32) | 否 | `GB18030` | 编码（ESC/POS 中文必须 GB18030） |
| `RenderMode` | Enum | 否 | `Image` | `Image`（位图，兼容性最好）/ `EscPos`（原生指令，快） |
| `IsEnabled` | bit | 否 | 1 | 是否启用 |
| `LastSeenAt` | datetimeoffset | 是 | — | 最近一次连通性检测成功时间 |
| `CreatedAt` / `UpdatedAt` | datetimeoffset | 否 | — | 审计字段 |
| `IsDeleted` | bit | 否 | 0 | 软删除 |

**索引**：`IX_PrinterConfig_Station (StoreId, OwnerStationId)`；`IX_PrinterConfig_Executor (ExecutorTerminalId)`。

### 9.18 PrintRule 打印规则表（阶段 × 档口 → 打印机 + 模板）

| 字段 | 类型 | 可空 | 默认 | 说明 |
|------|------|:----:|------|------|
| `Uid` | Guid | 否 | — | 主键 |
| `StoreId` | Guid | 否 | — | 门店 UID |
| `StationId` | Guid | 否 | — | 目标档口 |
| `Stage` | Enum | 否 | — | 目标阶段（`Prep` / `Cook` / `Expo`） |
| `Trigger` | Enum | 否 | `OnStageComplete` | `OnStageEnter` / `OnStageComplete` / `OnOrderDone` / `OnItemCancel` / `OnRemind` / `None` |
| `TemplateId` | Guid | 是 | — | 使用模板（`Trigger = None` 时为空） |
| `PrinterId` | Guid | 是 | — | 执行打印机（为空则按 §16.3 去重规则自动选） |
| `Copies` | int | 否 | 1 | 份数（V2） |
| `IsEnabled` | bit | 否 | 1 | 是否启用 |
| `CreatedAt` / `UpdatedAt` | datetimeoffset | 否 | — | 审计字段 |
| `IsDeleted` | bit | 否 | 0 | 软删除 |

**业务唯一键**：`UX_PrintRule_Station_Stage (StationId, Stage)`（一个档口一个阶段一条规则）。

### 9.19 PrintTemplate 打印模板表

| 字段 | 类型 | 可空 | 默认 | 说明 |
|------|------|:----:|------|------|
| `Uid` | Guid | 否 | — | 主键 |
| `StoreId` | Guid | 否 | — | 门店 UID |
| `TemplateName` | nvarchar(200) | 否 | — | 模板名称 |
| `TemplateKind` | Enum | 否 | `ItemSlip` | `OrderSummary`（整桌划菜汇总）/ `ItemSummary`（划菜汇总·按品项）/ `ItemSlip`（划菜单·跟盘单） |
| `TasteLayout` | Enum | 否 | `OwnLine` | **做法排法**（§16.4.2）：`OwnLine`（独立成行，默认）/ `Column`（独立列）/ `Inline`（括号内联菜名） |
| `Lang` | nvarchar(16) | 否 | `zh-CN` | 适用语言（多语言模板各自一份） |
| `BodyHtml` | nvarchar(MAX) | 否 | — | 模板正文（受限 HTML/CSS 子集，§16.5） |
| `Variables` | nvarchar(MAX) | 是 | — | 使用的变量清单（校验用） |
| `Version` | int | 否 | 1 | 模板版本（打印任务快照引用） |
| `IsDefault` | bit | 否 | 0 | 是否该类型默认模板 |
| `CreatedAt` / `UpdatedAt` | datetimeoffset | 否 | — | 审计字段 |
| `IsDeleted` | bit | 否 | 0 | 软删除 |

### 9.20 PrintJob 打印任务表（每执行终端独立队列）

| 字段 | 类型 | 可空 | 默认 | 说明 |
|------|------|:----:|------|------|
| `Uid` | Guid | 否 | — | 主键 |
| `StoreId` | Guid | 否 | — | 门店 UID |
| `DetailId` | Guid | 是 | — | 关联明细（`OrderSummary` / `ItemSummary` 记录首条或为空，聚合内容见 `ContentSnapshot`） |
| `OrderId` | Guid | 是 | — | 关联订单 |
| `StationId` | Guid | 是 | — | 触发档口 |
| `Stage` | Enum | 是 | — | 触发阶段 |
| `Trigger` | Enum | 否 | — | 触发类型（同 `PrintRule.Trigger`） |
| `PrinterId` | Guid | 否 | — | 目标打印机 |
| `ExecutorTerminalId` | Guid | 是 | — | **执行终端**（网络机为空 = Master 执行）；**队列归属键** |
| `TemplateId` | Guid | 是 | — | 使用的模板 |
| `TemplateVersion` | int | 是 | — | 模板版本快照 |
| `RenderMode` | Enum | 否 | `Image` | 渲染模式快照 |
| `ContentSnapshot` | nvarchar(MAX) | 否 | — | **冻结的渲染内容**（补打用，避免改名后单据与盘不符） |
| `PrintIndex` | int | 否 | 1 | **第 N 次打印**（≥2 为补打，单据上必须显示） |
| `IdempotencyKey` | nvarchar(160) | 否 | — | 幂等键：`DetailId + Stage + Trigger`（同一键自动打印只允许一次） |
| `Status` | Enum | 否 | `Pending` | `Pending` / `Printing` / `Success` / `Failed` / `DeadLetter` / `Cancelled` |
| `Priority` | int | 否 | 0 | 越大越先（退菜单最高） |
| `RetryCount` | int | 否 | 0 | 重试次数（上限默认 5） |
| `LeaseUntil` | datetimeoffset | 是 | — | 执行端领取租约（超时自动回收为 `Pending`） |
| `ErrorMessage` | nvarchar(MAX) | 是 | — | 失败原因 |
| `CompletedAt` | datetimeoffset | 是 | — | 打印成功时间 |
| `CreatedAt` / `UpdatedAt` | datetimeoffset | 否 | — | 审计字段 |

**索引**：
`IX_PrintJob_Queue (ExecutorTerminalId, Status, Priority DESC, CreatedAt)` —— 执行端拉取自己的队列；
`UX_PrintJob_Idempotency (IdempotencyKey, PrintIndex)` —— 防重复自动打印；
`IX_PrintJob_Printer (PrinterId, Status)` —— 同打印机串行化与状态监控；
`IX_PrintJob_Created (CreatedAt)` —— 记录查询与清理。

**清理策略**：`Success` 保留 30 天；`DeadLetter` 保留 90 天（与 §13.6 一致）。

### 9.21 TerminalPane 屏内分区表（**V1.1 功能预留；V1 建表但不开入口**）

> 用途与规则见 §3.7。
> **V1 落地口径（v6.95 定）**：表**照建**（两份 DDL 均含 `TerminalPane`，计入 29 表），字段结构即为 V1.1 终态，避免 V1.1 再加迁移；但 **V1 不开放任何配置入口**、管理端不展示、API 不暴露 CRUD，运行时 `TerminalConfig.PaneLayout` **恒为 `Single`**，每终端最多 1 个分区且该分区无实际作用。
> 即：**DDL 存在 ≠ 功能启用**。数据行数在 V1 恒为 0（除迁移自检可写 1 条默认分区）。

| 字段 | 类型 | 可空 | 默认 | 说明 |
|------|------|:----:|------|------|
| `Uid` | Guid | 否 | — | 主键 |
| `TerminalId` | Guid | 否 | — | 所属终端（`TerminalConfig.TerminalId`） |
| `PaneIndex` | int | 否 | — | 0 / 1 / 2，显示顺序 |
| `StationIds` | nvarchar(MAX) | 否 | — | **本栏关联档口**（GUID 逗号分隔，1~N 个，必须是终端绑定档口的子集） |
| `PaneTitle` | nvarchar(64) | 是 | — | 栏标题（默认取档口名） |
| `SortMode` | Enum | 否 | `WaitDuration` | 本栏排序：`WaitDuration` / `TableOrder` |
| `WidthWeight` | decimal(5,2) | 否 | 1.00 | 宽度权重（**V1.1 固定 1.00，不启用拖拽**） |
| `DefaultFilter` | nvarchar(MAX) | 是 | — | 本栏默认筛选（JSON，可空） |
| `CreatedAt` / `UpdatedAt` | datetimeoffset | 否 | — | 审计字段 |
| `IsDeleted` | bit | 否 | 0 | 软删除 |

**业务唯一键**：`UX_TerminalPane_Index (TerminalId, PaneIndex)`。

**校验（保存时执行，§3.7.5）**：档口子集、栏间不重叠、并集覆盖全部终端档口、栏数与档口数匹配。

### 9.21a OrderDetailStageLog 明细阶段时间线表

> **为什么必须有这张表**：`OrderDetail` 上的 `StageBeginTime` / `StageCompleteTime` / `StageElapsedSeconds` **只保留"当前阶段"**——阶段一推进，上一阶段的时刻就被覆盖，**历史阶段的进入/离开时刻永久丢失**。而没有这些时刻，就**算不出"后态与前态的时间间隔"**（如切配完成 → 制作开始之间等了多久、传菜等了多久）。
> 本表为**每阶段一行的不可变时间线**，是阶段时长、间隔、瓶颈分析、越级审计的唯一权威来源。

| 字段 | 类型 | 可空 | 说明 |
|------|------|:----:|------|
| `Uid` | Guid | 否 | 主键 |
| `DetailId` | Guid | 否 | 关联 `OrderDetail.DetailId` |
| `OrderId` | Guid | 否 | 冗余（便于按单查询） |
| `BusinessDate` | date | 否 | 营业日（冗余，用于按日聚合与归档分卷） |
| `Stage` | Enum | 否 | `Prep` / `Cook` / `Expo` |
| **`EnterAt`** | datetimeoffset | 否 | **进入该阶段时刻**（状态变为该阶段时写入） |
| **`ExitAt`** | datetimeoffset | 是 | **离开该阶段时刻**（完成或退菜时写入；进行中为空） |
| `ElapsedSeconds` | int | 是 | 该阶段实际耗时（`ExitAt - EnterAt`，完成时计算落库） |
| **`WaitSeconds`** | int | 是 | **进入前的等待间隔** = `EnterAt - 上一阶段的 ExitAt`（首个阶段 = `EnterAt - OrderCreateTime`） |
| `StationId` | Guid | 是 | 该阶段的主档口（快照，§2.2.1） |
| `OperatorName` | nvarchar(64) | 是 | 完成该阶段的操作人 |
| `EnterSource` | Enum | 否 | `Auto`（自动流转）/ `Manual`（人工推进）/ `Skip`（越级直接落到该阶段） |
| `ExitReason` | Enum | 是 | `Completed` / `Cancelled` / `Closed`（跨日清理，§2.14）/ `Void` |
| **`IsReverted`** | bit | 否 | `1` = 该阶段记录已被撤销作废（§2.19.3）；统计时**必须排除**，否则撤销会让产量虚增 |
| `CreatedAt` | datetimeoffset | 否 | 写入时间 |

**索引**：
`UX_StageLog_Detail_Stage (DetailId, Stage)` —— 一条明细每个阶段只有一行；
`IX_StageLog_Biz_Stage (BusinessDate, Stage)` —— 按日聚合各阶段时长；
`IX_StageLog_Station (BusinessDate, StationId, Stage)` —— 档口×阶段绩效与瓶颈分析。

**关键用途（后态与前态间隔怎么算）**

```
切配 → 制作 的间隔 = StageLog(Cook).EnterAt   - StageLog(Prep).ExitAt
制作 → 传菜 的间隔 = StageLog(Expo).EnterAt   - StageLog(Cook).ExitAt
整菜总时长         = StageLog(Expo).ExitAt    - StageLog(Prep).EnterAt
```

| 场景 | `WaitSeconds` 的取值特征 |
|------|--------------------------|
| 自动流转（推进即时） | `WaitSeconds ≈ 0`（前一阶段完成的同时进入下一阶段） |
| 手动流转（下游代办/排队） | `WaitSeconds > 0`，反映真实等待（如制作积压导致传菜前等待） |
| 越级完成（`A → C`） | 没有 `Cook` 的 StageLog 行；`Expo.EnterSource = Skip`，`WaitSeconds` 从 `Prep.ExitAt`（或 `OrderCreateTime`）起算 |

> **不可变性**：`ExitAt` 一旦写入不可修改（除非走管理端"恢复"流程并记 `OperationLog`）。阶段时间线是审计证据，**不允许静默重算**。
> **与 `OperationLog` 的分工**：`OperationLog` 记"谁做了什么动作"（审计），本表记"状态时间线"（统计）。两者互补，不重复。
> **归档**：随 `OrderDetail` 一同进入归档卷（§13.6.4），卷内建 `IX_Archive_StageLog_Detail`（**历史卷内部索引，不计入主库 72 索引**）。

### 9.22 DailyStoreStat 门店日统计表（**L3 统计层，永久保留**）

> 由 §13.6.3 的 T+1 预聚合任务产出（每日 03:00）。**一天一行**，体积可忽略，**永不清理**。

| 字段 | 类型 | 可空 | 说明 |
|------|------|:----:|------|
| `Uid` | Guid | 否 | 主键 |
| `StoreId` | Guid | 否 | 门店 UID |
| `StatDate` | date | 否 | 统计日期（营业日） |
| `OrderCount` | int | 否 | 订单数 |
| `DetailCount` | int | 否 | 明细行数 |
| `TotalQty` | decimal(18,3) | 否 | 总份数 |
| `CancelledCount` | int | 否 | 退菜明细数（**条数**） |
| **`CancelledQty`** | decimal(18,3) | 否 | **退菜份数合计**（报表 KPI 用"份"，§13.6.7） |
| **`OutputQty`** | decimal(18,3) | 否 | **已出品份数**（`CompletedQty` 合计）——"热销菜品""出品数"用它，**不是下单份数** |
| **`CancelledAmount`** | decimal(18,4) | 否 | **退菜金额合计**（依赖 POS 推送 `Amount`，缺失时为 0） |
| **`RemindCount`** | int | 否 | **催单明细数**（条） |
| **`RemindQty`** | decimal(18,3) | 否 | **催单份数合计** |
| `GiftCount` | int | 否 | 赠菜明细数 |
| `GuestCount` | int | 否 | 就餐人数合计 |
| `TableCount` | int | 否 | 涉及桌台数（去重） |
| `AvgElapsedSeconds` | int | 否 | 平均**总出品时长**（秒，= 点菜→制作完成，§4.4.1）——**展示用，不可用于跨周期加权** |
| **`SumElapsedSeconds`** | bigint | 否 | **时长总和（可加总）**：云端算周/月平均时用 `ΣSum / ΣCount`，**不能用日平均再平均** |
| **`ElapsedCount`** | int | 否 | **时长样本数**（= 参与计算的明细数，加权分母） |
| `P50ElapsedSeconds` | int | 是 | 中位数（**仅当日有效**，跨周期需用直方图重算） |
| `P90ElapsedSeconds` | int | 是 | P90（同上） |
| `MaxElapsedSeconds` | int | 是 | 最大（跨周期取 `max`，可加总） |
| **`ElapsedBuckets`** | nvarchar(MAX) | 是 | **时长直方图**（JSON，固定 12 桶：0-2/2-5/5-8/8-10/10-15/15-20/20-25/25-30/30-45/45-60/60-90/90+ 分钟）。**跨周期分位数唯一可精确近似的方式**（§9.23 说明） |
| `TimeoutCount` | int | 否 | 超时明细数 |
| **`TimeoutQty`** | decimal(18,3) | 否 | **超时份数合计**（KPI "超时数 8 份"口径） |
| **`SkipDoneCount`** | int | 否 | **越级完成明细数**（§2.7.1 ⑤）；`SkipDoneCount / DoneCount` = **越级完成率** |
| **`VoidCount`** | int | 否 | **报损明细数**（§2.17） |
| **`VoidQty`** | decimal(18,3) | 否 | **报损份数**（已出品后作废，与退菜分开统计） |
| **`VoidAmount`** | decimal(18,4) | 否 | **报损金额**（依赖 POS 推 `Amount`） |
| **`UndoCount`** | int | 否 | **撤销次数**（§2.19.10） |
| **`UndoRate`** | decimal(5,4) | 否 | **撤销率** = `UndoCount / StageCompleteCount`；>10% 说明划单动作设计有问题 |
| `TimeoutRate` | decimal(5,4) | 否 | 超时率（0~1） |
| **`SumWaitBeforeBumpSeconds`** | bigint | 是 | 划单前等待时长总和（可加总） |
| `CreatedAt` | datetimeoffset | 否 | 聚合生成时间 |
| `CalcVersion` | int | 否 | **聚合算法版本**（口径变更时递增，便于识别旧数据） |
| **`CrossDayOpenCount`** | int | 否 | **跨营业日仍在进行中的明细数**（§2.14；`CrossDayHandleMode` 处置前的存量，衡量交接质量） |
| **`CrossDayClosedCount`** | int | 否 | **被自动/手动关闭的跨日明细数**（`ExitReason = Closed`） |
| **`HqUploadedAt`** | datetimeoffset | 是 | **上云回执时刻**（§14.2.7）；空 = 待上传 |

**业务唯一键**：`UX_DailyStoreStat_Date (StoreId, StatDate)`。

> **可加总性原则（写死）**：凡是要"跨日/跨月汇总"的指标，**必须同时上传分子与分母**（`Sum` + `Count`），不能只传平均值。否则云端周报只能"把 7 天的日均再平均"，周末单量少的日子会被过度放大，数字必然错。
> **分位数同理不可加总**：日 P90 不能平均成周 P90。用 `ElapsedBuckets` 直方图在云端**按桶累加后重算分位数**，误差由桶宽决定（本例最宽 30 分钟，用于运营分析足够）。

### 9.23 DailyDimStat 维度日统计表（**L3 统计层，永久保留**）

> 同一张表承载 **档口 / 品项 / 时段** 三种维度，用 `Dimension` 区分；避免为每个维度建一张表。

| 字段 | 类型 | 可空 | 说明 |
|------|------|:----:|------|
| `Uid` | Guid | 否 | 主键 |
| `StoreId` | Guid | 否 | 门店 UID |
| `StatDate` | date | 否 | 统计日期 |
| `Dimension` | Enum | 否 | 见下方维度枚举（8 种） |
| `DimKey` | nvarchar(120) | 否 | 维度键，格式见下方枚举表 |
| `DimNameSnapshot` | nvarchar(200) | 是 | 维度名称快照（档口/品项改名后历史仍可读） |
| `DetailCount` | int | 否 | 明细行数 |
| `TotalQty` | decimal(18,3) | 否 | 份数合计（**下单份数**；与 `OutputQty` 区分，见 §13.6.8 ⑤） |
| **`OutputQty`** | decimal(18,3) | 否 | **已出品份数**（热销榜用它） |
| **`CancelledQty`** | decimal(18,3) | 否 | 退菜份数（该维度内） |
| **`CancelledAmount`** | decimal(18,4) | 否 | 退菜金额 |
| **`RemindCount`** | int | 否 | 催单条数 |
| **`RemindQty`** | decimal(18,3) | 否 | 催单份数 |
| **`TimeoutQty`** | decimal(18,3) | 否 | 超时份数 |
| **`VoidQty`** | decimal(18,3) | 否 | 报损份数（§2.17） |
| **`VoidAmount`** | decimal(18,4) | 否 | 报损金额 |
| `AvgElapsedSeconds` | int | 是 | 平均时长（展示用，**不可跨周期加总**） |
| **`SumElapsedSeconds`** | bigint | 否 | **时长总和（可加总）**：云端算周/月均用 `ΣSum / ΣCount` |
| **`ElapsedCount`** | int | 否 | 时长样本数（加权分母） |
| `P90ElapsedSeconds` | int | 是 | P90 时长（仅当日有效，跨周期用直方图重算） |
| `TimeoutCount` | int | 否 | 超时数 |
| `CancelledCount` | int | 否 | 退菜数 |
| `GiftCount` | int | 否 | 赠菜数 |
| `OrderCount` | int | 否 | 订单数（去重，供翻台/客单分析） |
| `CreatedAt` | datetimeoffset | 否 | 聚合生成时间 |
| `CalcVersion` | int | 否 | 聚合算法版本 |
| **`HqUploadedAt`** | datetimeoffset | 是 | **上云回执时刻**（§14.2.7）；空 = 待上传 |

**业务唯一键**：`UX_DailyDimStat (StoreId, StatDate, Dimension, DimKey)`；
**索引**：`IX_DailyDimStat_Dim (Dimension, DimKey, StatDate)`（查某档口/某品项的趋势）。

**维度枚举（8 种，覆盖餐饮运营报表的绝大多数交叉分析）**

| `Dimension` | `DimKey` 格式 | 回答什么问题 |
|-------------|---------------|--------------|
| `Station` | `{StationId}` | 各档口产量与效率 |
| `StationStage` | `{StationId}#{Stage}` | **瓶颈定位**：切配慢还是制作慢 |
| `Item` | `{DishItemId}` | 菜品销量排行、慢菜识别 |
| **`ItemStation`** | `{DishItemId}#{StationId}` | 某道菜在哪个档口做、各档口分摊 |
| **`OrderType`** | `DineIn` / `Takeaway` / `Pickup` | **堂食 vs 外卖**效率差异（外卖通常要求更快） |
| **`MealPeriod`** | `Breakfast` / `Lunch` / `Dinner` / `LateNight` | **餐段对比**（比"小时"更贴餐饮口径） |
| **`Area`** | `{AreaNameSnapshot}` | 区域 / 楼层产能（联台与跨区影响） |
| `Hour` | `00`~`23` | 峰值时段、排班依据 |

> **为什么除 `Hour` 还要 `MealPeriod`**：餐饮运营看的是"午市/晚市"，不是"14 点"。餐段边界由门店配置，聚合时打标签，云端直接可用。
> **为什么加 `ItemStation`**：一道菜可能被多个档口命中（§2.11 的 `MULTI_STATION_SAME_STAGE` 风险项），按此维度聚合能直接暴露"某菜长期由两个档口各做一遍"。

**数据量估算**：8 维度 × 平均 30 个维度值 × 1 天 ≈ **240 行/日** → 一年约 8.8 万行、SQLite 约 **8~12 MB**，永久保留无压力；上云每日仅传当日约 240 行（**< 30 KB**）。

> **`DimNameSnapshot` 必须有**：档口改名（"热菜制作1"→"热炒A"）后，若报表直接 join 主数据，历史数据名称会跟着变，看起来像"历史被改写"。快照保证「当时叫什么就是什么」。

### 9.24 ArchiveVolume 本地历史卷登记表（**L5 历史层**）

> 用途与三模式见 §14.1.3 / §14.1.5（主库外历史卷）。**一条记录 = 一个营业月的一卷**；历史卷本体是独立 SQLite 文件，本表只登记元数据与迁移水位，**永久保留**。
> 本表在 §9 表清单第 22 项，此前仅指向 §14.1.5 未列字段级定义，**v6.95 补齐**（与 DDL 逐列对齐）。

| 字段 | 类型 | 可空 | 默认 | 说明 |
|------|------|:----:|------|------|
| `Uid` | Guid | 否 | — | 主键 |
| `StoreId` | Guid | 否 | — | 门店 UID |
| **`VolumeMonth`** | nvarchar(7) | 否 | — | **营业月**（`YYYY-MM`），业务唯一键之一 |
| `BusinessDateFrom` | date | 是 | — | 卷内最早营业日（封卷时回填） |
| `BusinessDateTo` | date | 是 | — | 卷内最晚营业日 |
| `FileName` | nvarchar(200) | 是 | — | 历史卷文件名 |
| `FilePath` | nvarchar(500) | 是 | — | 相对路径（**不写绝对路径**，避免换机/换盘失效） |
| `Engine` | Enum | 否 | `Sqlite` | 卷引擎：`Sqlite` / `SqlServer`（与主库引擎解耦，便于日后迁移） |
| `RowCount` | int | 是 | — | 卷内订单明细行数 |
| `SizeBytes` | bigint | 是 | — | 卷文件大小（字节） |
| `Checksum` | nvarchar(64) | 是 | — | 封卷校验和（SHA256，用于完整性自检） |
| **`Status`** | Enum | 否 | `Writing` | `Writing`（可追加）/ `Sealed`（已封卷只读）/ `Uploaded`（已上云）/ `Corrupted`（校验失败）/ `Deleted`（已删除） |
| **`LastMovedBusinessDate`** | date | 是 | — | **迁移水位**：主库已搬到本卷的最后营业日；断点续搬据此重入（§14.1.5） |
| `SealedAt` | datetimeoffset | 是 | — | 封卷时刻 |
| `HqUploadedAt` | datetimeoffset | 是 | — | 上云回执时刻 |
| `HqRecordCount` | int | 是 | — | 上云记录数（与 `RowCount` 对账用） |
| `DeletedAt` | datetimeoffset | 是 | — | 物理删除时刻（仅 `DeleteAfterUpload` 类模式会产生） |
| `CreatedAt` / `UpdatedAt` | datetimeoffset | 否 | — | 审计字段 |

**业务唯一键**：`UX_ArchiveVolume_Month (StoreId, VolumeMonth)`。

> **`Status = Writing` 的卷必须唯一**：同一门店同一时刻只允许一个可写卷，否则迁移会分叉。切换月份时先把旧卷 `Sealed` 再开新卷，整个过程在维护窗口内完成（§2.13.4）。

---


