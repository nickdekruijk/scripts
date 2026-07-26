# photoscan

Scant meerdere foto's tegelijk op een flatbedscanner via SANE en snijdt ze
los op. Bash + ImageMagick, geen dependencies daarbuiten.

## Omgeving

- CanoScan LiDE 200 via SANE genesys-backend (`genesys:libusb:XXX:YYY`)
- macOS op Apple Silicon, ImageMagick 7 Q16-**HDRI**, `Thread: 1`
  (Homebrew bouwt zonder OpenMP - meerdere cores zijn niet beschikbaar)
- Shell-locale is Nederlands

## Gemeten eigenschappen van deze scanner

Niet aannemen, dit is opgemeten aan een echte scan:

- Klepbekleding scant als **88% helderheid**, niet als bijna-wit. Een vaste
  drempel van 92% vindt daardoor nul foto's: alles geldt dan als voorgrond,
  loopt aan elkaar vast tot een blob over de hele plaat, en wordt gefilterd.
  Vandaar dat de drempel uit de hoeken van de scan wordt afgeleid.
- Donkere band langs de glasrand is **niet rondom even breed**: opgemeten
  0,85 mm boven, 0,85 mm links, en nul onder en rechts. Eén `EDGEMM` voor
  alle vier de zijden gooit rechts en onder dus een hele millimeter beeld
  weg dat er wel is. Het script meet de band daarom zelf op, per zijde.
- Volle plaat op 600 dpi kleur duurt ~51 s scannen. Dat domineert de looptijd,
  dus verdere optimalisatie van de ImageMagick-pijplijn levert weinig op.

## Valkuilen - niet terugdraaien

**Locale.** `awk`'s `printf "%.4f"` levert in nl_NL een komma. Beland die in
een ImageMagick-geometrie, dan leest die `12,5000%` als breedte 12% bij
hoogte 5000% en krijg je een masker van 216 megapixel dat minuten kost.
Daarom `export LC_ALL=C` én alle geometrie als hele pixels, nooit als
percentage met decimalen. De maat-controle na het maskeren is het vangnet.

**`-trim` werkt niet.** Op 600 dpi zijn losse stofjes op het glas individueel
zichtbaar. Eén donkere pixel blokkeert de hele rij en alles daarbuiten, dus
`-trim` haalt er letterlijk nul pixels af. Daarom wordt de fotorand bepaald
via een tweede, scherp masker (drempel + `morphology Open`, zonder de blur
die het groepeermasker gebruikt). Op lagere resoluties werkt `-trim` wel,
dus dit reproduceert niet op een verkleinde testscan.

**Kleurnotatie.** `connected-components` meldt wit als `gray(255)`,
`gray(65535)`, `gray(100%)` of `srgb(255,255,255)`, afhankelijk van de build.
Filter op "elk getal > 0", niet op de string "255".

**Marge komt ná de verfijning.** `PADDING` voegt achtergrond toe die de
verfijning net heeft weggehaald. Standaard 0; alleen zinvol met `-N`.

**`-deskew` is hier onbruikbaar - de hoek komt uit een lijnfit.** De
Radon-transform grijpt aan op de langste rechte lijn, en dat is bij een
foto tegen de plaatrand de detectiemarge zelf: die knipt de blob daar
kaarsrecht af. Gemeten op de testplaat meldde `-deskew` -0,31° waar de rand
+0,31° was. Niet alleen de grootte klopte niet maar ook het teken, dus de
foto kwam er twee keer zo scheef uit als hij erin ging: +0,31° werd +0,61°.
Precies de klacht "hij staat een halve graad scheef".

In plaats daarvan wordt per zijde een rechte lijn door de fotorand gefit,
met de afgeknotte zijden overgeslagen. Resultaat op de testplaat: +0,32°
naar +0,02° en +0,27° naar -0,04°.

Drie dingen die daarbij nodig bleken:

- **Isoleren met `keep-top`.** Bounding boxes van schuin liggende foto's
  overlappen: een hoek van foto 2 valt in de box van foto 1, en de randscan
  pakt die hoek dan als rand. Dat gaf +6,8° waar +0,3° hoorde.
- **Uitschieters eruit** tijdens het fitten, anders trekt een stofje of een
  beschadigde hoek de lijn scheef.
- **Randen met te grote spreiding verwerpen.** Loopt er lucht of een wit
  plafond tot in de fotorand, dan valt die rand weg tegen de klep en
  springt de meting alle kanten op. Gemeten mediaan residu: 0,1-0,3 px voor
  een goede rand, 6,8 px voor zo een weggevallen rand. `MAXRESID` scheidt
  die twee ruim.

