// A QR code as a self-contained SVG string, made at build time. Used by the
// `/qr/<token>.svg` endpoint (src/pages/qr/[token].svg.ts) for the Get Waycar
// picker's desktop tile. `qrcode-generator` is a build-time dependency only:
// the page ships the finished SVG, with no script and no request to any other
// origin.
import qrcode from 'qrcode-generator';

/** Quiet zone the QR specification asks for, in modules. */
const QUIET_ZONE = 4;

/**
 * `text` as an SVG: black modules on a white ground, one `<path>` of
 * horizontal runs. Error correction M (15%), the smallest version that fits.
 */
export function qrSvg(text: string): string {
  const code = qrcode(0, 'M');
  code.addData(text, 'Byte');
  code.make();
  const modules = code.getModuleCount();
  const size = modules + QUIET_ZONE * 2;
  let path = '';
  for (let row = 0; row < modules; row++) {
    let col = 0;
    while (col < modules) {
      if (!code.isDark(row, col)) {
        col++;
        continue;
      }
      const start = col;
      while (col < modules && code.isDark(row, col)) col++;
      path += `M${start + QUIET_ZONE} ${row + QUIET_ZONE}h${col - start}v1h-${col - start}z`;
    }
  }
  return (
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${size} ${size}" shape-rendering="crispEdges">` +
    `<rect width="${size}" height="${size}" fill="#fff"/><path d="${path}" fill="#000"/></svg>\n`
  );
}
