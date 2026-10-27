fn rich_runtime() -> String {
  let js =
  #|const { MarkdownIt, DOMPurify, hljs, prettier, plugins } = window.CorridorLibraries;
  #|const richRendering = (snapshot.features || []).includes('rich-render');
  #|const codeFormatting = (snapshot.features || []).includes('code-format');
  #|hljs.registerLanguage('moonbit', h => ({ name:'MoonBit', aliases:['mbt'], keywords:{
  #|  keyword:'pub priv fn let mut struct enum trait impl derive type typealias suberror raise catch try match if else for while loop break continue return test async extern with as is guard defer const readonly all',
  #|  literal:'true false None Some', type:'Int Int64 UInt UInt64 Double Float Bool Byte Char String StringView Bytes Array Map Option Result Unit Json' },
  #|  contains:[h.C_LINE_COMMENT_MODE,h.C_BLOCK_COMMENT_MODE,h.QUOTE_STRING_MODE,h.APOS_STRING_MODE,h.C_NUMBER_MODE,
  #|    {className:'string',begin:/#\|/,end:/$/},{className:'meta',begin:/@[A-Za-z_][\w.]*/}]
  #|}));
  #|const aliases = {mbt:'moonbit',js:'javascript',ts:'typescript',jsx:'javascript',tsx:'javascript',md:'markdown',mdx:'markdown',yml:'yaml',sh:'bash',zsh:'bash',fish:'bash',html:'xml',vue:'xml'};
  #|const parsers = {javascript:'babel',js:'babel',jsx:'babel',typescript:'typescript',ts:'typescript',tsx:'typescript',json:'json',html:'html',css:'css',scss:'scss',less:'less',vue:'vue',markdown:'markdown',md:'markdown',yaml:'yaml',yml:'yaml'};
  #|const language = info => /^[\w+#.-]{1,32}$/.test(info || '') ? info.toLowerCase() : 'text';
  #|const esc = value => MarkdownIt().utils.escapeHtml(value);
  #|function paint(code, lang) {
  #|  const name=aliases[lang] || lang;
  #|  return hljs.getLanguage(name) ? hljs.highlight(code,{language:name,ignoreIllegals:true}).value : esc(code);
  #|}
  #|function localPath(href, from) {
  #|  if (!href || /^(?:[a-z][\w+.-]*:|\/\/|#)/i.test(href)) return null;
  #|  try { const url=new URL(href,'https://snapshot.invalid/'+from); return decodeURIComponent(url.pathname.slice(1)); }
  #|  catch { return null; }
  #|}
  #|function localFragment(href, from) {
  #|  if (!href || /^(?:[a-z][\w+.-]*:|\/\/|#)/i.test(href)) return '';
  #|  try { const url=new URL(href,'https://snapshot.invalid/'+from); return url.hash ? decodeURIComponent(url.hash.slice(1)) : ''; }
  #|  catch { return ''; }
  #|}
  #|function headingSlug(value) {
  #|  return value.toLowerCase().replace(/[^\p{L}\p{N}\s_-]/gu,'').trim().replace(/\s+/g,'-') || 'heading';
  #|}
  #|function wikilinkTarget(spec) {
  #|  const marker=spec.indexOf('#');
  #|  if (marker<0) return {id:spec,fragment:''};
  #|  return {id:spec.slice(0,marker),fragment:spec.slice(marker+1)};
  #|}
  #|function wikilinkHref(target, fragment) {
  #|  return '#'+target.anchor+(fragment ? '--'+encodeURIComponent(headingSlug(fragment)) : '');
  #|}
  #|function bindAssets(root, from, prefix, isolated=false) {
  #|  const ids=new Map();
  #|  for (const node of root.querySelectorAll('[id]')) { const old=node.id; node.id=prefix+'--'+old; ids.set(old,node.id); }
  #|  for (const img of root.querySelectorAll('img')) {
  #|    const path=localPath(img.getAttribute('src'),from);
  #|    const asset=snapshot.sources.find(s => s.path===path && s.image);
  #|    if (asset) img.src=asset.image;
  #|    else { img.removeAttribute('src'); img.alt=(img.alt || '图片')+'（未包含在快照）'; }
  #|  }
  #|  for (const a of root.querySelectorAll('a[href]')) {
  #|    const href=a.getAttribute('href');
  #|    if (href.startsWith('#')) {
  #|      let fragment=href.slice(1); try { fragment=decodeURIComponent(fragment); } catch { a.removeAttribute('href'); continue; }
  #|      if (ids.has(fragment)) a.setAttribute('href','#'+ids.get(fragment));
  #|      else if (isolated || !snapshot.links.concat(snapshot.source_links).some(x => href==='#'+x.anchor || href.startsWith('#'+x.anchor+'--'))) a.removeAttribute('href');
  #|      continue;
  #|    }
  #|    const path=localPath(href,from), fragment=localFragment(href,from), target=snapshot.links.concat(snapshot.source_links).find(s=>s.path===path);
  #|    if (target && !isolated) a.setAttribute('href','#'+target.anchor+(fragment ? '--'+encodeURIComponent(headingSlug(fragment)) : ''));
  #|    else if (!isolated && /^(https?:|mailto:)/i.test(href)) { a.target='_blank'; a.rel='noopener noreferrer'; }
  #|    else a.removeAttribute('href');
  #|  }
  #|}
  #|function markdown(source, path, prefix) {
  #|  const md=new MarkdownIt({html:true,linkify:true,typographer:false});
  #|  md.inline.ruler.before('link','wikilink',(state,silent)=>{
  #|    if (state.src.slice(state.pos,state.pos+2)!=='[[') return false;
  #|    const end=state.src.indexOf(']]',state.pos+2); if (end<0) return false;
  #|    const [spec,label]=state.src.slice(state.pos+2,end).split('|');
  #|    const wiki=wikilinkTarget(spec);
  #|    if (!wiki.id || (spec.includes('#') && (!wiki.fragment.trim() || wiki.fragment.includes('#')))) return false;
  #|    const target=snapshot.links.find(p=>p.id===wiki.id); if (!target) return false;
  #|    if (!silent) { let t=state.push('link_open','a',1); t.attrs=[['href',wikilinkHref(target,wiki.fragment)]];
  #|      t=state.push('text','',0); t.content=label || wiki.id; state.push('link_close','a',-1); }
  #|    state.pos=end+2; return true;
  #|  });
  #|  const slugs=new Map();
  #|  md.renderer.rules.heading_open=(tokens,idx,options,env,self)=>{
  #|    const slug=headingSlug(tokens[idx+1].content);
  #|    const count=slugs.get(slug) || 0; slugs.set(slug,count+1); tokens[idx].attrSet('id',slug+(count ? '-'+count : ''));
  #|    return self.renderToken(tokens,idx,options);
  #|  };
  #|  md.renderer.rules.fence=(tokens,idx)=>{
  #|    const token=tokens[idx], lang=language(token.info.trim().split(/\s+/)[0]);
  #|    return '<pre><code class="hljs language-'+esc(lang)+'" data-language="'+esc(lang)+'">'+paint(token.content,lang)+'</code></pre>';
  #|  };
  #|  const clean=DOMPurify.sanitize(md.render(source),{FORBID_TAGS:['style','script','iframe','object','embed','form','input','button','textarea','select','base','meta','link','svg','math'],FORBID_ATTR:['style','srcset','name'],ALLOW_DATA_ATTR:false});
  #|  const template=document.createElement('template'); template.innerHTML=clean;
  #|  for (const node of template.content.querySelectorAll('[class]')) {
  #|    const safe=[...node.classList].filter(c=>c==='hljs' || /^hljs-[\w-]+$/.test(c) || /^language-[\w+#.-]+$/.test(c));
  #|    if (safe.length) node.className=safe.join(' '); else node.removeAttribute('class');
  #|  }
  #|  // Code metadata is read from the highlighter class; user data attributes stay forbidden.
  #|  bindAssets(template.content,path,prefix); return template.content;
  #|}
  #|function htmlPreview(source, path, prefix) {
  #|  const clean=DOMPurify.sanitize(source,{WHOLE_DOCUMENT:true,FORBID_TAGS:['script','iframe','object','embed','base','meta','link','form','input','button','textarea','select'],FORBID_ATTR:['srcset'],ALLOW_DATA_ATTR:false});
  #|  const doc=new DOMParser().parseFromString(clean,'text/html'); bindAssets(doc,path,prefix,true);
  #|  const policy=doc.createElement('meta'); policy.httpEquiv='Content-Security-Policy';
  #|  policy.content="default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src data:; base-uri 'none'; form-action 'none'";
  #|  doc.head.prepend(policy);
  #|  const frame=document.createElement('iframe'); frame.className='html-preview'; frame.title='HTML 预览：'+path;
  #|  frame.setAttribute('sandbox',''); frame.srcdoc='<!doctype html>'+doc.documentElement.outerHTML; return frame;
  #|}
  #|function codeActions(code) {
  #|  if (!codeFormatting) return;
  #|  const raw=code.textContent, lang=language((code.className.match(/language-([\w+#.-]+)/) || [,'text'])[1]);
  #|  const bar=document.createElement('div'); bar.className='code-toolbar';
  #|  const label=document.createElement('span'); label.textContent=lang; bar.append(label); code.parentElement.before(bar);
  #|  const parser=parsers[lang]; if (!parser || raw.length>100000) return;
  #|  const toggle=document.createElement('button'); toggle.type='button'; toggle.textContent='格式化'; bar.append(toggle);
  #|  const status=document.createElement('span'); status.setAttribute('role','status'); bar.append(status);
  #|  let formatted=null, shown=false, busy=false;
  #|  toggle.addEventListener('click',async()=>{
  #|    if (busy) return; busy=true; toggle.disabled=true;
  #|    try { if (formatted===null) formatted=await prettier.format(raw,{parser,plugins,printWidth:88});
  #|      shown=!shown; code.innerHTML=paint(shown ? formatted : raw,lang); toggle.textContent=shown ? '原始排版' : '格式化'; status.textContent=''; }
  #|    catch { status.textContent='无法格式化，保留原文'; }
  #|    finally { busy=false; toggle.disabled=false; }
  #|  });
  #|  toggle.click();
  #|}
  #|function hydrate(section) {
  #|  if (section.dataset.ready) return; section.dataset.ready='true';
  #|  const rendered=section.querySelector('.rendered'), original=rendered.querySelector('.original-code');
  #|  const source=original.textContent, format=section.dataset.format, path=section.dataset.path, prefix=section.closest('.reading').id;
  #|  let preview;
  #|  if (format==='markdown') preview=markdown(source,path,prefix);
  #|  else if (format==='html') preview=htmlPreview(source,path,prefix);
  #|  else if (format==='image') { preview=document.createElement('img'); preview.alt=path; const asset=snapshot.sources.find(s=>s.path===path); if (asset?.image) preview.src=asset.image; }
  #|  else { preview=document.createElement('pre'); const code=document.createElement('code'); code.className='hljs language-'+language(format); code.innerHTML=paint(source,language(format)); preview.append(code); }
  #|  const details=document.createElement('details'); details.className='original';
  #|  const summary=document.createElement('summary'); summary.textContent='查看原文'; details.append(summary,original);
  #|  rendered.replaceChildren(preview); section.append(details);
  #|  for (const code of rendered.querySelectorAll('pre > code')) codeActions(code);
  #|  for (const table of rendered.querySelectorAll('table')) { const wrap=document.createElement('div'); wrap.className='table-scroll'; table.before(wrap); wrap.append(table); }
  #|  section.dataset.rendered='ready';
  #|}
  #|function hydrateVisible() { if (!richRendering) return; for (const section of document.querySelectorAll('.reading:not([hidden]) .rich-document')) hydrate(section); }
  #|if (richRendering) { window.addEventListener('hashchange',hydrateVisible); hydrateVisible(); }
  js
}
