// Where a visitor came from (release 48, migration 3230). The first page of a visit keeps the referring site, the landing
// page, the campaign tags and an ad click id in one first-party cookie (cc_src, 90 days). Nothing is sent anywhere by
// itself: the server reads the cookie only when the person sends a form or a request to book, and stores it with that
// lead or booking (src/server/source.ts), so Sales sees "ChatGPT", "Google search" or "Google Ads" and the first page.
// No imports: the script below runs in the page's <head>, and the parser runs on the server and in the unit test.

export const SRC_COOKIE = 'cc_src';
export interface Touch { ref?: string; landing?: string; at?: string; utm?: Record<string, string>; click?: { kind: string; id: string } }
export interface SourceCookie { f: Touch; l?: Pick<Touch, 'ref' | 'landing'> }

const UTM = ['source', 'medium', 'campaign', 'term', 'content'] as const;
export const CLICK_IDS = ['gclid', 'gbraid', 'wbraid', 'msclkid', 'fbclid', 'ttclid'] as const;
const cut = (v: unknown, n: number) => (typeof v === 'string' && v.trim() ? v.trim().replace(/[\u0000-\u001f]/g, '').slice(0, n) : undefined);

/** The referring page as it is kept: host and path, and the words searched when the address carries them (q, p, query). */
export function keptReferrer(referrer: string, ownOrigin: string): string | undefined {
  if (!referrer || referrer.startsWith(ownOrigin)) return undefined;
  try {
    const r = new URL(referrer);
    if (!/^https?:$/.test(r.protocol)) return undefined;
    const q = r.searchParams.get('q') || r.searchParams.get('p') || r.searchParams.get('query') || '';
    return (r.host + r.pathname).slice(0, 160) + (q ? `?q=${encodeURIComponent(q.slice(0, 80))}` : '');
  } catch { return undefined; }
}

/** What a page view adds: the touch of this visit, or null when it is a page inside the site with no campaign tag. */
export function touchOf(href: string, referrer: string, now: Date): { touch: Touch; fresh: boolean } {
  const u = new URL(href);
  const ref = keptReferrer(referrer, u.origin);
  const utm: Record<string, string> = {};
  for (const k of UTM) { const v = cut(u.searchParams.get(`utm_${k}`), 80); if (v) utm[k] = v; }
  let click: Touch['click'];
  for (const k of CLICK_IDS) { const v = cut(u.searchParams.get(k), 120); if (v) { click = { kind: k, id: v }; break; } }
  const touch: Touch = { landing: u.pathname.slice(0, 160), at: now.toISOString() };
  if (ref) touch.ref = ref;
  if (Object.keys(utm).length) touch.utm = utm;
  if (click) touch.click = click;
  return { touch, fresh: Boolean(ref || touch.utm || click) };
}

/** The cookie after a page view: the first touch never changes; a later visit from outside or with a tag is the last touch. */
export function nextSource(prev: SourceCookie | null, href: string, referrer: string, now: Date): SourceCookie | null {
  const { touch, fresh } = touchOf(href, referrer, now);
  if (!prev?.f) return { f: touch };
  if (!fresh) return null;
  return { f: prev.f, l: { ref: touch.ref, landing: touch.landing } };
}

/** The cookie's value as the server trusts it: only the known keys, every string cut short. Null when it is not ours. */
export function parseSource(raw: string | undefined | null): SourceCookie | null {
  if (!raw || raw.length > 2400) return null;
  let j: unknown;
  try { j = JSON.parse(decodeURIComponent(raw)); } catch { return null; }
  if (!j || typeof j !== 'object') return null;
  const touch = (t: unknown): Touch | null => {
    if (!t || typeof t !== 'object') return null;
    const x = t as Record<string, unknown>;
    const out: Touch = {};
    const landing = cut(x.landing, 160); if (landing && landing.startsWith('/')) out.landing = landing;
    const ref = cut(x.ref, 260); if (ref) out.ref = ref;
    const at = cut(x.at, 30); if (at && !Number.isNaN(Date.parse(at))) out.at = at;
    if (x.utm && typeof x.utm === 'object') {
      const utm: Record<string, string> = {};
      for (const k of UTM) { const v = cut((x.utm as Record<string, unknown>)[k], 80); if (v) utm[k] = v; }
      if (Object.keys(utm).length) out.utm = utm;
    }
    if (x.click && typeof x.click === 'object') {
      const c = x.click as Record<string, unknown>;
      const kind = cut(c.kind, 10); const id = cut(c.id, 120);
      if (kind && id && (CLICK_IDS as readonly string[]).includes(kind)) out.click = { kind, id };
    }
    return Object.keys(out).length ? out : null;
  };
  const f = touch((j as Record<string, unknown>).f);
  if (!f) return null;
  const l = touch((j as Record<string, unknown>).l);
  return l ? { f, l: { ref: l.ref, landing: l.landing } } : { f };
}

/** The script of the page's <head> (the same rules as nextSource, written for every browser; kept small). */
export const SOURCE_SCRIPT = `(function(){try{var d=document,l=location,m=d.cookie.match(/(?:^|; )${SRC_COOKIE}=([^;]*)/),s=null;try{s=m?JSON.parse(decodeURIComponent(m[1])):null}catch(e){}
var r=d.referrer||'',x=r&&r.indexOf(l.origin)!==0,q=new URLSearchParams(l.search),u={},k=${JSON.stringify(UTM)},c=${JSON.stringify(CLICK_IDS)},v,i,n=0,cl=null,ref='';
for(i=0;i<k.length;i++){v=q.get('utm_'+k[i]);if(v){u[k[i]]=v.slice(0,80);n++}}
for(i=0;i<c.length;i++){v=q.get(c[i]);if(v){cl={kind:c[i],id:v.slice(0,120)};break}}
if(x){try{var R=new URL(r),w=R.searchParams.get('q')||R.searchParams.get('p')||R.searchParams.get('query')||'';if(/^https?:$/.test(R.protocol))ref=(R.host+R.pathname).slice(0,160)+(w?'?q='+encodeURIComponent(w.slice(0,80)):'')}catch(e){}}
if(s&&s.f&&!ref&&!n&&!cl)return;
var t={landing:l.pathname.slice(0,160),at:new Date().toISOString()};if(ref)t.ref=ref;if(n)t.utm=u;if(cl)t.click=cl;
if(!s||!s.f)s={f:t};else s.l={ref:t.ref,landing:t.landing};
d.cookie='${SRC_COOKIE}='+encodeURIComponent(JSON.stringify(s))+'; path=/; max-age=7776000; samesite=lax'+(l.protocol==='https:'?'; secure':'')}catch(e){}})();`;
