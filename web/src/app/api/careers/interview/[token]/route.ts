import { NextResponse } from 'next/server';
import { answerQuestion, startInterview, TOKEN } from '@/server/interviews';
import { MAX_ANSWER_SECONDS, MAX_AUDIO_BYTES } from '@/features/careers/ai-interview';

// The AI interview's answers (migration 0380), from the candidate's page: no sign-in, the personal link's token is the
// key. POST form data: start (the consent), or an answer: seq, mode (voice with the audio file, or typed with the text),
// seconds. The answer goes back with the next question (or a follow-up, or the end). Same-site only.
export const dynamic = 'force-dynamic';

export async function POST(req: Request, { params }: { params: Promise<{ token: string }> }) {
  const { token } = await params;
  const origin = req.headers.get('origin');
  if (origin && new URL(origin).host !== req.headers.get('host')) return NextResponse.json({ ok: false, message: 'Not permitted.' }, { status: 403 });
  if (!TOKEN.test(token ?? '')) return NextResponse.json({ ok: false, message: 'This link is not valid.' }, { status: 404 });
  if (Number(req.headers.get('content-length') ?? 0) > MAX_AUDIO_BYTES + 64 * 1024) return NextResponse.json({ ok: false, message: 'That recording is too long. Please answer in under two minutes.' }, { status: 413 });
  try {
    const f = await req.formData();
    if (f.get('start') === '1') {
      if (f.get('consent') !== '1') return NextResponse.json({ ok: false, message: 'Please agree to the recording first.' }, { status: 400 });
      const v = await startInterview(token);
      return v.ok ? NextResponse.json({ ok: true, view: v }) : NextResponse.json({ ok: false, message: 'This interview is closed.' }, { status: 409 });
    }
    const seq = Number(f.get('seq'));
    const mode = f.get('mode') === 'voice' ? 'voice' : f.get('mode') === 'typed' ? 'typed' : null;
    if (!Number.isInteger(seq) || seq < 1 || seq > 40 || !mode) return NextResponse.json({ ok: false, message: 'Something is missing. Reload the page.' }, { status: 400 });
    const audio = f.get('audio');
    const blob = mode === 'voice' && audio instanceof Blob ? audio : null;
    if (mode === 'voice' && !blob) return NextResponse.json({ ok: false, message: 'The recording did not arrive. Please try again, or type your answer.' }, { status: 400 });
    const seconds = Math.min(Math.max(Number(f.get('seconds')) || 0, 0), MAX_ANSWER_SECONDS + 30);
    const r = await answerQuestion(token, { seq, mode, text: mode === 'typed' ? String(f.get('text') ?? '').slice(0, 4000) : undefined,
      audio: blob ? new Uint8Array(await blob.arrayBuffer()) : undefined, type: blob?.type || String(f.get('type') ?? ''), seconds });
    return r.ok ? NextResponse.json({ ok: true, view: r.view, heard: r.heard }) : NextResponse.json({ ok: false, message: r.message }, { status: r.status });
  } catch (e) {
    console.error('interview answer', e instanceof Error ? `${e.name}: ${e.message}`.slice(0, 300) : e);
    return NextResponse.json({ ok: false, message: 'We could not keep that answer. Please try again in a moment.' }, { status: 500 });
  }
}
