/**
 * Maakt van gewone telefoonscreenshots de plaatjes voor de App Store en Play Store.
 *
 * Leest   store/screenshots/raw/<toestel>/<n>-wat-dan-ook.png
 * Schrijft store/screenshots/out/<toestel>/<n>.png, op de maat die elke winkel wil.
 *
 * Het nummer voor in de bestandsnaam kiest het bijschrift, dus de volgorde van
 * de bestanden is de volgorde in de winkel. Zelfde opzet als de screenshots van
 * Streepje: een kop, een streepje eronder, het scherm met ronde hoeken en een
 * zachte schaduw. Hier met het JWF-verloop als streepje, zoals op het icoon.
 *
 * Maak de opnames in de demogroep (supabase/demo/demo-groep.sql), niet in de
 * echte groep: dit komt in een openbare winkel te staan.
 *
 * Standaard donker: de app zelf is licht en verdwijnt tegen een lichte achtergrond.
 *
 * Draaien met: npm run screenshots [-- --theme=light] [-- --device=iphone,android]
 */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import sharp from 'sharp';

const repo = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const rawRoot = path.join(repo, 'store/screenshots/raw');
const outRoot = path.join(repo, 'store/screenshots/out');
const font = path.join(
  repo,
  'node_modules/@expo-google-fonts/montserrat/600SemiBold/Montserrat_600SemiBold.ttf',
);

const INK = '#161616';
const PAPER = '#F5F5F6';

// Inkt op het lichte papier, of wit op inkt. Het verloop zelf is een vlak, nooit
// een ondergrond voor witte tekst.
const themes = {
  light: { bg: PAPER, caption: INK, shadow: '#5C5C60' },
  dark: { bg: INK, caption: '#FFFFFF', shadow: '#000000' },
};

/**
 * Wat elke winkel wil, in pixels.
 *
 * Apple vraagt per formaatslot vaste maten, en die veranderen. Het slot dat App
 * Store Connect nu als eerste toont is 6,1/6,3 inch: 1179x2556 of 1206x2622.
 * De eerste is hier gekozen omdat de verhouding (2,1680) vrijwel gelijk is aan
 * die van een opname op een 6,7-inch toestel (2,1674) -- verkleinen zonder
 * bijsnijden.
 *
 * Met `bron` leest een maat uit de raw-map van een ander toestel. Zo vullen
 * dezelfde zes opnamen allebei de sloten, zonder ze twee keer te maken.
 */
const devices = {
  iphone: { width: 1179, height: 2556 },
  "iphone-69": { width: 1320, height: 2868, bron: "iphone" },
  ipad: { width: 2064, height: 2752 },
  android: { width: 1080, height: 1920 },
};

/** Op het nummer voor in de bestandsnaam. */
const captions = {
  1: 'Al je vaarders, per speltak',
  2: 'Per eis afgetekend, met datum en naam',
  3: 'Knopen en commando’s los afstrepen',
  4: 'Een hele bak in één keer aftekenen',
  5: 'Alle eisen van de Watersport Academy',
  6: 'Ook voor vaarders zonder telefoon',
};

const args = Object.fromEntries(
  process.argv.slice(2).map((a) => {
    const [k, v] = a.replace(/^--/, '').split('=');
    return [k, v ?? true];
  }),
);
const theme = themes[args.theme === 'light' ? 'light' : 'dark'];
const wanted = typeof args.device === 'string' ? args.device.split(',') : Object.keys(devices);

const round = (w, h, r) =>
  Buffer.from(`<svg width="${w}" height="${h}"><rect width="${w}" height="${h}" rx="${r}" ry="${r}"/></svg>`);

const rule = (w, h) =>
  Buffer.from(`<svg width="${w}" height="${h}" xmlns="http://www.w3.org/2000/svg">
    <defs><linearGradient id="jwf" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0" stop-color="#1E8CCA"/><stop offset="0.5" stop-color="#34A0A2"/><stop offset="1" stop-color="#5ABC5B"/>
    </linearGradient></defs>
    <rect width="${w}" height="${h}" rx="${h / 2}" fill="url(#jwf)"/></svg>`);

