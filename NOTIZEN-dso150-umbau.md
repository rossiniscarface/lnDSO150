# DSO150 mit lnDSO150: Umbau, Messungen und Fundstücke

Arbeitsnotizen vom 5. und 6. November 2026 an einer **JYE Tech DSO Shell
(DSO150)**, Platine `109-15000-00E` von 2017, STM32F103C8T6.

Ziel war zunächst nur alternative Firmware. Daraus wurden der Rotary-Mod,
ein USB-Anschluss, ein DFU-Bootloader, ein eigener DFU-Client und vier
Befunde, die auch für andere interessant sein dürften.

---

## Kurzfassung der Befunde

| | Befund |
|---|---|
| 1 | `USE_ROTARY_FULL_STEP` ist **invertiert**, und der Dateiname lügt mit |
| 2 | `saveCalibrationData()` schreibt die AC-Tabelle in den DC-Speicher |
| 3 | Testsignal „50 kHz" und „100 kHz" sind **2,86 % zu hoch** |
| 4 | `dfu-util 0.11` scheitert reproduzierbar, ein schlanker Client nicht |

---

## 1. Hat der Chip wirklich 128 KB?

Der STM32F103C8T6 ist mit 64 KB spezifiziert, trägt aber meist 128 KB
Zellen. lnDSO150 braucht in der normalen Konfiguration rund 95 KB.

Getestet mit `stm32flash` über den ROM-Bootloader: 64 KB Zufallsmuster nach
`0x08010000` geschrieben, zurückgelesen, verglichen. Dazu die untere Hälfte
vorher und nachher gelesen, um **Adress-Aliasing** auszuschließen — also den
Fall, dass Schreibzugriffe oberhalb 64 KB in Wirklichkeit die Firmware
überschreiben.

```
Schreiben akzeptiert : ja
Muster identisch     : ja     (sha256 byteweise gleich)
Untere Hälfte verändert (Aliasing): nein
```

Die oberen 64 KB sind real und beschreibbar. Einschränkung: ST testet diese
Zellen nicht. „Funktioniert jetzt" ist nicht dasselbe wie „hält die
Datenerhaltung über Jahre".

Später unabhängig bestätigt: der DFU-Bootloader meldet selbst
`@Internal Flash /0x08000000/8*001Ka,120*001Kg` — 8 + 120 = 128 KB.

### Lesesperre

Die Werksfirmware war mit RDP geschützt, Auslesen also unmöglich. Entsperren
geht nur mit Massenlöschung (`stm32flash -k`), danach ist die Werksfirmware
weg. Zurück kommt man mit den Hex-Dateien von JYE Tech.

Praktischer Hinweis: die offizielle **-064 startet nach einer Massenlöschung
ohne Codeabfrage**. Bei neueren Versionen ist das offen; den Code gibt JYE
Tech kostenlos heraus.

---

## 2. Der Rotary-Mod und eine invertierte Option

Die Originalverdrahtung legt den Drehgeber auf PB0/PB1 — dieselben Pins wie
der LCD-Datenbus. Die Firmware schaltet sie laufend zwischen Ein- und
Ausgang um, weshalb beim Bildaufbau Drehschritte verlorengehen. Der Mod legt
den Geber auf die freien **PB14/PB15**.

Danach reagierte der Geber nur noch **jedes zweite Mal**. Das Wiki nennt die
Abhilfe knapp: *„USE_ROTARY_FULL_STEP : If the rotary encoder takes 2 steps
to move, rebuild with that enabled"*.

**Die Option ist invertiert**, in beiden CMakeLists gleichermaßen:

```cmake
IF(NOT USE_ROTARY_FULL_STEP)
    TARGET_COMPILE_DEFINITIONS(sourceLib PRIVATE "-DDSO_ROTARY_FULL_STEP")
ENDIF()
```

