'use client';
import type { Photo } from '@/lib/types';
import { photoUrl } from '@/lib/photo';
import { publicRead } from '@/lib/browser-rpc';
import { motionOK } from '@/lib/motion';

// The car card's photos (2026-11-06, docs/changes/2026-11-06-stale-chunks-car-card-photos.md). One delegated listener set for every
// card on the page, no hydration per card:
// - a mouse resting on a card (120 ms of intent) reads the car's photo list once (public.vehicle_photos_public, straight
//   to the database API with the anon key: no Worker CPU), then shows the next photo every 0.9 s as a crossfade, with
//   progress dots; leaving the card fades back to the cover. Only the next photo is downloaded ahead, never the set;
// - a finger swiping across the photo of a card in a grid moves to the next or previous photo (a card in a horizontal
//   rail keeps the rail's swipe); the tap that follows a swipe is not a click, a plain tap still opens the car;
// - under prefers-reduced-motion nothing cycles on its own (a swipe still changes the photo, at once).
// The layers live in the card's .car-card__deck, which React renders empty with dangerouslySetInnerHTML, so React
// never diffs or hydrates what is added here. At most data-max photos (the cover counts), 5 by default and never past
// the photos the phone number box leaves free (0280).

export const CYCLE_MS = 900;
const INTENT_MS = 120;
const SWIPE_PX = 36;

type Card = { el: HTMLElement; deck: HTMLElement; layers: HTMLImageElement[]; at: number; timer: number; list: Photo[] | null };

const lists = new Map<string, Promise<Photo[]>>();
function photosOf(slug: string, max: number): Promise<Photo[]> {
  let p = lists.get(slug);
  if (!p) {
    p = publicRead<Photo[] | null>('vehicle_photos_public', { p_slug: slug })
      .then((rows) => (Array.isArray(rows) ? rows : []).filter((x) => x && typeof x.path === 'string' && !x.is_cover && !x.sample))
      .catch(() => []);
    lists.set(slug, p);
  }
  return p.then((rows) => rows.slice(0, Math.max(0, max - 1)));
}

const srcSetOf = (p: Photo) => (p.variants?.length ? p.variants.map((v) => `${photoUrl(v.path)} ${v.width}w`).join(', ') : '');

