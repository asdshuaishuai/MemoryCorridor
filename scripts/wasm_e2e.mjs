import { readFile } from 'node:fs/promises';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { loadCorridor } from '../sdk/wasm.mjs';
const results = [];
const sha256 = text => createHash('sha256').update(text, 'utf8').digest('hex');
const viewText = await readFile(new URL('../views/library.mbt.md', import.meta.url), 'utf8');
const renderPageText = '---\ntype: concept\ntitle: WASM 阅读\nsources: ["raw/wasm.md"]\n---\n浏览器快照正文。\n';
const renderSourceText = '# WASM source\n';
const renderPageEntry = {
  id: 'concepts/wasm-render', path: 'wiki/concepts/wasm-render.md', kind: 'concept', format: 'markdown',
  sha256: sha256(renderPageText), sources: ['raw/wasm.md'], stale: false,
};
const renderSourceEntry = {
  id: 'raw/wasm.md', path: 'raw/wasm.md', kind: 'raw', format: 'markdown',
  sha256: sha256(renderSourceText), sources: [], stale: false,
};
const imageBytes = Buffer.from([1, 2, 3]);
const imageSourceEntry = {
  id: 'raw/tiny.png', path: 'raw/tiny.png', kind: 'raw', format: 'image',
  sha256: sha256(imageBytes), sources: [], stale: false,
};
for (const target of ['wasm', 'wasm-gc']) {
  const bytes = await readFile(new URL(`../_build/${target}/debug/build/wasm/wasm.wasm`, import.meta.url));
  const module = new WebAssembly.Module(bytes);
  const imports = WebAssembly.Module.imports(module);
  if (target === 'wasm') {
    // The service-capable target imports exactly the corridor-host surface;
    // every import must come from that module so the host contract stays closed.
    assert.deepEqual(imports.map(i => `${i.module}.${i.name}`).sort(), [
      'corridor-host.sock_recv', 'corridor-host.sock_send',
      'corridor-host.storage_check', 'corridor-host.storage_list', 'corridor-host.storage_lock',
      'corridor-host.storage_mkdir', 'corridor-host.storage_read', 'corridor-host.storage_remove',
      'corridor-host.storage_unlock', 'corridor-host.storage_write',
    ]);
  } else {
    assert.deepEqual(imports, [], 'the pure wasm-gc face must stay import-free');
  }
  const engine = await loadCorridor(bytes);
  assert(engine.evaluate({op:'tools'}).ok);
  assert(engine.evaluate({op:'page',text:'---\ntype: concept\ntitle: 测试\nsources: ["raw/a.md"]\n---\n正文中文😀'}).ok);
  const space = {id:'test',dimensions:2};
  const vector = engine.evaluate({op:'vectors',space,values:[1,0],records:[{page:'a',sha256:'0'.repeat(64),space,values:[1,0]}]});
  assert.equal(vector.result[0].id, 'a');
  assert.equal(engine.evaluate({op:'vectors',space,values:[0,0],records:[]}).ok,false);
  const graphPage = (id, link, source) => {
    const text = `---\ntype: concept\ntitle: ${id}\nsources: ["${source}"]\ntags: ["graph"]\n---\n${link ? `[[concepts/${link}]]` : '孤立页面'}\n`;
    return {
      entry: { id: `concepts/${id}`, path: `wiki/concepts/${id}.md`, kind: 'concept', format: 'markdown',
        sha256: sha256(text), sources: [source], stale: false }, text,
    };
  };
  const graphPages = [graphPage('a', 'b', 'raw/a.md'), graphPage('b', 'c', 'raw/b.md'), graphPage('c', '', 'raw/c.md')];
  const graph = engine.evaluate({op:'graph', pages:graphPages});
  assert.equal(graph.ok, true, JSON.stringify(graph));
  assert.equal(graph.result.nodes.length, 3);
  const neighbors = engine.evaluate({op:'neighbors', pages:graphPages, id:'concepts/a'});
  assert.deepEqual(neighbors.result, ['concepts/b']);
  const path = engine.evaluate({op:'path', pages:graphPages, from:'concepts/a', to:'concepts/c'});
  assert.deepEqual(path.result, ['concepts/a', 'concepts/b', 'concepts/c']);
  const weightedPath = engine.evaluate({op:'weighted-path', pages:graphPages, from:'concepts/a', to:'concepts/c'});
  assert.deepEqual(weightedPath.result, ['concepts/a', 'concepts/b', 'concepts/c']);
  const insights = engine.evaluate({op:'insights', pages:graphPages});
  assert.equal(insights.ok, true);
  const contextBody = '前言😀 '.repeat(24) + '\n\nNeedle evidence near the end.\n\n' + '尾部 '.repeat(24);
  const contextTextA = `---\ntype: concept\ntitle: Context A\nsources: ["raw/context-a.md"]\n---\n${contextBody}\n`;
  const contextTextB = `---\ntype: concept\ntitle: Context B\nsources: ["raw/context-b.md"]\n---\n${contextBody}\n`;
  const contextPages = [
    { entry: { id:'concepts/context-a', path:'wiki/concepts/context-a.md', kind:'concept', format:'markdown',
        sha256:sha256(contextTextA), sources:['raw/context-a.md'], stale:false },
      text: contextTextA, origin:'keyword' },
    { entry: { id:'concepts/context-b', path:'wiki/concepts/context-b.md', kind:'concept', format:'markdown',
        sha256:sha256(contextTextB), sources:['raw/context-b.md'], stale:false },
      text: contextTextB, origin:'graph' },
  ];
  const context = engine.evaluate({op:'context', candidates:contextPages, query:'needle', budget:180});
  assert.equal(context.ok, true, JSON.stringify(context));
  assert.equal(context.result.budget, 180);
  assert.equal(context.result.offset_unit, 'body_utf8_bytes');
  assert.equal(context.result.estimate_recipe, 'cjk_char_latin_word_v1');
  assert.equal(context.result.estimated_tokens,
    context.result.blocks.reduce((sum, block) => sum + block.estimated_tokens, 0));
  assert.equal(context.result.truncated, context.result.blocks.some(block => block.truncated));
  assert(context.result.used <= 180);
  assert.equal(context.result.blocks.length, 1);
  assert.equal(context.result.blocks[0].duplicates[0].id, 'concepts/context-b');
  const contextSimilar = engine.evaluate({op:'context', candidates:contextPages, query:'needle', budget:180, dedup:'similar'});
  assert.equal(contextSimilar.ok, true, JSON.stringify(contextSimilar));
  assert.equal(contextSimilar.result.strategy, 'similar_body_paragraph_ranked_v2');
  assert.equal(contextSimilar.result.blocks.length, 1);
  assert.deepEqual(contextSimilar.result.similar_duplicates,
    [{owner:'concepts/context-a', duplicates:[{id:'concepts/context-b', path:'wiki/concepts/context-b.md',
      sha256:sha256(contextTextB), sources:['raw/context-b.md'], origin:'graph', similarity:1}]}]);
  const contextEven = engine.evaluate({op:'context', candidates:contextPages, query:'needle', budget:180, spread:'even'});
  assert.equal(contextEven.ok, true, JSON.stringify(contextEven));
  assert.equal(contextEven.result.strategy, 'exact_body_paragraph_even_v2');
  assert.equal(contextEven.result.used, context.result.used);
  assert.equal(engine.evaluate({op:'context', candidates:contextPages, query:'needle', budget:180, dedup:'unknown'}).ok, false);
  assert.equal(engine.evaluate({op:'context', candidates:contextPages, query:'needle', budget:180, spread:'unknown'}).ok, false);
  assert.equal(engine.evaluate({op:'graph', pages:[{...graphPages[0], entry:{...graphPages[0].entry, sha256:'0'.repeat(64)}}]}).ok, false);
  assert.equal(engine.evaluate({op:'catalog',text:'arbitrary code'}).ok,false);
  assert.equal(engine.evaluate({op:'page',text:'bad',unexpected:true}).ok,false);
  const body = 'background😀 '.repeat(200) + '\n\nNeedle evidence near the end.\n\n' + 'tail '.repeat(200);
  const search = engine.evaluate({op:'search', query:'needle', documents:[{
    id:'a',title:'a',body,title_terms:['a'],body_terms:body.toLowerCase().match(/[a-z]+/g),
  }]});
  assert(search.ok, JSON.stringify(search));
  assert(search.result[0].excerpt.includes('Needle evidence'));
  assert(Buffer.byteLength(search.result[0].excerpt, 'utf8') <= 360);
  const edge = 'a'.repeat(359) + '😀';
  const unicode = engine.evaluate({op:'search',query:'a',documents:[{
    id:'a',title:'a',body:edge,title_terms:['a'],body_terms:['a'.repeat(359)],
  }]});
  assert.equal(unicode.result[0].excerpt, 'a'.repeat(359));
  const parsedView = engine.evaluate({op:'view', text:viewText});
  assert.equal(parsedView.ok, true, JSON.stringify(parsedView));
  assert.equal(engine.evaluate({op:'view', text:viewText + 'extra code'}).ok, false);
  assert.equal(engine.evaluate({op:'view', text:viewText + '\nProse after the block.\n'}).ok, true);
  const rendered = engine.evaluate({op:'render-view', text:viewText,
    pages:[{entry:renderPageEntry,text:renderPageText}],
    sources:[{entry:renderSourceEntry,text:renderSourceText,image:''}],
    fingerprint:'f'.repeat(64)});
  assert.equal(rendered.ok, true, JSON.stringify(rendered));
  assert.match(rendered.result.html, /<!doctype html>/i);
  assert.match(rendered.result.html, /WASM 阅读/);
  assert.equal(rendered.result.pages, 1);
  assert.equal(rendered.result.sources, 1);
  const imageRendered = engine.evaluate({op:'render-view', text:viewText, pages:[],
    sources:[{entry:imageSourceEntry, text:'host supplied text must not become authoritative', image:'data:image/png;base64,AQID'}],
    fingerprint:'f'.repeat(64)});
  assert.equal(imageRendered.ok, true, JSON.stringify(imageRendered));
  const tamperedImage = engine.evaluate({op:'render-view', text:viewText, pages:[],
    sources:[{entry:imageSourceEntry, text:'', image:'data:image/png;base64,BAUG'}], fingerprint:'f'.repeat(64)});
  assert.equal(tamperedImage.ok, false);
  assert.equal(engine.evaluate({op:'render-view', text:viewText, pages:[], sources:[], fingerprint:'bad'}).ok, false);
  assert.equal(engine.evaluate({op:'view', text:viewText, extra:true}).ok, false);
  results.push({tools:engine.evaluate({op:'tools'}),search,unicode,context});
}
assert.deepEqual(results[0], results[1]);
console.log('classic WASM and WASM-GC: integer UTF-8 ABI, closed corridor-host import surface on the service target, Unicode, query-aware excerpts, vectors, visual snapshot rendering, failures and dictionary parity passed');
