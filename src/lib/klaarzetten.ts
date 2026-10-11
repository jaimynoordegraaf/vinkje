/**
 * Alles ophalen wat je op het water nodig hebt, nu je nog bereik hebt.
 *
 * De app bewaart wat hij ophaalt, maar meer dan dat kan hij niet: wat je nooit
 * geopend hebt is er ook niet. Dat werkt als je toevallig de goede schermen
 * langsgelopen bent en niet als je dat vergeet — en vergeten doe je het precies
 * op de zaterdag dat je het nodig hebt.
 *
 * Dit haalt het in één keer op: de eisen van alle diploma's, de leden, hun
 * opleidingen en aftekenlijsten, en de bakken. Met een knop en niet vanzelf op
 * de achtergrond, want het zijn honderden verzoeken en dat hoor je te kiezen —
 * op wifi thuis, niet op je databundel onderweg.
 *
 * Een stap die mislukt stopt het geheel niet. Een lid mag de ledenlijst niet
 * opvragen, en dat hoort dan gewoon overgeslagen te worden in plaats van de
 * hele voorbereiding te laten stranden.
 */

import {
  fetchCatalogue,
  fetchCrew,
  fetchCrewDiplomas,
  fetchCrewRoster,
  fetchCrewSizes,
  fetchCrews,
  fetchDiploma,
  fetchEnrollment,
  fetchEnrollments,
  fetchMembers,
  fetchProfileName,
  fetchSections,
  fetchSheet,
} from './api';

export type Stand = {
  gedaan: number;
  totaal: number;
  /** Wat er nu opgehaald wordt, voor onder de balk. */
  bezig: string;
};

/** Een mislukte stap mag de rest niet meenemen. */
async function probeer<T>(taak: () => Promise<T>): Promise<T | null> {
  try {
    return await taak();
  } catch {
    return null;
  }
}

/**
 * Een handvol tegelijk.
 *
 * Alles tegelijk afvuren laat een telefoon op een matige verbinding omvallen —
 * en dan staat de helft er niet, zonder dat iemand het merkt. Vier tegelijk is
 * merkbaar sneller dan een voor een en blijft rustig.
 */
async function metVieren<T>(
  dingen: T[],
  doe: (ding: T) => Promise<unknown>,
  naElk: () => void,
): Promise<void> {
  const rij = [...dingen];
  const werkers = Array.from({ length: Math.min(4, rij.length) }, async () => {
    while (rij.length > 0) {
      const ding = rij.shift();
      if (ding === undefined) return;
      await probeer(() => doe(ding));
      naElk();
    }
  });
  await Promise.all(werkers);
}

export async function zetKlaar(
  groupId: string,
  meld: (stand: Stand) => void,
): Promise<{ opgehaald: number }> {
  let gedaan = 0;
  let totaal = 4; // wat we nu al weten: catalogus, speltakken, leden, bakken
  const stap = (bezig: string) => meld({ gedaan, totaal, bezig });

  stap('De eisenlijsten');
  const catalogus = await probeer(() => fetchCatalogue());
  gedaan += 1;

  await probeer(() => fetchSections(groupId));
  gedaan += 1;
  stap('De leden');
  const leden = (await probeer(() => fetchMembers(groupId))) ?? [];
  gedaan += 1;
  const bakken = (await probeer(() => fetchCrews(groupId))) ?? [];
  await probeer(() => fetchCrewSizes());
  gedaan += 1;

  // Nu weten we hoeveel werk er is.
  const diplomas = (catalogus ?? []).flatMap((groep) => groep.diplomas);
  totaal += diplomas.length + leden.length + bakken.length;
  stap('De eisen per diploma');

  await metVieren(diplomas, (d) => fetchDiploma(d.id), () => {
    gedaan += 1;
    stap('De eisen per diploma');
  });

  await metVieren(bakken, async (b) => {
    await fetchCrew(b.id);
    await fetchCrewRoster(b.id);
    await fetchCrewDiplomas(b.id);
  }, () => {
    gedaan += 1;
    stap('De bakken');
  });

  // Per lid: zijn naam en zijn opleidingen, en van elke opleiding de
  // aftekenlijst. Dat laatste is waar het om gaat -- dat is het scherm dat je
  // op de steiger openslaat.
  const opleidingen: string[] = [];
  await metVieren(leden, async (lid) => {
    await fetchProfileName(lid.profile_id);
    const rijen = await fetchEnrollments(groupId, lid.profile_id);
    for (const r of rijen) opleidingen.push(r.enrollment_id);
  }, () => {
    gedaan += 1;
    stap('De vaarders');
  });

  totaal += opleidingen.length;
  stap('De aftekenlijsten');
  await metVieren(opleidingen, async (id) => {
    await fetchEnrollment(id);
    await fetchSheet(id);
  }, () => {
    gedaan += 1;
    stap('De aftekenlijsten');
  });

  meld({ gedaan: totaal, totaal, bezig: 'Klaar' });
  return { opgehaald: totaal };
}
