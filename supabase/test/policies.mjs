/**
 * Runs the migrations against a real Postgres and then tries to break them.
 *
 * PGlite is Postgres compiled to WebAssembly: no Docker, no network, nothing
 * to install. That matters because RLS failures are silent — a wrong policy
 * raises no error, rows simply stop appearing, or start appearing to the wrong
 * person. The only way to know is to ask as a real member and count.
 *
 * Run with: npm run test:db
 */

import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { PGlite } from '@electric-sql/pglite';

const here = dirname(fileURLToPath(import.meta.url));
const sqlDir = join(here, '..');

const db = new PGlite();

let failures = 0;
let checks = 0;

function check(name, ok, extra) {
  checks++;
  if (ok) {
    console.log(`  ok   ${name}`);
  } else {
    failures++;
    console.log(`  FAIL ${name}${extra === undefined ? '' : ` — ${extra}`}`);
  }
}

function section(name) {
  console.log(`\n${name}`);
}

/**
 * Supabase gives every signed-in caller the `authenticated` role and an
 * auth.uid(). Here that is a role we create ourselves and a setting we can
 * change, so one process can act as several different members.
 */
async function as(uid, fn) {
  await db.exec(`set role authenticated; set "test.uid" = '${uid}';`);
  try {
    return await fn();
  } finally {
    await db.exec('reset role;');
  }
}

/** Run a statement as a member and report whether it was refused. */
async function refused(uid, sql, params = []) {
  try {
    await as(uid, () => db.query(sql, params));
    return null;
  } catch (e) {
    return e.message;
  }
}

