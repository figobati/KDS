# 第九部分：连锁总部汇总（V1 保留能力）

## 14. 总部汇总

- 门店 Master 每 **5 分钟**批量上报**终态订单**到总部（HTTPS 或 MQTT），总部 SQL Server upsert；
- 上报走 `OutboxMessage`（`TargetKind = Hq`），失败指数退避重试；
- **门店断网不影响业务**，恢复后**自动补传**；
- 幂等键：`StoreId + PosOrderNo + DetailId`，总部 upsert 去重；
- 上报内容：订单头 + 明细终态 + 各阶段耗时（`StageElapsedSeconds`）+ 退菜 / 赠菜标记；
- 上报接口与 Outbox 能力必须实现（否则后续补数据无源）；跨店报表界面不在本版。

### 14.1 上云策略与"上传成功才允许清本地"

> **边界先划清**：**KDS 不做云端报表**。云端报表是总部 / SaaS 平台的职责，KDS 的职责是**把结构化数据可靠地交出去、并能证明"交到了"**。门店屏上不出现任何云端报表入口。

#### 14.1.1 传什么（分三档，按需开启）

| 档位 | 内容 | 体积（单店/日） | 推荐 | 云端能做什么 |
|------|------|-----------------|:----:|--------------|
| **① 聚合指标** | `DailyStoreStat` + `DailyDimStat`（§9.22/§9.23） | **几十行，< 10 KB** | **默认开启** | 跨店趋势、排行、时长/超时对比、档口横评 |
| ② 订单明细 | `OrderHeader` + `OrderDetail` 终态 | ~1,500 行，1~3 MB | 可选 | 下钻到单、菜品级分析、异常订单回溯 |
| ③ 归档卷文件 | 按月归档库（压缩） | 20~50 MB/月 | 可选 | 完整历史留档（云端冷备） |

> **为什么默认只传聚合**：① 明细上云涉及菜品成本、客户信息，很多连锁不愿全量外流；② 聚合数据已能支撑 90% 的运营报表；③ 断网时积累 1 个月的明细（~50 MB）补传会拖垮门店上行带宽，而聚合数据积压一个月也只有 300 KB。
> **明细上云 = 可选项**，门店/总部按合规要求勾选。

#### 14.1.2 上报调度与校验

| 项 | 规则 |
|----|------|
| 聚合上报 | 每日 **03:30**（T+1 聚合完成后）立即上报前一日 L3 数据，落 `OutboxMessage(TargetKind = Hq)` |
| 明细上报 | 每小时增量（终端态订单），或按日期区间批量（历史补传） |
| 归档卷上传 | 每月归档完成后上传压缩卷，**断点续传** |
| **成功判定** | 云端返回 `AcceptedAt` + `RecordCount` + `Checksum`；KDS **必须校验行数与该批一致**才标记成功——**"发出去了"≠"云端收到了"** |
| 回执落库 | `OrderHeader.HqUploadedAt`（明细）、`DailyStoreStat.HqUploadedAt` / `DailyDimStat.HqUploadedAt`（聚合）、`ArchiveVolume.HqUploadedAt`（卷） |
| 失败处理 | 走 Outbox 指数退避（§9.14.1），`DeadLetter` 需人工处置 |

#### 14.1.3 本地保留策略：三档可选（默认最安全）

```diff
- 旧设计：上传成功 → 本地满 30 天 → 物理删除
+ 新设计：主库 → 移动（MOVE）到本地历史库（永久）→ 云端另存一份（可选）
         数据在门店始终有一份完整副本，"删除"降级为可选项
```

