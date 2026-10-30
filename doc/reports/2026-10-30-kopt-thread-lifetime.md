# PDF 后台 reflow context 的线程生命周期（2026-10-30）

CI 在真实 cache-pressure 清理测试中出现 glibc heap consolidation abort，另一次在用例通过后退出时出现 SIGSEGV。日志证明发生原生崩溃；结合对应源码确认存在生命周期窗口，但没有完整 native 调用栈，尚不能确定两次崩溃的精确因果；没有通过反复重试将失败视作已解决，也没有运行旧代码的并发释放触发器。

依赖保持为 koreader-base `7c4e2f0d81afafb8a19dfa2a28ec2df461962272`，它使用 libk2pdfopt `64aa9ccfcd55921c596458cb8a7197339d5f32c3`。
[该版本 native 实现](https://github.com/koreader/libk2pdfopt/blob/64aa9ccfcd55921c596458cb8a7197339d5f32c3/lib/koptreflow.c#L124) 提前清除 `precache`，随后仍写 context 的 rectmaps、BOXA 和 NUMA，并释放 source bitmap。仅轮询 `precache` 不保证消费者、序列化和析构看到的是已经完成的 context。

本修复在 core Lua 层为每个后台 context 保留 joinable pthread 的数组句柄及创建进程 PID。消费、序列化和显式释放前执行真实 `pthread_join`；重复等待和释放保持幂等。context 的 GC finalizer 直接捕获不引用 context 的独立 worker 记录，避免弱表条目提前消失或闭包保活；因此缓存拒绝、插入异常和调用者丢引用也能先 join 再析构。线程库不可用、属性初始化失败或线程创建失败均改为同步 reflow。

fork 子进程拒绝消费父进程尚未 join 的 context；父进程已 join 或同步完成的 context 仍可读取，不 join 父线程，也不析构其尚在修改的 native buffer 快照；继承的分配由子进程退出统一回收。缓存逐出直接进入释放路径，避免消费等待提前抛错阻断逐出；逐出这些已跟踪的后台 context 时，子进程也不代父线程修改 CPU 配置。正常进程发生 join 错误时拒绝消费和释放；GC 无法 join 则记录错误并保留 context，后续 reaping 逐项重试回收，单个错误不阻止其他 context 回收或新任务启动；仍有未回收 owner 时，新页面同步 reflow，避免继续增加异步故障；回收成功后恢复后台工作，每个 owner 的释放错误只记录一次。这是不可恢复 POSIX 错误下的显式安全隔离，不能把仍可能被 native 使用的内存强行释放。

安全负例只使用模拟 pthread 和 Lua 断言，不运行 native worker：覆盖提前置零仍须 join、延迟写 thread 数组、GC/重复释放、缓存拒绝与异常、消费/序列化边界、启动失败、join 错误隔离与恢复、fake PID 变化。修复后真实 native cache-pressure 单测 3/3 通过；完整 ReaderUI 场景 `28_cache_pressure` 26/26 检查通过，确认两个真实 native worker 均已 join。

本地原生验证复用成功 CI 的 a2c7697 模拟器产物及相同 base SHA，通过启动注入加载本工作树的 Lua；没有改写只读 runtime，也未重新编译 native。第一次场景运行曾因启动注入被覆盖而误用了旧 cache Lua，修正注入后再次运行通过；第一次结果保留在本地证据目录。模拟器验证不代表 Kindle 真机验收。

Windows 保留原有 libwinpthread 路径；进程标识显式使用 Windows CRT 的 [`_getpid`](https://learn.microsoft.com/en-us/cpp/c-runtime-library/reference/getpid)，不会假定 POSIX `getpid` 符号存在。该分支有 fake Windows API 测试，主机未执行 Windows 原生验证。

首轮 PR CI 的真实 KOPT、cache-pressure 和新生命周期套件均通过；唯一失败是既有 cache-memorypressure 合成测试仍通过拦截 `usleep` 模拟线程完成。它已改为模拟 join 边界，仍单独验证 busy context 的等待次数和旧压力回收范围，目标套件 9/9 通过；该断言失败与此前 native 崩溃分开记录。

修正生命周期后的 CI 另遇既有 WakeupMgr 单测跨秒：预期 epoch 与 addTask 分别读取实时时钟，差 1 秒后导致共享队列断言级联失败。仅在该套件 setup 固定 os.time 快照并在 teardown 还原，生产 RTC/队列逻辑及原断言均未改。安全注入第 4 次 RTC 换算时底层时钟加 1 秒，旧套件 6/8 失败、修后 8/8 通过；这是 CI 测试时钟修复，不作为新产品缺陷。
