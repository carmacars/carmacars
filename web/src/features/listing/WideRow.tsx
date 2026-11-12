'use client';
import { useEffect, useRef, type ReactNode } from 'react';

// r41: an editor opened from a photo of the listing review shows right under that photo, across the whole grid, and is
// scrolled into view with the focus on it. It was drawn after the last photo: with 20 photos "Cover the plate" seemed to
// do nothing, the editor opening far below the screen.
export function WideRow({ children, label }: { children: ReactNode; label: string }) {
  const ref = useRef<HTMLLIElement>(null);
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    el.scrollIntoView?.({ behavior: 'smooth', block: 'start' });
    el.querySelector<HTMLElement>('canvas[tabindex], button')?.focus({ preventScroll: true });
  }, []);
  return <li ref={ref} className="ad-photos__wide" aria-label={label} data-testid="photo-editor-row">{children}</li>;
}
