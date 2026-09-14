# Molndelning av Jenga-dashboarden via Google Drive och rclone

## Vad det är

En tvåstegskedja som gör projektets dashboard till något du kan skicka till en annan
människa:

1. **`snapshot.sh`** exporterar dashboarden till *en enda självförsörjande HTML-fil*
   (`jenga.html`) med board-datan inbakad.
2. **`rclone`** laddar upp den filen till Google Drive över ett OAuth-godkännande som
   görs en gång.

Resultatet är en fil som öppnas med dubbelklick i vilken webbläsare som helst — ingen
server, inget Node, ingen databas, ingen checkout av repot.

## Varför det finns

Den vanliga dashboarden (`j.dashboard` utan flaggor) startar en Express-API och en
Vite/React-UI lokalt. Den läser board-filer från disk i realtid, vilket betyder att den
bara fungerar på en maskin som har repot. Det gör den värdelös för de tre vanligaste
delningsfallen:

- visa status för någon som inte är utvecklare
- bifoga ett läge i en rapport eller ett möte
- frysa hur brädet såg ut vid ett visst datum

`--snapshot` löser *portabiliteten* men ger dig bara en fil på din egen disk. `rclone`
löser *transporten*. Behovet av det andra steget är inte självklart förrän man försöker
skicka filen: en 700 KB HTML-fil kan inte skickas genom en chattkoppling, eftersom
innehållet då måste passera tecken för tecken genom modellen. `rclone` flyttar bytes
direkt från disk till Drive utan att de går genom konversationen.

## Hur det fungerar

### Steg 1 — snapshot

`snapshot.sh` gör tre saker i ordning:

1. **Capture** — kör `capture-snapshot.js`, som anropar API:ets tre rutter (`/v1/board`,
   `/v1/history`, `/v1/architecture`) och skriver en JSON-artefakt med
   `{schema_version, captured_at, project_root, routes}`.
2. **Bundle** — `build-snapshot-html.cjs` inlinar den färdigbyggda `dist/` (JS + CSS) i
   en enda `index.html` och bakar in JSON:en i en
   `<script id="jenga-dashboard-data" type="application/json">`-tagg.
3. **Place** — kopierar resultatet till `--out` (standard: `jenga.html` i nuvarande katalog).

Appen ligger inte i repo-roten i det här projektet utan i
`node_modules/@jenga-ai/agent/project/app/` — `resolve-app-dir.sh` hittar den åt dig, så
du behöver inte bry dig. Eftersom `vite` inte är installerat där hoppas ombyggnaden av
`dist/` över och den medskickade builden används direkt. Hela körningen tar ~3 sekunder.

### Steg 2 — rclone

`rclone` är en generell fil-synk mot molnlagring. För Drive håller den en OAuth-token i
`~/.config/rclone/rclone.conf` (rättigheter `600`). Konfigurationen startar en lokal
webbserver på `127.0.0.1:53682`, skickar dig till Googles inloggning, och tar emot
auktoriseringskoden på den lokala adressen. Token förnyas sedan automatiskt via sin
refresh token — du loggar bara in en gång.

## När du ska använda det — och inte

**Använd det när:**

- mottagaren inte har repot, Node, eller en databas
- du vill frysa ett läge (statusmöte, retro, rapportbilaga)
- filen är för stor för att skickas genom en chattkoppling (allt över några tiotal KB)

**Använd det inte när:**

- du vill ha *live*-data — då är `j.dashboard` utan flaggor rätt; en snapshot är död vid
  `captured_at` och blir tyst inaktuell
- mottagaren sitter i samma repo — låt dem köra dashboarden själva
- du är i en fjärrsession utan delat filsystem — använd `snapshot.sh --data-url`, som
  base64-kodar filen till en `data:text/html;base64,...`-URI som klistras direkt i en
  webbläsare (vägrar över ~25 MB)

## Exempel

### Engångsuppsättning av rclone

```bash
brew install rclone
rclone config create gdrive drive scope=drive.file
```

Andra kommandot öppnar en webbläsarflik för Google-inloggning. Verifiera efteråt:

```bash
rclone listremotes          # ska skriva ut: gdrive:
rclone about gdrive:        # ska visa kvot, t.ex. Total: 15 GiB
```

### Exportera och ladda upp

```bash
# 1. Exportera med ett datumstämplat namn
bash .claude/skills/j-dashboard/scripts/snapshot.sh \
  --out "skolkartan-snapshot-$(date +%F).html"

# 2. Ladda upp till en mapp i Drive (copyto = kopiera till exakt denna sökväg)
rclone copyto "skolkartan-snapshot-$(date +%F).html" \
  "gdrive:Skolkartan/snapshots/skolkartan-snapshot-$(date +%F).html" -P

# 3. Verifiera att storleken i Drive matchar den lokala filen
rclone lsjson "gdrive:Skolkartan/snapshots/"
```

`lsjson` returnerar bland annat `ID`, som blir filens Drive-adress:
`https://drive.google.com/file/d/<ID>/view`. Den länken fungerar **bara för dig som
ägare** — uppladdning är inte delning.

### Före och efter: att faktiskt dela filen

Uppladdning ensam ger ingen åtkomst till någon annan. För att skapa en länk som andra
kan öppna:

```bash
# FÖRE: bara ägaren kommer åt filen
rclone lsjson "gdrive:Skolkartan/snapshots/"

# EFTER: skapar en delningslänk (alla med länken får läsbehörighet)
rclone link "gdrive:Skolkartan/snapshots/skolkartan-snapshot-2026-09-13.html"
```

`rclone link` ändrar delningsinställningen på filen i Drive. Kör det bara när du är
införstådd med att vem som helst med länken kan läsa hela board-datan — en snapshot
innehåller allt som API:et exponerar, inte ett filtrerat urval.

### Återkommande delning

Hela kedjan som ett kommando:

```bash
F="skolkartan-snapshot-$(date +%F).html"
bash .claude/skills/j-dashboard/scripts/snapshot.sh --out "$F" \
  && rclone copyto "$F" "gdrive:Skolkartan/snapshots/$F" -P \
  && rm "$F"
```

## Två fallgropar

**Scope.** `scope=drive` ger rclone läs- och skrivåtkomst till *hela* din Drive.
`scope=drive.file` begränsar åtkomsten till filer rclone själv skapat, vilket räcker helt
för snapshot-uppladdning. Välj det snävare om du inte har ett specifikt skäl till motsatsen.
Att byta scope kräver att remoten konfigureras om med en ny inloggning.

**Delat client_id.** rclone varnar vid varje körning att dess gemensamma Google-client_id
pensioneras under 2026 och slutar fungera. När det händer bryts remoten tills du skapar ett
eget client_id (se `https://rclone.org/drive/#making-your-own-client-id`). Varningen är inte
brådskande men den är inte heller brus.