| 模式（`LocalHistoryMode`） | 主库（90 天外） | 本地历史库 | 适用 |
|---|---|---|---|
| **`MoveToArchive`（默认）** | **移动到按月历史库**（不删） | **永久保留**，ATTACH 可查 | 绝大多数门店：查得到、主库又瘦 |
| `MoveAndDeleteAfterUpload` | 移动到历史库 → 上传成功后**再保留 30 天** → 删除历史库中的该月卷 | 到期删除 | 磁盘紧张、且已确认云端有备份 |
| `DeleteAfterUpload` | 上传成功后本地仅保留 **30 天**（明细+订单头） | 不建历史库 | 极简部署 / 云优先门店 |

> **默认 `MoveToArchive` 的理由**：门店最怕"数据没了"。本地历史库让"查三个月前的单"依然成立，且主库体积不涨（§13.6.6：主库稳定 200~400 MB，历史卷按月 ~30 MB）。**上传成功只影响"要不要删历史卷"，不影响"能不能查"。**

#### 14.1.4 清理前置条件（升级版）

```
主库明细移入历史库前，必须依次校验：
1. 该批次【归档卷写入成功且校验通过】（§13.6.4，同事务 MOVE，不是 COPY+DELETE）
2. T+1 聚合已完成，对应日期 DailyStat 存在（§13.6.3）
3. 最近一次数据库备份在 24 小时内成功
4. 若开启上云且模式含 Delete：该批次【云端已回执 AcceptedAt 且行数校验通过】

→ 1~3 任一不满足：跳过本轮 + 告警（绝不删）
→ 第 4 条不满足且为 Delete 模式：降级为 MoveToArchive（不动历史卷），并告警
```

> **第 4 条是"降级而非跳过"**：云端没确认就删本地历史卷，等于把唯一副本交给一个没回执的请求——这是数据安全事故。**宁可多占磁盘，不可丢数据。**

#### 14.1.5 归档卷登记表（`ArchiveVolume`）

管理端要能"看到有哪些历史卷、在哪、传没传、能不能查"：

| 字段 | 说明 |
|------|------|
| `VolumeMonth` | 归属月份（`2026-10`）——**按 `BusinessDate` 的月份归属**（§2.13.5），不是 `CompletedAt` 自然月 |
| `BusinessDateFrom` / `BusinessDateTo` | 卷内覆盖的营业日区间（便于校验"营业日是否连续、有无缺口"） |
| `FileName` / `FilePath` | 卷文件名与路径 |
| `Engine` | `Sqlite`（卷为 `.db` 文件）/ `SqlServer`（卷为 `KdsArchive_2026_10` 库） |
| `RowCount` / `SizeBytes` | 行数 / 字节数（用于校验） |
| `Checksum` | 内容校验和 |
| `Status` | `Writing` / `Sealed`（封卷）/ `Uploaded` / `Corrupted` / `Deleted` |
| `LastMovedBusinessDate` | **迁移水位**（断点续跑依据） |
| `HqUploadedAt` / `HqRecordCount` | 云端回执时间与行数 |
| `DeletedAt` | 若被主动删除（仅 Delete 模式） |

> **封卷（`Sealed`）后卷不可写**：允许后续月份继续写入同一卷会导致"一个月数据分散在两个文件"，查询逻辑会复杂到没人维护。月末封卷 + 新卷，规则简单稳定。
> **`BusinessDateFrom/To` 的价值**：营业日连续性是"数据完整"的最强证据。若发现 10 月卷只有 1~30 号、缺 31 号（而 31 号营业日存在且闭店），说明迁移漏批——这一项能直接查出"少了一天"。

#### 14.1.6 查询路由（用户无感）

**两条查询通道（这是"归档后还能不能方便查"的答案）**

| 查询类型 | 走哪 | 速度 | 说明 |
|----------|------|:----:|------|
| **聚合 / 趋势类**（某月单量、平均时长、档口排行、超时率） | **主库 L3 统计表**（`DailyStoreStat` / `DailyDimStat`，**永久保留**） | **毫秒级** | 无论查多久以前，**都不碰归档卷**——因为统计表永远在主库 |
| **单据级 / 逐单核对**（某个单号、某天的订单清单、某桌消费） | 主库（90 天内）→ **归档卷**（更早） | 主库快；卷内走索引，单月查询通常 < 100ms | 需要 ATTACH 归档卷 |
| 跨很长时间的明细导出（如导出 1 年明细给财务） | 逐卷遍历 + 流式导出 | 慢，但可接受 | 后台任务 + 进度提示，不阻塞前台 |

