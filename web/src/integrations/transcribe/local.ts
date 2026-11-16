import type { Transcriber, TranscribeRequest, TranscribeResult } from './types';

// r48 part AI (3095): speech to text on the company's server: whisper.cpp's server (container carmacars-stt, the English
// small model, checked against its published SHA-1 before it is used). The recording never leaves the server and costs
// nothing (no neurons). The server converts any audio (webm, mp3, wav) with ffmpeg (--convert). CPU only: about a third of
// the recording's length, so the timeout grows with it (at least 2 minutes).
export function localTranscriber(base: string, f: typeof fetch = fetch): Transcriber {
  return {
    name: 'local',
    async transcribe(req: TranscribeRequest): Promise<TranscribeResult> {
      const model = 'local:whisper-small.en';
      const timeoutMs = Math.max(120_000, Math.ceil(Math.max(req.seconds, 1) * 1500));
      const ctl = new AbortController();
      const t = setTimeout(() => ctl.abort(), timeoutMs);
      try {
        const form = new FormData();
        const ext = /webm/.test(req.type) ? 'webm' : /ogg|opus/.test(req.type) ? 'ogg' : /wav/.test(req.type) ? 'wav' : /mp4|m4a|aac/.test(req.type) ? 'm4a' : 'mp3';
        form.append('file', new Blob([req.audio as BlobPart], { type: req.type || 'application/octet-stream' }), `audio.${ext}`);
        form.append('response_format', 'json');
        form.append('temperature', '0');
        form.append('language', 'en');
        const r = await f(`${base.replace(/\/$/, '')}/inference`, { method: 'POST', body: form, signal: ctl.signal });
        if (r.status === 503) return { ok: false, reason: 'unavailable', message: 'The server\'s speech model is warming up: try again in a few minutes', model, neurons: 0 };
        if (!r.ok) return { ok: false, reason: 'unavailable', message: `The server's speech model answered ${r.status}`, model, neurons: 0 };
        const j = (await r.json().catch(() => null)) as { text?: unknown; error?: string } | null;
        if (typeof j?.text !== 'string') return { ok: false, reason: 'invalid_output', message: j?.error ? `Speech to text: ${String(j.error).slice(0, 160)}` : 'Speech to text returned no text', model, neurons: 0 };
        return { ok: true, text: j.text.replace(/\s+/g, ' ').trim(), model, neurons: 0 };
      } catch (e) {
        if (e instanceof Error && e.name === 'AbortError') return { ok: false, reason: 'timeout', message: `Speech to text did not answer within ${Math.round(timeoutMs / 1000)} seconds`, model, neurons: 0 };
        return { ok: false, reason: 'unavailable', message: 'The server\'s speech model is not reachable (its container is not running yet)', model, neurons: 0 };
      } finally { clearTimeout(t); }
    }
  };
}