| CMake-Option | Define gesetzt | Tabelle in `dso_control_internal.h` | Dateiname sagt |
|---|---|---|---|
| `OFF` (Vorgabe) | **ja** | `#ifdef`-Zweig = **Vollschritt** | `_hstep` |
| `ON` | **nein** | `#else`-Zweig = **Halbschritt** | `_fstep` |

Define **und** Dateiname sagen jeweils das Gegenteil. Wer nach `_hstep` im
Binärnamen geht, liegt falsch.

Nachgewiesen über `compile_commands.json`: altes Image 55 Vorkommen von
`-DDSO_ROTARY_FULL_STEP`, neues Image 0. Mit `-DUSE_ROTARY_FULL_STEP=ON`
reagiert der Geber auf jede Raste.

> Beim Neubau unbedingt ein **frisches Build-Verzeichnis** nehmen. CMake hält
> die Option im Cache, sonst ändert sich nichts.

---

## 3. USB nachrüsten

Auf der Platine liegen **TP2 (D−)** und **TP3 (D+)** als Durchkontaktierungen,
direkt an PA11/PA12, ohne Serienwiderstände und ohne Pull-up. R26 bis R28
sind 10 K und gehören zum LCD-Teil, nicht hierher.

Nötig sind also:

- je ein **Serienwiderstand** in D− und D+ (22 Ω vorgesehen, 2 × 10 Ω in
  Reihe tun es auch)
- ein **Pull-up von D+ nach 3,3 V**, 1,5 kΩ vorgesehen. 1 kΩ ergibt im
  Leerlauf 3,3 V × 15 k/(15 k+1 k) = **3,09 V** und liegt damit im
  geforderten Fenster 2,7 bis 3,6 V.

Der Pull-up gehört laut Schaltplan auf die **Buchsenseite** des
Serienwiderstands. Bei 10 Ω beträgt der Unterschied zur anderen Platzierung
rund **2 mV** — in der Praxis belanglos, man darf also dort löten, wo es
mechanisch besser geht.

Als Buchse diente der ohnehin verbaute USB-Port eines
**JYE140-Aufwärtswandlers** (5 → 9 V), dessen D−/D+ auf der Platine an
Nicht-angeschlossen-Kreuzen enden.

### Ergebnis

```
manufacturer  mean00
product       lnDSO150
speed         12          <- Full Speed, der Pull-up greift
Interfaces    CDC-ACM (/dev/ttyACM0) + DFU-Runtime
```

Beim ersten Einstecken brauchte der Kernel drei Anläufe (`-32`, `-32`, `-71`).
Vermutlich Einschaltstrom: das Gerät hängt über genau dieses VBUS am
Aufwärtswandler, bootet also während der Enumeration. Es meldet dabei
100 mA an, zieht real deutlich mehr — ein **aktiver Hub** ist zu empfehlen.

### Steuerung über USB

Im Repo liegt unter `python_usb_control/` eine Host-Bibliothek (braucht
`pyserial` und `protobuf`) sowie eine PyQt-Oberfläche. Der Handschlag dauert
1 ms, ein Screen-Dump von 240 Byte kommt in 32 bis 64 ms.

---

## 4. Bootloader und DFU

Für DFU braucht man **zwei** Images:

| Adresse | Datei |
|---|---|
| `0x08000000` | `bootloader_2.2.bin`, 8100 B |
| `0x08002000` | die Anwendung |

Der Bootloader ist ein eigenes Projekt
(`mean00/lnDSO-stm32-dfu-bootloader`, eine Anpassung von davidgf.net), hat
dort aber **keine Releases**. Das fertige Binary hängt an den Releases von
**lnDSO150 selbst**, Version v2.2. Die Release-Notes von v2.3 sagen
ausdrücklich, man könne den Bootloader eines früheren Release nehmen.

### Was der Bootloader prüft

`src/main.cpp` liest am Anfang der Anwendung vier Werte:

```c
uint32_t sig       = base_addr[0];   // Stackpointer, muss 0x200xxxxx sein
uint32_t imageSize = base_addr[2];
uint32_t checksum  = base_addr[3];
XXH32(&base_addr[4], imageSize, 0x100)
```

