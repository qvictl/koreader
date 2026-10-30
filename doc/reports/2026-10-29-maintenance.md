# 三仓维护与交付报告（2026-10-29）

证据快照：2026-10-29 17:30 UTC；报告整理：2026-10-30 UTC。

本报告汇总 qvictl 的 KOReader、koreader-base 和 weread.koplugin 本轮维护结果。
截至本报告所列发布完成时，开发子任务均已结束，已确认的本轮修复、CI 改造和发布验证已交付。
这不代表全库没有缺陷：原 Oasis 3 下载 811 章时卡死的真机根因、长书压力和休眠恢复验收尚未闭环。

## 1. 交付版本与范围

| 对象 | 本轮已交付源码 | 说明 |
| --- | --- | --- |
| KOReader main | `ab190e63c8ba8cab2324443ca13be9d390c8f157` | 完整 Kindle HF/PW2、Linux 模拟器；nightly 版本 `v2026.10.q1-241-gab190e6` |
| KOReader stable/v2026.07.1 | `8ff4d8bcfd8ccbcda02eda3ecaf628cfa84ca34c` | 已回移本轮缓存修复，用于稳定版 Lua overlay |
| koreader-base main | `0cdffb07f88b58ea8d7684c30faa3db0a4adf5f4` | 本轮 base 主线终点；产品精确固定 `7c4e2f0d81afafb8a19dfa2a28ec2df461962272` |
| CREngine 原生依赖 | `b9d1feff0e68ebbf61784bc9c4d1d6dd81f5bcaa` | 由产品 base gitlink 固定，包含字体生命周期修复 |
| weread.koplugin v1.6.92 | `c5855b317477db59c8896e2bc4832d6961d0ab48` | 已发布，包含本轮 worker、资源命名、章节状态与 reader 会话改动 |

