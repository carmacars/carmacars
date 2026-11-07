'use client';
import { useState, useTransition } from 'react';
import { useTool } from '@/features/admin/MoreMenu';
import { useRouter } from 'next/navigation';
import { staffDo } from '@/server/actions/staff-tools';

export function BlindSpotBoxesForm({ booking, boxes, refresh }: { booking: string; boxes: Array<{ box: string; label: string; value: string; typed: boolean }>; refresh: string[] }) {
  const router = useRouter();
  const [v, setV] = useState<Record<string, string>>(() => Object.fromEntries(boxes.map((b) => [b.box, b.value])));
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  const tool = useTool('blindspot');
  const Wrap = (tool ? 'div' : 'details') as 'div';
  const changed = boxes.filter((b) => (v[b.box] ?? '') !== b.value);
  const save = () => start(async () => {
    const r = await staffDo<{ saved: number; written_back: string[] }>('blindspot_boxes_save', { booking, boxes: Object.fromEntries(changed.map((b) => [b.box, v[b.box] ?? ''])) }, refresh);
    setMsg(r.ok ? { ok: true, text: `Saved ${r.data.saved} box${r.data.saved === 1 ? '' : 'es'}${r.data.written_back.length ? `; also on the booking: ${r.data.written_back.join(', ')}` : ''}. Open the preview to check it.` } : { ok: false, text: r.message });
    if (r.ok) router.refresh();
  });
  return (
    <Wrap className="stack" data-testid="blindspot-boxes">
      {tool ? <p className="pt-kicker">Type into the Blind Spot agreement</p> : <summary className="link">Type into the Blind Spot agreement</summary>}
      <p className="small muted">Each box as the form prints it; a saved value is drawn in place of the booking&apos;s. Empty a typed box to go back.</p>
      <div className="ad-fields">
        {boxes.map((b) => (
          <div className="field ad-field" key={b.box}>
            <label className="label" htmlFor={`bsb-${b.box}`}>{b.label}{b.typed ? ' (typed)' : ''}</label>
            <input className="input" id={`bsb-${b.box}`} maxLength={200} value={v[b.box] ?? ''} onChange={(e) => setV((s) => ({ ...s, [b.box]: e.target.value }))} data-testid={`bsb-${b.box}`} />
          </div>
        ))}
      </div>
      {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'}><span>{msg.text}</span></p>}
      <div className="row">
        <button className="btn btn--primary btn--sm" type="button" disabled={pending || !changed.length} onClick={save} data-testid="bsb-save">{pending ? 'Saving' : 'Save the corrections'}</button>
        <a className="btn btn--ghost btn--sm" href={`/api/staff/blindspot/${booking}`} target="_blank" rel="noreferrer" data-testid="bsb-preview">Preview the filled form</a>
        {tool && <button className="btn btn--quiet btn--sm" type="button" onClick={() => tool.hide()}>Close</button>}
      </div>
    </Wrap>
  );
}
