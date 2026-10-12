'use client';
import { useState } from 'react';

// Narrows the FAQ as you type (prototype data-faq-filter). Works on the server-rendered list.
export function FaqFilter() {
  const [count, setCount] = useState('');
  return (
    <div className="field">
      <label className="label" htmlFor="faq-q">Search the answers</label>
      <input className="input" id="faq-q" type="search" placeholder="deposit, G2, delivery" autoComplete="off" onChange={(e) => {
        const q = e.target.value.trim().toLowerCase(); let hits = 0;
        document.querySelectorAll<HTMLDetailsElement>('[data-faq-group] details').forEach((d) => { const hit = !q || d.textContent!.toLowerCase().includes(q); d.hidden = !hit; if (hit) hits++; });
        document.querySelectorAll<HTMLElement>('[data-faq-group]').forEach((g) => { g.hidden = !g.querySelector('details:not([hidden])'); });
        const none = document.querySelector<HTMLElement>('[data-faq-none]'); if (none) none.hidden = hits > 0;
        setCount(q ? `${hits} ${hits === 1 ? 'answer' : 'answers'}` : '');
      }} />
      <p className="hint" aria-live="polite">{count}</p>
    </div>
  );
}
