/**
 * De creative assets voor de App Store: het kopbeeld van de productpagina en
 * het beeld bij de zoekresultaten.
 *
 * Apple kende die lang niet — screenshots en het icoon deden al het werk — maar
 * sinds oktober 2026 staan ze in de specificatie. Drie maten, en Apple is er
 * streng in; ze moeten exact kloppen.
 *
 *   productpagina-kop   3840 x 1646   (21:9)   jpg of png
 *   zoekresultaten      3840 x 2560   (3:2)    jpg of png, min 1920 x 1280
 *   allebei in een      5244 x 2950   (16:9)   alleen png
 *
 * Voor alle drie geldt: geen alfakanaal, geen transparantie. Daar wijst App
 * Store Connect op af, en een PNG met een ongebruikt alfakanaal telt mee —
 * daarom gaat alles hier door flatten() heen.
 *
 * Zelfde taal als het icoon, de feature graphic en de titelkaart: het
 * JWF-verloop als vlak, het teken en de tekst in inkt. Inkt en niet wit, want
 * tegen dat heldere turquoise en groen haalt witte tekst de contrastnorm niet.
 *
 * Het beeld staat links van het midden en blijft uit de onderrand. Apple legt
 * op de productpagina zijn eigen knoppen over de onderkant van het kopbeeld,
 * en wat daar staat raak je kwijt.
 *
 *   npm run apple-assets
 *
 * Nodig: Axis Extrabold, de displayletter van de website. Die staat niet in deze
 * repo — openbaar, en de licentie is niet de onze — maar ernaast, in
 * Desktop\Claude\assets.
 */

import { Resvg } from '@resvg/resvg-js';
import sharp from 'sharp';
import { existsSync, mkdirSync } from 'node:fs';
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

const maten = [
  { naam: 'apple-header-3840x1646', W: 3840, H: 1646, wat: 'productpagina-kop (21:9)' },
  { naam: 'apple-zoek-3840x2560', W: 3840, H: 2560, wat: 'zoekresultaten (3:2)' },
  { naam: 'apple-universeel-5244x2950', W: 5244, H: 2950, wat: 'allebei in een (16:9)' },
];

/** Het teken uit icons.mjs, op zijn eigen 1024-raster. */
const glyph = (x, y, scale) => `
  <g transform="translate(${x} ${y}) scale(${scale}) translate(-512 -512)" fill="none"
     stroke="${INK}" stroke-width="52" stroke-linecap="round" stroke-linejoin="round">
    <path d="M362 432 L462 532 L662 332"/>
    <path d="M302 664 C337 636, 372 636, 407 664 S477 692, 512 664 S582 636, 617 664 S687 692, 722 664"/>
  </g>`;

/**
 * Twee indelingen, want één kan niet goed zijn op 21:9 én op 3:2.
 *
 * Breed (de productpagina-kop): teken links, tekst ernaast — zoals de feature
 * graphic. Minder breed (zoekresultaten, en het 16:9-bestand dat voor allebei
 * dient): teken boven, tekst eronder, alles gecentreerd. Eerst had alles de
 * brede indeling, en dan zweeft er een klein blokje in een groot leeg vlak.
 */
