'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { uploadLogo } from '@/server/actions/admin-portal';

const UPLOAD = {
  light: ['Logo for light backgrounds (SVG, PNG or WebP, under 1 MB)', 'image/svg+xml,image/png,image/webp', 'Logo saved.'],
  dark: ['Logo for dark backgrounds (SVG, PNG or WebP, under 1 MB)', 'image/svg+xml,image/png,image/webp', 'Logo saved.'],
  favicon: ['Browser tab icon (square SVG or PNG, at least 512 by 512)', 'image/svg+xml,image/png', 'Icon saved.'],
  og: ['Sharing image for links on social apps (PNG or JPEG, 1200 by 630, under 3 MB)', 'image/png,image/jpeg', 'Sharing image saved.']
} as const;

export function LogoUpload({ which }: { which: 'light' | 'dark' | 'favicon' | 'og' }) {
  const [label, accept, done] = UPLOAD[which];
  const router = useRouter();
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  return (
    <form className="ad-form" onSubmit={(e) => { e.preventDefault(); const fd = new FormData(e.currentTarget); fd.set('which', which); start(async () => { const r = await uploadLogo(fd); setMsg(r.ok ? { ok: true, text: done } : { ok: false, text: r.message }); if (r.ok) router.refresh(); }); }}>
      <div className="field"><label className="label" htmlFor={`logo-${which}`}>{label}</label>
        <input className="input" id={`logo-${which}`} name="file" type="file" accept={accept} required /></div>
      <div className="row"><button className="btn btn--ghost btn--sm" type="submit" disabled={pending}>{pending ? 'Uploading' : 'Upload'}</button>{msg && <span className={msg.ok ? 'small' : 'ad-err'} role={msg.ok ? 'status' : 'alert'}>{msg.text}</span>}</div>
    </form>
  );
}

