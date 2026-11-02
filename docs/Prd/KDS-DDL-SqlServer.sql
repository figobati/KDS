-- ============================================================================
-- KDS 厨房显示系统 — 门店运行库 DDL（SQL Server）
-- 版本：v6.65　生成依据：KDS-07-数据库与数据字典.md（§8–§9）
-- 最低版本：SQL Server 2016（不支持 2000/2005/2008，见 §8.3）
-- 与 SQLite 版（KDS-DDL-SQLite.sql）逐表对齐；差异仅类型映射与筛选索引语法
-- 执行：在空库上按顺序执行；建表顺序已按依赖排列
-- ============================================================================

-- ============================================================================
-- 一、配置类
-- ============================================================================

-- §9.1 门店配置（单行表）
CREATE TABLE StoreConfig (
    Uid                             uniqueidentifier NOT NULL CONSTRAINT PK_StoreConfig PRIMARY KEY,
    StoreId                         uniqueidentifier NOT NULL,   -- 门店业务 UID（业务唯一键，非主键）
    StoreCode                       nvarchar(64)     NOT NULL,   -- 门店编码（业务唯一）
    StoreName                       nvarchar(200)    NOT NULL,   -- 门店名称
    EnableWorkflowState             bit              NOT NULL CONSTRAINT DF_StoreConfig_Wf DEFAULT 1,
    FlowMode                        nvarchar(16)     NOT NULL CONSTRAINT DF_StoreConfig_FlowMode DEFAULT N'Auto',   -- Auto（V1 实现）/ Manual（设计保留，V2 实现）
    DefaultTotalTimeoutSeconds      int              NOT NULL CONSTRAINT DF_StoreConfig_To DEFAULT 1200,
    WarnRatio                       decimal(5,2)     NOT NULL CONSTRAINT DF_StoreConfig_Wr DEFAULT 0.80,
    TreatPlacedAsFired              bit              NOT NULL CONSTRAINT DF_StoreConfig_Tpaf DEFAULT 1,
    HoldPauseCounting               bit              NOT NULL CONSTRAINT DF_StoreConfig_Hpc DEFAULT 1,
    AllowKitchenCancel              bit              NOT NULL CONSTRAINT DF_StoreConfig_Akc DEFAULT 0,
    SoldOutMode                     nvarchar(32)     NOT NULL CONSTRAINT DF_StoreConfig_Som DEFAULT N'PosConfirm',
    EnableUndo                      bit              NOT NULL CONSTRAINT DF_StoreConfig_Eu  DEFAULT 1,
    UndoWindowSeconds               int              NOT NULL CONSTRAINT DF_StoreConfig_Uws DEFAULT 120,
    UndoScope                       nvarchar(32)     NOT NULL CONSTRAINT DF_StoreConfig_Us  DEFAULT N'PerDetail',
    UndoRequireSameOperator         bit              NOT NULL CONSTRAINT DF_StoreConfig_Urso DEFAULT 1,
    UndoPrintVoidSlip               bit              NOT NULL CONSTRAINT DF_StoreConfig_Upvs DEFAULT 0,
    EnableManageUndo                bit              NOT NULL CONSTRAINT DF_StoreConfig_Emu DEFAULT 0,
    DefaultLang                     nvarchar(16)     NOT NULL CONSTRAINT DF_StoreConfig_Dl  DEFAULT N'zh-CN',
    MainLang                        nvarchar(16)     NOT NULL CONSTRAINT DF_StoreConfig_Ml  DEFAULT N'zh-CN',
    BusinessDayStartHour            int              NOT NULL CONSTRAINT DF_StoreConfig_Bdsh DEFAULT 6,
    MealPeriods                     nvarchar(max)    NULL,
    FirstBusinessDate               date             NULL,
    MaintenanceWindowStartMinute    int              NOT NULL CONSTRAINT DF_StoreConfig_Mwsm DEFAULT 30,
    CrossDayHandleMode              nvarchar(32)     NOT NULL CONSTRAINT DF_StoreConfig_Cdhm DEFAULT N'MarkOnly',
    CrossDayAutoCloseDays           int              NOT NULL CONSTRAINT DF_StoreConfig_Cdacd DEFAULT 1,
    CrossDayPromptOnSwitch          bit              NOT NULL CONSTRAINT DF_StoreConfig_Cdpos DEFAULT 1,
    OrderRetentionDays              int              NOT NULL CONSTRAINT DF_StoreConfig_Ord DEFAULT 90,
    OrderHeaderRetentionDays        int              NOT NULL CONSTRAINT DF_StoreConfig_Ohrd DEFAULT 365,
    AutoCleanupEnabled              bit              NOT NULL CONSTRAINT DF_StoreConfig_Ace DEFAULT 1,
    ArchiveEnabled                  bit              NOT NULL CONSTRAINT DF_StoreConfig_Ae  DEFAULT 1,
    StatAggregateHour               int              NOT NULL CONSTRAINT DF_StoreConfig_Sah DEFAULT 3,
    LocalHistoryMode                nvarchar(32)     NOT NULL CONSTRAINT DF_StoreConfig_Lhm DEFAULT N'MoveToArchive',
    LocalBufferDaysAfterUpload      int              NOT NULL CONSTRAINT DF_StoreConfig_Lbdau DEFAULT 30,
    CleanupHour                     int              NOT NULL CONSTRAINT DF_StoreConfig_Ch  DEFAULT 4,
    DbSizeWarnMb                    int              NOT NULL CONSTRAINT DF_StoreConfig_Dswm DEFAULT 2048,
    LogRetentionDays                int              NOT NULL CONSTRAINT DF_StoreConfig_Lrd DEFAULT 30,
    LogMaxTotalMb                   int              NOT NULL CONSTRAINT DF_StoreConfig_Lmtm DEFAULT 2048,
    LogCompressAfterDays            int              NOT NULL CONSTRAINT DF_StoreConfig_Lcad DEFAULT 7,
    CrashLogRetentionDays           int              NOT NULL CONSTRAINT DF_StoreConfig_Clrd DEFAULT 90,
    LogLevel                        nvarchar(16)     NOT NULL CONSTRAINT DF_StoreConfig_Ll  DEFAULT N'Information',
    SlowQueryThresholdMs            int              NOT NULL CONSTRAINT DF_StoreConfig_Sqtm DEFAULT 200,
    DbLogWarnMb                     int              NOT NULL CONSTRAINT DF_StoreConfig_Dlwm DEFAULT 2048,
    SqlServerRecoveryMode           nvarchar(8)      NOT NULL CONSTRAINT DF_StoreConfig_Ssrm DEFAULT N'SIMPLE',
    ScreenSessionDays               int              NOT NULL CONSTRAINT DF_StoreConfig_Ssd DEFAULT 30,
    ScreenTokenRotation             bit              NOT NULL CONSTRAINT DF_StoreConfig_Str DEFAULT 1,
    AdminSessionIdleMinutes         int              NOT NULL CONSTRAINT DF_StoreConfig_Asim DEFAULT 30,
    AdminSessionAbsoluteHours       int              NOT NULL CONSTRAINT DF_StoreConfig_Asah DEFAULT 12,
    AllowScreenPinLogin             bit              NOT NULL CONSTRAINT DF_StoreConfig_Aspl DEFAULT 1,
    LoginLockoutCount               int              NOT NULL CONSTRAINT DF_StoreConfig_Llc DEFAULT 5,
    LoginLockoutMinutes             int              NOT NULL CONSTRAINT DF_StoreConfig_Llm DEFAULT 15,
    PasswordMinLength               int              NOT NULL CONSTRAINT DF_StoreConfig_Pml DEFAULT 8,
    PasswordRequireComplex          bit              NOT NULL CONSTRAINT DF_StoreConfig_Prc DEFAULT 1,
    StaffSource                     nvarchar(24)     NOT NULL CONSTRAINT DF_StoreConfig_Ssrc DEFAULT N'Local',
    PosRoleMapJson                  nvarchar(max)    NULL,
    PosStaffSyncIntervalMinutes     int              NOT NULL CONSTRAINT DF_StoreConfig_Pssim DEFAULT 60,
    HqUploadEnabled                 bit              NOT NULL CONSTRAINT DF_StoreConfig_Hue DEFAULT 0,
    HqUploadScope                   nvarchar(32)     NOT NULL CONSTRAINT DF_StoreConfig_Hus DEFAULT N'StatOnly',
    HqEndpoint                      nvarchar(500)    NULL,
    HqStoreToken                    nvarchar(500)    NULL,
    HqApiVersion                    int              NOT NULL CONSTRAINT DF_StoreConfig_Hav DEFAULT 1,
    HqBatchSize                     int              NOT NULL CONSTRAINT DF_StoreConfig_Hbs DEFAULT 500,
    HqTimeoutSeconds                int              NOT NULL CONSTRAINT DF_StoreConfig_Hts DEFAULT 30,
    HqCompress                      bit              NOT NULL CONSTRAINT DF_StoreConfig_Hc  DEFAULT 1,
    HqRetryMaxCount                 int              NOT NULL CONSTRAINT DF_StoreConfig_Hrmc DEFAULT 10,
    HqUploadIntervalMinutes         int              NOT NULL CONSTRAINT DF_StoreConfig_Huim DEFAULT 5,
    HqInsecureTransportAllowed      bit              NOT NULL CONSTRAINT DF_StoreConfig_Hita DEFAULT 0,
    PollingIntervalSeconds          int              NOT NULL CONSTRAINT DF_StoreConfig_Pis DEFAULT 15,
    PushSilenceSeconds              int              NOT NULL CONSTRAINT DF_StoreConfig_Pss DEFAULT 30,
    DataStaleSeconds                int              NOT NULL CONSTRAINT DF_StoreConfig_Dss DEFAULT 90,
    HeartbeatThresholdSeconds       int              NOT NULL CONSTRAINT DF_StoreConfig_Hts DEFAULT 60,
    RevisionHistorySize             int              NOT NULL CONSTRAINT DF_StoreConfig_Rhs DEFAULT 300,
    CompareDivisorMode              nvarchar(32)     NOT NULL CONSTRAINT DF_StoreConfig_Cdm DEFAULT N'EffectiveDays',
    TtsProvider                     nvarchar(32)     NOT NULL CONSTRAINT DF_StoreConfig_Ttp DEFAULT N'Console',
    CallCooldownSeconds             int              NOT NULL CONSTRAINT DF_StoreConfig_Ccs DEFAULT 30,
    CallQuietHours                  nvarchar(50)     NULL,
    CallAutoOnAllExpo               bit              NOT NULL CONSTRAINT DF_StoreConfig_Caoe DEFAULT 0,
    TtsVolume                       int              NOT NULL CONSTRAINT DF_StoreConfig_Tv  DEFAULT 100,
    TtsRate                         int              NOT NULL CONSTRAINT DF_StoreConfig_Tr  DEFAULT 0,
    CreatedAt                       datetimeoffset   NOT NULL,
    CreatedBy                       nvarchar(64)     NULL,
    UpdatedAt                       datetimeoffset   NOT NULL,
    UpdatedBy                       nvarchar(64)     NULL,
    IsDeleted                       bit              NOT NULL CONSTRAINT DF_StoreConfig_Del DEFAULT 0
);
CREATE UNIQUE INDEX UX_StoreConfig_Store ON StoreConfig (StoreId);

