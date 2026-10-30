'use client';
import { useState } from 'react';

// A channel's feed address: a button that copies it (the address itself is long; a link opens it).
export function CopyFeed({ url, label }: { url: string; label: string }) {
  const [done, setDone] = useState(false);
  return <span className="row" style={{ gap: 6, alignItems: 'center' }}>
    <a className="link small" href={url} target="_blank" rel="noopener noreferrer">{label}</a>
    <button type="button" className="btn btn--quiet btn--sm" aria-label={`Copy the ${label} feed address`} onClick={() => { void navigator.clipboard?.writeText(url).then(() => { setDone(true); setTimeout(() => setDone(false), 1500); }); }}>{done ? 'Copied' : 'Copy'}</button>
  </span>;
}
