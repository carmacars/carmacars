import { rgb, type PDFPage } from 'pdf-lib';
import { LOGO_BAR, LOGO_LETTERS, LOGO_VIEWBOX } from './logo-paths.ts';

// The brand logo drawn as vectors on a pdf-lib page (r32): the brand kit's paths (logo-paths.ts), no image file to
// fetch. `top` is the page's y of the logo's top edge; the logo is `width` points wide and about width / 5.66 tall.
export function drawBrandLogo(page: PDFPage, x: number, top: number, width: number, onDark = false) {
  const sc = width / LOGO_VIEWBOX.width;
  const at = { x: x - LOGO_VIEWBOX.x * sc, y: top + LOGO_VIEWBOX.y * sc, scale: sc, borderWidth: 0 };
  page.drawSvgPath(LOGO_LETTERS, { ...at, color: onDark ? rgb(1, 1, 1) : rgb(10 / 255, 10 / 255, 10 / 255) });
  page.drawSvgPath(LOGO_BAR, { ...at, color: rgb(227 / 255, 6 / 255, 19 / 255) });
  return (LOGO_VIEWBOX.height * sc);
}
