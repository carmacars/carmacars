// r48 speed (docs/changes/2026-11-20-r48-perf.md): THE loader of the whole site, in this one file. Every loading state uses
// it: the loading.tsx skeletons, the skeleton shown while a page is on its way (RouteProgress), the top progress bar and a
// button whose form is being sent. To change how loading looks (the owner's reel), change this file only: the mark, its
// motion, the shimmer, the bar and the busy button are all here; the skeleton shapes (skeletons.tsx) only place it.
// No 'use client' and no hooks: it renders on the server and in client components alike. Its styles are one <style> tag
// the root layout puts on every page (<BrandLoaderStyles/>), so a busy button looks right on any page. Under
// prefers-reduced-motion nothing moves: the mark and the shimmer hold still and the bar fills without sliding.

type Size = 'sm' | 'md' | 'lg';
const PX: Record<Size, number> = { sm: 18, md: 32, lg: 56 };

/** The CarmaCars mark, pulsing gently, with a word for screen readers. `inline` sits in a line of text or a button. */
export function BrandLoader({ size = 'md', label = 'Loading', inline = false, className = '' }: { size?: Size; label?: string; inline?: boolean; className?: string }) {
  const px = PX[size];
  return (
    <span className={`bl bl--${size}${inline ? ' bl--inline' : ''} ${className}`.trim()} role="status" data-testid="brand-loader">
      <span className="bl__mark" aria-hidden="true" style={{ width: px, height: px }}>
        {/* the brand kit's square mark (public/favicon.svg); cached by every page that shows the favicon */}
        {/* eslint-disable-next-line @next/next/no-img-element */}
        <img src="/favicon.svg" width={px} height={px} alt="" decoding="async" />
      </span>
      <span className="vh">{label}</span>
    </span>
  );
}

/** One shimmering placeholder block (a line of text, a photo, a card). Sizes in CSS lengths. */
export function Shimmer({ w = '100%', h = '1em', r, className = '' }: { w?: string; h?: string; r?: string; className?: string }) {
  return <span className={`bl-sh ${className}`.trim()} aria-hidden="true" style={{ width: w, height: h, ...(r ? { borderRadius: r } : {}) }} />;
}

// The look. --bl-accent is the brand red; the mark pulses (scale and opacity only: no layout moves, CLS stays 0).
export const LOADER_CSS = `
:root { --bl-accent: var(--red-600, #D0111B); --bl-base: var(--grey-200, #E2E2E2); --bl-shine: rgb(255 255 255 / 0.72); --bl-bar-h: 3px; }
.bl { display: inline-flex; align-items: center; justify-content: center; gap: 0.5em; line-height: 1; }
.bl--inline { vertical-align: -0.15em; }
.bl__mark { position: relative; display: inline-block; flex: none; border-radius: 22%; }
.bl__mark img { display: block; width: 100%; height: 100%; border-radius: 22%; }
.bl__mark::after { content: ""; position: absolute; inset: -4px; border-radius: 28%; border: 2px solid var(--bl-accent); opacity: 0; }
.bl-sh { position: relative; display: block; overflow: hidden; background: var(--bl-base); border-radius: 6px; }
.bl-sh::after { content: ""; position: absolute; inset: 0; background: linear-gradient(100deg, transparent 20%, var(--bl-shine) 50%, transparent 80%); transform: translateX(-100%); }
.on-dark .bl-sh, .bl-dark .bl-sh { --bl-base: var(--grey-900, #1A1A1A); --bl-shine: rgb(255 255 255 / 0.08); }
/* the top bar while a page is on its way (RouteProgress) */
.bl-bar { position: fixed; z-index: 2147483000; top: 0; left: 0; right: 0; height: var(--bl-bar-h); pointer-events: none; opacity: 0; transition: opacity 200ms linear 120ms; }
.bl-bar[data-on] { opacity: 1; transition-delay: 0ms; }
.bl-bar__fill { position: absolute; inset: 0; background: var(--bl-accent); transform-origin: 0 50%; transform: scaleX(var(--bl-p, 0)); transition: transform 300ms ease-out; box-shadow: 0 0 8px rgb(208 17 27 / 0.45); }
/* a button whose form is being sent: the mark's pulse as a small ring before the label, the button held still */
.btn[aria-busy="true"], button[data-bl-busy] { cursor: progress; pointer-events: none; }
.btn[aria-busy="true"]::before, button[data-bl-busy]:not(.btn)::before { content: ""; flex: none; display: inline-block; width: 0.9em; height: 0.9em; margin-right: 0.4em; border-radius: 50%; border: 2px solid currentColor; border-right-color: transparent; vertical-align: -0.1em; }
@media (prefers-reduced-motion: no-preference) {
  .bl__mark { animation: bl-pulse 1.4s cubic-bezier(0.4, 0, 0.2, 1) infinite; }
  .bl__mark::after { animation: bl-ring 1.4s cubic-bezier(0.2, 0.7, 0.1, 1) infinite; }
  .bl-sh::after { animation: bl-shimmer 1.3s linear infinite; }
  .btn[aria-busy="true"]::before, button[data-bl-busy]:not(.btn)::before { animation: bl-spin 700ms linear infinite; }
  .bl-bar[data-on] .bl-bar__fill { transition: transform 600ms cubic-bezier(0.1, 0.6, 0.2, 1); }
}
@keyframes bl-pulse { 0%, 100% { transform: scale(0.92); opacity: 0.82; } 50% { transform: scale(1); opacity: 1; } }
@keyframes bl-ring { 0% { transform: scale(0.85); opacity: 0.5; } 100% { transform: scale(1.25); opacity: 0; } }
@keyframes bl-shimmer { to { transform: translateX(100%); } }
@keyframes bl-spin { to { transform: rotate(360deg); } }
`;

/** The loader's styles, once per page (the root layout). React keeps one copy of a <style> with this href. */
export function BrandLoaderStyles() {
  return <style href="cc-brand-loader" precedence="default">{LOADER_CSS}</style>;
}
