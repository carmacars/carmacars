'use client';
import { createContext, useContext, useEffect, useRef, useState, type ReactNode } from 'react';

// One primary action and a "More" menu for the rest (r32, "declutter"): a card keeps one visible button; the other
// buttons, and the panels some of them open, sit behind More. A card that opens panels wraps itself in ToolsProvider:
// the menu items call show('id'), a ToolPane (or a component that calls useTool) shows when its id is the open one.
const Ctx = createContext<{ mode: string | null; set: (m: string | null) => void } | null>(null);

export function ToolsProvider({ children }: { children: ReactNode }) {
  const [mode, set] = useState<string | null>(null);
  return <Ctx.Provider value={{ mode, set }}>{children}</Ctx.Provider>;
}

/** The panel `id` as a component sees it; null outside a ToolsProvider (the component then keeps its own open state). */
export function useTool(id: string) {
  const c = useContext(Ctx);
  return c ? { open: c.mode === id, show: () => c.set(id), hide: () => c.set(null) } : null;
}

export function ToolPane({ id, children }: { id: string; children: ReactNode }) {
  const t = useTool(id);
  return t?.open ? <>{children}</> : null;
}

/** An item of the More menu that opens the panel `id`. */
export function ToolItem({ id, children, testId }: { id: string; children: ReactNode; testId?: string }) {
  const t = useTool(id);
  return <button type="button" role="menuitem" className="mm__item" onClick={() => t?.show()} data-testid={testId}>{children}</button>;
}

export function MoreMenu({ children, label = 'More', testId }: { children: ReactNode; label?: string; testId?: string }) {
  const ref = useRef<HTMLDetailsElement>(null);
  useEffect(() => {
    const away = (e: Event) => { const d = ref.current; if (d?.open && e.target instanceof Node && !d.contains(e.target)) d.open = false; };
    const esc = (e: KeyboardEvent) => { const d = ref.current; if (e.key === 'Escape' && d?.open) { d.open = false; d.querySelector('summary')?.focus(); } };
    document.addEventListener('pointerdown', away); document.addEventListener('keydown', esc);
    return () => { document.removeEventListener('pointerdown', away); document.removeEventListener('keydown', esc); };
  }, []);
  return (
    <details className="mm" ref={ref} data-testid={testId}>
      <summary className="btn btn--ghost btn--sm mm__btn" aria-haspopup="menu">{label}<svg viewBox="0 0 20 20" aria-hidden="true" width="14" height="14" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M5 8l5 5 5-5" /></svg></summary>
      <div className="mm__list" role="menu" onClick={(e) => { if ((e.target as HTMLElement).closest('button:not(:disabled), a') && ref.current) ref.current.open = false; }}>{children}</div>
    </details>
  );
}
