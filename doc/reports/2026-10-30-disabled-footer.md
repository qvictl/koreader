# 禁用页脚后的目录重置崩溃（2026-10-30）

来源：[上游问题](https://github.com/koreader/koreader/issues/16202) 与
[ClimbTheWorld 提出的生命周期修复](https://github.com/koreader/koreader/pull/16203)，
对应候选提交 `eb54dba314ff7257a770d28b648d7ffcee7b8c64`。

`footer.disabled=true` 会在创建进度条前结束初始化，但目录重置仍调用 `setTocMarkers(true)`。
本轮核对时该路径仍然存在。本变更采用与既有禁用方法一致的空操作，保留启用页脚的原有行为。

新增真实 ReaderUI 单测：修前捕获 nil 进度条错误，修后安全处理目录重置且保持隐藏。
真实模拟器场景 `29_disabled_footer` 还会打开 EPUB、分发目录重置、执行字体大小变更，
验证重排后页数更新且不创建隐藏进度条。主机验证不等于 Kindle 真机验收。
