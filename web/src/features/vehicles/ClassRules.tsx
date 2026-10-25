'use client';
import { useState, useTransition } from 'react';
import { opsAct } from '@/server/actions/ops';
import { Act, type Field } from '@/features/admin/Act';
import { Card } from '@/features/admin/ui';
import { ruleThen, ruleWhen, type ClassRule } from '@/features/field-pay/model';

// Admin > Settings > Vehicle class rules (0165): the rules the VIN-first entry reads to decide a new car's class from its make, model,
// trim and body, and the older class once a car is past an age. The lowest rank that matches wins. The database checks every rule
// (a condition, a pattern that compiles, the classes) and writes each change to the audit log.
export interface ClassRulesData { rules: ClassRule[]; classes: Array<{ code: string; label: string }> }

const fieldsFor = (classes: ClassRulesData['classes'], r?: ClassRule): Field[] => {
  const opts = classes.map((c) => [c.code, c.label] as [string, string]);
  return [
    { name: 'rank', label: 'Rank (the lowest that matches wins)', type: 'number', required: true, min: 1, max: 999, value: r?.rank ?? 100 },
    { name: 'make', label: 'Make (for example Porsche)', type: 'text', value: r?.make_key ?? '', hint: 'Spelling and spaces do not matter.' },
    { name: 'model_re', label: 'Model pattern', type: 'text', value: r?.model_re ?? '', hint: 'A pattern, not case sensitive: ^911 matches models that start with 911.' },
    { name: 'trim_re', label: 'Trim pattern', type: 'text', value: r?.trim_re ?? '' }, { name: 'body_re', label: 'Body pattern', type: 'text', value: r?.body_re ?? '' },
    { name: 'class', label: 'Class', type: 'select', required: true, options: opts, value: r?.class ?? 'standard' },
    { name: 'aged_years', label: 'Years old when it changes class', type: 'number', min: 1, max: 60, value: r?.aged_years ?? null, hint: 'Leave empty if age does not matter.' },
    { name: 'aged_class', label: 'The class of an older car', type: 'select', options: opts, value: r?.aged_class ?? null },
    { name: 'note', label: 'Note (shown as the reason for the class)', type: 'text', required: true, value: r?.note ?? '' },
    { name: 'is_active', label: 'On', type: 'bool', value: r ? r.is_active : true }
  ];
};

export function ClassRules({ data }: { data: ClassRulesData }) {
  const R = ['/admin/settings/class-rules'];
  return (
    <>
      <Card title="Rules" testId="class-rules" aside={<Act ops action="class_rule_save" label="Add a rule" variant="primary" testId="rule-add" refresh={R} done="Rule added." fields={fieldsFor(data.classes)} />}>
        <p className="small muted">A new car&apos;s class comes from the first rule that matches it, lowest rank first; a car that matches none is Standard. Changing a rule changes cars entered from now on; a car already listed keeps its class until you change it on the car. Every change is in the audit log.</p>
        <div className="table-scroll ad-scroll" tabIndex={0} role="region" aria-label="Vehicle class rules">
          <table className="ad-table ad-table--dense ad-table--cards" data-testid="rules-table">
            <thead><tr><th scope="col" className="num">Rank</th><th scope="col">When the car is</th><th scope="col">Class</th><th scope="col">Note</th><th scope="col">On</th><th scope="col"><span className="vh">Actions</span></th></tr></thead>
            <tbody>{data.rules.map((r) => (
              <tr key={r.id} data-testid={`rule-${r.id}`}>
                <td data-label="Rank" className="num">{r.rank}</td><td data-label="When the car is" className="wrap">{ruleWhen(r)}</td><td data-label="Class">{ruleThen(r)}</td>
                <td data-label="Note" className="wrap">{r.note}</td><td data-label="On">{r.is_active ? 'Yes' : 'Off'}</td>
                <td><span className="ad-actions">
                  <Act ops action="class_rule_save" payload={{ id: r.id }} label="Change" testId={`rule-edit-${r.id}`} refresh={R} done="Rule changed." fields={fieldsFor(data.classes, r)} />
                  <Act ops action="class_rule_delete" payload={{ id: r.id }} label="Delete" variant="danger" testId={`rule-delete-${r.id}`} refresh={R} done="Rule deleted." confirm={`Delete the rule "${r.note}"? Switch it off instead to keep it.`} /></span></td>
              </tr>))}</tbody>
          </table>
        </div>
      </Card>
      <Tester />
    </>
  );
}

// Try a car: the class the rules give it, and why (the same function the VIN-first entry calls).
function Tester() {
  const [v, setV] = useState({ year: String(new Date().getFullYear()), make: '', model: '', trim: '', body: '' });
  const [out, setOut] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  const set = (k: keyof typeof v) => (e: React.ChangeEvent<HTMLInputElement>) => setV((s) => ({ ...s, [k]: e.target.value }));
  return (
    <Card title="Try a car" testId="rule-test">
      <form className="ad-form" noValidate onSubmit={(e) => { e.preventDefault(); start(async () => {
        const r = await opsAct<{ class_label: string; why: string }>('class_rule_test', { year: v.year ? Number(v.year) : null, make: v.make, model: v.model, trim: v.trim || null, body: v.body || null });
        setOut(r.ok ? { ok: true, text: `${r.data.class_label}: ${r.data.why}` } : { ok: false, text: r.message });
      }); }}>
        <div className="ad-fields">
          <div className="field ad-field"><label className="label" htmlFor="rt-year">Year</label><input id="rt-year" className="input" inputMode="numeric" value={v.year} onChange={set('year')} /></div>
          <div className="field ad-field"><label className="label" htmlFor="rt-make">Make</label><input id="rt-make" className="input" value={v.make} onChange={set('make')} /></div>
          <div className="field ad-field"><label className="label" htmlFor="rt-model">Model</label><input id="rt-model" className="input" value={v.model} onChange={set('model')} /></div>
          <div className="field ad-field"><label className="label" htmlFor="rt-trim">Trim</label><input id="rt-trim" className="input" value={v.trim} onChange={set('trim')} /></div>
          <div className="field ad-field"><label className="label" htmlFor="rt-body">Body</label><input id="rt-body" className="input" value={v.body} onChange={set('body')} /></div>
        </div>
        <div className="row"><button className="btn btn--primary btn--sm" type="submit" disabled={pending} data-testid="rule-test-run">{pending ? 'Working' : 'Which class?'}</button></div>
        {out && <p className={out.ok ? 'small' : 'alert alert--error'} role={out.ok ? 'status' : 'alert'} data-testid="rule-test-result">{out.text}</p>}
      </form>
    </Card>
  );
}
