'use strict';
const fs=require('fs'),path=require('path'),assert=require('assert');
const root=path.resolve(__dirname,'..');
const base=path.join(root,'../../luci/luci-app-sponsorblocktv/htdocs/luci-static/resources/view/sponsorblocktv.js');
const catalogPath=path.join(root,'../../luci/luci-i18n-sponsorblocktv-vi/htdocs/luci-static/resources/sponsorblocktv/i18n/vi.json');
const source=fs.readFileSync(base,'utf8'),catalog=JSON.parse(fs.readFileSync(catalogPath,'utf8'));
const keys=[...source.matchAll(/\btr\((['"])(.*?)\1\)/g)].map(m=>m[2]);
for(const key of keys)assert(typeof catalog[key]==='string' && catalog[key].length,'Missing '+key);
assert(!/\b_\(/.test(source),'No global translation calls in private view');
assert(!/localStorage|appLanguageControl/.test(source),'No independent language preferences');
let present=true,fetches=0;
const documentStub={documentElement:{lang:'en'}};
const windowStub={fetch:async(url,opts)=>{fetches++;assert(url.includes('/sponsorblocktv/i18n/vi.json'));assert.equal(opts.cache,'no-store');return {ok:present,json:async()=>catalog};}};
const factory=new Function('window','document','L','rpc','_',source.replace('return view.extend({','return {loadAppLanguage,tr,categories:()=>CATEGORIES};\nreturn view.extend({'));
const app=factory(windowStub,documentStub,{resource:p=>'/luci-static/resources/'+p},{declare:()=>{}},()=>{throw Error('Global translator called');});
(async()=>{
 await app.loadAppLanguage();assert.equal(app.tr('Volume'),'Volume');assert.equal(fetches,0);
 for(const lang of ['vi','vi-VN','vi_VN']){
  documentStub.documentElement.lang=lang;
  await app.loadAppLanguage();
  assert.equal(app.tr('Volume'),'Âm lượng');
  assert.equal(app.tr('Author'),'Tác giả');
  assert.equal(app.categories()[0][1],'Tài trợ');
 }
 assert.equal(app.tr('not translated'),'not translated');
 for(const lang of ['en','zh-cn','fr','auto','']){
  documentStub.documentElement.lang=lang;
  const before=fetches;await app.loadAppLanguage();
  assert.equal(app.tr('Volume'),'Volume');assert.equal(app.categories()[0][1],'Sponsor');assert.equal(fetches,before);
 }
 documentStub.documentElement.lang='vi';present=false;
 await app.loadAppLanguage();assert.equal(app.tr('Volume'),'Volume');
 console.log('PASS: system document language, private catalog, '+Object.keys(catalog).length+' keys, regional variants, missing package fallback');
})().catch(e=>{console.error(e);process.exitCode=1;});
