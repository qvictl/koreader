# 单元测试覆盖率提升计划

本 fork 的目标是 Kindle 上的**稳定性、内存、响应速度**。单元测试（busted，`spec/unit/`；koreader-base 为其 `spec/unit/`）是最便宜、最快的回归防线，因此本计划只关注**单元测试**覆盖率（不含模拟器集成测试）。门禁规则与工具见 [CONTRIBUTING.md](../CONTRIBUTING.md)、[`.ci/coverage_config.lua`](../.ci/coverage_config.lua)、[`.ci/fork/coverage.lua`](../.ci/fork/coverage.lua)。

## 现状（2026-10-27，`main` @ 76b8c107f，koreader-base `main` @ e861fcf5）

| 范围 | 单元测试 | 单元 + 集成 |
|---|---:|---:|
| `frontend/` + `plugins/`（491 个文件） | **31.47%**（29309 / 93167 行） | 37.70%（35436 / 93993） |
| fork 自有模块（`owned-modules.txt`） | – | 88.5%（最低：readerdictionary 85.1%） |
| koreader-base `ffi/`（不含 `*_h.lua`） | **28.62%**（3667 / 12812） | 35.62%（4586 / 12875） |

数据来自 CI 产物（`unit-coverage`、`integration-coverage`）；本地复现方法见文末。

## 里程碑

| 日期 | `frontend/`+`plugins/` 单元 | koreader-base `ffi/` 单元 | fork 自有模块（单元+集成，每个模块） |
|---|---:|---:|---:|
| 2026-10-27（基线） | 31.47% | 28.62% | ≥ 80%（已生效） |
| 2026-11-24 | ≥ **36.47%**（+5 pp） | ≥ **33.62%**（+5 pp） | ≥ 85% |
| 2026-12-22 | ≥ **41.47%**（+10 pp） | ≥ **38.62%**（+10 pp） | ≥ 90% |

- 单元覆盖率目标写在两个仓库的 `.ci/coverage_config.lua` 的 `overall.unit` 中，由 Coverage 检查的 **`unit` 门禁**执行：到期前只报告，**到期当天起阻塞 PR**（upstream 同步 PR 除外，与 owned 门禁同一规则）。引擎自测：`.ci/fork/coverage_test.sh`（每次 Coverage 运行前执行）。
- 已有门禁不变：diff 覆盖率（单元 ≥ 80%，单元+集成 ≥ 90%）、整体覆盖率 ratchet（阻塞）、单元+集成整体覆盖率的 +5/+10 pp 目标（仅报告）。ratchet 与 PR 所基于的 main 提交（CI 所测 merge 提交的第一个父提交）记录的覆盖率比较，而不是与 main 最新的覆盖率比较；该提交没有记录时取其最近的有记录祖先。因此并行的 PR 不必逐个合入。
- 1 pp ≈ 930 行（frontend+plugins）/ 128 行（ffi）。+10 pp 意味着两个月内新增约 9300 行被单元测试执行的代码。

## 优先级排序

排序分 = 未被单元测试覆盖的行数 × 相关度权重。权重：**3** = 直接关系 Kindle 稳定性/内存/响应（uimanager、trapper、device/kindle、readerui、readerrolling/paging、credocument、cache/doccache、networkmgr、readerdictionary/dictquicklookup、readerhighlight、screensaver、autosuspend、readerfooter、filemanager 核心、input/gesturedetector、ffi/util 等）；**2** = 阅读器/文件管理器其他模块、通用控件、常用插件；**1** = 其他；**0.5** = 非 Kindle 平台代码、Kindle 上少用的插件、键盘布局数据。

### 按目录（前 20）