Genau dieses Format schreibt `lnDsoChecksum.py` — auch beim Standalone-Build.
**Flashbar ist die `.ck_bin`, nicht die `.elf.bin`.**

### Nützliche Eigenschaften

- Die ersten 8 KB sind im Deskriptor als `a` deklariert, also **nur lesbar**.
  Per DFU kann man den Bootloader nicht überschreiben und sich nicht
  aussperren.
- Ein ungültiges Image führt automatisch in den DFU-Modus.
- In den DFU-Modus kommt man außerdem mit der **OK-Taste beim Einschalten**
  (der Bootloader liest **PB7**) oder über den Detach-Befehl von dfu-util.
- Die Schutz-Flags sind **aus**. Der Config-String im Release-Binary lautet
  `Bootloader config: FW-CRC`. Kein `RDO/DBG` heißt: dieser Bootloader setzt
  RDP **nicht** wieder und schaltet JTAG **nicht** ab.

### JP1 und JP2

Für den **ROM**-Bootloader (UART, `stm32flash`) braucht man weiterhin die
Lötbrücken — der lnDSO-Bootloader kann nur USB, und der STM32F103 hat kein
USB-DFU im ROM.

| Brücke | Verbindet | Ohne Brücke |
|---|---|---|
| **JP1** | BOOT0 (Pin 44) an **+3,3 V** | R1 1 kΩ zieht BOOT0 auf Masse |
| **JP2** | PB2 / BOOT1 (Pin 20) an **Masse** | PB2 offen, kein Pulldown |

Beide Pegel werden **nur im Moment des Resets** gelesen. Kurz überbrücken
beim Einschalten genügt, löten ist nicht nötig; sobald `stm32flash` den Chip
gefunden hat, darf man loslassen. `TP1` ist `nRST`, damit kann man resetten,
ohne die Stromversorgung zu trennen.

> **JP2 muss im Betrieb offen sein.** PB2 ist die LCD-Datenleitung DB2.

---

## 5. dfu-util 0.11 scheitert — ein schlanker Client nicht

Vier Versuche, das 95-KB-Image mit
`dfu-util -d 1d50:6021 -s 0x08002000:leave -D …` zu schreiben, brachen an
**jeweils anderer Stelle** ab:

| Versuch | Lage | Abbruch |
|---|---|---|
| 1 | direkt am Port, per Detach gestartet | Erase 100 %, dann `SET_ADDRESS` bei 4 % Download |
| 2 | direkt, nach Fehlschlag | `ERASE_PAGE` bei 60 % |
| 3 | über aktiven Hub | `ERASE_PAGE` bei 6 % |
| 4 | frisch gestarteter Bootloader | `ERASE_PAGE` bei 0 % |

Ausgeschlossen: **Watchdog** (Config-String zeigt nur `FW-CRC`),
**Spannungseinbruch** (`devnum` blieb über alle Abbrüche konstant, das Gerät
hat sich nie neu angemeldet), **Hub oder Kabel** (beide Wege scheitern).

### Die Ursache steckt in dfu-util

Zwei Dinge, die der Bootloader gar nicht braucht:

```c
/* src/dfu.cpp */
baseaddr = prog.addr + ((prog.blocknum - 2) * DFU_TRANSFER_SIZE);
if (!_flash_page_is_erased(baseaddr))
    _flash_erase_page(baseaddr);        // löscht selbst!
_flash_program_buffer(baseaddr, (uint16_t*)prog.buf, prog.len);
```

1. **Der Schreibpfad löscht die Seite selbst.** Die vorgelagerte
   Löschphase mit `ERASE_PAGE` ist überflüssig — und dort passierten drei
   von vier Abbrüchen.
2. **Fortlaufende Blocknummern genügen.** Der Bootloader rechnet die
   Zieladresse aus `blocknum`. dfu-util schickt stattdessen vor *jedem*
   Block ein neues `SET_ADDRESS`; der Kommentar im eigenen Quelltext lautet
   „highly inefficient, but ...".

