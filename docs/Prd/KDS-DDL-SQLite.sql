-- ============================================================================
-- KDS 厨房显示系统 — 门店运行库 DDL（SQLite）
-- 版本：v6.64　生成依据：KDS-07-数据库与数据字典.md（§8–§9）
-- 适用：门店本地库（Master 运行库）。SQL Server 版见 KDS-DDL-SqlServer.sql
-- 约定：见 §8（主键/审计/并发/类型映射）；两处主键命名例外：OrderHeader.OrderId、OrderDetail.DetailId
-- ============================================================================

PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;          -- 读写不互斥（§13.6）
PRAGMA synchronous = NORMAL;
PRAGMA busy_timeout = 5000;

-- ============================================================================
-- 一、配置类
-- ============================================================================

-- §9.1 门店配置（单行表）
CREATE TABLE StoreConfig (
    Uid                             TEXT    NOT NULL PRIMARY KEY,
    StoreId                         TEXT    NOT NULL,           -- 门店业务 UID（业务唯一键，非主键）
    StoreCode                       TEXT    NOT NULL,           -- 门店编码（业务唯一）
    StoreName                       TEXT    NOT NULL,           -- 门店名称
    -- 流转（§4.1 / §4.2 / §2.7）
    EnableWorkflowState             INTEGER NOT NULL DEFAULT 1,
    FlowMode                        TEXT    NOT NULL DEFAULT 'Auto', -- Auto（V1 实现）/ Manual（设计保留，V2 实现）
    -- 超时（§4.4.1 / §4.4.2）
    DefaultTotalTimeoutSeconds      INTEGER NOT NULL DEFAULT 1200,
    WarnRatio                       REAL    NOT NULL DEFAULT 0.8,
    TreatPlacedAsFired              INTEGER NOT NULL DEFAULT 1,
    HoldPauseCounting               INTEGER NOT NULL DEFAULT 1,   -- 已废弃，保留兼容
    -- 退菜 / 沽清 / 撤销（§4.7.2 / §2.18 / §2.19）
    AllowKitchenCancel              INTEGER NOT NULL DEFAULT 0,
    SoldOutMode                     TEXT    NOT NULL DEFAULT 'PosConfirm', -- PosConfirm / KdsDirect / PosOnly
    EnableUndo                      INTEGER NOT NULL DEFAULT 1,
    UndoWindowSeconds               INTEGER NOT NULL DEFAULT 120,
    UndoScope                       TEXT    NOT NULL DEFAULT 'PerDetail',  -- PerDetail / LastActionOnly
    UndoRequireSameOperator         INTEGER NOT NULL DEFAULT 1,
    UndoPrintVoidSlip               INTEGER NOT NULL DEFAULT 0,
    EnableManageUndo                INTEGER NOT NULL DEFAULT 0,
    -- 多语言（§11）
    DefaultLang                     TEXT    NOT NULL DEFAULT 'zh-CN',
    MainLang                        TEXT    NOT NULL DEFAULT 'zh-CN',
    -- 营业日 / 维护窗口（§2.13）
    BusinessDayStartHour            INTEGER NOT NULL DEFAULT 6,
    MealPeriods                     TEXT,
    FirstBusinessDate               TEXT,
    MaintenanceWindowStartMinute    INTEGER NOT NULL DEFAULT 30,
    CrossDayHandleMode              TEXT    NOT NULL DEFAULT 'MarkOnly', -- MarkOnly / AutoClose / Prompt
    CrossDayAutoCloseDays           INTEGER NOT NULL DEFAULT 1,
    CrossDayPromptOnSwitch          INTEGER NOT NULL DEFAULT 1,
    -- 数据保留与清理（§13.6）
    OrderRetentionDays              INTEGER NOT NULL DEFAULT 90,
    OrderHeaderRetentionDays        INTEGER NOT NULL DEFAULT 365,
    AutoCleanupEnabled              INTEGER NOT NULL DEFAULT 1,
    ArchiveEnabled                  INTEGER NOT NULL DEFAULT 1,
    StatAggregateHour               INTEGER NOT NULL DEFAULT 3,
    -- 本地保留模式（§14.1.3）
    LocalHistoryMode                TEXT    NOT NULL DEFAULT 'MoveToArchive', -- MoveToArchive / MoveAndDeleteAfterUpload / DeleteAfterUpload
    LocalBufferDaysAfterUpload      INTEGER NOT NULL DEFAULT 30,
    CleanupHour                     INTEGER NOT NULL DEFAULT 4,
    DbSizeWarnMb                    INTEGER NOT NULL DEFAULT 2048,
    -- 日志管理（§13.9）
    LogRetentionDays                INTEGER NOT NULL DEFAULT 30,
    LogMaxTotalMb                   INTEGER NOT NULL DEFAULT 2048,
    LogCompressAfterDays            INTEGER NOT NULL DEFAULT 7,
    CrashLogRetentionDays           INTEGER NOT NULL DEFAULT 90,
    LogLevel                        TEXT    NOT NULL DEFAULT 'Information',
    SlowQueryThresholdMs            INTEGER NOT NULL DEFAULT 200,
    DbLogWarnMb                     INTEGER NOT NULL DEFAULT 2048,
    SqlServerRecoveryMode           TEXT    NOT NULL DEFAULT 'SIMPLE',
    -- 会话与口令（§13.11）
    ScreenSessionDays               INTEGER NOT NULL DEFAULT 30,
    ScreenTokenRotation             INTEGER NOT NULL DEFAULT 1,
    AdminSessionIdleMinutes         INTEGER NOT NULL DEFAULT 30,
    AdminSessionAbsoluteHours       INTEGER NOT NULL DEFAULT 12,
    AllowScreenPinLogin             INTEGER NOT NULL DEFAULT 1,
    LoginLockoutCount               INTEGER NOT NULL DEFAULT 5,
    LoginLockoutMinutes             INTEGER NOT NULL DEFAULT 15,
    PasswordMinLength               INTEGER NOT NULL DEFAULT 8,
    PasswordRequireComplex          INTEGER NOT NULL DEFAULT 1,
    -- 员工同步（§13.11.11）
    StaffSource                     TEXT    NOT NULL DEFAULT 'Local',   -- Local / Pos / PosWithLocalExtra
    PosRoleMapJson                  TEXT,
    PosStaffSyncIntervalMinutes     INTEGER NOT NULL DEFAULT 60,
    -- 上云（§14.2.7）
    HqUploadEnabled                 INTEGER NOT NULL DEFAULT 0,
    HqUploadScope                   TEXT    NOT NULL DEFAULT 'StatOnly',
    HqEndpoint                      TEXT,
    HqStoreToken                    TEXT,                          -- 加密存储
    HqApiVersion                    INTEGER NOT NULL DEFAULT 1,
    HqBatchSize                     INTEGER NOT NULL DEFAULT 500,
    HqTimeoutSeconds                INTEGER NOT NULL DEFAULT 30,
    HqCompress                      INTEGER NOT NULL DEFAULT 1,
    HqRetryMaxCount                 INTEGER NOT NULL DEFAULT 10,
    HqUploadIntervalMinutes         INTEGER NOT NULL DEFAULT 5,
    HqInsecureTransportAllowed      INTEGER NOT NULL DEFAULT 0,
    -- 同步（§2.10）
    PollingIntervalSeconds          INTEGER NOT NULL DEFAULT 15,
    PushSilenceSeconds              INTEGER NOT NULL DEFAULT 30,
    DataStaleSeconds                INTEGER NOT NULL DEFAULT 90,
    HeartbeatThresholdSeconds       INTEGER NOT NULL DEFAULT 60,  -- 终端在线判定阈值（秒）
    RevisionHistorySize             INTEGER NOT NULL DEFAULT 300,
    -- 报表（§13.6.8）
    CompareDivisorMode              TEXT    NOT NULL DEFAULT 'EffectiveDays',
    -- 叫号与 TTS（§3.5.3）
    TtsProvider                     TEXT    NOT NULL DEFAULT 'Console',
    CallCooldownSeconds             INTEGER NOT NULL DEFAULT 30,
    CallQuietHours                  TEXT,
    CallAutoOnAllExpo               INTEGER NOT NULL DEFAULT 0,
    TtsVolume                       INTEGER NOT NULL DEFAULT 100,
    TtsRate                         INTEGER NOT NULL DEFAULT 0,
    -- 审计
    CreatedAt                       TEXT    NOT NULL,
    CreatedBy                       TEXT,
    UpdatedAt                       TEXT    NOT NULL,
    UpdatedBy                       TEXT,
    IsDeleted                       INTEGER NOT NULL DEFAULT 0
);
CREATE UNIQUE INDEX UX_StoreConfig_Store ON StoreConfig (StoreId);