function kaart(W, H) {
  const breed = W / H > 2;
  const achtergrond = `<defs>
    <linearGradient id="jwf" x1="0" y1="0" x2="1" y2="1" gradientUnits="userSpaceOnUse"
                    gradientTransform="scale(${W} ${H})">
      <stop offset="0" stop-color="#1E8CCA"/>
      <stop offset="0.5" stop-color="#34A0A2"/>
      <stop offset="1" stop-color="#5ABC5B"/>
    </linearGradient>
  </defs>
  <rect width="${W}" height="${H}" fill="url(#jwf)"/>`;

  if (breed) {
    // Schalen op de krapste richting: alleen op hoogte liep de ondertitel van
    // het beeld af zodra de verhouding minder breed werd.
    const s = Math.min(H / 1646, W / 3840);
    const vlak = 700 * s;
    const midY = H / 2;

    // De hele groep horizontaal centreren in plaats van hem tegen de linkerkant
    // te zetten. De breedte van de tekst is geschat op de langste regel -- exact
    // meten zou de letter moeten laden, en zo nauw komt het niet.
    const tekstBreed = 1560 * s;
    const kier = 150 * s;
    const marge = (W - (vlak + kier + tekstBreed)) / 2;
    const tekstX = marge + vlak + kier;

    return `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">
  ${achtergrond}
  <rect x="${marge}" y="${midY - vlak / 2}" width="${vlak}" height="${vlak}"
        rx="${138 * s}" fill="#FFFFFF" fill-opacity="0.18"/>
  ${glyph(marge + vlak / 2, midY, 0.78 * s)}
  <text x="${tekstX}" y="${midY - 60 * s}" font-family="AXIS" font-weight="800"
        font-size="${186 * s}" fill="${INK}">Vinkje</text>
  <text x="${tekstX + 4 * s}" y="${midY + 40 * s}" font-family="Segoe UI" font-weight="600"
        font-size="${72 * s}" fill="${INK}">Watersportdiploma's, eis voor eis afgetekend</text>
  <text x="${tekstX + 4 * s}" y="${midY + 140 * s}" font-family="Segoe UI"
        font-size="${58 * s}" fill="${INK}" fill-opacity="0.78">Scouting Jan Willem Friso</text>
</svg>`;
  }

  // Gestapeld en gecentreerd. Het hele blok wordt uitgerekend en dan in het
  // midden gezet, zodat er boven en onder evenveel lucht staat — ook dat is wat
  // overleeft als Apple het beeld anders bijsnijdt.
  const s = Math.min(H / 1646, W / 2600);
  const vlak = 700 * s;
  const naTitel = 230 * s;
  const naOnder = 112 * s;
  const naGroep = 96 * s;
  const blok = vlak + naTitel + naOnder + naGroep;
  const top = (H - blok) / 2;
  const midX = W / 2;

  return `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">
  ${achtergrond}
  <rect x="${midX - vlak / 2}" y="${top}" width="${vlak}" height="${vlak}"
        rx="${156 * s}" fill="#FFFFFF" fill-opacity="0.18"/>
  ${glyph(midX, top + vlak / 2, 0.88 * s)}
  <text x="${midX}" y="${top + vlak + naTitel - 40 * s}" text-anchor="middle"
        font-family="AXIS" font-weight="800" font-size="${200 * s}" fill="${INK}">Vinkje</text>
  <text x="${midX}" y="${top + vlak + naTitel + naOnder - 24 * s}" text-anchor="middle"
        font-family="Segoe UI" font-weight="600" font-size="${78 * s}" fill="${INK}">Watersportdiploma's, eis voor eis afgetekend</text>
  <text x="${midX}" y="${top + vlak + naTitel + naOnder + naGroep}" text-anchor="middle"
        font-family="Segoe UI" font-size="${62 * s}" fill="${INK}" fill-opacity="0.78">Scouting Jan Willem Friso</text>
</svg>`;
}

const fonts = [axis, segoe];
if (existsSync(segoeBold)) fonts.push(segoeBold);

const uitDir = join(root, 'assets/store');
mkdirSync(uitDir, { recursive: true });

for (const { naam, W, H, wat } of maten) {
  const rendered = new Resvg(kaart(W, H), {
    font: { fontFiles: fonts, loadSystemFonts: false, defaultFontFamily: 'Segoe UI' },
  }).render();

  const pad = join(uitDir, `${naam}.png`);
  // flatten() haalt het alfakanaal eruit. Een PNG met een ongebruikt
  // alfakanaal wordt alsnog geweigerd, dus dit is geen overbodige stap.
  await sharp(rendered.asPng()).flatten({ background: '#1E8CCA' }).png().toFile(pad);

  const m = await sharp(pad).metadata();
  console.log(
    `${String(m.width).padStart(4)}x${String(m.height).padEnd(5)} alfa:${m.hasAlpha ? 'JA' : 'nee'}  ${wat}`,
  );
}

console.log('\nIn assets/store/. Alle drie zonder alfakanaal, zoals Apple eist.');
