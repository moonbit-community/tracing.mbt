# 代码审查报告

日期：2026-04-20

本报告整理了当前仓库审查中发现的硬实现 bug 与潜在设计问题。现有测试已执行：`moon test -v`，结果为 `75/75` 通过；下面的问题主要来自边界条件、异常路径和 API 语义检查。

## 硬实现 Bug

### 2. `Baggage` 解析会静默吞掉非法 UTF-8

- 位置：`propagation.mbt:164`，`propagation.mbt:373`
- 问题：百分号解码后的字节最终走的是 `decode_lossy`。像 `%FF` 这类非法 UTF-8 不会报错，而是被替换成损坏字符。
- 影响：
  - 非法 header 会被当成“成功解析”。
  - 值无法 round-trip，排查链路传播问题时会出现隐性数据损坏。
- 建议：改成严格 UTF-8 解码；只要解码失败就返回 `None`。

### 3. `TraceIdAllocator::new_seeded` 存在 off-by-one 边界问题

- 位置：`ids.mbt:261`
- 问题：构造函数允许 `seed == max_int64`，但第一次真正分配时会立刻在 `ids.mbt:269` 触发 `"Trace ID allocator exhausted"`。
- 影响：可以构造出一个“表面合法但第一次使用就崩”的 allocator。
- 建议：构造时直接拒绝这个边界值，或者调整内部计数语义。

## 潜在设计问题

### 4. fanout 没有 subscriber 失败隔离

- 位置：`trace_context.mbt:106`，`trace_context.mbt:121`，`trace_context.mbt:138`，`trace_context.mbt:154`，`trace_context.mbt:296`
- 问题：多个 lane 被顺序调用，但没有任何单 lane 失败隔离。一个 subscriber 抛错，会中断后续 lane，并把异常直接冒泡回业务逻辑。
- 影响：
  - tracing 代码会影响主业务路径。
  - 多 subscriber 场景下，一个实现不稳定的 sink 会拖垮其他 sink。
- 建议：明确策略。常见做法是按 lane 捕获错误、记录失败计数、继续投递其他 lane。

### 5. runtime 的 `unclosed_spans` 更像一次性快照，不是实时状态

- 位置：`jsonl/runtime.mbt:416`，`jsonl/runtime.mbt:690`，`logfmt/runtime.mbt:534`，`logfmt/runtime.mbt:808`
- 问题：`unclosed_spans` 只在 `shutdown` 时更新一次，`stats()` 读到的是上次 shutdown 的结果，不是当前未闭合 span 数。
- 影响：
  - 字段名容易让调用方误以为它是实时指标。
  - 在 runtime 运行期间读取 `stats()`，这个值没有监控意义。
- 建议：要么改名说明它是 shutdown snapshot，要么在运行时同步维护当前值。

## 测试与覆盖缺口

- 传播层基本缺少边界测试，尤其是：
  - 非法 UTF-8 的 baggage 输入
  - 重复/超长/非法 `tracestate`
  - `root_with_parent`、`propagated_span` 的远端 parent 语义
- `Value::to_json_string()` 没覆盖非有限浮点。
- 没有验证 subscriber 抛错时 fanout 的行为。

## 结论

当前仓库的 happy path 和 runtime 并发路径测试比较完整，但传播格式、异常隔离和 JSON 边界语义还有明显风险。优先级建议如下：

1. 先修复非法 JSON 与 baggage 非严格解码。
2. 再明确 fanout 的错误隔离策略。
3. 最后收敛重复字段与 target 推导这两个 API 设计问题。