-- §9.2 终端屏幕配置
CREATE TABLE TerminalConfig (
    Uid                             TEXT    NOT NULL PRIMARY KEY,
    StoreId                         TEXT    NOT NULL,
    TerminalCode                    TEXT    NOT NULL,          -- 绑定用编码（换屏重绑凭此）
    TerminalName                    TEXT    NOT NULL,
    TerminalType                    TEXT    NOT NULL DEFAULT 'Station', -- Station / Composite
    Role                            TEXT,                       -- Prep / Cook / Expo（综合屏可空）
    StationIds                      TEXT,                       -- ,guid,guid,
    BaseGroupMode                   TEXT    NOT NULL DEFAULT 'TableMode',  -- TableMode / OrderMode(V2)
    DefaultView                     TEXT    NOT NULL DEFAULT 'BaseGroupView',
    LastActiveView                  TEXT,
    CurrentLang                     TEXT    NOT NULL DEFAULT 'zh-CN',
    PageSize                        INTEGER NOT NULL DEFAULT 20,
    -- 视图细节（§3.2 / §3.3）
    ItemView_DetailMode             TEXT    NOT NULL DEFAULT 'SinglePortion',
    ItemView_SortMode               TEXT    NOT NULL DEFAULT 'TableFirst',
    SingleView_SortMode             TEXT    NOT NULL DEFAULT 'WaitDuration',
    SingleView_HideCancelled        INTEGER NOT NULL DEFAULT 0,
    TableView_SortMode              TEXT    NOT NULL DEFAULT 'TableOrder',
    -- 显示与网格（§1.7 / §1.12 屏端设置页）
    DisplayStyle                    TEXT    NOT NULL DEFAULT 'DishSummary', -- DishSummary/SingleShow/SingleSplit/MergedKeepTaste
    DishColumns                     INTEGER NOT NULL DEFAULT 8,
    DishRows                        INTEGER NOT NULL DEFAULT 6,
    FixDishPosition                 INTEGER NOT NULL DEFAULT 0,
    FontScale                       TEXT    NOT NULL DEFAULT 'M',   -- S/M/L（L 上限：菜名32px/桌号40px）
    OrderColumns                    INTEGER NOT NULL DEFAULT 2,
    OrderRows                       INTEGER NOT NULL DEFAULT 2,
    CardSize                        TEXT    NOT NULL DEFAULT 'S',   -- S/M/L
    DishSortMode                    TEXT    NOT NULL DEFAULT 'OrderSeq', -- OrderSeq/ItemTypeSeq
    ShowCompleted                   INTEGER NOT NULL DEFAULT 1,
    ConfirmWholeTable               INTEGER NOT NULL DEFAULT 1,
    HoldFireCountdown               INTEGER NOT NULL DEFAULT 0,
    SearchBumpWholeTable            INTEGER NOT NULL DEFAULT 0,     -- 两步确认：回车仅定位选中
    CallRepeatCount                 INTEGER NOT NULL DEFAULT 1,
    SndNewOrder                     INTEGER NOT NULL DEFAULT 1,
    SndFire                         INTEGER NOT NULL DEFAULT 1,
    SndRemind                       INTEGER NOT NULL DEFAULT 1,
    SndBumpSuccess                  INTEGER NOT NULL DEFAULT 1,
    SndCall                         INTEGER NOT NULL DEFAULT 1,
    PrintItemSlipOnBump             INTEGER NOT NULL DEFAULT 0,
    -- 合并条件①–⑦（§2.3.2，默认全开）
    Merge_DiffOrder                 INTEGER NOT NULL DEFAULT 1,
    Merge_DiffFlavor                INTEGER NOT NULL DEFAULT 1,
    Merge_DineInTakeaway            INTEGER NOT NULL DEFAULT 1,
    Merge_ComboAndNormal            INTEGER NOT NULL DEFAULT 1,
    Merge_Timeout                   INTEGER NOT NULL DEFAULT 1,
    Merge_Rush                      INTEGER NOT NULL DEFAULT 1,
    Merge_Hold                      INTEGER NOT NULL DEFAULT 1,
    -- 联台组卡（§3.1.4 / D11）
    Merge_LinkedTable               INTEGER NOT NULL DEFAULT 0,
    Merge_LinkedTable_CrossArea     INTEGER NOT NULL DEFAULT 0,
    -- 操作与权限
    EnableOperate                   INTEGER NOT NULL DEFAULT 1,
    IsEnabled                       INTEGER NOT NULL DEFAULT 1,
    EnablePrint                     INTEGER NOT NULL DEFAULT 0,
    EnableReprint                   INTEGER NOT NULL DEFAULT 0,
    PrintPriority                   INTEGER NOT NULL DEFAULT 0,
    StaffName                       TEXT,
    PaneLayout                      TEXT    NOT NULL DEFAULT 'Single',  -- V1 恒 Single
    -- 语音与叫号
    EnableVoice                     INTEGER NOT NULL DEFAULT 1,
    EnableCall                      INTEGER NOT NULL DEFAULT 1,
    -- 身份与版本
    DeviceKey                       TEXT,
    AppliedConfigVersion            INTEGER NOT NULL DEFAULT 0,
    ConfigVersion                   INTEGER NOT NULL DEFAULT 1,
    -- 审计
    CreatedAt                       TEXT    NOT NULL,
    CreatedBy                       TEXT,
    UpdatedAt                       TEXT    NOT NULL,
    UpdatedBy                       TEXT,
    IsDeleted                       INTEGER NOT NULL DEFAULT 0
);
CREATE UNIQUE INDEX UX_TerminalConfig_Code ON TerminalConfig (StoreId, TerminalCode);

