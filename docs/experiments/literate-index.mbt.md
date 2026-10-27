---
moonbit:
  backend: native
---

# 文学化索引编译能力实验

这是编译器能力实验，不是已经实现的 MemoryCorridor 索引格式。
`wiki/missing.md` 故意不存在，用于区分代码类型检查和外部文件验证。
检查和测试应在同一受检代码块中验证本例所需的定义作用域。

```mbt check
fn fixture_paths() -> Array[String] {
  ["wiki/missing.md"]
}

test "catalog declaration shape" {
  assert_eq(fixture_paths().length(), 1)
  assert_eq(fixture_paths()[0], "wiki/missing.md")
}
```