-- §9.2 终端屏幕配置
CREATE TABLE TerminalConfig (
    Uid                             uniqueidentifier NOT NULL CONSTRAINT PK_TerminalConfig PRIMARY KEY,
    StoreId                         uniqueidentifier NOT NULL,
    TerminalCode                    nvarchar(64)     NOT NULL,
    TerminalName                    nvarchar(200)    NOT NULL,
    TerminalType                    nvarchar(32)     NOT NULL CONSTRAINT DF_TerminalConfig_Type DEFAULT N'Station',
    Role                            nvarchar(16)     NULL,
    StationIds                      nvarchar(max)    NULL,
    BaseGroupMode                   nvarchar(32)     NOT NULL CONSTRAINT DF_TerminalConfig_Bgm DEFAULT N'TableMode',
    DefaultView                     nvarchar(32)     NOT NULL CONSTRAINT DF_TerminalConfig_Dv DEFAULT N'BaseGroupView',
    LastActiveView                  nvarchar(32)     NULL,
    CurrentLang                     nvarchar(16)     NOT NULL CONSTRAINT DF_TerminalConfig_Lang DEFAULT N'zh-CN',
    PageSize                        int              NOT NULL CONSTRAINT DF_TerminalConfig_Ps DEFAULT 20,
    ItemView_DetailMode             nvarchar(32)     NOT NULL CONSTRAINT DF_TerminalConfig_Ivdm DEFAULT N'SinglePortion',
    ItemView_SortMode               nvarchar(32)     NOT NULL CONSTRAINT DF_TerminalConfig_Ivsm DEFAULT N'TableFirst',
    SingleView_SortMode             nvarchar(32)     NOT NULL CONSTRAINT DF_TerminalConfig_Svsm DEFAULT N'WaitDuration',
    SingleView_HideCancelled        bit              NOT NULL CONSTRAINT DF_TerminalConfig_Svhc DEFAULT 0,
    TableView_SortMode              nvarchar(32)     NOT NULL CONSTRAINT DF_TerminalConfig_Tvsm DEFAULT N'TableOrder',
    DisplayStyle                    nvarchar(32)     NOT NULL CONSTRAINT DF_TerminalConfig_Ds  DEFAULT N'DishSummary',
    DishColumns                     int              NOT NULL CONSTRAINT DF_TerminalConfig_Dc  DEFAULT 8,
    DishRows                        int              NOT NULL CONSTRAINT DF_TerminalConfig_Dr  DEFAULT 6,
    FixDishPosition                 bit              NOT NULL CONSTRAINT DF_TerminalConfig_Fdp DEFAULT 0,
    FontScale                       nvarchar(4)      NOT NULL CONSTRAINT DF_TerminalConfig_Fs  DEFAULT N'M',
    OrderColumns                    int              NOT NULL CONSTRAINT DF_TerminalConfig_Oc  DEFAULT 2,
    OrderRows                       int              NOT NULL CONSTRAINT DF_TerminalConfig_Or  DEFAULT 2,
    CardSize                        nvarchar(4)      NOT NULL CONSTRAINT DF_TerminalConfig_Cs  DEFAULT N'S',
    DishSortMode                    nvarchar(16)     NOT NULL CONSTRAINT DF_TerminalConfig_Dsm DEFAULT N'OrderSeq',
    ShowCompleted                   bit              NOT NULL CONSTRAINT DF_TerminalConfig_Scp DEFAULT 1,
    ConfirmWholeTable               bit              NOT NULL CONSTRAINT DF_TerminalConfig_Cwt DEFAULT 1,
    HoldFireCountdown               bit              NOT NULL CONSTRAINT DF_TerminalConfig_Hfc DEFAULT 0,
    SearchBumpWholeTable            bit              NOT NULL CONSTRAINT DF_TerminalConfig_Sbwt DEFAULT 0,
    CallRepeatCount                 int              NOT NULL CONSTRAINT DF_TerminalConfig_Crc DEFAULT 1,
    SndNewOrder                     bit              NOT NULL CONSTRAINT DF_TerminalConfig_Sno DEFAULT 1,
    SndFire                         bit              NOT NULL CONSTRAINT DF_TerminalConfig_Sf  DEFAULT 1,
    SndRemind                       bit              NOT NULL CONSTRAINT DF_TerminalConfig_Srm DEFAULT 1,
    SndBumpSuccess                  bit              NOT NULL CONSTRAINT DF_TerminalConfig_Sbs DEFAULT 1,
    SndCall                         bit              NOT NULL CONSTRAINT DF_TerminalConfig_Scl DEFAULT 1,
    PrintItemSlipOnBump             bit              NOT NULL CONSTRAINT DF_TerminalConfig_Pisob DEFAULT 0,
    Merge_DiffOrder                 bit              NOT NULL CONSTRAINT DF_TerminalConfig_M1 DEFAULT 1,
    Merge_DiffFlavor                bit              NOT NULL CONSTRAINT DF_TerminalConfig_M2 DEFAULT 1,
    Merge_DineInTakeaway            bit              NOT NULL CONSTRAINT DF_TerminalConfig_M3 DEFAULT 1,
    Merge_ComboAndNormal            bit              NOT NULL CONSTRAINT DF_TerminalConfig_M4 DEFAULT 1,
    Merge_Timeout                   bit              NOT NULL CONSTRAINT DF_TerminalConfig_M5 DEFAULT 1,
    Merge_Rush                      bit              NOT NULL CONSTRAINT DF_TerminalConfig_M6 DEFAULT 1,
    Merge_Hold                      bit              NOT NULL CONSTRAINT DF_TerminalConfig_M7 DEFAULT 1,
    Merge_LinkedTable               bit              NOT NULL CONSTRAINT DF_TerminalConfig_Mlt DEFAULT 0,
    Merge_LinkedTable_CrossArea     bit              NOT NULL CONSTRAINT DF_TerminalConfig_Mltca DEFAULT 0,
    EnableOperate                   bit              NOT NULL CONSTRAINT DF_TerminalConfig_Eo DEFAULT 1,
    IsEnabled                       bit              NOT NULL CONSTRAINT DF_TerminalConfig_En DEFAULT 1,
    EnablePrint                     bit              NOT NULL CONSTRAINT DF_TerminalConfig_Ep DEFAULT 0,
    EnableReprint                   bit              NOT NULL CONSTRAINT DF_TerminalConfig_Er DEFAULT 0,
    PrintPriority                   int              NOT NULL CONSTRAINT DF_TerminalConfig_Pp DEFAULT 0,
    StaffName                       nvarchar(64)     NULL,
    PaneLayout                      nvarchar(16)     NOT NULL CONSTRAINT DF_TerminalConfig_Pl DEFAULT N'Single',
    EnableVoice                     bit              NOT NULL CONSTRAINT DF_TerminalConfig_Ev DEFAULT 1,
    EnableCall                      bit              NOT NULL CONSTRAINT DF_TerminalConfig_Ec DEFAULT 1,
    DeviceKey                       nvarchar(200)    NULL,
    AppliedConfigVersion            int              NOT NULL CONSTRAINT DF_TerminalConfig_Acv DEFAULT 0,
    ConfigVersion                   int              NOT NULL CONSTRAINT DF_TerminalConfig_Cv DEFAULT 1,
    CreatedAt                       datetimeoffset   NOT NULL,
    CreatedBy                       nvarchar(64)     NULL,
    UpdatedAt                       datetimeoffset   NOT NULL,
    UpdatedBy                       nvarchar(64)     NULL,
    IsDeleted                       bit              NOT NULL CONSTRAINT DF_TerminalConfig_Del DEFAULT 0
);
CREATE UNIQUE INDEX UX_TerminalConfig_Code ON TerminalConfig (StoreId, TerminalCode);

