'use client';
import { useEffect, useRef } from 'react';
import { playMoment, type MomentKind } from './moment';

/** r35 S2: plays a moment once when the page shows (a server page: the request sent, the booking confirmed). */
export function Moment({ kind }: { kind: MomentKind }) {
  const done = useRef(false);
  useEffect(() => { if (!done.current) { done.current = true; playMoment(kind); } }, [kind]);
  return null;
}
