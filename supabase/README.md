# Supabase setup

Stappen die alleen jij kunt doen. De app start ook zonder dit — hij laat dan een
"nog niet gekoppeld"-scherm zien in plaats van te crashen — maar er wordt niets
bewaard tot dit klaar is.

## 1. Project aanmaken

1. <https://supabase.com/dashboard> → **New project**. Kies regio **West EU
   (Ireland)**, dan blijven ledengegevens in de EU.
2. Bewaar het databasewachtwoord ergens veilig.

## 2. De SQL draaien

Voor een nieuw project is `schema.sql` alles in één keer. Kopieer hem vanuit de
projectmap naar het klembord:

```bash
Get-Content supabase/schema.sql -Encoding UTF8 | Set-Clipboard
```

Let op `-Encoding UTF8`. Zonder dat leest PowerShell 5.1 een bestand zonder BOM
als ANSI: `é` wordt dan `Ã©` en `—` wordt `â€”`. Dat plak je zo de database in,
en je ziet het pas terug in de app. Repareren gaat door `010-eisen.sql` opnieuw
te draaien, mét die vlag — hij werkt bij op `code`, dus aftekeningen blijven staan.

Dan **SQL Editor → New query**, plakken, **Run**. Hij hoort te eindigen met
"Success. No rows returned".