-- §9.5 品项基础资料
CREATE TABLE DishItem (
    Uid                             uniqueidentifier NOT NULL CONSTRAINT PK_DishItem PRIMARY KEY,
    StoreId                         uniqueidentifier NOT NULL,
    ItemCode                        nvarchar(64)     NOT NULL,
    ItemName                        nvarchar(max)    NOT NULL,   -- LocalizedText JSON
    DishTypeId                      uniqueidentifier NULL,
    SaleMode                        nvarchar(16)     NOT NULL CONSTRAINT DF_DishItem_Sm DEFAULT N'ByPiece',
    QtyStep                         decimal(18,3)    NOT NULL CONSTRAINT DF_DishItem_Qs DEFAULT 1,
    Unit                            nvarchar(16)     NULL,
    TotalTimeoutSeconds             int              NULL,
    StageStandardSeconds            nvarchar(max)    NULL,
    IsEnabled                       bit              NOT NULL CONSTRAINT DF_DishItem_En DEFAULT 1,
    SortOrder                       int              NOT NULL CONSTRAINT DF_DishItem_So DEFAULT 0,
    DefaultSpec                     nvarchar(100)    NULL,        -- 默认规格
    Price                           decimal(18,3)    NULL,        -- 单价（仅展示，KDS 不做金额计算）
    IsSoldOut                       bit              NOT NULL CONSTRAINT DF_DishItem_Sold DEFAULT 0,
    CreatedAt                       datetimeoffset   NOT NULL,
    CreatedBy                       nvarchar(64)     NULL,
    UpdatedAt                       datetimeoffset   NOT NULL,
    UpdatedBy                       nvarchar(64)     NULL,
    IsDeleted                       bit              NOT NULL CONSTRAINT DF_DishItem_Del DEFAULT 0
);
CREATE UNIQUE INDEX UX_DishItem_Code ON DishItem (StoreId, ItemCode);
CREATE INDEX IX_DishItem_Type ON DishItem (StoreId, DishTypeId);

-- §9.6 品项类型 / 品类
CREATE TABLE DishType (
    Uid                             uniqueidentifier NOT NULL CONSTRAINT PK_DishType PRIMARY KEY,
    StoreId                         uniqueidentifier NOT NULL,
    TypeCode                        nvarchar(64)     NOT NULL,
    TypeName                        nvarchar(max)    NOT NULL,
    ParentTypeId                    uniqueidentifier NULL,
    SortOrder                       int              NOT NULL CONSTRAINT DF_DishType_So DEFAULT 0,
    DefaultStagePath                nvarchar(50)     NULL,        -- 品类默认 StagePath
    DefaultStageStandardSeconds     nvarchar(max)    NULL,        -- 品类默认阶段标准工时 JSON
    CreatedAt                       datetimeoffset   NOT NULL,
    CreatedBy                       nvarchar(64)     NULL,
    UpdatedAt                       datetimeoffset   NOT NULL,
    UpdatedBy                       nvarchar(64)     NULL,
    IsDeleted                       bit              NOT NULL CONSTRAINT DF_DishType_Del DEFAULT 0
);
CREATE UNIQUE INDEX UX_DishType_Code ON DishType (StoreId, TypeCode);

-- §9.7 桌台主数据
CREATE TABLE DiningTable (
    Uid                             uniqueidentifier NOT NULL CONSTRAINT PK_DiningTable PRIMARY KEY,
    StoreId                         uniqueidentifier NOT NULL,
    ExternalTableId                 nvarchar(64)     NULL,
    TableCode                       nvarchar(64)     NOT NULL,
    TableName                       nvarchar(max)    NULL,
    AreaName                        nvarchar(200)    NULL,
    SeatCount                       int              NULL,
    SortOrder                       int              NOT NULL CONSTRAINT DF_DiningTable_So DEFAULT 0,
    IsEnabled                       bit              NOT NULL CONSTRAINT DF_DiningTable_En DEFAULT 1,
    IsAutoCreated                   bit              NOT NULL CONSTRAINT DF_DiningTable_Auto DEFAULT 0,
    CreatedAt                       datetimeoffset   NOT NULL,
    CreatedBy                       nvarchar(64)     NULL,
    UpdatedAt                       datetimeoffset   NOT NULL,
    UpdatedBy                       nvarchar(64)     NULL,
    IsDeleted                       bit              NOT NULL CONSTRAINT DF_DiningTable_Del DEFAULT 0
);
CREATE UNIQUE INDEX UX_DiningTable_Code ON DiningTable (StoreId, TableCode);
CREATE UNIQUE INDEX UX_DiningTable_External ON DiningTable (StoreId, ExternalTableId) WHERE ExternalTableId IS NOT NULL;
CREATE INDEX IX_DiningTable_Sort ON DiningTable (StoreId, SortOrder);

-- §9.9 档口主配置
CREATE TABLE Station (
    Uid                             uniqueidentifier NOT NULL CONSTRAINT PK_Station PRIMARY KEY,
    StoreId                         uniqueidentifier NOT NULL,
    StationCode                     nvarchar(64)     NOT NULL,
    Name                            nvarchar(max)    NOT NULL,
    Role                            nvarchar(16)     NOT NULL,
    SortOrder                       int              NOT NULL CONSTRAINT DF_Station_So DEFAULT 0,
    IncludeTypeIds                  nvarchar(max)    NULL,
    ExcludeItemIds                  nvarchar(max)    NULL,
    IncludeItemIds                  nvarchar(max)    NULL,
    IsEnabled                       bit              NOT NULL CONSTRAINT DF_Station_En DEFAULT 1,
    EnableVoice                     bit              NOT NULL CONSTRAINT DF_Station_Ev DEFAULT 1,
    CreatedAt                       datetimeoffset   NOT NULL,
    CreatedBy                       nvarchar(64)     NULL,
    UpdatedAt                       datetimeoffset   NOT NULL,
    UpdatedBy                       nvarchar(64)     NULL,
    IsDeleted                       bit              NOT NULL CONSTRAINT DF_Station_Del DEFAULT 0
);
CREATE UNIQUE INDEX UX_Station_Code ON Station (StoreId, StationCode);
CREATE INDEX IX_Station_Role ON Station (StoreId, Role, SortOrder);

-- §9.11 品项自定义工序流程
CREATE TABLE Workflow (
    Uid                             uniqueidentifier NOT NULL CONSTRAINT PK_Workflow PRIMARY KEY,
    StoreId                         uniqueidentifier NOT NULL,
    Scope                           nvarchar(16)     NOT NULL CONSTRAINT DF_Workflow_Scope DEFAULT N'Item',
    ScopeId                         uniqueidentifier NOT NULL,
    StagePath                       nvarchar(50)     NOT NULL CONSTRAINT DF_Workflow_Sp DEFAULT N'Prep,Cook,Expo',
    StageStandardSeconds            nvarchar(max)    NULL,
    IsEnabled                       bit              NOT NULL CONSTRAINT DF_Workflow_En DEFAULT 1,
    CreatedAt                       datetimeoffset   NOT NULL,
    CreatedBy                       nvarchar(64)     NULL,
    UpdatedAt                       datetimeoffset   NOT NULL,
    UpdatedBy                       nvarchar(64)     NULL,
    IsDeleted                       bit              NOT NULL CONSTRAINT DF_Workflow_Del DEFAULT 0
);
CREATE UNIQUE INDEX UX_Workflow_Scope ON Workflow (StoreId, Scope, ScopeId);

-- §9.15 终端语言包覆盖（可选）
CREATE TABLE ScreenLangPack (
    Uid                             uniqueidentifier NOT NULL CONSTRAINT PK_ScreenLangPack PRIMARY KEY,
    StoreId                         uniqueidentifier NOT NULL,
    TerminalId                      uniqueidentifier NULL,
    Lang                            nvarchar(16)     NOT NULL,
    PackJson                        nvarchar(max)    NOT NULL,
    Version                         int              NOT NULL CONSTRAINT DF_ScreenLangPack_V DEFAULT 1,
    UpdatedAt                       datetimeoffset   NOT NULL
);
CREATE UNIQUE INDEX UX_ScreenLangPack ON ScreenLangPack (StoreId, TerminalId, Lang);

