import { NextResponse } from 'next/server';
import { rpc } from '@/lib/db/repo';
import { jobAuthorized } from '@/server/job-auth';
import { renderGuide } from '@/features/guides/markdown';
import { REWRITE_SCHEMA, REWRITE_SYSTEM, rewritePrompt, rewriteProblems, type SectionFacts } from '@/features/guides/upkeep';

// The guides keep up with the portals (migration 0055), with the jobs' bearer token (web/scripts/guide-upkeep.mjs):
//   GET   ?run=<id>  every published section, with the screenshots this run replaced in it
//   POST  {section_id, run, reason, facts, labels}: Workers AI rewrites the section, held to the facts read from the code;
//         a rewrite that passes the checks is published at once (the old text kept for the one-click revert), one that
//         does not is kept as a suggestion to review in Admin > Settings > Guides
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
  const r = await gen.generate<{ body_md?: string; summary?: string }>({ task: 'guide_rewrite', system: REWRITE_SYSTEM, prompt: rewritePrompt(s.title, s.body_md, p.facts, reason),
    schema: REWRITE_SCHEMA, maxOutputTokens: 4000, temperature: 0.1 });
  if (!r.ok) return NextResponse.json({ ok: false, result: 'model', reason: r.reason, message: r.message });
  const body = (r.data.body_md ?? '').replace(/ ?[—–] ?/g, ', ').replace(/\r\n/g, '\n').trim() + '\n';
  const problems = rewriteProblems(s.body_md, body, p.labels);
  // the HTML the portals read, rendered as publishing renders it
  let html = '';
  const rendered = renderGuide([{ id: s.id, slug: s.slug, kind: s.kind, title: s.title, body_md: body }]);
  if (rendered.warnings.length) problems.push(`the text does not render: ${rendered.warnings.slice(0, 2).join('; ')}`);
  else html = rendered.html[s.id] ?? '';
  const out = await rpc('server_guide_auto_update', { p: { section_id: s.id, body_md: body, html, reason, run: p.run ?? 'manual', model: r.model,
    neurons: r.usage.neurons, duration_ms: Date.now() - t0, checks_ok: problems.length === 0, problems: problems.join('; ') } }, SR);
  return NextResponse.json({ ok: true, summary: r.data.summary ?? '', problems, ...(out as unknown as Record<string, unknown>) });
}
