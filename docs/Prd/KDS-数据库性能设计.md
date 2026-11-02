# KDS 数据库性能设计

> 版本：v6.70　对应章节：§8.5 / §8.6（本文为独立可执行版本，含索引清单、查询模式、调优与验收）
> 读者：后端开发、DBA、实施
> 前置：数据字典见 [KDS-07-数据库与数据字典.md](KDS-07-数据库与数据字典.md)；DDL 见 [KDS-DDL-SQLite.sql](KDS-DDL-SQLite.sql) / [KDS-DDL-SqlServer.sql](KDS-DDL-SqlServer.sql)

---

## 1. 第一原则：**热路径不查库**

> **屏幕数据来自 Master 内存，不来自数据库。**
> 库是**持久化层**，屏是**内存层**。一次变更 → 更新内存投影 → 推送 N 块屏，**全程 0 次数据库查询**。

**为什么这条是第一位**

```
20 屏 × 15s 轮询 = 1.3 QPS          ← 看着不多
但推送会放大：1 次变更 × 20 屏     ← 若每屏查一次库 = 20 倍放大
SQLite 单写者 + 20 倍放大 = 立刻打满
```

**分层与查询预算**

| 层 | 数据来源 | 允许查库 | 目标耗时 |
|----|----------|:--------:|---------|
| 屏幕推送 / 增量同步 | Master 内存投影 | ❌ **禁止** | 单次推送 < 50ms |
| 屏幕全量重同步 | 内存快照（分批） | ❌ 禁止 | 300 条 < 200ms |
| 划单 / 退菜 / 撤销 / 报损 | DB（EF Core 写） | ✅ 必须 | **P95 < 100ms** |
| 报表查询 | DB（Dapper 读） | ✅ | 单页 < 500ms |
| 日统计聚合 | DB（Dapper 单条 SQL） | ✅ | < 3s（维护窗口跑） |
| 归档 MOVE | DB（Dapper 跨库） | ✅ | 后台分批，不阻塞营业 |

**内存层的实现要求（否则退化成查库）**

| 要求 | 说明 |
|------|------|
| 启动全量加载 | Master 启动时把"当前未完成明细 + 配置"加载进内存，之后只增量维护 |
| 写操作同步更新内存 | **先改库成功，再改内存**；顺序反了会出现"屏上有、库里没有" |
| 配置变更走事件 | `ConfigVersion` 递增 → 各屏与 Master 同步刷新缓存 |
| 内存按档口索引 | 预建 `Dictionary<StationId, List<Detail>>`，推送时直接命中，不遍历全量 |
| 重启恢复 | 重启后从库重建内存（一次全量查），此时允许查库 |

---

## 2. EF Core 的七条纪律

| # | 纪律 | 原因 | 反例 |
|:-:|------|------|------|
| 1 | 只读查询**必须** `AsNoTracking()` | 省状态快照，内存降 30~50% | 报表查 5000 行带追踪 → 内存爆 |
| 2 | 列表查询**必须**投影 DTO | 少取列 = 少 IO + 少分配 | `ToListAsync()` 后手动映射 |
| 3 | **禁用懒加载** | 必然 N+1，异步下还会抛异常 | 装 `Microsoft.EntityFrameworkCore.Proxies` |
| 4 | 批量更新用 `ExecuteUpdate` / `ExecuteDelete` | 避免"读 300 改 300 再存" | 循环改实体 |
| 5 | **禁止循环里 `SaveChanges`** | 每次一个事务 + fsync | `foreach { ctx.Save() }` |
| 6 | 分页**一律服务端**（`Skip/Take`） | 内存分页 = 全表拉取 | `ToList().Skip()` |
| 7 | 动态查询用编译查询 | 运行时拼 `Expression` 会破查询缓存 | 反射构造 Where |

### 2.1 乐观锁的正确写法（避免读-改-写）

