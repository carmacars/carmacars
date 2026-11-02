'use client';
import { useState } from 'react';

// A small Copy button beside one value of a Marketplace kit (migration 0410).
export function CopyValue({ value, label }: { value: string; label: string }) {
  const [done, setDone] = useState(false);
  if (!value) return null;
  const copy = () => { void navigator.clipboard?.writeText(value).then(() => { setDone(true); setTimeout(() => setDone(false), 1400); }); };
  return <button type="button" className="mp-copy" onClick={copy} aria-label={`Copy ${label}`}>{done ? 'Copied' : 'Copy'}</button>;
}