Zusammen über 450 Control-Transfers statt der nötigen ~190.

### Ergebnis

Ein minimaler Client (`dfu-schlank.py`, braucht `pyusb`), der die Adresse
einmal setzt und dann durchschreibt:

```
Schreiben [#########################] 100%  Block 93/93
Fertig in 10.1s, 0 Wiederholungen noetig.
```

**95 KB in 10,1 Sekunden, kein einziger Fehler.** Die handverdrahtete
USB-Strecke war nie das Problem.

Nebenbei: DFU schreibt **gezielt** nur die beteiligten Seiten. Die
Kalibrierdaten liegen bei `0x0801F800`, also 25 KB oberhalb des Images, und
überleben ein Update. Ein `stm32flash -o` (Massenlöschung) nimmt sie dagegen
mit.

---

## 6. Fehler in `saveCalibrationData()`

`src/dso_calibrate.cpp`, Zeile 130 und 138:

```c
uint16_t *ac = DSOInputGain::getCalibrationTable(1);   // -> AC-Slot   richtig
...
uint16_t *dc = DSOInputGain::getCalibrationTable(1);   // -> DC-Slot   FALSCH
```

Die DC-Kalibrierung wird mit AC-Werten überschrieben. An den übrigen vier
Stellen (67, 81, 164, 165) steht die `0` korrekt.

Der Fix ist ein Zeichen: `getCalibrationTable(1)` → `getCalibrationTable(0)`
in Zeile 138. In diesem Zweig angewandt.

Zweimal Kalibrieren hilft dagegen **nicht** — der Speichervorgang ist jedes
Mal gleich falsch. Nach dem Patch muss man **einmal** neu kalibrieren, damit
echte DC-Werte in den Speicher kommen; der Patch repariert nur das
Speichern, nicht das bereits Gespeicherte.

---

## 7. Das Testsignal ist 2,86 % zu schnell

`lnArduino/mcus/common_bluepill/lnTimer.cpp`:

```c
#define PMW_RANGE 100
int divider = (2 * clock + (fqInHz * PMW_RANGE / 2)) / (fqInHz * PMW_RANGE);
t->PSC = divider - 1;
t->CAR = PMW_RANGE - 1;
```

Erzeugbar ist nur `72 MHz / (100 × N)`. Für 50 kHz bräuchte man N = 14,4.

| Menü | Teiler | tatsächlich | Abweichung |
|---|---|---|---|
| 1 kHz | 720 | 1000,0 Hz | 0,00 % |
| 10 kHz | 72 | 10000,0 Hz | 0,00 % |
| 20 kHz | 36 | 20000,0 Hz | 0,00 % |
| **50 kHz** | **14** | **51428,6 Hz** | **+2,86 %** |
| **100 kHz** | **7** | **102857,1 Hz** | **+2,86 %** |

Über USB nachgemessen, vier Zeitbasen: 51425 / 51438 / 51439 / 51416 Hz.
Vorhersage 51428,6 Hz — Übereinstimmung auf **0,003 %**.

Gegenprobe bei 10 kHz: gemessen 10000 Hz, Streuung über vier Zeitbasen
0,06 %. Damit ist das Messverfahren absolut geeicht, nicht nur in sich
stimmig.

**Als Zeitbasis-Referenz taugen 1, 10 und 20 kHz. 50 und 100 kHz nicht.**

### Amplitude

Das Testsignal hat eine Umschaltung groß/klein. Klein zieht PA12 über R31
gegen Masse; der Kommentar in `src/dso_test_signal.cpp` rechnet vor:
`3.3 * R31/(R16+R31) = ~100 mV`. Gemessen 118 mV. Nicht mit einem
Kalibrierfehler verwechseln.

---

## 8. Die Frequenzanzeige ist nur eine Schätzung

Bei 51,43 kHz zeigte das Display **56 kHz** (+8,9 %). Bei 10 kHz stimmt sie.