De genummerde bestanden zijn hetzelfde, opgesplitst, en zijn wat je draait op een
project dat al bestaat:

    001-core.sql              tabellen, types, helperfuncties, profiel-trigger
    002-rls.sql               row level security — tot dit draait staan de
                              tabellen open
    003-rpc.sql               create_group, redeem_invite, group_members,
                              member_enrollments, enrollment_sheet, set_sign_off
    010-eisen.sql             de diploma's, hun eisen en de losse onderdelen
    011-laatste-beheerder.sql een groep kan zijn laatste beheerder niet
                              kwijtraken
    012-onderdelen.sql        eisen kunnen losse onderdelen hebben (knopen,
                              commando's, termen)
    013-beheer.sql            iemand uit de groep halen, en de catalogus
                              bewerkbaar voor beheerders
    014-speltakken.sql        leden aan speltakken koppelen, speltak op een
                              uitnodigingscode
    015-leden-zonder-account.sql
                              vaarders zonder eigen login
    016-bakken-en-standen.sql bakken, en aftekenen in drie standen
    017-account-verwijderen.sql
                              je eigen account verwijderen vanuit de app
    018-eigen-lijsten.sql     eigen eisenlijsten naast de landelijke catalogus;
                              landelijk wordt weer alleen-lezen
    019-examens.sql           examens maken, afnemen met een sessiecode en
                              meekijken; deelnemers hebben geen account
    020-examen-nakijken.sql   na het inleveren zien wat goed en fout was, als
                              de sessie dat toestaat
    021-examenvraag-bij-eis.sql
                              een examenvraag mag bij een eis horen, zodat je
                              een examen uit de eisenlijst kunt bouwen
    022-examen-aftekenen.sql  een uitslag per eis bekijken en die eisen
                              overnemen in de vorderingenstaat
    023-examen-afbeeldingen.sql
                              de opslagmap voor plaatjes bij een vraag:
                              iedereen mag lezen, alleen instructeurs uploaden
    024-examen-geslaagd.sql   het deelnemersoverzicht zegt erbij of iemand
                              geslaagd is, met het percentage en de grens
    025-examen-opruimen.sql   gegeven antwoorden van oude examens wissen; de
                              uitslag blijft. Alleen een beheerder
    026-voortgang.sql         de stand van de hele groep in een keer: per lid, en
                              per eis wie hem nog mist. Alleen instructeurs
    027-oud-lid.sql           wie van de groep af is verdwijnt uit het overzicht maar
                              houdt zijn aftekeningen; met een lijst en een knop
                              om die na de beloofde 2 jaar echt op te ruimen
    028-lesmateriaal.sql      lesboeken en naslagkaarten van de groep bij een
                              diploma, in een afgeschermde map. Lezen mag elk lid,
                              uploaden alleen de leiding
    029-aftekenen-met-moment.sql
                              aftekenen met het moment erbij, voor wat op het
                              water gebeurde en pas later verstuurd wordt

`010-eisen.sql` draait **als laatste**, ook al is zijn nummer lager. De catalogus
hangt aan elke schemawijziging die erna genummerd is, dus hij wordt steeds
opnieuw geladen nadat de rest gedraaid heeft. `schema.sql` zet ze al in die
volgorde.

`010-eisen.sql` mag je zo vaak draaien als je wilt: hij werkt bij op `code`, dus
ids blijven gelijk en aftekeningen die er al zijn blijven kloppen. Zie
[docs/EISEN.md](../docs/EISEN.md).

## 3. Inloggen met e-mail aanzetten, en waar de mail vandaan komt

**Authentication → Providers → Email**: aan. **Confirm email** mag uit terwijl je
zelf test — dan hoef je niet op een mailtje te wachten — maar aan voordat je de
app uitdeelt. De app en de beheerpagina vangen allebei op dat er na het
registreren nog geen sessie is en zeggen dan dat er een mail onderweg is.

### Waar de link uit de mail heen mag

**Authentication → URL Configuration → Redirect URLs.** Wat daar niet in staat,
weigert Supabase, en de gebruiker komt na het klikken niet terug in de app. Er
moeten er twee in:

    vinkje://*
    aftekenboek://*

De app registreert beide schema's, in die volgorde, en `Linking.createURL` pakt
de eerste — dus nieuwe mails wijzen naar `vinkje://`. Het oude schema blijft
staan omdat er mails in postvakken liggen die er nog naar wijzen; haal je het uit
de lijst, dan werken die links niet meer. Ze zijn allebei nodig.

Dat de app een schema registreert gebeurt bij een **native build**, niet bij een
OTA-update. Maar de volgorde komt uit `Constants.expoConfig`, en die zit wél in
een OTA-update. Een update kan dus het schema van een mail omzetten naar iets wat
de geïnstalleerde app niet kent. Daarom hangt de volgorde aan het versienummer:
`runtimeVersion` volgt de appVersion, dus een update voor 0.3.0 bereikt een
0.2.0-app niet. Verander het schema nooit zonder de versie mee te nemen.

Hier staat ook de **Site URL**, en die moet de map van de beheerpagina noemen
(nu `/cwo-beheer/`). Verhuist die map, dan hier mee: anders vallen de
bevestigingslinks uit de beheerpagina terug op een 404.

### Eigen SMTP

De ingebouwde mailer van Supabase heeft een lage limiet, een handvol per uur. Dat
merk je pas als je op één ochtend een stuk of acht instructeurs aanmeldt en de
laatsten niets krijgen — het lijkt dan alsof de registratie stuk is, terwijl je
gewoon tegen de limiet aanloopt.

Scouting JWF draait op Google Workspace, en dat scheelt werk: het SPF-record van
het domein bevat `include:_spf.google.com` en DKIM staat aan, dus mail die via
Google verstuurd wordt komt meteen goed aan. Geen DNS-wijziging nodig.

**Authentication → Emails → SMTP Settings**:

    Host            smtp.gmail.com
    Port            465
    Username        het volledige adres waarvandaan verstuurd wordt
    Password        een Google app-wachtwoord van zestien tekens
    Sender email    hetzelfde adres als de username
    Sender name     Scouting JWF Vinkje

Drie dingen die hier misgaan:

- **Het wachtwoord moet een app-wachtwoord zijn.** Het gewone accountwachtwoord
  wordt geweigerd. Er is geen knop in de admin-console om dit aan te zetten: de
  oude "less secure apps"-instelling is verwijderd. Een app-wachtwoord kan pas
  bestaan als tweestapsverificatie aanstaat op het account zelf, via
  <https://myaccount.google.com> → Beveiliging, niet via de admin-console.
- **Het afzenderadres moet bij het inlogaccount horen.** Een ander adres mag
  alleen als het in Gmail als alias is toegevoegd onder "E-mail verzenden als".
- Werkt het niet, kijk dan in **Logs → Auth**. De SMTP-fout staat daar letterlijk;
  `535 Authentication failed` betekent een verkeerd app-wachtwoord.

Zijn app-wachtwoorden in de tenant uitgeschakeld, dan is Google geen route en ga
je naar een verzenddienst. Resend heeft een koppeling die deze instellingen
invult, maar vraagt twee DNS-records op het domein. Vul de bestaande SPF-regel
dan aan, vervang hem niet — zonder `include:_spf.google.com` breekt de gewone
mail van de groep.

## 4. De app eraan koppelen

Zet in een `.env` in de projectmap (kopieer `.env.example`, niet hernoemen —
dat voorbeeld wil je houden):

    EXPO_PUBLIC_SUPABASE_URL=https://xxxxxxxx.supabase.co
    EXPO_PUBLIC_SUPABASE_PUBLISHABLE_KEY=sb_publishable_...

Allebei staan ze in het dashboard onder **Project Settings**: de URL bij
**Data API**, de sleutel bij **API Keys**. Neem de *publishable* sleutel, niet de
*secret* — die laatste omzeilt alle policies en hoort nooit in een app die je
uitdeelt. Oudere projecten hebben in plaats daarvan een JWT-`anon`-sleutel; die
mag ook, onder de naam `EXPO_PUBLIC_SUPABASE_ANON_KEY`.

`.env` staat in `.gitignore`. Start `npx expo start` opnieuw na het wijzigen —
Expo leest deze bij het bundelen, niet tijdens het draaien.

## 5. Je groep maken

Maak een account in de app en kies op het welkomstscherm **Een nieuwe groep
beginnen**. Dat roept `create_group()` aan en maakt jou beheerder. Vanuit
Meer → Beheer wijs je instructeurs aan en deel je codes uit.

## De policies testen zonder server

```bash
npm run test:db
```

Draait de migraties tegen een echte Postgres die naar WebAssembly is
gecompileerd (PGlite — geen Docker, geen netwerk, niets te installeren) en
probeert de policies daarna te breken: een lid dat zichzelf wil aftekenen, een
instructeur die op andermans naam tekent, een andere groep die meekijkt, een eis
van het verkeerde diploma.

Dit bestaat omdat RLS-fouten stil zijn. Een verkeerde policy geeft geen foutmelding;
rijen verdwijnen gewoon, of duiken op bij de verkeerde persoon. Draai dit na elke
wijziging in de SQL.

## Afspraken

- Elke schemawijziging komt als een genummerd `0NN-naam.sql` dat jij draait, en
  `schema.sql` wordt bijgewerkt (die is gegenereerd — bewerk de genummerde
  bestanden). Wijzig nooit een bestand dat al gedraaid is, behalve `010-eisen.sql`,
  dat daar juist voor gemaakt is.
- Policies zijn zo geschreven dat iemand alleen bij de eigen groep kan. Wat niet
  in een policy past, is een `security definer`-functie in `003-rpc.sql`, en elk
  van die functies controleert zelf `auth.uid()`. Die controle is het enige
  tussen een beller en de gegevens van een andere groep — haal er geen weg om
  iets te "vereenvoudigen".