-- §9.5 品项基础资料
CREATE TABLE DishItem (
    Uid                             TEXT    NOT NULL PRIMARY KEY,
    StoreId                         TEXT    NOT NULL,
    ItemCode                        TEXT    NOT NULL,
    ItemName                        TEXT    NOT NULL,          -- LocalizedText JSON（§9.16）
    DishTypeId                      TEXT,
    -- 售卖模式（§4.5）
    SaleMode                        TEXT    NOT NULL DEFAULT 'ByPiece',  -- ByPiece / ByWeight
    QtyStep                         REAL    NOT NULL DEFAULT 1,
    Unit                            TEXT,
    -- 超时（§4.4.2）
    TotalTimeoutSeconds             INTEGER,
    -- 预留：阶段工时仅供瓶颈分析，不参与超时判定
    StageStandardSeconds            TEXT,
    IsEnabled                       INTEGER NOT NULL DEFAULT 1,
    SortOrder                       INTEGER NOT NULL DEFAULT 0,
    DefaultSpec                     TEXT,                       -- 默认规格
    Price                           REAL,                       -- 单价（仅展示，KDS 不做金额计算）
    IsSoldOut                       INTEGER NOT NULL DEFAULT 0, -- 沽清标记
    CreatedAt                       TEXT    NOT NULL,
    CreatedBy                       TEXT,
    UpdatedAt                       TEXT    NOT NULL,
    UpdatedBy                       TEXT,
    IsDeleted                       INTEGER NOT NULL DEFAULT 0
);
CREATE UNIQUE INDEX UX_DishItem_Code ON DishItem (StoreId, ItemCode);
CREATE INDEX IX_DishItem_Type ON DishItem (StoreId, DishTypeId);

-- §9.6 品项类型 / 品类
CREATE TABLE DishType (
    Uid                             TEXT    NOT NULL PRIMARY KEY,
    StoreId                         TEXT    NOT NULL,
    TypeCode                        TEXT    NOT NULL,
    TypeName                        TEXT    NOT NULL,          -- LocalizedText JSON
    ParentTypeId                    TEXT,
    SortOrder                       INTEGER NOT NULL DEFAULT 0,
    DefaultStagePath                TEXT,                       -- 品类默认 StagePath
    DefaultStageStandardSeconds     TEXT,                       -- 品类默认阶段标准工时 JSON
    CreatedAt                       TEXT    NOT NULL,
    CreatedBy                       TEXT,
    UpdatedAt                       TEXT    NOT NULL,
    UpdatedBy                       TEXT,
    IsDeleted                       INTEGER NOT NULL DEFAULT 0
);
CREATE UNIQUE INDEX UX_DishType_Code ON DishType (StoreId, TypeCode);

-- §9.7 桌台主数据
CREATE TABLE DiningTable (
    Uid                             TEXT    NOT NULL PRIMARY KEY,
    StoreId                         TEXT    NOT NULL,
    ExternalTableId                 TEXT,                       -- 外部 POS 桌台 ID
    TableCode                       TEXT    NOT NULL,
    TableName                       TEXT,                       -- LocalizedText JSON
    AreaName                        TEXT,
    SeatCount                       INTEGER,
    SortOrder                       INTEGER NOT NULL DEFAULT 0,
    IsEnabled                       INTEGER NOT NULL DEFAULT 1,
    IsAutoCreated                   INTEGER NOT NULL DEFAULT 0,
    CreatedAt                       TEXT    NOT NULL,
    CreatedBy                       TEXT,
    UpdatedAt                       TEXT    NOT NULL,
    UpdatedBy                       TEXT,
    IsDeleted                       INTEGER NOT NULL DEFAULT 0
);
CREATE UNIQUE INDEX UX_DiningTable_Code ON DiningTable (StoreId, TableCode);
CREATE UNIQUE INDEX UX_DiningTable_External ON DiningTable (StoreId, ExternalTableId) WHERE ExternalTableId IS NOT NULL;
CREATE INDEX IX_DiningTable_Sort ON DiningTable (StoreId, SortOrder);

-- §9.9 档口主配置
CREATE TABLE Station (
    Uid                             TEXT    NOT NULL PRIMARY KEY,
    StoreId                         TEXT    NOT NULL,
    StationCode                     TEXT    NOT NULL,
    Name                            TEXT    NOT NULL,          -- LocalizedText JSON
    Role                            TEXT    NOT NULL,          -- Prep / Cook / Expo
    SortOrder                       INTEGER NOT NULL DEFAULT 0,
    -- 反选三字段（§9.10；运行期走内存 HashSet，不走 SQL）
    IncludeTypeIds                  TEXT,
    ExcludeItemIds                  TEXT,
    IncludeItemIds                  TEXT,
    IsEnabled                       INTEGER NOT NULL DEFAULT 1,
    EnableVoice                     INTEGER NOT NULL DEFAULT 1,   -- 本档口是否启用语音
    CreatedAt                       TEXT    NOT NULL,
    CreatedBy                       TEXT,
    UpdatedAt                       TEXT    NOT NULL,
    UpdatedBy                       TEXT,
    IsDeleted                       INTEGER NOT NULL DEFAULT 0
);
CREATE UNIQUE INDEX UX_Station_Code ON Station (StoreId, StationCode);
CREATE INDEX IX_Station_Role ON Station (StoreId, Role, SortOrder);

-- §9.11 品项自定义工序流程
CREATE TABLE Workflow (
    Uid                             TEXT    NOT NULL PRIMARY KEY,
    StoreId                         TEXT    NOT NULL,
    Scope                           TEXT    NOT NULL DEFAULT 'Item',  -- Item / Type
    ScopeId                         TEXT    NOT NULL,
    StagePath                       TEXT    NOT NULL DEFAULT 'Prep,Cook,Expo',
    StageStandardSeconds            TEXT,
    IsEnabled                       INTEGER NOT NULL DEFAULT 1,
    CreatedAt                       TEXT    NOT NULL,
    CreatedBy                       TEXT,
    UpdatedAt                       TEXT    NOT NULL,
    UpdatedBy                       TEXT,
    IsDeleted                       INTEGER NOT NULL DEFAULT 0
);
CREATE UNIQUE INDEX UX_Workflow_Scope ON Workflow (StoreId, Scope, ScopeId);

-- §9.15 终端语言包覆盖（可选）
CREATE TABLE ScreenLangPack (
    Uid                             TEXT    NOT NULL PRIMARY KEY,
    StoreId                         TEXT    NOT NULL,
    TerminalId                      TEXT,
    Lang                            TEXT    NOT NULL,
    PackJson                        TEXT    NOT NULL,
    Version                         INTEGER NOT NULL DEFAULT 1,
    UpdatedAt                       TEXT    NOT NULL
);
CREATE UNIQUE INDEX UX_ScreenLangPack ON ScreenLangPack (StoreId, TerminalId, Lang);

-- §9.15a 语音播报模板（可编辑，场景 × 语言）
CREATE TABLE VoiceTemplate (
    Uid                             TEXT    NOT NULL PRIMARY KEY,
    StoreId                         TEXT    NOT NULL,
    TemplateKind                    TEXT    NOT NULL,   -- Call / AllDone / Timeout / Remind / SoldOut
    Lang                            TEXT    NOT NULL DEFAULT 'zh-CN',
    Body                            TEXT    NOT NULL,   -- 含 {变量}；空串 = 该场景不播报
    Variables                       TEXT,
    Version                         INTEGER NOT NULL DEFAULT 1,
    IsEnabled                       INTEGER NOT NULL DEFAULT 1,
    CreatedAt                       TEXT    NOT NULL,
    UpdatedAt                       TEXT    NOT NULL,
    UpdatedBy                       TEXT
);
CREATE UNIQUE INDEX UX_VoiceTemplate ON VoiceTemplate (StoreId, TemplateKind, Lang);

