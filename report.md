# 代码审查报告

日期：2026-05-25

本报告整理了当前仓库审查中发现的硬实现 bug 与潜在设计问题，并记录本轮修复状态。问题主要来自边界条件、异常路径和 API 语义检查。

## 潜在设计问题

### fanout 没有 subscriber 失败隔离

- 位置：`trace_context.mbt:106`，`trace_context.mbt:121`，`trace_context.mbt:138`，`trace_context.mbt:154`，`trace_context.mbt:296`
- 问题：多个 lane 被顺序调用，但没有任何单 lane 失败隔离。一个 subscriber 抛错，会中断后续 lane，并把异常直接冒泡回业务逻辑。
- 影响：
  - tracing 代码会影响主业务路径。
  - 多 subscriber 场景下，一个实现不稳定的 sink 会拖垮其他 sink。
- 当前策略：本轮不改变 fanout 行为。subscriber 抛错是否应隔离属于 API 策略问题，需要先设计 fallible subscriber 或明确文档约束。

## 测试与覆盖缺口

- 仍未验证 subscriber 抛错时 fanout 的行为；该项等待 API 策略明确后再补。

