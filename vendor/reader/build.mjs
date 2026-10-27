// Reproducible embedding only. Owned browser behavior belongs in visual/.
import { build } from 'esbuild';
import { readFile, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
const result = await build({
  stdin: { contents: `
    import MarkdownIt from 'markdown-it';
    import DOMPurify from 'dompurify';
    import hljs from 'highlight.js';
    import * as prettier from 'prettier/standalone';
    import * as babel from 'prettier/plugins/babel';
    import * as estree from 'prettier/plugins/estree';
    import * as typescript from 'prettier/plugins/typescript';
    import * as html from 'prettier/plugins/html';
    import * as postcss from 'prettier/plugins/postcss';
    import * as markdown from 'prettier/plugins/markdown';
    import * as yaml from 'prettier/plugins/yaml';
    window.CorridorLibraries = { MarkdownIt, DOMPurify, hljs, prettier,
      plugins: [babel, estree, typescript, html, postcss, markdown, yaml] };
  `, resolveDir: process.cwd() },
  bundle: true, minify: true, write: false, format: 'iife', target: 'es2020', legalComments: 'inline', lineLimit: 8000
});
const js = result.outputFiles[0].text.replace(/<\/script/gi, '<\\/script');
// ASCII chunks avoid compiler column limits even for one huge JS string token.
const encoded=Buffer.from(js).toString('base64');
const chunks=encoded.match(/.{1,12000}/g).map(chunk=>'    '+JSON.stringify(chunk)+',');
await writeFile('libraries.mbt', '// Generated third-party embedding; npm ci && npm run build.\n'
  + 'pub fn javascript() -> String {\n  let encoded = [\n' + chunks.join('\n')
  + '\n  ].join("")\n  @utf8.decode_lossy(@base64.decode_lossy(encoded))\n}\n');
const packages = JSON.parse(await readFile('package-lock.json', 'utf8')).packages;
const rows = Object.entries(packages).filter(([name]) => name.startsWith('node_modules/')).map(([name, p]) => ({
  package: name.slice(13), version: p.version, integrity: p.integrity, license: p.license, build_only: !!p.dev
}));
await writeFile('provenance.json', JSON.stringify({
  generated: 'libraries.mbt', javascript_sha256: createHash('sha256').update(js).digest('hex'), dependencies: rows
}, null, 2) + '\n');
const notices=[];
for (const row of rows.filter(row=>!row.build_only)) {
  const name=row.package; let license;
  for (const filename of ['LICENSE','LICENSE.md','LICENSE.txt','LICENSE-MIT.txt']) {
    try { license=await readFile('node_modules/'+name+'/'+filename,'utf8'); break; }
    catch (error) { if (error.code!=='ENOENT') throw error; }
  }
  if (!license) throw new Error('License missing: '+name);
  await writeFile('../../licenses/' + name.replaceAll('/','-') + '.txt', license);
  notices.push({package:name,version:row.version,license});
}
const noticeText=JSON.stringify(notices).replaceAll('<','\\u003c').replaceAll('>','\\u003e');
const notice64=Buffer.from(noticeText).toString('base64').match(/.{1,12000}/g);
await writeFile('notices.mbt','// Generated third-party notices; see build.mjs.\npub fn notices() -> String {\n  let encoded = [\n'
  + notice64.map(chunk=>'    '+JSON.stringify(chunk)+',').join('\n') + '\n  ].join("")\n  @utf8.decode_lossy(@base64.decode_lossy(encoded))\n}\n');
