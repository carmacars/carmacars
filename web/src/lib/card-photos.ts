'use client';
import type { Photo } from '@/lib/types';
import { photoUrl } from '@/lib/photo';
import { publicRead } from '@/lib/browser-rpc';
import { motionOK } from '@/lib/motion';
import { DRIVE_MS, DRIVE_NAV_MS, DRIVE_RESET_MS, INTENT_MS, parseBox, plainClick, rearPivot, segmentAt, slidePhotos, snapIndex, stepIndex } from './card-photos-model.ts';

// The car card's photos and drive-off (release 50, 5030; docs/changes/2026-11-25-r50-car-cards.md). One delegated listener
// set for every card on the page, no hydration per card (Effects starts it once). With CarCard.tsx and styles/car-card.css.
// - Phone: the photo is a native scroll-snap track (momentum, one photo a snap, a rubber band at the ends); the browser
//   tells a sideways swipe from a page scroll, so a vertical scroll is never taken. A tap (a click on the track: browsers
//   send none after a swipe) opens the car. The dots follow the track. The photos after the first are filled when the card
//   comes near the screen (the next one ahead, the rest lazy).
// - Mouse: the photo is cut into N segments; where the pointer is picks the photo (a 180 ms crossfade, the dots follow), the
//   photos read and loaded after 60 ms of rest on the card. Leaving the card goes back to the cover.
// - Keyboard: the arrow keys on the focused card (its link) move through the photos.
// - The drive-off: a click or tap on a car whose side render has its matte (data-matte) plays the drive-off on the cover and
//   starts the car page 140 ms later (the page loads while the car pulls away). Hover only scrubs photos, so the two never
//   fight. The layers are made on first intent (hover, focus, touch, or the card coming into view on a phone).
// - Reduced motion, or the pause control: no drive-off and no crossfade; the swipe and the arrow keys still change the photo.
// The slides are React's empty elements (dangerouslySetInnerHTML ''), so React never diffs what is added here.

type Card = {
  el: HTMLElement; media: HTMLElement; track: HTMLElement; slides: HTMLElement[]; dots: HTMLElement[]; n: number; at: number; want: number;
  list: Photo[] | null; loading: Promise<Photo[]> | null; drive: HTMLElement | null; ready: boolean; reset: number;
};

const lists = new Map<string, Promise<Photo[]>>();
function photosOf(slug: string): Promise<Photo[]> {
  let p = lists.get(slug);
  if (!p) {
    p = publicRead<Photo[] | null>('vehicle_photos_public', { p_slug: slug }).then((rows) => (Array.isArray(rows) ? rows : [])).catch(() => []);
    lists.set(slug, p);
  }
  return p;
}
const srcSetOf = (p: Photo) => (p.variants?.length ? p.variants.map((v) => `${photoUrl(v.path)} ${v.width}w`).join(', ') : '');
// React marks every element it owns with a fiber key: nothing is added to a card before React has hydrated it
const owned = (el: Element) => Object.keys(el).some((k) => k.startsWith('__reactFiber$'));
const coverOf = (c: Card) => c.slides[0]?.querySelector('img') ?? null;

