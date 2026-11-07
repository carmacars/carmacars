import { NextResponse } from 'next/server';
import { answerQuestion, prepareUpload, startInterview, TOKEN } from '@/server/interviews';
import { MAX_AUDIO_BYTES, MAX_VIDEO_BYTES } from '@/features/careers/ai-interview';

// The AI interview's answers (migration 0380), from the candidate's page: no sign-in, the personal link's token is the
// key. POST form data: start (the consent); prepare (0585: seq, video_type, audio_type: two signed upload links, the
// answer's video and its audio track, which the browser sends straight to private storage); or an answer: seq, mode
// (voice with audio_key and video_key, or the audio file; typed with the text; none when the time ran out), seconds.
// The answer goes back with the next question (or a follow-up, or the end). Same-site only.
export const dynamic = 'force-dynamic';

export async function POST(req: Request, { params }: { params: Promise<{ token: string }> }) {
  const { token } = await params;
  const origin = req.headers.get('origin');
  if (origin && new URL(origin).host !== req.headers.get('host')) return NextResponse.json({ ok: false, message: 'Not permitted.' }, { status: 403 });
  if (!TOKEN.test(token ?? '')) return NextResponse.json({ ok: false, message: 'This link is not valid.' }, { status: 404 });
  if (Number(req.headers.get('content-length') ?? 0) > MAX_AUDIO_BYTES + 64 * 1024) return NextResponse.json({ ok: false, message: 'That recording is too large. Please record it again.' }, { status: 413 });
  try {
    const f = await req.formData();
    if (f.get('start') === '1') {
      if (f.get('consent') !== '1') return NextResponse.json({ ok: false, message: 'Please agree to the recording first.' }, { status: 400 });
      const v = await startInterview(token);
      return v.ok ? NextResponse.json({ ok: true, view: v }) : NextResponse.json({ ok: false, message: 'This interview is closed.' }, { status: 409 });
    }
    const seq = Number(f.get('seq'));
    if (f.get('prepare') === '1') {
      if (!Number.isInteger(seq) || seq < 1 || seq > 40) return NextResponse.json({ ok: false, message: 'Something is missing. Reload the page.' }, { status: 400 });
      const u = await prepareUpload(token, seq, String(f.get('video_type') ?? ''), String(f.get('audio_type') ?? ''));
      return u.ok ? NextResponse.json(u) : NextResponse.json({ ok: false, message: u.message }, { status: u.status });
    }
    const m = f.get('mode');
    const mode = m === 'voice' ? 'voice' : m === 'typed' ? 'typed' : m === 'none' ? 'none' : null;
    if (!Number.isInteger(seq) || seq < 1 || seq > 40 || !mode) return NextResponse.json({ ok: false, message: 'Something is missing. Reload the page.' }, { status: 400 });
    const audioKey = String(f.get('audio_key') ?? '') || undefined;
    const audio = f.get('audio');
    const blob = mode === 'voice' && !audioKey && audio instanceof Blob ? audio : null;
    if (mode === 'voice' && !blob && !audioKey) return NextResponse.json({ ok: false, message: 'The recording did not arrive. Please try again.' }, { status: 400 });
    const seconds = Math.min(Math.max(Number(f.get('seconds')) || 0, 0), 240);
    const videoBytes = Number(f.get('video_bytes')) || 0;
    if (videoBytes > MAX_VIDEO_BYTES) return NextResponse.json({ ok: false, message: 'That video is too large. Please record it again.' }, { status: 413 });
    const r = await answerQuestion(token, { seq, mode, text: mode === 'typed' ? String(f.get('text') ?? '').slice(0, 4000) : undefined,
      audio: blob ? new Uint8Array(await blob.arrayBuffer()) : undefined, type: blob?.type || String(f.get('type') ?? ''), seconds,
      audio_key: audioKey, video_key: String(f.get('video_key') ?? '') || undefined, video_type: String(f.get('video_type') ?? '') || undefined,
      video_bytes: videoBytes || undefined, retakes_used: Number(f.get('retakes_used')) || 0 });
    return r.ok ? NextResponse.json({ ok: true, view: r.view, heard: r.heard }) : NextResponse.json({ ok: false, message: r.message }, { status: r.status });
  } catch (e) {
    console.error('interview answer', e instanceof Error ? `${e.name}: ${e.message}`.slice(0, 300) : e);
    return NextResponse.json({ ok: false, message: 'We could not keep that answer. Please try again in a moment.' }, { status: 500 });
  }
}
