'use client';
import { useState, useTransition } from 'react';
import type { ActionResult } from '@/features/forms/schemas';

/** Runs a server action from an event handler and keeps its result; a redirect from the action navigates. */
export function useAct<T = null>() {
  const [pending, start] = useTransition();
  const [res, setRes] = useState<ActionResult<T> | null>(null);
  const run = (fn: () => Promise<ActionResult<T>>, after?: (r: ActionResult<T>) => void) =>
    start(async () => { const r = await fn(); setRes(r); after?.(r); });
  const err = (k: string) => (res && !res.ok ? res.fieldErrors?.[k] : undefined);
  return { pending, res, run, setRes, err };
}
