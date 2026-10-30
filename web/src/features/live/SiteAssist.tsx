'use client';
import { useEffect, useState, type ComponentType } from 'react';
import { usePathname } from 'next/navigation';

// Live visitors and live chat (migration 0060) on the public site and the renter and owner portals: nothing loads with
// the page. Once the page has loaded and the browser is idle, the beacon and the chat button are fetched as their own
// small files. Staff portals and documents get neither. The discount games' watcher (0069) loads the same way.
const NONE = /^\/(admin|va|field|staff|investor|guide-pdf|sign-document|two-step|read-only|d\/|files)/;

export function SiteAssist() {
  const path = usePathname() ?? '/';
  const off = NONE.test(path);
  const [Widget, setWidget] = useState<ComponentType | null>(null);
  const [Gate, setGate] = useState<ComponentType | null>(null);
  useEffect(() => {
    if (off || Widget) return;
    let done = false;
    const go = () => {
      if (done) return;
      done = true;
      void import('./beacon').then((m) => m.startBeacon());
      void import('./ChatWidget').then((m) => setWidget(() => m.ChatWidget));
      // discount games (0069): the small watcher only; the game loads when a rule fires
      void import('@/features/games/GameGate').then((m) => setGate(() => m.GameGate));
    };
    const idle = () => ('requestIdleCallback' in window ? requestIdleCallback(go, { timeout: 3000 }) : setTimeout(go, 1500));
    if (document.readyState === 'complete') idle();
    else addEventListener('load', idle, { once: true });
    return () => removeEventListener('load', idle);
  }, [off, Widget]);
  if (off || !Widget) return null;
  return <><Widget />{Gate && <Gate />}</>;
}
