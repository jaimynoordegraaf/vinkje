import { useEffect, useRef } from 'react';
import { View } from 'react-native';
import * as Linking from 'expo-linking';
import { Stack, useRouter, useSegments } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { GestureHandlerRootView } from 'react-native-gesture-handler';
import { SafeAreaProvider } from 'react-native-safe-area-context';

import { Loading, Txt } from '@/components/ui';
import { isAuthLink, parseAuthLink } from '@/lib/auth-link';
import { errorMessage } from '@/lib/errors';
import { Verbinding } from '@/components/Verbinding';
import { useSession } from '@/lib/session';
import { isConfigured, supabase } from '@/lib/supabase';
import { useTheme } from '@/lib/use-theme';

export default function RootLayout() {
  const bootstrap = useSession((s) => s.bootstrap);

  useEffect(() => {
    void bootstrap();
  }, [bootstrap]);

  useAuthLinks();

  return (
    <GestureHandlerRootView style={{ flex: 1 }}>
      <SafeAreaProvider>
        <Gate />
      </SafeAreaProvider>
    </GestureHandlerRootView>
  );
}

/**
 * Decides which of the three worlds the app is in: signed out, signed in but
 * not in a groep yet, or in. Keeping it in one place means no screen has to
 * defend itself against a missing session.
 */
function Gate() {
  const t = useTheme();
  const router = useRouter();
  const segments = useSegments();

  const ready = useSession((s) => s.ready);
  const userId = useSession((s) => s.userId);
  const hasGroup = useSession((s) => s.memberships.length > 0);
  const groepenGeladen = useSession((s) => s.groepenGeladen);
  const recovering = useSession((s) => s.recovering);

  const first = segments[0];
  const inAuth = first === 'sign-in';
  const inOnboarding = first === 'welkom';
  const inRecovery = first === 'wachtwoord';

  useEffect(() => {
    if (!ready) return;

    // Binnengekomen via "wachtwoord vergeten": er is een sessie, maar eerst
    // moet er een nieuw wachtwoord gekozen worden, en pas dan de rest van de app.
    if (recovering && userId) {
      if (!inRecovery) router.replace('/wachtwoord');
      return;
    }

    if (!userId) {
      if (!inAuth) router.replace('/sign-in');
    } else if (!hasGroup && groepenGeladen) {
      // Alleen doorsturen als we ook echt wéten dat hij nergens bij hoort.
      // Zonder bereik is de lijst leeg omdat het ophalen mislukte, en dan is
      // "Een nieuwe groep beginnen" het laatste wat je wil zien.
      if (!inOnboarding) router.replace('/welkom');
    } else if (inAuth || inOnboarding || inRecovery) {
      router.replace('/');
    }
  }, [ready, userId, hasGroup, groepenGeladen, recovering, inAuth, inOnboarding, inRecovery, router]);

  if (!isConfigured) return <NotConfigured />;
  if (!ready) {
    return (
      <View style={{ flex: 1, backgroundColor: t.background, justifyContent: 'center' }}>
        <Loading />
      </View>
    );
  }

  return (
    <>
      <StatusBar style={t.dark ? 'light' : 'dark'} />
      <Verbinding />
      <Stack
        screenOptions={{
          headerStyle: { backgroundColor: t.background },
          headerTintColor: t.text,
          headerShadowVisible: false,
          contentStyle: { backgroundColor: t.background },
          // iOS zet de titel van het vorige scherm naast de terugpijl. Vanuit
          // een tabblad is dat de groep "(tabs)", die geen titel heeft, en dan
          // staat die interne naam in beeld. Overal "Terug" is duidelijker
          // dan een wisselend label, ook vanuit gewone schermen.
          headerBackTitle: 'Terug',
        }}>
        <Stack.Screen name="(tabs)" options={{ headerShown: false }} />
        <Stack.Screen name="sign-in" options={{ headerShown: false }} />
        <Stack.Screen name="welkom" options={{ headerShown: false }} />
        <Stack.Screen name="wachtwoord" options={{ headerShown: false }} />
        <Stack.Screen name="profiel" options={{ title: 'Mijn gegevens' }} />
        <Stack.Screen name="lid/[id]" options={{ title: 'Vaarder' }} />
        <Stack.Screen name="voortgang/[id]" options={{ title: 'Aftekenlijst' }} />
        <Stack.Screen name="diploma/[id]" options={{ title: 'Diploma' }} />
        <Stack.Screen
          name="nieuw/opleiding"
          options={{ title: 'Opleiding starten', presentation: 'modal' }}
        />
        <Stack.Screen
          name="nieuw/lid"
          options={{ title: 'Lid toevoegen', presentation: 'modal' }}
        />
        <Stack.Screen
          name="groep/aanmelden"
          options={{ title: 'Aanmelden bij een groep', presentation: 'modal' }}
        />
        <Stack.Screen
          name="eigen/nieuw"
          options={{ title: 'Eigen lijst', presentation: 'modal' }}
        />
        <Stack.Screen name="bak/[crew]/[req]" options={{ title: 'Bak' }} />
        <Stack.Screen name="bakken/index" options={{ title: 'Bakken' }} />
        <Stack.Screen name="bakken/[id]" options={{ title: 'Bak indelen' }} />
        <Stack.Screen name="beheer/index" options={{ title: 'Beheer' }} />
        <Stack.Screen name="beheer/leden" options={{ title: 'Rollen' }} />
        <Stack.Screen name="beheer/speltakken" options={{ title: 'Speltakken' }} />
        <Stack.Screen name="beheer/uitnodigingen" options={{ title: 'Uitnodigingen' }} />
      </Stack>
    </>
  );
}