```csharp
// ✅ 单条 UPDATE，一次往返，Version 条件即并发守卫
var affected = await _db.OrderDetails
    .Where(d => d.DetailId == id && d.Version == expectedVersion)
    .ExecuteUpdateAsync(s => s
        .SetProperty(d => d.CompletedQty, d => d.CompletedQty + qty)
        .SetProperty(d => d.Version, d => d.Version + 1)
        .SetProperty(d => d.StatusUpdatedAt, now)
        .SetProperty(d => d.UpdatedAt, now), ct);

if (affected == 0) throw new ConcurrencyException();   // 冲突，不是失败
```

```csharp
// ❌ 反例：先查、再改、再存（两次往返 + 中间可能被别的屏改掉）
var d = await _db.OrderDetails.FirstAsync(x => x.DetailId == id);
d.CompletedQty += qty;
d.Version++;
await _db.SaveChangesAsync();
```

### 2.2 状态机推进的写路径（一次事务内完成）

```
① 校验（内存中，0 次查库）：该明细是否仍在我这屏、阶段是否匹配
② 单条 ExecuteUpdate 更新 OrderDetail（Version 守卫）
③ 插入 OrderDetailStageLog（一条）
④ 插入 OperationLog（一条，含 FromStage/ToStage/VersionAt）
⑤ 插入 OutboxMessage（回执，入队即返回）
⑥ 提交事务
⑦ 更新内存投影 → 推送各屏
```

> ②~⑤ 在同一事务；⑦ 在事务提交后。**推送失败不回滚写操作**（屏会靠下一次轮询补齐）。

---

## 3. SQLite 专项调优（门店默认库）

### 3.1 建库时定、之后不可改

| 设置 | 值 | 说明 |
|------|----|------|
| `page_size` | **4096** | 创建后不可改；与 OS 页对齐 |
| `auto_vacuum` | **INCREMENTAL** | 创建后不可改；配合定期增量回收 |
| 编码 | UTF-8 | 默认 |

### 3.2 每次连接建立后执行

```sql
PRAGMA journal_mode = WAL;        -- 读写不互斥（最关键一条）
PRAGMA synchronous  = NORMAL;     -- WAL 下足够安全，性能好一个量级
PRAGMA busy_timeout = 5000;       -- 避免瞬时 BUSY 直接抛错
PRAGMA cache_size   = -32000;     -- 32MB 页缓存（负数单位 KB）
PRAGMA mmap_size    = 268435456;  -- 256MB 内存映射
PRAGMA temp_store   = MEMORY;     -- 临时表放内存（报表排序）
PRAGMA foreign_keys = ON;
```

> ⚠️ `journal_mode` 是**库级持久设置**，只需设一次；其余是**连接级**，每次开连接都要设。

### 3.3 单写者串行（**最重要的架构约束**）

SQLite **同时只允许一个写事务**。所有写操作必须走**同一写连接 + 进程内 `SemaphoreSlim(1)`**：

```csharp
private static readonly SemaphoreSlim _writeLock = new(1, 1);

public async Task<T> WriteAsync<T>(Func<DbConnection, Task<T>> action, CancellationToken ct)
{
    await _writeLock.WaitAsync(ct);
    try   { return await action(_writeConnection); }
    finally { _writeLock.Release(); }
}
```

| 不这么做的后果 | 现象 |
|----------------|------|
| 多连接并发写 | 大量 `SQLITE_BUSY` → 重试 → 延迟雪崩 → 超时 |
| 长事务持锁 | 屏幕写操作全部排队，看起来"系统卡了" |

**读连接可以并行**：WAL 下读不阻塞写，读用独立连接（甚至独立连接池），但**同样只读**。

### 3.4 维护窗口（**只能在营业日边界后跑**）

| 任务 | 频率 | 说明 |
|------|------|------|
| `PRAGMA wal_checkpoint(TRUNCATE)` | 每 5 分钟（空闲时） | 防止 WAL 无限膨胀 |
| `PRAGMA incremental_vacuum` | 每日维护窗口 | 回收已删页 |
| `ANALYZE` | 每周 | 更新统计信息，改善查询计划 |
| **`VACUUM`（全量）** | 每月 / 数据大变动后 | **营业中跑会锁库几十秒，绝对禁止** |

