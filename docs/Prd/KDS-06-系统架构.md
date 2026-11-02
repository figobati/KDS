# 第五部分：系统架构

## 5. 节点角色与部署形态

| 角色 | 做什么 |
|------|--------|
| **Master** | 持 SQLite + 业务逻辑 + Kestrel + MQTT；本地显示 UI |
| **Worker** | 只跑 UI，连 Master WebSocket；**不碰数据库** |
| **Browser** | Win7 / 安卓浏览器直接访问 Master（BS 终端） |

- 同一时间**只能有一个 Master**（高可用由备份与快速重装承担）；
- 所有状态变更由 Master 统一管理；终端仅做展示与提交操作，**不直接操作数据库**。

**终端形态：**

| 终端 | 技术 | 说明 |
|------|------|------|
| Win10 Master | WPF + WebView2 | Kestrel + SQLite + 本地 UI |
| Win10 Worker | WPF + WebView2 | 连 Master |
| Android / iOS | MAUI 或浏览器 BS | SignalR + 本地缓存（V1 以浏览器为主） |
| Win7 | Edge 109 浏览器 | kiosk 访问 Master |

**MAUI / 移动端性能要点**（若启用）：CollectionView 虚拟化、delta 推送局部更新、全局 DispatcherTimer、MessagePack、本地 SQLite 离线缓存、Android `KeepScreenOn`。

### 5.1 配置归属：**全部在 Master，终端只持只读缓存**

> 一句话：**屏幕配置存在 Master 的 `TerminalConfig` 里，由管理端维护；终端本地不保存任何"配置"，只保存身份和一份只读缓存。**
> 注意区分：**屏幕级**配置允许各屏不同（这是特性）；**门店级**规则（流转开关等）才要求全店一致。

**三类数据，三个落点（不要混）**

| 类别 | 例子 | 权威存放 | 终端是否可改 |
|------|------|----------|--------------|
| **① 屏幕配置** | 角色（`Role`）、绑定档口（`StationIds`）、`BaseGroupMode`、`DefaultView`、`EnableOperate`、`Merge_*` 合并条件、`CurrentLang`、`PageSize`、`EnableVoice`、`DeviceKey` | **Master `TerminalConfig`**（管理端维护） | ❌ 只读 |
| **② 运行时状态** | 当前 Tab（`ActiveView`）、各视图排序（`TableView_SortMode` 等）、展开/收起、滚动位置 | **终端本地**（持久化） | ✅ 可改 |
| **③ 身份凭据** | `TerminalId`、`DeviceKey` | Master 生成并签发；终端**本地保存副本**用于自动登录 | ❌ 不可改（只能重绑） |

**先分清三层语义（很多误解都出在这里）**

| 层 | 是什么 | 例子 | 谁的配置 |
|----|--------|------|----------|
| **门店级** | 全店统一的后厨业务规则 | `EnableWorkflowState`、`FlowMode`、**总超时阈值**（`DefaultTotalTimeoutSeconds` / `WarnRatio`）、营业日、默认语言 | `StoreConfig`（一个门店一份，**必须全店一致**） |
| **屏幕级** | 单块屏的取数与展示方式 | 角色 `Role`、绑定档口、`BaseGroupMode`、`DefaultView`、`EnableOperate`、7 项合并条件、`CurrentLang`、分页 | `TerminalConfig`（**一屏一份，允许各屏不同**） |
| **档口级** | 品项路由的业务分组 | `Station.Role`、反选三字段（`IncludeTypeIds` / `ExcludeItemIds` / `IncludeItemIds`） | `Station`（**逻辑路由单位，不是物理位置**） |

> **超时阈值只有两级（门店默认 + 菜品特例）**，见 §4.4.2；**档口不参与超时判定**（`Station.StageTimeoutSeconds` 已于 v6.55 废弃）。

> **档口是路由单位，不是"房间"**：品项靠反选规则落到档口，档口绑定角色与屏幕，屏幕只拉自己该看的品项（§2.1 / §2.2）。
> 因此**同一档口挂两块屏，这两块屏的视图、合并条件、语言完全可以不同**——这是特性，不是不一致。例如：一块用桌台视图、一块用合菜视图；一块中文、一块英文。

**那为什么屏幕级配置还是要放在 Master？**

| 理由 | 说明 |
|------|------|
| **不随硬件走** | 硬件会坏、浏览器会清缓存。配置只存本机 → 换屏 / 重装后"不知道自己是谁、该收哪些菜"，后厨直接停摆 |
| **集中管理** | 20 块屏要配 20 次、改 20 次；存在 Master 才能在管理端一次改完并下发 |
| **远程排障** | 现场说"我这屏不对"，要能远程看到"这块屏的实际配置是什么"，而不是跑到后厨点屏幕 |
| **版本化下发** | 变更必须递增 `ConfigVersion` 并推 `ConfigChanged`，需要一个**唯一权威版本源**；多份本机配置无法协商"谁是最新" |
| **与既有架构一致** | §5 已定：终端不直接操作数据库，所有状态由 Master 统一管理 |

