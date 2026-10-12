/**
 * Een titelkaart als eerste screenshot, voor de App Store en de Play Store.
 *
 * Apple kent geen feature graphic — daar is geen tegenhanger van. Wat de kop
 * van een App Store-pagina doet, zijn het icoon en de screenshots. Veel apps
 * maken daarom van hun eerste screenshot een titelkaart, en dat is het
 * dichtstbijzijnde bij wat een feature graphic in de Play Store doet.
 *
 * Zelfde taal als scripts/feature-graphic.mjs en scripts/icons.mjs: het
 * JWF-verloop als vlak, het teken en de tekst in inkt erop. Inkt en niet wit,
 * want tegen dat heldere turquoise en groen haalt witte tekst de contrastnorm
 * niet — zie de huisstijl.
 *
 * De maten zijn die van store-screenshots.mjs, zodat de kaart naast de echte
 * opnamen past zonder bijsnijden.
 *
 *   npm run titelkaart
 *
 * Schrijft store/screenshots/out/<toestel>/00.png. Nul, zodat hij vóór 01 komt
 * te staan; de winkel toont ze op volgorde van bestandsnaam.
 *
 * Nodig: Axis Extrabold, de displayletter van de website. Die staat niet in
 * deze repo — openbaar, en de licentie is niet de onze — maar ernaast, in
 * Desktop\Claude\assets.
 */

import { Resvg } from '@resvg/resvg-js';
import { existsSync, mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const axis = join(root, '..', 'assets', 'Axis_Extrabold.otf');
const segoe = 'C:/Windows/Fonts/segoeui.ttf';
const segoeBold = 'C:/Windows/Fonts/seguisb.ttf';

for (const f of [axis, segoe]) {
  if (!existsSync(f)) throw new Error(`Letter niet gevonden: ${f}`);
}

const INK = '#161616';

/** Dezelfde maten als store-screenshots.mjs. */
const devices = {
  iphone: { width: 1320, height: 2868 },
  android: { width: 1080, height: 1920 },
};

/** Het teken uit icons.mjs, op zijn eigen 1024-raster. */
const glyph = (x, y, scale) => `
  <g transform="translate(${x} ${y}) scale(${scale}) translate(-512 -512)" fill="none"
     stroke="${INK}" stroke-width="52" stroke-linecap="round" stroke-linejoin="round">
    <path d="M362 432 L462 532 L662 332"/>
    <path d="M302 664 C337 636, 372 636, 407 664 S477 692, 512 664 S582 636, 617 664 S687 692, 722 664"/>
  </g>`;

function kaart(W, H) {
  // Alles op de breedte geschaald, zodat beide toestellen dezelfde verhoudingen
  // houden en de tekst niet op het ene formaat als muizenpoot aankomt.
  const s = W / 1320;
  const midden = W / 2;
  const vlak = 420 * s;

  // Het blok echt centreren in plaats van op een vaste fractie zetten: anders
  // staat alles hoog en blijft er een groot leeg vlak onderaan. De hoogte is
  // het vlak plus de tekst eronder.
  const blok = vlak + 380 * s;
  const top = (H - blok) / 2;

  return `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">
  <defs>
    <linearGradient id="jwf" x1="0" y1="0" x2="1" y2="1" gradientUnits="userSpaceOnUse"
                    gradientTransform="scale(${W} ${H})">
      <stop offset="0" stop-color="#1E8CCA"/>
      <stop offset="0.5" stop-color="#34A0A2"/>
      <stop offset="1" stop-color="#5ABC5B"/>
    </linearGradient>
  </defs>
  <rect width="${W}" height="${H}" fill="url(#jwf)"/>

  <rect x="${midden - vlak / 2}" y="${top}" width="${vlak}" height="${vlak}"
        rx="${94 * s}" fill="#FFFFFF" fill-opacity="0.18"/>
  ${glyph(midden, top + vlak / 2, 0.53 * s)}

  <text x="${midden}" y="${top + vlak + 150 * s}" text-anchor="middle"
        font-family="AXIS" font-weight="800" font-size="${118 * s}" fill="${INK}">Vinkje</text>
  <text x="${midden}" y="${top + vlak + 232 * s}" text-anchor="middle"
        font-family="Segoe UI" font-weight="600" font-size="${44 * s}" fill="${INK}">Watersportdiploma's,</text>
  <text x="${midden}" y="${top + vlak + 292 * s}" text-anchor="middle"
        font-family="Segoe UI" font-weight="600" font-size="${44 * s}" fill="${INK}">eis voor eis afgetekend</text>
  <text x="${midden}" y="${top + vlak + 380 * s}" text-anchor="middle"
        font-family="Segoe UI" font-size="${36 * s}" fill="${INK}" fill-opacity="0.78">Scouting Jan Willem Friso</text>
</svg>`;
}

const fonts = [axis, segoe];
if (existsSync(segoeBold)) fonts.push(segoeBold);

for (const [naam, { width, height }] of Object.entries(devices)) {
  const img = new Resvg(kaart(width, height), {
    font: { fontFiles: fonts, loadSystemFonts: false, defaultFontFamily: 'Segoe UI' },
  }).render();

  const dir = join(root, 'store/screenshots/out', naam);
  mkdirSync(dir, { recursive: true });
  const uit = join(dir, '00.png');
  writeFileSync(uit, img.asPng());
  console.log(`${naam.padEnd(8)} ${width}x${height}  00.png`);
}

console.log('\nTitelkaarten klaar. Ze komen vóór 01 te staan in de winkel.');