> 维护窗口：默认营业日边界后 `MaintenanceWindowStartMinute`（默认 30 分钟）开始，见 §2.13。

### 3.5 容量与增长（单店估算）

| 表 | 90 天估算 | 说明 |
|----|-----------|------|
| `OrderDetail` | ~22.5 万行 / **~250MB** | 500 单/日 × 5 明细 × 90 天 |
| `OrderHeader` | ~4.5 万行 / ~30MB | |
| `OperationLog` | ~45 万行 / ~120MB | 每次划单/撤销一条 |
| `EventLog` | 30 天保留，~15 万行 / ~80MB | 入站全量 |
| `PrintJob` | 7 天清理 | |
| `DailyStoreStat` / `DailyDimStat` | 永久但极小 | |
| **合计（热库）** | **约 500MB ~ 1GB** | 归档卷另计 |

→ 设计上 `DbSizeWarnMb` 默认 2048MB，超过即告警并建议检查归档是否正常工作。

---

## 4. SQL Server 专项

| 项 | 规则 | 原因 |
|----|------|------|
| **`READ_COMMITTED_SNAPSHOT ON`** | **强烈建议开启** | 读写不互斥，防止报表查询阻塞划单写入 |
| 连接池 | Max Pool Size ≈ 屏数 × 2（20 屏 → 60） | 每屏一条长连接 + 余量 |
| 统计信息 | 日统计落库后 `UPDATE STATISTICS` | 报表聚合依赖准确基数 |
| 参数嗅探 | 报表长查询加 `OPTION (RECOMPILE)` | **仅报表**，不要全库加 |
| 执行计划 | 报表 SQL 上线前必须看执行计划 | 确认走覆盖索引，无 `SCAN` |
| 文件组 | 数据与日志分盘 | IO 隔离 |
| 备份 | **KDS 独立备份计划** | 与 POS 库解耦（见选型指南 §4） |

---

## 5. Dapper 的五条纪律

| 规则 | 说明 |
|------|------|
| **必须传 `commandTimeout`** | 报表 30s、日常 5s；不设会用默认 30s 卡住连接池 |
| 参数化查询 | 一律参数化，禁止字符串拼接（注入 + 执行计划复用） |
| 多结果集用 `QueryMultiple` | 一次往返取"合计 + 明细页"，不要查两次 |
| 大结果集**流式读** | 导出 CSV 用 `QueryUnbuffered`，避免一次全载入内存 |
| **复用 EF Core 的连接与事务** | `Database.GetDbConnection()` + `CurrentTransaction`，否则读不到未提交数据 / 死锁 |

---

## 6. 索引清单与用途（72 个索引的归类）

> 完整定义见 DDL。下表按**用途**归类，便于审查"每个索引都有查询对应"。

### 6.1 配置类（低频，小表）

| 索引 | 用途 |
|------|------|
| `UX_StoreConfig_Store` | 单行表，取配置 |
| `UX_TerminalConfig_Code` | 终端绑定（`TerminalCode` 换屏重绑） |
| `UX_DishItem_Code` / `IX_DishItem_Type` | 菜单同步 / 按品类筛选 |
| `UX_DishType_Code` / `UX_DiningTable_Code` / `UX_DiningTable_External` / `IX_DiningTable_Sort` | 主数据 |
| `UX_Station_Code` / `IX_Station_Role` | 档口匹配（启动时一次性加载进内存） |
| `UX_Workflow_Scope` | 流程配置查找 |
| `UX_VoiceTemplate` | 播报模板查找（缓存后低频） |
| `IX_PrinterConfig_Station` / `IX_PrinterConfig_Executor` | 打印路由 / 本机队列 |
| `IX_PrintTemplate_Kind` / `UX_PrintRule_Station_Stage` | 打印规则命中 |
| `UX_TerminalPane_Index` | V1.1 |
| `UX_ScreenLangPack` | 语言包覆盖 |

### 6.2 订单类（高频）

