'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { adminAct } from '@/server/actions/admin-portal';
import { STAFF_FN_LABEL, type StaffFn } from '@/features/staff/nav';

const ALL: StaffFn[] = ['cs', 'fleet', 'finance', 'sales', 'field'];

// Admin > Staff (0197): the kinds of staff work a person does, any combination, with the Sales work mode (in person or
// remote) and the field role. The person's staff portal shows the pages of every function ticked.
export function StaffFunctions({ user, functions, salesMode, fieldRole, testId }: { user: string; functions: string[]; salesMode: string | null; fieldRole: string | null; testId?: string }) {
  const router = useRouter();
  const [fns, setFns] = useState<string[]>(functions);
  const [mode, setMode] = useState(salesMode ?? 'in_person');
  const [role, setRole] = useState(fieldRole ?? 'driver_detailer');
  const [msg, setMsg] = useState<string | null>(null);
  const [busy, start] = useTransition();
  const toggle = (f: string, on: boolean) => setFns((x) => (on ? [...x.filter((y) => y !== f), f] : x.filter((y) => y !== f)));
  const save = () => start(async () => {
    setMsg(null);
    if (!fns.length) { setMsg('Choose at least one function.'); return; }
    const r = await adminAct('staff_functions', { user_id: user, functions: fns, sales_work_mode: fns.includes('sales') ? mode : null, field_function: fns.includes('field') ? role : null }, ['/admin/settings/staff']);
    if (!r.ok) { setMsg(r.message); return; }
    setMsg('Saved.');
    router.refresh();
  });
  return (
    <details className="ad-inline" data-testid={testId}>
      <summary className="link small">Functions</summary>
      <fieldset className="stack-s">
        <legend className="small">Staff work this person does</legend>
        {ALL.map((f) => <label key={f} className="check"><input type="checkbox" checked={fns.includes(f)} onChange={(e) => toggle(f, e.target.checked)} data-testid={`fn-${f}`} /> {STAFF_FN_LABEL[f]}</label>)}
        {fns.includes('sales') && <label className="small">Sales work <select className="select" value={mode} onChange={(e) => setMode(e.target.value)} data-testid="fn-sales-mode">
          <option value="in_person">In person</option><option value="remote">Remote</option></select></label>}
        {fns.includes('field') && <label className="small">Field role <select className="select" value={role} onChange={(e) => setRole(e.target.value)} data-testid="fn-field-role">
          <option value="driver">Driver</option><option value="detailer">Detailer</option><option value="driver_detailer">Driver and detailer</option></select></label>}
        <button type="button" className="btn btn--sm btn--primary" onClick={save} disabled={busy} data-testid="fn-save">Save functions</button>
        {msg && <p className="small" role="status">{msg}</p>}
      </fieldset>
    </details>
  );
}
