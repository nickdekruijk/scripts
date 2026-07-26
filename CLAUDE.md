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
- Donkere band langs de glasrand is 0,2 mm (onder) tot 0,7 mm (boven).
  `EDGEMM=1` dekt dat; hoger gooit onnodig beeld weg.
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

**Deskew meet op het masker, niet op de foto.** `-deskew` doet een
Radon-transform; op een binair masker klopt dat, op fotobeeld vindt het
willekeurige hoeken - vandaar dat de oude `-D` zo slecht werkte. Het masker
op 150 dpi is nauwkeurig genoeg: gemeten 0,168° tegen 0,196° op volle
resolutie, een verschil van 1,7 px over een hele fotohoogte. Een extra
threshold-pass op 600 dpi zou 2,5 s kosten voor niets.

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

**Kwartslagen kan het script niet raden.** Zonder EXIF (SANE zet
`Orientation: TopLeft`) en zonder inhoudsherkenning valt 90/180/270 niet af
te leiden. Aan de bounding box ook niet: liggende foto's die verticaal op de
plaat liggen leveren een staande uitsnede op, dus een regel als "breder dan
hoog → draaien" doet precies niets. Daarom `-R` als expliciete keuze.

## Testen zonder scanner

`~/Desktop/foto-plaat.tif` is een bewaarde plaatscan (5104x7062, twee foto's).
Altijd hiermee testen:

    photoscan -i ~/Desktop/foto-plaat.tif -r 600 -n -v      # detectie + timing
    photoscan -i ~/Desktop/foto-plaat.tif -r 600 -o /tmp/t -p t -f png

Verwacht: achtergrond ~87%, drempel 81%, 2 foto's van 102x232 en 102x148 mm,
rechtgetrokken over -0,056° en 0,224°. De foto's liggen op hun kant; `-R 270`
zet ze rechtop.

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