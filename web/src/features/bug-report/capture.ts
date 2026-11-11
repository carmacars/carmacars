'use client';
import { isSensitiveField } from './logs';

// Release 37 (2340): a picture of what the person sees, taken in the browser for free, without any library: the page is
// copied, its form values written in (passwords, card fields and anything marked data-sensitive masked), its styles
// inlined, then drawn through an SVG image onto a canvas. Images from other sites and some fonts may be missing; a browser
// that refuses (Safari taints the canvas) gets null, and the form offers "Capture my screen" (the browser's own screen
// share, one frame) and uploads instead.
const MASK = '••••••';

function styles(): string {
  let css = '';
  for (const sheet of Array.from(document.styleSheets)) {
    try { for (const r of Array.from(sheet.cssRules)) css += `${r.cssText}\n`; } catch { /* another site's sheet: skipped */ }
  }
  return css;
}

function copyPage(): HTMLElement {
  const src = document.documentElement;
  const clone = src.cloneNode(true) as HTMLElement;
  // form values (the copy only has the attributes)
  const a = src.querySelectorAll('input, textarea, select');
  const b = clone.querySelectorAll('input, textarea, select');
  a.forEach((el, i) => {
    const c = b[i] as HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement | undefined;
    if (!c) return;
    const f = el as HTMLInputElement;
    const hidden = isSensitiveField({ type: f.type, name: f.name, autocomplete: f.autocomplete, sensitive: f.closest('[data-sensitive]') !== null });
    if (el instanceof HTMLTextAreaElement) c.textContent = hidden ? MASK : el.value;
    else if (el instanceof HTMLSelectElement) Array.from((c as HTMLSelectElement).options).forEach((o, j) => { if (j === el.selectedIndex) o.setAttribute('selected', ''); else o.removeAttribute('selected'); });
    else if (f.type === 'checkbox' || f.type === 'radio') { if (f.checked) c.setAttribute('checked', ''); else c.removeAttribute('checked'); }
    else c.setAttribute('value', hidden ? (f.value ? MASK : '') : f.value);
    if (hidden && c instanceof HTMLInputElement) c.setAttribute('type', 'text');
  });
  // text marked sensitive
  clone.querySelectorAll('[data-sensitive]:not(input):not(textarea):not(select)').forEach((el) => { el.textContent = MASK; });
  // what cannot or must not be drawn
  clone.querySelectorAll('script, noscript, iframe, video, audio, object, embed, [data-bug-report-ui], link[rel="preload"], link[rel="stylesheet"]').forEach((el) => {
    if (el.tagName === 'IFRAME' || el.tagName === 'VIDEO') {
      const ph = document.createElement('div');
      const r = (el as HTMLElement).getBoundingClientRect?.();
      ph.setAttribute('style', `background:#ddd;width:${r?.width ?? 100}px;height:${r?.height ?? 60}px`);
      el.replaceWith(ph);
    } else el.remove();
  });
  // canvases (charts) as pictures
  const ca = src.querySelectorAll('canvas');
  const cb = clone.querySelectorAll('canvas');
  ca.forEach((el, i) => {
    try { const img = document.createElement('img'); img.src = el.toDataURL(); img.setAttribute('style', el.getAttribute('style') ?? ''); img.width = el.width; img.height = el.height; cb[i]?.replaceWith(img); } catch { /* tainted */ }
  });
  // other sites' images do not draw inside the SVG: keep their place
  clone.querySelectorAll('img').forEach((img) => { if (!img.src.startsWith('data:')) img.removeAttribute('srcset'); });
  return clone;
}

/** The visible part of the page as a PNG (or JPEG when large), or null when this browser cannot draw it. */
export async function capturePage(timeoutMs = 6000): Promise<Blob | null> {
  if (typeof document === 'undefined') return null;
  const work = (async () => {
    const w = window.innerWidth;
    const h = window.innerHeight;
    const clone = copyPage();
    const style = document.createElement('style');
    style.textContent = styles();
    clone.querySelector('head')?.appendChild(style);
    clone.style.setProperty('width', `${w}px`);
    const body = clone.querySelector('body');
    body?.setAttribute('style', `${body.getAttribute('style') ?? ''};margin-top:${-window.scrollY}px;margin-left:${-window.scrollX}px;overflow:hidden`);
    const xml = new XMLSerializer().serializeToString(clone);
    const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}"><foreignObject x="0" y="0" width="100%" height="100%">${xml}</foreignObject></svg>`;
    const img = new Image();
    img.decoding = 'sync';
    const loaded = new Promise<void>((ok, no) => { img.onload = () => ok(); img.onerror = () => no(new Error('draw')); });
    img.src = `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`;
    await loaded;
    const scale = Math.min(window.devicePixelRatio || 1, 2);
    const canvas = document.createElement('canvas');
    canvas.width = Math.round(w * scale);
    canvas.height = Math.round(h * scale);
    const ctx = canvas.getContext('2d');
    if (!ctx) return null;
    ctx.fillStyle = getComputedStyle(document.body).backgroundColor || '#fff';
    ctx.fillRect(0, 0, canvas.width, canvas.height);
    ctx.scale(scale, scale);
    ctx.drawImage(img, 0, 0);
    return toBlob(canvas);
  })();
  const timer = new Promise<null>((r) => setTimeout(() => r(null), timeoutMs));
  try { return await Promise.race([work, timer]); } catch { return null; }
}

/** One frame of the screen, tab or window the person picks (the browser asks them). */
export async function captureScreen(): Promise<Blob | null> {
  const md = navigator.mediaDevices as MediaDevices & { getDisplayMedia?: (o: unknown) => Promise<MediaStream> };
  if (!md?.getDisplayMedia) return null;
  let stream: MediaStream | null = null;
  try {
    stream = await md.getDisplayMedia({ video: { displaySurface: 'browser' }, audio: false, preferCurrentTab: true });
    const video = document.createElement('video');
    video.srcObject = stream;
    video.muted = true;
    await video.play();
    await new Promise((r) => setTimeout(r, 250));
    const canvas = document.createElement('canvas');
    canvas.width = video.videoWidth;
    canvas.height = video.videoHeight;
    canvas.getContext('2d')?.drawImage(video, 0, 0);
    return await toBlob(canvas);
  } catch { return null; } finally { stream?.getTracks().forEach((t) => t.stop()); }
}

async function toBlob(canvas: HTMLCanvasElement): Promise<Blob | null> {
  const png = await new Promise<Blob | null>((r) => { try { canvas.toBlob(r, 'image/png'); } catch { r(null); } });
  if (png && png.size <= 4.5 * 1024 * 1024) return png;
  return new Promise<Blob | null>((r) => { try { canvas.toBlob(r, 'image/jpeg', 0.75); } catch { r(null); } });
}