async function caption(text, width, fontSize) {
  return sharp({
    text: {
      text: `<span foreground="${theme.caption}">${text.replace(/&/g, '&amp;')}</span>`,
      font: `Montserrat ${fontSize}`,
      fontfile: font,
      rgba: true,
      width,
      align: 'centre',
      wrap: 'word',
    },
  })
    .png()
    .toBuffer({ resolveWithObject: true });
}

async function compose(device, file) {
  const { width, height } = devices[device];
  const number = Number(path.basename(file).split('-')[0]);
  const text = captions[number] ?? '';

  // Een band tekst bovenaan, het scherm eronder, en ruim lucht rondom zodat op
  // een kleine voorvertoning in de winkel niets tegen de rand zit.
  const side = Math.round(width * 0.08);
  const top = Math.round(height * 0.045);
  const fontSize = Math.round(width * 0.052);
  const shotTop = Math.round(height * 0.15);
  const shotWidth = width - side * 2;
  const shotHeight = height - shotTop - Math.round(height * 0.045);
  const radius = Math.round(shotWidth * 0.055);

  const shot = await sharp(file)
    .resize({ width: shotWidth, height: shotHeight, fit: 'contain', background: { r: 0, g: 0, b: 0, alpha: 0 } })
    .toBuffer({ resolveWithObject: true });

  // De doorzichtige rand die "contain" toevoegt weer weg, zodat de rand om het scherm sluit.
  const framed = await sharp(shot.data).trim({ threshold: 0 }).toBuffer({ resolveWithObject: true });

  const rounded = await sharp(framed.data)
    .composite([{ input: round(framed.info.width, framed.info.height, radius), blend: 'dest-in' }])
    .png()
    .toBuffer({ resolveWithObject: true });

  const shadow = await sharp({
    create: { width: rounded.info.width, height: rounded.info.height, channels: 4, background: theme.shadow },
  })
    .composite([{ input: round(rounded.info.width, rounded.info.height, radius), blend: 'dest-in' }])
    .blur(Math.round(width * 0.02))
    .png()
    .toBuffer();

  const { data: label, info: labelInfo } = await caption(text, width - side * 2, fontSize);
  const ruleWidth = Math.round(width * 0.09);
  const ruleHeight = Math.max(6, Math.round(height * 0.0028));
  const ruleTop = top + labelInfo.height + Math.round(height * 0.02);
  const left = Math.round((width - rounded.info.width) / 2);

  const outDir = path.join(outRoot, device);
  fs.mkdirSync(outDir, { recursive: true });
  const out = path.join(outDir, `${String(number).padStart(2, '0')}.png`);

  // Geen alfakanaal: Apple weigert screenshots met transparantie.
  await sharp({ create: { width, height, channels: 4, background: theme.bg } })
    .composite([
      { input: label, top, left: Math.round((width - labelInfo.width) / 2) },
      { input: rule(ruleWidth, ruleHeight), top: ruleTop, left: Math.round((width - ruleWidth) / 2) },
      { input: shadow, top: shotTop + Math.round(height * 0.006), left },
      { input: rounded.data, top: shotTop, left },
    ])
    .flatten({ background: theme.bg })
    .removeAlpha()
    .png()
    .toFile(out);

  return { out, text, size: `${width}x${height}` };
}

let made = 0;
for (const device of wanted) {
  const dir = path.join(rawRoot, devices[device].bron ?? device);
  if (!fs.existsSync(dir)) {
    console.log(`(overgeslagen) geen map ${path.relative(repo, dir)}`);
    continue;
  }
  const files = fs.readdirSync(dir).filter((f) => /\.(png|jpe?g)$/i.test(f)).sort();
  if (files.length === 0) console.log(`(leeg) ${path.relative(repo, dir)}`);
  for (const file of files) {
    const result = await compose(device, path.join(dir, file));
    console.log(`${device}  ${result.size}  ${path.basename(result.out)}  "${result.text}"`);
    made += 1;
  }
}
console.log(
  made === 0 ? 'Niets gemaakt: zet eerst opnames in de raw-mappen.' : `${made} plaatjes klaar in store/screenshots/out/`,
);
