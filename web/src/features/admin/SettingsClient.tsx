'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { inviteStaff, uploadLogo } from '@/server/actions/admin-portal';

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

export function StaffInvite() {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [f, setF] = useState({ email: '', full_name: '', role: 'va', va_function: 'cs', field_function: 'driver' });
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  return (
    <form className="ad-form" data-testid="staff-invite" onSubmit={(e) => { e.preventDefault(); start(async () => { const r = await inviteStaff(f); setMsg(r.ok ? { ok: true, text: `Invitation sent to ${f.email}.` } : { ok: false, text: r.message }); if (r.ok) { setF({ ...f, email: '', full_name: '' }); router.refresh(); } }); }}>
      <div className="ad-fields">
        <div className="field ad-field"><label className="label" htmlFor="si-n">Name</label><input className="input" id="si-n" value={f.full_name} onChange={(e) => setF({ ...f, full_name: e.target.value })} required /></div>
        <div className="field ad-field"><label className="label" htmlFor="si-e">Email</label><input className="input" id="si-e" type="email" value={f.email} onChange={(e) => setF({ ...f, email: e.target.value })} required /></div>
        <div className="field ad-field"><label className="label" htmlFor="si-r">Role</label><select className="select" id="si-r" value={f.role} onChange={(e) => setF({ ...f, role: e.target.value })}><option value="va">Assistant</option><option value="field">Field staff</option><option value="admin">Admin</option></select></div>
        {f.role === 'va' && <div className="field ad-field"><label className="label" htmlFor="si-v">Function</label><select className="select" id="si-v" value={f.va_function} onChange={(e) => setF({ ...f, va_function: e.target.value })}><option value="cs">Customer service</option><option value="sales">Sales</option><option value="fleet">Fleet</option><option value="finance">Finance</option></select></div>}
        {f.role === 'field' && <div className="field ad-field"><label className="label" htmlFor="si-f">Field function</label><select className="select" id="si-f" value={f.field_function} onChange={(e) => setF({ ...f, field_function: e.target.value })}><option value="driver">Driver</option><option value="detailer">Detailer</option><option value="driver_detailer">Driver and detailer</option></select></div>}
      </div>
      <div className="row"><button className="btn btn--primary btn--sm" type="submit" disabled={pending}>{pending ? 'Inviting' : 'Invite'}</button>{msg && <span className={msg.ok ? 'small' : 'ad-err'} role={msg.ok ? 'status' : 'alert'}>{msg.text}</span>}</div>
    </form>
  );
}
