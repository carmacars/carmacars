'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { adminAct, inviteAccount } from '@/server/actions/admin-portal';
import { AddressInput } from '@/features/forms/AddressInput';
import { InfoTip } from '@/components/InfoTip';

// Admin > Investors, Add an investor (0210): the record, and with Invite now (on by default) the invitation through the same
// path as Invite to the investor portal, in one step.
export function AddInvestor({ defaultBps }: { defaultBps: number }) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [pending, start] = useTransition();
  const [f, setF] = useState({ legal_name: '', investor_type: 'individual', signatory_name: '', email: '', phone: '', address: '', committed: '', roi: String(defaultBps / 100), invite: true });
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const set = (k: keyof typeof f) => (e: { target: { value: string } }) => setF((x) => ({ ...x, [k]: e.target.value }));
  const submit = () => start(async () => {
    setMsg(null);
    const committed = f.committed.trim() ? Math.round(Number(f.committed.replace(/[$,\s]/g, '')) * 100) : null;
    const bps = Math.round(Number(f.roi) * 100);
    if (committed !== null && !(committed > 0)) { setMsg({ ok: false, text: 'The amount committed is a number of dollars.' }); return; }
    if (!(bps >= 1 && bps <= 10000)) { setMsg({ ok: false, text: 'The yearly return is a percentage between 0.01 and 100.' }); return; }
    const r = await adminAct<{ id: string; email: string }>('investor_create', { legal_name: f.legal_name, investor_type: f.investor_type, signatory_name: f.investor_type === 'corporation' ? f.signatory_name : null,
      email: f.email, phone: f.phone, address: f.address, committed_amount_cents: committed, offered_yearly_bps: bps }, ['/admin/investors']);
    if (!r.ok) { setMsg({ ok: false, text: r.message }); return; }
    if (f.invite) {
      const name = f.investor_type === 'corporation' ? f.signatory_name || f.legal_name : f.legal_name;
      const inv = await inviteAccount({ role: 'investor', email: r.data.email, full_name: name, investor_id: r.data.id });
      setMsg(inv.ok ? { ok: true, text: inv.data.existed ? 'Added. They already sign in: linked, no email sent.' : `Added and invited: the invitation went to ${inv.data.email}.` } : { ok: false, text: `Added, but the invitation failed: ${inv.message}` });
    } else setMsg({ ok: true, text: 'Added. Invite them from the list when ready.' });
    setF((x) => ({ ...x, legal_name: '', signatory_name: '', email: '', phone: '', address: '', committed: '' }));
    router.refresh();
  });
  if (!open) return <span className="row" style={{ gap: 'var(--s-2)', flexWrap: 'wrap' }}><button type="button" className="btn btn--primary btn--sm" onClick={() => setOpen(true)} data-testid="add-investor">Add an investor</button>{msg && <span className="small" role="status">{msg.text}</span>}</span>;
  return (
    <form className="pt-card stack" aria-labelledby="ai-h" data-testid="add-investor-form" noValidate onSubmit={(e) => { e.preventDefault(); submit(); }}>
      <h2 className="d4" id="ai-h">Add an investor</h2>
      <div className="ad-fields">
        <div className="field ad-field"><label className="label" htmlFor="ai-name">Legal name</label><input className="input" id="ai-name" value={f.legal_name} onChange={set('legal_name')} required data-testid="ai-name" /></div>
        <div className="field ad-field"><label className="label" htmlFor="ai-type">Type</label><select className="select" id="ai-type" value={f.investor_type} onChange={set('investor_type')} data-testid="ai-type"><option value="individual">Individual</option><option value="corporation">Corporation</option></select></div>
        {f.investor_type === 'corporation' && <div className="field ad-field"><label className="label" htmlFor="ai-sign">Person who signs for the corporation</label><input className="input" id="ai-sign" value={f.signatory_name} onChange={set('signatory_name')} data-testid="ai-sign" /></div>}
        <div className="field ad-field"><label className="label" htmlFor="ai-email">Email</label><input className="input" id="ai-email" type="email" value={f.email} onChange={set('email')} required data-testid="ai-email" /></div>
        <div className="field ad-field"><label className="label" htmlFor="ai-phone">Phone</label><input className="input" id="ai-phone" type="tel" value={f.phone} onChange={set('phone')} autoComplete="off" data-testid="ai-phone" /></div>
        <div className="field ad-field ad-field--wide"><label className="label" htmlFor="ai-address">Address</label>
          <AddressInput id="ai-address" name="address" value={{ label: f.address, placeId: '' }} onChange={(v) => setF((x) => ({ ...x, address: v.label }))} placeholder="Start typing the street address" testId="ai-address" anywhere /></div>
        <div className="field ad-field"><label className="label" htmlFor="ai-committed">Amount committed ($, optional)</label><input className="input" id="ai-committed" inputMode="decimal" value={f.committed} onChange={set('committed')} data-testid="ai-committed" /></div>
        <div className="field ad-field"><span className="label-line"><label className="label" htmlFor="ai-roi">Yearly return offered (%)</label><InfoTip k="investor_roi" topic="the yearly return offered" testId="info-ai-roi" /></span>
          <input className="input" id="ai-roi" inputMode="decimal" value={f.roi} onChange={set('roi')} data-testid="ai-roi" /></div>
      </div>
      <label className="check"><input type="checkbox" checked={f.invite} onChange={(e) => setF((x) => ({ ...x, invite: e.target.checked }))} data-testid="ai-invite" /> <span>Invite now: email them a link to set a password for the investor portal</span></label>
      {msg && <p className={msg.ok ? 'small' : 'ad-err'} role={msg.ok ? 'status' : 'alert'} data-testid="ai-msg">{msg.text}</p>}
      <span className="row" style={{ gap: 'var(--s-2)' }}><button className="btn btn--primary btn--sm" type="submit" disabled={pending} data-testid="ai-submit">{pending ? 'Adding' : f.invite ? 'Add and invite' : 'Add the investor'}</button>
        <button className="btn btn--quiet btn--sm" type="button" onClick={() => setOpen(false)}>Close</button></span>
    </form>
  );
}
