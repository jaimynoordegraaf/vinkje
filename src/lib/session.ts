/**
 * Who is signed in, which Scoutinggroep they are looking at, and what they are
 * allowed to do in it.
 *
 * Everything else in the app reads from here rather than asking Supabase who
 * the user is, so there is one answer to "welke groep" and one place that
 * changes when they switch.
 */

import AsyncStorage from '@react-native-async-storage/async-storage';
import { create } from 'zustand';

import { errorMessage } from './errors';
import { metOpslag, wisAlles } from './opslag';
import { laadWachtrij, verstuurWachtrij } from './wachtrij';
import { db, isConfigured, supabase } from './supabase';
import {
  STAFF_ROLES,
  type MyMembership,
  type Profile,
  type Role,
  type Section,
} from './types';

const ACTIVE_GROUP_KEY = 'vinkje:active-group';

/**
 * De sleutel heette tot de naamswijziging `aftekenboek:active-group`. Wie de app
 * al had staan, heeft zijn groep daar nog liggen: zonder deze terugval zou hij na
 * het bijwerken ineens in de eerste groep uit de lijst kijken in plaats van in die
 * van hemzelf. Eén keer overzetten en de oude weggooien.
 */
const OUDE_ACTIVE_GROUP_KEY = 'aftekenboek:active-group';

async function leesActieveGroep() {
  const nieuwe = await AsyncStorage.getItem(ACTIVE_GROUP_KEY);
  if (nieuwe !== null) return nieuwe;

  const oude = await AsyncStorage.getItem(OUDE_ACTIVE_GROUP_KEY);
  if (oude !== null) {
    await AsyncStorage.setItem(ACTIVE_GROUP_KEY, oude);
    await AsyncStorage.removeItem(OUDE_ACTIVE_GROUP_KEY);
  }
  return oude;
}

type State = {
  /** False until the stored session has been read; the UI waits on this. */
  ready: boolean;
  /**
   * Of de lijst met groepen ooit gelezen is -- vers of uit de opslag.
   *
   * Zonder dit stuurde de app je naar het welkomstscherm zodra het ophalen
   * mislukte: memberships bleef leeg, en leeg betekende "zit in geen enkele
   * groep". Op het water, zonder bereik, stond je dus ineens op "Een nieuwe
   * groep beginnen". Niets weten is iets anders dan nergens bij horen.
   */
  groepenGeladen: boolean;
  userId: string | null;
  email: string | null;
  profile: Profile | null;
  memberships: MyMembership[];
  activeGroupId: string | null;
  sections: Section[];
  error: string | null;
  /**
   * Binnengekomen via een herstellink uit "wachtwoord vergeten". Dan is er een
   * sessie, maar hoort de app niet naar de tabbladen te gaan: eerst een nieuw
   * wachtwoord kiezen.
   */
  recovering: boolean;
  /** Een link uit een mail die niet werkte, meestal omdat hij verlopen was. */
  authLinkError: string | null;
};

type Actions = {
  bootstrap: () => Promise<void>;
  reload: () => Promise<void>;
  setActiveGroup: (groupId: string) => Promise<void>;
  signOut: (scope?: 'global' | 'local') => Promise<void>;
  setRecovering: (recovering: boolean) => void;
  setAuthLinkError: (message: string | null) => void;
};

