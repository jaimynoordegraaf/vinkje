/**
 * Everything the app asks the database for.
 *
 * Reads that need a join across the catalogue and the voortgang go through the
 * `security definer` functions in supabase/003-rpc.sql — one round trip, and
 * the guard is in the database rather than in a screen that might forget it.
 * Everything else is a plain table query behind RLS.
 */

import { db } from './supabase';
import { metOpslag } from './opslag';
import { tekenAf } from './wachtrij';
import type {
  Crew,
  CrewDiploma,
  CrewSheetRow,
  Diploma,
  Discipline,
  DisciplineWithDiplomas,
  EnrollmentRow,
  Invite,
  ListKind,
  Material,
  MemberRow,
  Requirement,
  RequirementKind,
  Role,
  Section,
  SheetRow,
  SignOffStatus,
} from './types';

// ---------------------------------------------------------------- groep

export async function createGroup(name: string): Promise<string> {
  const { data, error } = await db().rpc('create_group', {
    p_name: name.trim(),
    p_slug: slugify(name),
  });
  if (error) throw error;
  return data as string;
}

export async function redeemInvite(code: string): Promise<string> {
  const { data, error } = await db().rpc('redeem_invite', {
    p_code: code.trim().toUpperCase(),
  });
  if (error) throw error;
  return data as string;
}

function slugify(name: string): string {
  const base = name
    .toLowerCase()
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-|-$/g, '')
    .slice(0, 40);
  // A slug has to be unique across every groep, and two groups called
  // "Scouting Jan Willem Friso" is not far-fetched.
  return `${base || 'groep'}-${Math.random().toString(36).slice(2, 6)}`;
}

// ---------------------------------------------------------------- de vaarders

export async function fetchMembers(groupId: string): Promise<MemberRow[]> {
  return metOpslag('members:' + groupId, async () => {
    const { data, error } = await db().rpc('group_members', { p_group: groupId });
    if (error) throw error;
    return (data ?? []) as MemberRow[];
  });
}

/**
 * Iemand in het register zetten die geen account heeft en dat ook niet krijgt.
 * De meeste vaarders zijn kinderen zonder telefoon; hun vorderingenstaat moet er
 * zijn zonder dat zij zich ergens aanmelden.
 */
export async function addMember(groupId: string, fullName: string): Promise<string> {
  const { data, error } = await db().rpc('add_member', {
    p_group: groupId,
    p_name: fullName.trim(),
  });
  if (error) throw error;
  return data as string;
}

/** Een naam corrigeren voor iemand die dat zelf niet kan, omdat hij niet inlogt. */
export async function setMemberName(
  groupId: string,
  profileId: string,
  fullName: string,
): Promise<void> {
  const { error } = await db().rpc('set_member_name', {
    p_group: groupId,
    p_profile: profileId,
    p_name: fullName.trim(),
  });
  if (error) throw error;
}

export async function fetchProfileName(profileId: string): Promise<string> {
  const { data, error } = await db()
    .from('profiles')
    .select('full_name')
    .eq('id', profileId)
    .maybeSingle();
  if (error) throw error;
  return (data?.full_name as string) ?? '';
}

/** Leave `profileId` out for your own voortgang. */
export async function fetchEnrollments(
  groupId: string,
  profileId?: string,
): Promise<EnrollmentRow[]> {
  return metOpslag('enrollments:' + groupId + ':' + (profileId ?? 'ik'), async () => {
    const { data, error } = await db().rpc('member_enrollments', {
      p_group: groupId,
      p_profile: profileId ?? null,
    });
    if (error) throw error;
    return (data ?? []) as EnrollmentRow[];
  });
}

/** The opleiding itself: who, which diploma, and the dates around the examens. */
export async function fetchEnrollment(enrollmentId: string): Promise<EnrollmentDetail> {
  const { data, error } = await db()
    .from('enrollments')
    .select(
      // profiles!profile_id is geen omhaal: enrollments wijst op twee manieren
      // naar profiles — profile_id (de kandidaat) en created_by (wie hem
      // inschreef). Zonder die hint weigert PostgREST de embed, omdat het niet
      // kan raden welke van de twee bedoeld is. Laat hem staan.
      'id, group_id, profile_id, started_on, theory_passed_on, awarded_on, note, profiles!profile_id(id, full_name), diplomas(*, disciplines(*))',
    )
    .eq('id', enrollmentId)
    .single();
  if (error) throw error;

  const row = data as any;
  const { disciplines, ...diploma } = row.diplomas;
  return {
    id: row.id,
    group_id: row.group_id,
    profile_id: row.profile_id,
    started_on: row.started_on,
    theory_passed_on: row.theory_passed_on,
    awarded_on: row.awarded_on,
    note: row.note,
    member: row.profiles as { id: string; full_name: string },
    diploma: diploma as Diploma,
    discipline: (disciplines ?? null) as Discipline | null,
  };
}

