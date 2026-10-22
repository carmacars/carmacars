import Link from 'next/link';
import { Act } from '@/features/admin/Act';
import { DocumentReview } from '@/features/admin/DocumentReview';
import { InsurerBulk, InsurerConfirm } from '@/features/admin/InsurerConfirm';
import { FirstLastPaid, TermsAgreed } from '@/features/admin/OwnerMoneyPrompts';
import { ManualPaymentForm, PaperSignatureForm } from '@/features/manual/ManualRecords';
import { paperDocs, type ChecklistItem } from '@/features/manual/OwnerChecklist';
import { adminTaskHref } from '@/features/va/tasks';
import { Pop } from './Pop';
import { SpecsConfirm, TrimPick } from './CarFacts';
import { TASK_PROMPTS } from './registry';
import type { Prompt } from './types';
import { groupPrompts } from './group';
import './todo.css';

// Admin > Today as a list of prompts (migration 0078): each line says what to do and why, and its button opens a small
// pop-up that does it in place, pre-filled. A line disappears when its work is done. Most urgent first.
const R = ['/admin'];
const today = () => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date());
const inADay = () => new Date(Date.now() + 86_400_000).toISOString();
const go = (href: string, label: string, testId: string, variant: 'primary' | 'ghost' = 'primary') =>
  <Link prefetch={false} className={`btn btn--sm ${variant === 'primary' ? 'btn--primary' : 'btn--ghost'}`} href={href} data-testid={testId}>{label}</Link>;

function Control({ p }: { p: Prompt }) {
  const tid = `todo-act-${p.key}`;
  switch (p.kind) {
    case 'insurer':
      return <InsurerConfirm vehicleId={p.vehicle_id!} name={p.name ?? ''} testId={tid} refresh={R} />;
    case 'insurer_bulk':
      return <InsurerBulk cars={(p.cars ?? []).map((c) => ({ vehicle_id: c.vehicle_id, name: c.name, plate: c.plate ?? null }))} refresh={R} />;
    case 'first_last_paid':
      return <FirstLastPaid p={p} />;
    case 'terms':
      return <TermsAgreed p={p} />;
    case 'publish': {
      const r = p.rates ?? null;
      return (
        <Act ops action="todo_publish" payload={{ vehicle_id: p.vehicle_id }} label="Set rates and publish" variant="primary" title={`Publish ${p.name}`} submitLabel="Publish now" testId={tid} refresh={R}
          confirm="It goes on the site at once with these rates. Kilometres, deposit and fees stay as they are (the defaults for a car without rates); change them later on the car's Rates tab."
          done="Published." fields={[
            { name: 'daily', label: 'Daily rate', type: 'money', required: true, value: r?.daily ?? p.suggested?.daily_cents ?? null, hint: r?.daily ? 'Its current daily rate.' : p.suggested?.text ? `Suggested: ${p.suggested.text}.` : undefined },
            { name: 'weekend', label: 'Weekend rate, a day (optional)', type: 'money', value: r?.weekend ?? null, hint: 'A price per day, not for the whole weekend. Empty: the daily rate.' },
            { name: 'weekly', label: 'Weekly rate, 7 days (optional)', type: 'money', value: r?.weekly ?? null },
            { name: 'monthly', label: 'Monthly rate, 30 days (optional)', type: 'money', value: r?.monthly ?? null }]} />
      );
    }
    case 'documents':
      return <DocumentReview booking={p.booking_number!} refresh={R} />;
    case 'chat':
      return go(`/admin/chat?id=${p.chat_id}`, 'Open the chat', tid);
    case 'requests':
      return go(`/admin/bookings/${encodeURIComponent(p.booking_number!)}?tab=review`, 'Answer it', tid);
    case 'changes':
      return (
        <span className="ad-actions">
          <Act action="approve_change" payload={{ request: p.request_id }} label="Approve" variant="primary" confirm="The renter is told and the booking changes as they asked." refresh={R} testId={`${tid}-approve`} />
          <Act action="decline_change" payload={{ request: p.request_id }} label="Decline" fields={[{ name: 'reason', label: 'Reason the renter sees', type: 'text', required: true }]} refresh={R} testId={`${tid}-decline`} />
          {go(`/admin/bookings/${encodeURIComponent(p.booking_number!)}?tab=changes`, 'Details', `${tid}-open`, 'ghost')}
        </span>
      );
    case 'applications':
      return go(`/admin/applications/${p.application_id}`, 'Decide', tid);
    case 'invoice_payment':
      return (
        <Pop label="Record payment" title={`Record a payment on ${p.invoice_number}`} testId={tid}>
          <p className="small">{p.owner}. Paid by e-Transfer, cash or cheque: record it here and the invoice is marked paid (a receipt goes to the owner).</p>
          <ManualPaymentForm invoice={p.invoice_id} number={p.invoice_number ?? ''} balance={p.balance_cents ?? 0} today={today()} refresh={R} startOpen prefix="todo" />
          <p className="small"><Link prefetch={false} className="link" href={`/admin/invoices/${encodeURIComponent(p.invoice_number ?? '')}`}>Open the invoice</Link> to void it or send it again.</p>
        </Pop>
      );
    case 'invoice_draft':
      return go(`/admin/invoices/${encodeURIComponent(p.invoice_number!)}`, 'Open the draft', tid);
    case 'paper': {
      const docs = paperDocs((p.docs ?? []) as unknown as ChecklistItem[], p.owner ?? '');
      return (
        <Pop label="Record paper signature" title={`Signed on paper: ${p.owner}`} testId={tid}>
          <p className="small">Only if they signed on paper: choose the document, the date and attach the scan. It then counts as signed.</p>
          <PaperSignatureForm docs={docs} today={today()} refresh={R} startOpen />
          <p className="small"><Link prefetch={false} className="link" href={`/admin/owners/${p.owner_id}`}>Open the owner</Link> to send the signing link again.</p>
        </Pop>
      );
    }
    case 'forms':
      return (
        <span className="ad-actions">
          <Act ops action="form_verify" payload={{ template: p.template_id }} label="Checked: use for owners" variant="primary" testId={tid} refresh={['/admin', '/admin/settings/forms']}
            confirm="Owners' forms of this kind that are not signed yet are filled again from the official PDF, and owners sign that instead of the data sheet. Preview it filled for a car first if you have not." />
          {go(`/admin/settings/forms#${encodeURIComponent(p.form_code ?? '')}`, 'Preview it', `${tid}-preview`, 'ghost')}
        </span>
      );
    case 'trim':
      return <TrimPick p={p} testId={tid} />;
    case 'specs':
      return <SpecsConfirm p={p} testId={tid} />;
    case 'plates':
      return go(`/admin/vehicles/${p.vehicle_id}?tab=listing`, 'Check the plates', tid);
    case 'photos':
      return go(`/admin/vehicles/${p.vehicle_id}?tab=listing`, 'Add photos', tid, 'ghost');
    case 'task': {
      const own = p.task_type ? TASK_PROMPTS[p.task_type] : undefined;
      if (own) { const c = own(p); if (c) return <>{c}</>; }
      const href = adminTaskHref({ task_type: p.task_type ?? '', booking_number: p.booking_number ?? null, vehicle_id: p.vehicle_id ?? null, related_table: p.related_table ?? null, related_id: p.related_id ?? null, owner_id: p.owner_id ?? null, invoice_number: p.invoice_number ?? null });
      return (
        <Pop label="Open" title={p.title} testId={tid}>
          {p.why && <p className="small">{p.why}</p>}
          <div className="ad-actions">
            {href !== '/admin/tasks' && go(href, 'Go to where it is done', `${tid}-go`)}
            <Act action="task_complete" payload={{ id: p.task_id }} label="Done" variant={href === '/admin/tasks' ? 'primary' : 'ghost'} fields={[{ name: 'note', label: 'What you did (optional)' }]} refresh={R} testId={`${tid}-done`} />
            <Act action="task_snooze" payload={{ id: p.task_id }} label="Later" fields={[{ name: 'until', label: 'Bring it back', type: 'datetime', required: true, value: inADay() }, { name: 'reason', label: 'Waiting for', required: true }]} refresh={R} testId={`${tid}-later`} />
          </div>
        </Pop>
      );
    }
    default:
      return null;
  }
}