```diff
按日期区间查：
  ├─ 全部落在主库保留期（90 天）内        → 只查主库
  ├─ 完全在更早                            → 按 ArchiveVolume 定位月份卷 → ATTACH 只读 → 查卷
  ├─ 跨主库与归档（如 80 天前 ~ 100 天前）  → 主库段 + 卷段 分别查 → 合并排序返回
  └─ 跨多个月（> 3 卷）                     → 逐卷顺序查询并流式合并，或提示缩小范围
```

| 规则 | 说明 |
|------|------|
| ATTACH 上限 | **同时最多挂 3 个归档卷**（SQLite `ATTACH` 默认上限 10，留余量给主库与临时库）；超过则逐卷分批查询后合并 |
| 索引必命中 | 卷内查询必须带 `CompletedAt` 区间或 `PosOrderNo`，**禁止全卷扫描**（卷内无索引的 `like` 查询直接拒绝并提示） |
| 结果分页 | 卷内查询同样分页（默认 50 条/页），避免一次拉出几万行 |
| 卷缺失 | 该月卷已删除（`DeleteAfterUpload` 模式）→ 返回明确提示"该日期本地已归档至云端"，并给出云端跳转/查询指引 |
| 卷损坏 | `ArchiveVolume.Status = Corrupted` → 提示可用云端副本或备份恢复，**不要静默返回空结果**（空结果会被误读成"没有这单"） |

> **对用户是透明的**：管理端"历史查询"只需要一个日期区间，系统自动决定查哪个库；不要求操作人员知道"哪个月在哪"。
> **关键取舍**：**统计不依赖归档卷**。所以即使某个月卷被删除，`DailyStoreStat` 里的数字依然完整——这是把"运营数据"与"单据数据"分开保留的最大价值。

### 14.2 上报接口契约（KDS → 云端，**可配置**）

> **设计原则五条**：① **异步不阻塞**（上报失败绝不影响划单）；② **幂等可重放**（网络抖动 / 重复批次不产生脏数据）；③ **可验证**（行数 + 校验和，不信 HTTP 200）；④ **可断点**（大文件分片续传）；⑤ **全量可配**（端点、档位、批量、超时、压缩、开关都可配，关掉即为纯本地部署）。

#### 14.2.1 通道与认证

| 项 | 规则 |
|----|------|
| 协议 | **HTTPS（必须 TLS）**；可选 MQTT（与 POS 通道一致，V1 优先 HTTPS） |
| 方法 | `POST`（JSON，`application/json; charset=utf-8`） |
| 认证 | `Authorization: Bearer {StoreToken}` + `X-Store-Id: {StoreId}` |
| `StoreToken` | 门店级密钥，**加密存储**（DPAPI / AES），**不入配置快照导出**（§11.7.6） |
| 版本头 | `X-Api-Version: 1`（主版本变更才不兼容，同 §9.0 契约纪律） |
| 幂等头 | `X-Batch-Id: {BatchId}`（GUID，由 KDS 生成，全局唯一） |
| 压缩 | `Content-Encoding: gzip`（`HqCompress = 1` 时，> 32 KB 强制压缩） |
| 超时 | 默认 **30 秒**（`HqTimeoutSeconds`），超时按失败处理 |

> **为什么必须 TLS**：上报内容含门店营业数据，明文 HTTP 在公网传输不可接受；若部署在 VPN/专线内可降级，但需显式配置并在健康检查里标 `INSECURE_TRANSPORT` 警告。

#### 14.2.2 能力协商（KDS 启动时 + 每日一次）

