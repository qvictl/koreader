# 三上游 issues / PR 调研与修复（2026-10-30）

**当前阶段：扫描报告已先交付，用户回复继续后，仅恢复 PDF 后台线程生命周期与 WAL 云同步两项。** 字典 PR49、插件 PR71、base PR35 继续暂停；WAL PR51 的技术依赖 hold 保留到线程修复 PR52 实际进入 main 并重新验证。页脚 PR50 在用户要求先报告前已经合入，本报告保留该事实。报告与完整清单随本分支保存。状态记录于 2026-10-30 05:23 UTC；未合入项不计作已交付。

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

## 优先修复的确认问题

| 问题及来源 | 本 fork 确认结果 | 修复与验证 | 交付记录 |
| --- | --- | --- | --- |
| [统计云同步 WAL 旧快照](https://github.com/koreader/koreader/issues/16299) | 真实 SQLite 中本地 2 本书，实际上传及 `.sync` 基线只有 1 本；直接复制主文件漏掉已提交 WAL 数据 | stats/vocab 显式使用一致 SQLite 快照；上传与原子替换基线使用同一快照；上传期间新增数据留给下次同步；验证冲突/失败清理与旧基线保护 | [本 fork PR51](https://github.com/qvictl/koreader/pull/51)，已恢复，等待 PR52 实际进入 main 后重新验证，未合入 |
| PDF 后台 context 的线程完成与回收窗口（本轮 CI 额外发现） | 两次独立 CI 出现原生崩溃；对应 native 源码在最终写入前清除进度标记，不能用该标记代替线程完成同步。无原生栈，精确崩溃因果仍未证明 | Lua 层保留 joinable worker，在消费、序列化、释放和 GC 前等待真实返回；检查启动失败、fork 和跨平台边界 | [本 fork PR52](https://github.com/qvictl/koreader/pull/52)，修复与回归进行中，未合入 |
| [禁用页脚后目录重置崩溃](https://github.com/koreader/koreader/issues/16202) / [生命周期修复建议](https://github.com/koreader/koreader/pull/16203) | 完全禁用页脚时没有进度条，EPUB 目录重置却仍更新标记，真实 ReaderUI 与模拟器均复现 nil 错误 | 一行生产修复，按已有禁用生命周期停止标记更新；完整 ReaderFooter 23 个单测和真实重排场景 7 个检查通过，均有修前失败证据 | [本 fork PR50](https://github.com/qvictl/koreader/pull/50)，已合入 `ff643535c92edac959dce59155a8db94300e3caa` |
| [同名词典被下载菜单隐藏](https://github.com/koreader/koreader/pull/16281) | 真实 1773 项目录中 5 个下载地址、10 个语言入口被显示名去重隐藏 | 菜单按下载地址区分；同时处理同名版本安装目录与实际词典身份，避免“菜单可选但安装/禁用互相覆盖”；未知来源旧目录不猜测删除 | [本 fork PR49](https://github.com/qvictl/koreader/pull/49)，已暂停，未合入；故障分支单测的 finally 隔离问题仍待处理 |
| [二维码 UI 候选](https://github.com/finlater/weread.koplugin/pull/225) | 官方运行时样本存在 0.9 二次插值；简单放大又会令白边不足，不能照搬尺寸改动或其中未证的鉴权假设 | 复用原生 QR 编码/绘制，保持整数像素与至少四模块白边；保留取消、释放、F5 刷新；不改鉴权协议。六组真实运行时/视口流程验证 | [本 fork PR71](https://github.com/qvictl/weread.koplugin/pull/71)，已暂停，未合入 |
| [RGB565 缩放行距错误](https://github.com/koreader/koreader/issues/16298) | 格式转换后仍使用旧行距，当前 base 与上游对应代码均受影响 | 一行生产修复；旧实现由 Lua 参数边界安全拒绝，修后正常原生像素、尺寸和输入数据保持验证通过；2 个原生 UT 与 35 个跨仓检查通过 | [本 fork base PR35](https://github.com/qvictl/koreader-base/pull/35)，Actions 外部禁用阻塞，尚未合入 |

SQLite 能力已分别在本轮 main 原生运行时和官方 v2026.07.1 实测：
SQLite 3.54.1 / 3.53.3 的只读连接均支持 `VACUUM INTO`，并能在持有旧读事务时生成包含新已提交行的独立快照。
新快照不是简单 checkpoint；失败不能先删除旧 `.sync`。
它只由已核查的 stats/vocab 调用者选择使用，通用同步接口仍保留普通文件调用方式。

二维码官方 600×800 样本从旧 339 px 插值结果改为 406 px 自然像素，模块 14 px、白边 78 px；
320×480 样本为 203 / 7 / 39 px。不同运行时原有布局不同，不能声称所有版本都更大。
真实关闭路径区分幂等方法调用与资源释放：`free` 方法可被框架多次调用，但活原生缓冲只释放一次、取消回调一次。
这些是 Linux 主机渲染、适屏和生命周期验证，未声称手机扫码成功或 Kindle 残影已硬件验收。

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

base 的 Actions 设置显示 enabled、workflow 显示 active；此前执行接口返回 HTTP422 禁用，本轮 PR 仍没有 required checks，尚未确认执行恢复。
因此其修复与配套 core 测试已经保存、验证并推到自有分支，却不能算作已合入。
配套 core 测试保留 `f76d9115004eb61c46a993f0eac85a63802487bb`，没有把未合 base 固定进产品 main，也未绕过分支保护。

对三个上游的操作均为只读：没有评论、reaction、标签、review、PR、push 或关闭操作。
本 fork 的 PR 描述、评论和提交消息也避免上游条目的 URL/跨仓引用，防止自动 cross-reference 通知；
来源和归属保留在仓库文件中，而不是给维护者发送完成通知。

本轮结果不等于所有上游问题已解决。原 Oasis 3 的 811 章卡死/COW 因果、长期长书和休眠恢复真机验收仍未闭环。

## 本轮 CI 额外发现：原生线程生命周期风险

两个独立 CI 中，既有 cache-pressure 场景分别出现 SIGABRT 与 SIGSEGV，原始日志和 JUnit 已保留。读取本轮实际 base7c4 固定的 libk2pdfopt64aa9cc 源码发现：precache 完成标记先于后续 context 写入及清理，而上层仅轮询该标记。存在过早消费/回收窗口，与崩溃高度一致，但日志无原生栈，尚不能断言两次崩溃的精确因果。该项需要真实线程完成同步与全生命周期设计；用户回复继续后已恢复为优先项 [本 fork PR52](https://github.com/qvictl/koreader/pull/52)，以真实 pthread join 覆盖消费、缓存序列化、释放与 GC，兼顾启动失败、fork 子进程和 Windows PID 接口。安全回归在 Lua 边界拒绝缺失同步，不故意执行旧原生并发释放；当前 `7e80861a3fcdbc867a01e7174d7eb2516e723fa4` 必需 CI 已通过，等待最新 head 的 AI 审查，未合入。

线程修复的 PR CI 还识别了两种独立测试问题：旧压力测试通过拦截 `usleep` 模拟完成，已改为 join 边界；唤醒队列测试在预期计算与实际入队之间跨秒，已在测试内固定并恢复时钟。安全注入跨秒时旧测试 6/8 失败，修后同条件 8/8 通过；唤醒生产逻辑未改。这些不计作额外产品 bug 修复，也不通过反复重跑掩盖。

原生故障也不能被写成“字典/云同步测试全部完成”：对应业务测试通过，但所需 CI 曾受该独立问题阻断。字典另有一项故障测试隔离问题，旧通过数不能作为该分支的有效证据。WAL 将在线程修复实际进入 main 后重新验证；字典继续暂停，其隔离问题不能借其他修复冒称完成。