-- §9.17 打印机配置
CREATE TABLE PrinterConfig (
    Uid                             TEXT    NOT NULL PRIMARY KEY,
    StoreId                         TEXT    NOT NULL,
    PrinterName                     TEXT    NOT NULL,
    Model                           TEXT,
    ConnectionType                  TEXT    NOT NULL DEFAULT 'Network', -- Network / Usb / Bluetooth
    PrinterHost                     TEXT,
    PrinterPort                     INTEGER DEFAULT 9100,
    ExecutorTerminalId              TEXT,
    OwnerStationId                  TEXT,
    PaperWidth                      TEXT    NOT NULL DEFAULT 'Mm58',   -- Mm58 / Mm80
    Encoding                        TEXT    NOT NULL DEFAULT 'GB18030',
    RenderMode                      TEXT    NOT NULL DEFAULT 'Image',   -- Image / EscPos
    IsEnabled                       INTEGER NOT NULL DEFAULT 1,
    LastSeenAt                      TEXT,
    CreatedAt                       TEXT    NOT NULL,
    CreatedBy                       TEXT,
    UpdatedAt                       TEXT    NOT NULL,
    UpdatedBy                       TEXT,
    IsDeleted                       INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IX_PrinterConfig_Station ON PrinterConfig (StoreId, OwnerStationId);
CREATE INDEX IX_PrinterConfig_Executor ON PrinterConfig (ExecutorTerminalId);

-- §9.19 打印模板
CREATE TABLE PrintTemplate (
    Uid                             TEXT    NOT NULL PRIMARY KEY,
    StoreId                         TEXT    NOT NULL,
    TemplateName                    TEXT    NOT NULL,
    TemplateKind                    TEXT    NOT NULL DEFAULT 'ItemSlip', -- OrderSummary / ItemSummary / ItemSlip
    TasteLayout                     TEXT    NOT NULL DEFAULT 'OwnLine', -- OwnLine / Column / Inline
    Lang                            TEXT    NOT NULL DEFAULT 'zh-CN',
    BodyHtml                        TEXT    NOT NULL,
    Variables                       TEXT,
    Version                         INTEGER NOT NULL DEFAULT 1,
    IsDefault                       INTEGER NOT NULL DEFAULT 0,
    CreatedAt                       TEXT    NOT NULL,
    CreatedBy                       TEXT,
    UpdatedAt                       TEXT    NOT NULL,
    UpdatedBy                       TEXT,
    IsDeleted                       INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IX_PrintTemplate_Kind ON PrintTemplate (StoreId, TemplateKind, Lang);

-- §9.21 屏内分区（V1.1 预留；V1 不建表亦可，此处一并给出）
-- TerminalPane：V1.1 功能预留表。V1 照建（结构即终态，避免后续迁移），但不开放配置入口，
-- 运行时 TerminalConfig.PaneLayout 恒为 Single，本表 V1 业务行数恒为 0（§9.21）
CREATE TABLE TerminalPane (
    Uid                             TEXT    NOT NULL PRIMARY KEY,
    TerminalId                      TEXT    NOT NULL,
    PaneIndex                       INTEGER NOT NULL,
    StationIds                      TEXT    NOT NULL,
    PaneTitle                       TEXT,
    SortMode                        TEXT    NOT NULL DEFAULT 'WaitDuration',
    WidthWeight                     REAL    NOT NULL DEFAULT 1.0,
    DefaultFilter                   TEXT,
    CreatedAt                       TEXT    NOT NULL,
    UpdatedAt                       TEXT    NOT NULL,
    IsDeleted                       INTEGER NOT NULL DEFAULT 0
);
CREATE UNIQUE INDEX UX_TerminalPane_Index ON TerminalPane (TerminalId, PaneIndex);

-- ============================================================================
-- 二、订单类
-- ============================================================================

-- §9.3 订单主表（主键命名例外：OrderId）
CREATE TABLE OrderHeader (
    OrderId                         TEXT    NOT NULL PRIMARY KEY,
    StoreId                         TEXT    NOT NULL,
    PosOrderNo                      TEXT    NOT NULL,          -- 幂等键
    OrderType                       TEXT    NOT NULL DEFAULT 'DineIn', -- DineIn / Takeaway / Pickup
    GuestCount                      INTEGER,
    TableUids                       TEXT,                       -- 冗余投影（不参与分组）
    PosSource                       TEXT,                       -- POS 来源标识
    IsSharedTable                   INTEGER NOT NULL DEFAULT 0,
    IsHeld                          INTEGER NOT NULL DEFAULT 0,
    -- 时间
    OrderCreateTime                 TEXT    NOT NULL,          -- POS 点菜时间
    ReceivedAt                      TEXT    NOT NULL,          -- Master 接收时间
    CompletedAt                     TEXT,
    -- 营业日（§2.13，入库快照，永不重算）
    BusinessDate                    TEXT    NOT NULL,
    MealPeriod                      TEXT,
    -- 备注
    Remark                          TEXT,                       -- LocalizedText JSON
    OrderStatus                     TEXT    NOT NULL DEFAULT 'Normal', -- Normal / PartlyCancelled / AllCancelled / Archived
    Version                         INTEGER NOT NULL DEFAULT 0,
    -- 上云回执（§14.1.2）
    HqUploadedAt                    TEXT,
    CreatedAt                       TEXT    NOT NULL,
    CreatedBy                       TEXT,
    UpdatedAt                       TEXT    NOT NULL,
    UpdatedBy                       TEXT,
    IsDeleted                       INTEGER NOT NULL DEFAULT 0
);
CREATE UNIQUE INDEX UX_OrderHeader_Store_PosNo ON OrderHeader (StoreId, PosOrderNo);
CREATE INDEX IX_OrderHeader_BusinessDate ON OrderHeader (BusinessDate);
CREATE INDEX IX_OrderHeader_HqPending ON OrderHeader (HqUploadedAt) WHERE HqUploadedAt IS NULL;

-- §9.4 订单明细（主键命名例外：DetailId）
CREATE TABLE OrderDetail (
    DetailId                        TEXT    NOT NULL PRIMARY KEY,
    OrderId                         TEXT    NOT NULL REFERENCES OrderHeader (OrderId),
    TableId                         TEXT    NOT NULL,          -- 无桌台 = Guid.Empty（不用 NULL）
    LineNo                          INTEGER NOT NULL,
    DishItemId                      TEXT,
    DishName                        TEXT    NOT NULL,          -- 当前语言解析结果
    Spec                            TEXT,
    Taste                           TEXT,
    Method                          TEXT,
    -- 数量（§4.6 / §4.7）
    Qty                             REAL    NOT NULL DEFAULT 1,
    CompletedQty                    REAL    NOT NULL DEFAULT 0,
    CancelledQty                    REAL    NOT NULL DEFAULT 0,
    QtyStepSnapshot                 REAL    NOT NULL DEFAULT 1,
    Unit                            TEXT    NOT NULL DEFAULT '份',
    -- 桌台快照
    TableNo                         TEXT,
    TableSortOrder                  INTEGER,
    -- 标记
    IsGift                          INTEGER NOT NULL DEFAULT 0,
    IsCancel                        INTEGER NOT NULL DEFAULT 0,      -- 派生：CancelledQty = Qty
    IsRush                          INTEGER NOT NULL DEFAULT 0,
    IsRemind                        INTEGER NOT NULL DEFAULT 0,
    IsHold                          INTEGER NOT NULL DEFAULT 0,      -- 派生：NotifyState = 30
    IsFire                          INTEGER NOT NULL DEFAULT 0,      -- 派生：NotifyState = 20
    SpecialFlags                    TEXT,
    -- 套餐（§2.12）
    IsComboItem                     INTEGER NOT NULL DEFAULT 0,
    ComboNo                         TEXT,
    ComboName                       TEXT,
    ComboSeq                        INTEGER,
    ComboItemTotal                  INTEGER,
    -- 人员与金额（§13.6.7，金额权威在 POS，KDS 只透传）
    WaiterName                      TEXT,
    UnitPrice                       REAL,
    Amount                          REAL,
    -- 催单 / 退菜 / 报损（§13.6.7 / §2.17）
    RemindCount                     INTEGER NOT NULL DEFAULT 0,
    RemindAt                        TEXT,
    RemindBy                        TEXT,
    CancelAt                        TEXT,
    CancelBy                        TEXT,
    CancelReason                    TEXT,                       -- 自由文本（§4.7.2）
    VoidQty                         REAL    NOT NULL DEFAULT 0,
    VoidReasonCode                  INTEGER,                    -- §2.17.1 号段
    VoidRemark                      TEXT,
    VoidAt                          TEXT,
    VoidBy                          TEXT,
    -- 状态机（§2.15）
    WorkflowStage                   TEXT    NOT NULL DEFAULT 'Pending',
    StageStatus                     TEXT    NOT NULL DEFAULT 'Waiting',
    StagePathSnapshot               TEXT    NOT NULL DEFAULT 'Prep,Cook,Expo',
    StageStandardSeconds            TEXT,
    StageBeginTime                  TEXT,
    StageCompleteTime               TEXT,
    StageElapsedSeconds             INTEGER,
    StatusUpdatedAt                 TEXT    NOT NULL,
    CurrentStationId                TEXT,
    SkippedStages                   TEXT,
    -- 通知单（§2.16）
    NotifyState                     INTEGER NOT NULL DEFAULT 0,
    NotifyFlags                     INTEGER NOT NULL DEFAULT 0,
    FirstFireAt                     TEXT,
    LastFireAt                      TEXT,
    HoldCount                       INTEGER NOT NULL DEFAULT 0,
    HoldAccumSeconds                INTEGER NOT NULL DEFAULT 0,
    -- 计时与超时（§4.4.1 / §4.4.2）
    TotalWaitBeginTime              TEXT    NOT NULL,
    TotalTimeoutSeconds             INTEGER NOT NULL,
    ProducedAt                      TEXT,
    ProducedSeconds                 INTEGER,
    IsTimeout                       INTEGER NOT NULL DEFAULT 0,
    TimeoutSeconds                  INTEGER,
    -- 营业日快照（§2.13；报表按营业日筛选明细，§13.6.7）
    BusinessDate                    TEXT    NOT NULL,
    MealPeriod                      TEXT,
    -- 跨营业日（§2.14）
    IsCrossDay                      INTEGER NOT NULL DEFAULT 0,
    CrossDayDays                    INTEGER NOT NULL DEFAULT 0,
    ClosedAt                        TEXT,
    ClosedReason                    TEXT,
    -- 并发与审计
    Version                         INTEGER NOT NULL DEFAULT 0,
    CreatedAt                       TEXT    NOT NULL,
    CreatedBy                       TEXT,
    UpdatedAt                       TEXT    NOT NULL,
    UpdatedBy                       TEXT,
    IsDeleted                       INTEGER NOT NULL DEFAULT 0
);
CREATE UNIQUE INDEX UX_OrderDetail_LineNo ON OrderDetail (OrderId, LineNo);
CREATE INDEX IX_OrderDetail_Stage ON OrderDetail (WorkflowStage, StageStatus);
CREATE INDEX IX_OrderDetail_Station ON OrderDetail (CurrentStationId, WorkflowStage);
CREATE INDEX IX_OrderDetail_Table ON OrderDetail (TableId);
CREATE INDEX IX_OrderDetail_Combo ON OrderDetail (OrderId, ComboNo);
-- 报表所需索引（§13.6.7）：按营业日筛选各类明细
CREATE INDEX IX_OrderDetail_Biz ON OrderDetail (BusinessDate);
CREATE INDEX IX_OrderDetail_Biz_Cancel ON OrderDetail (BusinessDate, CancelAt);
CREATE INDEX IX_OrderDetail_Biz_Remind ON OrderDetail (BusinessDate, RemindAt);
CREATE INDEX IX_OrderDetail_Biz_Timeout ON OrderDetail (BusinessDate, TimeoutSeconds);
CREATE INDEX IX_OrderDetail_Biz_Void ON OrderDetail (BusinessDate, VoidAt);
CREATE INDEX IX_OrderDetail_Biz_Item ON OrderDetail (BusinessDate, DishItemId);
CREATE INDEX IX_OrderDetail_Biz_Waiter ON OrderDetail (BusinessDate, WaiterName);
CREATE INDEX IX_OrderDetail_CrossDay ON OrderDetail (IsCrossDay, BusinessDate);

-- §9.8 订单-桌台关联（业务键 (OrderId, TableId) = 卡片分组键）
CREATE TABLE OrderTableRel (
    Uid                             TEXT    NOT NULL PRIMARY KEY,
    OrderId                         TEXT    NOT NULL REFERENCES OrderHeader (OrderId),
    TableId                         TEXT    NOT NULL,
    TableCodeSnapshot               TEXT,
    SortOrderSnapshot               INTEGER,
    AreaNameSnapshot                TEXT,
    Status                          TEXT    NOT NULL DEFAULT 'Active', -- Active / Closed
    CreatedAt                       TEXT    NOT NULL,
    CreatedBy                       TEXT,
    UpdatedAt                       TEXT    NOT NULL,
    UpdatedBy                       TEXT,
    IsDeleted                       INTEGER NOT NULL DEFAULT 0
);
CREATE UNIQUE INDEX UX_OrderTableRel_Order_Table ON OrderTableRel (OrderId, TableId);
CREATE INDEX IX_OrderTableRel_Table ON OrderTableRel (TableId, Status);
CREATE INDEX IX_OrderTableRel_Order ON OrderTableRel (OrderId);

-- §9.21a 明细阶段时间线（每阶段一行，不可变）
CREATE TABLE OrderDetailStageLog (
    Uid                             TEXT    NOT NULL PRIMARY KEY,
    DetailId                        TEXT    NOT NULL REFERENCES OrderDetail (DetailId),
    OrderId                         TEXT    NOT NULL,
    BusinessDate                    TEXT    NOT NULL,
    Stage                           TEXT    NOT NULL,
    EnterAt                         TEXT    NOT NULL,
    ExitAt                          TEXT,
    ElapsedSeconds                  INTEGER,
    WaitSeconds                     INTEGER,
    StationId                       TEXT,
    OperatorName                    TEXT,
    EnterSource                     TEXT    NOT NULL DEFAULT 'Auto',  -- Auto / Manual / Skip
    ExitReason                      TEXT,                            -- Completed / Cancelled / Closed / Void
    IsReverted                      INTEGER NOT NULL DEFAULT 0,      -- 撤销后标记（§2.19.3）
    CreatedAt                       TEXT    NOT NULL
);
CREATE UNIQUE INDEX UX_StageLog_Detail_Stage ON OrderDetailStageLog (DetailId, Stage);
CREATE INDEX IX_StageLog_Biz_Stage ON OrderDetailStageLog (BusinessDate, Stage);
CREATE INDEX IX_StageLog_Station ON OrderDetailStageLog (BusinessDate, StationId, Stage);

-- ============================================================================
-- 三、日志与队列类
-- ============================================================================

-- §9.12 操作日志（撤销能力依赖 FromStage/ToStage/VersionAt）
CREATE TABLE OperationLog (
    Uid                             TEXT    NOT NULL PRIMARY KEY,
    StoreId                         TEXT    NOT NULL,
    TerminalId                      TEXT,
    OperatorName                    TEXT,
    Action                          TEXT    NOT NULL,
    OrderId                         TEXT,
    DetailId                        TEXT,
    Stage                           TEXT,
    FromStage                       TEXT,
    ToStage                         TEXT,
    FromStatus                      TEXT,
    ToStatus                        TEXT,
    Qty                             REAL,
    VersionAt                       INTEGER,
    IsUndoable                      INTEGER NOT NULL DEFAULT 0,
    RevertedAt                      TEXT,
    RevertedBy                      TEXT,
    ClientEventId                   TEXT,
    BeforeState                     TEXT,
    AfterState                      TEXT,
    Result                          TEXT    NOT NULL DEFAULT 'Success',
    Remark                          TEXT,
    BusinessDate                    TEXT,
    OccurredAt                      TEXT    NOT NULL,
    CreatedAt                       TEXT    NOT NULL
);
CREATE INDEX IX_OperationLog_Order ON OperationLog (OrderId, CreatedAt);
CREATE INDEX IX_OperationLog_Terminal ON OperationLog (TerminalId, CreatedAt);
CREATE INDEX IX_OperationLog_Biz ON OperationLog (TerminalId, BusinessDate, CreatedAt);
CREATE INDEX IX_OperationLog_Undo ON OperationLog (TerminalId, BusinessDate, IsUndoable, RevertedAt);
CREATE UNIQUE INDEX UX_OperationLog_ClientEventId ON OperationLog (ClientEventId) WHERE ClientEventId IS NOT NULL;

-- §9.13 原始事件日志（POS 入站全量留存，可重放）
CREATE TABLE EventLog (
    Uid                             TEXT    NOT NULL PRIMARY KEY,
    StoreId                         TEXT    NOT NULL,
    EventId                         TEXT    NOT NULL,
    EventType                       TEXT    NOT NULL,
    PosSource                       TEXT,
    Payload                         TEXT    NOT NULL,
    ProtocolVersion                 TEXT,
    SourceTimestamp                 TEXT,                       -- 事件内声明的发生时间（POS 时钟）
    TraceId                         TEXT,
    ProcessStatus                   TEXT    NOT NULL DEFAULT 'Pending', -- Processed / Ignored / Failed
    ErrorCode                       TEXT,                       -- 处理失败错误码（结构化）
    ErrorMessage                    TEXT,
    ReceivedAt                      TEXT    NOT NULL,
    ProcessedAt                     TEXT,
    CreatedAt                       TEXT    NOT NULL
);
CREATE UNIQUE INDEX UX_EventLog_EventId ON EventLog (EventId);
CREATE INDEX IX_EventLog_Type_Time ON EventLog (EventType, ReceivedAt);

-- §9.14 出站回执待发表
CREATE TABLE OutboxMessage (
    Uid                             TEXT    NOT NULL PRIMARY KEY,
    StoreId                         TEXT    NOT NULL,
    TargetKind                      TEXT    NOT NULL DEFAULT 'Pos',  -- Pos / Hq
    EventType                       TEXT    NOT NULL,
    Payload                         TEXT    NOT NULL,
    IdempotencyKey                  TEXT    NOT NULL,
    Status                          TEXT    NOT NULL DEFAULT 'Pending', -- Pending/Sent/Failed/DeadLetter
    RetryCount                      INTEGER NOT NULL DEFAULT 0,
    NextRetryAt                     TEXT,
    LastError                       TEXT,
    CreatedAt                       TEXT    NOT NULL,
    SentAt                          TEXT
);
CREATE UNIQUE INDEX UX_Outbox_IdempotencyKey ON OutboxMessage (IdempotencyKey);
CREATE INDEX IX_Outbox_Status ON OutboxMessage (Status, NextRetryAt);
CREATE INDEX IX_Outbox_DeadLetter ON OutboxMessage (Status, CreatedAt);

-- §9.18 打印规则（阶段 × 档口 → 打印机 + 模板）
CREATE TABLE PrintRule (
    Uid                             TEXT    NOT NULL PRIMARY KEY,
    StoreId                         TEXT    NOT NULL,
    StationId                       TEXT    NOT NULL,
    Stage                           TEXT    NOT NULL,
    Trigger                         TEXT    NOT NULL DEFAULT 'OnStageComplete',
    TemplateId                      TEXT,
    PrinterId                       TEXT,
    Copies                          INTEGER NOT NULL DEFAULT 1,
    IsEnabled                       INTEGER NOT NULL DEFAULT 1,
    CreatedAt                       TEXT    NOT NULL,
    CreatedBy                       TEXT,
    UpdatedAt                       TEXT    NOT NULL,
    UpdatedBy                       TEXT,
    IsDeleted                       INTEGER NOT NULL DEFAULT 0
);
CREATE UNIQUE INDEX UX_PrintRule_Station_Stage ON PrintRule (StationId, Stage);

-- §9.20 打印任务（每执行终端独立队列）
CREATE TABLE PrintJob (
    Uid                             TEXT    NOT NULL PRIMARY KEY,
    StoreId                         TEXT    NOT NULL,
    DetailId                        TEXT,
    OrderId                         TEXT,
    StationId                       TEXT,
    Stage                           TEXT,
    Trigger                         TEXT    NOT NULL,
    PrinterId                       TEXT    NOT NULL,
    ExecutorTerminalId              TEXT,                       -- 队列归属键
    TemplateId                      TEXT,
    TemplateVersion                 INTEGER,
    RenderMode                      TEXT    NOT NULL DEFAULT 'Image',
    ContentSnapshot                 TEXT    NOT NULL,
    PrintIndex                      INTEGER NOT NULL DEFAULT 1,
    IdempotencyKey                  TEXT    NOT NULL,
    Status                          TEXT    NOT NULL DEFAULT 'Pending',
    Priority                        INTEGER NOT NULL DEFAULT 0,
    RetryCount                      INTEGER NOT NULL DEFAULT 0,
    LeaseUntil                      TEXT,
    ErrorMessage                    TEXT,
    CompletedAt                     TEXT,
    CreatedAt                       TEXT    NOT NULL,
    UpdatedAt                       TEXT    NOT NULL
);
CREATE INDEX IX_PrintJob_Queue ON PrintJob (ExecutorTerminalId, Status, Priority DESC, CreatedAt);
CREATE UNIQUE INDEX UX_PrintJob_Idempotency ON PrintJob (IdempotencyKey, PrintIndex);
CREATE INDEX IX_PrintJob_Printer ON PrintJob (PrinterId, Status);
CREATE INDEX IX_PrintJob_Created ON PrintJob (CreatedAt);

-- §9.15b 沽清记录
CREATE TABLE SoldOutLog (
    Uid                             TEXT    NOT NULL PRIMARY KEY,
    StoreId                         TEXT    NOT NULL,
    DishItemId                      TEXT    NOT NULL,
    DishTypeId                      TEXT,
    DishNameSnapshot                TEXT,
    SoldOutType                     TEXT    NOT NULL DEFAULT 'UntilManual',
    LimitQty                        REAL,
    SoldQty                         REAL    NOT NULL DEFAULT 0,
    ReasonCode                      INTEGER NOT NULL DEFAULT 0,
    Remark                          TEXT,
    StartAt                         TEXT    NOT NULL,
    EndAt                           TEXT,
    EndReason                       TEXT,
    Status                          TEXT    NOT NULL DEFAULT 'Requested',
    RequestedBy                     TEXT,
    RequestedFrom                   TEXT    NOT NULL DEFAULT 'Kds',
    ApprovedBy                      TEXT,
    ApprovedAt                      TEXT,
    BusinessDate                    TEXT    NOT NULL,
    CreatedAt                       TEXT    NOT NULL,
    UpdatedAt                       TEXT    NOT NULL,
    IsDeleted                       INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IX_SoldOutLog_Item_Active ON SoldOutLog (StoreId, DishItemId, Status);
CREATE INDEX IX_SoldOutLog_Biz ON SoldOutLog (StoreId, BusinessDate);
CREATE INDEX IX_SoldOutLog_Status_End ON SoldOutLog (Status, EndAt);

-- §9.15c 叫号记录
CREATE TABLE CallLog (
    Uid                             TEXT    NOT NULL PRIMARY KEY,
    StoreId                         TEXT    NOT NULL,
    OrderId                         TEXT,
    TableId                         TEXT,
    TableCodeSnapshot               TEXT,
    TerminalId                      TEXT,
    OperatorName                    TEXT,
    TriggerSource                   TEXT    NOT NULL DEFAULT 'Manual',
    RenderedText                    TEXT,
    TemplateKind                    TEXT,
    Lang                            TEXT,
    TtsProvider                     TEXT,
    SpeakResult                     TEXT    NOT NULL DEFAULT 'Skipped',
    ErrorMessage                    TEXT,
    BusinessDate                    TEXT    NOT NULL,
    CreatedAt                       TEXT    NOT NULL
);
CREATE INDEX IX_CallLog_Cooldown ON CallLog (StoreId, TableId, CreatedAt);
CREATE INDEX IX_CallLog_Biz ON CallLog (StoreId, BusinessDate);

-- §9.15d 账号（管理端登录账号 + 作业屏人员名单，一张表两类）
CREATE TABLE UserAccount (
    Uid                             TEXT    NOT NULL PRIMARY KEY,
    StoreId                         TEXT    NOT NULL,
    UserName                        TEXT    NOT NULL,
    DisplayName                     TEXT    NOT NULL,
    AccountType                     TEXT    NOT NULL DEFAULT 'Admin',   -- Admin / Operator
    Role                            TEXT,                              -- Owner / Manager / Viewer（Operator 为空）
    PasswordHash                    TEXT,
    PasswordSalt                    TEXT,
    PasswordIterations              INTEGER,
    MustChangePassword              INTEGER NOT NULL DEFAULT 0,
    PasswordUpdatedAt               TEXT,
    IsEnabled                       INTEGER NOT NULL DEFAULT 1,
    IsRosterVisible                 INTEGER NOT NULL DEFAULT 1,
    Phone                           TEXT,
    FailedLoginCount                INTEGER NOT NULL DEFAULT 0,
    LockedUntil                     TEXT,
    LastLoginAt                     TEXT,
    Remark                          TEXT,
    Position                        TEXT,                              -- 岗位（仅 Operator）
    Source                          TEXT    NOT NULL DEFAULT 'Local',   -- Local / Pos
    ExternalId                      TEXT,                              -- POS 员工 ID
    SyncedAt                        TEXT,
    RoleOverriddenByAdmin           INTEGER NOT NULL DEFAULT 0,
    CreatedAt                       TEXT    NOT NULL,
    CreatedBy                       TEXT,
    UpdatedAt                       TEXT    NOT NULL,
    UpdatedBy                       TEXT,
    IsDeleted                       INTEGER NOT NULL DEFAULT 0
);
CREATE UNIQUE INDEX UX_UserAccount_Name ON UserAccount (StoreId, UserName);
CREATE INDEX IX_UserAccount_Type ON UserAccount (StoreId, AccountType, IsEnabled);
CREATE INDEX IX_UserAccount_Role ON UserAccount (StoreId, Role);
CREATE UNIQUE INDEX UX_UserAccount_External ON UserAccount (StoreId, ExternalId) WHERE ExternalId IS NOT NULL;

-- §9.15e 登录日志（只追加，保留 180 天）
CREATE TABLE LoginLog (
    Uid                             TEXT    NOT NULL PRIMARY KEY,
    StoreId                         TEXT    NOT NULL,
    UserName                        TEXT    NOT NULL,
    UserId                          TEXT,
    Success                         INTEGER NOT NULL,
    FailReason                      TEXT,                              -- BadPassword/NoSuchUser/Disabled/LockedOut/MustChangePassword
    IpAddress                       TEXT,
    UserAgent                       TEXT,
    SessionId                       TEXT,
    OccurredAt                      TEXT    NOT NULL
);
CREATE INDEX IX_LoginLog_User_Time ON LoginLog (StoreId, UserName, OccurredAt);
CREATE INDEX IX_LoginLog_Fail ON LoginLog (StoreId, Success, OccurredAt);

-- §9.15f 会话（屏无感登录令牌哈希 + 终端绑定）
CREATE TABLE UserSession (
    Uid                             TEXT    NOT NULL PRIMARY KEY,
    StoreId                         TEXT    NOT NULL,
    UserId                          TEXT    NOT NULL REFERENCES UserAccount (Uid),
    TokenHash                       TEXT    NOT NULL,                  -- SHA256 十六进制
    SessionType                     TEXT    NOT NULL DEFAULT 'Admin',  -- Screen / Admin
    TerminalId                      TEXT,
    DeviceKey                       TEXT,
    ExpiresAt                       TEXT,                              -- 空 = 永久（ScreenSessionDays=0）
    LastSeenAt                      TEXT    NOT NULL,
    RevokedAt                       TEXT,
    RevokedReason                   TEXT,
    RotationCount                   INTEGER NOT NULL DEFAULT 0,
    IpAddress                       TEXT,
    UserAgent                       TEXT,
    CreatedAt                       TEXT    NOT NULL
);
CREATE UNIQUE INDEX UX_UserSession_TokenHash ON UserSession (TokenHash);
CREATE INDEX IX_UserSession_User ON UserSession (UserId, RevokedAt);
CREATE INDEX IX_UserSession_Terminal ON UserSession (TerminalId, RevokedAt);

-- ============================================================================
-- 四、统计与归档类
-- ============================================================================

-- §9.22 门店日统计（L3，永久保留）
CREATE TABLE DailyStoreStat (
    Uid                             TEXT    NOT NULL PRIMARY KEY,
    StoreId                         TEXT    NOT NULL,
    StatDate                        TEXT    NOT NULL,          -- 营业日
    OrderCount                      INTEGER NOT NULL DEFAULT 0,
    DetailCount                     INTEGER NOT NULL DEFAULT 0,
    TotalQty                        REAL    NOT NULL DEFAULT 0,
    OutputQty                       REAL    NOT NULL DEFAULT 0,
    CancelledCount                  INTEGER NOT NULL DEFAULT 0,
    CancelledQty                    REAL    NOT NULL DEFAULT 0,
    CancelledAmount                 REAL    NOT NULL DEFAULT 0,
    RemindCount                     INTEGER NOT NULL DEFAULT 0,
    RemindQty                       REAL    NOT NULL DEFAULT 0,
    GiftCount                       INTEGER NOT NULL DEFAULT 0,
    GuestCount                      INTEGER NOT NULL DEFAULT 0,
    TableCount                      INTEGER NOT NULL DEFAULT 0,
    AvgElapsedSeconds               INTEGER NOT NULL DEFAULT 0,
    SumElapsedSeconds               INTEGER NOT NULL DEFAULT 0,
    ElapsedCount                    INTEGER NOT NULL DEFAULT 0,
    P50ElapsedSeconds               INTEGER,
    P90ElapsedSeconds               INTEGER,
    MaxElapsedSeconds               INTEGER,
    ElapsedBuckets                  TEXT,
    TimeoutCount                    INTEGER NOT NULL DEFAULT 0,
    TimeoutQty                      REAL    NOT NULL DEFAULT 0,
    TimeoutRate                     REAL    NOT NULL DEFAULT 0,
    SumWaitBeforeBumpSeconds        INTEGER,
    SkipDoneCount                   INTEGER NOT NULL DEFAULT 0,
    VoidCount                       INTEGER NOT NULL DEFAULT 0,
    VoidQty                         REAL    NOT NULL DEFAULT 0,
    VoidAmount                      REAL    NOT NULL DEFAULT 0,
    UndoCount                       INTEGER NOT NULL DEFAULT 0,
    UndoRate                        REAL    NOT NULL DEFAULT 0,
    CrossDayOpenCount               INTEGER NOT NULL DEFAULT 0,
    CrossDayClosedCount             INTEGER NOT NULL DEFAULT 0,
    HqUploadedAt                    TEXT,
    CreatedAt                       TEXT    NOT NULL,
    CalcVersion                     INTEGER NOT NULL DEFAULT 1
);
CREATE UNIQUE INDEX UX_DailyStoreStat_Date ON DailyStoreStat (StoreId, StatDate);

-- §9.23 维度日统计（档口 / 档口×阶段 / 品项 / 品项×档口 / 订单类型 / 餐段 / 区域 / 时段）
CREATE TABLE DailyDimStat (
    Uid                             TEXT    NOT NULL PRIMARY KEY,
    StoreId                         TEXT    NOT NULL,
    StatDate                        TEXT    NOT NULL,
    Dimension                       TEXT    NOT NULL,
    DimKey                          TEXT    NOT NULL,
    DimNameSnapshot                 TEXT,
    OrderCount                      INTEGER NOT NULL DEFAULT 0,
    DetailCount                     INTEGER NOT NULL DEFAULT 0,
    TotalQty                        REAL    NOT NULL DEFAULT 0,
    OutputQty                       REAL    NOT NULL DEFAULT 0,
    CancelledQty                    REAL    NOT NULL DEFAULT 0,
    CancelledAmount                 REAL    NOT NULL DEFAULT 0,
    RemindCount                     INTEGER NOT NULL DEFAULT 0,
    RemindQty                       REAL    NOT NULL DEFAULT 0,
    TimeoutQty                      REAL    NOT NULL DEFAULT 0,
    VoidQty                         REAL    NOT NULL DEFAULT 0,
    VoidAmount                      REAL    NOT NULL DEFAULT 0,
    AvgElapsedSeconds               INTEGER,
    SumElapsedSeconds               INTEGER NOT NULL DEFAULT 0,
    ElapsedCount                    INTEGER NOT NULL DEFAULT 0,
    P90ElapsedSeconds               INTEGER,
    TimeoutCount                    INTEGER NOT NULL DEFAULT 0,
    CancelledCount                  INTEGER NOT NULL DEFAULT 0,
    GiftCount                       INTEGER NOT NULL DEFAULT 0,
    HqUploadedAt                    TEXT,
    CreatedAt                       TEXT    NOT NULL,
    CalcVersion                     INTEGER NOT NULL DEFAULT 1
);
CREATE UNIQUE INDEX UX_DailyDimStat ON DailyDimStat (StoreId, StatDate, Dimension, DimKey);
CREATE INDEX IX_DailyDimStat_Dim ON DailyDimStat (Dimension, DimKey, StatDate);

-- §14.1.5 归档卷登记
CREATE TABLE ArchiveVolume (
    Uid                             TEXT    NOT NULL PRIMARY KEY,
    StoreId                         TEXT    NOT NULL,
    VolumeMonth                     TEXT    NOT NULL,          -- 营业月 2026-10
    BusinessDateFrom                TEXT,
    BusinessDateTo                  TEXT,
    FileName                        TEXT,
    FilePath                        TEXT,
    Engine                          TEXT    NOT NULL DEFAULT 'Sqlite', -- Sqlite / SqlServer
    RowCount                        INTEGER,
    SizeBytes                       INTEGER,
    Checksum                        TEXT,
    Status                          TEXT    NOT NULL DEFAULT 'Writing', -- Writing/Sealed/Uploaded/Corrupted/Deleted
    LastMovedBusinessDate           TEXT,                       -- 迁移水位
    SealedAt                        TEXT,
    HqUploadedAt                    TEXT,
    HqRecordCount                   INTEGER,
    DeletedAt                       TEXT,
    CreatedAt                       TEXT    NOT NULL,
    UpdatedAt                       TEXT    NOT NULL
);
CREATE UNIQUE INDEX UX_ArchiveVolume_Month ON ArchiveVolume (StoreId, VolumeMonth);

-- ============================================================================
-- 说明
-- ============================================================================
-- ① 写 DDL 时发现并修正的一处遗漏：OrderDetail 必须有 BusinessDate / MealPeriod
--    （§9.4 已有定义，初版 DDL 漏写）。缺了它，§13.6.7 的明细报表无法按营业日筛选。
--    已在 CREATE TABLE 中补入，并补齐 7 个按营业日的报表索引。
--
-- ② SQLite 特有注意事项：
--    - GUID 必须写入小写带横线格式（D 格式小写），仓储层统一转换（§8.1）
--    - 布尔用 INTEGER 0/1；枚举用 TEXT（PascalCase 字符串）（§8）
--    - datetimeoffset 存 ISO 8601 带时区文本；跨库比较在应用层统一换算
--    - 部分索引（WHERE ...）SQLite 支持；SQL Server 用筛选索引（filtered index）
--
-- ③ 建表顺序已按依赖排列：配置类 → 订单类 → 日志队列类 → 统计归档类
--    若要重建，按本文件顺序执行即可（仅 OrderDetail → OrderHeader 一处 FK 依赖）。
--
-- ④ V1.1 预留表：TerminalPane（PaneLayout 启用后才需要）。
--    V1 部署可跳过该表，不影响任何既有功能。
--
-- ⑤ 归档卷 schema：与本库同结构子集（OrderHeader / OrderDetail / OrderDetailStageLog /
--    OperationLog 片段），索引见 §13.6.4 ⑤（封卷时一次性建好）。