const WHEN: Record<number, string> = { 1: 'Now', 2: 'Today', 3: 'When you can' };

export function Prompts({ prompts }: { prompts: Prompt[] }) {
  if (!prompts.length) return null;
  return (
    <ol className="gd-list" data-testid="todo-prompts">
      {groupPrompts(prompts).map((l) => 'one' in l ? (
        <li key={l.key} className={`gd-item gd-item--p${l.one.priority}`} data-testid={`prompt-${l.key}`} data-kind={l.one.kind}>
          <span className="gd-when">{WHEN[l.one.priority]}</span>
          <span className="gd-text"><b className="gd-title">{l.one.title}</b>{l.one.why && <span className="gd-why">{l.one.why}</span>}</span>
          <span className="gd-act"><Control p={l.one} /></span>
        </li>) : (
        <li key={l.key} className={`gd-item gd-item--p${l.priority}`} data-testid={`prompt-${l.key}`} data-kind={l.items[0]!.kind} data-count={l.items.length}>
          <span className="gd-when">{WHEN[l.priority]}</span>
          <span className="gd-text"><b className="gd-title">{l.title}</b>{l.items[0]!.why && <span className="gd-why">{l.items[0]!.why}</span>}</span>
          <span className="gd-act">
            <Pop label="Show the list" title={l.title} wide testId={`${l.key}-open`}>
              <ol className="gd-list gd-list--inner">
                {l.items.map((p) => (
                  <li key={p.key} className="gd-item gd-item--inner" data-testid={`prompt-${p.key}`} data-kind={p.kind}>
                    <span className="gd-text"><span className="gd-title">{p.title}</span>{p.why && <span className="gd-why">{p.why}</span>}</span>
                    <span className="gd-act"><Control p={p} /></span>
                  </li>))}
              </ol>
            </Pop>
          </span>
        </li>))}
    </ol>
  );
}
