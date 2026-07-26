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

## Testen zonder scanner

`~/Desktop/foto-plaat.tif` is een bewaarde plaatscan (5104x7062, twee foto's).
Altijd hiermee testen:

    photoscan -i ~/Desktop/foto-plaat.tif -r 600 -n -v      # detectie + timing
    photoscan -i ~/Desktop/foto-plaat.tif -r 600 -o /tmp/t -p t -f png

Verwacht: achtergrond ~87%, drempel 81%, 2 foto's van 102x233 en 103x149 mm.

Verifieer het resultaat numeriek, niet op het oog - meet of de buitenste
pixels achtergrond bevatten. Let op de geometrie: links/rechts is een
verticale strook (`2x100%`), boven/onder een horizontale (`100%x2`). Met
`2x100%` levert `-gravity North` dezelfde strook op als `South` en meet je
de horizontale randen dus niet.

    for g in West East; do
      magick out.png -gravity $g -crop 2x100%+0+0 +repage -colorspace Gray \
        -format "$g %[fx:mean*100]\n" info:
    done
    for g in North South; do
      magick out.png -gravity $g -crop 100%x2+0+0 +repage -colorspace Gray \
        -format "$g %[fx:mean*100]\n" info:
    done

Klepbekleding is ~88%. Fotobeeld zit ruim daaronder (gemeten: 20-65%). Zit
een rand rond de 88%, dan staat er nog achtergrond op.