| 目录 | 可执行行 | 单元覆盖 | 未覆盖 | 单元+集成 | 排序分 |
|---|---:|---:|---:|---:|---:|
| `frontend/ui/widget/` | 19560 | 33.1% | 13081 | 35.6% | 27012 |
| `frontend/apps/reader/modules/` | 16616 | 39.3% | 10094 | 42.4% | 24433 |
| `frontend/apps/filemanager/` | 4307 | 17.2% | 3567 | 18.6% | 8010 |
| `frontend/ui/` | 4417 | 43.6% | 2493 | 47.9% | 5377 |
| `plugins/statistics.koplugin/` | 2348 | 0.0% | 2348 | 15.4% | 4696 |
| `frontend/` | 4837 | 59.9% | 1940 | 62.8% | 4416 |
| `plugins/coverbrowser.koplugin/` | 1821 | 0.0% | 1821 | 45.7% | 3642 |
| `frontend/device/` | 2129 | 41.4% | 1248 | 41.8% | 3164 |
| `frontend/ui/elements/` | 1488 | 3.4% | 1438 | 3.4% | 2876 |
| `frontend/device/kindle/` | 1356 | 39.1% | 826 | 39.1% | 2478 |
| `frontend/document/` | 3162 | 73.3% | 844 | 73.5% | 2121 |
| `frontend/ui/network/` | 825 | 19.4% | 665 | 19.4% | 1995 |
| `frontend/ui/data/keyboardlayouts/` | 3146 | 5.9% | 2959 | 5.9% | 1480 |
| `plugins/kosync.koplugin/` | 716 | 32.5% | 483 | 37.7% | 1449 |
| `frontend/ui/widget/container/` | 1088 | 39.2% | 662 | 48.8% | 1324 |
| `plugins/vocabbuilder.koplugin/` | 1293 | 0.0% | 1293 | 16.2% | 1293 |
| `frontend/ui/data/` | 2398 | 58.9% | 986 | 72.5% | 1289 |
| `frontend/device/generic/` | 750 | 52.9% | 353 | 54.9% | 1059 |
| `plugins/autosuspend.koplugin/` | 337 | 36.2% | 215 | 40.6% | 641 |
| `plugins/cloudstorage.koplugin/` | 1264 | 0.0% | 1264 | 14.0% | 632 |

### 按文件（前 30）