-- §9.15a 语音播报模板
CREATE TABLE VoiceTemplate (
    Uid                             uniqueidentifier NOT NULL CONSTRAINT PK_VoiceTemplate PRIMARY KEY,
    StoreId                         uniqueidentifier NOT NULL,
    TemplateKind                    nvarchar(32)     NOT NULL,
    Lang                            nvarchar(16)     NOT NULL CONSTRAINT DF_VoiceTemplate_Lang DEFAULT N'zh-CN',
    Body                            nvarchar(500)    NOT NULL,
    Variables                       nvarchar(200)    NULL,
    Version                         int              NOT NULL CONSTRAINT DF_VoiceTemplate_V DEFAULT 1,
    IsEnabled                       bit              NOT NULL CONSTRAINT DF_VoiceTemplate_En DEFAULT 1,
    CreatedAt                       datetimeoffset   NOT NULL,
    UpdatedAt                       datetimeoffset   NOT NULL,
    UpdatedBy                       nvarchar(64)     NULL
);
CREATE UNIQUE INDEX UX_VoiceTemplate ON VoiceTemplate (StoreId, TemplateKind, Lang);

-- §9.17 打印机配置
CREATE TABLE PrinterConfig (
    Uid                             uniqueidentifier NOT NULL CONSTRAINT PK_PrinterConfig PRIMARY KEY,
    StoreId                         uniqueidentifier NOT NULL,
    PrinterName                     nvarchar(200)    NOT NULL,
    Model                           nvarchar(100)    NULL,
    ConnectionType                  nvarchar(16)     NOT NULL CONSTRAINT DF_PrinterConfig_Ct DEFAULT N'Network',
    PrinterHost                     nvarchar(64)     NULL,
    PrinterPort                     int              NULL CONSTRAINT DF_PrinterConfig_Pp DEFAULT 9100,
    ExecutorTerminalId              uniqueidentifier NULL,
    OwnerStationId                  uniqueidentifier NULL,
    PaperWidth                      nvarchar(8)      NOT NULL CONSTRAINT DF_PrinterConfig_Pw DEFAULT N'Mm58',
    Encoding                        nvarchar(32)     NOT NULL CONSTRAINT DF_PrinterConfig_Enc DEFAULT N'GB18030',
    RenderMode                      nvarchar(16)     NOT NULL CONSTRAINT DF_PrinterConfig_Rm DEFAULT N'Image',
    IsEnabled                       bit              NOT NULL CONSTRAINT DF_PrinterConfig_En DEFAULT 1,
    LastSeenAt                      datetimeoffset   NULL,
    CreatedAt                       datetimeoffset   NOT NULL,
    CreatedBy                       nvarchar(64)     NULL,
    UpdatedAt                       datetimeoffset   NOT NULL,
    UpdatedBy                       nvarchar(64)     NULL,
    IsDeleted                       bit              NOT NULL CONSTRAINT DF_PrinterConfig_Del DEFAULT 0
);
CREATE INDEX IX_PrinterConfig_Station ON PrinterConfig (StoreId, OwnerStationId);
CREATE INDEX IX_PrinterConfig_Executor ON PrinterConfig (ExecutorTerminalId);

-- §9.19 打印模板
CREATE TABLE PrintTemplate (
    Uid                             uniqueidentifier NOT NULL CONSTRAINT PK_PrintTemplate PRIMARY KEY,
    StoreId                         uniqueidentifier NOT NULL,
    TemplateName                    nvarchar(200)    NOT NULL,
    TemplateKind                    nvarchar(32)     NOT NULL CONSTRAINT DF_PrintTemplate_Tk DEFAULT N'ItemSlip',
    TasteLayout                     nvarchar(16)     NOT NULL CONSTRAINT DF_PrintTemplate_Tl DEFAULT N'OwnLine',
    Lang                            nvarchar(16)     NOT NULL CONSTRAINT DF_PrintTemplate_Lang DEFAULT N'zh-CN',
    BodyHtml                        nvarchar(max)    NOT NULL,
    Variables                       nvarchar(max)    NULL,
    Version                         int              NOT NULL CONSTRAINT DF_PrintTemplate_V DEFAULT 1,
    IsDefault                       bit              NOT NULL CONSTRAINT DF_PrintTemplate_Def DEFAULT 0,
    CreatedAt                       datetimeoffset   NOT NULL,
    CreatedBy                       nvarchar(64)     NULL,
    UpdatedAt                       datetimeoffset   NOT NULL,
    UpdatedBy                       nvarchar(64)     NULL,
    IsDeleted                       bit              NOT NULL CONSTRAINT DF_PrintTemplate_Del DEFAULT 0
);
CREATE INDEX IX_PrintTemplate_Kind ON PrintTemplate (StoreId, TemplateKind, Lang);

-- §9.21 屏内分区（V1.1 预留）
-- TerminalPane：V1.1 功能预留表。V1 照建（结构即终态，避免后续迁移），但不开放配置入口，
-- 运行时 TerminalConfig.PaneLayout 恒为 Single，本表 V1 业务行数恒为 0（§9.21）
CREATE TABLE TerminalPane (
    Uid                             uniqueidentifier NOT NULL CONSTRAINT PK_TerminalPane PRIMARY KEY,
    TerminalId                      uniqueidentifier NOT NULL,
    PaneIndex                       int              NOT NULL,
    StationIds                      nvarchar(max)    NOT NULL,
    PaneTitle                       nvarchar(64)     NULL,
    SortMode                        nvarchar(32)     NOT NULL CONSTRAINT DF_TerminalPane_Sm DEFAULT N'WaitDuration',
    WidthWeight                     decimal(5,2)     NOT NULL CONSTRAINT DF_TerminalPane_Ww DEFAULT 1.00,
    DefaultFilter                   nvarchar(max)    NULL,
    CreatedAt                       datetimeoffset   NOT NULL,
    UpdatedAt                       datetimeoffset   NOT NULL,
    IsDeleted                       bit              NOT NULL CONSTRAINT DF_TerminalPane_Del DEFAULT 0
);
CREATE UNIQUE INDEX UX_TerminalPane_Index ON TerminalPane (TerminalId, PaneIndex);

-- ============================================================================
-- 二、订单类
-- ============================================================================

-- §9.3 订单主表（主键命名例外：OrderId）
CREATE TABLE OrderHeader (
    OrderId                         uniqueidentifier NOT NULL CONSTRAINT PK_OrderHeader PRIMARY KEY,
    StoreId                         uniqueidentifier NOT NULL,
    PosOrderNo                      nvarchar(64)     NOT NULL,
    OrderType                       nvarchar(16)     NOT NULL CONSTRAINT DF_OrderHeader_Ot DEFAULT N'DineIn',
    GuestCount                      int              NULL,
    TableUids                       nvarchar(max)    NULL,
    PosSource                       nvarchar(64)     NULL,        -- POS 来源标识
    IsSharedTable                   bit              NOT NULL CONSTRAINT DF_OrderHeader_Ist DEFAULT 0,
    IsHeld                          bit              NOT NULL CONSTRAINT DF_OrderHeader_Ih DEFAULT 0,
    OrderCreateTime                 datetimeoffset   NOT NULL,
    ReceivedAt                      datetimeoffset   NOT NULL,
    CompletedAt                     datetimeoffset   NULL,
    BusinessDate                    date             NOT NULL,
    MealPeriod                      nvarchar(16)     NULL,
    Remark                          nvarchar(max)    NULL,
    OrderStatus                     nvarchar(32)     NOT NULL CONSTRAINT DF_OrderHeader_Os DEFAULT N'Normal',   -- Normal / PartlyCancelled / AllCancelled / Archived
    Version                         int              NOT NULL CONSTRAINT DF_OrderHeader_V DEFAULT 0,
    HqUploadedAt                    datetimeoffset   NULL,
    CreatedAt                       datetimeoffset   NOT NULL,
    CreatedBy                       nvarchar(64)     NULL,
    UpdatedAt                       datetimeoffset   NOT NULL,
    UpdatedBy                       nvarchar(64)     NULL,
    IsDeleted                       bit              NOT NULL CONSTRAINT DF_OrderHeader_Del DEFAULT 0
);
CREATE UNIQUE INDEX UX_OrderHeader_Store_PosNo ON OrderHeader (StoreId, PosOrderNo);
CREATE INDEX IX_OrderHeader_BusinessDate ON OrderHeader (BusinessDate);
CREATE INDEX IX_OrderHeader_HqPending ON OrderHeader (HqUploadedAt) WHERE HqUploadedAt IS NULL;

