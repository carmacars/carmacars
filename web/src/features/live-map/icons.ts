import type { LeadType } from './model';

// One small glyph per kind of pin (24 by 24, drawn in the pin's dark ink on its colour). Our own drawings.
const svg = (d: string) => `<svg viewBox="0 0 24 24" width="100%" height="100%" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round">${d}</svg>`;
export const ICONS: Record<LeadType, string> = {
  on_rent: svg('<path d="M5 16v-4l1.6-4.2A2 2 0 0 1 8.5 6.5h7a2 2 0 0 1 1.9 1.3L19 12v4"/><path d="M4 16h16"/><circle cx="8" cy="16.5" r="1.4"/><circle cx="16" cy="16.5" r="1.4"/>'),
  booking: svg('<path d="M5 12.5l4.2 4.2L19 7"/>'),
  request: svg('<rect x="4.5" y="5.5" width="15" height="14" rx="2"/><path d="M4.5 10h15M9 3.5v4M15 3.5v4"/>'),
  lead: svg('<rect x="4" y="6" width="16" height="12" rx="1.5"/><path d="M4.5 7l7.5 6 7.5-6"/>'),
  draft: svg('<path d="M5 19l1-4L16 5l3 3L9 18z"/><path d="M14 7l3 3"/>'),
  game: svg('<path d="M12 4l2.4 5 5.4.6-4 3.7 1.1 5.3L12 16l-4.9 2.6 1.1-5.3-4-3.7 5.4-.6z"/>'),
  previous: svg('<path d="M9 7L4.5 11.5 9 16"/><path d="M5 11.5h9a5 5 0 0 1 0 10"/>'),
  session: svg('<circle cx="12" cy="12" r="3.2" fill="currentColor"/><path d="M2.8 12S6.3 5.8 12 5.8 21.2 12 21.2 12 17.7 18.2 12 18.2 2.8 12 2.8 12z"/>')
};