```
GET /api/v1/ingest/capabilities
Authorization: Bearer {StoreToken}
```

```json
{
  "ServerVersion": "1.4.2",
  "ApiVersions": ["1"],
  "SupportedDataTypes": ["DailyStat", "Order", "ArchiveVolume"],
  "MaxBatchRecords": 1000,
  "MaxRequestBytes": 8388608,
  "SupportsGzip": true,
  "SupportsChunkedUpload": true,
  "ChunkSizeBytes": 4194304,
  "ServerTime": "2026-10-21T03:31:00+08:00"
}
```

**KDS 必须据此调整**：

| 协商项 | KDS 行为 |
|--------|----------|
| `MaxBatchRecords` | 本地 `HqBatchSize` 取 `min(本地配置, 服务端上限)` |
| `SupportedDataTypes` 缺 `Order` | 即使本地开了 `StatAndDetail`，**自动降级为 `StatOnly`** 并告警（不静默丢数据） |
| 无 `ArchiveVolume` 或 `SupportsChunkedUpload = false` | 跳过卷上传，本地历史卷保留（降级为 `MoveToArchive`） |
| `ApiVersions` 不含 `1` | **停止上报 + 告警**（`HQ_API_VERSION_UNSUPPORTED`），不尝试旧接口 |

#### 14.2.3 通用批量上报（JSON）

```
POST /api/v1/ingest/batch
X-Batch-Id: 8f3c…-guid
X-Api-Version: 1
Content-Encoding: gzip
```

**请求体**

```json
{
  "DataType": "DailyStat",          // DailyStat | Order
  "StoreId": "guid",
  "BatchId": "8f3c…",
  "RecordCount": 2,
  "Checksum": "sha256-hex",         // 对 Records 规范化 JSON 序列化后取 SHA256
  "GeneratedAt": "2026-10-21T03:30:12+08:00",
  "Records": [ /* 见下方字段表 */ ]
}
```

**`DataType = DailyStat`（聚合指标，默认档位）**

| 字段 | 类型 | 说明 |
|------|------|------|
| `StatDate` | date | 统计日期 |
| `StoreStat` | object | 对应 `DailyStoreStat` 全字段（§9.22），**不含 `Uid`/`StoreId`** |
| `Dims` | array | 对应 `DailyDimStat`（§9.23）：`Dimension` / `DimKey` / `DimNameSnapshot` / 指标字段 |
| `CalcVersion` | int | 聚合算法版本（云端据此识别口径） |

**`DataType = Order`（订单明细，可选档位）**

| 字段 | 类型 | 说明 |
|------|------|------|
| `PosOrderNo` | string | 订单号（幂等键之一） |
| `OrderType` / `TableCodes` / `GuestCount` / `OrderCreateTime` / `CompletedAt` | — | 订单头 |
| `TotalElapsedSeconds` | int | 整单耗时 |
| `Details` | array | 明细数组，每项含 `LineNo` / `DishName`（**`MergeBaseName` 主名**）/ `Qty` / `Unit` / `CompletedQty` / `CancelledQty` / `IsComboItem` / `ComboNo` / `CurrentStationId` / `StageElapsedSeconds`（各阶段）/ `IsGift` / `IsCancel` |

> **明细上报只传 `MergeBaseName` 而不传多语言对象**：云端报表统计只需一个稳定名称，传 `LocalizedText` 会成倍放大体积（§11.4 语言无关原则）。

**响应体（云端 → KDS）**

```json
{
  "BatchId": "8f3c…",
  "Accepted": 2,
  "Rejected": 0,
  "AcceptedAt": "2026-10-21T03:30:14+08:00",
  "ChecksumVerified": true,
  "ServerRecordCount": 2
}
```

**部分成功（必须支持，不许整批退回）**

