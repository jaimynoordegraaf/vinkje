/**
 * Wat er het laatst opgehaald is, zodat het er zonder bereik nog staat.
 *
 * Op het water is geen signaal. Tot nu toe las elk scherm rechtstreeks uit de
 * database, dus zonder verbinding was er niets te zien — en erger: de lijst
 * met lidmaatschappen bleef leeg, waarop de app dacht dat je in geen enkele
 * groep zat en je naar het welkomstscherm stuurde.
 *
 * Dit is met opzet geen slimme cache met vervaldatums. Het bewaart het laatste
 * antwoord per sleutel en geeft dat terug als het verzoek niet aankomt. Is er
 * wel bereik, dan wint altijd de database: er wordt niets uit de opslag
 * gelezen zolang het ophalen lukt.
 */

import AsyncStorage from '@react-native-async-storage/async-storage';

import { isNetwerkFout, meldGelukt, meldMislukt } from './netwerk';

const VOORVOEGSEL = 'vinkje:bewaard:';

export async function bewaar(sleutel: string, waarde: unknown): Promise<void> {
  try {
    await AsyncStorage.setItem(VOORVOEGSEL + sleutel, JSON.stringify(waarde));
  } catch {
    // Vol geheugen of een waarde die niet in JSON past. Niet kunnen bewaren is
    // vervelend maar nooit een reden om het scherm te laten vallen.
  }
}

export async function lees<T>(sleutel: string): Promise<T | null> {
  try {
    const rauw = await AsyncStorage.getItem(VOORVOEGSEL + sleutel);
    return rauw === null ? null : (JSON.parse(rauw) as T);
  } catch {
    return null;
  }
}

export async function wis(sleutel: string): Promise<void> {
  try {
    await AsyncStorage.removeItem(VOORVOEGSEL + sleutel);
  } catch {
    /* zie bewaar() */
  }
}

/** Alles weggooien bij uitloggen: wat je bewaarde is van de vorige gebruiker. */
export async function wisAlles(): Promise<void> {
  try {
    const sleutels = await AsyncStorage.getAllKeys();
    const van_ons = sleutels.filter((s) => s.startsWith(VOORVOEGSEL));
    if (van_ons.length) await AsyncStorage.multiRemove(van_ons);
  } catch {
    /* zie bewaar() */
  }
}

/**
 * Ophalen, bewaren, en bij geen bereik teruggeven wat er lag.
 *
 * Een fout die géén netwerkfout is gaat gewoon door naar het scherm. Een
 * geweigerde policy of een ontbrekende functie hoort zichtbaar te zijn; die
 * wegmoffelen achter oude gegevens is precies hoe je een halve dag kwijt bent.
 */
export async function metOpslag<T>(sleutel: string, haal: () => Promise<T>): Promise<T> {
  try {
    const verse = await haal();
    meldGelukt();
    void bewaar(sleutel, verse);
    return verse;
  } catch (e) {
    if (!isNetwerkFout(e)) throw e;
    meldMislukt();
    const bewaarde = await lees<T>(sleutel);
    if (bewaarde !== null) return bewaarde;
    throw e;
  }
}

/** Het bewaarde antwoord bijwerken, voor een aftekening die nog in de wachtrij staat. */
export async function pasBewaardeAan<T>(
  sleutel: string,
  pas: (huidig: T) => T,
): Promise<void> {
  const huidig = await lees<T>(sleutel);
  if (huidig === null) return;
  await bewaar(sleutel, pas(huidig));
}