-- §9.4 订单明细（主键命名例外：DetailId）
CREATE TABLE OrderDetail (
    DetailId                        uniqueidentifier NOT NULL CONSTRAINT PK_OrderDetail PRIMARY KEY,
    OrderId                         uniqueidentifier NOT NULL CONSTRAINT FK_OrderDetail_Order REFERENCES OrderHeader (OrderId),
    TableId                         uniqueidentifier NOT NULL,
    LineNo                          int              NOT NULL,
    DishItemId                      uniqueidentifier NULL,
    DishName                        nvarchar(200)    NOT NULL,
    Spec                            nvarchar(100)    NULL,
    Taste                           nvarchar(200)    NULL,
    Method                          nvarchar(200)    NULL,
    Qty                             decimal(18,3)    NOT NULL CONSTRAINT DF_OrderDetail_Qty DEFAULT 1,
    CompletedQty                    decimal(18,3)    NOT NULL CONSTRAINT DF_OrderDetail_Cq DEFAULT 0,
    CancelledQty                    decimal(18,3)    NOT NULL CONSTRAINT DF_OrderDetail_Ccq DEFAULT 0,
    QtyStepSnapshot                 decimal(18,3)    NOT NULL CONSTRAINT DF_OrderDetail_Qss DEFAULT 1,
    Unit                            nvarchar(16)     NOT NULL CONSTRAINT DF_OrderDetail_Unit DEFAULT N'份',
    TableNo                         nvarchar(64)     NULL,
    TableSortOrder                  int              NULL,
    IsGift                          bit              NOT NULL CONSTRAINT DF_OrderDetail_Ig DEFAULT 0,
    IsCancel                        bit              NOT NULL CONSTRAINT DF_OrderDetail_Ic DEFAULT 0,
    IsRush                          bit              NOT NULL CONSTRAINT DF_OrderDetail_Ir DEFAULT 0,
    IsRemind                        bit              NOT NULL CONSTRAINT DF_OrderDetail_Irem DEFAULT 0,
    IsHold                          bit              NOT NULL CONSTRAINT DF_OrderDetail_Iho DEFAULT 0,
    IsFire                          bit              NOT NULL CONSTRAINT DF_OrderDetail_If DEFAULT 0,
    SpecialFlags                    nvarchar(max)    NULL,
    IsComboItem                     bit              NOT NULL CONSTRAINT DF_OrderDetail_Ici DEFAULT 0,
    ComboNo                         nvarchar(64)     NULL,
    ComboName                       nvarchar(200)    NULL,
    ComboSeq                        int              NULL,
    ComboItemTotal                  int              NULL,
    WaiterName                      nvarchar(64)     NULL,
    UnitPrice                       decimal(18,4)    NULL,
    Amount                          decimal(18,4)    NULL,
    RemindCount                     int              NOT NULL CONSTRAINT DF_OrderDetail_Rc DEFAULT 0,
    RemindAt                        datetimeoffset   NULL,
    RemindBy                        nvarchar(64)     NULL,
    CancelAt                        datetimeoffset   NULL,
    CancelBy                        nvarchar(64)     NULL,
    CancelReason                    nvarchar(200)    NULL,
    VoidQty                         decimal(18,3)    NOT NULL CONSTRAINT DF_OrderDetail_Vq DEFAULT 0,
    VoidReasonCode                  int              NULL,
    VoidRemark                      nvarchar(200)    NULL,
    VoidAt                          datetimeoffset   NULL,
    VoidBy                          nvarchar(64)     NULL,
    WorkflowStage                   nvarchar(16)     NOT NULL CONSTRAINT DF_OrderDetail_Ws DEFAULT N'Pending',
    StageStatus                     nvarchar(16)     NOT NULL CONSTRAINT DF_OrderDetail_Ss DEFAULT N'Waiting',
    StagePathSnapshot               nvarchar(50)     NOT NULL CONSTRAINT DF_OrderDetail_Sps DEFAULT N'Prep,Cook,Expo',
    StageStandardSeconds            nvarchar(max)    NULL,
    StageBeginTime                  datetimeoffset   NULL,
    StageCompleteTime               datetimeoffset   NULL,
    StageElapsedSeconds             int              NULL,
    StatusUpdatedAt                 datetimeoffset   NOT NULL,
    CurrentStationId                uniqueidentifier NULL,
    SkippedStages                   nvarchar(50)     NULL,
    NotifyState                     int              NOT NULL CONSTRAINT DF_OrderDetail_Ns DEFAULT 0,
    NotifyFlags                     int              NOT NULL CONSTRAINT DF_OrderDetail_Nf DEFAULT 0,
    FirstFireAt                     datetimeoffset   NULL,
    LastFireAt                      datetimeoffset   NULL,
    HoldCount                       int              NOT NULL CONSTRAINT DF_OrderDetail_Hc DEFAULT 0,
    HoldAccumSeconds                int              NOT NULL CONSTRAINT DF_OrderDetail_Has DEFAULT 0,
    TotalWaitBeginTime              datetimeoffset   NOT NULL,
    TotalTimeoutSeconds             int              NOT NULL,
    ProducedAt                      datetimeoffset   NULL,
    ProducedSeconds                 int              NULL,
    IsTimeout                       bit              NOT NULL CONSTRAINT DF_OrderDetail_Ito DEFAULT 0,
    TimeoutSeconds                  int              NULL,
    BusinessDate                    date             NOT NULL,
    MealPeriod                      nvarchar(16)     NULL,
    IsCrossDay                      bit              NOT NULL CONSTRAINT DF_OrderDetail_Icd DEFAULT 0,
    CrossDayDays                    int              NOT NULL CONSTRAINT DF_OrderDetail_Cdd DEFAULT 0,
    ClosedAt                        datetimeoffset   NULL,
    ClosedReason                    nvarchar(200)    NULL,
    Version                         int              NOT NULL CONSTRAINT DF_OrderDetail_V DEFAULT 0,
    CreatedAt                       datetimeoffset   NOT NULL,
    CreatedBy                       nvarchar(64)     NULL,
    UpdatedAt                       datetimeoffset   NOT NULL,
    UpdatedBy                       nvarchar(64)     NULL,
    IsDeleted                       bit              NOT NULL CONSTRAINT DF_OrderDetail_Del DEFAULT 0
);
CREATE UNIQUE INDEX UX_OrderDetail_LineNo ON OrderDetail (OrderId, LineNo);
CREATE INDEX IX_OrderDetail_Stage ON OrderDetail (WorkflowStage, StageStatus);
CREATE INDEX IX_OrderDetail_Station ON OrderDetail (CurrentStationId, WorkflowStage);
CREATE INDEX IX_OrderDetail_Table ON OrderDetail (TableId);
CREATE INDEX IX_OrderDetail_Combo ON OrderDetail (OrderId, ComboNo);
CREATE INDEX IX_OrderDetail_Biz ON OrderDetail (BusinessDate);
CREATE INDEX IX_OrderDetail_Biz_Cancel ON OrderDetail (BusinessDate, CancelAt);
CREATE INDEX IX_OrderDetail_Biz_Remind ON OrderDetail (BusinessDate, RemindAt);
CREATE INDEX IX_OrderDetail_Biz_Timeout ON OrderDetail (BusinessDate, TimeoutSeconds);
CREATE INDEX IX_OrderDetail_Biz_Void ON OrderDetail (BusinessDate, VoidAt);
CREATE INDEX IX_OrderDetail_Biz_Item ON OrderDetail (BusinessDate, DishItemId);
CREATE INDEX IX_OrderDetail_Biz_Waiter ON OrderDetail (BusinessDate, WaiterName);
CREATE INDEX IX_OrderDetail_CrossDay ON OrderDetail (IsCrossDay, BusinessDate);

-- §9.8 订单-桌台关联
CREATE TABLE OrderTableRel (
    Uid                             uniqueidentifier NOT NULL CONSTRAINT PK_OrderTableRel PRIMARY KEY,
    OrderId                         uniqueidentifier NOT NULL CONSTRAINT FK_OrderTableRel_Order REFERENCES OrderHeader (OrderId),
    TableId                         uniqueidentifier NOT NULL,
    TableCodeSnapshot               nvarchar(64)     NULL,
    SortOrderSnapshot               int              NULL,
    AreaNameSnapshot                nvarchar(200)    NULL,
    Status                          nvarchar(16)     NOT NULL CONSTRAINT DF_OrderTableRel_St DEFAULT N'Active',
    CreatedAt                       datetimeoffset   NOT NULL,
    CreatedBy                       nvarchar(64)     NULL,
    UpdatedAt                       datetimeoffset   NOT NULL,
    UpdatedBy                       nvarchar(64)     NULL,
    IsDeleted                       bit              NOT NULL CONSTRAINT DF_OrderTableRel_Del DEFAULT 0
);
CREATE UNIQUE INDEX UX_OrderTableRel_Order_Table ON OrderTableRel (OrderId, TableId);
CREATE INDEX IX_OrderTableRel_Table ON OrderTableRel (TableId, Status);
CREATE INDEX IX_OrderTableRel_Order ON OrderTableRel (OrderId);

-- §9.21a 明细阶段时间线
CREATE TABLE OrderDetailStageLog (
    Uid                             uniqueidentifier NOT NULL CONSTRAINT PK_OrderDetailStageLog PRIMARY KEY,
    DetailId                        uniqueidentifier NOT NULL CONSTRAINT FK_StageLog_Detail REFERENCES OrderDetail (DetailId),
    OrderId                         uniqueidentifier NOT NULL,
    BusinessDate                    date             NOT NULL,
    Stage                           nvarchar(16)     NOT NULL,
    EnterAt                         datetimeoffset   NOT NULL,
    ExitAt                          datetimeoffset   NULL,
    ElapsedSeconds                  int              NULL,
    WaitSeconds                     int              NULL,
    StationId                       uniqueidentifier NULL,
    OperatorName                    nvarchar(64)     NULL,
    EnterSource                     nvarchar(16)     NOT NULL CONSTRAINT DF_StageLog_Es DEFAULT N'Auto',
    ExitReason                      nvarchar(16)     NULL,
    IsReverted                      bit              NOT NULL CONSTRAINT DF_StageLog_Ir DEFAULT 0,
    CreatedAt                       datetimeoffset   NOT NULL
);
CREATE UNIQUE INDEX UX_StageLog_Detail_Stage ON OrderDetailStageLog (DetailId, Stage);
CREATE INDEX IX_StageLog_Biz_Stage ON OrderDetailStageLog (BusinessDate, Stage);
CREATE INDEX IX_StageLog_Station ON OrderDetailStageLog (BusinessDate, StationId, Stage);

