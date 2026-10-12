# Vinkje 1.0.0 naar de stores

Afvinklijst voor de eerste publieke release. Opgesteld 2026-10-12.

De volgorde is niet willekeurig: wat bovenaan staat houdt de rest tegen. Bouw
niet voordat het offline werken getest is, en stuur niet in voordat er een
testaccount klaarstaat — dan loop je een reviewronde van een week mis om iets
wat je in tien minuten had kunnen regelen.

Wie wat doet staat erbij. **J** is Jaimy, **C** is Claude.

---

## Apple vraagt extra uitleg bij een nieuw account

Streepje kreeg die vraag al, dus Vinkje krijgt hem vrijwel zeker ook: zelfde
ontwikkelaarsaccount. Zes vragen, plus een schermopname op een echt toestel.
De antwoorden staan klaar in [app-store.md](app-store.md) onder "De zes vragen
van App Review". Vul ze meteen in het Notes-veld in, dan is de kans groot dat
die ronde je bespaard blijft.

- [x] **J** Schermopname gemaakt op een iPhone. Gaat in App Store Connect naar
      **App Review Information → Attachment** — er is nog geen gespreksdraad om
      in te antwoorden, want er is nog niets ingestuurd.
- [ ] **J** De zes antwoorden in het Notes-veld zetten.
- [ ] **J** **Toestemming regelen voor het materiaal van anderen** — de
      toelichtingen uit de handboeken en de examenvragen. Apple vraagt hier
      letterlijk om (punt 6). Zie app-store.md.
- [x] De formulering "internal tool" is uit de review notes gehaald: dat nodigt
      richtlijn 3.2 uit, en het klopte niet — elke groep kan zich aanmelden.
- [x] De titelkaart wordt niet meer voor Apple gemaakt — richtlijn 2.3.3 wil de
      app in gebruik zien, geen title art. `npm run titelkaart` maakt nu alleen
      de Android-versie, en zonder alfakanaal.

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
      **App access** (Google). De begeleidende tekst staat klaar: de review
      notes in [app-store.md](app-store.md), de instructies voor Google in
      [play-store.md](play-store.md). Allebei in het Engels — de beoordelaar
      leest geen Nederlands. Vul in de Apple-tekst nog je mailadres in.

**Zet de beoordelaar niet in de echte groep.** Dan kijkt een vreemde naar namen
en vorderingen van jullie jeugd. Daar is die demogroep voor.

Laat de demogroep staan zolang de review loopt. Daarna opruimen met
`supabase/demo/demo-opruimen.sql`.

## Materiaal voor de winkelpagina

- [ ] **J** Google: listingtekst uit [play-store.md](play-store.md) — naam,
      korte omschrijving, volledige omschrijving. Platte tekst, geen opmaak.
- [ ] **J** Apple: naam, subtitel, promotionele tekst, trefwoorden en
      beschrijving uit [app-store.md](app-store.md). Andere velden en andere
      limieten dan bij Google, dus het is een eigen tekst.
- [ ] **J** Naam **Vinkje** in beide consoles.
- [ ] **J** Feature graphic (`assets/store/feature-graphic.png`) in Play.
- [x] **J** Apple creative assets (optioneel, sinds oktober 2026). Alle drie in
      `assets/store/`, zonder alfakanaal zoals Apple eist:
      `apple-header-3840x1646.png` voor de kop van de productpagina,
      `apple-zoek-3840x2560.png` voor de zoekresultaten, en
      `apple-universeel-5244x2950.png` als je er één wilt die voor allebei dient
      — die moet dan wel png zijn, jpeg mag daar niet.
      Opnieuw maken: `npm run apple-assets`.
- [x] Android-screenshots in `store/screenshots/out/android/`. Van 21 september,
      uit de demogroep, lichte modus. Van die zes schermen is in 1.0.0 niets
      veranderd, dus ze kloppen nog.
- [x] **iOS-screenshots klaar.** Apple vraagt per formaatslot vaste maten en
      die zijn veranderd; het slot dat App Store Connect nu toont is 6,1/6,3
      inch. `out/iphone/` staat op **1179x2556**, wat in hun lijst staat.
      `out/iphone-69/` heeft dezelfde zes op 1320x2868 voor het 6,9-inch slot,
      uit dezelfde opnamen. Zes stuks, uit de demogroep, donkere modus.
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
- [x] Doelgroep en inhoud: **13 jaar en ouder**. Onderbouwing en de afspraak
      die daarbij hoort staan hieronder onder "Leeftijd en doelgroep".
- [ ] Verklaring over advertenties: die zijn er niet

### Allebei

- [x] Privacybeleid-URL: <https://scoutingjwf.nl/privacybeleid-vinkje/> — in
      beide consoles ingevuld. Let op: het oude adres
      `/privacybeleid-aftekenboek/` verwijst **niet** door en geeft 404 zodra de
      cache verloopt. Staat het ergens anders nog (een mail aan ouders), zet er
      dan een omleiding op.
- [ ] Route om je account te laten verwijderen. In de app kan het al
      (Meer › Mijn gegevens › Account verwijderen) en dat is wat Apple eist;
      Google wil daarnaast een webadres. Het privacybeleid beschrijft beide —
      verwijs daarnaar.

## Wat de app werkelijk verzamelt

