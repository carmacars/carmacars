'use client';
import { useEffect, useState } from 'react';
import { cardPaymentsNow } from '@/server/actions/card-state';
import type { CardPayments } from './card-pay';

// Hotfix 3650: the card state for client card tools, asked once per page load (shared by every tool on the page).
// Until it answers the tools show as before; a failed read keeps them (the database refuses a card call while paused).
let asked: Promise<CardPayments | null> | null = null;
export function useCardPayments(): CardPayments | null {
  const [s, setS] = useState<CardPayments | null>(null);
  useEffect(() => {
    let live = true;
    asked ??= cardPaymentsNow().catch(() => null);
    asked.then((x) => { if (live) setS(x); });
    return () => { live = false; };
  }, []);
  return s;
}