```json
{
  "BatchId": "8f3c…",
  "Accepted": 1,
  "Rejected": 1,
  "AcceptedAt": "…",
  "ChecksumVerified": true,
  "RejectedRecords": [
    { "Index": 1, "Key": "20261021-2", "ErrorCode": "ORDER_EXISTS_CONFLICT", "Message": "同单号但金额不一致" }
  ]
}
```

| KDS 处理 | 规则 |
|----------|------|
| `Accepted` 部分 | 只把这些记录标记 `HqUploadedAt`，**不重传** |
| `Rejected` 部分 | 进 `DeadLetter` 并告警（业务冲突需人工判断，**不自动重试**，否则死循环） |
| `ChecksumVerified = false` 或 `ServerRecordCount ≠ RecordCount` | **整批视为失败**，重算校验和重传（最多 3 次，仍失败转死信） |
| 幂等重放 | 同 `BatchId` 重复提交，云端返回**首次相同结果**（`Accepted/Rejected` 一致），不重复入库 |

#### 14.2.4 归档卷分片上传（二进制，可选档位）

三步协议，支持断点续传（月度卷 20~50 MB，门店上行慢时必需）：

```
① POST /api/v1/ingest/volume/init
   { "VolumeMonth":"2026-10", "FileName":"orders-2026-10.db.gz",
     "SizeBytes":31457280, "Checksum":"sha256", "ChunkSizeBytes":4194304 }
   → { "UploadId":"guid", "ReceivedChunks":[], "ChunkSizeBytes":4194304 }

② PUT /api/v1/ingest/volume/chunk?uploadId=…&index=3
   Content-Type: application/octet-stream
   → { "Received": true, "ReceivedChunks":[0,1,2,3] }
   // index 越界 / 重复 → 幂等返回已收列表，不报错

③ POST /api/v1/ingest/volume/complete
   { "UploadId":"guid", "Checksum":"sha256" }
   → { "VolumeMonth":"2026-10", "AcceptedAt":"…", "ServerRecordCount":152340 }
```

| 规则 | 说明 |
|------|------|
| 断点续传 | KDS 启动或重连后调 `init`（同 `VolumeMonth` + 同 `Checksum` 返回**同一 `UploadId` 与已收分片**），从缺失分片继续 |
| 分片校验 | 每片独立强校验失败只重传该片；`complete` 时云端校验整卷 `Checksum` |
| 失败降级 | 连续失败 3 次 → 停止上传、保持本地卷（`MoveToArchive`），告警 `HQ_VOLUME_UPLOAD_FAILED` |
| 上传后 | `ArchiveVolume.Status = Uploaded` + `HqUploadedAt` + `HqRecordCount`（§14.1.5） |

#### 14.2.5 错误码（云端返回，KDS 依此决策）

| HTTP | ErrorCode | KDS 行为 |
|------|-----------|----------|
| 200 | — | 按 `Accepted` / `Rejected` 分别处理 |
| 400 | `VALIDATION_FAILED` | **重试无意义**，转死信 + 告警 |
| 401 | `UNAUTHORIZED` | 停止上报 + 告警（`StoreToken` 失效/轮换） |
| 403 | `STORE_DISABLED` | 停止上报 + 告警（门店在云端被停用） |
| 409 | `BATCH_CONFLICT` | 幂等命中但内容不同 → 转死信（数据被篡改或本地重算不一致） |
| 413 | `PAYLOAD_TOO_LARGE` | **自动减半批量**重试（最小 50 条），成功后将 `HqBatchSize` 下调并记录 |
| 422 | `CHECKSUM_MISMATCH` | 重算校验和重试（最多 3 次） |
| 429 | `RATE_LIMITED` | 读 `Retry-After`，遵守后重试 |
| 500 / 503 | `SERVER_ERROR` | 指数退避重试（走 Outbox，最多 10 次转死信） |
| 网络超时 | — | 同 5xx |

#### 14.2.6 调度、批量与优先级

