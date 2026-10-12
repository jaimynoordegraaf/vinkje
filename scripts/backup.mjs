/**
 * Een kopie van de database op deze machine zetten.
 *
 * Supabase maakt op een betaald plan zelf elke dag een back-up. Dit is de
 * tweede lijn: een kopie die níét bij Supabase staat. Gaat daar iets mis met
 * het account, of wist iemand per ongeluk een groep, dan heb je hier nog wat.
 *
 *   npm run backup
 *
 * Nodig: in .env een verbindingsreeks van Supabase.
 *
 *   SUPABASE_DB_URL=postgresql://postgres.xxxx:WACHTWOORD@aws-0-eu-west-1...
 *
 * Die staat in het dashboard onder Project Settings → Database → Connection
 * string, kies "URI". Hij bevat het databasewachtwoord, dus hij hoort in .env
 * en nergens anders; .env staat in .gitignore.
 *
 * WAT HIER UITKOMT IS GEEN GEWOON BESTAND. Er staan namen in van kinderen, wie
 * wat heeft afgetekend, en e-mailadressen. Het valt onder dezelfde afspraken
 * als de database zelf: niet in de repo, niet in een gedeelde map waar het hele
 * bestuur bij kan, en weggooien als je het niet meer nodig hebt. Daarom schrijft
 * dit script standaard búíten de projectmap.
 */

import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, statSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');

function stop(bericht) {
  console.error('\n' + bericht + '\n');
  process.exit(1);
}

// .env zelf lezen: dit script draait buiten Expo om, dus niemand laadt hem.
function uitEnv(sleutel) {
  const pad = join(root, '.env');
  if (!existsSync(pad)) return null;
  for (const regel of readFileSync(pad, 'utf8').split(/\r?\n/)) {
    const m = regel.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)$/);
    if (m && m[1] === sleutel) return m[2].trim().replace(/^["']|["']$/g, '');
  }
  return null;
}

const url = process.env.SUPABASE_DB_URL ?? uitEnv('SUPABASE_DB_URL');
if (!url) {
  stop(
    'SUPABASE_DB_URL ontbreekt in .env.\n\n' +
      'Haal hem uit het dashboard: Project Settings → Database → Connection\n' +
      'string → URI. Hij bevat het databasewachtwoord, dus zet hem in .env en\n' +
      'nergens anders.',
  );
}

// Standaard naast de projectmap, niet erin. Wat hier uitkomt bevat
// persoonsgegevens en hoort niet per ongeluk in een commit te belanden.
const waar = process.argv[2] ? resolve(process.argv[2]) : resolve(root, '..', 'vinkje-backups');
mkdirSync(waar, { recursive: true });

const nu = new Date();
const stempel =
  nu.getFullYear() +
  String(nu.getMonth() + 1).padStart(2, '0') +
  String(nu.getDate()).padStart(2, '0') +
  '-' +
  String(nu.getHours()).padStart(2, '0') +
  String(nu.getMinutes()).padStart(2, '0');
const uit = join(waar, `vinkje-${stempel}.sql`);

console.log('Kopie maken van de database…');
console.log('naar ' + uit + '\n');

// De Supabase CLI heeft pg_dump bij zich, dus er hoeft geen PostgreSQL op deze
// machine te staan. --data-only niet: we willen ook het schema, anders kun je
// er niets mee terugzetten.
const uitkomst = spawnSync(
  'npx',
  ['--yes', 'supabase', 'db', 'dump', '--db-url', url, '-f', uit],
  { stdio: 'inherit', shell: true, cwd: root },
);

if (uitkomst.status !== 0) {
  stop(
    'Het dumpen is misgegaan (code ' + uitkomst.status + ').\n\n' +
      'Meestal is dat de verbindingsreeks: controleer of je de URI hebt genomen\n' +
      'en niet de pooler-variant, en of het wachtwoord erin klopt.',
  );
}

if (!existsSync(uit) || statSync(uit).size < 1024) {
  stop('Er staat geen bruikbaar bestand op ' + uit + '. Niets bewaard dus.');
}

const mb = (statSync(uit).size / 1048576).toFixed(1);
console.log(`\nKlaar: ${uit} (${mb} MB)`);
console.log(
  '\nDit bestand bevat namen, e-mailadressen en aftekeningen. Bewaar het als\n' +
    'zodanig, en gooi oude kopieën weg als je ze niet meer nodig hebt.',
);
