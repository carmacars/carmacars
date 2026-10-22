import { NextResponse } from 'next/server';
import { rpc } from '@/lib/db/repo';
import { jobAuthorized } from '@/server/job-auth';
import { renderGuide } from '@/features/guides/markdown';
import { labelOnlyRewrite, REWRITE_ATTEMPTS, REWRITE_SCHEMA, REWRITE_SYSTEM, rewritePrompt, rewriteProblems, type SectionFacts } from '@/features/guides/upkeep';

// The guides keep up with the portals (migration 0055), with the jobs' bearer token (web/scripts/guide-upkeep.mjs):
//   GET   ?run=<id>  every published section, with the screenshots this run replaced in it
//   POST  {section_id, run, reason, facts, labels}: Workers AI rewrites the section, held to the facts read from the code.
//         Nothing waits for review (0059): a rewrite that passes the checks is published at once, whatever an Admin
//         edited (the replaced text kept for the one-click revert); one that fails is asked again, more strictly, up to
//         REWRITE_ATTEMPTS times; if every answer fails, only the button names are fixed in the old text (published when
//         that passes the checks) and the section is logged for the next run, which tries again.
export const dynamic = 'force-dynamic';
const SR = { role: 'service_role' as const };
interface Section { id: string; portal: string; slug: string; kind: 'start' | 'chapter' | 'reference'; title: string; body_md: string; draft_waiting: boolean; is_hidden: boolean }

export async function GET(req: Request) {
  if (!(await jobAuthorized(req))) return new NextResponse('Forbidden', { status: 403 });
  const run = new URL(req.url).searchParams.get('run');
  return NextResponse.json({ ok: true, sections: await rpc('server_guide_upkeep_sections', { p_run: run ?? '' }, SR) });
}

export async function POST(req: Request) {
  if (!(await jobAuthorized(req))) return new NextResponse('Forbidden', { status: 403 });
  const p = (await req.json().catch(() => null)) as { section_id?: string; run?: string; reason?: string; facts?: SectionFacts; labels?: string[] } | null;
  if (!p?.section_id || !p.facts || !Array.isArray(p.labels)) return new NextResponse('section_id, facts and labels are needed', { status: 400 });
  const all = (await rpc('server_guide_upkeep_sections', { p_run: '' }, SR)) as unknown as Section[];
  const s = all.find((x) => x.id === p.section_id);
  if (!s) return new NextResponse('Section not found', { status: 404 });
  const reason = (p.reason ?? 'The screen changed').slice(0, 200);
  const { textGenerator } = await import('@/integrations/llm');
  const gen = await textGenerator();
  const t0 = Date.now();
  const render = (body: string): { html: string; warnings: string[] } => {
    const rendered = renderGuide([{ id: s.id, slug: s.slug, kind: s.kind, title: s.title, body_md: body }]);
    return { html: rendered.warnings.length ? '' : rendered.html[s.id] ?? '', warnings: rendered.warnings };
  };
  const tries: Array<{ attempt: number; problems: string[] }> = [];
  let last: { problems: string[]; model: string; neurons: number; summary: string } = { problems: [], model: 'workers-ai', neurons: 0, summary: '' };
  let neurons = 0;
  for (let attempt = 1; attempt <= REWRITE_ATTEMPTS; attempt++) {
    const r = await gen.generate<{ body_md?: string; summary?: string }>({ task: 'guide_rewrite', system: REWRITE_SYSTEM,
      prompt: rewritePrompt(s.title, s.body_md, p.facts, reason, attempt, last.problems), schema: REWRITE_SCHEMA, maxOutputTokens: 4000, temperature: attempt === 1 ? 0.1 : 0 });
    // Workers AI paused for the day (the usage guard, 0104): stop here, the section keeps its text and the next run tries again
    if (!r.ok && r.reason === 'quota') return NextResponse.json({ ok: false, paused: true, result: 'paused', attempts: attempt, summary: 'Workers AI is paused for today; the next run tries again', problems: [r.message] });
    if (!r.ok) { tries.push({ attempt, problems: [`the model did not answer (${r.reason})`] }); last = { ...last, problems: [] }; continue; }
    neurons += r.usage.neurons ?? 0;
    const body = (r.data.body_md ?? '').replace(/ ?[—–] ?/g, ', ').replace(/\r\n/g, '\n').trim() + '\n';
    const problems = rewriteProblems(s.body_md, body, p.labels);
    const { html, warnings } = render(body);
    if (warnings.length) problems.push(`the text does not render: ${warnings.slice(0, 2).join('; ')}`);
    last = { problems, model: r.model, neurons, summary: r.data.summary ?? '' };
    tries.push({ attempt, problems });
    if (!problems.length && html) {
      const out = await rpc('server_guide_auto_update', { p: { section_id: s.id, body_md: body, html, reason, run: p.run ?? 'manual', model: r.model,
        neurons, duration_ms: Date.now() - t0, checks_ok: true } }, SR);
      return NextResponse.json({ ok: true, attempts: attempt, summary: last.summary, problems: [], ...(out as unknown as Record<string, unknown>) });
    }
  }
  // every answer failed: the old text with only the button names fixed, logged for the next run
  const failed = tries.map((t) => `attempt ${t.attempt}: ${t.problems.join(', ') || 'no answer'}`).join('; ');
  const fixed = labelOnlyRewrite(s.body_md, p.facts.missing ?? []);
  const fixedProblems = fixed.renamed.length ? rewriteProblems(s.body_md, fixed.body_md, p.labels).filter((x) => !/names buttons/.test(x)) : ['no button name to fix'];
  const { html: fixedHtml } = fixed.renamed.length ? render(fixed.body_md) : { html: '' };
  const ok = fixed.renamed.length > 0 && fixedProblems.length === 0 && !!fixedHtml;
  const out = await rpc('server_guide_auto_update', { p: { section_id: s.id, body_md: ok ? fixed.body_md : s.body_md, html: ok ? fixedHtml : '', model: last.model, neurons,
    reason: ok ? `${reason}: the button names were updated (${fixed.renamed.slice(0, 3).join('; ')})` : reason, run: p.run ?? 'manual', duration_ms: Date.now() - t0,
    checks_ok: ok, problems: failed, retry_note: ok ? `The rewrite did not pass the checks (${failed}); only the button names were updated. The next run tries again.` : null } }, SR);
  return NextResponse.json({ ok: true, attempts: tries.length, summary: ok ? `Button names updated: ${fixed.renamed.join('; ')}` : 'Kept the old text; the next run tries again',
    problems: last.problems, labels_only: ok, ...(out as unknown as Record<string, unknown>) });
}
