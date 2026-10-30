import Link from 'next/link';
import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { requireAdmin } from '@/server/admin/data';
import { adminRead } from '@/server/admin/api';
import { Card, PageHead } from '@/features/admin/ui';
import { Act } from '@/features/admin/Act';
import type { Scene } from '@/features/academy/model';
import { LessonPreview } from '@/features/academy/LessonPreview';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Edit an academy section', path: '/admin/academy', noindex: true, description: 'The lessons, scenes and questions of a section.' });

type Sec = { id: string; slug: string; title: string; blurb: string; paths: string[]; lessons: Array<{ id: string; sort: number; title: string; scenes: Scene[] }>;
  questions: Array<{ id: string; sort: number; prompt: string; options: string[]; answer: number; explain: string }> };
const SCENES_HINT = 'A list of scenes: {"caption": "...", "say": "the words the voice says", "visual": {"kind": "title" | "chat" | "list" | "steps" | "money" | "rule", ...}}. title: heading, text; chat: lines [{who, text}] (who "you" is us); list and steps: heading, items; money: heading, rows [[label, amount]], total; rule: heading, text, tone ok or warn.';

// The editor of one section (Release 21b, item 9): its title, each lesson's scenes (with a preview), each question.
export default async function AcademySectionEdit({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/.test(id)) notFound();
  const { user } = await requireAdmin(`/admin/academy/sections/${id}`);
  const s = await adminRead<Sec | null>(user.id, 'academy_content', { section: id });
  if (!s) notFound();
  const here = `/admin/academy/sections/${id}`;
  return (
    <>
      <PageHead title={s.title} kicker="Academy · edit" purpose={`On the paths: ${s.paths.join(', ')}. Changes apply at once for everyone.`}><Link prefetch={false} className="btn btn--sm btn--quiet" href="/admin/academy">Academy</Link></PageHead>
      <Card title="The section">
        <Act action="academy_section_save" payload={{ id: s.id }} label="Edit the title" testId="sec-edit" refresh={[here]} done="Saved."
          fields={[{ name: 'title', label: 'Title', required: true, value: s.title }, { name: 'blurb', label: 'What it covers', type: 'textarea', value: s.blurb }]} />
      </Card>
      {s.lessons.map((l) => (
        <Card key={l.id} title={`Lesson ${l.sort}: ${l.title}`}>
          <LessonPreview lesson={{ id: l.id, title: l.title, scenes: l.scenes }} />
          <span className="row" style={{ gap: 'var(--s-2)', flexWrap: 'wrap' }}>
            <Act action="academy_lesson_save" payload={{ id: l.id }} label="Edit the lesson" testId={`lesson-edit-${l.sort}`} refresh={[here]} done="Saved."
              fields={[{ name: 'title', label: 'Title', required: true, value: l.title }, { name: 'scenes', label: 'Scenes', type: 'json', value: l.scenes, hint: SCENES_HINT }]} />
            <Act action="academy_lesson_delete" payload={{ id: l.id }} label="Delete" variant="danger" confirm={`Delete the lesson "${l.title}"?`} refresh={[here]} />
          </span>
        </Card>
      ))}
      <Card title="Add a lesson">
        <Act action="academy_lesson_save" payload={{ section_id: s.id }} label="Add a lesson" testId="lesson-add" refresh={[here]} done="Added."
          fields={[{ name: 'title', label: 'Title', required: true }, { name: 'scenes', label: 'Scenes', type: 'json', required: true, value: [{ caption: 'The point', say: 'What the voice says.', visual: { kind: 'title', heading: 'The point' } }], hint: SCENES_HINT }]} />
      </Card>
      <Card title={`Quiz (${s.questions.length} questions)`}>
        <ol className="stack">{s.questions.map((q) => (
          <li key={q.id} data-testid={`qe-${q.sort}`}>
            <p><b>{q.prompt}</b></p>
            <ol type="a" className="small">{q.options.map((o, i) => <li key={i}>{o}{i === q.answer ? ' (right answer)' : ''}</li>)}</ol>
            <p className="small muted">{q.explain}</p>
            <span className="row" style={{ gap: 'var(--s-2)', flexWrap: 'wrap' }}>
              <Act action="academy_question_save" payload={{ id: q.id }} label="Edit" testId={`qedit-${q.sort}`} refresh={[here]} done="Saved."
                fields={[{ name: 'prompt', label: 'Question', type: 'textarea', required: true, value: q.prompt }, { name: 'options', label: 'Options (a list)', type: 'json', required: true, value: q.options },
                  { name: 'answer', label: 'Right answer (0 is the first option)', type: 'number', required: true, value: q.answer, min: 0, max: 5 }, { name: 'explain', label: 'Why', type: 'textarea', value: q.explain }]} />
              <Act action="academy_question_delete" payload={{ id: q.id }} label="Delete" variant="danger" confirm="Delete this question?" refresh={[here]} />
            </span>
          </li>))}</ol>
        <Act action="academy_question_save" payload={{ section_id: s.id }} label="Add a question" testId="q-add" refresh={[here]} done="Added."
          fields={[{ name: 'prompt', label: 'Question', type: 'textarea', required: true }, { name: 'options', label: 'Options (a list)', type: 'json', required: true, value: ['', ''] },
            { name: 'answer', label: 'Right answer (0 is the first option)', type: 'number', required: true, value: 0, min: 0, max: 5 }, { name: 'explain', label: 'Why', type: 'textarea' }]} />
      </Card>
    </>
  );
}
