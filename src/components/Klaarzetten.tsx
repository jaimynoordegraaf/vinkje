/**
 * De knop die alles ophaalt voor op het water.
 *
 * Zonder dit moet je de goede schermen toevallig geopend hebben voordat je
 * wegvaart. Dat lukt een keer en dan vergeet je het precies op de zaterdag dat
 * er geen bereik is.
 *
 * Met een knop en niet vanzelf: het zijn honderden verzoeken, en of dat op wifi
 * gebeurt of op je databundel onderweg hoort jouw keuze te zijn.
 */

import { useState } from 'react';
import { View } from 'react-native';

import { Button, Card, ErrorNote, Txt } from '@/components/ui';
import { zetKlaar, type Stand } from '@/lib/klaarzetten';
import { useNetwerk } from '@/lib/netwerk';
import { errorMessage } from '@/lib/errors';
import { space, radius } from '@/theme';
import { useTheme } from '@/lib/use-theme';

export function Klaarzetten({ groupId }: { groupId: string | null }) {
  const online = useNetwerk((s) => s.online);
  const [stand, setStand] = useState<Stand | null>(null);
  const [klaar, setKlaar] = useState(false);
  const [fout, setFout] = useState<string | null>(null);
  const t = useTheme();

  if (!groupId) return null;

  const bezig = stand !== null && !klaar;
  const deel = stand && stand.totaal > 0 ? stand.gedaan / stand.totaal : 0;

  return (
    <Card>
      <Txt variant="subheading">Klaarzetten voor op het water</Txt>
      <Txt variant="small" dim style={{ marginTop: 2 }}>
        Haalt de eisen, de vaarders en hun aftekenlijsten op, zodat je ze zonder
        bereik kunt zien. Doe dit op wifi; het zijn veel kleine verzoeken.
      </Txt>

      {bezig ? (
        <View style={{ marginTop: space.sm }}>
          <View
            style={{
              height: 8,
              borderRadius: radius.sm,
              backgroundColor: t.chip,
              overflow: 'hidden',
            }}>
            <View
              style={{
                height: '100%',
                width: `${Math.round(deel * 100)}%`,
                backgroundColor: t.accent,
              }}
            />
          </View>
          <Txt variant="small" dim style={{ marginTop: space.xs }}>
            {stand?.bezig} — {stand?.gedaan} van {stand?.totaal}
          </Txt>
        </View>
      ) : null}

      {klaar ? (
        <Txt variant="small" style={{ marginTop: space.xs, color: t.good, fontWeight: '600' }}>
          Alles staat klaar. Ook zonder bereik.
        </Txt>
      ) : null}

      <ErrorNote error={fout} />

      <View style={{ marginTop: space.sm }}>
      <Button
        variant="secondary"
        busy={bezig}
        label={bezig ? 'Bezig…' : klaar ? 'Opnieuw ophalen' : 'Klaarzetten'}
        disabled={bezig || !online}
        onPress={async () => {
          setFout(null);
          setKlaar(false);
          setStand({ gedaan: 0, totaal: 1, bezig: 'Beginnen' });
          try {
            await zetKlaar(groupId, setStand);
            setKlaar(true);
          } catch (e) {
            setFout(errorMessage(e));
          } finally {
            setStand((s) => s);
          }
        }}
      />
      </View>

      {!online ? (
        <Txt variant="small" dim style={{ marginTop: space.xs }}>
          Hiervoor heb je verbinding nodig.
        </Txt>
      ) : null}
    </Card>
  );
}
