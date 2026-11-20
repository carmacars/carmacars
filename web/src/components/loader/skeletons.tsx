import { BrandLoader, Shimmer } from './BrandLoader';

// r48 speed (docs/changes/2026-11-20-r48-perf.md): the shapes a page has while it loads, built from the one loader
// (BrandLoader.tsx). The loading.tsx files of the portals render one of these, and RouteProgress shows the same shape the
// moment a link is tapped (before the server answers), so a tap never leaves the old page or a blank screen in place.
// Each shape follows its pages' layout closely enough that nothing jumps when the real page arrives.

export type Shape = 'dashboard' | 'table' | 'calendar' | 'detail' | 'form' | 'hero' | 'cards' | 'home' | 'cars' | 'car' | 'page';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
/** A path segment that names one record (a booking number, an id, a plate) rather than a page. */
const isRecord = (s: string) => UUID.test(s) || /^[A-Z]{1,3}-\d{3,}$/i.test(s) || /^\d+$/.test(s);
const PORTALS = ['admin', 'staff', 'owner', 'account', 'investor', 'va', 'field'];

/** The skeleton for a page by its address (paths only; the search part never changes the shape). */
export function shapeFor(pathname: string): Shape {
  const parts = pathname.split('?')[0]!.split('#')[0]!.split('/').filter(Boolean);
  const [top, ...rest] = parts;
  if (!top) return 'home';
  if (!PORTALS.includes(top)) {
    if (top === 'cars') return rest.length === 1 ? 'car' : rest.length ? 'page' : 'cars';
    return 'page';
  }
  const last = rest[rest.length - 1] ?? '';
  if (/calendar|schedule/.test(last)) return 'calendar';
  if (last === 'new' || last === 'edit' || /^(apply|sign|profile|settings|account)$/.test(last)) return 'form';
  if (rest.some(isRecord)) return 'detail';
  if (top === 'owner' || top === 'account' || top === 'investor') return rest.length ? 'cards' : 'hero';
  if (!rest.length || (top === 'staff' && rest.length === 1 && rest[0] === 'field')) return 'dashboard';
  return 'table';
}

function Head({ wide = false }: { wide?: boolean }) {
  return (
    <div className="skp__head">
      <BrandLoader size="sm" />
      <div className="skp__title"><Shimmer w={wide ? '46%' : '32%'} h="1.9rem" /><Shimmer w="58%" h="0.9rem" /></div>
    </div>
  );
}
const Lines = ({ n, w = ['92%', '78%', '64%'] }: { n: number; w?: string[] }) => <>{Array.from({ length: n }, (_, i) => <Shimmer key={i} w={w[i % w.length]} h="0.85rem" />)}</>;
const Card = ({ h = '9rem', children }: { h?: string; children?: React.ReactNode }) => <div className="skp__card" style={{ minHeight: h }}>{children ?? <Lines n={4} />}</div>;

/** The page-shaped skeleton. `testId` lets a test tell the shapes apart. */
export function PageSkeleton({ shape }: { shape: Shape }) {
  return (
    <div className={`skp skp--${shape}`} aria-busy="true" data-testid={`skeleton-${shape}`} data-skeleton={shape}>
      {body(shape)}
    </div>
  );
}