export const useSession = create<State & Actions>((set, get) => ({
  ready: !isConfigured, // nothing to wait for when there is no server
  groepenGeladen: false,
  userId: null,
  email: null,
  profile: null,
  memberships: [],
  activeGroupId: null,
  sections: [],
  error: null,
  recovering: false,
  authLinkError: null,

  setRecovering(recovering) {
    set({ recovering });
  },

  setAuthLinkError(message) {
    set({ authLinkError: message });
  },

  async bootstrap() {
    if (!supabase) {
      set({ ready: true });
      return;
    }

    const { data } = await supabase.auth.getSession();
    set({
      userId: data.session?.user.id ?? null,
      email: data.session?.user.email ?? null,
    });

    supabase.auth.onAuthStateChange((_event, session) => {
      const previous = get().userId;
      const next = session?.user.id ?? null;
      set({ userId: next, email: session?.user.email ?? null });
      if (next !== previous) void get().reload();
    });

    await get().reload();
    await laadWachtrij();
    void verstuurWachtrij();
    set({ ready: true });
  },

  async reload() {
    if (!supabase || !get().userId) {
      set({ profile: null, memberships: [], sections: [], activeGroupId: null });
      return;
    }

    try {
      const userId = get().userId as string;
      const memberships = await metOpslag('memberships:' + userId, () =>
        fetchMemberships(userId));
      const profile = await metOpslag('profile:' + userId, () => fetchProfile(userId));

      // Keep the groep they were last looking at, if they are still in it.
      const stored = await leesActieveGroep();
      const active =
        memberships.find((m) => m.group_id === stored)?.group_id ??
        memberships[0]?.group_id ??
        null;

      set({ profile, memberships, activeGroupId: active, error: null, groepenGeladen: true });
      set({ sections: active ? await fetchSections(active) : [] });
    } catch (e) {
      set({ error: errorMessage(e) });
    }
  },

  async setActiveGroup(groupId) {
    if (!get().memberships.some((m) => m.group_id === groupId)) return;
    await AsyncStorage.setItem(ACTIVE_GROUP_KEY, groupId);
    set({ activeGroupId: groupId, sections: await fetchSections(groupId) });
  },

  async signOut(scope) {
    await supabase?.auth.signOut(scope ? { scope } : undefined);
    await AsyncStorage.multiRemove([ACTIVE_GROUP_KEY, OUDE_ACTIVE_GROUP_KEY]);
    // Wat bewaard is hoort bij wie er net nog inlogde; dat mag de volgende niet zien.
    await wisAlles();
    set({
      userId: null,
      email: null,
      profile: null,
      memberships: [],
      sections: [],
      activeGroupId: null,
      recovering: false,
    });
  },
}));

// ---------------------------------------------------------------- queries

/**
 * Alleen de lidmaatschappen van de ingelogde persoon zelf.
 *
 * Dat `.eq('profile_id', ...)` is geen overbodige veiligheid maar de kern van
 * deze functie. De policy op memberships geeft je iedereen in je groep te zien
 * — nodig, want leden moeten elkaar kunnen vinden — dus zonder dit filter komt
 * hier de hele groep binnen. Dan staat de groep net zo vaak in de wisselaar als
 * er leden zijn, en erger: useActiveMembership() pakt de eerste regel van die
 * groep, en dat kan de rol van iemand anders zijn. Een beheerder ziet zichzelf
 * dan als lid.
 */
async function fetchMemberships(userId: string): Promise<MyMembership[]> {
  const { data, error } = await db()
    .from('memberships')
    .select(
      'id, group_id, profile_id, role, groups(id, name, slug, accent_color), membership_sections(section_id)',
    )
    .eq('profile_id', userId);
  if (error) throw error;

  return (data ?? [])
    .map((row: any) => ({
      id: row.id,
      group_id: row.group_id,
      profile_id: row.profile_id,
      role: row.role as Role,
      group: row.groups,
      sectionIds: (row.membership_sections ?? []).map((s: any) => s.section_id),
    }))
    .filter((m) => Boolean(m.group))
    .sort((a, b) => a.group.name.localeCompare(b.group.name, 'nl'));
}

async function fetchProfile(userId: string): Promise<Profile | null> {
  const { data, error } = await db()
    .from('profiles')
    .select('id, full_name')
    .eq('id', userId)
    .maybeSingle();
  if (error) throw error;
  return (data as Profile) ?? null;
}

async function fetchSections(groupId: string): Promise<Section[]> {
  const { data, error } = await db()
    .from('sections')
    .select('*')
    .eq('group_id', groupId)
    .order('sort_order')
    .order('name');
  if (error) throw error;
  return (data ?? []) as Section[];
}

// ---------------------------------------------------------------- selectors

export function useActiveMembership(): MyMembership | null {
  return useSession(
    (s) => s.memberships.find((m) => m.group_id === s.activeGroupId) ?? null,
  );
}

export function useActiveGroup() {
  return useActiveMembership()?.group ?? null;
}

export function useMyRole(): Role | null {
  return useActiveMembership()?.role ?? null;
}

/** Instructeurs and beheerders: the people who may aftekenen. */
export function useIsStaff(): boolean {
  const role = useMyRole();
  return role !== null && STAFF_ROLES.includes(role);
}

export function useIsAdmin(): boolean {
  return useMyRole() === 'beheerder';
}
