'use client';
// React pieces of the motion kit (release 48 AN). Portable: React only. Styles: tokens.css and motion.css next to this.
import { useEffect, useSyncExternalStore, type CSSProperties, type ReactNode } from 'react';
import { motionPaused, setMotionPaused, startMotion, type MotionHooks } from './runtime.ts';

/** Mount once in the root layout. */
export function MotionRuntime({ hooks }: { hooks?: MotionHooks }) {
  const key = JSON.stringify(hooks ?? {});
  useEffect(() => startMotion(JSON.parse(key) as MotionHooks), [key]);
  return null;
}

const PAUSE_EVENT = 'mo-motion-change';
const subscribePause = (cb: () => void) => { window.addEventListener(PAUSE_EVENT, cb); return () => window.removeEventListener(PAUSE_EVENT, cb); };

/** The pause control (WCAG 2.2.2 Pause, Stop, Hide): stops every animation on the site, remembered in this browser. */
export function MotionPauseToggle({ className = '', labels = ['Pause animations', 'Play animations'] }: { className?: string; labels?: [string, string] }) {
  const paused = useSyncExternalStore(subscribePause, motionPaused, () => false);
  return (
    <button type="button" className={className} aria-pressed={paused} onClick={() => { setMotionPaused(!paused); window.dispatchEvent(new Event(PAUSE_EVENT)); }} data-testid="motion-pause">
      {paused ? labels[1] : labels[0]}
    </button>
  );
}

/** A tick that pops and draws itself (after a save); decorative unless a label is given. */
export function SuccessTick({ label, className = '' }: { label?: string; className?: string }) {
  return (
    <svg className={`mo-tick ${className}`.trim()} viewBox="0 0 20 20" role={label ? 'img' : undefined} aria-label={label} aria-hidden={label ? undefined : true}>
      <circle cx="10" cy="10" r="10" fill="currentColor" />
      <path d="M5.5 10.5l3 3 6-7" fill="none" stroke="#fff" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round" pathLength={1} />
    </svg>
  );
}

/** A frame whose cut-out car drives off its side on hover (desktop) or once when scrolled into view (touch), the frame's
 *  background still, then eases back in. `facing`: where the car's nose points in the image (mirrored to face left).
 *  The host (the card) is the element with data-mo-drive-host; without it the frame itself. */
export function DriveFrame({ src, srcSet, sizes, width, height, alt = '', facing = 'left', className = '', style, children }: {
  src: string; srcSet?: string; sizes?: string; width?: number; height?: number; alt?: string; facing?: 'left' | 'right'; className?: string; style?: CSSProperties; children?: ReactNode;
}) {
  return (
    <span className={`mo-drive${facing === 'right' ? ' mo-drive--mirror' : ''} ${className}`.trim()} style={style}>
      {children}
      <span className="mo-drive__car">
        <span className="mo-drive__ghost" aria-hidden="true">
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img src={src} srcSet={srcSet} sizes={sizes} width={width} height={height} alt="" loading="lazy" decoding="async" />
        </span>
        <span className="mo-drive__body">
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img src={src} srcSet={srcSet} sizes={sizes} width={width} height={height} alt={alt} loading="lazy" decoding="async" />
        </span>
      </span>
    </span>
  );
}
