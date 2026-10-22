import 'server-only';
import { rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import { door } from '@/server/door';
import { env } from '@/lib/env';
import { torontoInstant } from '@/lib/dates';
import { ask, type AssistantModel, type Deps, type Out, type Turn } from '@/features/assistant/agent';
import { claudeModel, fakeModel, workersAiModel } from '@/features/assistant/models';
import type { Portal, VaFn, Who } from '@/features/assistant/tools';
import type { FieldList } from '@/features/field/types';

// The staff assistant as the site runs it (migration 0080). Every read and every change goes through the door as the
// signed-in person, with their session's assurance level: the database decides what they may see and do, exactly as
// for the screens. The model's own use is recorded for the usage guard (the only call made as the service role).
const SR = { role: 'service_role' as const };

/** The model: Claude when ANTHROPIC_API_KEY is set, Workers AI when the Worker has its AI binding, else the stub. */
export async function assistantModel(settings: { claude_model?: string; claude_in_usd_per_m?: number; claude_out_usd_per_m?: number }): Promise<AssistantModel> {
  const key = process.env.ANTHROPIC_API_KEY;
  if (key && process.env.ASSISTANT_PROVIDER !== 'fake') {
    return claudeModel({ key, model: settings.claude_model || 'claude-haiku-4-5', inUsdPerM: Number(settings.claude_in_usd_per_m ?? 1), outUsdPerM: Number(settings.claude_out_usd_per_m ?? 5) });
  }
  if (env().LLM_PROVIDER === 'workers-ai' && process.env.ASSISTANT_PROVIDER !== 'fake') {
    try {
      const { getCloudflareContext } = await import('@opennextjs/cloudflare');
      const { env: cf } = await getCloudflareContext({ async: true });
      const ai = (cf as unknown as { AI?: import('@/integrations/llm/workers-ai').AiBinding }).AI;
      if (ai) return workersAiModel(ai);
    } catch { /* not running in the Worker */ }
  }
  return fakeModel();
}

const todayToronto = () => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date());
const time = (iso: string) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', hour: 'numeric', minute: '2-digit' }).format(new Date(iso));

/** What needs doing today, read the way each portal's home page reads it. */
async function todo(userId: string, aal: 'aal1' | 'aal2' | null, who: Who, extra: Record<string, unknown>): Promise<Out[]> {
  if (who.portal === 'admin') {
    const d = await door<{ items: Array<{ key: string; label: string; button: string; href: string; count: number }>; pickups: Array<{ booking_number: string; at: string; vehicle: string; renter: string }>; returns: Array<{ booking_number: string; at: string; vehicle: string; renter: string; late: boolean }> }>(userId, 'ops_read', 'admin_todo', {}, aal);
    const open = d.items.filter((i) => i.count > 0);
    return [
      { type: 'results', title: open.length ? `${open.reduce((n, i) => n + i.count, 0)} things need you` : 'Nothing needs you right now', rows: open.map((i) => ({ title: `${i.count} · ${i.label}`, href: i.href })), empty: 'All clear.' },
      { type: 'results', title: `Pickups ${d.pickups.length} and returns ${d.returns.length} today`, rows: [...d.pickups.map((p) => ({ title: `${time(p.at)} pickup ${p.booking_number}`, sub: `${p.renter} · ${p.vehicle}`, href: `/admin/bookings/${p.booking_number}` })),
        ...d.returns.map((p) => ({ title: `${time(p.at)} return ${p.booking_number}${p.late ? ' (late)' : ''}`, sub: `${p.renter} · ${p.vehicle}`, href: `/admin/bookings/${p.booking_number}` }))], empty: 'No pickups or returns today.' }
    ];
  }
  if (who.portal === 'va') {
    const [dg, q] = await Promise.all([
      door<{ open: number; overdue: number; due_today: number; mine: number; pickups_today: number; returns_today: number; requests_waiting: number | null }>(userId, 'va_read', 'digest', extra, aal),
      door<Array<{ task_id: string; title: string; due_at: string | null; overdue: boolean; bucket: string; priority: string }>>(userId, 'va_read', 'queue', extra, aal)
    ]);
    const mine = q.filter((t) => t.bucket === 'mine' || t.bucket === 'unassigned').slice(0, 8);
    return [{ type: 'results', title: `${dg.open} open in your queue, ${dg.overdue} overdue, ${dg.due_today} due today${dg.requests_waiting ? `, ${dg.requests_waiting} requests waiting` : ''}`,
      rows: mine.map((t) => ({ title: `${t.overdue ? 'Overdue: ' : ''}${t.title}`, sub: [t.priority !== 'normal' ? t.priority : '', t.due_at ? `due ${time(t.due_at)}` : '', t.bucket === 'mine' ? 'yours' : 'unassigned'].filter(Boolean).join(' · '), href: `/va/tasks/${t.task_id}` })),
      empty: 'Your queue is clear.' }];
  }
  const f = await door<FieldList>(userId, 'field_read', 'jobs', {}, aal);
  return [{ type: 'results', title: `${f.today.length} job${f.today.length === 1 ? '' : 's'} today`, empty: 'No jobs today.',
    rows: f.today.map((j) => ({ title: `${time(j.scheduled_at)} ${j.kind.replace(/_/g, ' ')}${j.status === 'done' ? ' (done)' : ''}`, sub: [j.vehicle_label, j.plate, j.place, j.renter_first_name].filter(Boolean).join(' · '), href: `/field/jobs/${j.field_job_id}` })) }];
}

