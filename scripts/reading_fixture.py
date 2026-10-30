#!/usr/bin/env python3
"""Create a real vault for the repeatable rich-reader browser checks.

With --with-map the fixture also renders the graph-enabled view and runs the
headless-Chrome CDP check (scripts/reading_map_browser_cdp.py, pure Python
standard library) when a Chrome binary is available; otherwise it prints an
explicit skip line.
"""
import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

REPO = Path(__file__).resolve().parents[1]
arguments = [arg for arg in sys.argv[1:] if not arg.startswith("--")]
with_map = "--with-map" in sys.argv[1:]
ROOT = Path(arguments[0] if arguments else '/tmp/corridor-rich-reading').resolve()
ROOT.mkdir(parents=True, exist_ok=True)
EXE = REPO / '_build/native/debug/build/cli/cli.exe'


def call(op, **fields):
    result = subprocess.run([str(EXE)], input=json.dumps({'op': op, 'vault': str(ROOT), **fields})+'\n', capture_output=True, text=True, check=True, timeout=30)
    value = json.loads(result.stdout)
    assert value['ok'], value
    return value['result']


if (ROOT / 'index.mbt.md').exists():
    raise SystemExit('fixture requires a new directory')
call('init', purpose='验证真实 Markdown / HTML 呈现以及代码排版。')
markdown = '''# 渲染验收

**加粗文本**，*强调文本*，~~删除文本~~，以及 `inline()`。

> 引用段落。[[concepts/rich|返回本页]]

1. 第一项
2. 第二项
   - 嵌套条目

| 语言 | 用途 |
| --- | --- |
| MoonBit | 核心 |
| JavaScript | 浏览器适配 |

[跳转标题](#代码示例) · [原始 HTML](/raw/sample.html)

![本地证据](/raw/pixel.png)

## 代码示例

```mbt check
pub fn add(a : Int, b : Int) -> Int {
  // MoonBit 高亮
  a + b
}
```

```javascript
const answer={value:42,list:[1,2]};function greet(name){return "hello "+name;}
```

```json
{"nested":{"count":2},"items":[true,false]}
```

```python
def greet(name):
    # preserve indentation
    return f"Hello {name}"
```

```unknown-language
<tag>untouched</tag>
```

<section><h3>HTML 片段</h3><p>段落中的 <strong>真实 HTML</strong>。</p></section>
<script>window.READER_ATTACKED=true</script>
<img src=x onerror="window.READER_ATTACKED=true">
<a href="javascript:window.READER_ATTACKED=true">危险地址</a>
<form id="query"><input name="action"></form>
<article class="reading"><section class="rich-document">不能干扰宿主导航</section></article>
<svg><a href="javascript:window.READER_ATTACKED=true">svg</a></svg>

```html
<script>window.CODE_EXECUTED=true</script>
<div class="example">代码中的 HTML</div>
```
'''
(ROOT / 'raw/article.md').write_text(markdown)
(ROOT / 'raw/sample.html').write_text('''<!doctype html><html><head><style>
body{font-family:system-ui;background:#eaf3ff;padding:24px}h1{color:#245c9a}
</style></head><body><h1>独立 HTML 页面</h1><p><strong>保留样式</strong>与段落。</p>
<table><tr><th>类型</th><th>值</th></tr><tr><td>HTML</td><td>已渲染</td></tr></table>
<img src="pixel.png" alt="frame image"><script>parent.READER_ATTACKED=true</script>
<img src=x onerror="parent.READER_ATTACKED=true"><iframe srcdoc="nested"></iframe>
<a href="javascript:alert(1)">unsafe</a></body></html>''')
(ROOT / 'raw/example.py').write_text('def double(value):\n    return value * 2\n')
(ROOT / 'raw/pixel.png').write_bytes(base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aV1cAAAAASUVORK5CYII='))
call('scan')
for order in call('plan'):
    call('context', order=order['id'])
    call('analysis-submit', order=order['id'], analysis={'entities': [], 'concepts': [], 'conflicts': [], 'summary': '展示验证'})
    pages = []
    if order['source'] == 'raw/article.md':
        staged = 'staging/'+order['id']+'/rich.md'
        (ROOT / staged).write_text('---\ntype: concept\ntitle: 富文本与代码\nsources: ["raw/article.md"]\n---\n'+markdown)
        second = 'staging/'+order['id']+'/graph.md'
        (ROOT / second).write_text('---\ntype: concept\ntitle: 关系快照\nsources: ["raw/article.md"]\n---\n'
                                   '本页引用 [[concepts/rich]]，用于验证确定性快照图与节点跳转。\n')
        sibling = 'staging/'+order['id']+'/sibling.md'
        (ROOT / sibling).write_text('---\ntype: concept\ntitle: 并列来源\nsources: ["raw/article.md"]\n---\n'
                                   '本页与其余页面共享同一来源，用于验证共同来源虚线边。\n')
        pages = [{'id': 'concepts/rich', 'path': 'wiki/concepts/rich.md', 'staged': staged},
                 {'id': 'concepts/map', 'path': 'wiki/concepts/map.md', 'staged': second},
                 {'id': 'concepts/sibling', 'path': 'wiki/concepts/sibling.md', 'staged': sibling}]
    call('commit', order=order['id'], pages=pages, at='2026-10-16')
call('view-init')
default_result = call('render-view')
assert default_result['pages'] == 7 and default_result['sources'] == 4, default_result
default_html = (ROOT / default_result['output']).read_bytes()
library_source = (ROOT / 'views/library.mbt.md').read_text()
map_source = library_source.replace('["catalog","page","sources"]',
                                    '["catalog","page","graph","insights","sources"]')
assert map_source != library_source
(ROOT / 'views/map.mbt.md').write_text(map_source)
map_result = call('render-view', view='views/map.mbt.md')
map_html = (ROOT / map_result['output']).read_text()
assert "svg class='graph-map'" in map_html and "class='graph-edge'" in map_html, 'graph map missing'
assert "graph-edge graph-shared" in map_html, 'shared-source edges missing'
assert "#p-" in map_html
call('render-view')
assert (ROOT / default_result['output']).read_bytes() == default_html, 'default view output changed'
call('rebuild')
call('verify')
if with_map:
    import tempfile
    with tempfile.TemporaryDirectory(prefix='corridor-map-view-') as work:
        map_artifact = Path(work) / 'map-viewer.html'
        map_artifact.write_text(map_html)
        chrome = next((candidate for candidate in [
            os.environ.get('CHROME_BINARY'),
            '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
            shutil.which('google-chrome'),
            shutil.which('chromium'),
        ] if candidate and Path(candidate).exists()), None)
        if chrome is None:
            print('map reader browser check: skipped (no Chrome binary found; set CHROME_BINARY)')
        else:
            run = subprocess.run([sys.executable, str(REPO / 'scripts/reading_map_browser_cdp.py'),
                                  map_artifact.as_uri(), chrome], capture_output=True, text=True, timeout=120)
            if run.returncode != 0:
                raise SystemExit('map reader browser check failed:\n' + run.stdout + run.stderr)
            print(run.stdout.strip())
print(ROOT / default_result['output'])