-- ============================================================================
-- 三、日志与队列类
-- ============================================================================

-- §9.12 操作日志
CREATE TABLE OperationLog (
    Uid                             uniqueidentifier NOT NULL CONSTRAINT PK_OperationLog PRIMARY KEY,
    StoreId                         uniqueidentifier NOT NULL,
    TerminalId                      uniqueidentifier NULL,
    OperatorName                    nvarchar(64)     NULL,
    Action                          nvarchar(32)     NOT NULL,
    OrderId                         uniqueidentifier NULL,
    DetailId                        uniqueidentifier NULL,
    Stage                           nvarchar(16)     NULL,
    FromStage                       nvarchar(16)     NULL,
    ToStage                         nvarchar(16)     NULL,
    FromStatus                      nvarchar(16)     NULL,
    ToStatus                        nvarchar(16)     NULL,
    Qty                             decimal(18,3)    NULL,
    VersionAt                       int              NULL,
    IsUndoable                      bit              NOT NULL CONSTRAINT DF_OperationLog_Iu DEFAULT 0,
    RevertedAt                      datetimeoffset   NULL,
    RevertedBy                      nvarchar(64)     NULL,
    ClientEventId                   uniqueidentifier NULL,
    BeforeState                     nvarchar(200)    NULL,
    AfterState                      nvarchar(200)    NULL,
    Result                          nvarchar(16)     NOT NULL CONSTRAINT DF_OperationLog_Res DEFAULT N'Success',
    Remark                          nvarchar(max)    NULL,
    BusinessDate                    date             NULL,
    OccurredAt                      datetimeoffset   NOT NULL,
    CreatedAt                       datetimeoffset   NOT NULL
);
CREATE INDEX IX_OperationLog_Order ON OperationLog (OrderId, CreatedAt);
CREATE INDEX IX_OperationLog_Terminal ON OperationLog (TerminalId, CreatedAt);
CREATE INDEX IX_OperationLog_Biz ON OperationLog (TerminalId, BusinessDate, CreatedAt);
CREATE INDEX IX_OperationLog_Undo ON OperationLog (TerminalId, BusinessDate, IsUndoable, RevertedAt);
CREATE UNIQUE INDEX UX_OperationLog_ClientEventId ON OperationLog (ClientEventId) WHERE ClientEventId IS NOT NULL;

-- §9.13 原始事件日志
CREATE TABLE EventLog (
    Uid                             uniqueidentifier NOT NULL CONSTRAINT PK_EventLog PRIMARY KEY,
    StoreId                         uniqueidentifier NOT NULL,
    EventId                         uniqueidentifier NOT NULL,
    EventType                       nvarchar(64)     NOT NULL,
    PosSource                       nvarchar(64)     NULL,
    Payload                         nvarchar(max)    NOT NULL,
    ProtocolVersion                 nvarchar(16)     NULL,
    SourceTimestamp                 datetimeoffset   NULL,        -- 事件内声明的发生时间（POS 时钟）
    TraceId                         nvarchar(64)     NULL,
    ProcessStatus                   nvarchar(16)     NOT NULL CONSTRAINT DF_EventLog_Ps DEFAULT N'Pending',
    ErrorCode                       nvarchar(64)     NULL,        -- 处理失败错误码（结构化）
    ErrorMessage                    nvarchar(max)    NULL,
    ReceivedAt                      datetimeoffset   NOT NULL,
    ProcessedAt                     datetimeoffset   NULL,
    CreatedAt                       datetimeoffset   NOT NULL
);
CREATE UNIQUE INDEX UX_EventLog_EventId ON EventLog (EventId);
CREATE INDEX IX_EventLog_Type_Time ON EventLog (EventType, ReceivedAt);

-- §9.14 出站回执待发表
CREATE TABLE OutboxMessage (
    Uid                             uniqueidentifier NOT NULL CONSTRAINT PK_OutboxMessage PRIMARY KEY,
    StoreId                         uniqueidentifier NOT NULL,
    TargetKind                      nvarchar(8)      NOT NULL CONSTRAINT DF_Outbox_Tk DEFAULT N'Pos',
    EventType                       nvarchar(64)     NOT NULL,
    Payload                         nvarchar(max)    NOT NULL,
    IdempotencyKey                  nvarchar(128)    NOT NULL,
    Status                          nvarchar(16)     NOT NULL CONSTRAINT DF_Outbox_St DEFAULT N'Pending',
    RetryCount                      int              NOT NULL CONSTRAINT DF_Outbox_Rc DEFAULT 0,
    NextRetryAt                     datetimeoffset   NULL,
    LastError                       nvarchar(max)    NULL,
    CreatedAt                       datetimeoffset   NOT NULL,
    SentAt                          datetimeoffset   NULL
);
CREATE UNIQUE INDEX UX_Outbox_IdempotencyKey ON OutboxMessage (IdempotencyKey);
CREATE INDEX IX_Outbox_Status ON OutboxMessage (Status, NextRetryAt);
CREATE INDEX IX_Outbox_DeadLetter ON OutboxMessage (Status, CreatedAt);

-- §9.18 打印规则
CREATE TABLE PrintRule (
    Uid                             uniqueidentifier NOT NULL CONSTRAINT PK_PrintRule PRIMARY KEY,
    StoreId                         uniqueidentifier NOT NULL,
    StationId                       uniqueidentifier NOT NULL,
    Stage                           nvarchar(16)     NOT NULL,
    Trigger                         nvarchar(32)     NOT NULL CONSTRAINT DF_PrintRule_Trg DEFAULT N'OnStageComplete',
    TemplateId                      uniqueidentifier NULL,
    PrinterId                       uniqueidentifier NULL,
    Copies                          int              NOT NULL CONSTRAINT DF_PrintRule_Cp DEFAULT 1,
    IsEnabled                       bit              NOT NULL CONSTRAINT DF_PrintRule_En DEFAULT 1,
    CreatedAt                       datetimeoffset   NOT NULL,
    CreatedBy                       nvarchar(64)     NULL,
    UpdatedAt                       datetimeoffset   NOT NULL,
    UpdatedBy                       nvarchar(64)     NULL,
    IsDeleted                       bit              NOT NULL CONSTRAINT DF_PrintRule_Del DEFAULT 0
);
CREATE UNIQUE INDEX UX_PrintRule_Station_Stage ON PrintRule (StationId, Stage);

-- §9.20 打印任务
CREATE TABLE PrintJob (
    Uid                             uniqueidentifier NOT NULL CONSTRAINT PK_PrintJob PRIMARY KEY,
    StoreId                         uniqueidentifier NOT NULL,
    DetailId                        uniqueidentifier NULL,
    OrderId                         uniqueidentifier NULL,
    StationId                       uniqueidentifier NULL,
    Stage                           nvarchar(16)     NULL,
    Trigger                         nvarchar(32)     NOT NULL,
    PrinterId                       uniqueidentifier NOT NULL,
    ExecutorTerminalId              uniqueidentifier NULL,
    TemplateId                      uniqueidentifier NULL,
    TemplateVersion                 int              NULL,
    RenderMode                      nvarchar(16)     NOT NULL CONSTRAINT DF_PrintJob_Rm DEFAULT N'Image',
    ContentSnapshot                 nvarchar(max)    NOT NULL,
    PrintIndex                      int              NOT NULL CONSTRAINT DF_PrintJob_Pi DEFAULT 1,
    IdempotencyKey                  nvarchar(160)    NOT NULL,
    Status                          nvarchar(16)     NOT NULL CONSTRAINT DF_PrintJob_St DEFAULT N'Pending',
    Priority                        int              NOT NULL CONSTRAINT DF_PrintJob_Pr DEFAULT 0,
    RetryCount                      int              NOT NULL CONSTRAINT DF_PrintJob_Rc DEFAULT 0,
    LeaseUntil                      datetimeoffset   NULL,
    ErrorMessage                    nvarchar(max)    NULL,
    CompletedAt                     datetimeoffset   NULL,
    CreatedAt                       datetimeoffset   NOT NULL,
    UpdatedAt                       datetimeoffset   NOT NULL
);
CREATE INDEX IX_PrintJob_Queue ON PrintJob (ExecutorTerminalId, Status, Priority DESC, CreatedAt);
CREATE UNIQUE INDEX UX_PrintJob_Idempotency ON PrintJob (IdempotencyKey, PrintIndex);
CREATE INDEX IX_PrintJob_Printer ON PrintJob (PrinterId, Status);
CREATE INDEX IX_PrintJob_Created ON PrintJob (CreatedAt);

