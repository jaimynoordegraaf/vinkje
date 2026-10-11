/**
 * Of er verbinding is, afgeleid uit wat er met de verzoeken gebeurt.
 *
 * Er is met opzet geen pakket bijgehaald dat de netwerkstatus uitleest. Zo'n
 * pakket is native, en dat betekent een nieuwe build in beide stores voordat
 * er iets van merkbaar is. Dit werkt met een OTA-update.
 *
 * Bovendien zegt "de telefoon heeft wifi" niet dat Supabase bereikbaar is. Wat
 * telt is of het verzoek aankwam, en dat weten we al.
 */

import { create } from 'zustand';

/**
 * Een mislukt verzoek is niet hetzelfde als een weigering.
 *
 * PostgREST geeft bij een echte fout een `code` mee (PGRST202, 23505, P0001).
 * Valt het verzoek om omdat er geen netwerk is, dan is er geen code en zegt de
 * melding iets over fetch. Dat onderscheid is het hele punt: zonder bereik
 * willen we het bewaarde beeld laten zien, bij een weigering juist niet — dan
 * is er iets mis en moet je dat te zien krijgen.
 */
export function isNetwerkFout(error: unknown): boolean {
  if (error == null) return false;
  const e = error as { code?: unknown; message?: unknown };
  if (typeof e.code === 'string' && e.code !== '') return false;
  const tekst = String(
    (typeof e.message === 'string' && e.message) || error,
  ).toLowerCase();
  return /network|fetch|load failed|failed to connect|timeout|timed out|offline|econn|enotfound/.test(
    tekst,
  );
}

type Netwerk = {
  online: boolean;
  /** Wanneer er voor het laatst iets aankwam. Null zolang er niets gelukt is. */
  laatstGelukt: number | null;
  meldGelukt: () => void;
  meldMislukt: () => void;
};

export const useNetwerk = create<Netwerk>((set, get) => ({
  online: true,
  laatstGelukt: null,
  meldGelukt: () => {
    if (!get().online) set({ online: true });
    set({ laatstGelukt: Date.now() });
  },
  meldMislukt: () => {
    if (get().online) set({ online: false });
  },
}));

/** Buiten React, want de meeste meldingen komen uit de api-laag. */
export const meldGelukt = () => useNetwerk.getState().meldGelukt();
export const meldMislukt = () => useNetwerk.getState().meldMislukt();
export const isOnline = () => useNetwerk.getState().online;