| 项 | 规则 |
|----|------|
| `DailyStat` 上报 | 每日 **03:30** 聚合完成后立即；积压也仅几十行 |
| `Order` 上报 | **滚动增量**：每 5 分钟一批（取 `HqUploadedAt IS NULL` 的终态订单） |
| 归档卷上传 | 每月封卷后，**非营业时段**（04:30）执行 |
| 批量大小 | 默认 **500 条/批**（`HqBatchSize`），受 `MaxBatchRecords` 约束 |
| 并发 | **单线程串行**（不并发多批），避免门店上行被占满、也简化顺序与幂等 |
| 优先级 | `DailyStat` > `Order` > `ArchiveVolume`（聚合最关键且最轻） |
| 与业务隔离 | 上报在**独立后台队列**，与划单事务无耦合；上报慢不影响出餐 |
| 载荷落库 | 上报任务落 `OutboxMessage(TargetKind = Hq)`，复用 §9.14.1 的重试/死信/监控 |

#### 14.2.7 配置项（`StoreConfig`，全部可改，改后不重启生效）

> ⚠️ **本节只列"上云"相关的字段**；`StoreConfig` 的**唯一权威定义在 §9.1**（含全部字段、类型、默认值）。本节不复述无关字段，避免三处各列一份子集导致口径漂移。

| 字段 | 默认 | 说明 |
|------|------|------|
| `HqUploadEnabled` | **0** | 总开关；0 = 纯本地部署，不上报任何数据 |
| `HqUploadScope` | `StatOnly` | `StatOnly` / `StatAndDetail` / `StatAndArchiveFile` |
| `HqEndpoint` | — | 云端基址（`https://hq.example.com/kds`） |
| `HqStoreToken` | — | 门店密钥（**加密存储**，快照导出时剔除） |
| `HqApiVersion` | `1` | 契约版本 |
| `HqBatchSize` | 500 | 每批记录数（受云端 `MaxBatchRecords` 钳制） |
| `HqTimeoutSeconds` | 30 | 单请求超时 |
| `HqCompress` | 1 | 是否 gzip |
| `HqRetryMaxCount` | 10 | 与 Outbox 一致 |
| `HqUploadIntervalMinutes` | 5 | 订单增量上报间隔 |
| `HqInsecureTransportAllowed` | 0 | 允许 http（仅内网/VPN，开启则健康检查告警） |

**管理端配置页要求**：填完可点**【测试连通性】**（调 `capabilities` 并展示协商结果 + 是否降级），保存后立即生效，无需重启。

#### 14.2.8 运维与可观测

| 能力 | 说明 |
|------|------|
| `GET /api/Admin/Hq/Stats` | 待传 / 成功 / 失败 / 死信条数、**最老待传滞留时长**、最近一次成功时间、协商到的能力 |
| `POST /api/Admin/Hq/Test` | 测试连通性 + 能力协商 |
| `POST /api/Admin/Hq/Resend` | **手动补传**（按日期区间 / 数据类型，上限 1,000 条/次） |
| 健康检查项 | `HQ_UPLOAD_DISABLED_BY_CONFIG`（Info）/ `HQ_UPLOAD_BACKLOG`（Warn，>1,000 条或最滞 >1 小时）/ `HQ_DEADLETTER`（Error，>0）/ `HQ_API_VERSION_UNSUPPORTED`（Error）/ `INSECURE_TRANSPORT`（Warn）/ `HQ_CAPABILITY_DOWNGRADED`（Warn，云端不支持明细导致降级） |
| 日志 | 每次上报记 `BatchId` / 记录数 / 耗时 / 结果；日志保留 30 天 |
| 不静默降级 | 能力协商导致的降级（明细→仅聚合、卷上传跳过）**必须告警并落 `OperationLog`**，不允许悄悄降功能 |

> **"不静默降级"是这一节的底线**：门店配了 `StatAndDetail`，云端却不支持明细，若只在日志里写一行，门店会以为明细一直在传。这类问题只能靠显式告警暴露。


---