export function cardPhotos(): () => void {
  const state = new WeakMap<HTMLElement, Card>();
  let hovered: Card | null = null;
  let intent = 0;
  let swipe: { card: Card; x: number; y: number; id: number } | null = null;
  let swiped: { el: HTMLElement; at: number } | null = null;

  const cardOf = (t: EventTarget | null) => {
    const el = (t as Element | null)?.closest?.('.car-card') as HTMLElement | null;
    const deck = el?.querySelector<HTMLElement>(':scope > .car-card__media > .car-card__deck');
    if (!el || !deck || !deck.dataset.slug) return null;
    let c = state.get(el);
    if (!c || c.deck !== deck) { c = { el, deck, layers: [], at: 0, timer: 0, list: null }; state.set(el, c); }
    return c;
  };

  const load = async (c: Card) => {
    if (c.list) return c.list;
    const max = Math.min(5, Math.max(1, Number(c.deck.dataset.max) || 5));
    c.list = await photosOf(c.deck.dataset.slug!, max);
    if (c.list.length && !c.deck.querySelector('.car-card__dots')) {
      const dots = document.createElement('span'); dots.className = 'car-card__dots';
      for (let i = 0; i <= c.list.length; i++) dots.appendChild(document.createElement('i'));
      c.deck.appendChild(dots);
    }
    return c.list;
  };
  // the image of photo i (1 based: 0 is the cover under the deck), made when first needed
  const layer = (c: Card, i: number) => {
    if (i < 1 || !c.list || i > c.list.length) return null;
    let img = c.layers[i - 1];
    if (!img) {
      const p = c.list[i - 1]!;
      const cover = c.el.querySelector<HTMLImageElement>('.car-card__media > img');
      img = document.createElement('img');
      img.alt = ''; img.decoding = 'async'; img.draggable = false;
      img.width = p.width ?? cover?.width ?? 1800; img.height = p.height ?? cover?.height ?? 1200;
      const ss = srcSetOf(p); if (ss) { img.srcset = ss; img.sizes = cover?.sizes || '(min-width: 64rem) 33vw, 100vw'; }
      img.src = photoUrl(p.path);
      c.layers[i - 1] = img;
      c.deck.insertBefore(img, c.deck.querySelector('.car-card__dots'));
    }
    return img;
  };
  const ready = (img: HTMLImageElement | null) => !!img && img.complete && img.naturalWidth > 0;
  const show = (c: Card, i: number) => {
    c.at = i;
    c.layers.forEach((img, k) => img.classList.toggle('is-on', k === i - 1));
    c.deck.querySelectorAll('.car-card__dots > i').forEach((d, k) => { d.classList.toggle('is-on', k === i); d.classList.toggle('is-past', k < i); });
    c.deck.dataset.at = String(i);
    layer(c, i + 1); // the next one starts downloading now
  };
  const stop = (c: Card) => {
    window.clearTimeout(c.timer); c.timer = 0;
    c.el.classList.remove('is-cycling');
    show(c, 0);
  };
  const tick = (c: Card) => {
    c.timer = window.setTimeout(() => {
      if (hovered !== c || !c.list) return;
      const n = c.list.length + 1, next = (c.at + 1) % n;
      if (next === 0 || ready(layer(c, next))) show(c, next);
      tick(c);
    }, CYCLE_MS);
  };
  const start = (c: Card) => {
    window.clearTimeout(intent);
    intent = window.setTimeout(async () => {
      const list = await load(c);
      if (hovered !== c || !list.length) return;
      c.el.classList.add('is-cycling');
      if (!c.timer) { show(c, 0); tick(c); }
    }, INTENT_MS);
  };

  // ---- mouse: hover to cycle
  const onOver = (e: PointerEvent) => {
    if (e.pointerType === 'touch') return;
    const c = cardOf(e.target);
    if (c === hovered) return;
    if (hovered) stop(hovered);
    hovered = c;
    if (c && motionOK()) start(c);
  };
  const onOut = (e: PointerEvent) => {
    if (!hovered || e.pointerType === 'touch') return;
    const to = e.relatedTarget as Node | null;
    if (to && hovered.el.contains(to)) return;
    window.clearTimeout(intent);
    stop(hovered); hovered = null;
  };

  // ---- touch: swipe the photo of a card in a grid
  const onDown = (e: PointerEvent) => {
    if (e.pointerType !== 'touch' || !e.isPrimary) return;
    const c = cardOf(e.target);
    if (!c || c.el.closest('.rail')) return;
    const m = c.el.querySelector('.car-card__media')!.getBoundingClientRect();
    if (e.clientX < m.left || e.clientX > m.right || e.clientY < m.top || e.clientY > m.bottom) return;
    swipe = { card: c, x: e.clientX, y: e.clientY, id: e.pointerId };
    void load(c).then(() => layer(c, 1));
  };
  const onUp = (e: PointerEvent) => {
    const s = swipe; swipe = null;
    if (!s || e.pointerId !== s.id) return;
    const dx = e.clientX - s.x, dy = e.clientY - s.y;
    if (Math.abs(dx) < SWIPE_PX || Math.abs(dx) < Math.abs(dy) * 1.4) return;
    swiped = { el: s.card.el, at: performance.now() };
    const c = s.card;
    void load(c).then((list) => {
      if (!list.length) return;
      const n = list.length + 1, next = (c.at + (dx < 0 ? 1 : -1) + n) % n;
      c.el.classList.add('is-swiped');
      const img = layer(c, next);
      if (next === 0 || ready(img)) show(c, next);
      else img?.addEventListener('load', () => show(c, next), { once: true });
    });
  };
  const onCancel = () => { swipe = null; };
  // the click a browser may still send after a swipe opens nothing
  const onClick = (e: MouseEvent) => {
    if (!swiped || performance.now() - swiped.at > 600) return;
    if (swiped.el.contains(e.target as Node)) { e.preventDefault(); e.stopPropagation(); }
    swiped = null;
  };

  document.addEventListener('pointerover', onOver, { passive: true });
  document.addEventListener('pointerout', onOut, { passive: true });
  document.addEventListener('pointerdown', onDown, { passive: true });
  document.addEventListener('pointerup', onUp, { passive: true });
  document.addEventListener('pointercancel', onCancel, { passive: true });
  window.addEventListener('click', onClick, true); // before the page transition's own capture listener
  return () => {
    window.clearTimeout(intent);
    if (hovered) stop(hovered);
    document.removeEventListener('pointerover', onOver);
    document.removeEventListener('pointerout', onOut);
    document.removeEventListener('pointerdown', onDown);
    document.removeEventListener('pointerup', onUp);
    document.removeEventListener('pointercancel', onCancel);
    window.removeEventListener('click', onClick, true);
  };
}