function body(shape: Shape) {
  switch (shape) {
    case 'dashboard':
      return <><Head /><div className="skp__tiles">{[0, 1, 2, 3].map((i) => <Card key={i} h="5.5rem"><Shimmer w="40%" h="1.6rem" /><Shimmer w="70%" h="0.8rem" /></Card>)}</div>
        <div className="skp__split"><Card h="22rem"><Lines n={9} /></Card><Card h="16rem"><Lines n={6} /></Card></div></>;
    case 'table':
      return <><Head /><div className="skp__bar"><Shimmer w="16rem" h="2.5rem" /><Shimmer w="6rem" h="2.5rem" r="999px" /><Shimmer w="6rem" h="2.5rem" r="999px" /><Shimmer w="6rem" h="2.5rem" r="999px" /></div>
        <div className="skp__card skp__rows">{Array.from({ length: 9 }, (_, i) => <div key={i} className="skp__row"><Shimmer w="18%" h="0.9rem" /><Shimmer w="30%" h="0.9rem" /><Shimmer w="16%" h="0.9rem" /><Shimmer w="12%" h="0.9rem" /></div>)}</div></>;
    case 'calendar':
      return <><Head /><div className="skp__bar"><Shimmer w="10rem" h="2.5rem" /><Shimmer w="7rem" h="2.5rem" /><Shimmer w="7rem" h="2.5rem" /></div>
        <div className="skp__card skp__cal">{Array.from({ length: 10 }, (_, i) => <div key={i} className="skp__calrow"><Shimmer w="100%" h="1.1rem" /><Shimmer w={`${30 + ((i * 23) % 50)}%`} h="1.1rem" r="4px" className="skp__calbar" /></div>)}</div></>;
    case 'detail':
      return <><Head wide /><div className="skp__split"><div className="skp__stack"><Card h="12rem" /><Card h="10rem" /><Card h="8rem" /></div><div className="skp__stack"><Card h="14rem" /><Card h="7rem" /></div></div></>;
    case 'form':
      return <><Head /><div className="skp__card skp__form">{[0, 1, 2, 3, 4].map((i) => <div key={i} className="skp__field"><Shimmer w="30%" h="0.8rem" /><Shimmer w="100%" h="2.75rem" /></div>)}<Shimmer w="9rem" h="2.75rem" r="999px" /></div></>;
    case 'hero':
      return <><Head /><Shimmer w="100%" h="12rem" r="16px" /><div className="skp__tiles">{[0, 1, 2, 3].map((i) => <Card key={i} h="5rem"><Shimmer w="45%" h="1.4rem" /></Card>)}</div><Card h="10rem" /></>;
    case 'cards':
      return <><Head /><div className="skp__stack"><Card h="8rem" /><Card h="8rem" /><Card h="8rem" /></div></>;
    case 'home':
      return <><Shimmer w="100%" h="min(62vh, 34rem)" r="0" /><div className="skp__wrap"><div className="skp__grid">{[0, 1, 2].map((i) => <div key={i} className="skp__stack"><Shimmer w="100%" h="11rem" r="8px" /><Lines n={2} /></div>)}</div></div></>;
    case 'cars':
      return <div className="skp__wrap"><Head /><div className="skp__bar"><Shimmer w="14rem" h="2.75rem" /><Shimmer w="8rem" h="2.75rem" /></div>
        <div className="skp__grid">{Array.from({ length: 6 }, (_, i) => <div key={i} className="skp__stack"><Shimmer w="100%" h="12rem" r="8px" /><Shimmer w="70%" h="1.1rem" /><Shimmer w="40%" h="0.9rem" /></div>)}</div></div>;
    case 'car':
      return <div className="skp__wrap"><div className="skp__split skp__split--car"><div className="skp__stack"><Shimmer w="100%" h="min(52vh, 28rem)" r="8px" /><div className="skp__thumbs">{[0, 1, 2, 3].map((i) => <Shimmer key={i} w="100%" h="4.5rem" r="6px" />)}</div><Lines n={5} /></div>
        <div className="skp__card skp__stack"><BrandLoader size="sm" /><Shimmer w="60%" h="1.8rem" /><Shimmer w="40%" h="1.2rem" /><Shimmer w="100%" h="2.75rem" /><Shimmer w="100%" h="2.75rem" /><Shimmer w="100%" h="3rem" r="999px" /></div></div></div>;
    default:
      return <div className="skp__wrap"><Head wide /><Shimmer w="100%" h="14rem" r="8px" /><div className="skp__stack"><Lines n={6} /></div></div>;
  }
}

// The shapes' layout (the look is BrandLoader's). Phone first; nothing here is wider than the screen.
export const SKELETON_CSS = `
.skp { display: grid; gap: 1.25rem; padding-block: 0.5rem 2rem; min-width: 0; }
.skp__wrap { width: min(100% - 32px, 1200px); margin-inline: auto; display: grid; gap: 1.25rem; padding-block: 1.25rem; }
.skp__head { display: flex; align-items: flex-start; gap: 0.75rem; }
.skp__title { display: grid; gap: 0.5rem; flex: 1; min-width: 0; }
.skp__tiles { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 0.75rem; }
.skp__split, .skp__grid { display: grid; gap: 1rem; grid-template-columns: minmax(0, 1fr); }
.skp__stack { display: grid; gap: 0.75rem; align-content: start; min-width: 0; }
.skp__card { display: grid; gap: 0.6rem; align-content: start; padding: 1rem; border: 1px solid var(--grey-200, #E2E2E2); border-radius: 12px; background: var(--white, #fff); min-width: 0; }
.skp__bar { display: flex; flex-wrap: wrap; gap: 0.5rem; }
.skp__bar > .bl-sh { max-width: 100%; }
.skp__rows { gap: 0; padding: 0; }
.skp__row { display: flex; gap: 1rem; align-items: center; padding: 0.95rem 1rem; border-top: 1px solid var(--grey-200, #E2E2E2); }
.skp__row:first-child { border-top: 0; }
.skp__cal { gap: 0.55rem; }
.skp__calrow { display: grid; grid-template-columns: minmax(5rem, 18%) 1fr; gap: 0.75rem; align-items: center; }
.skp__calbar { margin-left: 12%; background: var(--red-100, #FAD4D6); }
.skp__form { max-width: 40rem; gap: 1rem; }
.skp__field { display: grid; gap: 0.4rem; }
.skp__thumbs { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 0.5rem; }
@media (min-width: 720px) {
  .skp__tiles { grid-template-columns: repeat(4, minmax(0, 1fr)); }
  .skp__grid { grid-template-columns: repeat(3, minmax(0, 1fr)); }
  .skp__split { grid-template-columns: minmax(0, 2fr) minmax(0, 1fr); }
  .skp__split--car { grid-template-columns: minmax(0, 3fr) minmax(0, 2fr); }
}
/* the skeleton RouteProgress shows over a page while the next one is on its way: the old page is hidden, not removed */
[data-nav-pending] > :not(.nav-skel) { display: none !important; }
.nav-skel { display: block; min-height: 60vh; }
`;

/** The shapes' styles, once per page (the root layout). */
export function SkeletonStyles() {
  return <style href="cc-skeletons" precedence="default">{SKELETON_CSS}</style>;
}
