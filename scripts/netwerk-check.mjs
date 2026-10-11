/**
 * Nakijken dat geen bereik en een weigering uit elkaar gehouden worden.
 *
 * Dit is het scharnier van het offline werken, en het is stil als het fout
 * gaat. Ziet `isNetwerkFout` een echte weigering aan voor netwerkpech, dan
 * verbergt de app die fout achter oude gegevens — dan staat er een beeld op je
 * scherm dat niet klopt en zegt niets dat er iets mis is. Andersom is erger:
 * een netwerkfout die voor een weigering wordt aangezien, laat de wachtrij
 * denken dat opnieuw proberen zinloos is. Daar gaat dan een aftekening aan
 * verloren die iemand op het water heeft gezet.
 *
 *   npm run test:netwerk
 */

import { isNetwerkFout } from '../src/lib/netwerk.ts';

const gevallen = [
  // Geen bereik: hier mag het bewaarde beeld terug, en blijft de wachtrij staan.
  [{ message: 'TypeError: Network request failed' }, true, 'React Native zonder bereik'],
  [new TypeError('Failed to fetch'), true, 'browser zonder bereik'],
  [{ message: 'TypeError: Load failed' }, true, 'iOS/WebKit zonder bereik'],
  [{ message: 'network timeout at https://x.supabase.co' }, true, 'tijd verlopen'],

  // Echte antwoorden van de server: die horen in beeld, niet weggemoffeld.
  // Ze hebben allemaal een code, en dat is waar we op kijken.
  [{ code: 'P0001', message: 'Alleen instructeurs kunnen aftekenen' }, false, 'policy weigert'],
  [{ code: 'PGRST202', message: 'function not found' }, false, 'functie ontbreekt'],
  [{ code: '23505', message: 'duplicate key value' }, false, 'dubbele sleutel'],
  [{ code: '42501', message: 'permission denied' }, false, 'geen rechten'],
  [{ code: 'PGRST301', message: 'JWT expired' }, false, 'sessie verlopen'],
  [null, false, 'niets'],
];

let fout = 0;
for (const [fout_object, verwacht, naam] of gevallen) {
  const uit = isNetwerkFout(fout_object);
  const ok = uit === verwacht;
  if (!ok) fout += 1;
  console.log(`  ${ok ? 'ok  ' : 'FAIL'} ${naam.padEnd(32)} ${uit} (verwacht ${verwacht})`);
}

console.log(
  fout === 0
    ? `\n${gevallen.length}/${gevallen.length} goed\n`
    : `\n${gevallen.length - fout}/${gevallen.length} goed — ${fout} FOUT\n`,
);
process.exit(fout === 0 ? 0 : 1);
