/**
 * Turning whatever was thrown into something a mens kan lezen.
 *
 * Supabase does not throw `Error` objects. A failed query rejects with a plain
 * `{ message, details, hint, code }`, and `String()` on that gives the useless
 * "[object Object]" — which is exactly what ends up on screen in place of the
 * one sentence that would have said what went wrong. So the shape is checked
 * rather than the class.
 *
 * `details` and `hint` are included when they are there: PostgREST puts the
 * actionable half of the story in them ("Perhaps you meant the table
 * public.diplomas"), and dropping them costs an afternoon of guessing.
 */

import { isNetwerkFout } from './netwerk';

export function errorMessage(error: unknown): string {
  if (error == null) return '';

  // "TypeError: Network request failed" is waar, en zegt een vaarder op de
  // steiger niets. Dit is geen fout in de app maar een paal zonder bereik.
  if (isNetwerkFout(error)) {
    return 'Geen verbinding. Zodra je weer bereik hebt gaat dit vanzelf verder.';
  }

  if (typeof error === 'string') return error;
  if (error instanceof Error && error.message) return error.message;

  if (typeof error === 'object') {
    const e = error as Record<string, unknown>;
    const parts = [e.message, e.details, e.hint]
      .filter((p): p is string => typeof p === 'string' && p.trim() !== '');

    if (parts.length > 0) {
      const text = parts.join(' — ');
      return typeof e.code === 'string' && e.code ? `${text} (${e.code})` : text;
    }

    // Nothing recognisable: show the thing itself rather than [object Object].
    try {
      return JSON.stringify(error);
    } catch {
      return 'Er ging iets mis, maar de foutmelding is niet leesbaar.';
    }
  }

  return String(error);
}
