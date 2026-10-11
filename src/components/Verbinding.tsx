/**
 * Het balkje dat zegt waar je aan toe bent zonder bereik.
 *
 * Twee dingen die je moet weten op het water: dat wat je ziet bewaard is en
 * niet vers, en dat je aftekeningen nog niet verstuurd zijn. Dat laatste is
 * het belangrijkste — anders sluit je de app af in de veronderstelling dat
 * alles binnen is.
 *
 * Staat alles goed, dan staat er niets. Een balk die altijd in beeld is, leest
 * niemand meer op het moment dat het ertoe doet.
 */

import { useEffect } from 'react';
import { Pressable, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { Txt } from '@/components/ui';
import { prik, useNetwerk } from '@/lib/netwerk';
import { verbindingsAdres, verbindingsSleutel } from '@/lib/supabase';
import { useWachtrij, verstuurWachtrij } from '@/lib/wachtrij';
import { useTheme } from '@/lib/use-theme';
import { space } from '@/theme';

export function Verbinding() {
  const online = useNetwerk((s) => s.online);
  const wachtend = useWachtrij((s) => s.taken.length);
  const fout = useWachtrij((s) => s.fout);
  const t = useTheme();
  const insets = useSafeAreaInsets();

  // Zodra er iets klaarstaat, blijven proberen. Twintig seconden is vaak genoeg
  // om het moment te pakken waarop je langs een mast vaart, en zelden genoeg om
  // een batterij te merken.
  useEffect(() => {
    // Zonder bereik: eens per twintig seconden één goedkoop verzoek om te
    // merken dat het terug is. Staat er iets klaar, dan meteen versturen.
    if (online && wachtend === 0) return;
    const tik = setInterval(() => {
      if (wachtend > 0) {
        void verstuurWachtrij();
      } else if (verbindingsAdres && verbindingsSleutel) {
        void prik(verbindingsAdres, verbindingsSleutel);
      }
    }, 20000);
    return () => clearInterval(tik);
  }, [wachtend, online]);

  if (online && wachtend === 0 && !fout) return null;

  // Elke achtergrond zijn eigen tekstkleur. onAccent is berekend bij de
  // accentkleur en zegt niets over wat er op warn of danger leesbaar is;
  // die twee zijn donker genoeg voor wit.
  const kleur = fout ? t.danger : online ? t.accent : t.warn;
  const opKleur = fout ? t.onDanger : online ? t.onAccent : '#FFFFFF';
  const tekst = fout
    ? fout
    : wachtend > 0
      ? `${wachtend} ${wachtend === 1 ? 'aftekening wacht' : 'aftekeningen wachten'}` +
        (online ? ' — versturen…' : ' tot je weer bereik hebt')
      : 'Geen verbinding. Je ziet wat er het laatst is opgehaald.';

  return (
    <Pressable
      onPress={() => void verstuurWachtrij()}
      style={{
        backgroundColor: kleur,
        paddingTop: insets.top + 6,
        paddingBottom: 8,
        paddingHorizontal: space.md,
      }}>
      <Txt variant="small" style={{ color: opKleur, fontWeight: '600', textAlign: 'center' }}>
        {tekst}
      </Txt>
    </Pressable>
  );
}
