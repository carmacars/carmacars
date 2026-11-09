// The stale page guard (2026-11-06, docs/changes/2026-11-06-stale-chunks-car-card-photos.md). A page whose HTML comes
// from before a deploy (a tab left open, the browser's own copy, the last good copy of 0106) asks for the script and
// stylesheet files of that build. The deploy now keeps them for 8 days (scripts/deploy/keep-assets.mjs); if one is
// missing anyway, the page renders half styled and never wakes up (the owner's date picker of November 1: "October
// 2026", no day numbers). This inline script, first in <head>, watches for that and reloads the page once, fresh:
// - a /_next/ script or stylesheet that fails to load (the error event, caught on window in the capture phase);
// - a chunk that fails to load later, on a client navigation or in a lazy component (ChunkLoadError, "Loading chunk",
//   "Loading CSS chunk", "Failed to fetch dynamically imported module");
// - at load, a /_next/static/ file the browser got an error status for (resource timing, where the browser has it).
// A client navigation to a page of another build is a full page load already (Next compares the build id of the
// answer). The reload first refetches the page with cache: 'reload', so a stale copy in the browser's cache is
// replaced, and it happens at most once a minute per tab (sessionStorage), so a real outage never loops.
// Plain text with no imports: it is inlined in the page (the Worker gives it the page's nonce).

export const RELOAD_KEY = 'cc-stale-reload';
export const CHUNK_ERROR_SOURCE = 'ChunkLoadError|Loading (CSS )?chunk|Failed to load chunk|Failed to fetch dynamically imported module|Importing a module script failed|error loading dynamically imported module|Failed to find Server Action|older or newer deployment';

export const CHUNK_GUARD_SCRIPT = `(function(w){
var done=false,K=${JSON.stringify(RELOAD_KEY)},RE=new RegExp(${JSON.stringify(CHUNK_ERROR_SOURCE)},'i');
function ours(u){if(!u)return false;try{var x=new URL(u,w.location.href);return x.origin===w.location.origin&&x.pathname.indexOf('/_next/')===0}catch(e){return false}}
function reload(){if(done)return;var last=0;try{last=Number(w.sessionStorage.getItem(K))||0}catch(e){}
if(Date.now()-last<60000)return;done=true;try{w.sessionStorage.setItem(K,String(Date.now()))}catch(e){}
var gone=false;function go(){if(gone)return;gone=true;w.location.reload()}
try{w.fetch(w.location.href,{cache:'reload',credentials:'same-origin'}).then(go,go)}catch(e){go()}w.setTimeout(go,2500)}
w.addEventListener('error',function(e){var t=e.target;
if(t&&t!==w&&(t.tagName==='SCRIPT'||(t.tagName==='LINK'&&/stylesheet|preload/.test(t.rel||'')))){if(ours(t.src||t.href))reload();return}
var m=e.message||(e.error&&e.error.name)||'';if(RE.test(String(m)))reload()},true);
w.addEventListener('unhandledrejection',function(e){var r=e.reason,m=typeof r==='string'?r:r?(r.name||'')+' '+(r.message||''):'';if(RE.test(m))reload()});
w.addEventListener('load',function(){try{var es=w.performance.getEntriesByType('resource');
for(var i=0;i<es.length;i++){var x=es[i];if(x.name.indexOf('/_next/static/')!==-1&&typeof x.responseStatus==='number'&&x.responseStatus>=400){reload();return}}}catch(e){}});
})(window);`;