-- §9.15b 沽清记录
CREATE TABLE SoldOutLog (
    Uid                             uniqueidentifier NOT NULL CONSTRAINT PK_SoldOutLog PRIMARY KEY,
    StoreId                         uniqueidentifier NOT NULL,
    DishItemId                      uniqueidentifier NOT NULL,
    DishTypeId                      uniqueidentifier NULL,
    DishNameSnapshot                nvarchar(200)    NULL,
    SoldOutType                     nvarchar(16)     NOT NULL CONSTRAINT DF_SoldOut_Type DEFAULT N'UntilManual',
    LimitQty                        decimal(18,3)    NULL,
    SoldQty                         decimal(18,3)    NOT NULL CONSTRAINT DF_SoldOut_Sq DEFAULT 0,
    ReasonCode                      int              NOT NULL CONSTRAINT DF_SoldOut_Rc DEFAULT 0,
    Remark                          nvarchar(200)    NULL,
    StartAt                         datetimeoffset   NOT NULL,
    EndAt                           datetimeoffset   NULL,
    EndReason                       nvarchar(16)     NULL,
    Status                          nvarchar(16)     NOT NULL CONSTRAINT DF_SoldOut_St DEFAULT N'Requested',
    RequestedBy                     nvarchar(64)     NULL,
    RequestedFrom                   nvarchar(8)      NOT NULL CONSTRAINT DF_SoldOut_Rf DEFAULT N'Kds',
    ApprovedBy                      nvarchar(64)     NULL,
    ApprovedAt                      datetimeoffset   NULL,
    BusinessDate                    date             NOT NULL,
    CreatedAt                       datetimeoffset   NOT NULL,
    UpdatedAt                       datetimeoffset   NOT NULL,
    IsDeleted                       bit              NOT NULL CONSTRAINT DF_SoldOut_Del DEFAULT 0
);
CREATE INDEX IX_SoldOutLog_Item_Active ON SoldOutLog (StoreId, DishItemId, Status);
CREATE INDEX IX_SoldOutLog_Biz ON SoldOutLog (StoreId, BusinessDate);
CREATE INDEX IX_SoldOutLog_Status_End ON SoldOutLog (Status, EndAt);

-- §9.15c 叫号记录
CREATE TABLE CallLog (
    Uid                             uniqueidentifier NOT NULL CONSTRAINT PK_CallLog PRIMARY KEY,
    StoreId                         uniqueidentifier NOT NULL,
    OrderId                         uniqueidentifier NULL,
    TableId                         uniqueidentifier NULL,
    TableCodeSnapshot               nvarchar(64)     NULL,
    TerminalId                      uniqueidentifier NULL,
    OperatorName                    nvarchar(64)     NULL,
    TriggerSource                   nvarchar(16)     NOT NULL CONSTRAINT DF_CallLog_Ts DEFAULT N'Manual',
    RenderedText                    nvarchar(500)    NULL,
    TemplateKind                    nvarchar(32)     NULL,
    Lang                            nvarchar(16)     NULL,
    TtsProvider                     nvarchar(32)     NULL,
    SpeakResult                     nvarchar(16)     NOT NULL CONSTRAINT DF_CallLog_Sr DEFAULT N'Skipped',
    ErrorMessage                    nvarchar(200)    NULL,
    BusinessDate                    date             NOT NULL,
    CreatedAt                       datetimeoffset   NOT NULL
);
CREATE INDEX IX_CallLog_Cooldown ON CallLog (StoreId, TableId, CreatedAt);
CREATE INDEX IX_CallLog_Biz ON CallLog (StoreId, BusinessDate);

-- §9.15d 账号（管理端登录账号 + 作业屏人员名单，一张表两类）
CREATE TABLE UserAccount (
    Uid                             uniqueidentifier NOT NULL CONSTRAINT PK_UserAccount PRIMARY KEY,
    StoreId                         uniqueidentifier NOT NULL,
    UserName                        nvarchar(64)     NOT NULL,
    DisplayName                     nvarchar(64)     NOT NULL,
    AccountType                     nvarchar(16)     NOT NULL CONSTRAINT DF_UserAccount_Type DEFAULT N'Admin',
    Role                            nvarchar(16)     NULL,
    PasswordHash                    nvarchar(256)    NULL,
    PasswordSalt                    nvarchar(64)     NULL,
    PasswordIterations              int              NULL,
    MustChangePassword              bit              NOT NULL CONSTRAINT DF_UserAccount_Mcp DEFAULT 0,
    PasswordUpdatedAt               datetimeoffset   NULL,
    IsEnabled                       bit              NOT NULL CONSTRAINT DF_UserAccount_En DEFAULT 1,
    IsRosterVisible                 bit              NOT NULL CONSTRAINT DF_UserAccount_Irv DEFAULT 1,
    Phone                           nvarchar(32)     NULL,
    FailedLoginCount                int              NOT NULL CONSTRAINT DF_UserAccount_Ffc DEFAULT 0,
    LockedUntil                     datetimeoffset   NULL,
    LastLoginAt                     datetimeoffset   NULL,
    Remark                          nvarchar(200)    NULL,
    Position                        nvarchar(32)     NULL,
    Source                          nvarchar(8)      NOT NULL CONSTRAINT DF_UserAccount_Src DEFAULT N'Local',
    ExternalId                      nvarchar(64)     NULL,
    SyncedAt                        datetimeoffset   NULL,
    RoleOverriddenByAdmin           bit              NOT NULL CONSTRAINT DF_UserAccount_Roba DEFAULT 0,
    CreatedAt                       datetimeoffset   NOT NULL,
    CreatedBy                       nvarchar(64)     NULL,
    UpdatedAt                       datetimeoffset   NOT NULL,
    UpdatedBy                       nvarchar(64)     NULL,
    IsDeleted                       bit              NOT NULL CONSTRAINT DF_UserAccount_Del DEFAULT 0
);
CREATE UNIQUE INDEX UX_UserAccount_Name ON UserAccount (StoreId, UserName);
CREATE INDEX IX_UserAccount_Type ON UserAccount (StoreId, AccountType, IsEnabled);
CREATE INDEX IX_UserAccount_Role ON UserAccount (StoreId, Role);
CREATE UNIQUE INDEX UX_UserAccount_External ON UserAccount (StoreId, ExternalId) WHERE ExternalId IS NOT NULL;

-- §9.15e 登录日志（只追加，保留 180 天）
CREATE TABLE LoginLog (
    Uid                             uniqueidentifier NOT NULL CONSTRAINT PK_LoginLog PRIMARY KEY,
    StoreId                         uniqueidentifier NOT NULL,
    UserName                        nvarchar(64)     NOT NULL,
    UserId                          uniqueidentifier NULL,
    Success                         bit              NOT NULL,
    FailReason                      nvarchar(32)     NULL,
    IpAddress                       nvarchar(45)     NULL,
    UserAgent                       nvarchar(300)    NULL,
    SessionId                       nvarchar(64)     NULL,
    OccurredAt                      datetimeoffset   NOT NULL
);
CREATE INDEX IX_LoginLog_User_Time ON LoginLog (StoreId, UserName, OccurredAt);
CREATE INDEX IX_LoginLog_Fail ON LoginLog (StoreId, Success, OccurredAt);

-- §9.15f 会话（屏无感登录令牌哈希 + 终端绑定）
CREATE TABLE UserSession (
    Uid                             uniqueidentifier NOT NULL CONSTRAINT PK_UserSession PRIMARY KEY,
    StoreId                         uniqueidentifier NOT NULL,
    UserId                          uniqueidentifier NOT NULL CONSTRAINT FK_UserSession_User REFERENCES UserAccount (Uid),
    TokenHash                       nvarchar(64)     NOT NULL,
    SessionType                     nvarchar(16)     NOT NULL CONSTRAINT DF_UserSession_Type DEFAULT N'Admin',
    TerminalId                      uniqueidentifier NULL,
    DeviceKey                       nvarchar(200)    NULL,
    ExpiresAt                       datetimeoffset   NULL,
    LastSeenAt                      datetimeoffset   NOT NULL,
    RevokedAt                       datetimeoffset   NULL,
    RevokedReason                   nvarchar(32)     NULL,
    RotationCount                   int              NOT NULL CONSTRAINT DF_UserSession_Rc DEFAULT 0,
    IpAddress                       nvarchar(45)     NULL,
    UserAgent                       nvarchar(300)    NULL,
    CreatedAt                       datetimeoffset   NOT NULL
);
CREATE UNIQUE INDEX UX_UserSession_TokenHash ON UserSession (TokenHash);
CREATE INDEX IX_UserSession_User ON UserSession (UserId, RevokedAt);
CREATE INDEX IX_UserSession_Terminal ON UserSession (TerminalId, RevokedAt);

-- ============================================================================
-- 四、统计与归档类
-- ============================================================================