| 文件 | 可执行行 | 单元覆盖 | 未覆盖 | 单元+集成 | 权重 | 排序分 |
|---|---:|---:|---:|---:|---:|---:|
| `frontend/apps/reader/modules/readerhighlight.lua` | 1614 | 34.4% | 1058 | 34.6% | 3 | 3174 |
| `frontend/apps/reader/modules/readerdictionary.lua` | 1284 | 24.1% | 974 | 51.0% | 3 | 2922 |
| `plugins/statistics.koplugin/main.lua` | 1405 | 0.0% | 1405 | 22.6% | 2 | 2810 |
| `frontend/ui/widget/dictquicklookup.lua` | 1287 | 40.3% | 768 | 45.3% | 3 | 2304 |
| `frontend/device/kindle/device.lua` | 1162 | 38.3% | 717 | 38.3% | 3 | 2151 |
| `frontend/apps/reader/modules/readerfooter.lua` | 1530 | 54.4% | 697 | 54.8% | 3 | 2091 |
| `frontend/ui/widget/bookmapwidget.lua` | 1024 | 0.0% | 1024 | 0.0% | 2 | 2048 |
| `frontend/apps/filemanager/filemanager.lua` | 883 | 24.7% | 665 | 29.2% | 3 | 1995 |
| `frontend/apps/reader/modules/readerrolling.lua` | 944 | 38.2% | 583 | 39.9% | 3 | 1749 |
| `frontend/ui/widget/pagebrowserwidget.lua` | 849 | 0.0% | 849 | 0.0% | 2 | 1698 |
| `frontend/apps/filemanager/filemanagercollection.lua` | 859 | 9.3% | 779 | 9.3% | 2 | 1558 |
| `frontend/device/input.lua` | 915 | 44.3% | 510 | 45.0% | 3 | 1530 |
| `frontend/ui/widget/textboxwidget.lua` | 1391 | 45.6% | 757 | 46.4% | 2 | 1514 |
| `plugins/statistics.koplugin/calendarview.lua` | 730 | 0.0% | 730 | 0.0% | 2 | 1460 |
| `frontend/ui/widget/configdialog.lua` | 779 | 9.8% | 703 | 9.8% | 2 | 1406 |
| `frontend/ui/widget/touchmenu.lua` | 678 | 0.0% | 678 | 0.0% | 2 | 1356 |
| `frontend/ui/network/manager.lua` | 562 | 20.8% | 445 | 20.8% | 3 | 1335 |
| `plugins/kosync.koplugin/main.lua` | 510 | 18.6% | 415 | 25.1% | 3 | 1245 |
| `frontend/apps/filemanager/filemanagerbookinfo.lua` | 707 | 12.2% | 621 | 14.1% | 2 | 1242 |
| `frontend/device/gesturedetector.lua` | 707 | 42.4% | 407 | 42.4% | 3 | 1221 |
| `frontend/apps/reader/modules/readerkeyselection.lua` | 731 | 16.6% | 610 | 16.6% | 2 | 1220 |
| `frontend/ui/wikipedia.lua` | 626 | 8.9% | 570 | 8.9% | 2 | 1140 |
| `frontend/apps/reader/modules/readerbookmark.lua` | 858 | 35.5% | 553 | 35.5% | 2 | 1106 |
| `plugins/coverbrowser.koplugin/bookinfomanager.lua` | 547 | 0.0% | 547 | 47.8% | 2 | 1094 |
| `frontend/apps/reader/modules/readerfont.lua` | 510 | 32.2% | 346 | 49.1% | 3 | 1038 |
| `frontend/dispatcher.lua` | 771 | 34.6% | 504 | 39.9% | 2 | 1008 |
| `plugins/vocabbuilder.koplugin/main.lua` | 1004 | 0.0% | 1004 | 16.0% | 1 | 1004 |
| `frontend/apps/reader/modules/readerlink.lua` | 711 | 29.7% | 500 | 31.4% | 2 | 1000 |
| `frontend/apps/reader/modules/readerpaging.lua` | 753 | 58.0% | 316 | 58.0% | 3 | 948 |
| `frontend/ui/widget/bookmarkbrowser.lua` | 473 | 0.0% | 473 | 0.0% | 2 | 946 |

### koreader-base `ffi/`（前 16）

| 文件 | 可执行行 | 单元覆盖 | 未覆盖 | 单元+集成 | 权重 | 排序分 |
|---|---:|---:|---:|---:|---:|---:|
| `ffi/sha2.lua` | 2804 | 12.2% | 2462 | 12.2% | 1 | 2462 |
| `ffi/framebuffer_mxcfb.lua` | 607 | 0.0% | 607 | 0.0% | 3 | 1821 |
| `ffi/blitbuffer.lua` | 1579 | 42.6% | 907 | 48.8% | 2 | 1814 |
| `ffi/kotasync.lua` | 414 | 0.0% | 414 | 0.0% | 2 | 828 |
| `ffi/rtc.lua` | 199 | 0.0% | 199 | 0.0% | 3 | 597 |
| `ffi/bitser.lua` | 286 | 0.0% | 286 | 11.1% | 2 | 572 |
| `ffi/util.lua` | 372 | 51.1% | 182 | 72.7% | 3 | 546 |
| `ffi/archiver.lua` | 236 | 0.0% | 236 | 14.1% | 2 | 472 |
| `ffi/framebuffer.lua` | 244 | 42.6% | 140 | 52.9% | 3 | 420 |
| `ffi/lru.lua` | 137 | 0.0% | 137 | 69.1% | 3 | 411 |
| `ffi/mupdf.lua` | 625 | 67.8% | 201 | 67.8% | 2 | 402 |
| `ffi/netinfo.lua` | 129 | 0.0% | 129 | 10.9% | 3 | 387 |
| `ffi/SDL3.lua` | 484 | 0.0% | 484 | 38.3% | 0.5 | 242 |
| `ffi/serpent.lua` | 118 | 0.0% | 118 | 69.4% | 2 | 236 |
| `ffi/pic.lua` | 207 | 46.4% | 111 | 46.4% | 2 | 222 |
| `ffi/freetype.lua` | 133 | 39.8% | 80 | 92.0% | 2 | 160 |