Het masker op 150 dpi is nauwkeurig genoeg: gemeten 0,168° tegen 0,196° op
volle resolutie, een verschil van 1,7 px over een hele fotohoogte. Een
extra threshold-pass op 600 dpi zou 2,5 s kosten voor niets.

De tekenconventie is opgemeten aan een blok dat met `-rotate +0,5` gedraaid
is: een verticale rand geeft dan `dx/dy = -0,5`, een horizontale
`dy/dx = +0,5`. Het teken van de verticale randen moet dus om. Niet op
gevoel aanpassen - dit was juist de bug.

Na het draaien moet er opnieuw gesneden worden, en dat gaat op de formule,
niet met `-trim` (zie hierboven). Voor een foto w x h onder hoek t is de
bounding box `W = w·cos t + h·sin t` bij `H = w·sin t + h·cos t`; dat
stelsel omgekeerd geeft de strakke maat terug. `DESKEWPAD` vangt de
afrondingsrest op - met 0 px blijft er rotatie-achtergrond staan, met 2 px
niet meer.

**Rotatievulling is helderder dan de klep.** De klep meet 88%, maar de
achtergrond die `-rotate` bijvult is 100% wit. Een randgemiddelde ziet dat
verschil nauwelijks; `%[fx:maxima]` over een hoekblokje wel. Verifieer
rechtgetrokken uitsnedes dus op de hoeken, niet alleen op de randen.

**Contrast rekt de L van Lab, niet R, G en B apart.** `-contrast-stretch`
werkt standaard per kanaal, en dan verschuift de kleurbalans: op de
testscan liep de afstand tussen het rode en het blauwe gemiddelde van 4,7
naar 6,9, terwijl via Lab 4,6 bleef. Gevraagd was contrast, geen
kleurcorrectie. `-normalize` en `-auto-level` hebben hetzelfde bezwaar.

De volgorde is niet vrij: contrast moet ná het rechttrekken en snijden.
De vulling die `-rotate` bijzet is 100% wit en zou anders het witpunt
bepalen, waardoor de stretch niets meer doet.

Een sigmoïdale curve er bovenop (`-sigmoidal-contrast 2x50%`) is te veel -
de schaduwen lopen dicht. `CLIP=0.3` levert vol bereik met sd van 19-21
naar 28-30.

**EDGEMM geldt voor de detectie, de gemeten band voor het snijden.** Die
marge is onmisbaar in het masker: zonder (`-e 0`) telt de donkere glasrand
als voorgrond, verbindt hij alle foto's tot één blob en vindt het script er
op de testplaat nog maar één in plaats van drie. Maar bij het uitsnijden
moet dezelfde marge er juist niet af, want daar staat gewoon beeld. Foto's
liggen bewust tegen de rand - dat is de enige manier om ze recht en passend
neer te leggen - dus dit raakt vrijwel elke scan.

Het opmeten gebeurt per rij, op de plekken waar de klep zichtbaar is, en
daarvan de mediaan. Twee dingen die niet werken: het maximum per rij (één
lichte pixel in een verder donkere rij verpest het al - alle rijen kwamen
op 80% uit), en `asort` om de mediaan te vinden (dat is gawk, macOS heeft
het niet; een frequentietabel over de dieptes doet hetzelfde). Uitlezen
gaat via ASCII-PGM (`-compress none pgm:-`), want `txt:` schrijft de kleur
per build anders op - zie de kleurnotatie-valkuil hierboven.

Ziet minder dan 5% van de rand klep, dan is die zijde bedekt en valt de
meting terug op `EDGEMM`.

**Kwartslagen kan het script niet raden.** Zonder EXIF (SANE zet
`Orientation: TopLeft`) en zonder inhoudsherkenning valt 90/180/270 niet af
te leiden. Aan de bounding box ook niet: liggende foto's die verticaal op de
plaat liggen leveren een staande uitsnede op, dus een regel als "breder dan
hoog → draaien" doet precies niets. Daarom `-R` als expliciete keuze.

## Testen zonder scanner

`~/Desktop/foto-plaat.tif` is een bewaarde plaatscan (5104x7062). Altijd
hiermee testen:

    photoscan -i ~/Desktop/foto-plaat.tif -r 600 -n -v      # detectie + timing
    photoscan -i ~/Desktop/foto-plaat.tif -r 600 -o /tmp/t -p t -f png

Gaat een uitsnede mis, schrijf dan de maskers weg met `-M masker.png`. Je
krijgt het groepeermasker (wat als foto telt) en het scherpe masker (waar
de randen liggen). Daar is meestal in één oogopslag te zien wat er speelt.

