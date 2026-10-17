'use client';
import { useEffect, useRef, useState } from 'react';
import type { Photo } from '@/lib/types';
import { photoUrl } from '@/lib/photo';

// Native scroll-snap gallery (prototype .gallery): touch, trackpad and keyboard all move it;
// buttons and thumbnails scroll it. The first photo is the page's LCP image and is never lazy.
export function Gallery({ name, photos }: { name: string; photos: Photo[] }) {
  const track = useRef<HTMLUListElement>(null);
  const [cur, setCur] = useState(0);
  useEffect(() => {
    const t = track.current; if (!t) return;
    let tk = false;
    const on = () => { if (!tk) { tk = true; requestAnimationFrame(() => { tk = false; setCur(Math.round(t.scrollLeft / t.clientWidth)); }); } };
    t.addEventListener('scroll', on, { passive: true }); return () => t.removeEventListener('scroll', on);
  }, []);
  const go = (i: number) => {
    const t = track.current; if (!t) return; const n = Math.max(0, Math.min(photos.length - 1, i));
    const li = t.children[n] as HTMLElement | undefined;
    t.scrollTo({ left: li?.offsetLeft ?? 0, behavior: window.matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth' });
  };
  if (!photos.length) return <div className="gallery"><div className="skeleton sk-img" /></div>;
  return (
    <div className="gallery" aria-roledescription="carousel" aria-label={`${name} photos`}>
      <ul className="gallery__track" tabIndex={0} aria-label="Photos. Use the arrow keys to move between them." ref={track}
        onKeyDown={(e) => { if (e.key === 'ArrowRight') { e.preventDefault(); go(cur + 1); } if (e.key === 'ArrowLeft') { e.preventDefault(); go(cur - 1); } }}>
        {photos.map((g, i) => (
          <li key={g.path} aria-label={`${i + 1} of ${photos.length}`}>
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img src={photoUrl(g.path)} width={g.width ?? 1800} height={g.height ?? 1200} alt={g.alt} sizes="(min-width: 64rem) 62vw, 100vw"
              loading={i === 0 ? 'eager' : 'lazy'} fetchPriority={i === 0 ? 'high' : undefined} decoding="async" />
            {g.sample && <span className="gallery__sample" data-testid="sample-photo-caption">Sample photo. Photos of this car are coming soon.</span>}
          </li>
        ))}
      </ul>
      <div className="gallery__ui">
        <span className="gallery__count"><b className="num">{cur + 1} / {photos.length}</b> <span>{photos[cur]?.label}</span></span>
        <span className="row">
          <button type="button" className="icon-btn" aria-label="Previous photo" disabled={cur === 0} onClick={() => go(cur - 1)}><svg viewBox="0 0 20 20" aria-hidden="true"><path d="M12.5 4l-6 6 6 6" fill="none" stroke="currentColor" strokeWidth="2" /></svg></button>
          <button type="button" className="icon-btn" aria-label="Next photo" disabled={cur === photos.length - 1} onClick={() => go(cur + 1)}><svg viewBox="0 0 20 20" aria-hidden="true"><path d="M7.5 4l6 6-6 6" fill="none" stroke="currentColor" strokeWidth="2" /></svg></button>
        </span>
      </div>
      <ul className="gallery__thumbs" aria-label="Choose a photo">
        {photos.map((g, i) => (
          <li key={g.path}><button type="button" aria-label={`Photo ${i + 1}: ${g.label ?? ''}`} aria-current={i === cur} onClick={() => go(i)}>
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img src={photoUrl(g.path)} width={g.width ?? 1800} height={g.height ?? 1200} alt="" sizes="120px" loading="lazy" decoding="async" />
          </button></li>
        ))}
      </ul>
    </div>
  );
}
