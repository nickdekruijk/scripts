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

## Twee valkuilen - niet terugdraaien

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

## Testen zonder scanner

`foto-plaat.tif` is een bewaarde plaatscan. Altijd hiermee testen:

    photoscan -i foto-plaat.tif -r 600 -n -v      # detectie + timing
    photoscan -i foto-plaat.tif -r 600 -o /tmp/t -p t

Verifieer het resultaat numeriek, niet op het oog - meet of de buitenste
pixels achtergrond bevatten:

    magick out.png -gravity West -crop 2x100%+0+0 +repage -colorspace Gray \
      -format '%[fx:mean*100]\n' info:

Klepbekleding is ~88%. Fotobeeld zit ruim daaronder. Zit een rand rond de
88%, dan staat er nog achtergrond op.