> ⚠️ **不要用"多屏一致"当理由**：屏幕级配置本来就允许各屏不同。真正要求一致的只有**门店级**规则（`StoreConfig`），那部分才是"全店一套"。

**禁止的做法（明确写死）**

- ❌ 把角色 / 绑定档口 / 合并条件存进浏览器 `localStorage` 或本机配置文件——会退化成"每块屏一套私配置"，运维无法收敛；
- ❌ 单机部署时"因为 Master 在这台机器上"就把配置写进本机文件——**即使 Master 与屏同机，配置仍走 `TerminalConfig` 表**，保持模型统一；
- ❌ 终端自行决定 Role 或档口（例如"我看到这个档口没屏，就当切配屏"）；
- ❌ 把门店级规则（流转开关 / 自动流转 / 营业日）下放到屏幕级——那会导致同一门店不同屏的工序口径不一致。

**配置校验（管理端保存时拦截）**

| 校验 | 规则 | 违反后果 |
|------|------|----------|
| 角色与档口匹配 | `TerminalConfig.Role` 必须等于其绑定档口的 `Station.Role`（`TerminalType = Composite` 的综合屏除外） | 切配屏收到制作阶段品项，或某个阶段无屏承接而静默跳过 |
| 档口至少绑一屏 | 每个启用的 `Station` 至少被一块启用的终端绑定 | 该档口品项**无人接单**（漏单） |
| 屏幕至少绑一档口 | 非综合屏必须绑定 ≥1 个档口 | 屏幕永远无数据 |
| 合并条件与视图 | `BaseGroupMode` / 合并条件在 `ActiveView` 下的组合必须合法（如 `SingleView_SortMode` 仅单菜视图生效） | 配了不生效，现场以为坏了 |
| **路由完整** | 保存后自动跑 §2.11.2 自检；`STATION_NO_SCREEN` / `MULTI_STATION_SAME_STAGE` 为**致命**，必须阻断或有明确风险确认 | 静默漏单 / 重复出品 |
| **分屏完整性（V1.1）** | `PaneLayout != Single` 时：栏档口 ⊆ 终端档口、**栏间不重叠**、**并集覆盖全部终端档口**、栏数匹配 | 重复显示 / 静默漏档口 |

**首次接入与重装（终端如何拿到自己的配置）**

```
① 终端启动：读本地保存的 TerminalId + DeviceKey
   有 → 直连 /hub/KdsHub?terminalId=…&deviceKey=…，拉 Config
   无 → 进入【绑定模式】：输入 Master 地址 + 终端编码（TerminalCode）
        → POST /api/Terminal/Bind（校验 TerminalCode + 管理员口令）
        → Master 返回 TerminalId + DeviceKey → 终端本地保存 → 进入正常流程

② 换屏 / 清缓存后重新绑定：用同一个 TerminalCode 重绑，配置自动恢复
   （配置挂在 TerminalConfig 记录上，不随硬件走）
```

**加载、缓存与失效**

| 环节 | 规则 |
|------|------|
| 启动 | 先读本地缓存（**只读、仅用于首屏渲染**），同时拉最新 `Config`；版本不同则以服务端为准覆盖 |
| 断网 | 用缓存配置继续展示（**只读、禁提交**），符合 §13.2 |
| 配置变更 | 管理端保存 → `ConfigVersion + 1` → 推送 `ConfigChanged`（带新版本）→ 终端重载配置并按需全量刷新数据 |
| 版本对账 | 终端在心跳中上报 `AppliedConfigVersion`；落后则 Master 主动补推 `ConfigChanged` |
| 禁用屏 | `TerminalConfig.IsEnabled = 0` → 拒绝连接（`UNAUTHORIZED` / `TERMINAL_DISABLED`），屏幕上显示"本终端已被停用，请联系管理员" |

> **唯一允许放终端的"配置性"数据**：UI 语言包文本（纯静态资源，随程序发布）与缓存副本。**行为参数（角色、档口、视图默认值、合并条件、超时阈值）一律不在终端立法。**

## 6. 事件分片队列

- 按订单号哈希**分片**，**同订单串行、跨订单并行**；
- 查询与推送使用**独立线程池**，互不阻塞；
- 分片队列保证同订单事件的处理顺序，避免并发改单导致状态错乱；
- 队列积压时**优先保证状态变更事件**，日志类事件可降级丢弃（记 `Warning`）。

## 7. 传输层

### 7.1 抽象接口

```csharp
public interface IKdsEventPublisher
{
    Task<PublishResult> PublishAsync(KdsEventEnvelope envelope, CancellationToken ct = default);
    event Func<KdsEventEnvelope, Task> OnKdsCallback;
}

public class KdsEventEnvelope
{
    public Guid EventId { get; set; }
    public string EventType { get; set; } = string.Empty;
    public string PosSource { get; set; } = string.Empty;
    public string StoreId { get; set; } = string.Empty;
    public DateTimeOffset Timestamp { get; set; }
    public JsonElement Payload { get; set; }
    public string ProtocolVersion { get; set; } = "1.0";
}
```

### 7.2 配置切换

`Transport.Mode` = `Mqtt` / `SignalR`（默认 `SignalR`）。JSON 序列化**强制 PascalCase**。

---

