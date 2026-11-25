'use client';
import { useEffect, useRef, useState } from 'react';
import type { Photo } from '@/lib/types';
import { photoUrl } from '@/lib/photo';
import { emitTrack } from '@/lib/track/emit';
import { photoLocked, type GateRules } from '@/features/phone-gate/rules';
import { usePhoneGate, useGatePassed } from '@/features/phone-gate/usePhoneGate';

// The sizes the listing pipeline made of a photo (0022): a phone downloads the one that fits, not the 1800 px original.
const srcSetOf = (g: Photo) => {
  if (!g.variants?.length) return undefined;
  const all = [...g.variants, ...(g.width ? [{ width: g.width, path: g.path }] : [])];
  return [...new Map(all.map((v) => [v.width, v])).values()].sort((a, b) => a.width - b.width).map((v) => `${photoUrl(v.path)} ${v.width}w`).join(', ') || undefined;
};

// Native scroll-snap gallery (prototype .gallery): touch, trackpad and keyboard all move it;
// buttons and thumbnails scroll it. The first photo is the page's LCP image and is never lazy.
// 0280: with the phone number box on, moving past the first free photos (6 by default) asks for a mobile number first,
// then goes to the photo tapped. Every photo stays in the page's HTML (search engines and the JSON-LD see them all).
export function Gallery({ name, photos, gate }: { name: string; photos: Photo[]; gate?: GateRules | null }) {
  const track = useRef<HTMLUListElement>(null);
  const [cur, setCur] = useState(0);
  const passed = useGatePassed();
  const { ask, dialog } = usePhoneGate(gate);
  // r48 AN (3150): the studio renders never count against the free photos, so the car's own photos (after them) are as
  // free to see as before: the phone number box opens only past the free photos of the car's own
  const rendered = photos.filter((g) => g.generated).length;
  // the phone number box counts from the car's real photos, after its renders (3150); since 3701 the public gallery is
  // renders only, so with no real photo after them it counts from the first photo (else it would never open)
  const ungated = rendered < photos.length ? rendered : 0;
  const free = Math.max(1, gate?.free_photos ?? 4) + ungated;
  const scrollTo = (i: number) => {
    const t = track.current; if (!t) return; const n = Math.max(0, Math.min(photos.length - 1, i));
    const li = t.children[n] as HTMLElement | undefined;
    t.scrollTo({ left: li?.offsetLeft ?? 0, behavior: window.matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth' });
  };
  // what the scroll listener and the buttons call: a photo past the free ones opens the box first
  const gated = useRef<{ locked: (i: number) => boolean; open: (i: number) => void }>({ locked: () => false, open: () => undefined });
  useEffect(() => {
    gated.current = {
      locked: (i: number) => !passed && i >= ungated && photoLocked(i - ungated, photos.length - ungated, gate),
      open: (i: number) => { void ask('gallery', () => { gated.current.locked = () => false; scrollTo(i); }); }
    };
  });
  // Live visitors (0086): how many different photos were looked at, told to the beacon at 3, 6 and 10 (and all)
  const seen = useRef(new Set<number>([0]));
  useEffect(() => {
    const s = seen.current; if (s.has(cur)) return; s.add(cur);
    if ([3, 6, 10, photos.length].includes(s.size)) emitTrack({ k: 'photos', d: { n: String(s.size) } });
  }, [cur, photos.length]);
  useEffect(() => {
    const t = track.current; if (!t) return;
    let tk = false;
    const on = () => { if (!tk) { tk = true; requestAnimationFrame(() => {
      tk = false; const i = Math.round(t.scrollLeft / t.clientWidth);
      // a swipe past the free photos: back to the last free one, and the box (then on to the photo swiped to)
      if (gated.current.locked(i)) { const li = t.children[free - 1] as HTMLElement | undefined; t.scrollTo({ left: li?.offsetLeft ?? 0, behavior: 'auto' }); gated.current.open(i); return; }
      setCur(i);
    }); } };
    t.addEventListener('scroll', on, { passive: true }); return () => t.removeEventListener('scroll', on);
  }, [free]);
  // 2026-11-06: a mouse over the photo zooms it a little toward the pointer (motion.css, fine pointers only); this only
  // moves the zoom's origin, once a frame
  const zr = useRef(0);
  const zoomAt = (e: React.PointerEvent<HTMLUListElement>) => {
    if (e.pointerType !== 'mouse' || zr.current) return;
    const img = (e.target as Element).closest('li')?.querySelector('img'); if (!img) return;
    const x = e.clientX, y = e.clientY;
    zr.current = requestAnimationFrame(() => {
      zr.current = 0; const r = img.getBoundingClientRect(); if (!r.width) return;
      img.style.setProperty('--zx', `${Math.round(((x - r.left) / r.width) * 100)}%`);
      img.style.setProperty('--zy', `${Math.round(((y - r.top) / r.height) * 100)}%`);
    });
  };
  const go = (i: number) => { if (gated.current.locked(i)) gated.current.open(i); else scrollTo(i); };
  if (!photos.length) return <div className="gallery"><div className="skeleton sk-img" /></div>;
  // r48 AN (3150): the studio renders come first, the car's own photos after them: said above the gallery, with a way
  // straight to the real photos (never hidden)
  const firstReal = photos.findIndex((g) => g.real);
  const reals = firstReal < 0 ? 0 : photos.length - firstReal;
  return (
    <div className="gallery" aria-roledescription="carousel" aria-label={`${name} photos`}>
    {rendered > 0 && (
      <p className="gallery__note small muted" data-testid="rendered-note">
        <b>Rendered photos.</b> The first {rendered === 1 ? 'photo is a studio render' : `${rendered} photos are studio renders`} made from this car&apos;s own photos.
        {reals > 0 && <> <button type="button" className="link" onClick={() => go(firstReal)} data-testid="see-real-photos">See its real photos ({reals})</button></>}
      </p>
    )}
      <ul className="gallery__track" tabIndex={0} aria-label="Photos. Use the arrow keys to move between them." ref={track}
        onPointerMove={zoomAt}
        onKeyDown={(e) => { if (e.key === 'ArrowRight') { e.preventDefault(); go(cur + 1); } if (e.key === 'ArrowLeft') { e.preventDefault(); go(cur - 1); } }}>
        {photos.map((g, i) => (
          <li key={g.path} aria-label={`${i + 1} of ${photos.length}`} data-wm={g.sample ? undefined : ""}>
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img src={photoUrl(g.path)} srcSet={srcSetOf(g)} width={g.width ?? 1800} height={g.height ?? 1200} alt={g.alt} sizes="(min-width: 64rem) 62vw, 100vw"
              loading={i === 0 ? 'eager' : 'lazy'} fetchPriority={i === 0 ? 'high' : undefined} decoding="async" />
            {g.placeholder && <span className="gallery__sample" data-testid="photos-coming-soon">Photos coming soon</span>}
          </li>
        ))}
      </ul>
      <div className="gallery__ui">
        <span className="gallery__count"><b className="num">{cur + 1} / {photos.length}</b> <span>{photos[cur]?.label}{photos[cur]?.generated ? ' (rendered)' : photos[cur]?.real && rendered > 0 ? ' (real photo)' : ''}</span></span>
        <span className="row">
          <button type="button" className="icon-btn" aria-label="Previous photo" disabled={cur === 0} onClick={() => go(cur - 1)} title={((cur === 0)) ? 'This is the first photo' : undefined}><svg viewBox="0 0 20 20" aria-hidden="true"><path d="M12.5 4l-6 6 6 6" fill="none" stroke="currentColor" strokeWidth="2" /></svg></button>
          <button type="button" className="icon-btn" aria-label="Next photo" disabled={cur === photos.length - 1} onClick={() => go(cur + 1)} title={((cur === photos.length - 1)) ? 'This is the last photo' : undefined}><svg viewBox="0 0 20 20" aria-hidden="true"><path d="M7.5 4l6 6-6 6" fill="none" stroke="currentColor" strokeWidth="2" /></svg></button>
        </span>
      </div>
      <ul className="gallery__thumbs" aria-label="Choose a photo">
        {photos.map((g, i) => (
          <li key={g.path}><button type="button" aria-label={`Photo ${i + 1}: ${g.label ?? ''}`} aria-current={i === cur} onClick={() => go(i)}>
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img src={photoUrl(g.path)} srcSet={srcSetOf(g)} width={g.width ?? 1800} height={g.height ?? 1200} alt="" sizes="120px" loading="lazy" decoding="async" />
          </button></li>
        ))}
      </ul>
      {dialog}
    </div>
  );
}