export function cardPhotos(): () => void {
  const fine = window.matchMedia('(hover: hover) and (pointer: fine)').matches;
  const saveData = !!(navigator as Navigator & { connection?: { saveData?: boolean } }).connection?.saveData;
  const state = new WeakMap<HTMLElement, Card>();
  let hovered: Card | null = null;
  let intent = 0;
  let passing = false;

  const cardOf = (t: EventTarget | null): Card | null => {
    const el = (t as Element | null)?.closest?.('.car-card') as HTMLElement | null;
    if (!el) return null;
    let c = state.get(el);
    if (c) return c;
    const media = el.querySelector<HTMLElement>(':scope > .car-card__media');
    const track = media?.querySelector<HTMLElement>(':scope > .car-card__track');
    if (!media || !track || !owned(el)) return null;
    c = { el, media, track, slides: [...track.children] as HTMLElement[], dots: [...media.querySelectorAll<HTMLElement>(':scope > .car-card__dots > i')],
      n: Number(el.dataset.n) || 1, at: 0, want: 0, list: null, loading: null, drive: null, ready: false, reset: 0 };
    state.set(el, c);
    return c;
  };

  // ---- the photos
  const load = (c: Card): Promise<Photo[]> => {
    if (c.list) return Promise.resolve(c.list);
    if (!c.loading) {
      const slug = c.el.dataset.slug;
      c.loading = (slug && c.n > 1 ? photosOf(slug) : Promise.resolve([])).then((rows) => {
        const src = coverOf(c)?.getAttribute('src') ?? '';
        const cover = rows.find((p) => photoUrl(p.path) === src)?.path ?? null;
        c.list = slidePhotos(rows, cover, c.n);
        return c.list;
      });
    }
    return c.loading;
  };
  /** The image of slide i (1 based; 0 is the cover), made when first needed. */
  const fill = (c: Card, i: number, eager: boolean): HTMLImageElement | null => {
    if (i < 1 || !c.list || i > c.list.length) return i === 0 ? coverOf(c) : null;
    const slide = c.slides[i]; if (!slide) return null;
    let img = slide.querySelector('img');
    if (!img) {
      const p = c.list[i - 1]!, cover = coverOf(c);
      img = document.createElement('img');
      img.alt = ''; img.decoding = 'async'; img.draggable = false; img.loading = eager ? 'eager' : 'lazy';
      img.width = p.width ?? cover?.width ?? 1800; img.height = p.height ?? cover?.height ?? 1200;
      const ss = srcSetOf(p); if (ss) { img.srcset = ss; img.sizes = cover?.sizes || '(min-width: 64rem) 33vw, 100vw'; }
      img.src = photoUrl(p.path);
      slide.appendChild(img);
    } else if (eager && img.loading === 'lazy') img.loading = 'eager';
    return img;
  };
  const ready = (img: HTMLImageElement | null) => !!img && img.complete && img.naturalWidth > 0;
  const mark = (c: Card, i: number) => {
    c.at = i;
    c.dots.forEach((d, k) => d.classList.toggle('is-on', k === i));
  };
  /** Mouse layout: the stacked photo i shows (once it has loaded: the one before stays until then). */
  const show = (c: Card, i: number) => {
    c.want = i;
    const img = fill(c, i, true);
    const go = () => { if (c.want !== i) return; c.slides.forEach((s, k) => s.classList.toggle('is-on', k === i)); mark(c, i); fill(c, i + 1, true); };
    if (i === 0 || ready(img)) go(); else img?.addEventListener('load', go, { once: true });
  };

  // ---- mouse: the photo under the pointer
  const onOver = (e: PointerEvent) => {
    if (e.pointerType === 'touch') return;
    const c = cardOf(e.target);
    if (c === hovered) return;
    if (hovered) { show(hovered, 0); }
    hovered = c;
    window.clearTimeout(intent);
    if (!c) return;
    // the photo list read once the mouse rests; then the photo under the pointer at once (it may not move again)
    intent = window.setTimeout(() => { if (hovered === c) { void load(c).then(() => { if (hovered !== c) return; for (let i = 1; i < c.slides.length; i++) fill(c, i, true); if (last) scrub(c, last.x, last.y); }); prepareDrive(c); } }, INTENT_MS);
  };
  const onOut = (e: PointerEvent) => {
    if (!hovered || e.pointerType === 'touch') return;
    const to = e.relatedTarget as Node | null;
    if (to && hovered.el.contains(to)) return;
    window.clearTimeout(intent);
    show(hovered, 0); hovered = null;
  };
  let last: { x: number; y: number } | null = null;
  const scrub = (c: Card, x: number, y: number) => {
    if (c.n <= 1 || !c.list) return;
    const r = c.media.getBoundingClientRect();
    if (y < r.top || y > r.bottom || x < r.left || x > r.right) return;
    const i = segmentAt(x - r.left, r.width, c.list.length + 1);
    if (i !== c.want) show(c, i);
  };
  const onMove = (e: PointerEvent) => {
    if (e.pointerType === 'touch') return;
    last = { x: e.clientX, y: e.clientY };
    // a pointer already over a card when React hydrated it had no pointerover to start from (cardOf said no): the first move picks it up
    if (!hovered && (e.target as Element | null)?.closest?.('.car-card')) onOver(e);
    if (hovered) scrub(hovered, e.clientX, e.clientY);
  };

  // ---- phone: the track's dots, and the photos filled as the card comes near
  let sraf = 0; const moved = new Set<Card>();
  const onScroll = (e: Event) => {
    const t = e.target as HTMLElement;
    if (!t.classList?.contains('car-card__track')) return;
    const c = cardOf(t); if (!c) return;
    moved.add(c);
    if (!sraf) sraf = requestAnimationFrame(() => {
      sraf = 0;
      moved.forEach((m) => { const i = snapIndex(m.track.scrollLeft, m.track.clientWidth, m.slides.length); if (i !== m.at) { mark(m, i); fill(m, i + 1, true); } });
      moved.clear();
    });
  };
  const near = 'IntersectionObserver' in window && !fine ? new IntersectionObserver((es) => es.forEach((en) => {
    if (!en.isIntersecting) return;
    near!.unobserve(en.target);
    const c = cardOf(en.target); if (!c) return;
    void load(c).then(() => { fill(c, 1, true); for (let i = 2; i < c.slides.length; i++) fill(c, i, false); });
    if (!saveData) prepareDrive(c);
  }), { rootMargin: '200px 0px' }) : null;
  const watched = new WeakSet<Element>();
  let tries = 0, scanT = 0;
  const scan = () => {
    if (!near) return;
    let waiting = false;
    document.querySelectorAll<HTMLElement>('.car-card[data-n], .car-card[data-matte]').forEach((el) => {
      if (watched.has(el)) return;
      if (!owned(el)) { waiting = true; return; }
      watched.add(el); near.observe(el);
    });
    if (waiting && ++tries <= 25) scanT = window.setTimeout(scan, 400);
  };
  const mo = near ? new MutationObserver(() => { tries = 0; window.clearTimeout(scanT); scanT = window.setTimeout(scan, 100); }) : null;
  const onDown = (e: PointerEvent) => { if (e.pointerType !== 'touch') return; const c = cardOf(e.target); if (c) { void load(c); prepareDrive(c); } };

  // ---- the drive-off
  function prepareDrive(c: Card) {
    if (c.drive || !c.el.dataset.matte || !c.el.dataset.plate || !motionOK()) return;
    const box = parseBox(c.el.dataset.box), cover = coverOf(c);
    if (!box || !cover) return;
    const facing = c.el.dataset.facing === 'right' ? 'right' : 'left';
    const src = cover.currentSrc || cover.src;
    const pic = (cls?: string) => { const img = document.createElement('img'); img.alt = ''; img.decoding = 'async'; img.draggable = false; img.src = src; if (cls) img.className = cls; return img; };
    const span = (cls: string, ...kids: Node[]) => { const s = document.createElement('span'); s.className = cls; kids.forEach((k) => s.appendChild(k)); return s; };
    const plate = document.createElement('img'); plate.alt = ''; plate.decoding = 'async'; plate.src = c.el.dataset.plate;
    const body = span('car-drive__body', pic());
    const d = span(`car-drive${facing === 'right' ? ' car-drive--mirror' : ''}`, plate, span('car-drive__floor', pic()),
      span('car-drive__car', span('car-drive__lift', span('car-drive__ghost', pic()), span('car-drive__ghost', pic()), body)));
    d.setAttribute('aria-hidden', 'true'); d.dataset.testid = 'card-drive';
    const piv = rearPivot(box, facing);
    d.style.setProperty('--m', `url("${c.el.dataset.matte}")`);
    d.style.setProperty('--rear-x', piv.x); d.style.setProperty('--floor-y', piv.y);
    c.media.appendChild(d);
    c.drive = d;
    const matte = new Image(); matte.src = c.el.dataset.matte;
    const dec = (img: HTMLImageElement) => (img.decode ? img.decode() : Promise.resolve());
    void Promise.all([dec(plate), dec(matte), dec(body.firstChild as HTMLImageElement)]).then(() => { c.ready = true; c.el.dataset.drive = 'ready'; }).catch(() => undefined);
  }
  const drive = (c: Card) => {
    window.clearTimeout(c.reset);
    c.el.classList.add('is-snap'); show(c, 0); if (c.track.scrollLeft) c.track.scrollLeft = 0;
    c.el.classList.remove('is-back'); void c.drive!.offsetWidth;
    c.el.classList.add('is-driving');
    c.reset = window.setTimeout(() => back(c), DRIVE_MS + DRIVE_RESET_MS);
  };
  const back = (c: Card) => {
    if (!c.el.classList.contains('is-driving')) return;
    c.el.classList.remove('is-driving', 'is-snap'); c.el.classList.add('is-back');
    window.setTimeout(() => c.el.classList.remove('is-back'), 260);
  };
  const open = (a: HTMLAnchorElement) => { passing = true; try { a.click(); } finally { passing = false; } };
  const onClick = (e: MouseEvent) => {
    if (passing || e.defaultPrevented) return;
    const c = cardOf(e.target); if (!c) return;
    const a = c.el.querySelector<HTMLAnchorElement>('.car-card__name a'); if (!a) return;
    const onTrack = c.track.contains(e.target as Node);
    if (!onTrack && !a.contains(e.target as Node)) return;
    if (!plainClick(e)) return; // a new tab or window: the browser's own (the link covers the photo with a mouse)
    const canDrive = c.ready && !!c.drive && motionOK();
    if (!onTrack && !canDrive) return; // the link as it is
    e.preventDefault(); e.stopImmediatePropagation();
    if (!canDrive) { open(a); return; }
    drive(c);
    window.setTimeout(() => open(a), DRIVE_NAV_MS);
  };
  // back to a page kept by the browser (back/forward cache): the cars are home again
  const onShow = (e: PageTransitionEvent) => { if (e.persisted) document.querySelectorAll('.car-card.is-driving, .car-card.is-back').forEach((el) => el.classList.remove('is-driving', 'is-back', 'is-snap')); };

  // ---- keyboard: the arrow keys on the focused card
  const onKey = (e: KeyboardEvent) => {
    if (e.altKey || e.ctrlKey || e.metaKey || e.shiftKey) return;
    const t = e.target as HTMLElement;
    if (!t.matches?.('.car-card__name a')) return;
    const c = cardOf(t); if (!c || c.n <= 1) return;
    const i = stepIndex(c.want, e.key, c.slides.length); if (i === null) return;
    e.preventDefault();
    void load(c).then((list) => {
      if (i > list.length) return;
      if (fine) show(c, i);
      else { c.want = i; fill(c, i, true); c.track.scrollTo({ left: i * c.track.clientWidth, behavior: motionOK() ? 'smooth' : 'auto' }); }
    });
  };
  const onFocusIn = (e: FocusEvent) => { const c = cardOf(e.target); if (c) { void load(c); prepareDrive(c); } };
  const onFocusOut = (e: FocusEvent) => {
    const c = cardOf(e.target); if (!c || (e.relatedTarget && c.el.contains(e.relatedTarget as Node))) return;
    if (c !== hovered) { if (fine) show(c, 0); }
  };

  document.addEventListener('pointerover', onOver, { passive: true });
  document.addEventListener('pointerout', onOut, { passive: true });
  document.addEventListener('pointermove', onMove, { passive: true });
  document.addEventListener('pointerdown', onDown, { passive: true });
  document.addEventListener('scroll', onScroll, { capture: true, passive: true });
  document.addEventListener('keydown', onKey);
  document.addEventListener('focusin', onFocusIn);
  document.addEventListener('focusout', onFocusOut);
  window.addEventListener('click', onClick, true); // before the page transition's own capture listener (Effects)
  window.addEventListener('pageshow', onShow);
  const main = document.getElementById('main') ?? document.body;
  mo?.observe(main, { childList: true, subtree: true });
  const idle = typeof window.requestIdleCallback === 'function' ? window.requestIdleCallback(scan, { timeout: 800 }) : window.setTimeout(scan, 200);
  return () => {
    window.clearTimeout(intent); window.clearTimeout(scanT); cancelAnimationFrame(sraf);
    if (typeof window.cancelIdleCallback === 'function') window.cancelIdleCallback(idle as number); else window.clearTimeout(idle as number);
    near?.disconnect(); mo?.disconnect();
    document.removeEventListener('pointerover', onOver);
    document.removeEventListener('pointerout', onOut);
    document.removeEventListener('pointermove', onMove);
    document.removeEventListener('pointerdown', onDown);
    document.removeEventListener('scroll', onScroll, { capture: true });
    document.removeEventListener('keydown', onKey);
    document.removeEventListener('focusin', onFocusIn);
    document.removeEventListener('focusout', onFocusOut);
    window.removeEventListener('click', onClick, true);
    window.removeEventListener('pageshow', onShow);
  };
}
