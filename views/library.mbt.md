---
moonbit:
  backend: native
---

# MemoryCorridor 阅读页面 v1

页面布局和数据绑定由下面的 MoonBit 声明决定。正文保留在知识文件中。

```mbt check
pub(all) struct CorridorView {
  title : String
  accent : String
  paper : String
  panels : Array[String]
  features : Array[String]
}
pub fn view(title : String, accent : String, paper : String, panels : Array[String], features : Array[String]) -> CorridorView {
  { title, accent, paper, panels, features }
}
pub fn corridor_view() -> CorridorView {
  view("MemoryCorridor", "#315B47", "#F4F1E9", ["catalog","page","sources"], ["search","routing","rich-render","code-format","source-links"])
}
test "visual declaration" {
  assert_eq(corridor_view().panels.length(), 3)
}
```