export type EnrollmentDetail = {
  id: string;
  group_id: string;
  profile_id: string;
  started_on: string;
  theory_passed_on: string | null;
  awarded_on: string | null;
  note: string | null;
  member: { id: string; full_name: string };
  diploma: Diploma;
  /** Null bij een eigen lijst. */
  discipline: Discipline | null;
};

export async function fetchSheet(enrollmentId: string): Promise<SheetRow[]> {
  return metOpslag('sheet:' + enrollmentId, async () => {
    const { data, error } = await db().rpc('enrollment_sheet', {
      p_enrollment: enrollmentId,
    });
    if (error) throw error;
    return (data ?? []) as SheetRow[];
  });
}

/**
 * Tick one eis off, or take it back. The database fills in who signed and
 * when — the app is never trusted with either.
 */
export async function setSignOff(
  enrollmentId: string,
  requirementId: string,
  signed: boolean,
  note?: string | null,
): Promise<void> {
  const { error } = await db().rpc('set_sign_off', {
    p_enrollment: enrollmentId,
    p_requirement: requirementId,
    p_signed: signed,
    p_note: note ?? null,
  });
  if (error) throw error;
}

/**
 * Eén eis op een stand zetten: 'behandeld', 'gehaald', of null voor niet
 * behandeld. Een notitie blijft staan als je er geen nieuwe meegeeft; een lege
 * string wist hem.
 */
export async function setSignOffStatus(
  enrollmentId: string,
  requirementId: string,
  status: SignOffStatus | null,
  note?: string | null,
): Promise<void> {
  // Niet rechtstreeks naar de database: op het water is er geen bereik. De
  // aftekening gaat in de wachtrij, het scherm toont hem meteen, en versturen
  // gebeurt zodra het kan. Het moment van tikken gaat mee, want dat is wat
  // telt als twee instructeurs dezelfde eis aanraken.
  await tekenAf({
    enrollment_id: enrollmentId,
    requirement_id: requirementId,
    status,
    note: note ?? null,
    moment: new Date().toISOString(),
  });
}

// ---------------------------------------------------------------- bakken

export async function fetchCrews(groupId: string): Promise<Crew[]> {
  return metOpslag('crews:' + groupId, async () => {
    const { data, error } = await db()
      .from('crews')
      .select('*')
      .eq('group_id', groupId)
      .order('sort_order')
      .order('name');
    if (error) throw error;
    return (data ?? []) as Crew[];
  });
}

export async function fetchCrew(crewId: string): Promise<Crew> {
  const { data, error } = await db().from('crews').select('*').eq('id', crewId).single();
  if (error) throw error;
  return data as Crew;
}

export async function createCrew(groupId: string, name: string): Promise<void> {
  const { error } = await db().from('crews').insert({ group_id: groupId, name: name.trim() });
  if (error) throw error;
}

export async function deleteCrew(crewId: string): Promise<void> {
  const { error } = await db().from('crews').delete().eq('id', crewId);
  if (error) throw error;
}

/** Hoeveel mensen er in elke bak zitten, voor de lijst met bakken. */
export async function fetchCrewSizes(): Promise<Record<string, number>> {
  const { data, error } = await db().from('crew_members').select('crew_id');
  if (error) throw error;
  const sizes: Record<string, number> = {};
  for (const row of data ?? []) {
    sizes[row.crew_id] = (sizes[row.crew_id] ?? 0) + 1;
  }
  return sizes;
}

export async function fetchCrewRoster(
  crewId: string,
): Promise<{ profile_id: string; full_name: string }[]> {
  const { data, error } = await db().rpc('crew_roster', { p_crew: crewId });
  if (error) throw error;
  return data ?? [];
}

/** De hele bemanning in één keer vervangen. */
export async function setCrewMembers(crewId: string, profileIds: string[]): Promise<void> {
  const { error } = await db().rpc('set_crew_members', {
    p_crew: crewId,
    p_profiles: profileIds,
  });
  if (error) throw error;
}

