import { View } from 'react-native';
import { useRouter } from 'expo-router';

import { Button, Card, Chip, Divider, LinkRow, Row, Screen, Txt } from '@/components/ui';
import {
  useActiveGroup,
  useIsAdmin,
  useMyRole,
  useSession,
} from '@/lib/session';
import { Klaarzetten } from '@/components/Klaarzetten';
import { ROLE_LABEL } from '@/lib/types';
import { space } from '@/theme';

export default function Meer() {
  const router = useRouter();
  const group = useActiveGroup();
  const role = useMyRole();
  const admin = useIsAdmin();

  const profile = useSession((s) => s.profile);
  const email = useSession((s) => s.email);
  const memberships = useSession((s) => s.memberships);
  const setActiveGroup = useSession((s) => s.setActiveGroup);
  const signOut = useSession((s) => s.signOut);

  return (
    <Screen>
      <View style={{ gap: space.lg }}>
        <Card>
          <Txt variant="subheading">{profile?.full_name || 'Naam nog niet ingevuld'}</Txt>
          <Txt variant="small" dim>
            {email}
          </Txt>
          <Row gap={space.xs} style={{ marginTop: space.xs }}>
            {group ? <Chip label={group.name} /> : null}
            {role ? <Chip label={ROLE_LABEL[role]} /> : null}
          </Row>
        </Card>

        <Card style={{ paddingVertical: space.xs }}>
          <LinkRow label="Mijn gegevens" onPress={() => router.push('/profiel')} />
          <Divider />
          <LinkRow
            label="Aanmelden bij een groep"
            onPress={() => router.push('/groep/aanmelden')}
          />
          {admin ? (
            <>
              <Divider />
              <LinkRow label="Beheer" onPress={() => router.push('/beheer')} />
            </>
          ) : null}
        </Card>

        {memberships.length > 1 ? (
          <View style={{ gap: space.sm }}>
            <Txt variant="label" dim>
              Wissel van groep
            </Txt>
            <Row gap={space.sm} style={{ flexWrap: 'wrap' }}>
              {memberships.map((m) => (
                <Chip
                  // het lidmaatschap zelf, niet de groep: dat is de sleutel die
                  // per definitie uniek is
                  key={m.id}
                  label={m.group.name}
                  selected={m.group_id === group?.id}
                  onPress={() => void setActiveGroup(m.group_id)}
                />
              ))}
            </Row>
          </View>
        ) : null}

        <View style={{ gap: space.xs }}>
          <Txt variant="small" dim>
            De eisen in deze app komen uit de handboeken van de Watersport Academy
            en zijn landelijk vastgesteld. Klopt er iets niet? Geef het door aan de
            beheerder van de app — de eisenlijst wordt centraal bijgewerkt.
          </Txt>
        </View>

        <Klaarzetten groupId={group?.id ?? null} />

        <Button variant="secondary" label="Uitloggen" onPress={() => void signOut()} />
      </View>
    </Screen>
  );
}