**`foto-plaat.tif` wordt overschreven zodra er opnieuw gescand wordt.** Dat
is al twee keer gebeurd midden in het uitzoeken, en juist de lastige plaat -
drie foto's strak tegen de randen - was daardoor weg. Wat over de scanner
zelf gemeten is blijft gelden; de verwachte uitvoer hierboven hoort bij de
scan die er op dat moment lag. Bewaar een plaat die een probleem laat zien
onder een eigen naam: `-k lastige-plaat.tif`.

Die plaat is wel te herbouwen uit de uitsnedes, en dat is een bruikbare
fixture: foto's tegen alle randen, overlappende bounding boxes, glasband
boven en links. De hoeken worden er expres in gedraaid, dus je kunt meteen
nameten of de deskew ze terugvindt (+0,30/+0,28/-0,12 erin, +0,32/+0,38/
-0,13 eruit):

    magick -size 5104x7062 xc:'rgb(227,227,227)' -colorspace sRGB \
      \( foto-01.jpg -background 'rgb(227,227,227)' -rotate 0.30 \) -geometry +10+22 -composite \
      \( foto-02.jpg -background 'rgb(227,227,227)' -rotate 0.28 \) -geometry +1670+2420 -composite \
      \( foto-03.jpg -background 'rgb(227,227,227)' -rotate -0.12 \) -geometry +10+4890 -composite \
      -fill 'rgb(43,43,43)' -draw 'rectangle 0,0 5103,13' -draw 'rectangle 0,0 11,7061' \
      -depth 8 herbouw.tif

De glasband moet smal genoeg blijven om binnen `EDGE` te vallen: op 600 dpi
is 22 px na het schalen naar 150 dpi net te breed, en dan overleeft er een
restje de `-shave`. Dat verbindt alle foto's tot één blob over de volle
plaatbreedte. 13 px werkt. Even krap zetten in de hoogte werkt ook niet:
onder de ~40 px tussenruimte overbrugt de blur van het groepeermasker het
gat en lopen twee foto's samen.

Voor logica die niet van de scaninhoud afhangt (nummering, optie-parsing)
volstaat een synthetische plaat, die scant in een fractie van de tijd:

    magick -size 1276x1766 xc:'gray(88%)' \
      -fill 'gray(30%)' -draw 'rectangle 100,100 700,900' \
      -fill 'gray(25%)' -draw 'rectangle 800,150 1150,700' \
      -density 150 nep.tif
    photoscan -i nep.tif -r 150 -o /tmp/t -p t

Verifieer het resultaat numeriek, niet op het oog. Twee metingen, want ze
vangen verschillende fouten:

**Randen** - staat er nog klepbekleding op? Let op de geometrie: links/rechts
is een verticale strook (`3x100%`), boven/onder een horizontale (`100%x3`).
Met `3x100%` levert `-gravity North` dezelfde strook op als `South` en meet
je de horizontale randen dus niet.

    for g in West East; do
      magick out.png -gravity $g -crop 3x100%+0+0 +repage -colorspace Gray \
        -format "$g %[fx:mean*100]\n" info:
    done
    for g in North South; do
      magick out.png -gravity $g -crop 100%x3+0+0 +repage -colorspace Gray \
        -format "$g %[fx:mean*100]\n" info:
    done

Klepbekleding is ~88%. Fotobeeld zit ruim daaronder (gemeten: 20-58%). Zit
een rand rond de 88%, dan staat er nog achtergrond op.

**Hoeken** - staat er nog rotatievulling op? Die is 100% wit, dus een maximum
per hoekblokje verraadt hem:

    for g in NorthWest NorthEast SouthWest SouthEast; do
      magick out.png -gravity $g -crop 40x40+0+0 +repage -colorspace Gray \
        -format "$g %[fx:maxima*100]\n" info:
    done

Gemeten op een goede uitsnede: 83-93%. De 93% is een lichte plek in de foto
zelf, die zit er ook zonder rechttrekken in. Een 100 is altijd fout.

Let op de volgorde: dit geldt voor uitsnedes zonder `-c`. Mét `-c` haalt het
oprekken de hoeken alsnog naar 100 en zegt de meting niets meer. Controleer
het snijwerk dus altijd zonder `-c`.

**Contrast** - deed `-c` wat het moest? Spreiding en kleurbalans:

    magick out.png -colorspace Gray \
      -format 'sd=%[fx:standard_deviation*100]\n' info:

Zonder `-c` 19-21, met `-c` 28-30, en het bereik loopt dan van 0 tot 100.