| 索引 | 支撑的查询 | 热度 |
|------|-----------|:----:|
| `UX_OrderHeader_Store_PosNo` | 幂等校验（每个入站事件都查） | 🔥🔥🔥 |
| `IX_OrderDetail_Stage` | 屏数据构建（按阶段筛未完成） | 🔥🔥🔥 |
| `IX_OrderDetail_Station` | 按档口筛明细 | 🔥🔥🔥 |
| `UX_OrderDetail_LineNo` | 按 `(OrderId, LineNo)` 定位明细（退菜/报损） | 🔥🔥 |
| `IX_OrderDetail_Table` | 桌台视图分组 | 🔥🔥 |
| `IX_OrderDetail_Combo` | 套餐子项展开 | 🔥 |
| `UX_OrderTableRel_Order_Table` | **卡片分组键**（业务唯一键） | 🔥🔥🔥 |
| `IX_OrderTableRel_Table` | 按桌查关联 | 🔥🔥 |
| `UX_StageLog_Detail_Stage` | 阶段时间线查询 | 🔥 |
| `IX_StageLog_Biz_Stage` / `IX_StageLog_Station` | 瓶颈分析报表 | 🔥 |

### 6.3 报表类（按营业日 — 这是 v6.65 补的 7 个）

| 索引 | 支撑的报表 |
|------|-----------|
| `IX_OrderDetail_Biz` | 任意按日筛选 |
| `IX_OrderDetail_Biz_Cancel` | 退菜明细表 |
| `IX_OrderDetail_Biz_Remind` | 催单明细表 |
| `IX_OrderDetail_Biz_Timeout` | 超时明细表 |
| `IX_OrderDetail_Biz_Void` | **报损明细表**（§2.17） |
| `IX_OrderDetail_Biz_Item` | 菜品排行 / 分品类榜 |
| `IX_OrderDetail_Biz_Waiter` | 服务员维度 |
| `IX_OrderDetail_CrossDay` | 跨日未完成清单 |
| `UX_DailyStoreStat_Date` | 日报（**直接查统计表，不扫明细**） |
| `UX_DailyDimStat` / `IX_DailyDimStat_Dim` | 维度统计 |

> **报表口径纪律**：日报**必须**读 `DailyStoreStat`，**禁止**从 `OrderDetail` 现算——这是 < 1s 的唯一前提。

### 6.4 日志与队列类

| 索引 | 支撑 |
|------|------|
| `IX_OperationLog_Biz` / `IX_OperationLog_Undo` | 【我的划单记录】抽屉（按营业日 + 可撤销） |
| `IX_OperationLog_Order` / `IX_OperationLog_Terminal` | 审计追溯 |
| `UX_OperationLog_ClientEventId` | 离线补发去重 |
| `UX_EventLog_EventId` | **入站幂等**（🔥🔥🔥） |
| `IX_EventLog_Type_Time` | 按类型排查 |
| `UX_Outbox_IdempotencyKey` | 回执幂等 |
| `IX_Outbox_Status` | 待发表扫描（🔥🔥） |
| `IX_Outbox_DeadLetter` | 死信告警 |
| `IX_PrintJob_Queue` | **打印队列拉取**（带 `Priority DESC` 排序，纯索引扫描） |
| `UX_PrintJob_Idempotency` / `IX_PrintJob_Printer` / `IX_PrintJob_Created` | 补打 / 按机查询 / 清理 |
| `IX_SoldOutLog_Item_Active` | **每个新单校验沽清**（🔥🔥🔥） |
| `IX_SoldOutLog_Status_End` | 定时恢复扫描 |
| `IX_CallLog_Cooldown` | **叫号冷却判定**（🔥🔥） |
| `UX_ArchiveVolume_Month` | 归档卷登记 |

---

## 7. 典型查询模式与预期计划