export async function fetchCrewDiplomas(crewId: string): Promise<CrewDiploma[]> {
  const { data, error } = await db().rpc('crew_diplomas', { p_crew: crewId });
  if (error) throw error;
  return (data ?? []) as CrewDiploma[];
}

export async function fetchCrewSheet(
  crewId: string,
  requirementId: string,
): Promise<CrewSheetRow[]> {
  return metOpslag('crewsheet:' + crewId + ':' + requirementId, async () => {
    const { data, error } = await db().rpc('crew_sheet', {
      p_crew: crewId,
      p_requirement: requirementId,
    });
    if (error) throw error;
    return (data ?? []) as CrewSheetRow[];
  });
}

export async function fetchRequirement(requirementId: string): Promise<Requirement> {
  const { data, error } = await db()
    .from('requirements')
    .select('*')
    .eq('id', requirementId)
    .single();
  if (error) throw error;
  return data as Requirement;
}

// ---------------------------------------------------------------- opleidingen

export async function enroll(
  groupId: string,
  profileId: string,
  diplomaId: string,
  createdBy: string,
): Promise<string> {
  const { data, error } = await db()
    .from('enrollments')
    .insert({
      group_id: groupId,
      profile_id: profileId,
      diploma_id: diplomaId,
      created_by: createdBy,
    })
    .select('id')
    .single();
  if (error) throw error;
  return data.id as string;
}

export async function updateEnrollment(
  enrollmentId: string,
  patch: {
    theory_passed_on?: string | null;
    awarded_on?: string | null;
    note?: string | null;
  },
): Promise<void> {
  const { error } = await db().from('enrollments').update(patch).eq('id', enrollmentId);
  if (error) throw error;
}

/** Removing an opleiding takes its aftekeningen with it — the cascade is in the schema. */
export async function deleteEnrollment(enrollmentId: string): Promise<void> {
  const { error } = await db().from('enrollments').delete().eq('id', enrollmentId);
  if (error) throw error;
}

// ---------------------------------------------------------------- catalogus

export async function fetchCatalogue(): Promise<DisciplineWithDiplomas[]> {
  return metOpslag('catalogus', async () => {
  const [disciplines, diplomas] = await Promise.all([
    db().from('disciplines').select('*').order('sort_order'),
    db().from('diplomas').select('*').order('sort_order'),
  ]);
  if (disciplines.error) throw disciplines.error;
  if (diplomas.error) throw diplomas.error;

  const all = (diplomas.data ?? []) as Diploma[];
  const landelijk = ((disciplines.data ?? []) as Discipline[]).map((d) => ({
    ...d,
    diplomas: all.filter((dip) => dip.discipline_id === d.id),
  }));

  // Eigen lijsten hangen aan geen enkele landelijke discipline. Ze krijgen hier
  // hun eigen kopje, zodat het bemanningslid-insigne niet tussen de CWO-diploma's
  // verdwijnt. De id is een verzonnen sleutel voor de lijst op het scherm, geen rij.
  // Let op de dubbele ontkenning: draait de update vóór de migratie, dan bestaat
  // de kolom nog niet en is group_id undefined. Dan is niets een eigen lijst,
  // in plaats van alles.
  const eigen = all.filter((dip) => !!dip.group_id);
  const eigenGroep = (kind: ListKind, name: string, subtitle: string) => ({
    id: `eigen-${kind}`,
    code: `eigen-${kind}`,
    name,
    subtitle,
    sort_order: 90,
    diplomas: eigen.filter((dip) => dip.kind === kind),
  });

  return [
    ...landelijk,
    eigenGroep('diploma', 'Eigen lijsten', 'Van onze groep, niet landelijk'),
    eigenGroep('insigne', 'Insignes', 'Van onze groep'),
  ].filter((g) => g.diplomas.length > 0);
  });
}

export async function fetchDiploma(
  diplomaId: string,
): Promise<{ diploma: Diploma; discipline: Discipline | null; requirements: Requirement[] }> {
  return metOpslag('diploma:' + diplomaId, async () => {
  const [diploma, requirements] = await Promise.all([
    db().from('diplomas').select('*, disciplines(*)').eq('id', diplomaId).single(),
    db()
      .from('requirements')
      .select('*')
      .eq('diploma_id', diplomaId)
      .order('kind')
      .order('position'),
  ]);
  if (diploma.error) throw diploma.error;
  if (requirements.error) throw requirements.error;

  const { disciplines, ...rest } = diploma.data as any;
  return {
    diploma: rest as Diploma,
    discipline: (disciplines ?? null) as Discipline | null,
    requirements: (requirements.data ?? []) as Requirement[],
  };
  });
}

