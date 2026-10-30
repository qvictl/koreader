# 三上游 issues / PR 调研与修复（2026-10-30）

**已交付的修复包括 PDF 后台线程生命周期、WAL 云同步、页脚、微信读书二维码与字典基础修复。** 字典元数据、配套文件和即时列表补修由 [PR55](https://github.com/qvictl/koreader/pull/55) 交付，本报告随该补修更新；最终提交、合入状态及当前门禁以其[检查页](https://github.com/qvictl/koreader/pull/55/checks)为准。base PR35 尚未合入，最近执行请求被 GitHub 拒绝，仍缺四项必需 CI。

交付状态记录于 2026-10-30；开放条目数使用本轮采样快照，不能当作实时总数。页脚 PR50 在用户要求先报告前已合入，本报告保留该事实。

本轮只读调查 `koreader/koreader`、`koreader/koreader-base` 和 `finlater/weread.koplugin`，
以数据安全、可复现崩溃、常用功能正确性和实现风险排序，挑选适合本 fork 的修复。
不将开放条目数当作已确认缺陷数，也不整包采纳尚未验证的上游 PR。

## 扫描范围与完整性

| 上游 | 开放 issue | 开放 PR | 核查范围 |
| --- | ---: | ---: | --- |
| koreader/koreader | 1306 | 89 | issue 元数据 14 页、PR 元数据 1 页；唯一编号数与各页 total 一致；重点条目再读正文、讨论和 diff |
| koreader/koreader-base | 7 | 9 | 完整开放清单、重点条目讨论与近期已合入修复 |
| finlater/weread.koplugin | 28 | 25 | 完整开放清单、逐项处置；另查全部 81 个已关闭 PR 的清单 |

这是 2026-10-30 本轮收集的快照，共 1341 个开放 issue、123 个开放 PR。
上游在扫描期间仍有更新，例如另一次稍晚 core 读取已变为 1305 个 issue；不能把不同采样时间拼成一个实时总数。
全量覆盖指元数据分页清单，**不是逐一复现了所有开放条目**。
快照中的主要分类如下，标签可以重叠，未打 bug 标签也不表示不存在缺陷：

| 上游 | 标签与 PR 状态 | 对本 fork 的含义 |
| --- | --- | --- |
| core | enhancement 554、Plugin 103、bug 60、firmware 57、Kindle 48、Kobo 48、CREngine 38；17 个草稿 PR | 大量条目是功能或平台特定需求；优先做有源码和复现证据的数据安全、生命周期及本设备常用路径 |
| base | 7 个 issue 仅 1 个 enhancement 标签；9 个 PR 中 3 个草稿 | 标签不足以判断严重性，需核查当前 diff、core 接口和设备契约，不能按标题直接移植 |
| weread | bug 12、enhancement 11、P0 2、P1 1；无草稿 PR | 重点区分凭据、服务端限流、启动缓存与排版问题；上游优先级标签不等于当前 fork 已复现 |

可审计的完整开放元数据保存在 [压缩 JSON 快照](2026-10-30-upstream-census.json.gz)：
包含每条编号、标题、链接、创建/更新时间、标签，以及 PR 的草稿和 head 信息，不含评论正文或用户书籍数据。
未压缩 352803 B，压缩 80556 B，SHA-256：
`662ab222bc9e66a0aec5567f4de6394666aba28e292b5dd6d3f71cadf94ff90d`。

插件全部 28 个 issue 与 25 个 PR 的逐项处置见 [固定提交中的明细表](https://github.com/qvictl/weread.koplugin/blob/48166ec3631eed03416c51136a48ba5a409bf549/docs/reports/2026-10-30-upstream-plugin-triage.md)。该链接保留初始扫描版本；已合入的[插件报告](https://github.com/qvictl/weread.koplugin/blob/4afb5d3138d23298a6b0451d0a341419ebf229cd/docs/reports/2026-10-30-upstream-plugin-triage.md)补充最终验证与历史证据的区别。

## 优先修复的确认问题

| 问题及来源 | 本 fork 确认结果 | 修复与验证 | 交付记录 |
| --- | --- | --- | --- |
| [统计云同步 WAL 旧快照](https://github.com/koreader/koreader/issues/16299) | 真实 SQLite 中本地 2 本书，实际上传及 `.sync` 基线只有 1 本；直接复制主文件漏掉已提交 WAL 数据 | stats/vocab 显式使用一致 SQLite 快照；上传与原子替换基线使用同一快照；上传期间新增数据留给下次同步；验证冲突/失败清理与旧基线保护 | [本 fork PR51](https://github.com/qvictl/koreader/pull/51)，已合入 `ec3b5cb7583c65e40eeee9dba3700690ced940d6` |
| PDF 后台 context 的线程完成与回收窗口（本轮 CI 额外发现） | 两次独立 CI 出现原生崩溃；对应 native 源码在最终写入前清除进度标记，不能用该标记代替线程完成同步。无原生栈，精确崩溃因果仍未证明 | Lua 层保留 joinable worker，在消费、序列化、释放和 GC 前等待真实返回；检查启动失败、fork 和跨平台边界 | [本 fork PR52](https://github.com/qvictl/koreader/pull/52)，已合入 `496f3fd326dda8c67faa69d7eb33f7b1ec318c28`；[生命周期验证报告](2026-10-30-kopt-thread-lifetime.md) |
| [禁用页脚后目录重置崩溃](https://github.com/koreader/koreader/issues/16202) / [生命周期修复建议](https://github.com/koreader/koreader/pull/16203) | 完全禁用页脚时没有进度条，EPUB 目录重置却仍更新标记，真实 ReaderUI 与模拟器均复现 nil 错误 | 一行生产修复，按已有禁用生命周期停止标记更新；完整 ReaderFooter 23 个单测和真实重排场景 7 个检查通过，均有修前失败证据 | [本 fork PR50](https://github.com/qvictl/koreader/pull/50)，已合入 `ff643535c92edac959dce59155a8db94300e3caa` |
| [同名词典被下载菜单隐藏](https://github.com/koreader/koreader/pull/16281) | 真实 1773 项目录中 5 个下载地址、10 个语言入口被显示名去重隐藏 | 菜单按地址区分，同名来源使用不同安装目录和实际词典身份；目标路径不同的旧副本保留，同一路径成功重装替换旧目录；补充准备失败保旧、配套文件准入和即时列表恢复 | [PR49](https://github.com/qvictl/koreader/pull/49) 已合入 `ab784a8c080255007497f8009d9d1890fd1cdea8`；[PR55](https://github.com/qvictl/koreader/pull/55) 为后续补修，最终交付及检查记录见该 PR |
| [二维码 UI 候选](https://github.com/finlater/weread.koplugin/pull/225) | 官方运行时样本存在 0.9 二次插值；简单放大又会令白边不足，不能照搬尺寸改动或其中未证的鉴权假设 | 复用原生 QR 编码/绘制，保持整数像素与至少四模块白边；保留取消、释放、F5 刷新；不改鉴权协议。最终源码在三个实际运行时/屏幕组合各通过 10 项流程检查 | [本 fork PR71](https://github.com/qvictl/weread.koplugin/pull/71)，已合入 `4afb5d3138d23298a6b0451d0a341419ebf229cd`；兼容小屏 nil/零尺寸失败分支，同时保留大屏 dense 正向编码断言 |
| [RGB565 缩放行距错误](https://github.com/koreader/koreader/issues/16298) | 格式转换后仍使用旧行距，当前 base 与上游对应代码均受影响 | 一行生产修复；旧实现由 Lua 参数边界安全拒绝，修后正常原生像素、尺寸和输入数据保持验证通过；2 个原生 UT 与 35 个跨仓检查通过 | [本 fork base PR35](https://github.com/qvictl/koreader-base/pull/35)，Actions 外部禁用阻塞，尚未合入 |

SQLite 能力已分别在本轮 main 原生运行时和官方 v2026.07.1 实测：
SQLite 3.54.1 / 3.53.3 的只读连接均支持 `VACUUM INTO`，并能在持有旧读事务时生成包含新已提交行的独立快照。
新快照不是简单 checkpoint；失败不能先删除旧 `.sync`。
它只由已核查的 stats/vocab 调用者选择使用，通用同步接口仍保留普通文件调用方式。

WAL 最终候选 `9478a710e925b65af59dec0412d895ba60a8b87f` 明确包含已合入的线程修复 `496f3fd3`。对新组合重新核对 500 个运行时 Lua，0 个缺失或不匹配；base 与 native 构建输入未变，复用已验证的 Linux native 产物，而非冒称重新编译。新隔离 profile 的 19 项相关单测与 `31_cloud_sqlite_snapshot` 11/11 检查通过；使用真实 ReaderUI/SQLite，云传输由受控回调模拟，未作为真实云服务、断电持久性或 Kindle 硬件验收。

二维码最终源码分别验证 fork 运行时 240×320、官方 v2026.07.1 运行时 240×320、fork 运行时 600×800，三组均 10/10。小屏普通登录二维码为 145 px、模块 5 px、白边 28 px；大屏为 406 / 14 / 78 px。2953 字节 dense 样本在两种小屏运行时分别返回 nil、0×0，均走明确失败分支；大屏必须成功产生 354 px 图像。真实小屏负例证明旧测试错误拒绝合法 nil；另用纯 Lua 安全注入证明，小屏兼容后的过宽测试会漏掉大屏编码失败。最终断言同时覆盖两者。此前六组记录仅为历史样本，不计为当前最终源码验证，也不声称所有版本都更大。
真实关闭路径区分幂等方法调用与资源释放：`free` 方法可被框架多次调用，但活原生缓冲只释放一次、取消回调一次。
这些是 Linux 主机渲染、适屏和生命周期验证，未声称手机扫码成功或 Kindle 残影已硬件验收。

## 修复验证与交付记录

| 修复 | 最终候选与候选 CI | 验证范围 | 主线交付 |
| --- | --- | --- | --- |
| PDF worker 生命周期 | `a2959d5beedb5db8b27e635a54185bb6498ce0c1`；[CI 41016508983](https://github.com/qvictl/koreader/actions/runs/41016508983) | 33 项安全边界、9 项压力检查、3 项原生清理；真实场景 28 为 26/26、两个 worker 已 join；CI front146/base37，改动行 96/103＝93.204% | 07:00:56 UTC 合入 `496f3fd3`；[合入后 CI](https://github.com/qvictl/koreader/actions/runs/41017473409) 成功 |
| WAL 一致快照 | `9478a710e925b65af59dec0412d895ba60a8b87f`；[CI 41017949388](https://github.com/qvictl/koreader/actions/runs/41017949388) | 19 项相关单测；真实场景 31 为 11/11；CI front147/base37，改动行 56/58＝96.552% | 07:23:43 UTC 合入 `ec3b5cb7`；[合入后 CI](https://github.com/qvictl/koreader/actions/runs/41019822972) 成功 |
| 字典基础修复 | `05dfd664223f6e23fce2e3f05c59e1d5e1bbc370`；[CI 41033209673](https://github.com/qvictl/koreader/actions/runs/41033209673) | CI front148/base37、零失败；改动行 71/73＝97.260%；148/37 是 spec 文件套件数 | 09:44:43 UTC 合入 `ab784a8c`；[合入后 CI](https://github.com/qvictl/koreader/actions/runs/41035656014) 首次成功 |
| 字典补修 | [PR55 最新提交与检查](https://github.com/qvictl/koreader/pull/55/checks) | 设置、真实 sdcv/渐进查询、quicklookup 定向回归，新增缺件、类型和压缩兼容用例；改动行覆盖率以该提交的 coverage 工件为准 | 本报告随 PR55 交付；实际合入记录见 [PR55](https://github.com/qvictl/koreader/pull/55) |

PDF/WAL 两项均有最新候选的正式 AI 批准与全部必需检查，审查对话全部解决，经原网关正常合入。root 独立核验两份实际合入树分别等于其候选树，`ec3b5cb7` 包含 `496f3fd3`；base 仍为 `7c4e2f0d81afafb8a19dfa2a28ec2df461962272`。上表百分比均为改动行单测覆盖率；普通 CI 的整体指标为未测量，不作为整体 UT 覆盖率提升或发布基线记录。

二维码最终候选 `1739f76ce9dbe2e71b70c8430da65feb7bfb1f91` 的 [CI 41027044985](https://github.com/qvictl/weread.koplugin/actions/runs/41027044985) 与 tests policy 成功，选择的 71 项 spec 无失败，改动行单测覆盖率 71/71＝100%，整体指标未测量。当前 AI 正式批准、审查对话全部解决，经原门禁于 08:47:58 UTC 合入 `4afb5d31`，完整树与候选一致；[合入后 CI 41028886643](https://github.com/qvictl/weread.koplugin/actions/runs/41028886643) 五个 job 全成功。Release 工作流仅解析条件，发布 job skipped；没有发版或安装设备。最终补丁只修集成场景断言与报告，生产 QRDialog 与先前实现 `185581df` 逐字一致。原生运行时复用已有构建、Lua 按最终源码覆盖，没有重新编译 core/native。

字典安装先在同一文件系统的隐藏专用目录准备归档，再备份旧目录并替换。提取、已检测的元数据/配套文件检查、身份改写、备份或发布失败时保留或恢复旧词典。发布和回滚同时失败时保留旧文件、报告实际恢复路径，并立即刷新当前实例；刷新读取失败则保留原错误与路径，目录和活动选择落到安全空状态。活动首选仅包含当前可发现的名称，保存的首选值和顺序保留；已安装但全局禁用的首选仍可启用，恢复文件并重扫后可重新生效。

准入按 Reader 的 LF `bookname` 规则以 4 KiB 分块扫描，不新增整份元数据分配；身份改写零替换也在发布前失败。所有候选元数据及 native 实际选中的索引、数据组件须为普通文件，遵循压缩路径优先、选中后不自动回退的规则，支持 `.idx` / `.idx.gz`、`.dict` / `.dict.dz`。该检查是基本存在性与类型校验，未实现任意二进制内容验证；`.syn` 不被新增为整词典加载的强制项。压缩兼容使用[与当前 native 同源的官方资产](https://github.com/Dushistov/sdcv/tree/a4ab0d45c53100433098b8d3e4c21d04b7c42f11/tests/stardict-test_synonyms-2.4.2)，保留原 `.dict.dz`、元数据与同义词字节；四种索引/数据组合对 `foo/bar/test` 的 12 次独立 native 查询全部符合官方预期。

缺件守卫的设置/目录定向回归为 46 项，包含 10 种缺件、类型与后续条目边界，以及四种官方格式的实际安装查询。本轮此前还完成真实 sdcv/渐进查询 50 项、quicklookup 24 项关联回归；本次守卫只改安装准入，最终源代码的 CI 结果见 PR55 当前检查。分块测试覆盖标记全部十个切点、跨多块长字段和截断 EOF；1 MiB 描述尾部样本的预检最多读取 16 KiB，每次最多 4 KiB，量化的是预检读取量。故障测试核对旧文件完整字节、禁用/排序设置、当前缓存与实际恢复路径。保留真实暂存残留后强制重扫，并用无 `-u` 的真实 sdcv 验证残留不进入查询：Lua 仅排除 `.koreader-dict-download-` 专用前缀，当前 native 也跳过隐藏目录；其它用户隐藏目录的 Lua 发现行为保留。

真实 `04_dictionary` 场景为 39 项检查。清理验证覆盖原设置 false、原键不存在与可捕获异常，设置和整个词典 fixture 树均恢复到事前状态；异常样本按失败记录。场景核实自身 KO_HOME、fixture symlink 目标及实际词典根目录后使用私有副本；主动强退只留下私有残留，共享 fixture 不变，同一 runner 下一次重复场景仍通过 39 项检查。测试使用自有合成数据或官方测试资产，复用已核原生构建与当前 Lua，不作为新 native 构建、用户词典操作或 Kindle 硬件验收。[下载文档](../Dictionary_downloads.md)说明新旧版本与归档并存的空间需求、目录身份边界及手工恢复。

## 去重后不重复修复的问题

- [未绘制按钮点击崩溃](https://github.com/koreader/koreader/pull/16327)、相关 DNS/UI 等待路径：当前 fork 已有前置 guard 和有界 worker 修复，不能重复算新成果。
- [资源下载限流/失败候选](https://github.com/finlater/weread.koplugin/pull/226)：当前 Downloader 已把 source/images 放进整章重试，包含三次尝试及 0.8/1.6 秒协作调度。499/429 合成真实调用链检查确认已有缓解；不额外叠乘内部重试，也不以丢图片后继续来宣称成功。
- [清空批注后文件不缩小](https://github.com/finlater/weread.koplugin/pull/208)：当前实现已有 VACUUM 和真实文件大小回归。
- [阅读上报 gate](https://github.com/finlater/weread.koplugin/pull/213) 等进度路径：已有相关请求归属、失败恢复和单测，不能据旧版本反馈重复改写；真实服务端计时仍需独立验收。
- 插件上游开放的本 fork 既有 PR 分支保留原样，不重发、不关闭、不追加“我们已经修复”的通知。

## 暂不采纳及后续调查

| 范围 | 判断 |
| --- | --- |
| [Android 旋转候选](https://github.com/koreader/koreader-base/pull/2393) | 当前 diff 与早期正文方案已不同，作者讨论提及触摸/显示错位；需要 core 联动契约及 Android 验证，不能直接抄映射 |
| [多输入 FD 的触摸 slot](https://github.com/koreader/koreader-base/issues/1437) | 需要把每 FD 身份跨 C 输入与 core 手势链传递；不是独立一行 Lua 修复，也未用模型单测冒称设备闭环 |
| [公众号凭据过期（上游 P0）](https://github.com/finlater/weread.koplugin/issues/62) | 依赖账号/服务状态，未访问真实账号或猜改参数；与二维码 UI 显示问题分开处理 |
| [想法下载限流（上游 P0）](https://github.com/finlater/weread.koplugin/issues/134) | 已有错误分类和暂停续跑，但该账号限流未稳定复现，不能用资源下载 499/429 的已有缓解冒称此问题关闭 |
| [重启缓存冲突（上游 P1）](https://github.com/finlater/weread.koplugin/issues/97) | 已有原子 EPUB 与 workspace 隔离；仍缺该旧启动失败的稳定复现，不能声称根因已闭环 |
| 插件 401 登录协议、截图手势等反馈 | 没有足够真实协议/事件链证据的项继续列为候选，不凭匿名请求或标题猜修复 |
| base 其余开放项 | 主要包括构建分发、CMake/Makefile、SDL、面板/文字接口和 Android IME 等需求；不将功能提案当作本设备已确认缺陷，不整包引入新增原生模块 |
| core 其余开放项 | 平台、固件、格式兼容、插件与功能建议仍有大量条目；本轮只对表内明确范围给出源码和复现结论 |

## 合入、通知边界和剩余事项

修复仅提交到我们的 fork，经当前 head 的必需 CI、AI 审查及 review thread 门禁进入 main。
按照 [CONTRIBUTING](../../CONTRIBUTING.md) 与当前 CI，普通 PR 须通过全部必需构建、选择性 UT、改动行单测覆盖率与 AI/对话门禁；用户可见修复还须提供适用集成场景，但完整模拟器 IT 在发版候选验证时执行。本轮有针对性的本地主机集成复现，不改变该执行策略或门槛。README 的中英文贡献说明也已与此策略对齐。
未为本轮修改版本号、手动发版或重新安装设备。

原先三个 `do-not-merge` 是维护 agent 在“先报告、暂停实施”阶段添加的标记，用户恢复工作后已移除。PR49 收到有效 outside-diff 意见时未及时恢复技术暂停，正常门禁先行合入；PR55 补齐已确认的数据丢失和列表缺口。此次补修在完整 AI 检查结束、全文意见读完并处理完有效阻断、当前 CI 通过后才解除临时暂停。报告随同补修交付，后续非阻断建议记录待办，避免持续扩大本轮范围。原保护、必需检查和执行策略保持。

base 的 Actions 设置显示 enabled、workflow 显示 active，但 2026-10-30 08:20:38 UTC 对当前 `448fa0440d64c63a4918ecdca29b15ccaee61ff3` 分支进行的一次正确 dispatch，仍返回 HTTP422：`Actions has been disabled for this repository.`（请求 ID `D3B4:2CF054:A703F:B6E93:6AE45355`）。前后工作流 run 均为 1331 个，没有创建新 run。当前 AI 已批准、无开放审查对话，重新验证的 2 个原生正向测试通过；保护规则的 Lint、Build and unit tests、Tests policy、Coverage 四个真实检查仍缺失。本次没有重复 dispatch，原四项必需检查继续执行；限制原因尚未得到提供方确认，需要仓库所有者核查 GitHub 限制通知或由 GitHub Support 恢复执行。诊断与未发送的支持草稿已本地保存。
因此其修复与配套 core 测试已经保存、验证并推到自有分支，却不能算作已合入。
配套 core 测试保留 `f76d9115004eb61c46a993f0eac85a63802487bb`，没有把未合 base 固定进产品 main，也未绕过分支保护。

对三个上游的操作均为只读：没有评论、reaction、标签、review、PR、push 或关闭操作。
本 fork 的 PR 描述、评论和提交消息也避免上游条目的 URL/跨仓引用，防止自动 cross-reference 通知；
来源和归属保留在仓库文件中，而不是给维护者发送完成通知。

811 章真机问题已由用户确认闭环；原有“仍未闭环”的状态标注有误，现已更正。本轮新增 PDF/WAL 修复的主机测试、真实云服务和硬件验证范围仍按上文分别记录。

## 本轮 CI 额外发现：原生线程生命周期风险

两个独立 CI 中，既有 cache-pressure 场景分别出现 SIGABRT 与 SIGSEGV，原始日志和 JUnit 已保留。读取本轮实际 base7c4 固定的 libk2pdfopt64aa9cc 源码发现：precache 完成标记先于后续 context 写入及清理，而上层仅轮询该标记。存在过早消费/回收窗口，与崩溃高度一致，但日志无原生栈，尚不能断言两次崩溃的精确因果。该项需要真实线程完成同步与全生命周期设计；用户回复继续后已恢复为优先项 [本 fork PR52](https://github.com/qvictl/koreader/pull/52)，以真实 pthread join 覆盖消费、缓存序列化、释放与 GC，兼顾启动失败、fork 子进程和 Windows PID 接口。安全回归在 Lua 边界拒绝缺失同步，不故意执行旧原生并发释放；最终候选 `a2959d5beedb5db8b27e635a54185bb6498ce0c1` 已通过全部必需检查、当前 AI 审查和对话门禁，于 07:00:56 UTC 正常合入 `496f3fd326dda8c67faa69d7eb33f7b1ec318c28`；root 核对合入树与候选树完全相同，base 仍为 `7c4e2f0d81afafb8a19dfa2a28ec2df461962272`。

线程修复的 PR CI 还识别了两种独立测试问题：旧压力测试通过拦截 `usleep` 模拟完成，已改为 join 边界；唤醒队列测试在预期计算与实际入队之间跨秒，已在测试内固定并恢复时钟。安全注入跨秒时旧测试 6/8 失败，修后同条件 8/8 通过；唤醒生产逻辑未改。这些不计作额外产品 bug 修复，也不通过反复重跑掩盖。

预取还会在生成页面像素和提升 CPU 核数前，按现有预算检查固定的 context 大小，并核查线程库与隔离状态；插入缓存使用同一大小。这样消除正常预算拒收造成的后台 orphan，预算阈值保持原值。真正插入异常或调用者丢引用的 GC，以及失败 owner 的隔离回收，仍可能等待 native worker 返回，这是当前内存安全兜底；本修复不声称异常 GC 与回收完全不阻塞。

线程修复的 [成功 CI 计时样本](https://github.com/qvictl/koreader/actions/runs/41012619801) 对应 `0431cdb8eef833cf9a9b57145d0fd415a1c846ef`：模拟器 job 240 秒，其中 front 146 个套件含单测覆盖率 164 秒、base 37 个套件 4 秒、范围分析 10 秒、打包 22 秒；后续覆盖率报告 16 秒，Lint 38 秒并行执行。步骤时间来自该次 GitHub job 元数据，不能直接相加成总等待时间；外部 AI 另计：该样本的 CodeRabbit 检查从 06:11:34 至 06:30:02 UTC 共 18 分 28 秒，包含外部排队、工具与审查处理，且提出修改意见；check 完成不等于审查批准。单测 changed-line 96/103＝93.204%，普通 CI 的 whole 指标仍为 null，没有伪造全量覆盖率或写入 release baseline。该次选择清单为 full，唯一原因是修改的 koptinterface 依赖 ffi/koptcontext，属于无法证明闭包的原生接口；不是把全部 PR 固定为全量 UT。

原生故障也不能被写成“字典/云同步测试全部完成”：对应业务测试通过，但所需 CI 曾受该独立问题阻断。字典旧故障测试存在 finally 覆盖导致的隔离问题，已在恢复实施时修正并按当前源码重新验证；不能使用旧通过数替代新证据。WAL 已在实际线程修复主线组合上重新验证并完成合入；字典基础修复与补修的记录分别见前文。
