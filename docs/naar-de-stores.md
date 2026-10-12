# Vinkje 1.0.0 naar de stores

Afvinklijst voor de eerste publieke release. Opgesteld 2026-10-12.

De volgorde is niet willekeurig: wat bovenaan staat houdt de rest tegen. Bouw
niet voordat het offline werken getest is, en stuur niet in voordat er een
testaccount klaarstaat — dan loop je een reviewronde van een week mis om iets
wat je in tien minuten had kunnen regelen.

Wie wat doet staat erbij. **J** is Jaimy, **C** is Claude.

---

## Eerst: is 1.0.0 klaar om te bouwen?

- [x] **J** Het offline werken is getest op **beide** telefoons: klaarzetten op
      wifi, vliegtuigstand, een eis openen per bak, aftekenen, verbinding terug,
      aftekening komt aan.
- [x] **J** De beheerpagina is nagelopen met echte gegevens: Voortgang, Examens,
      Diploma's en eisen, Lesmateriaal.
- [x] **C** `npm run test:db`, `npm run test:netwerk`, `npm run typecheck` en
      beide bundels (`expo export`) groen.

Pas als dit staat heeft bouwen zin: een build duurt een uur en een afgekeurde
inzending kost een week.

## De build

- [x] **C** Versie op **1.0.0** in `app.json` en `package.json`.
- [x] **C** Android 1.0.0 gebouwd (build 07561cde).
- [x] **C** iOS 1.0.0 gebouwd (build 52dafde8) en geüpload naar App Store
      Connect. Dat zet hem klaar; het start de review niet.
- [ ] **J** De Android-bundel met de hand uploaden naar de **productie**-track
      (niet de closed test). Er is geen service-accountsleutel, dus `eas submit`
      kan dit niet doen.
- [x] **C** De Android-build krijgt automatisch een hoger versionCode dan 4.

Let op: `runtimeVersion` volgt de appVersion, dus 1.0.0 krijgt een eigen
OTA-lijn. Je huidige testers zitten op 0.3.0 en krijgen die updates niet meer —
die moeten de nieuwe build installeren.

## Het testaccount — dit is de valkuil

Vinkje begint met een inlogscherm, dus een beoordelaar komt er niet in zonder
account. Dat is bij Apple de meest voorkomende afwijzingsgrond (richtlijn 2.1)
en Google vraagt hetzelfde.

- [x] **J** Een apart account maken, bijvoorbeeld `review@scoutingjwf.nl`, en
      het **e-mailadres bevestigen** — "Confirm email" staat aan, dus een
      onbevestigd account kan niet inloggen.
- [x] **J** De demogroep "Scouting De Waterlanders" bestond al van de
      screenshots. Het reviewaccount is er met een uitnodigingscode bij gekomen,
      zodat `demo-groep.sql` niet opnieuw hoefde te draaien — dat zou de groep
      hebben weggegooid en de screenshots ongeldig gemaakt.
- [ ] **J** Zelf één keer inloggen met dat account om te zien dat het werkt.
- [ ] **J** De gegevens invullen bij **App Review Information** (Apple) en
      **App access** (Google).

**Zet de beoordelaar niet in de echte groep.** Dan kijkt een vreemde naar namen
en vorderingen van jullie jeugd. Daar is die demogroep voor.

Laat de demogroep staan zolang de review loopt. Daarna opruimen met
`supabase/demo/demo-opruimen.sql`.

## Materiaal voor de winkelpagina

- [ ] **J** Listingtekst plakken uit [play-store.md](play-store.md): naam,
      korte omschrijving, volledige omschrijving. Platte tekst, geen opmaak.
- [ ] **J** Naam **Vinkje** in beide consoles.
- [ ] **J** Feature graphic (`assets/store/feature-graphic.png`) in Play.
- [x] Android-screenshots in `store/screenshots/out/android/`. Van 21 september,
      uit de demogroep, lichte modus. Van die zes schermen is in 1.0.0 niets
      veranderd, dus ze kloppen nog.
- [x] **iOS-screenshots klaar** in `store/screenshots/out/iphone/`, zes stuks op
      1320x2868, uit de demogroep en in donkere modus.
- [x] **Besloten: geen iPad.** `supportsTablet` staat op `false`, dus Apple
      vraagt geen iPad-screenshots. De app is nog steeds op een iPad te
      installeren en draait daar in iPhone-formaat. Later alsnog aanzetten kan,
      maar vraagt een nieuwe build én een set screenshots — en dan wil ik de
      schermen eerst op dat formaat zien, want daar zijn ze nooit op getest.

Maak die screenshots met de **demogroep**, om dezelfde reden als hierboven.

## De formulieren

Geen van deze kan Claude invullen, en zonder deze kun je niet insturen.

### Apple

- [ ] App Privacy — welke gegevens de app verzamelt en waarvoor
- [ ] Leeftijdsclassificatie
- [ ] Categorie
- [ ] Exportregels: `usesNonExemptEncryption` staat al op `false` in `app.json`

### Google

- [ ] Data Safety
- [ ] Contentclassificatie
- [ ] Doelgroep en inhoud — **let op, hier zit een strik:** zeg je dat de app
      (mede) voor kinderen onder de 13 is, dan geldt het Families-beleid met
      extra eisen. Vinkje wordt gebruikt dóór jeugd, dus lees die vraag goed.
- [ ] Verklaring over advertenties: die zijn er niet

### Allebei

- [ ] Privacybeleid-URL: <https://scoutingjwf.nl/privacybeleid-aftekenboek/>
- [ ] Route om je account te laten verwijderen. In de app kan het al
      (Meer › Mijn gegevens › Account verwijderen) en dat is wat Apple eist;
      Google wil daarnaast een webadres. Het privacybeleid beschrijft beide —
      verwijs daarnaar.

## Buiten de winkels, maar vóór je publiek gaat

- [ ] **J** **Back-ups van Supabase.** Zodra dit productie is staan er
      vorderingen van echte kinderen in. Kijk wat jullie plan aan back-ups
      geeft; op het gratis plan is dat mager en pauzeert een project bovendien
      bij inactiviteit.
- [ ] **J** **SMTP-afzendernaam** op "Scouting JWF Vinkje". Een bevestigingsmail
      van "Supabase Auth" aan een ouder is niet wat je wil.
- [ ] **J** **De lesboeken van Sint Maarten Hoofddorp.** Staat die toestemming
      er nog niet, zorg dan dat er niets van hen in het lesmateriaal staat op
      het moment dat de app publiek wordt. Nu is het een besloten test; straks
      een app in de winkel.
- [ ] **J** Nagaan of de examenvragen van de werkgroep CWO-examenvragen mogen
      blijven staan. Ze zijn alleen zichtbaar voor wie een sessiecode heeft,
      maar de app zelf wordt openbaar.

## Na goedkeuring

- [ ] **J** Demogroep opruimen (`supabase/demo/demo-opruimen.sql`).
- [ ] **J** Het reviewaccount laten staan — bij elke volgende versie vraagt
      Apple er weer om.
- [ ] **C** Een git-tag `v1.0.0` zetten op de commit waar de build van kwam.