| 场景 | 查询要点 | 预期计划 |
|------|----------|----------|
| 入站幂等 | `WHERE StoreId=? AND PosOrderNo=?` | 唯一索引 seek |
| 屏数据构建 | `WHERE WorkflowStage IN (...) AND CurrentStationId IN (...)` | `IX_OrderDetail_Station` seek + 小范围 |
| 划单更新 | `WHERE DetailId=? AND Version=?` | 主键 seek + 行锁 |
| 取待发表 | `WHERE Status='Pending' AND NextRetryAt<=?` | `IX_Outbox_Status` range seek |
| 拉打印队列 | `WHERE ExecutorTerminalId=? AND Status='Pending' ORDER BY Priority DESC, CreatedAt` | `IX_PrintJob_Queue` **无排序开销** |
| 退菜明细页 | `WHERE BusinessDate BETWEEN ? AND ? AND CancelAt IS NOT NULL` + 分页 | `IX_OrderDetail_Biz_Cancel` seek |
| 日报 | `WHERE StoreId=? AND StatDate=?` | 唯一索引 seek（**单行**） |
| 叫号冷却 | `WHERE StoreId=? AND TableId=? AND CreatedAt>=?` | `IX_CallLog_Cooldown` range seek |
| 沽清校验 | `WHERE StoreId=? AND DishItemId=? AND Status='Active'` | `IX_SoldOutLog_Item_Active` seek |

**反例（必须避免）**

| 反例 | 问题 |
|------|------|
| `LIKE '%关键词%'` 于大表 | 全表扫；搜索限定在明细 90 天内且加 `BusinessDate` 前缀 |
| `ORDER BY` 无索引列 | 排序临时表；分页必须按索引序 |
| `IN (1000 个 Guid)` | 执行计划退化；改临时表 / 表值参数 |
| 用 `IsCancel` 代替 `CancelledQty` 判部分退 | 语义错 + 索引不匹配 |

### 7.1 分页策略：OFFSET 深翻页会变慢，用 keyset

`OFFSET n ROWS FETCH NEXT m ROWS ONLY`（EF Core 的 `Skip(n).Take(m)`）在 **n 很大时必然慢**——数据库要**扫过前 n 行然后全部丢弃**。`ROW_NUMBER()` 写法同理。

| 页码 | `OFFSET` 代价 |
|------|---------------|
| 第 1~5 页 | 无感 |
| 第 50 页 | 明显（扫 ~1000 行） |
| 第 500 页 | 很慢（扫 ~10000 行） |

**三种分页的适用场景**

| 方式 | 写法 | 适用 |
|------|------|------|
| **OFFSET/FETCH** | `ORDER BY x OFFSET n ROWS FETCH NEXT m ROWS ONLY` | **管理端有页码的列表**（用户会跳页，页码通常在前几页） |
| **keyset（游标）** | `WHERE Id > @lastId ORDER BY Id FETCH NEXT m ROWS ONLY` | **无限滚动 / 导出 / 逐批处理**（只能"下一页"，不能跳页，但**恒定快**） |
| **TOP N** | `ORDER BY x OFFSET 0 ROWS FETCH NEXT N ROWS ONLY` 或 `TOP N` | 只取前 N 条 |

**KDS 的取舍**

| 场景 | 用哪种 | 理由 |
|------|--------|------|
| 【我的划单记录】 | **OFFSET**（当天最多几百条，深度浅） | 用户要跳页 |
| 五类明细报表 | **OFFSET**（有页码）+ **导出走 keyset 流式** | 导出是逐批全量，不分页 |
| Outbox / 打印任务列表 | **OFFSET**（页数少） | — |
| 归档 MOVE 分批 | **keyset**（按 `DetailId` 游标） | 逐批处理，不能跳页，必须恒定快 |
| 数据清理分批 | **keyset** | 同上 |

**分页的三条硬规则**

| # | 规则 |
|:-:|------|
| 1 | 分页 `ORDER BY` **必须是索引的一部分**，否则每页都排序 |
| 2 | `ORDER BY` **必须唯一且稳定**（加 `Id` 兜底），否则翻页会出现重复/漏行 |
| 3 | 批量任务（归档/清理）**禁止用 OFFSET**，一律 keyset 游标 |

