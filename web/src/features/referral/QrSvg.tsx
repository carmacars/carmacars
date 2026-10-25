import qrcode from 'qrcode-generator';

/** A QR code as inline SVG (server-rendered; the link is the partner's short address). */
export function QrSvg({ text, label }: { text: string; label: string }) {
  const qr = qrcode(0, 'M');
  qr.addData(text);
  qr.make();
  return <div className="fd-qr" role="img" aria-label={label} style={{ maxWidth: 220 }} dangerouslySetInnerHTML={{ __html: qr.createSvgTag({ cellSize: 4, margin: 2, scalable: true }) }} />;
}