async function main() {
  section('Opzet');

  // What Supabase provides and the migrations assume exists.
  await db.exec(`
    create role authenticated;
    create schema auth;
    create table auth.users (
      id uuid primary key default gen_random_uuid(),
      email text,
      raw_user_meta_data jsonb not null default '{}'::jsonb
    );
    create or replace function auth.uid () returns uuid
      language sql stable as $$
      select nullif(current_setting('test.uid', true), '')::uuid;
    $$;
  `);
  check('auth-stub staat', true);

  // 010-eisen.sql gaat als laatste: de catalogus hangt inmiddels aan elke
  // schemawijziging die erna genummerd is, en onderdelen kunnen pas geladen
  // worden als requirements.parent_id bestaat.
  for (const file of [
    '001-core.sql',
    '002-rls.sql',
    '003-rpc.sql',
    '011-laatste-beheerder.sql',
    '012-onderdelen.sql',
    '013-beheer.sql',
    '014-speltakken.sql',
    '015-leden-zonder-account.sql',
    '016-bakken-en-standen.sql',
    '017-account-verwijderen.sql',
    '018-eigen-lijsten.sql',
    '019-examens.sql',
    '020-examen-nakijken.sql',
    '021-examenvraag-bij-eis.sql',
    '022-examen-aftekenen.sql',
    '023-examen-afbeeldingen.sql',
    '024-examen-geslaagd.sql',
    '025-examen-opruimen.sql',
    '026-voortgang.sql',
    '027-oud-lid.sql',
    '028-lesmateriaal.sql',
    '029-aftekenen-met-moment.sql',
    '010-eisen.sql',
  ]) {
    try {
      await db.exec(readFileSync(join(sqlDir, file), 'utf8'));
      check(`${file} draait`, true);
    } catch (e) {
      check(`${file} draait`, false, e.message);
      // Nothing after this can mean anything.
      report();
      process.exit(1);
    }
  }

  // schema.sql is the paste-once path for a fresh project, and it is generated
  // — so it is exactly the file most likely to drift from the numbered ones.
  try {
    const fresh = new PGlite();
    await fresh.exec(`
      create role authenticated;
      create schema auth;
      create table auth.users (
        id uuid primary key default gen_random_uuid(),
        email text,
        raw_user_meta_data jsonb not null default '{}'::jsonb
      );
      create or replace function auth.uid () returns uuid
        language sql stable as $$ select null::uuid; $$;
    `);
    await fresh.exec(readFileSync(join(sqlDir, 'schema.sql'), 'utf8'));
    const n = await fresh.query('select count(*)::int as n from requirements');
    await fresh.close();
    check('schema.sql draait op een leeg project', n.rows[0].n > 250, `${n.rows[0].n} eisen`);
  } catch (e) {
    check('schema.sql draait op een leeg project', false, e.message);
  }

  // Supabase grants these; without them `authenticated` cannot reach a table
  // at all and every test below would pass for the wrong reason.
  await db.exec(`
    grant usage on schema public to authenticated;
    grant all on all tables in schema public to authenticated;
    grant all on all sequences in schema public to authenticated;
    grant execute on all functions in schema public to authenticated;
  `);

  section('De catalogus is geladen');

  const disciplines = await one('select count(*)::int as n from disciplines');
  check('vijf disciplines', disciplines.n === 5, `${disciplines.n}`);

  const diplomas = await one('select count(*)::int as n from diplomas');
  check('twaalf diploma\'s en drie insignes', diplomas.n === 15, `${diplomas.n}`);

  const reqs = await one('select count(*)::int as n from requirements');
  check('meer dan 250 eisen', reqs.n > 250, `${reqs.n}`);

  // Het insigne Bemanningslid is landelijk, net als de CWO-eisen: drie niveaus,
  // van niemand, en met kind 'insigne' zodat het niet tussen de diploma's staat.
  const insignes = await one(
    `select count(*)::int as n, count(*) filter (where group_id is null)::int as landelijk
     from diplomas where kind = 'insigne'`,
  );
  check('drie insignes', insignes.n === 3, `${insignes.n}`);
  check('en ze zijn landelijk', insignes.landelijk === 3, `${insignes.landelijk}`);

  const bml = await one(`
    select
      count(*) filter (where r.parent_id is null)::int     as eisen,
      count(*) filter (where r.parent_id is not null)::int as onderdelen
    from requirements r
    join diplomas d on d.id = r.diploma_id
    where d.code like 'bml-%'
  `);
  check('het insigne heeft 43 eisen', bml.eisen === 43, `${bml.eisen}`);
  check('en 42 onderdelen eronder', bml.onderdelen === 42, `${bml.onderdelen}`);

  const vletdelen = await one(`
    select count(*)::int as n from requirements r
    join requirements p on p.id = r.parent_id
    where p.code = 'bml-1.t1'
  `);
  check('de vijftien onderdelen van een vlet staan erin', vletdelen.n === 15, `${vletdelen.n}`);

  // parent_id is null: onderdelen tellen niet mee als eis — dat is de hele
  // afspraak achter 012-onderdelen.sql.
  const roeien = await one(`
    select
      count(*) filter (where r.kind = 'praktijk')::int as p,
      count(*) filter (where r.kind = 'theorie')::int  as t
    from requirements r
    join diplomas d on d.id = r.diploma_id
    where d.code = 'roeien-12' and r.parent_id is null
  `);
  check('Roeien I/II: 9 praktijk, 8 theorie', roeien.p === 9 && roeien.t === 8,
    `${roeien.p}/${roeien.t}`);

  // Every diploma whose handboek carries a "toelichting op de eisen" should
  // have one on every eis. Sloep/motorvlet is the exception: that handboek has
  // no per-eis toelichting at all, only beoordelingsrichtlijnen.
  const missing = await db.query(`
    select d.code, count(*)::int as n
    from requirements r
    join diplomas d on d.id = r.diploma_id
    where r.detail is null
      and r.parent_id is null
      and d.code not like 'sloep-%'
    group by d.code
    order by d.code
  `);
  check(
    'elke eis met een handboek-toelichting heeft er een',
    missing.rows.length === 0,
    missing.rows.map((r) => `${r.code}: ${r.n} zonder`).join(', '),
  );

  const sloepGrouped = await one(`
    select count(*)::int as n from requirements r
    join diplomas d on d.id = r.diploma_id
    where d.code = 'sloep-1' and r.kind = 'praktijk' and r.detail is not null
  `);
  check('sloep-praktijk draagt het handboek-onderdeel', sloepGrouped.n === 33,
    `${sloepGrouped.n}`);

  section('Onderdelen binnen een eis');

  const knopen = await db.query(`
    select r.position, r.title
    from requirements r
    join requirements p on p.id = r.parent_id
    where p.code = 'roeien-12.t1'
    order by r.position
  `);
  check('Schiemanswerk is opgesplitst', knopen.rows.length === 6,
    `${knopen.rows.length}`);
  check('en de eerste is de halve steek',
    (knopen.rows[0]?.title ?? '').startsWith('Twee halve steken'),
    knopen.rows[0]?.title ?? 'geen');

  const onderdelen = await one(
    'select count(*)::int as n from requirements where parent_id is not null',
  );
  check('er staan ruim 200 onderdelen klaar', onderdelen.n > 200, `${onderdelen.n}`);

  const wees = await one(`
    select count(*)::int as n
    from requirements r join requirements p on p.id = r.parent_id
    where r.diploma_id <> p.diploma_id
  `);
  check('geen onderdeel onder een ander diploma', wees.n === 0, `${wees.n}`);

  // Twee lagen diep zou een boom maken van wat een lijst moet blijven.
  const parentCode = await one(
    `select id, diploma_id from requirements where code = 'roeien-12.t1.1'`,
  );
  let nested = null;
  try {
    await db.query(
      `insert into requirements (diploma_id, parent_id, code, kind, position, title)
       values ($1, $2, 'test.te.diep', 'theorie', 1, 'Te diep')`,
      [parentCode.diploma_id, parentCode.id],
    );
  } catch (e) {
    nested = e.message;
  }
  check('een onderdeel van een onderdeel wordt geweigerd', nested !== null,
    'het lukte wel');

  section('De seed kan opnieuw');

  // The whole point of upserting on `code`: ids survive, so aftekeningen that
  // already exist keep pointing at the same eis.
  const before = await one(`select id from requirements where code = 'roeien-12.p1'`);
  await db.exec(readFileSync(join(sqlDir, '010-eisen.sql'), 'utf8'));
  const after = await one(`select id from requirements where code = 'roeien-12.p1'`);
  const stillFifteen = await one('select count(*)::int as n from diplomas');
  check('opnieuw draaien houdt dezelfde eis-id', before.id === after.id);
  check('opnieuw draaien dupliceert geen diploma', stillFifteen.n === 15, `${stillFifteen.n}`);

  section('Twee groepen, vier mensen');

  const wim = await newUser('wim@voorbeeld.nl', 'Wim de Instructeur');
  const sam = await newUser('sam@voorbeeld.nl', 'Sam het Lid');
  const nina = await newUser('nina@voorbeeld.nl', 'Nina het Lid');
  const ander = await newUser('ander@voorbeeld.nl', 'Ander Groep');

  const jwf = await as(wim, async () => {
    const r = await db.query(`select create_group('Scouting JWF', 'jwf') as id`);
    return r.rows[0].id;
  });
  check('groep aangemaakt', Boolean(jwf));

  const other = await as(ander, async () => {
    const r = await db.query(`select create_group('Andere Groep', 'andere') as id`);
    return r.rows[0].id;
  });

  // Wim is beheerder by making the groep; give him the instructeur hat too by
  // leaving him as beheerder (is_staff covers both), and add the two leden.
  await db.exec(
    `insert into memberships (group_id, profile_id, role) values
       ('${jwf}', '${sam}', 'lid'),
       ('${jwf}', '${nina}', 'lid')`,
  );
  check('twee leden toegevoegd', true);

  section('Aftekenen is van de instructeur');

  const roeien12 = (await one(`select id from diplomas where code = 'roeien-12'`)).id;

  const samEnrollment = await as(wim, async () => {
    const r = await db.query(
      `insert into enrollments (group_id, profile_id, diploma_id, created_by)
       values ($1, $2, $3, $4) returning id`,
      [jwf, sam, roeien12, wim],
    );
    return r.rows[0].id;
  });
  check('instructeur schrijft een lid in', Boolean(samEnrollment));

  const selfEnroll = await refused(
    sam,
    `insert into enrollments (group_id, profile_id, diploma_id) values ($1, $2, $3)`,
    [jwf, sam, (await one(`select id from diplomas where code = 'roeien-3'`)).id],
  );
  check('lid kan zichzelf niet inschrijven', selfEnroll !== null, 'het lukte wel');

  const eis1 = (await one(`select id from requirements where code = 'roeien-12.p1'`)).id;

  const selfSign = await refused(sam, `select set_sign_off($1, $2, true, null)`, [
    samEnrollment,
    eis1,
  ]);
  check('lid kan zichzelf niet aftekenen', selfSign !== null, 'het lukte wel');

  await as(wim, () =>
    db.query(`select set_sign_off($1, $2, true, $3)`, [
      samEnrollment,
      eis1,
      'Netjes gedaan op de vaaravond',
    ]),
  );
  const signed = await one(
    `select s.signed_by, s.note, p.full_name
     from sign_offs s join profiles p on p.id = s.signed_by
     where s.enrollment_id = '${samEnrollment}'`,
  );
  check('instructeur tekent af', signed?.signed_by === wim);
  check('de naam van de instructeur staat erbij', signed?.full_name === 'Wim de Instructeur');
  check('de notitie is bewaard', signed?.note === 'Netjes gedaan op de vaaravond');

  // A sign_off that carries someone else's name is the one thing that would
  // quietly corrupt a vorderingenstaat.
  const forged = await refused(
    wim,
    `insert into sign_offs (enrollment_id, requirement_id, diploma_id, signed_by)
     values ($1, $2, $3, $4)`,
    [samEnrollment, (await one(`select id from requirements where code = 'roeien-12.p2'`)).id,
      roeien12, sam],
  );
  check('aftekenen op andermans naam kan niet', forged !== null, 'het lukte wel');

  const wrongDiploma = (await one(`select id from requirements where code = 'kielboot-1.p1'`)).id;
  const crossed = await refused(wim, `select set_sign_off($1, $2, true, null)`, [
    samEnrollment,
    wrongDiploma,
  ]);
  check('een eis van een ander diploma wordt geweigerd', crossed !== null, 'het lukte wel');

  section('Ontaftekenen');

  await as(wim, () =>
    db.query(`select set_sign_off($1, $2, false, null)`, [samEnrollment, eis1]),
  );
  const left = await one(
    `select count(*)::int as n from sign_offs where enrollment_id = '${samEnrollment}'`,
  );
  check('een aftekening kan terug', left.n === 0, `${left.n}`);

  // Put it back for the counting tests.
  await as(wim, () =>
    db.query(`select set_sign_off($1, $2, true, null)`, [samEnrollment, eis1]),
  );

  section('Wie ziet wat');

  const samSees = await as(sam, async () => {
    const r = await db.query('select count(*)::int as n from enrollments');
    return r.rows[0].n;
  });
  check('lid ziet de eigen inschrijving', samSees === 1, `${samSees}`);

  const ninaEnrollment = await as(wim, async () => {
    const r = await db.query(
      `insert into enrollments (group_id, profile_id, diploma_id, created_by)
       values ($1, $2, $3, $4) returning id`,
      [jwf, nina, roeien12, wim],
    );
    return r.rows[0].id;
  });

  const samSeesNina = await as(sam, async () => {
    const r = await db.query('select count(*)::int as n from enrollments');
    return r.rows[0].n;
  });
  check('lid ziet die van een ander niet', samSeesNina === 1, `${samSeesNina}`);

  const wimSees = await as(wim, async () => {
    const r = await db.query('select count(*)::int as n from enrollments');
    return r.rows[0].n;
  });
  check('instructeur ziet beide leden', wimSees === 2, `${wimSees}`);

  const otherSees = await as(ander, async () => {
    const r = await db.query('select count(*)::int as n from enrollments');
    return r.rows[0].n;
  });
  check('een andere groep ziet er geen enkele', otherSees === 0, `${otherSees}`);

  const sheetForStranger = await as(ander, async () => {
    const r = await db.query('select * from enrollment_sheet($1)', [samEnrollment]);
    return r.rows.length;
  });
  check('de aftekenlijst lekt niet naar een andere groep', sheetForStranger === 0,
    `${sheetForStranger} regels`);

  const ledenlijstVoorLid = await as(sam, async () => {
    const r = await db.query('select * from group_members($1)', [jwf]);
    return r.rows.length;
  });
  check('een lid krijgt geen ledenlijst', ledenlijstVoorLid === 0, `${ledenlijstVoorLid}`);

  const ledenlijst = await as(wim, async () => {
    const r = await db.query('select * from group_members($1)', [jwf]);
    return r.rows;
  });
  check('instructeur krijgt de hele ledenlijst', ledenlijst.length === 3,
    `${ledenlijst.length}`);
  check('de ledenlijst telt lopende opleidingen',
    ledenlijst.find((m) => m.full_name === 'Sam het Lid')?.in_progress === 1n ||
    ledenlijst.find((m) => m.full_name === 'Sam het Lid')?.in_progress === 1);

  const stolenProgress = await as(sam, async () => {
    const r = await db.query('select * from member_enrollments($1, $2)', [jwf, nina]);
    return r.rows.length;
  });
  check('lid kan de voortgang van een ander niet opvragen', stolenProgress === 0,
    `${stolenProgress} regels`);

  section('Tellen');

  const sheet = await as(wim, async () => {
    const r = await db.query('select * from enrollment_sheet($1)', [samEnrollment]);
    return r.rows;
  });
  const eisen = sheet.filter((r) => r.parent_id === null);
  check('de aftekenlijst heeft alle 17 eisen', eisen.length === 17, `${eisen.length}`);
  check('en de onderdelen komen mee', sheet.length > eisen.length,
    `${sheet.length} regels`);
  check('precies één eis is afgetekend',
    sheet.filter((r) => r.signed_at !== null).length === 1);
  check('praktijk staat voor theorie', sheet[0].kind === 'praktijk');
  check('de nummering volgt het handboek', sheet[0].position === 1);

  // Een onderdeel staat direct achter zijn eigen eis, zodat het scherm de
  // lijst van boven naar beneden kan doorlopen.
  const commandoIndex = sheet.findIndex((r) => r.parent_id === null && r.position === 3);
  check('onderdelen staan achter hun eis',
    sheet[commandoIndex + 1]?.parent_id === sheet[commandoIndex]?.requirement_id,
    'de volgorde klopt niet');

  // Een onderdeel aftekenen is gewoon aftekenen — maar het verschuift de
  // voortgang niet, want de eis blijft het oordeel van de instructeur.
  const knoop = (await one(`select id from requirements where code = 'roeien-12.t1.2'`)).id;
  await as(wim, () =>
    db.query(`select set_sign_off($1, $2, true, null)`, [samEnrollment, knoop]),
  );
  const afterKnoop = await as(wim, async () => {
    const r = await db.query('select * from member_enrollments($1, $2)', [jwf, sam]);
    return r.rows[0];
  });
  check('een onderdeel aftekenen kan',
    (await one(`select count(*)::int as n from sign_offs where requirement_id = '${knoop}'`)).n === 1);
  check('maar het telt niet mee als eis',
    Number(afterKnoop.theorie_done) === 0 && Number(afterKnoop.theorie_total) === 8,
    `${afterKnoop.theorie_done}/${afterKnoop.theorie_total}`);

  const mine = await as(wim, async () => {
    const r = await db.query('select * from member_enrollments($1, $2)', [jwf, sam]);
    return r.rows[0];
  });
  check('voortgang: 1 van 9 praktijk',
    Number(mine.praktijk_done) === 1 && Number(mine.praktijk_total) === 9,
    `${mine.praktijk_done}/${mine.praktijk_total}`);
  check('voortgang: 0 van 8 theorie',
    Number(mine.theorie_done) === 0 && Number(mine.theorie_total) === 8,
    `${mine.theorie_done}/${mine.theorie_total}`);
  check('de discipline komt mee', mine.discipline_name === 'Roeien');

  section('Drie standen');

  const eis2 = (await one(`select id from requirements where code = 'roeien-12.p2'`)).id;
  const progressOf = async () =>
    Number(
      (await as(wim, async () =>
        (await db.query('select * from member_enrollments($1, $2)', [jwf, sam])).rows[0],
      )).praktijk_done,
    );

  const bestaand = await one(
    `select status from sign_offs where enrollment_id = '${samEnrollment}' and requirement_id = '${eis1}'`,
  );
  check('een bestaande aftekening is gehaald', bestaand?.status === 'gehaald',
    bestaand?.status);

  const voor = await progressOf();
  await as(wim, () =>
    db.query(`select set_sign_off_status($1, $2, 'behandeld', 'nog een keer bij meer wind')`,
      [samEnrollment, eis2]),
  );
  check('behandeld onderweg telt niet mee', (await progressOf()) === voor,
    `${voor} → ${await progressOf()}`);

  await as(wim, () =>
    db.query(`select set_sign_off_status($1, $2, 'gehaald', null)`, [samEnrollment, eis2]),
  );
  check('gehaald telt wel', (await progressOf()) === voor + 1, `${await progressOf()}`);

  const bewaard = await one(
    `select note from sign_offs where enrollment_id = '${samEnrollment}' and requirement_id = '${eis2}'`,
  );
  check('de notitie blijft staan bij een nieuwe stand',
    bewaard?.note === 'nog een keer bij meer wind', bewaard?.note);

  await as(wim, () =>
    db.query(`select set_sign_off_status($1, $2, null, null)`, [samEnrollment, eis2]),
  );
  const weg = await one(
    `select count(*)::int as n from sign_offs where enrollment_id = '${samEnrollment}' and requirement_id = '${eis2}'`,
  );
  check('niet behandeld haalt de rij weg', weg.n === 0, `${weg.n}`);

  // De builds die nu op telefoons staan roepen nog de oude functie aan.
  await as(wim, () =>
    db.query(`select set_sign_off_status($1, $2, 'behandeld', null)`, [samEnrollment, eis2]),
  );
  await as(wim, () =>
    db.query(`select set_sign_off($1, $2, true, null)`, [samEnrollment, eis2]),
  );
  const oud = await one(
    `select status from sign_offs where enrollment_id = '${samEnrollment}' and requirement_id = '${eis2}'`,
  );
  check('de oude aan/uit-functie zet op gehaald', oud?.status === 'gehaald', oud?.status);
  await as(wim, () =>
    db.query(`select set_sign_off($1, $2, false, null)`, [samEnrollment, eis2]),
  );

  const lidStand = await refused(sam,
    `select set_sign_off_status($1, $2, 'gehaald', null)`, [samEnrollment, eis2]);
  check('een lid zet geen stand', lidStand !== null, 'het lukte wel');

  section('De voortgang van de hele groep');

  // Eerst een eigen uitgangsstand, zodat deze sectie niet leunt op wat de
  // vorige liet liggen: Sam heeft eis 1 gehaald en is met eis 2 bezig. Zonder
  // dit klopten de aantallen hieronder alleen zolang niemand de secties
  // hierboven aanraakte.
  await db.exec(`delete from sign_offs where enrollment_id = '${samEnrollment}'`);
  await as(wim, () =>
    db.query(`select set_sign_off_status($1, $2, 'gehaald', null)`, [samEnrollment, eis1]));
  await as(wim, () =>
    db.query(`select set_sign_off_status($1, $2, 'behandeld', null)`, [samEnrollment, eis2]));

  const groepStand = await as(wim, async () =>
    (await db.query('select * from group_progress($1)', [jwf])).rows);
  check('een instructeur ziet de voortgang van de hele groep', groepStand.length >= 2,
    `${groepStand.length} regels`);

  const samStand = groepStand.find((r) => r.enrollment_id === samEnrollment);
  check('Sams inschrijving staat erin', Boolean(samStand));
  check('alleen gehaald telt mee in de voortgang',
    samStand && Number(samStand.praktijk_done) === 1,
    samStand ? `praktijk_done = ${samStand.praktijk_done}` : 'geen regel');
  check('behandeld wordt apart geteld en niet meegerekend',
    samStand && Number(samStand.onderweg) === 1,
    samStand ? `onderweg = ${samStand.onderweg}` : 'geen regel');
  check('er valt nog iets te doen',
    samStand && Number(samStand.praktijk_total) > Number(samStand.praktijk_done),
    samStand ? `${samStand.praktijk_done}/${samStand.praktijk_total}` : 'geen regel');
  check('de datum van de laatste aftekening staat erbij',
    samStand && samStand.laatst_afgetekend !== null);

  // Het hele punt van beide functies: ze geven de stand van iedereen, en dat
  // is precies wat een lid niet van zijn medevaarders hoort te zien.
  const standVoorLid = await refused(sam, 'select * from group_progress($1)', [jwf]);
  check('een lid komt er niet bij', standVoorLid !== null, 'het lukte wel');
  const standVoorVreemde = await refused(ander, 'select * from group_progress($1)', [jwf]);
  check('iemand van buiten de groep ook niet', standVoorVreemde !== null, 'het lukte wel');

  const eisRaster = await as(wim, async () =>
    (await db.query('select * from diploma_eis_stand($1, $2)', [jwf, roeien12])).rows);
  const eisenVanRoeien = (await one(
    `select count(*)::int as n from requirements
       where diploma_id = '${roeien12}' and parent_id is null`)).n;
  const ingeschrevenOp = (await one(
    `select count(*)::int as n from enrollments
       where group_id = '${jwf}' and diploma_id = '${roeien12}'`)).n;
  check('het raster is volledig: elke eis maal elk ingeschreven lid',
    eisRaster.length === eisenVanRoeien * ingeschrevenOp,
    `${eisRaster.length} regels, verwacht ${eisenVanRoeien} x ${ingeschrevenOp}`);

  // Niet behandeld hoort een regel te zijn met status null, geen ontbrekende
  // regel. Anders kan de pagina "nog niet behandeld" niet onderscheiden van
  // "doet dit diploma niet", en juist die eerste groep is waar het om gaat.
  check('nog niet behandelde eisen staan erin met status null',
    eisRaster.some((r) => r.status === null), 'geen enkele');
  const rasterGehaald = eisRaster.filter((r) => r.status === 'gehaald').length;
  check('de gehaalde eis staat er met zijn stand', rasterGehaald === 1, `${rasterGehaald}`);
  const rasterOnderweg = eisRaster.filter((r) => r.status === 'behandeld').length;
  check('de behandelde eis ook', rasterOnderweg === 1, `${rasterOnderweg}`);

  const rasterVoorLid = await refused(sam,
    'select * from diploma_eis_stand($1, $2)', [jwf, roeien12]);
  check('een lid komt ook niet bij het raster', rasterVoorLid !== null, 'het lukte wel');

  section('Bakken');

  const vlet = await as(wim, async () =>
    (await db.query(
      `insert into crews (group_id, name) values ($1, 'Vlet 1') returning id`, [jwf],
    )).rows[0].id,
  );
  check('een instructeur maakt een bak', Boolean(vlet));

  const lidBak = await refused(sam,
    `insert into crews (group_id, name) values ($1, 'Eigen bak')`, [jwf]);
  check('een lid maakt geen bak', lidBak !== null, 'het lukte wel');

  const ingedeeld = await refused(wim, 'select set_crew_members($1, $2)', [vlet, [sam, nina]]);
  check('een instructeur deelt de bak in', ingedeeld === null, ingedeeld ?? '');

  const vreemdeling = await refused(wim, 'select set_crew_members($1, $2)', [vlet, [ander]]);
  check('iemand van een andere groep kan er niet in', vreemdeling !== null, 'het lukte wel');

  const bemanning = await as(wim, async () =>
    (await db.query('select * from crew_roster($1)', [vlet])).rows,
  );
  check('de bak heeft twee opvarenden', bemanning.length === 2, `${bemanning.length}`);

  const blad = await as(wim, async () =>
    (await db.query('select * from crew_sheet($1, $2)', [vlet, eis1])).rows,
  );
  check('het overzicht toont iedereen in de bak', blad.length === 2, `${blad.length}`);
  const samRij = blad.find((r) => r.profile_id === sam);
  check('met de stand van wie al gehaald heeft', samRij?.status === 'gehaald',
    samRij?.status);

  // Nina is voor roeien ingeschreven; iemand die dat niet is komt er wel bij,
  // maar zonder opleiding.
  const kielboot1eis = (await one(`select id from requirements where code = 'kielboot-1.p1'`)).id;
  const kielBlad = await as(wim, async () =>
    (await db.query('select * from crew_sheet($1, $2)', [vlet, kielboot1eis])).rows,
  );
  check('wie niet ingeschreven is staat erbij zonder opleiding',
    kielBlad.length === 2 && kielBlad.every((r) => r.enrollment_id === null),
    JSON.stringify(kielBlad.map((r) => r.enrollment_id)));

  const bakDiplomas = await as(wim, async () =>
    (await db.query('select * from crew_diplomas($1)', [vlet])).rows,
  );
  check('de bak weet aan welke diploma’s hij werkt',
    bakDiplomas.some((d) => d.diploma_name === 'Roeien I/II'),
    JSON.stringify(bakDiplomas.map((d) => d.diploma_name)));

  const bakVoorLid = await as(sam, async () =>
    (await db.query('select * from crew_sheet($1, $2)', [vlet, eis1])).rows,
  );
  check('een lid krijgt het overzicht niet', bakVoorLid.length === 0, `${bakVoorLid.length}`);

  const bakVoorVreemde = await as(ander, async () =>
    (await db.query('select * from crews')).rows,
  );
  check('een andere groep ziet de bak niet', bakVoorVreemde.length === 0,
    `${bakVoorVreemde.length}`);

  section('De landelijke catalogus is van niemand');

  // 013 gaf elke beheerder de hele catalogus. Sinds 018 niet meer: een
  // wijziging daar zou élke groep in deze database raken, en 010-eisen.sql
  // overschrijft hem toch weer. Eigen eisen horen in een eigen lijst.
  await refused(
    wim,
    `update requirements set title = 'Bijgewerkt' where code = 'roeien-12.p1'`,
  );
  const changed = await one(`select title from requirements where code = 'roeien-12.p1'`);
  check('een beheerder kan een landelijke eis niet bijwerken',
    changed.title === 'Het schip vaarklaar en nachtklaar maken', changed.title);

  await refused(
    sam,
    `update requirements set title = 'Door een lid' where code = 'roeien-12.p1'`,
  );
  const afterLid = await one(`select title from requirements where code = 'roeien-12.p1'`);
  check('een lid al helemaal niet',
    afterLid.title === 'Het schip vaarklaar en nachtklaar maken', afterLid.title);

  await refused(
    wim,
    `insert into diplomas (discipline_id, code, name)
     select id, 'gekaapt', 'Gekaapt' from disciplines limit 1`,
  );
  const landelijkAantal = await one('select count(*)::int as n from diplomas where group_id is null');
  check('en er komt geen landelijk diploma bij', landelijkAantal.n === 15, `${landelijkAantal.n}`);

  await refused(
    sam,
    `insert into diplomas (discipline_id, code, name)
     select id, 'verzonnen', 'Verzonnen' from disciplines limit 1`,
  );
  const diplomaCount = await one('select count(*)::int as n from diplomas');
  check('en een lid kan er geen diploma bij zetten', diplomaCount.n === 15,
    `${diplomaCount.n}`);

  section('Leden zonder account');

  // De kern: iemand in het register zetten die zich nooit zal aanmelden.
  const pietId = await as(wim, async () => {
    const r = await db.query('select add_member($1, $2) as id', [jwf, 'Piet Zonder Telefoon']);
    return r.rows[0].id;
  });
  check('een instructeur voegt iemand zonder account toe', Boolean(pietId));

  const piet = await one(`select id, full_name from profiles where id = '${pietId}'`);
  check('hij staat in het register', piet.full_name === 'Piet Zonder Telefoon');

  const noAuth = await one(
    `select count(*)::int as n from auth.users where id = '${pietId}'`,
  );
  check('en heeft geen account', noAuth.n === 0, `${noAuth.n}`);

  const inList = await as(wim, async () => {
    const r = await db.query('select * from group_members($1)', [jwf]);
    return r.rows.some((m) => m.full_name === 'Piet Zonder Telefoon');
  });
  check('hij staat in de ledenlijst', inList);

  // Waar het om begonnen was: hij moet een opleiding kunnen krijgen.
  const pietEnrollment = await as(wim, async () => {
    const r = await db.query(
      `insert into enrollments (group_id, profile_id, diploma_id, created_by)
       values ($1, $2, $3, $4) returning id`,
      [jwf, pietId, roeien12, wim],
    );
    return r.rows[0].id;
  });
  await as(wim, () =>
    db.query(`select set_sign_off($1, $2, true, null)`, [pietEnrollment, eis1]),
  );
  const pietProgress = await as(wim, async () => {
    const r = await db.query('select * from member_enrollments($1, $2)', [jwf, pietId]);
    return r.rows[0];
  });
  check('en kan afgetekend worden als ieder ander',
    Number(pietProgress.praktijk_done) === 1, `${pietProgress?.praktijk_done}`);

  await as(wim, () =>
    db.query('select set_member_name($1, $2, $3)', [jwf, pietId, 'Piet de Vries']),
  );
  const renamed = await one(`select full_name from profiles where id = '${pietId}'`);
  check('een instructeur corrigeert zijn naam', renamed.full_name === 'Piet de Vries',
    renamed.full_name);

  const byOutsider = await refused(ander, 'select add_member($1, $2)', [jwf, 'Indringer']);
  check('iemand van buiten voegt niets toe', byOutsider !== null, 'het lukte wel');

  const renameByLid = await refused(sam, 'select set_member_name($1, $2, $3)', [
    jwf, pietId, 'Gehackt',
  ]);
  check('een lid hernoemt niemand', renameByLid !== null, 'het lukte wel');

  section('Speltakken');

  await db.exec(
    `insert into sections (group_id, name) values ('${jwf}', 'Zeeverkenners'), ('${jwf}', 'Wilde Vaart')`,
  );
  const zv = (await one(`select id from sections where name = 'Zeeverkenners'`)).id;
  const wv = (await one(`select id from sections where name = 'Wilde Vaart'`)).id;

  const assigned = await refused(wim, 'select set_member_sections($1, $2, $3)', [
    jwf,
    sam,
    [zv, wv],
  ]);
  check('een beheerder wijst speltakken toe', assigned === null, assigned ?? '');

  const samRow = await as(wim, async () => {
    const r = await db.query('select * from group_members($1)', [jwf]);
    return r.rows.find((m) => m.full_name === 'Sam het Lid');
  });
  check('de ledenlijst geeft de namen terug',
    (samRow?.sections ?? []).length === 2, JSON.stringify(samRow?.sections));
  check('en de ids, zodat er gefilterd kan worden',
    (samRow?.section_ids ?? []).length === 2, JSON.stringify(samRow?.section_ids));

  // Opnieuw zetten vervangt de set in plaats van er iets bij te stapelen.
  await as(wim, () =>
    db.query('select set_member_sections($1, $2, $3)', [jwf, sam, [wv]]),
  );
  const afterReplace = await one(
    `select count(*)::int as n from membership_sections ms
     join memberships m on m.id = ms.membership_id
     where m.profile_id = '${sam}'`,
  );
  check('opnieuw toewijzen vervangt de hele set', afterReplace.n === 1, `${afterReplace.n}`);

  const byMember = await refused(sam, 'select set_member_sections($1, $2, $3)', [
    jwf,
    sam,
    [zv],
  ]);
  check('een lid wijst zichzelf niets toe', byMember !== null, 'het lukte wel');

  // Een speltak uit een andere groep zou hier binnen kunnen glippen, want de
  // functie draait als eigenaar en de policies kijken niet mee.
  await db.exec(`insert into sections (group_id, name) values ('${other}', 'Vreemde Speltak')`);
  const foreign = (await one(`select id from sections where name = 'Vreemde Speltak'`)).id;
  const crossedSection = await refused(wim, 'select set_member_sections($1, $2, $3)', [
    jwf,
    sam,
    [foreign],
  ]);
  check('een speltak van een andere groep wordt geweigerd', crossedSection !== null,
    'het lukte wel');

  section('Iemand uit de groep halen');

  const gone = await refused(wim, 'select remove_member($1, $2)', [jwf, nina]);
  check('een beheerder haalt iemand eruit', gone === null, gone ?? '');
  check('en die staat niet meer in de ledenlijst',
    (await as(wim, async () => (await db.query('select * from group_members($1)', [jwf])).rows))
      .every((m) => m.full_name !== 'Nina het Lid'));

  // De aftekeningen blijven: komt ze terug, dan staat haar lijst er weer.
  const kept = await one(
    `select count(*)::int as n from enrollments where profile_id = '${nina}'`,
  );
  check('haar voortgang blijft bewaard', kept.n === 1, `${kept.n}`);

  // Bewaard is niet hetzelfde als zichtbaar. Wie uit de groep is, hoort uit het
  // voortgangsoverzicht te verdwijnen zoals hij uit de ledenlijst verdwijnt --
  // anders staat iemand die er niet meer is nog wel in het lijstje "wie moet
  // wat nog doen", en ga je een middag plannen voor iemand die niet komt.
  const naVerwijderen = await as(wim, async () =>
    (await db.query('select * from group_progress($1)', [jwf])).rows);
  check('en verdwijnt uit het voortgangsoverzicht',
    naVerwijderen.every((r) => r.profile_id !== nina),
    'Nina staat er nog in');

  const rasterNa = await as(wim, async () =>
    (await db.query('select * from diploma_eis_stand($1, $2)', [jwf, roeien12])).rows);
  check('en uit het raster per eis',
    rasterNa.every((r) => r.profile_id !== nina),
    'Nina staat er nog in');

  // Bewaren wat niemand kan zien is het slechtste van twee werelden. Wie weg is
  // maar nog gegevens heeft staan, staat op een eigen lijst.
  const weggegaan = await as(wim, async () =>
    (await db.query('select * from former_members($1)', [jwf])).rows);
  const ninaWeg = weggegaan.find((r) => r.profile_id === nina);
  check('wie weg is staat op de lijst oud-leden', Boolean(ninaWeg),
    `${weggegaan.length} regels`);
  check('met wat er van hem bewaard is',
    ninaWeg && Number(ninaWeg.opleidingen) === 1,
    ninaWeg ? `${ninaWeg.opleidingen}` : 'geen regel');
  check('en een vertrekdatum, zodat de 2 jaar te meten is',
    ninaWeg && ninaWeg.left_at !== null);
  check('die nog niet verlopen is', ninaWeg && ninaWeg.over_de_tijd === false,
    ninaWeg ? String(ninaWeg.over_de_tijd) : 'geen regel');

  const lijstVoorLid = await refused(sam, 'select * from former_members($1)', [jwf]);
  check('een lid ziet die lijst niet', lijstVoorLid !== null, 'het lukte wel');

  // Wissen op een wegwerp-vaarder, zodat Nina's gegevens blijven staan voor de
  // secties die hierna komen.
  const tijdelijk = await as(wim, async () =>
    (await db.query('select add_member($1, $2) as id', [jwf, 'Kees Tijdelijk'])).rows[0].id);
  await as(wim, () => db.query(
    'insert into enrollments (group_id, profile_id, diploma_id) values ($1, $2, $3)',
    [jwf, tijdelijk, roeien12]));

  const nogLid = await refused(wim,
    'select delete_member_progress($1, $2)', [jwf, tijdelijk]);
  check('wissen kan niet zolang iemand nog in de groep zit', nogLid !== null,
    'het lukte wel');

  await as(wim, () => db.query('select remove_member($1, $2)', [jwf, tijdelijk]));
  const doorLid = await refused(sam,
    'select delete_member_progress($1, $2)', [jwf, tijdelijk]);
  check('en een lid wist sowieso niets', doorLid !== null, 'het lukte wel');

  const gewistVoorOudLid = await as(wim, async () =>
    (await db.query('select delete_member_progress($1, $2) as n', [jwf, tijdelijk])).rows[0].n);
  check('een beheerder wist de vorderingen van een oud-lid', Number(gewistVoorOudLid) === 1,
    `${gewistVoorOudLid}`);
  const restje = await one(
    `select count(*)::int as n from enrollments where profile_id = '${tijdelijk}'`);
  check('en er blijft niets van staan', restje.n === 0, `${restje.n}`);
  const naamWeg = await one(
    `select count(*)::int as n from profiles where id = '${tijdelijk}'`);
  check('ook zijn naam, want hij had geen account', naamWeg.n === 0, `${naamWeg.n}`);

  const byLid = await refused(sam, 'select remove_member($1, $2)', [jwf, wim]);
  check('een lid kan niemand verwijderen', byLid !== null, 'het lukte wel');

  const lastOne = await refused(wim, 'select remove_member($1, $2)', [jwf, wim]);
  check('de laatste beheerder kan zichzelf er niet uit halen', lastOne !== null,
    'het lukte wel');

  const rawDelete = await refused(
    wim,
    'delete from memberships where group_id = $1 and profile_id = $2',
    [jwf, sam],
  );
  const samStill = await one(
    `select count(*)::int as n from memberships where group_id = '${jwf}' and profile_id = '${sam}'`,
  );
  check('en verwijderen kan niet om remove_member heen',
    rawDelete !== null || samStill.n === 1, `${samStill.n}`);

  // Nina hoort er weer bij voor de tests die hierna komen.
  await db.exec(
    `insert into memberships (group_id, profile_id, role)
     values ('${jwf}', '${nina}', 'lid')`,
  );

  section('De laatste beheerder');

  // Dit is de fout die één keer echt gemaakt is: de enige beheerder tikt
  // zichzelf op 'lid' en kan daarna niets meer, ook zijn eigen rol niet terug.
  const selfDemote = await refused(
    wim,
    `update memberships set role = 'lid' where group_id = $1 and profile_id = $2`,
    [jwf, wim],
  );
  check('de enige beheerder kan zichzelf niet degraderen', selfDemote !== null,
    'het lukte wel');
  check('en de melding zegt waarom',
    (selfDemote ?? '').includes('laatste beheerder'), selfDemote ?? '');

  const stillAdmin = await one(
    `select role from memberships where group_id = '${jwf}' and profile_id = '${wim}'`,
  );
  check('hij is nog steeds beheerder', stillAdmin.role === 'beheerder', stillAdmin.role);

  // Een lid degraderen of promoveren raakt de regel niet.
  await as(wim, () =>
    db.query(
      `update memberships set role = 'instructeur' where group_id = $1 and profile_id = $2`,
      [jwf, nina],
    ),
  );
  const ninaRole = await one(
    `select role from memberships where group_id = '${jwf}' and profile_id = '${nina}'`,
  );
  check('een lid promoveren kan gewoon', ninaRole.role === 'instructeur', ninaRole.role);

  // Met een tweede beheerder mag het wel — dat is de nette volgorde.
  await as(wim, () =>
    db.query(
      `update memberships set role = 'beheerder' where group_id = $1 and profile_id = $2`,
      [jwf, sam],
    ),
  );
  const nowAllowed = await refused(
    wim,
    `update memberships set role = 'lid' where group_id = $1 and profile_id = $2`,
    [jwf, wim],
  );
  check('met een tweede beheerder mag het wel', nowAllowed === null, nowAllowed ?? '');

  // En nu is Sam de laatste, dus die zit weer vast.
  const samLast = await refused(
    sam,
    `update memberships set role = 'instructeur' where group_id = $1 and profile_id = $2`,
    [jwf, sam],
  );
  check('de nieuwe laatste beheerder zit er ook aan vast', samLast !== null,
    'het lukte wel');

  section('Je eigen account verwijderen');

  // Een instructeur die zelf ook een diploma haalt, en die bij Nina iets heeft
  // afgetekend. Na het verwijderen hoort zijn eigen voortgang weg te zijn en
  // Nina's aftekening te blijven — alleen zonder zijn naam.
  const tijd = await newUser('tijd@voorbeeld.nl', 'Tijdelijke Instructeur');
  await db.exec(
    `insert into memberships (group_id, profile_id, role) values ('${jwf}', '${tijd}', 'instructeur')`,
  );
  await db.exec(
    `insert into enrollments (group_id, profile_id, diploma_id) values ('${jwf}', '${tijd}', '${roeien12}')`,
  );
  const eis3 = (await one(`select id from requirements where code = 'roeien-12.p3'`)).id;
  await as(tijd, () =>
    db.query(`select set_sign_off_status($1, $2, 'gehaald', null)`, [ninaEnrollment, eis3]),
  );

  const verwijderd = await refused(tijd, 'select delete_my_account()');
  check('iemand verwijdert zijn eigen account', verwijderd === null, verwijderd ?? '');

  const profielWeg = await one(`select count(*)::int as n from profiles where id = '${tijd}'`);
  const loginWeg = await one(`select count(*)::int as n from auth.users where id = '${tijd}'`);
  const eigenVoortgang = await one(
    `select count(*)::int as n from enrollments where profile_id = '${tijd}'`,
  );
  check('zijn naam is weg', profielWeg.n === 0, `${profielWeg.n}`);
  check('zijn login is weg', loginWeg.n === 0, `${loginWeg.n}`);
  check('zijn eigen voortgang is weg', eigenVoortgang.n === 0, `${eigenVoortgang.n}`);

  const bijNina = await one(
    `select status, signed_by from sign_offs
     where enrollment_id = '${ninaEnrollment}' and requirement_id = '${eis3}'`,
  );
  check('wat hij bij een ander aftekende blijft staan', bijNina?.status === 'gehaald',
    bijNina?.status ?? 'weg');
  check('maar niet meer op zijn naam', bijNina?.signed_by === null,
    String(bijNina?.signed_by));

  // Ander is de enige beheerder van zijn eigen groep.
  const laatste = await refused(ander, 'select delete_my_account()');
  check('de laatste beheerder van een groep kan het niet', laatste !== null,
    'het lukte wel');
  const anderBestaat = await one(`select count(*)::int as n from profiles where id = '${ander}'`);
  check('en zijn account staat er nog', anderBestaat.n === 1, `${anderBestaat.n}`);

  const zonderLogin = await refused('', 'select delete_my_account()');
  check('niet ingelogd verwijdert niets', zonderLogin !== null, 'het lukte wel');

  section('Eigen eisenlijsten');

  const kamp = await newUser('kamp@voorbeeld.nl', 'Kampinstructeur');
  await db.exec(
    `insert into memberships (group_id, profile_id, role) values ('${jwf}', '${kamp}', 'instructeur')`,
  );

  // Een insigne dat nergens op lijkt: leeg beginnen.
  const insigne = (
    await as(kamp, () =>
      db.query(`select create_own_list($1, 'Bemanningslid', 'insigne', null) as id`, [jwf]),
    )
  ).rows[0].id;
  check('een instructeur maakt een eigen lijst', !!insigne, String(insigne));

  const vaarder = await newUser('vaarder@voorbeeld.nl', 'Gewoon Lid');
  await db.exec(
    `insert into memberships (group_id, profile_id, role) values ('${jwf}', '${vaarder}', 'lid')`,
  );
  const lidMaakt = await refused(vaarder, `select create_own_list($1, 'Van een lid')`, [jwf]);
  check('een lid mag dat niet', lidMaakt !== null, 'het lukte wel');

  const zietAnder = await as(ander, () =>
    one(`select count(*)::int as n from diplomas where id = '${insigne}'`),
  );
  check('een andere groep ziet hem niet', zietAnder.n === 0, `${zietAnder.n}`);
  const zietEigen = await as(kamp, () =>
    one(`select count(*)::int as n from diplomas where id = '${insigne}'`),
  );
  check('de eigen groep wel', zietEigen.n === 1, `${zietEigen.n}`);

  // De verkorte vletlijst: kopie van een landelijk diploma.
  const kopie = (
    await as(kamp, () =>
      db.query(`select copy_list_to_group($1, $2, 'Vlet herfstkamp') as id`, [jwf, roeien12]),
    )
  ).rows[0].id;
  const bron = await one(
    `select count(*) filter (where parent_id is null)::int as eisen,
            count(*) filter (where parent_id is not null)::int as onderdelen
     from requirements where diploma_id = '${roeien12}'`,
  );
  const kop = await one(
    `select count(*) filter (where parent_id is null)::int as eisen,
            count(*) filter (where parent_id is not null)::int as onderdelen
     from requirements where diploma_id = '${kopie}'`,
  );
  check('de kopie heeft evenveel eisen', kop.eisen === bron.eisen, `${kop.eisen} vs ${bron.eisen}`);
  check('en evenveel onderdelen', kop.onderdelen === bron.onderdelen,
    `${kop.onderdelen} vs ${bron.onderdelen}`);

  // Hangen de onderdelen aan dezelfde eis als in het origineel?
  const verkeerdeOuder = await one(
    `select count(*)::int as n
     from requirements k
     join requirements ko on ko.id = k.parent_id
     where k.diploma_id = '${kopie}' and k.parent_id is not null
       and not exists (
         select 1 from requirements b
         join requirements bo on bo.id = b.parent_id
         where b.diploma_id = '${roeien12}' and b.title = k.title and bo.title = ko.title
       )`,
  );
  check('elk onderdeel hangt aan dezelfde eis als in het origineel', verkeerdeOuder.n === 0,
    `${verkeerdeOuder.n} verkeerd`);

  // Inkorten in de kopie, en kijken of het origineel heel blijft.
  const schrap = await one(
    `select id from requirements where diploma_id = '${kopie}' and parent_id is null
       and kind = 'praktijk' and "position" = 2`,
  );
  const geschrapt = await refused(kamp, `select delete_own_requirement($1)`, [schrap.id]);
  check('een eis uit de eigen kopie schrappen', geschrapt === null, geschrapt ?? '');
  const naSchrap = await one(
    `select count(*)::int as n from requirements where diploma_id = '${roeien12}' and parent_id is null`,
  );
  check('de landelijke lijst blijft heel', naSchrap.n === bron.eisen, `${naSchrap.n}`);
  const gaten = await one(
    `select count(*)::int as n from requirements r
     where r.diploma_id = '${kopie}' and r.parent_id is null and r.kind = 'praktijk'
       and r."position" > (select count(*) from requirements q
                           where q.diploma_id = '${kopie}' and q.parent_id is null and q.kind = 'praktijk')`,
  );
  check('de nummering sluit weer aan', gaten.n === 0, `${gaten.n} gaten`);

  // De landelijke lijst zelf is van niemand.
  const landelijkRPC = await refused(kamp, `select update_own_list($1, 'Gekaapt')`, [roeien12]);
  check('een landelijke lijst kun je niet hernoemen', landelijkRPC !== null, 'het lukte wel');
  const landelijkDirect = await refused(
    kamp,
    `update diplomas set name = 'Gekaapt' where id = $1`,
    [roeien12],
  );
  const naam = await one(`select name from diplomas where id = '${roeien12}'`);
  check('ook niet rechtstreeks', landelijkDirect !== null || naam.name !== 'Gekaapt', naam.name);
  const landelijkeEis = await refused(
    kamp,
    `update requirements set title = 'Gekaapt' where id = $1`,
    [eis3],
  );
  const eisNaam = await one(`select title from requirements where id = '${eis3}'`);
  check('en een landelijke eis ook niet', landelijkeEis !== null || eisNaam.title !== 'Gekaapt',
    eisNaam.title);

  // Een andere groep kan er niet bij, ook niet als beheerder daar.
  const vreemdeHand = await refused(ander, `select update_own_list($1, 'Van mij nu')`, [insigne]);
  check('een beheerder van een andere groep kan er niet bij', vreemdeHand !== null, 'het lukte wel');

  // Eisen toevoegen, met onderdelen eronder, en niet dieper dan dat.
  const eigenEis = (
    await as(kamp, () =>
      db.query(`select add_own_requirement($1, 'praktijk', 'Roer houden', 'Op een rechte koers') as id`, [
        insigne,
      ]),
    )
  ).rows[0].id;
  const eigenOnderdeel = (
    await as(kamp, () =>
      db.query(`select add_own_requirement($1, 'praktijk', 'Stuurboord', null, $2) as id`, [
        insigne,
        eigenEis,
      ]),
    )
  ).rows[0].id;
  check('een eis met een onderdeel eronder', !!eigenOnderdeel, String(eigenOnderdeel));
  const teDiep = await refused(
    kamp,
    `select add_own_requirement($1, 'praktijk', 'Nog dieper', null, $2)`,
    [insigne, eigenOnderdeel],
  );
  check('een onderdeel van een onderdeel kan niet', teDiep !== null, 'het lukte wel');

  // Volgorde omdraaien.
  const tweede = (
    await as(kamp, () =>
      db.query(`select add_own_requirement($1, 'praktijk', 'Afmeren') as id`, [insigne]),
    )
  ).rows[0].id;
  const omgedraaid = await refused(
    kamp,
    `select set_own_requirement_order($1, 'praktijk', null, $2::uuid[])`,
    [insigne, [tweede, eigenEis]],
  );
  check('de volgorde aanpassen', omgedraaid === null, omgedraaid ?? '');
  const eerste = await one(
    `select title from requirements where diploma_id = '${insigne}' and parent_id is null
       and kind = 'praktijk' and "position" = 1`,
  );
  check('en Afmeren staat nu bovenaan', eerste.title === 'Afmeren', eerste.title);

  // Aftekenen op een eigen lijst werkt als op elke andere.
  const kampInschrijving = (
    await as(kamp, () =>
      db.query(
        `insert into enrollments (group_id, profile_id, diploma_id) values ($1, $2, $3) returning id`,
        [jwf, nina, insigne],
      ),
    )
  ).rows[0].id;
  const afgetekend = await refused(
    kamp,
    `select set_sign_off_status($1, $2, 'gehaald', null)`,
    [kampInschrijving, eigenEis],
  );
  check('aftekenen op een eigen lijst', afgetekend === null, afgetekend ?? '');
  const voortgang = await as(kamp, () =>
    one(`select done, total from enrollment_progress where enrollment_id = '${kampInschrijving}'`),
  );
  check('en het telt mee in de voortgang', Number(voortgang.done) === 1 && Number(voortgang.total) === 2,
    `${voortgang.done} van ${voortgang.total}`);

  // Weggooien kan pas als er niemand meer aan werkt.
  const bezet = await refused(kamp, `select delete_own_list($1)`, [insigne]);
  check('een lijst met een opleiding eraan gaat niet weg', bezet !== null, 'het lukte wel');
  await db.exec(`delete from enrollments where id = '${kampInschrijving}'`);
  const weggegooid = await refused(kamp, `select delete_own_list($1)`, [insigne]);
  check('daarna wel', weggegooid === null, weggegooid ?? '');
  const eisenWeg = await one(
    `select count(*)::int as n from requirements where diploma_id = '${insigne}'`,
  );
  check('en zijn eisen gaan mee', eisenWeg.n === 0, `${eisenWeg.n}`);

  section('Examens');

  // Een examen van twee vragen. De instructeur maakt het op de gewone manier:
  // via de tabellen, want daar mag hij bij.
  const examen = (
    await as(kamp, () =>
      db.query(
        `insert into exams (group_id, title, intro, pass_percent, shuffle, created_by)
         values ($1, 'Theorie Roeien', 'Tien minuten, geen boekje', 60, false, $2) returning id`,
        [jwf, kamp],
      ),
    )
  ).rows[0].id;

  const vraag = {};
  for (const [nr, tekst, goed, fout] of [
    [1, 'Welke kant is stuurboord?', 'Rechts', 'Links'],
    [2, 'Wat betekent oploeven?', 'Meer naar de wind toe', 'Van de wind af'],
  ]) {
    vraag[nr] = (
      await as(kamp, () =>
        db.query(
          `insert into exam_questions (exam_id, position, prompt) values ($1, $2, $3) returning id`,
          [examen, nr, tekst],
        ),
      )
    ).rows[0].id;
    await as(kamp, () =>
      db.query(
        `insert into exam_options (question_id, position, label, correct)
         values ($1, 1, $2, true), ($1, 2, $3, false)`,
        [vraag[nr], goed, fout],
      ),
    );
  }

  // Een lid van de groep mag de vragen niet zien; anders is er geen examen meer.
  const vragenVoorLid = await as(vaarder, () =>
    one(`select count(*)::int as n from exam_questions where exam_id = '${examen}'`),
  );
  check('een lid ziet de vragen niet', vragenVoorLid.n === 0, `${vragenVoorLid.n}`);
  const vragenVoorVreemde = await as(ander, () =>
    one(`select count(*)::int as n from exam_questions`),
  );
  check('een andere groep ook niet', vragenVoorVreemde.n === 0, `${vragenVoorVreemde.n}`);
  const antwoordenZonderLogin = await as('', () =>
    one(`select count(*)::int as n from exam_options`),
  );
  check('en zonder inloggen al helemaal niet', antwoordenZonderLogin.n === 0,
    `${antwoordenZonderLogin.n}`);

  // Een vraag mag bij een eis horen, zodat je een examen uit de eisenlijst kunt
  // bouwen. Verdwijnt die eis later, dan blijft de vraag staan: een afgenomen
  // examen hoort niet te veranderen omdat iemand de catalogus opruimt.
  const losseEis = (
    await as(kamp, () =>
      db.query(`select add_own_requirement($1, 'theorie', 'Proefeis') as id`, [kopie]),
    )
  ).rows[0].id;
  await as(kamp, () =>
    db.query(
      `update exam_questions set requirement_id = $1 where id = $2`,
      [losseEis, vraag[1]],
    ),
  );
  const gekoppeld = await one(
    `select requirement_id from exam_questions where id = '${vraag[1]}'`,
  );
  check('een vraag kan bij een eis horen', gekoppeld.requirement_id === losseEis,
    String(gekoppeld.requirement_id));

  await as(kamp, () => db.query(`select delete_own_requirement($1)`, [losseEis]));
  const naWeghalen = await one(
    `select count(*)::int as n, count(requirement_id)::int as gekoppeld
     from exam_questions where id = '${vraag[1]}'`,
  );
  check('en blijft bestaan als die eis verdwijnt',
    naWeghalen.n === 1 && naWeghalen.gekoppeld === 0,
    `${naWeghalen.n} / ${naWeghalen.gekoppeld}`);

  // Afnemen: een sessie met een code.
  const sessie = (
    await as(kamp, () => db.query(`select * from open_exam_session($1, 'Herfstkamp')`, [examen]))
  ).rows[0];
  check('een sessie krijgt een code van zes tekens', /^[A-Z2-9]{6}$/.test(sessie.code),
    sessie.code);

  const doorVreemde = await refused(ander, `select * from open_exam_session($1)`, [examen]);
  check('een andere groep kan er geen sessie van openen', doorVreemde !== null, 'het lukte wel');

  // Meedoen zonder account: alleen de code en een naam.
  const mee = (
    await as('', () => db.query(`select * from exam_join($1, 'Anouk Bakker')`, [sessie.code]))
  ).rows[0];
  check('meedoen met de code, zonder inloggen', !!mee.attempt_id, String(mee.attempt_id));
  check('en je krijgt de vragen', mee.questions.length === 2, `${mee.questions.length}`);

  const lek = JSON.stringify(mee.questions);
  check('zonder het juiste antwoord erbij', !/correct/i.test(lek), lek.slice(0, 80));

  const fouteCode = await refused('', `select * from exam_join('XXXXXX', 'Iemand')`);
  check('een code die niet bestaat doet niets', fouteCode !== null, 'het lukte wel');
  const zonderNaam = await refused('', `select * from exam_join($1, ' ')`, [sessie.code]);
  check('en zonder naam kom je er niet in', zonderNaam !== null, 'het lukte wel');

  // Antwoorden. Het goede antwoord van vraag 1, het foute van vraag 2.
  const goed1 = await one(
    `select id from exam_options where question_id = '${vraag[1]}' and correct`,
  );
  const fout2 = await one(
    `select id from exam_options where question_id = '${vraag[2]}' and not correct`,
  );
  const geantwoord = await refused(
    '',
    `select exam_answer($1, $2, $3, $4)`,
    [mee.attempt_id, mee.token, vraag[1], goed1.id],
  );
  check('een antwoord opslaan', geantwoord === null, geantwoord ?? '');
  await as('', () =>
    db.query(`select exam_answer($1, $2, $3, $4)`, [mee.attempt_id, mee.token, vraag[2], fout2.id]),
  );

  // Het token is het enige dat een deelname beschermt.
  const metVerzonnenToken = await refused(
    '',
    `select exam_answer($1, gen_random_uuid(), $2, $3)`,
    [mee.attempt_id, vraag[1], goed1.id],
  );
  check('met een verzonnen token kom je er niet bij', metVerzonnenToken !== null, 'het lukte wel');

  // Een tweede deelnemer mag niet bij het werk van de eerste.
  const mee2 = (
    await as('', () => db.query(`select * from exam_join($1, 'Daan Visser')`, [sessie.code]))
  ).rows[0];
  const bijEenAnder = await refused('', `select * from exam_result($1, $2)`, [
    mee.attempt_id,
    mee2.token,
  ]);
  check('en niet bij de deelname van een ander', bijEenAnder !== null, 'het lukte wel');

  // Nakijken gebeurt op de server.
  const uitslag = (
    await as('', () => db.query(`select * from exam_submit($1, $2)`, [mee.attempt_id, mee.token]))
  ).rows[0];
  check('inleveren geeft de score', uitslag.score === 1 && uitslag.total === 2,
    `${uitslag.score} van ${uitslag.total}`);
  check('en zegt of het gehaald is', uitslag.passed === false, String(uitslag.passed));

  // Nakijken mag pas na het inleveren, en alleen als de sessie het toestaat.
  const nagekeken = await as('', async () =>
    (await db.query(`select * from exam_review($1, $2)`, [mee.attempt_id, mee.token])).rows,
  );
  check('na inleveren mag je je antwoorden zien', nagekeken.length === 2,
    `${nagekeken.length}`);
  check('met goed en fout erbij',
    nagekeken[0].correct === true && nagekeken[1].correct === false,
    JSON.stringify(nagekeken.map((r) => r.correct)));
  check('en wat het juiste antwoord was', nagekeken[1].juiste === 'Meer naar de wind toe',
    String(nagekeken[1].juiste));

  const nogBezig = await refused('', `select * from exam_review($1, $2)`, [
    mee2.attempt_id,
    mee2.token,
  ]);
  check('wie nog bezig is ziet niets', nogBezig !== null, 'het lukte wel');

  await db.exec(`update exam_sessions set show_answers = false where id = '${sessie.session_id}'`);
  const dichtgehouden = await refused('', `select * from exam_review($1, $2)`, [
    mee.attempt_id,
    mee.token,
  ]);
  check('en met nakijken uit ziet niemand ze', dichtgehouden !== null, 'het lukte wel');
  await db.exec(`update exam_sessions set show_answers = true where id = '${sessie.session_id}'`);

  const naInleveren = await refused('', `select exam_answer($1, $2, $3, $4)`, [
    mee.attempt_id,
    mee.token,
    vraag[2],
    fout2.id,
  ]);
  check('na inleveren kan er niets meer bij', naInleveren !== null, 'het lukte wel');

  // Meekijken hoort bij de groep, en bij niemand anders.
  const overzicht = await as(kamp, async () =>
    (await db.query(`select * from exam_session_overview($1)`, [sessie.session_id])).rows,
  );
  check('de instructeur ziet beide deelnemers', overzicht.length === 2, `${overzicht.length}`);
  // Precies wat de beheerpagina toont: staat er na inleveren ook echt dat het
  // ingeleverd is, met de score erbij?
  const ingeleverd = overzicht.find((r) => r.display_name === 'Anouk Bakker');
  check('de ingeleverde deelname staat als ingeleverd', ingeleverd.submitted_at !== null,
    String(ingeleverd.submitted_at));
  check('met de score erbij', Number(ingeleverd.score) === 1 && Number(ingeleverd.total) === 2,
    `${ingeleverd.score} van ${ingeleverd.total}`);
  const bezig = overzicht.find((r) => r.display_name === 'Daan Visser');
  check('en wie nog bezig is niet', bezig.submitted_at === null, String(bezig.submitted_at));

  // Geslaagd of niet hoort de database te zeggen: de grens staat bij het examen.
  check('het overzicht rekent het percentage uit', Number(ingeleverd.percent) === 50,
    String(ingeleverd.percent));
  check('en zegt dat dit niet gehaald is', ingeleverd.geslaagd === false,
    String(ingeleverd.geslaagd));
  check('met de grens van dit examen erbij', Number(ingeleverd.grens) === 60,
    String(ingeleverd.grens));
  check('wie nog bezig is, is niet gezakt maar onbekend', bezig.geslaagd === null,
    String(bezig.geslaagd));

  check('met hun namen', overzicht[0].display_name === 'Anouk Bakker',
    overzicht[0].display_name);
  const overzichtVreemde = await as(ander, async () =>
    (await db.query(`select * from exam_session_overview($1)`, [sessie.session_id])).rows,
  );
  check('een andere groep ziet niets', overzichtVreemde.length === 0,
    `${overzichtVreemde.length}`);

  const detail = await as(kamp, async () =>
    (await db.query(`select * from exam_attempt_detail($1)`, [mee.attempt_id])).rows,
  );
  check('en kan de antwoorden nakijken', detail.length === 2 && detail[0].correct === true,
    JSON.stringify(detail.map((d) => d.correct)));

  // Van een uitslag naar een aftekening: per eis zien hoe het ging, en die
  // eisen overnemen in de vorderingenstaat — maar alleen als jij dat zegt.
  const roeienEis = await one(
    `select id from requirements where code = 'roeien-12.t1'`,
  );
  await as(kamp, () =>
    db.query(`update exam_questions set requirement_id = $1 where id = $2`, [
      roeienEis.id,
      vraag[1],
    ]),
  );

  const perEis = await as(kamp, async () =>
    (await db.query(`select * from exam_attempt_requirements($1)`, [mee.attempt_id])).rows,
  );
  check('per eis zie je hoe het ging', perEis.length === 1,
    JSON.stringify(perEis.map((r) => [r.eis_title, r.goed, r.vragen])));
  check('met het aantal goede vragen',
    Number(perEis[0]?.goed) === 1 && Number(perEis[0]?.vragen) === 1,
    `${perEis[0]?.goed} van ${perEis[0]?.vragen}`);
  check('en zonder opleiding is er niets om op af te tekenen',
    perEis[0]?.enrollment_id === null, String(perEis[0]?.enrollment_id));

  const zonderKoppeling = await refused(
    kamp,
    `select exam_sign_off_from_attempt($1, $2::uuid[])`,
    [mee.attempt_id, [roeienEis.id]],
  );
  check('aftekenen kan niet zonder vaarder erbij', zonderKoppeling !== null, 'het lukte wel');

  // Koppel de deelname aan Nina, die aan Roeien I/II werkt.
  await as(kamp, () =>
    db.query(`select exam_attempt_link($1, $2)`, [mee.attempt_id, nina]),
  );
  const metOpleiding = await as(kamp, async () =>
    (await db.query(`select * from exam_attempt_requirements($1)`, [mee.attempt_id])).rows,
  );
  check('na koppelen wijst hij de opleiding aan',
    metOpleiding[0]?.enrollment_id === ninaEnrollment,
    String(metOpleiding[0]?.enrollment_id));

  const overgenomen = await as(kamp, async () =>
    (await db.query(`select exam_sign_off_from_attempt($1, $2::uuid[]) as n`, [
      mee.attempt_id,
      [roeienEis.id],
    ])).rows[0].n,
  );
  check('de eis wordt afgetekend', Number(overgenomen) === 1, String(overgenomen));

  const stand = await one(
    `select status, note from sign_offs
     where enrollment_id = '${ninaEnrollment}' and requirement_id = '${roeienEis.id}'`,
  );
  check('en staat op gehaald', stand?.status === 'gehaald', stand?.status ?? 'niets');
  check('met een notitie waar hij vandaan komt', /^Examen /.test(stand?.note ?? ''),
    stand?.note ?? '');

  const doorVreemdeHand = await refused(
    ander,
    `select exam_sign_off_from_attempt($1, $2::uuid[])`,
    [mee.attempt_id, [roeienEis.id]],
  );
  check('een andere groep kan hier niet aftekenen', doorVreemdeHand !== null, 'het lukte wel');

  // Opruimen: de antwoorden weg, de uitslag blijft. Dat is wat het
  // privacybeleid belooft.
  const morgen = new Date(Date.now() + 864e5).toISOString().slice(0, 10);
  const vooraf = await as(kamp, () =>
    one(`select * from exam_cleanup_preview($1, $2::date)`, [jwf, morgen]),
  );
  check('vooraf zie je hoeveel er weggaat',
    Number(vooraf.antwoorden) >= 2 && Number(vooraf.deelnames) === 2,
    `${vooraf.antwoorden} antwoorden, ${vooraf.deelnames} deelnames`);

  const doorInstructeur = await refused(kamp, `select exam_cleanup($1, $2::date)`, [jwf, morgen]);
  check('een instructeur mag niet wissen', doorInstructeur !== null, 'het lukte wel');

  const gewist = (
    await as(sam, () => db.query(`select exam_cleanup($1, $2::date) as n`, [jwf, morgen]))
  ).rows[0].n;
  check('een beheerder wel', Number(gewist) >= 2, String(gewist));

  const naOpruimen = await one(
    `select
       (select count(*)::int from exam_answers x
        join exam_attempts a on a.id = x.attempt_id where a.session_id = '${sessie.session_id}') as antwoorden,
       (select count(*)::int from exam_attempts where session_id = '${sessie.session_id}') as deelnames,
       (select score from exam_attempts where id = '${mee.attempt_id}') as score`,
  );
  check('de antwoorden zijn weg', naOpruimen.antwoorden === 0, `${naOpruimen.antwoorden}`);
  check('de deelnames blijven staan', naOpruimen.deelnames === 2, `${naOpruimen.deelnames}`);
  check('met hun uitslag', Number(naOpruimen.score) === 1, String(naOpruimen.score));

  // Sluiten is een slot, geen verzoek.
  await as(kamp, () => db.query(`select close_exam_session($1)`, [sessie.session_id]));
  const naSluiten = await refused('', `select exam_answer($1, $2, $3, $4)`, [
    mee2.attempt_id,
    mee2.token,
    vraag[1],
    goed1.id,
  ]);
  check('een gesloten sessie neemt niets meer aan', naSluiten !== null, 'het lukte wel');
  const meedoenNaSluiten = await refused('', `select * from exam_join($1, 'Te laat')`, [
    sessie.code,
  ]);
  check('en laat niemand meer binnen', meedoenNaSluiten !== null, 'het lukte wel');

  // Een sessie die niemand sluit, sluit zichzelf.
  await db.exec(`update exam_sessions set status = 'open', closes_at = now() - interval '1 minute'
                 where id = '${sessie.session_id}'`);
  const verlopen = await refused('', `select * from exam_join($1, 'Te laat')`, [sessie.code]);
  check('een sessie die over zijn tijd is ook niet', verlopen !== null, 'het lukte wel');

  section('Lesmateriaal');

  // Eigen mensen. Deze sectie staat achteraan, en daar is wim allang geen lid
  // meer van jwf -- de secties hierboven halen hem eruit. Een sectie die op de
  // nalatenschap van veertien andere leunt, faalt op een dag om een reden die
  // niets met het onderwerp te maken heeft.
  const lesLeiding = await newUser('lesleiding@voorbeeld.nl', 'Lesbaas');
  const lesVaarder = await newUser('lesvaarder@voorbeeld.nl', 'Lesvaarder');
  await db.exec(
    `insert into memberships (group_id, profile_id, role) values
       ('${jwf}', '${lesLeiding}', 'instructeur'),
       ('${jwf}', '${lesVaarder}', 'lid')`,
  );

  const lesPad = jwf + '/' + '11111111-1111-1111-1111-111111111111.pdf';
  const gezet = await refused(lesLeiding,
    `insert into materials (group_id, diploma_id, title, path, bytes)
     values ($1, $2, $3, $4, $5)`,
    [jwf, roeien12, 'Lesboek Roeien', lesPad, 1234]);
  check('een instructeur zet er lesmateriaal in', gezet === null, gezet ?? '');

  // Dit is het punt van de hele tabel: een gewoon lid moet erbij kunnen. Bij de
  // eisenlijst is lezen voor iedereen en schrijven voor de leiding; hier ook,
  // maar lezen is hier het doel en niet de bijvangst.
  const doorLidGelezen = await as(lesVaarder, async () =>
    (await db.query('select * from materials')).rows);
  check('een lid van de groep kan het lezen', doorLidGelezen.length === 1,
    `${doorLidGelezen.length}`);

  const doorLidGezet = await refused(lesVaarder,
    `insert into materials (group_id, title, path) values ($1, $2, $3)`,
    [jwf, 'Stiekem', jwf + '/22222222-2222-2222-2222-222222222222.pdf']);
  check('maar er niets in zetten', doorLidGezet !== null, 'het lukte wel');

  const doorLidWeg = await refused(lesVaarder, 'delete from materials where group_id = $1', [jwf]);
  const erStaatNog = await one('select count(*)::int as n from materials');
  check('en niets weggooien', doorLidWeg !== null || erStaatNog.n === 1, `${erStaatNog.n}`);

  // Een andere groep hoort het niet eens te zien staan. Lesmateriaal is vaak van
  // iemand anders; toestemming voor de ene groep is geen toestemming voor alle.
  const lesDoorVreemde = await as(ander, async () =>
    (await db.query('select * from materials')).rows);
  check('een andere groep ziet het niet', lesDoorVreemde.length === 0,
    `${lesDoorVreemde.length}`);

  const vreemdeZet = await refused(ander,
    `insert into materials (group_id, title, path) values ($1, $2, $3)`,
    [jwf, 'Indringer', jwf + '/33333333-3333-3333-3333-333333333333.pdf']);
  check('en kan er niets in zetten', vreemdeZet !== null, 'het lukte wel');

  // Een eigen lijst weggooien mag geen bestand meenemen: het materiaal wordt
  // algemeen, niet weg.
  const losseLijst = await as(lesLeiding, async () =>
    (await db.query(`select create_own_list($1, $2, 'diploma') as id`,
      [jwf, 'Tijdelijke lijst'])).rows[0].id);
  await as(lesLeiding, () => db.query(
    `insert into materials (group_id, diploma_id, title, path) values ($1, $2, $3, $4)`,
    [jwf, losseLijst, 'Hoort bij die lijst',
      jwf + '/44444444-4444-4444-4444-444444444444.pdf']));
  await as(lesLeiding, () => db.query('select delete_own_list($1)', [losseLijst]));
  const naWeggooien = await one(
    `select count(*)::int as n, count(diploma_id)::int as metDiploma
       from materials where path like '%44444444%'`);
  check('een lijst weggooien neemt het materiaal niet mee', naWeggooien.n === 1,
    `${naWeggooien.n}`);
  check('het wordt algemeen in plaats van weg', naWeggooien.metdiploma === 0,
    `${naWeggooien.metdiploma}`);

  section('Aftekenen met een moment erbij');

  // Eigen mensen, want deze sectie staat achteraan en wim is daar allang geen
  // lid meer van jwf.
  const waterBaas = await newUser('water@voorbeeld.nl', 'Waterinstructeur');
  const waterLid = await newUser('watervaarder@voorbeeld.nl', 'Watervaarder');
  await db.exec(
    `insert into memberships (group_id, profile_id, role) values
       ('${jwf}', '${waterBaas}', 'instructeur'),
       ('${jwf}', '${waterLid}', 'lid')`,
  );
  const waterOpleiding = await as(waterBaas, async () =>
    (await db.query(
      'insert into enrollments (group_id, profile_id, diploma_id) values ($1, $2, $3) returning id',
      [jwf, waterLid, roeien12])).rows[0].id);
  const waterEis = (await one("select id from requirements where code = 'roeien-12.p1'")).id;

  const waterStand = async () => (await one(
    `select status, signed_at from sign_offs
      where enrollment_id = '${waterOpleiding}' and requirement_id = '${waterEis}'`));

  // Om 10:00 op het water afgetekend, pas om 14:00 verstuurd.
  const binnen = await refused(waterBaas,
    "select set_sign_off_status_at($1, $2, 'gehaald', null, $3::timestamptz)",
    [waterOpleiding, waterEis, '2026-09-01T10:00:00Z']);
  check('een aftekening van het water komt binnen', binnen === null, binnen ?? '');
  const metMoment = await waterStand();
  check('en houdt het moment waarop het gebeurde',
    metMoment && metMoment.signed_at.toISOString().startsWith('2026-09-01T10:00'),
    metMoment ? metMoment.signed_at.toISOString() : 'geen rij');

  // Hier gaat het om: wie het eerst tikte maar het laatst aan land komt, mag
  // een nieuwere aftekening niet omver gooien.
  await as(waterBaas, () => db.query(
    "select set_sign_off_status_at($1, $2, 'behandeld', null, $3::timestamptz)",
    [waterOpleiding, waterEis, '2026-09-01T09:00:00Z']));
  check('een oudere handeling overschrijft een nieuwere niet',
    (await waterStand()).status === 'gehaald', (await waterStand()).status);

  await as(waterBaas, () => db.query(
    "select set_sign_off_status_at($1, $2, 'behandeld', null, $3::timestamptz)",
    [waterOpleiding, waterEis, '2026-09-01T11:00:00Z']));
  check('een nieuwere wel', (await waterStand()).status === 'behandeld',
    (await waterStand()).status);

  // Weghalen is ook een handeling, met dezelfde regel.
  await as(waterBaas, () => db.query(
    'select set_sign_off_status_at($1, $2, null, null, $3::timestamptz)',
    [waterOpleiding, waterEis, '2026-09-01T10:30:00Z']));
  check('weghalen met een ouder moment doet niets',
    (await waterStand()) !== undefined, 'de rij was weg');

  await as(waterBaas, () => db.query(
    'select set_sign_off_status_at($1, $2, null, null, $3::timestamptz)',
    [waterOpleiding, waterEis, '2026-09-01T12:00:00Z']));
  const waterWeg = await one(
    `select count(*)::int as n from sign_offs
      where enrollment_id = '${waterOpleiding}' and requirement_id = '${waterEis}'`);
  check('met een nieuwer moment wel', waterWeg.n === 0, `${waterWeg.n}`);

  // Een telefoon met een verkeerd gezette klok mag niet alles daarna blokkeren.
  await as(waterBaas, () => db.query(
    "select set_sign_off_status_at($1, $2, 'gehaald', null, $3::timestamptz)",
    [waterOpleiding, waterEis, '2099-01-01T00:00:00Z']));
  const uitDeToekomst = await waterStand();
  check('een moment uit de toekomst wordt teruggezet naar nu',
    uitDeToekomst && uitDeToekomst.signed_at < new Date(Date.now() + 60000),
    uitDeToekomst ? uitDeToekomst.signed_at.toISOString() : 'geen rij');
  await as(waterBaas, () => db.query(
    "select set_sign_off_status_at($1, $2, 'behandeld', null, null)",
    [waterOpleiding, waterEis]));
  check('en blokkeert dus niet wat erna komt',
    (await waterStand()).status === 'behandeld', (await waterStand()).status);

  // De rollen gelden onverminderd.
  const waterDoorLid = await refused(waterLid,
    "select set_sign_off_status_at($1, $2, 'gehaald', null, null)",
    [waterOpleiding, waterEis]);
  check('een lid tekent ook zo niet af', waterDoorLid !== null, 'het lukte wel');
  const waterDoorVreemde = await refused(ander,
    "select set_sign_off_status_at($1, $2, 'gehaald', null, null)",
    [waterOpleiding, waterEis]);
  check('iemand van buiten de groep ook niet', waterDoorVreemde !== null, 'het lukte wel');

  report();
  process.exit(failures === 0 ? 0 : 1);
}

function report() {
  console.log(
    `\n${checks - failures}/${checks} goed${failures ? ` — ${failures} FOUT` : ''}\n`,
  );
}

async function one(sql, params = []) {
  const r = await db.query(sql, params);
  return r.rows[0];
}

async function newUser(email, name) {
  const r = await db.query(
    `insert into auth.users (email, raw_user_meta_data)
     values ($1, jsonb_build_object('full_name', $2::text)) returning id`,
    [email, name],
  );
  return r.rows[0].id;
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
