// Playwright tool entry for the graph-enabled view: browser_run_code_unsafe(filename=absolute path).
// Loads the preserved map snapshot artifact written by scripts/reading_fixture.py.
async page => {
  const passed=[], errors=[];
  page.on('pageerror',e=>errors.push(e.message));
  page.on('console',m=>{if(m.type()==='error') errors.push(m.text());});
  const check=(value,message)=>{if(!value) throw new Error(message);};
  await page.setViewportSize({width:1440,height:1000});
  await page.goto('file:///tmp/corridor-rich-reading/.corridor/map-viewer.html');
  const panel=page.locator('.graph-panel');
  await panel.waitFor();
  const map=panel.locator('svg.graph-map');
  await map.waitFor();
  const edges=await map.locator('line.graph-edge').count();
  const nodes=await map.locator('circle.graph-node').count();
  check(edges >= 1,'graph edges rendered: '+edges);
  check(nodes >= 2,'graph nodes rendered: '+nodes);
  const link=map.locator('a').first();
  const href=await link.getAttribute('href');
  await link.click();
  check(page.url().endsWith(href),'graph node click updates the hash route');
  check(await page.locator('.reading:not([hidden])').count() === 1,'graph navigation selects exactly one article');
  await page.locator('#catalog').getByRole('link',{name:'关系快照',exact:true}).click();
  check(await page.locator('.reading:not([hidden])').count() === 1,'catalog navigation still works beside the map');
  await page.setViewportSize({width:390,height:844});
  await page.waitForFunction(()=>document.documentElement.scrollWidth<=innerWidth);
  check(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),'mobile page width');
  check(errors.length===0,'runtime errors: '+errors.join('; '));
  passed.push('graph map renders, routes, coexists with catalog and fits 390px');
  return {passed,errors};
}