export interface AskInput { userId: string; aal: 'aal1' | 'aal2' | null; portal: Portal; fn?: VaFn | null; name?: string | null; text: string; history?: Turn[] }

export async function runAssistant(i: AskInput): Promise<Out[]> {
  const who: Who = { portal: i.portal, fn: i.fn ?? null };
  const extra = i.portal === 'va' && i.fn ? { _va: i.fn } : {};
  // the gate first: Workers AI or Claude, measured now (the usage guard); it also says whether the assistant is on
  const pre = await door<{ claude_model?: string; claude_in_usd_per_m?: number; claude_out_usd_per_m?: number; assistant_enabled?: boolean }>(i.userId, 'ops_read', 'usage_gate',
    { portal: i.portal, service: process.env.ANTHROPIC_API_KEY ? 'claude' : 'workers_ai', ...extra }, i.aal);
  if (pre.assistant_enabled === false) return [{ type: 'text', text: 'The assistant is turned off in Program settings.' }];
  const model = await assistantModel(pre);
  const deps: Deps = {
    who, today: todayToronto(), name: i.name, model,
    gate: async () => (model.service === (process.env.ANTHROPIC_API_KEY ? 'claude' : 'workers_ai') ? pre as { ok: boolean }
      : door<{ ok: boolean }>(i.userId, 'ops_read', 'usage_gate', { portal: i.portal, service: model.service, ...extra }, i.aal)),
    record: async (u) => { await rpc('server_usage_call', { p: { provider: model.name === 'claude' ? `anthropic:${'model' in u ? u.model ?? '' : ''}` : u.model ?? model.name, purpose: 'staff_assistant', ok: u.ok, error: u.error ?? null, duration_ms: u.ms, units: u.units, unit: u.unit } as unknown as Json }, SR); },
    todo: () => todo(i.userId, i.aal, who, extra),
    find: async (kind, q) => (await door<{ rows: Array<Record<string, unknown>> }>(i.userId, 'ops_read', 'assistant_find', { portal: i.portal, kind, q, ...extra }, i.aal)).rows,
    available: async (from, to) => (await rpc('search_available', { p_pickup: torontoInstant(from, '10:00'), p_return: torontoInstant(to, '10:00'), p_filters: {} as Json }, { role: 'anon' })) as unknown as Array<Record<string, unknown>>,
    propose: async (p) => door<{ id: string; summary: string }>(i.userId, 'ops_do', 'assistant_propose', { portal: i.portal, tool: p.tool, name: p.name, args: p.args, summary: p.summary, ...extra }, i.aal)
  };
  return (await ask(deps, { text: i.text, history: i.history })).out;
}

/** Confirm or cancel a card: the stored action runs through the door as the person (app.assistant_confirm). */
export async function decide(i: { userId: string; aal: 'aal1' | 'aal2' | null; portal: Portal; fn?: VaFn | null; id: string; confirm: boolean }): Promise<{ ok: boolean; text: string; result?: unknown }> {
  const extra = i.portal === 'va' && i.fn ? { _va: i.fn } : {};
  if (!i.confirm) {
    await door(i.userId, 'ops_do', 'assistant_cancel', { id: i.id, ...extra }, i.aal);
    return { ok: true, text: 'Cancelled. Nothing was changed.' };
  }
  const r = await door<{ ok: boolean; error?: string; result?: Record<string, unknown> }>(i.userId, 'ops_do', 'assistant_confirm', { id: i.id, ...extra }, i.aal);
  if (!r.ok) return { ok: false, text: `Not done: ${r.error ?? 'the database refused it'}. Nothing was changed.` };
  const x = r.result ?? {};
  const said = typeof x.booking_number === 'string' ? ` Rental ${x.booking_number} added.` : typeof x.invoice_status === 'string' ? ` The invoice is now ${String(x.invoice_status).replace(/_/g, ' ')}.` : '';
  return { ok: true, text: `Done.${said}`, result: r.result };
}