> **SQL Server 2008 备注**：该版本无 `OFFSET/FETCH`，需改 `ROW_NUMBER() BETWEEN`，性能更差。本项目底线为 2012（详见 [07 号文件 §8.3](KDS-07-数据库与数据字典.md)）。

---

## 8. 并发与锁

| 机制 | 实现 |
|------|------|
| **明细级乐观锁** | `OrderDetail.Version`，`WHERE Version=@v` 判断 `affected==0` |
| **SQLite 写串行** | 进程内 `SemaphoreSlim(1)` + 单一写连接 |
| **SQL Server 行锁** | 默认 `READ COMMITTED`（建议开 RCSI）；需要读-改-写时 `WITH (UPDLOCK)` |
| **跨屏重复划** | 广播模式下靠"实时移除 + 乐观锁"，冲突返回 `VERSION_CONFLICT`（§10.6） |
| **冲突率监控** | 记录 `ConcurrencyException` 次数 / 划单总数；> 5% 说明屏间同步延迟过大 |

---

## 9. 监控指标

| 指标 | 采集 | 告警阈值 |
|------|------|----------|
| 划单响应 P95 | 应用埋点 | > 100ms |
| 推送延迟 | 变更时间 → 屏确认 | > 500ms |
| DB 大小 | 文件大小 | > `DbSizeWarnMb`（默认 2GB） |
| WAL 大小 | `-wal` 文件 | > 200MB（说明 checkpoint 失效） |
| SQLITE_BUSY 次数 | 异常计数 | > 10 次/小时 |
| 慢查询（> 200ms） | `SlowQueryInterceptor` | 每日 > 20 条 |
| 乐观锁冲突率 | 异常 / 总数 | > 5% |
| Outbox 积压 | 最老 Pending 滞留时长 | > 60s |
| 归档是否成功 | `ArchiveVolume.Status` | 出现 `Corrupted` |

---

## 10. 性能验收（可执行）

| 验收项 | 方法 | 通过标准 |
|--------|------|----------|
| 划单响应 | 200 次并发划单压测 | **P95 < 100ms** |
| 推送到达 | 20 屏模拟订阅 | < 500ms |
| 三视图切换 | 300 条明细 | **< 200ms**（纯本地） |
| 全量重同步 | 300 条 | < 2s |
| 日报查询 | 连续 365 天数据 | < 1s |
| 明细报表单页 | 90 天数据 | < 500ms |
| 索引命中 | `EXPLAIN QUERY PLAN` / 执行计划 | 报表查询无 `SCAN TABLE` |
| SQLite 写并发 | 10 线程并发划单 | 无 `SQLITE_BUSY` 抛出（全部由串行化吸收） |
| 归档不阻塞 | 归档 MOVE 期间持续划单 | 划单 P95 不劣化 2 倍以上 |
| 内存层生效 | 压测期统计 DB 查询次数 | 推送路径 **0 次**查询 |

---

## 11. 常见性能陷阱速查

| 现象 | 根因 | 修正 |
|------|------|------|
| 午市高峰越来越慢 | 推送路径在查库 | 改内存投影 |
| 每 5 分钟卡顿一下 | WAL checkpoint 阻塞 | 改 `TRUNCATE` 模式 + 空闲时段 |
| 数据库文件暴涨 | 归档未运行 / WAL 未回收 | 检查归档任务与 `wal_checkpoint` |
| 报表越查越慢 | 从 `OrderDetail` 现算 | 改读 `DailyStoreStat` |
| 划单偶发失败 | 乐观锁冲突 | 正常现象，前端提示"已被他人处理"并刷新；冲突率高则查屏同步 |
| 打印队列延迟 | 队列索引缺 `Priority DESC` | 已修（`IX_PrintJob_Queue`） |
| 跨时区排序错乱 | `DateTimeOffset` 在 SQLite 存 TEXT，字符串序 ≠ 时间序 | **入库前统一换算门店时区、offset 固定**（§8.6.3 坑 3） |
| 改一个列类型卡了 10 分钟 | SQLite 重建表 | V1 尽量不改列类型；大表变更走维护窗口 |
