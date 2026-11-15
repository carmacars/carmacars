'use client';
import { useEffect } from 'react';

// r48 (2960): an alert opens the exact row it is about (?job=, ?slot=): the row is marked (.is-focus) and scrolled to
// the middle of the screen once the page is drawn.
export function FocusRow() {
  useEffect(() => {
    const el = document.querySelector<HTMLElement>('[data-focus-row]');
    el?.scrollIntoView({ block: 'center', behavior: 'auto' });
  }, []);
  return null;
}