base 主线比产品 gitlink 多出的 [PR #33](https://github.com/qvictl/koreader-base/pull/33)
恢复已有上游同步 diff 覆盖率例外，没有新增产品运行时代码。本文不把主线 SHA 当作已打包 gitlink。
报告本身后续的文档提交不改变上述受测版本。

## 2. 缺陷修复与结构调整

### KOReader

| 问题范围 | 交付结果 | 合并记录 |
| --- | --- | --- |
| 居中词典弹窗边界 | 修正坐标轴计算，并回移稳定线 | [#23](https://github.com/qvictl/koreader/pull/23)、[#24](https://github.com/qvictl/koreader/pull/24) |
| 统计历史兼容与时间边界 | 恢复旧数据导入，保留周期边界语义 | [#26](https://github.com/qvictl/koreader/pull/26) |
| 屏保图片枚举 | 按可用图片计数，避免无关文件耗尽限额 | [#27](https://github.com/qvictl/koreader/pull/27) |
| 文件管理与输入生命周期 | 释放浏览器对话框，隔离输入状态与手势状态 | [#28](https://github.com/qvictl/koreader/pull/28) |
| 文档缓存与 PDF 标注交互 | 淘汰旧页映射，保留 PDF 箭头动作 | [#30](https://github.com/qvictl/koreader/pull/30) |
| 休眠、快速再次休眠与屏保 | 保留队列事件，正确管理延迟屏保任务 | [#32](https://github.com/qvictl/koreader/pull/32) |
| worker 结果、命令输出与取消 | 有界收集部分结果；输出持续写入、继承 writer、取消等路径保持响应 | [#33](https://github.com/qvictl/koreader/pull/33)、[#36](https://github.com/qvictl/koreader/pull/36) |
| DNS 与 KOSync | 交互 DNS、默认 HTTP 和认证移至有界 worker；保留关闭/休眠进度，淘汰过期重试 | [#34](https://github.com/qvictl/koreader/pull/34)、[#38](https://github.com/qvictl/koreader/pull/38)、[#39](https://github.com/qvictl/koreader/pull/39)、[#41](https://github.com/qvictl/koreader/pull/41) |
| 短词查词延迟 | 减少初始等待，保留渐进显示回归验证 | [#37](https://github.com/qvictl/koreader/pull/37) |
| PDF/DjVu 内存压力回收 | 就绪文档缓存按已用字节约减半，再恢复容量上限；busy KOPT 保留原槽位回收行为 | [#45](https://github.com/qvictl/koreader/pull/45) |
| 缓存回归测试自身的资源生命周期 | 实际线程 barrier、故障注入和清理测试，覆盖准备失败、部分打开失败、关闭失败 | [#46](https://github.com/qvictl/koreader/pull/46) |
| 稳定分支交付 | 回移已验证修复，避免把 main-only 测试工具带入稳定版 | [#40](https://github.com/qvictl/koreader/pull/40)、[#47](https://github.com/qvictl/koreader/pull/47) |

### koreader-base

归档失败和特殊数字序列化已修复并回移；macOS 平台标识判断已修复；原生字体在文档销毁后释放。
子进程结果管道、文件操作错误传播和直接执行的 shell 输出管道也已交付，分别有单测与产品集成回归。
详见 [base 分报告](https://github.com/qvictl/koreader-base/blob/62aa10c712fa090483921eeb216789fc3c05a433/doc/reports/2026-10-29-maintenance.md)
及 [#23](https://github.com/qvictl/koreader-base/pull/23)、[#25](https://github.com/qvictl/koreader-base/pull/25)、
[#26](https://github.com/qvictl/koreader-base/pull/26)、[#27](https://github.com/qvictl/koreader-base/pull/27)、
[#28](https://github.com/qvictl/koreader-base/pull/28)、[#29](https://github.com/qvictl/koreader-base/pull/29)。

### weread.koplugin

本轮修复覆盖下载/预取失败后的作业释放、账号切换时结果归属、QR 登录与其余网络操作的 UI 响应、
资源解包回滚、字面目录名保护、进度同步和请求所有权。结构上收敛到进程 Runtime、请求 owner、
共享 fork 预算和明确的章节状态增量边界。

最新交付中，资源命名修复避免封面名称冲突导致挂起；共享预算持续占用到精确 PID 回收；
手动待同步进度在重开/恢复阅读后重试；章节 worker 只返回当前章节变化；reader 会话在同一下载任务内复用，
错误或重试时回到新建会话路径。详见
[插件分报告](https://github.com/qvictl/weread.koplugin/blob/54145af8ff4bcf23cf53c20b629d6be23a23be60/docs/reports/2026-10-29-maintenance.md)
和 [v1.6.92](https://github.com/qvictl/weread.koplugin/releases/tag/v1.6.92)。

## 3. 性能实测及代价

下表均是特定主机、输入和运行时下的结果。它们不构成 Kindle 实测速度或整机内存收益承诺。
不同 fixture 和采样阶段的耗时不能直接互相比快。

| 项目 | 观察到的变化 | 适用范围及代价 |
| --- | --- | --- |
| 原生字体生命周期 | 关闭后遗留字体 face 数从 6/5/7 降为 0；主机关闭后 RSS 约少 16–18 MiB | 相同渲染样本的 18 张 PNG 一致；不宣称跨字号共用一个 face 或节省 40 MiB |
| PDF 页面缓存压力回收 | 实际 MuPDF 缓冲从 32,034,816 B：旧策略剩 25,482,240 B，新策略剩 14,864,640 B，额外释放 10.125 MiB | 回看 15 大页由 12 hit/3 miss 变为 7 hit/8 miss；主机 CPU 约 4.4→9.1–9.3 ms。改善释放量，同时增加重绘；不是提速 |
| 封面/资源同名分配 | 2,000 同名候选主机中位数 4,453.852→10.136 ms | 保留 Lua 堆约 123.3→128.9 KiB；减少重复扫描，不是降低内存 |
| worker 章节状态 | 旧整状态文件 1,767,176 B，增量结果文件约 5.7 KB | 是真实跨进程文件通道，不是管道容量实验；没有据此声称 RSS 或 200 章提速 |
| reader 会话复用 | 控制场景 reader GET 从 4 降为 2 | 计数含初始 GET；已验证失败/缺失元数据回退。两章真实协议样本解码一致，但不等于所有书籍协议保证 |
| 缓存扫描/导入 | 历史主机峰值 RSS 285,068→112,900 KiB，UI 间隔 5,478→374 ms | 同一样本总耗时 5,998→8,713 ms，约慢 45%；以响应和峰值内存换总耗时 |

缩小 MuPDF store 的候选在公开样本上带来约 12% 渲染退化，已撤回。
没有证据支持增加 sdcv 常驻 daemon 或全局动态缓存预算框架，因此未将这些研究建议写成已交付优化。
PDF/DjVu 压力调用链不等于 EPUB/WeRead 下载路径，不能用本次缓存修复解释原 811 章卡死。

## 4. 测试与覆盖率

| 对象 | 实际完整验证 | Unit | Unit + integration |
| --- | --- | --- | --- |
| KOReader `ab190e63` | 144 单测套件、2,068 cases；普通及覆盖率 IT 各 28/28 场景、510/510 checks | 48.507%（47,846/98,637） | 53.119%（52,757/99,319） |
| 产品 base `7c4e2f0d` | 37 单测套件、491 cases；同一精确 gitlink 参加上述产品 IT | 41.580%（5,370/12,915） | 45.833%（5,939/12,958） |
| 插件 v1.6.92 | 145 完整普通 UT 文件；fork 与官方各 30/30 场景，含 200 章预算；固定版本 PluginLoader | 91.55%（19,734/21,555） | 93.65%（20,278/21,653） |

core/base 单测均零失败、零 error、零 skip，两仓各 6 项强制发布覆盖率门槛通过。
core 本批执行行 diff 13/13；base 本批 diff 0/0 表示没有新的生产执行行，不能当作覆盖率新增成果。
插件发布批次 combined diff 为 368/384，即 95.83%；原阻断门槛和同步持久化 ack 均通过。
插件 LuaCov 有两项既有性能采样 advisory；`plugin_util.lua` 55.9% 未达到未来模块目标，尚须补齐。

KOReader 稳定 overlay 实际完成 27 个场景、510/510 checks。
完整包与 overlay 的运行时不同，不能混用场景数或把 overlay 当作原生二进制修复包。
插件此次自动发布的 fork 运行时是 `8e9a159e16f39541a9c3c406e548f5cac65e1bc3` nightly，
不是稍后发布的 `ab190e63`；另外的本地预验使用了精确 main `a2c7697c`、官方 v2026.07.1 和稳定 `aef4bb9d` 运行时。

发布证据入口：

- [KOReader 完整发版运行 40918614215](https://github.com/qvictl/koreader/actions/runs/40918614215)：构建、JUnit、普通/覆盖率 IT、两仓覆盖率 JSON、稳定 overlay 和 Publish，全部成功。
- [插件完整发版运行 40919127472](https://github.com/qvictl/weread.koplugin/actions/runs/40919127472)：完整 UT、真实集成矩阵、覆盖率、同步 persist 与公开包，全部成功，用时 7 分 56 秒。
- 运行日志与 artifacts 的可下载期限由 GitHub 配置决定；本文保存关键数值与精确源码，避免把易过期的本地路径作为唯一记录。

## 5. CI/CD 最终策略

普通 PR/main push 根据完整改动范围，结合 base/head 两版依赖图选择完整 UT 套件；没有可靠映射时保守回退全量。
选择结果记录精确 SHA、改动文件、套件和原因。正常文档改动允许显式 `none`，不会伪造执行结果。
它不是只测修改的几行，也不保证所有改动都会明显缩量。

普通合代码不执行真实集成，只保留所需构建、lint、工具自检和改动行 unit ≥80%。
部分 UT 的整体指标是未测，不能写入全量历史、抬高或降低 baseline，也不会在合入后偷偷再启动全量覆盖率。
发版执行完整 UT、真实 IT 和原有全局 unit/combined 棘轮、日期/模块目标、整批 combined diff ≥90%，
阈值和 0.1 个百分点容忍没有放宽；具体差异及既有上游同步例外以各仓 CONTRIBUTING 为准。

仍通过当前 head 的必需 CI、CodeRabbit 审查与所有 review thread 处理后，由原 gate 合入受保护 main。
本轮没有为赶进度取消 AI gate、绕过分支保护或增加人工审批。
对应改动：KOReader [#43](https://github.com/qvictl/koreader/pull/43)、[#44](https://github.com/qvictl/koreader/pull/44)，
base [#31](https://github.com/qvictl/koreader-base/pull/31)、[#32](https://github.com/qvictl/koreader-base/pull/32)、[#33](https://github.com/qvictl/koreader-base/pull/33)，
插件 [#65](https://github.com/qvictl/weread.koplugin/pull/65)、[#66](https://github.com/qvictl/weread.koplugin/pull/66)、[#68](https://github.com/qvictl/weread.koplugin/pull/68)。

## 6. 发布包与设备状态

| 已核验公开资产 | SHA-256 |
| --- | --- |
| KOReader Kindle HF `ab190e63` | `00f0677a80f820765f2b90a5e2c9360fc18730f10329356698768ece17f226fb` |
| v2026.07.1 Lua overlay | `46e79aafa2a87c0310e9fc792102b566fda739594c4125ff64d652932c0799bc` |
| weread.koplugin v1.6.92 | `579e0659c4f6fa7bbe26b26bc7ce6dcb5fdf98220f94358ce8e8f3b12985adc4` |

HF 的 591 个运行 Lua 文件逐一匹配源码，CRC、公开校验和与 ARM ELF 格式正确。
overlay 核验 49 个载荷和 48 个原始备份：41 个 core 文件来自稳定 `8ff4d8bc`，8 个 base 文件按原构建脚本三方重构。
overlay 的 base 不能整体标成 `kindle-v2026.07.1` 分支；它来自 fork base `cd173c17` 到 `7c4e2f0d` 的补丁应用于 release base `6e4bc81a`。
插件 104 个文件逐一匹配发布 tag 及预验包内容。整个 ZIP 因打包元数据不同可以有不同哈希，不能用本地 ZIP 哈希冒充公开资产哈希。

[KOReader nightly](https://github.com/qvictl/koreader/releases/tag/nightly) 是滚动发布；以后下载必须重新核对 build-info 和校验和，不能假定仍是本文版本。
[插件 v1.6.92](https://github.com/qvictl/weread.koplugin/releases/tag/v1.6.92) 使用版本 tag。

截至最后一次授权 USB 安装记录，Oasis 3 为完整 HF `v2026.10.q1-207-g938e5d5_2026-10-29_kindlehf` 加插件 **1.6.91**。
安装前保存了 868,986,880 B 的完整原目录备份；1155 个程序文件 SHA 核对通过，18 个配置文件 SHA 未变；同步并安全卸载成功。
刚发布的 `241-gab190e6` / 1.6.92 没有在本报告阶段重新装入设备，不能把公开发布等同于真机验收。

插件补做了真实旧 1.6.90/1.6.91 ZIP 到 1.6.92 的升级，检查 104 个目标文件及全部旧 97/101 个备份文件。
新进程重启验证保留设置、加载当前版本并抑制同版本更新；样本中没有缓存 WeRead EPUB，不能声称已验证该恢复子场景。
自动化是在 Linux SDL 环境执行，不等于完整 macOS 人工清单或 Kindle 硬件测试。

## 7. 未闭环事项与后续验收

| 事项 | 当前判断 | 闭环依据 |
| --- | --- | --- |
| 原 811 章整机卡死、OOM/COW 因果 | 有并发、内存与生命周期缓解；没有真机因果证明 | 在明确安装版本下重跑长书，关联 UI、内存、进程和系统日志，保留故障前后对照 |
| Kindle 长书、取消、重开、休眠恢复 | 主机回归已过，真机长期验收未完成 | 用户设备按上述场景试用；不能以主机 200 章结果替代 |
| 低层 Wi-Fi/socket 原因 | 既有报错不足以证明缓存 Wi-Fi 状态是根因 | 先给出可复现消费链再修，不凭日志文本猜原因 |
| 覆盖率 | core/base 全库仍有大量未执行代码；插件有未来模块目标缺口 | 结合确认缺陷和真实调用链补回归，不用镜像实现或空断言堆数字 |
| 其他性能建议 | annotation DB 每操作开销、checkpoint 增量化等尚未全部实现 | 先建立可复现热点、正确性和前后指标，再决定改动 |
| 全局动态缓存预算 | 尚无证据支持增加该框架 | 保留已测出的局部修复及其代价，不将研究建议标为缺陷已修 |

上游插件 PR 是否被 maintainer 接收是另一项状态，不因本 fork 修复完成而自动关闭上游问题。
本报告的完成范围是本轮交付与证据整理；后续工作以明确的复现和验收结果继续推进。