Nagekeken op 2026-10-12, zodat de formulieren hierboven op feiten rusten en niet
op aannames.

**De app vraagt nergens toestemming voor.** Geen camera, foto's, locatie,
contacten of meldingen — `app.json` zet geen enkele permissie en in `src/`
staat geen aanroep die erom vraagt. Er zit ook geen analytics-, advertentie- of
trackingbibliotheek in `package.json`.

Wat er wél wordt vastgelegd:

| Wat | Van wie | Waarvoor |
|---|---|---|
| Naam | iedereen in het register | de vaarder herkennen op een aftekenlijst |
| E-mailadres | alleen wie een account heeft | inloggen |
| Gebruikers-id | alleen wie een account heeft | koppelen van account aan persoon |
| Afgetekende eisen, met datum, naam van de instructeur en een notitie | vaarders | de vorderingenstaat zelf |
| Bij een examen: een opgegeven naam en de gegeven antwoorden | deelnemers, ook zonder account | nakijken en de uitslag |

### Apple — App Privacy

Alles hieronder is **linked to the user** en **niet** gebruikt voor tracking.

- Contact Info → **Name** — App Functionality
- Contact Info → **Email Address** — App Functionality
- Identifiers → **User ID** — App Functionality
- User Content → **Other User Content** — App Functionality (de aftekeningen,
  notities en examenantwoorden)
- Alle overige categorieën: **No**
- "Do you or your third-party partners use data for tracking purposes?" → **No**

### Google — Data Safety

De labels in die console schuiven weleens, dus match op de inhoud:

- Naam en e-mailadres: **verzameld**, niet gedeeld, **vereist** (geen keuze),
  voor accountbeheer en app-functionaliteit
- De aftekeningen en examenantwoorden: door de gebruiker gemaakte inhoud,
  verzameld, niet gedeeld
- **Versleuteld onderweg**: ja (alles gaat over HTTPS naar Supabase)
- **Kan een gebruiker verwijdering vragen**: ja — in de app via
  Meer › Mijn gegevens, en per mail; het privacybeleid beschrijft beide
- Niet gedeeld met derden, niet gebruikt voor advertenties

### Leeftijd en doelgroep

Apple: **4+**. Er staat niets in dat om een hogere grens vraagt.

Google's contentclassificatie: alles "nee" — geen geweld, geen aankopen, geen
gebruikersinteractie van het soort waar die vraag op doelt.

**Google's "Doelgroep en inhoud" is de vraag om over na te denken.** Zeg je dat
de app (mede) bedoeld is voor kinderen onder de 13, dan geldt het
Families-beleid met extra eisen en een strengere beoordeling.

De feiten om die keuze op te baseren:

- De app is gebouwd voor instructeurs. Sinds 015 hoeft een vaarder **geen
  account** te hebben: zijn naam staat in het register en een instructeur tekent
  af. Dat is de normale gang van zaken.
- Een lid *kan* een account krijgen, met een uitnodigingscode. Doe je dat bij
  kinderen onder de 13, dan is het antwoord een ander.
- De app bevat wél gegevens *over* kinderen. Dat is iets anders dan de vraag die
  Google hier stelt — dat gaat over wie de app gebruikt — maar het is wel waarom
  het privacybeleid bestaat.

**Besloten op 2026-10-12: 13 jaar en ouder.** Vaarders krijgen geen eigen
account; hun naam staat in het register en een instructeur tekent af. De app
richt zich daarmee op instructeurs, niet op kinderen.

Let op wat dat antwoord wél en niet betekent. 13+ zegt niet dat geen enkele
vaarder ooit een account mag; het zegt dat de app zich niet op kinderen onder de
13 richt. Een vaarder van vijftien met een eigen account past daar binnen.

**De grens die bewaakt moet worden is dus: geen uitnodigingscode aan iemand
onder de 13.** Dat staat niet in de code — het uitnodigingsscherm biedt gewoon
de rol "lid" aan, en dat is met opzet, want een oudere vaarder of een
hulpinstructeur hoort die wel te kunnen krijgen. Het is een afspraak, en de
verklaring aan Google klopt alleen zolang die afspraak staat.

Verandert dat ooit — gaan de jongste vaarders toch inloggen — dan moet de
doelgroep in de Play Console mee, en geldt het Families-beleid alsnog.

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

## Terwijl de review loopt

**Ingestuurd bij Apple op 2026-10-12**, versie 1.0.0.

- **Geen OTA-updates naar het productiekanaal.** Een update die het gedrag
  verandert terwijl Apple naar de binary kijkt, kan uitgelegd worden als het
  omzeilen van de review. Wat af is wacht tot de uitslag er is.
- **De demogroep laten staan.** Opruimen kan pas na goedkeuring, anders logt de
  beoordelaar in op een leeg scherm.
- Komt Apple terug met de zes vragen, dan staan de antwoorden in
  [app-store.md](app-store.md). Antwoorden gaat via de Resolution Center-draad
  die er dan wél is.

## Na goedkeuring

- [ ] **J** Demogroep opruimen (`supabase/demo/demo-opruimen.sql`).
- [ ] **J** Het reviewaccount laten staan — bij elke volgende versie vraagt
      Apple er weer om.
- [x] **C** Git-tag `v1.0.0` staat op 08914ec, de commit waar de iOS-build van kwam.