// ---------------------------------------------------------------- beheer

export async function fetchSections(groupId: string): Promise<Section[]> {
  return metOpslag('sections:' + groupId, async () => {
  const { data, error } = await db()
    .from('sections')
    .select('*')
    .eq('group_id', groupId)
    .order('sort_order')
    .order('name');
  if (error) throw error;
  return (data ?? []) as Section[];
  });
}

export async function createSection(groupId: string, name: string): Promise<void> {
  const { error } = await db()
    .from('sections')
    .insert({ group_id: groupId, name: name.trim() });
  if (error) throw error;
}

export async function deleteSection(sectionId: string): Promise<void> {
  const { error } = await db().from('sections').delete().eq('id', sectionId);
  if (error) throw error;
}

export async function setMemberRole(
  groupId: string,
  profileId: string,
  role: Role,
): Promise<void> {
  const { error } = await db()
    .from('memberships')
    .update({ role })
    .eq('group_id', groupId)
    .eq('profile_id', profileId);
  if (error) throw error;
}

/**
 * Iemand uit de groep halen. Zijn aftekeningen blijven staan — meldt hij zich
 * later weer aan met een code, dan staat zijn vorderingenstaat er weer precies
 * zoals hij hem achterliet.
 *
 * Gaat via een functie en niet via een delete, zodat de controle op de laatste
 * beheerder er niet omheen kan.
 */
export async function removeMember(groupId: string, profileId: string): Promise<void> {
  const { error } = await db().rpc('remove_member', {
    p_group: groupId,
    p_profile: profileId,
  });
  if (error) throw error;
}

/**
 * De speltakken van één lid, in één keer vervangen. Een leeg lijstje haalt hem
 * overal uit.
 */
export async function setMemberSections(
  groupId: string,
  profileId: string,
  sectionIds: string[],
): Promise<void> {
  const { error } = await db().rpc('set_member_sections', {
    p_group: groupId,
    p_profile: profileId,
    p_sections: sectionIds,
  });
  if (error) throw error;
}

export async function fetchInvites(groupId: string): Promise<Invite[]> {
  const { data, error } = await db()
    .from('invites')
    .select('*')
    .eq('group_id', groupId)
    .order('created_at', { ascending: false });
  if (error) throw error;
  return (data ?? []) as Invite[];
}

/**
 * `sectionId` zet de nieuwe leden meteen in de goede speltak: redeem_invite
 * koppelt ze eraan zodra ze de code invullen. Dat is de enige plek waar een lid
 * zichzelf in een speltak krijgt zonder dat een beheerder er nog naar omkijkt.
 */
export async function createInvite(
  groupId: string,
  role: Role,
  label: string | null,
  maxUses: number,
  sectionId: string | null = null,
): Promise<Invite> {
  const { data, error } = await db()
    .from('invites')
    .insert({
      group_id: groupId,
      code: inviteCode(),
      role,
      label: label?.trim() || null,
      max_uses: maxUses,
      section_id: sectionId,
    })
    .select('*')
    .single();
  if (error) throw error;
  return data as Invite;
}

export async function deleteInvite(inviteId: string): Promise<void> {
  const { error } = await db().from('invites').delete().eq('id', inviteId);
  if (error) throw error;
}

/** No O/0 and no I/1: the code gets read out loud across a botenloods. */
function inviteCode(): string {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  let out = '';
  for (let i = 0; i < 6; i++) {
    out += alphabet[Math.floor(Math.random() * alphabet.length)];
  }
  return out;
}

// ---------------------------------------------------------------- profiel

export async function updateMyName(userId: string, fullName: string): Promise<void> {
  const { error } = await db()
    .from('profiles')
    .update({ full_name: fullName.trim(), updated_at: new Date().toISOString() })
    .eq('id', userId);
  if (error) throw error;
}

/**
 * Je eigen account weg: login, naam, lidmaatschappen en je eigen voortgang.
 * Wat je bij anderen aftekende blijft staan, zonder jouw naam. De laatste
 * beheerder van een groep krijgt een foutmelding die zegt wat eerst moet.
 */
export async function deleteMyAccount(): Promise<void> {
  const { error } = await db().rpc('delete_my_account');
  if (error) throw error;
}