`sha2.lua` 行数多但大部分是非 LuaJIT 分支，性价比低，放到最后。

## 批次

每个 PR 只做一个领域、只加测试（不改产品代码），必须通过 Lint / Build and unit tests / Integration tests / Coverage / Tests policy 后合并。测试要断言行为和边界，重点是曾导致卡死的失败路径。发现真实 bug：另开小 PR（先失败的测试 + 最小修复）。

| 批次 | 时间 | 领域（PR） | 预期新增覆盖行 |
|---|---|---|---:|
| 1 | 2026-10-27 起 | 词典（readerdictionary / dictquicklookup，fork 自有行 ≥ 90%）；Trapper 与子进程（含 ffi/util 自有函数）；NetworkMgr 超时/DNS；Kindle 设备与挂起/恢复（device/kindle、powerd、autosuspend）；阅读核心（readerhighlight / readerrolling / readerpaging）；readerfooter / filemanager / cache；input 批处理与手势；statistics 插件；base：ffi util / lru / rtc / 序列化 | ≈ 3000（+3 pp）；base ≈ 650（+5 pp） |
| 2 | 至 2026-11-24 | screensaver、readerui、credocument、readerview、readerbookmark、readertoc、readerlink、readersearch、kosync、dispatcher、touchmenu、configdialog、textboxwidget、inputtext/inputdialog；base：blitbuffer、framebuffer_mxcfb（Kindle 刷新）、kotasync | ≈ 2000（累计 ≥ +5 pp） |
| 3 | 至 2026-12-22 | bookmapwidget、pagebrowserwidget、filemanagercollection / bookinfo、coverbrowser、vocabbuilder、calendarview、wikipedia、readerkeyselection、readerstyletweak；uimanager 剩余路径；base：archiver、netinfo、mupdf、pic | ≈ 4500（累计 ≥ +10 pp） |

进度以 `coverage` 分支的 [HISTORY.md](../../../blob/coverage/HISTORY.md)（新增“Unit tests only”列）和每个 PR 的 Coverage 评论为准。

## 本地复现

CI 的计算方式：`fork_emulator.yml` 在 `koreader/kobase` 镜像里构建模拟器并以 luacov 运行前端单元测试（`make coverage-run`，每个 spec 一个进程），产出 `unit.stats.out`；`.ci/fork/coverage.sh` 用模拟器自带的 luajit + luacov 运行 `coverage.lua` 计算各门禁。本地无需重新构建：

1. 下载 `main` 最近一次 CI 的 `koreader-emulator-x86_64`、`unit-coverage`、`integration-coverage` 产物（`gh run download <run> -n <name>`）。
2. 解包模拟器，把 `frontend/`、`plugins/`、顶层 `*.lua`、`.luacov` 换成指向工作树的符号链接，`spec/front` → 工作树的 `spec/`，`spec/front/unit/data` → `test` 子模块；需要 `libSDL3.so.0`（放进 `libs/`）。
3. 每个 spec 单独进程运行：`KO_HOME=spec/run/<name> ./luajit -e 'require "busted.runner" {standalone = false}' /dev/null --config-file=spec/config.lua --helper=spec/helper.lua --run=front --coverage spec/front/unit/<name>_spec.lua`（`LUA_PATH`/`LUA_CPATH` 同 `spec/runtests`），再用 `tools/merge_luacov_stats.lua` 合并。
4. 用 `coverage.lua`（`--unit`/`--integration`）计算门禁，或逐文件统计。本地结果与 CI 相差 < 0.05 pp。
