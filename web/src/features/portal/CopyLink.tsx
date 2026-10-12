'use client';
import { useState } from 'react';

export function CopyLink({ url, label }: { url: string; label: string }) {
  const [done, setDone] = useState(false);
  return (
    <button type="button" className="btn btn--ghost btn--sm" onClick={() => { navigator.clipboard?.writeText(url).then(() => setDone(true)).catch(() => setDone(false)); }}>
      {done ? 'Link copied' : label}
    </button>
  );
}