// ---------------------------------------------------------- eigen lijsten
//
// Een eigen lijst is een diploma of insigne van de groep zelf: het
// bemanningslid-insigne, of een verkorte vletlijst voor een kamp. De database
// laat alleen instructeurs en beheerders van díe groep erbij; de landelijke
// eisen blijven voor iedereen alleen-lezen.

/** Een lege lijst, om zelf vol te zetten. */
export async function createOwnList(
  groupId: string,
  name: string,
  kind: ListKind = 'diploma',
  summary?: string,
): Promise<string> {
  const { data, error } = await db().rpc('create_own_list', {
    p_group: groupId,
    p_name: name,
    p_kind: kind,
    p_summary: summary ?? null,
  });
  if (error) throw error;
  return data as string;
}

/**
 * Een bestaande lijst overnemen om daarna in te korten. De kopie staat los van
 * het origineel: schrappen raakt de landelijke lijst niet.
 */
export async function copyListToGroup(
  groupId: string,
  sourceId: string,
  name?: string,
  kind: ListKind = 'diploma',
): Promise<string> {
  const { data, error } = await db().rpc('copy_list_to_group', {
    p_group: groupId,
    p_source: sourceId,
    p_name: name ?? null,
    p_kind: kind,
  });
  if (error) throw error;
  return data as string;
}

export async function updateOwnList(
  diplomaId: string,
  name: string,
  kind?: ListKind,
  summary?: string,
): Promise<void> {
  const { error } = await db().rpc('update_own_list', {
    p_diploma: diplomaId,
    p_name: name,
    p_kind: kind ?? null,
    p_summary: summary ?? null,
  });
  if (error) throw error;
}

export async function deleteOwnList(diplomaId: string): Promise<void> {
  const { error } = await db().rpc('delete_own_list', { p_diploma: diplomaId });
  if (error) throw error;
}

export async function addOwnRequirement(
  diplomaId: string,
  kind: RequirementKind,
  title: string,
  detail?: string,
  parentId?: string,
): Promise<string> {
  const { data, error } = await db().rpc('add_own_requirement', {
    p_diploma: diplomaId,
    p_kind: kind,
    p_title: title,
    p_detail: detail ?? null,
    p_parent: parentId ?? null,
  });
  if (error) throw error;
  return data as string;
}

export async function updateOwnRequirement(
  requirementId: string,
  title: string,
  detail?: string,
): Promise<void> {
  const { error } = await db().rpc('update_own_requirement', {
    p_requirement: requirementId,
    p_title: title,
    p_detail: detail ?? null,
  });
  if (error) throw error;
}

export async function deleteOwnRequirement(requirementId: string): Promise<void> {
  const { error } = await db().rpc('delete_own_requirement', { p_requirement: requirementId });
  if (error) throw error;
}

/** De hele volgorde in één keer, zoals hij op het scherm staat. */
export async function setOwnRequirementOrder(
  diplomaId: string,
  kind: RequirementKind,
  parentId: string | null,
  ids: string[],
): Promise<void> {
  const { error } = await db().rpc('set_own_requirement_order', {
    p_diploma: diplomaId,
    p_kind: kind,
    p_parent: parentId,
    p_ids: ids,
  });
  if (error) throw error;
}

// ---------------------------------------------------------------- lesmateriaal

/**
 * Lesboeken en naslagkaarten die de groep zelf heeft neergezet.
 *
 * De bestanden staan in een afgeschermde map. Een vast adres bestaat dus niet;
 * je vraagt er een link voor die een uur geldig is, en die krijg je alleen als
 * je in de groep zit. Dat is strenger dan bij de plaatjes in een examen, omdat
 * lesmateriaal vaak door iemand anders gemaakt is.
 */
export async function fetchMaterials(
  groupId: string,
  diplomaId: string,
): Promise<Material[]> {
  const { data, error } = await db()
    .from('materials')
    .select('id, title, path, bytes, created_at')
    .eq('group_id', groupId)
    .eq('diploma_id', diplomaId)
    .order('title');
  if (error) throw error;
  return (data ?? []) as Material[];
}

/** Een link die een uur meegaat. Daarna moet je opnieuw vragen. */
export async function signedMaterialUrl(path: string): Promise<string> {
  const { data, error } = await db().storage
    .from('lesmateriaal')
    .createSignedUrl(path, 3600);
  if (error) throw error;
  return data.signedUrl;
}
