/**
 * Aftekeningen die nog verstuurd moeten worden.
 *
 * Een instructeur tekent af op de steiger, waar geen bereik is. De aftekening
 * gaat hier in, het scherm doet alsof hij er al staat, en zodra er verbinding
 * is gaat hij alsnog de deur uit.
 *
 * Het moment gaat mee. Dat is niet hetzelfde als wanneer hij aankomt: een
 * aftekening van tien uur 's ochtends die om vier uur 's middags wordt
 * verstuurd hoort niet te winnen van iets wat om twaalf uur gebeurde. De
 * database beslist daarover in set_sign_off_status_at (029) — hier wordt het
 * moment alleen vastgelegd.
 *
 * Per eis staat er hooguit één taak. Wie drie keer twijfelt tussen behandeld
 * en gehaald, verstuurt niet drie keer: alleen wat hij uiteindelijk bedoelde.
 */

import AsyncStorage from '@react-native-async-storage/async-storage';
import { create } from 'zustand';

import { db } from './supabase';
import { errorMessage } from './errors';
import { isNetwerkFout, meldGelukt, meldMislukt } from './netwerk';
import { pasBewaardeAan } from './opslag';
import type { SheetRow, SignOffStatus } from './types';

const SLEUTEL = 'vinkje:wachtrij';

export type Taak = {
  enrollment_id: string;
  requirement_id: string;
  status: SignOffStatus | null;
  note: string | null;
  /** Wanneer er getikt werd, niet wanneer het verstuurd wordt. */
  moment: string;
};

type Wachtrij = {
  taken: Taak[];
  /** Een fout van de server, geen netwerkfout: die vraagt om aandacht. */
  fout: string | null;
  zet: (taken: Taak[], fout?: string | null) => void;
};

export const useWachtrij = create<Wachtrij>((set) => ({
  taken: [],
  fout: null,
  zet: (taken, fout = null) => set({ taken, fout }),
}));

async function schrijf(taken: Taak[], fout: string | null = null): Promise<void> {
  useWachtrij.getState().zet(taken, fout);
  try {
    await AsyncStorage.setItem(SLEUTEL, JSON.stringify(taken));
  } catch {
    /* niet kunnen bewaren mag het aftekenen niet tegenhouden */
  }
}

export async function laadWachtrij(): Promise<void> {
  try {
    const rauw = await AsyncStorage.getItem(SLEUTEL);
    useWachtrij.getState().zet(rauw ? (JSON.parse(rauw) as Taak[]) : []);
  } catch {
    useWachtrij.getState().zet([]);
  }
}

const sleutelVan = (t: Pick<Taak, 'enrollment_id' | 'requirement_id'>) =>
  t.enrollment_id + ':' + t.requirement_id;

/**
 * Het bewaarde aftekenblad meteen bijwerken.
 *
 * Zonder dit springt het scherm terug zodra het ververst: het haalt dan de
 * opgeslagen versie op, en daar staat de aftekening nog niet in.
 */
async function werkBewaardBladBij(taak: Taak): Promise<void> {
  await pasBewaardeAan<SheetRow[]>('sheet:' + taak.enrollment_id, (rijen) =>
    rijen.map((r) =>
      r.requirement_id === taak.requirement_id
        ? {
            ...r,
            status: taak.status,
            signed_at: taak.status === null ? null : taak.moment,
            note: taak.note ?? r.note,
          }
        : r,
    ),
  );
}

/** Aftekenen: in de wachtrij, scherm bijwerken, en meteen proberen te versturen. */
export async function tekenAf(taak: Taak): Promise<void> {
  const taken = [
    ...useWachtrij.getState().taken.filter((t) => sleutelVan(t) !== sleutelVan(taak)),
    taak,
  ];
  await schrijf(taken);
  await werkBewaardBladBij(taak);
  await verstuurWachtrij();
}

/**
 * Versturen wat er klaarstaat.
 *
 * Op volgorde, en bij de eerste netwerkfout stoppen: de rest komt later wel, en
 * doorgaan levert alleen nog meer mislukte verzoeken op. Een fout van de server
 * is iets anders — die taak gaat eruit, want opnieuw proberen geeft dezelfde
 * weigering, en de melding gaat naar het scherm.
 */
export async function verstuurWachtrij(): Promise<void> {
  const client = db;
  let over = [...useWachtrij.getState().taken];
  if (over.length === 0) return;

  let fout: string | null = null;

  while (over.length > 0) {
    const taak = over[0];
    try {
      const { error } = await client().rpc('set_sign_off_status_at', {
        p_enrollment: taak.enrollment_id,
        p_requirement: taak.requirement_id,
        p_status: taak.status,
        p_note: taak.note,
        p_at: taak.moment,
      });
      if (error) throw error;
      meldGelukt();
      over = over.slice(1);
    } catch (e) {
      if (isNetwerkFout(e)) {
        meldMislukt();
        break;
      }

      // Weggooien mag alleen bij een onmiskenbare weigering, en dat is er één
      // met een code: PGRST202, 23505, P0001. Dan verandert opnieuw proberen
      // niets en blijft de wachtrij anders eeuwig vastzitten.
      //
      // Alles daarbuiten houden we vast. Een netwerkfout die ik niet herken --
      // een melding van een iOS-versie die anders heet, bijvoorbeeld -- zou
      // anders een aftekening wissen die iemand op het water heeft gezet. Dat
      // is het ergste wat deze app kan doen, dus bij twijfel blijft hij staan.
      const code = (e as { code?: unknown }).code;
      fout = errorMessage(e);
      if (typeof code === 'string' && code !== '') {
        over = over.slice(1);
      } else {
        break;
      }
    }
  }

  await schrijf(over, fout);
}

/** Hoeveel er nog wacht, voor het balkje bovenin. */
export function useWachtAantal(): number {
  return useWachtrij((s) => s.taken.length);
}

/** Of deze ene eis nog op versturen wacht, voor een merkje op de regel. */
export function useWachtOpEis(enrollmentId: string, requirementId: string): boolean {
  return useWachtrij((s) =>
    s.taken.some(
      (t) => t.enrollment_id === enrollmentId && t.requirement_id === requirementId,
    ),
  );
}