-- §9.22 门店日统计（L3，永久保留）
CREATE TABLE DailyStoreStat (
    Uid                             uniqueidentifier NOT NULL CONSTRAINT PK_DailyStoreStat PRIMARY KEY,
    StoreId                         uniqueidentifier NOT NULL,
    StatDate                        date             NOT NULL,
    OrderCount                      int              NOT NULL CONSTRAINT DF_Dss_Oc DEFAULT 0,
    DetailCount                     int              NOT NULL CONSTRAINT DF_Dss_Dc DEFAULT 0,
    TotalQty                        decimal(18,3)    NOT NULL CONSTRAINT DF_Dss_Tq DEFAULT 0,
    OutputQty                       decimal(18,3)    NOT NULL CONSTRAINT DF_Dss_Oq DEFAULT 0,
    CancelledCount                  int              NOT NULL CONSTRAINT DF_Dss_Cc DEFAULT 0,
    CancelledQty                    decimal(18,3)    NOT NULL CONSTRAINT DF_Dss_Cq DEFAULT 0,
    CancelledAmount                 decimal(18,4)    NOT NULL CONSTRAINT DF_Dss_Ca DEFAULT 0,
    RemindCount                     int              NOT NULL CONSTRAINT DF_Dss_Rc DEFAULT 0,
    RemindQty                       decimal(18,3)    NOT NULL CONSTRAINT DF_Dss_Rq DEFAULT 0,
    GiftCount                       int              NOT NULL CONSTRAINT DF_Dss_Gc DEFAULT 0,
    GuestCount                      int              NOT NULL CONSTRAINT DF_Dss_Gu DEFAULT 0,
    TableCount                      int              NOT NULL CONSTRAINT DF_Dss_Tc DEFAULT 0,
    AvgElapsedSeconds               int              NOT NULL CONSTRAINT DF_Dss_Aes DEFAULT 0,
    SumElapsedSeconds               bigint           NOT NULL CONSTRAINT DF_Dss_Ses DEFAULT 0,
    ElapsedCount                    int              NOT NULL CONSTRAINT DF_Dss_Ec DEFAULT 0,
    P50ElapsedSeconds               int              NULL,
    P90ElapsedSeconds               int              NULL,
    MaxElapsedSeconds               int              NULL,
    ElapsedBuckets                  nvarchar(max)    NULL,
    TimeoutCount                    int              NOT NULL CONSTRAINT DF_Dss_Toc DEFAULT 0,
    TimeoutQty                      decimal(18,3)    NOT NULL CONSTRAINT DF_Dss_Toq DEFAULT 0,
    TimeoutRate                     decimal(5,4)     NOT NULL CONSTRAINT DF_Dss_Tor DEFAULT 0,
    SumWaitBeforeBumpSeconds        bigint           NULL,
    SkipDoneCount                   int              NOT NULL CONSTRAINT DF_Dss_Sdc DEFAULT 0,
    VoidCount                       int              NOT NULL CONSTRAINT DF_Dss_Vc DEFAULT 0,
    VoidQty                         decimal(18,3)    NOT NULL CONSTRAINT DF_Dss_Vq DEFAULT 0,
    VoidAmount                      decimal(18,4)    NOT NULL CONSTRAINT DF_Dss_Va DEFAULT 0,
    UndoCount                       int              NOT NULL CONSTRAINT DF_Dss_Uc DEFAULT 0,
    UndoRate                        decimal(5,4)     NOT NULL CONSTRAINT DF_Dss_Ur DEFAULT 0,
    CrossDayOpenCount               int              NOT NULL CONSTRAINT DF_Dss_Cdoc DEFAULT 0,
    CrossDayClosedCount             int              NOT NULL CONSTRAINT DF_Dss_Cdcc DEFAULT 0,
    HqUploadedAt                    datetimeoffset   NULL,
    CreatedAt                       datetimeoffset   NOT NULL,
    CalcVersion                     int              NOT NULL CONSTRAINT DF_Dss_Cv DEFAULT 1
);
CREATE UNIQUE INDEX UX_DailyStoreStat_Date ON DailyStoreStat (StoreId, StatDate);

-- §9.23 维度日统计
CREATE TABLE DailyDimStat (
    Uid                             uniqueidentifier NOT NULL CONSTRAINT PK_DailyDimStat PRIMARY KEY,
    StoreId                         uniqueidentifier NOT NULL,
    StatDate                        date             NOT NULL,
    Dimension                       nvarchar(32)     NOT NULL,
    DimKey                          nvarchar(120)    NOT NULL,
    DimNameSnapshot                 nvarchar(200)    NULL,
    OrderCount                      int              NOT NULL CONSTRAINT DF_Dds_Oc DEFAULT 0,
    DetailCount                     int              NOT NULL CONSTRAINT DF_Dds_Dc DEFAULT 0,
    TotalQty                        decimal(18,3)    NOT NULL CONSTRAINT DF_Dds_Tq DEFAULT 0,
    OutputQty                       decimal(18,3)    NOT NULL CONSTRAINT DF_Dds_Oq DEFAULT 0,
    CancelledQty                    decimal(18,3)    NOT NULL CONSTRAINT DF_Dds_Cq DEFAULT 0,
    CancelledAmount                 decimal(18,4)    NOT NULL CONSTRAINT DF_Dds_Ca DEFAULT 0,
    RemindCount                     int              NOT NULL CONSTRAINT DF_Dds_Rc DEFAULT 0,
    RemindQty                       decimal(18,3)    NOT NULL CONSTRAINT DF_Dds_Rq DEFAULT 0,
    TimeoutQty                      decimal(18,3)    NOT NULL CONSTRAINT DF_Dds_Tq2 DEFAULT 0,
    VoidQty                         decimal(18,3)    NOT NULL CONSTRAINT DF_Dds_Vq DEFAULT 0,
    VoidAmount                      decimal(18,4)    NOT NULL CONSTRAINT DF_Dds_Va DEFAULT 0,
    AvgElapsedSeconds               int              NULL,
    SumElapsedSeconds               bigint           NOT NULL CONSTRAINT DF_Dds_Ses DEFAULT 0,
    ElapsedCount                    int              NOT NULL CONSTRAINT DF_Dds_Ec DEFAULT 0,
    P90ElapsedSeconds               int              NULL,
    TimeoutCount                    int              NOT NULL CONSTRAINT DF_Dds_Toc DEFAULT 0,
    CancelledCount                  int              NOT NULL CONSTRAINT DF_Dds_Cc DEFAULT 0,
    GiftCount                       int              NOT NULL CONSTRAINT DF_Dds_Gc DEFAULT 0,
    HqUploadedAt                    datetimeoffset   NULL,
    CreatedAt                       datetimeoffset   NOT NULL,
    CalcVersion                     int              NOT NULL CONSTRAINT DF_Dds_Cv DEFAULT 1
);
CREATE UNIQUE INDEX UX_DailyDimStat ON DailyDimStat (StoreId, StatDate, Dimension, DimKey);
CREATE INDEX IX_DailyDimStat_Dim ON DailyDimStat (Dimension, DimKey, StatDate);

-- §14.1.5 归档卷登记
CREATE TABLE ArchiveVolume (
    Uid                             uniqueidentifier NOT NULL CONSTRAINT PK_ArchiveVolume PRIMARY KEY,
    StoreId                         uniqueidentifier NOT NULL,
    VolumeMonth                     nvarchar(7)      NOT NULL,
    BusinessDateFrom                date             NULL,
    BusinessDateTo                  date             NULL,
    FileName                        nvarchar(200)    NULL,
    FilePath                        nvarchar(500)    NULL,
    Engine                          nvarchar(16)     NOT NULL CONSTRAINT DF_ArchiveVolume_Eng DEFAULT N'Sqlite',
    RowCount                        int              NULL,
    SizeBytes                       bigint           NULL,
    Checksum                        nvarchar(128)    NULL,
    Status                          nvarchar(16)     NOT NULL CONSTRAINT DF_ArchiveVolume_St DEFAULT N'Writing',
    LastMovedBusinessDate           date             NULL,
    SealedAt                        datetimeoffset   NULL,
    HqUploadedAt                    datetimeoffset   NULL,
    HqRecordCount                   int              NULL,
    DeletedAt                       datetimeoffset   NULL,
    CreatedAt                       datetimeoffset   NOT NULL,
    UpdatedAt                       datetimeoffset   NOT NULL
);
CREATE UNIQUE INDEX UX_ArchiveVolume_Month ON ArchiveVolume (StoreId, VolumeMonth);

-- ============================================================================
-- 说明
-- ============================================================================
-- ① 与 SQLite 版的类型映射（§8.1）：TEXT→uniqueidentifier/nvarchar(max)、
--    INTEGER→bit/int、REAL→decimal(18,3|18,4|5,4|5,2)、ISO 文本→datetimeoffset/date。
-- ② 筛选索引：SQLite 的 `CREATE INDEX ... WHERE col IS NOT NULL` 在 SQL Server 用
--    filtered index（2008+），语法一致，均用于 UX_DiningTable_External / IX_OrderHeader_HqPending /
--    UX_OperationLog_ClientEventId 三处。
-- ③ 分页统一用 `OFFSET n ROWS FETCH NEXT m ROWS ONLY`（SQL Server 2012+）。
-- ④ 事务隔离：默认 READ COMMITTED；乐观锁冲突靠 `WHERE Version = @v` 行数判断，
--    需要时用 `WITH (UPDLOCK)` 防并发写同一行。
-- ⑤ 归档卷（ArchiveVolume.Engine = SqlServer 时）：每营业月一个归档数据库
--    `KdsArchive_YYYY_MM`，同实例内可跨库原子 MOVE（§8.2）。
-- ⑥ 时钟：全部 datetimeoffset，应用层统一换算门店时区，不依赖 DB 时区函数。
-- ⑦ 版本底线：SQL Server 2016+。2000/2005/2008 缺少 datetimeoffset、nvarchar(max)、
--    ROW_NUMBER、筛选索引、EF Core 支持，**不可用**（§8.3）。