function NotConfigured() {
  const t = useTheme();
  return (
    <View
      style={{
        flex: 1,
        backgroundColor: t.background,
        padding: 24,
        gap: 12,
        justifyContent: 'center',
      }}>
      <Txt variant="heading">Nog niet gekoppeld</Txt>
      <Txt dim>
        Er is nog geen server ingesteld. Zet EXPO_PUBLIC_SUPABASE_URL en
        EXPO_PUBLIC_SUPABASE_PUBLISHABLE_KEY in een .env in de projectmap en start
        de app opnieuw. De stappen staan in supabase/README.md.
      </Txt>
    </View>
  );
}

/**
 * Links uit mails van Supabase opvangen: "wachtwoord vergeten" en de
 * bevestiging na het registreren.
 *
 * De sleutels in zo'n link worden omgezet in een sessie. Bij een herstellink
 * gaat de app daarna naar het scherm om een nieuw wachtwoord te kiezen; bij een
 * bevestiging ben je gewoon ingelogd. Een verlopen link geeft een melding op
 * het inlogscherm, in plaats van dat er stilletjes niets gebeurt.
 */
function useAuthLinks() {
  const url = Linking.useLinkingURL();
  const handled = useRef<string | null>(null);

  useEffect(() => {
    if (!url || url === handled.current || !supabase) return;
    const link = parseAuthLink(url);
    if (!isAuthLink(link)) return;
    handled.current = url;

    const { setRecovering, setAuthLinkError } = useSession.getState();

    if (link.error) {
      setAuthLinkError(
        /expired|invalid/i.test(link.error)
          ? 'Deze link is verlopen of al gebruikt. Vraag een nieuwe aan.'
          : link.error,
      );
      return;
    }

    // Vóór de sessie, niet erna: setSession maakt je meteen ingelogd, en dan zou
    // de poortwachter je eerst naar de tabbladen sturen voordat hij weet dat je
    // een nieuw wachtwoord moet kiezen.
    if (link.type === 'recovery') setRecovering(true);

    const client = supabase;
    void (async () => {
      const { error } = link.code
        ? await client.auth.exchangeCodeForSession(link.code)
        : await client.auth.setSession({
            access_token: link.accessToken as string,
            refresh_token: link.refreshToken as string,
          });
      if (error) {
        setRecovering(false);
        setAuthLinkError(errorMessage(error));
        return;
      }
      setAuthLinkError(null);
    })();
  }, [url]);
}