`capture/dso_frequency.cpp` sagt es selbst:

> *„Compute # of samples between two local maximum, that gives ~ the
> frequency. This is not very accurate"*

Schwellen bei 1/3 und 2/3 zwischen Min und Max, Hysterese, höchstens 15
Ereignisse, **ganze Abtastwerte ohne Interpolation**. Bei 38,9 Werten pro
Periode ist ein einzelner Fehltritt schon 2,6 %.

Dazu kommt die Bandbreite: bei 51 kHz ist man bei einem Viertel der
spezifizierten 200 kHz. Die Flanken brauchen dann rund 21 % der Periode, das
Rechteck wird sichtbar zum Trapez — gemessene Anstiegszeit 1,79 µs, was
rechnerisch 196 kHz entspricht. Das Gerät hält also seine Spezifikation ein,
nur die Anzeige wird in diesem Bereich unzuverlässig.

---

## 9. Messen über USB: die Umrechnung

Aus `src/dso_display.h`:

```c
#define DSO_WAVEFORM_WIDTH  240  // 20 pixel / unit, 12 square => 240 pixel
#define DSO_WAVEFORM_HEIGHT 200  // 10 square : 200 pixel
```

**20 Pixel pro Division in beiden Achsen.** Daraus:

- Abtastintervall = (µs pro Division) / 20
- Spannung = Pixel / 20 × (Volt pro Division)

Der Screen-Dump liefert 240 Werte, einen je Spalte, y wächst nach unten.
Bestätigt durch die 10-kHz-Messung mit 0,06 % Streuung.

---

## Was schiefging

Der Vollständigkeit halber, weil die Sackgassen Zeit gekostet haben:

- **Vier falsche Hypothesen** zum DFU-Abbruch (Watchdog, Stromversorgung,
  Signalqualität, beschädigter Bootloader-Zustand), bevor der Blick in
  `dfu.cpp` die Antwort lieferte. Lesen hätte früher geholfen als raten.
- Ein Test über zwei Zeitbasen beweist nur **relative** Konsistenz. Ein
  gemeinsamer Skalenfehler bleibt unsichtbar. Erst die 10-kHz-Stufe, bei der
  der PWM-Teiler exakt aufgeht, lieferte einen äußeren Bezugspunkt.
- Ein Aliasing-Test, der eine Zeitbasis unterhalb der Auflösungsgrenze
  einschließt, meldet fälschlich Aliasing.
- Aus komprimierter ASCII-Grafik auf die Kurvenform zu schließen führt in
  die Irre; die Rohwerte sagen etwas anderes.

---

## Beigelegte Werkzeuge

Unter `dso150-umbau/`:

| Datei | Zweck |
|---|---|
| `dfu-schlank.py` | DFU-Client ohne Löschphase und ohne wiederholtes `SET_ADDRESS`. Braucht `pyusb`. Aufruf: `dfu-schlank.py <image.ck_bin>` |
| `70-lndso150-dfu.rules` | udev-Regel, damit `dfu-util` und `dfu-schlank.py` ohne `sudo` arbeiten. Nach `/etc/udev/rules.d/` kopieren, dann `udevadm control --reload-rules && udevadm trigger` |
| `dso150-flash-test-uart.sh` | 128-KB-Nachweis über den ROM-Bootloader, inklusive Aliasing-Kontrolle |
| `dso150-jp1-jp2-markiert.png` | JP1/JP2 im Schaltplan markiert |

---

## Aktueller Stand

```
0x08000000   bootloader_2.2.bin      8.100 B
0x08002000   Anwendung              95.024 B   (Encoder-Halbschritt,
                                                USB-Fix, Kalibrier-Patch)
0x0801F800   Kalibrierdaten          2.048 B
             ─────────────────────────────────
             102,8 KB von 128 KB
```

Updates laufen über USB, ohne Lötkolben:

```
dfu-schlank.py <neues-image.ck_bin>
```
