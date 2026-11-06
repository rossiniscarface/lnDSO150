#!/usr/bin/env bash
#
# dso150-flash-test-uart.sh
#
# Wie dso150-flash-test.sh, aber ueber den seriellen Bootloader
# statt ueber SWD. Fuer alle, die einen USB-UART-Adapter haben,
# aber keinen ST-Link.
#
# Vorbereitung am Geraet:
#   1. JP1 und JP2 auf der Hauptplatine mit Loetzinn bruecken
#   2. FT232 o.ae. an J5 anschliessen - NUR RX, TX, GND:
#         FT232 TX  ->  J5 Pin 2 (RX1)
#         FT232 RX  ->  J5 Pin 3 (TX1)
#         FT232 GND ->  J5 Pin 4 (GND)
#      J5 Pin 1 (+3.3V) bleibt frei, das Oszilloskop wird wie
#      gewohnt ueber die 9-V-Buchse versorgt.
#   3. Adapter auf 3.3 V Pegel stellen, nicht 5 V.
#   4. Oszilloskop einschalten (bleibt dank JP1/JP2 im Bootloader)
#
# Nach dem Test JP1/JP2 wieder entloeten.
#
# Aufruf:  ./dso150-flash-test-uart.sh [/dev/ttyUSB0] [ausgabeverzeichnis]
#
set -uo pipefail

PORT="${1:-/dev/ttyUSB0}"
OUT="${2:-./flashtest-uart-$(date +%Y%m%d-%H%M%S)}"
BAUD=115200

FLASH_BASE=0x08000000
UPPER_BASE=0x08010000
HALF=65536
STOCK_HEX="./firmware/113-15001-064.hex"

red() { printf '\033[31m%s\033[0m\n' "$*"; }
grn() { printf '\033[32m%s\033[0m\n' "$*"; }
ylw() { printf '\033[33m%s\033[0m\n' "$*"; }
hdr() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

# Erster Aufruf initialisiert den Bootloader, alle weiteren setzen mit -c
# fort: der STM32F1-Bootloader nimmt die INIT-Sequenz nur einmal pro Reset an.
# INITED wird im Hauptteil gesetzt, nicht hier - sf() laeuft teils in einer
# Pipeline und damit in einer Subshell, deren Variablen nicht zurueckwirken.
INITED=0
sf() {
    if [ "$INITED" = "0" ]; then
        stm32flash -b "$BAUD" "$@" "$PORT"
    else
        stm32flash -b "$BAUD" -c "$@" "$PORT"
    fi
}

if ! command -v stm32flash >/dev/null; then
    red "stm32flash fehlt."
    echo "Arch/CachyOS:  paru -S stm32flash    (AUR, Version 0.7-2)"
    exit 1
fi

if [ ! -e "$PORT" ]; then
    red "$PORT existiert nicht."
    echo "Angeschlossene Adapter:"; ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null || echo "  keine"
    exit 1
fi

if [ ! -r "$PORT" ] || [ ! -w "$PORT" ]; then
    ylw "Keine Lese-/Schreibrechte auf $PORT."
    ylw "Meist hilft:  sudo usermod -aG uucp $USER   (danach neu anmelden)"
fi

mkdir -p "$OUT"
hdr "Arbeitsverzeichnis"; echo "$OUT"
echo "Port: $PORT  @ ${BAUD} 8e1"

#--------------------------------------------------------------------
hdr "1/6  Bootloader ansprechen"
#--------------------------------------------------------------------
if ! sf 2>&1 | tee "$OUT/probe.txt"; then
    red "Keine Verbindung zum Bootloader."
    echo "Pruefe der Reihe nach:"
    echo "  - JP1 UND JP2 gebrueckt? (beide, nicht nur eine)"
    echo "  - TX/RX vertauscht? TX des Adapters gehoert an J5 Pin 2."
    echo "  - Adapter auf 3.3 V?"
    echo "  - Nach dem Bruecken einmal aus- und wieder eingeschaltet?"
    exit 1
fi
INITED=1          # ab jetzt mit -c fortsetzen
echo
ylw "Achtung: die Zeile 'Flash: Up to 128KiB' stammt aus der statischen"
ylw "Geraetetabelle von stm32flash, nicht aus deinem Chip. Sie erscheint"
ylw "bei JEDEM Medium-Density-F1 und ist KEIN Testergebnis."

#--------------------------------------------------------------------
hdr "2/6  Werksfirmware sichern (untere 64 KB)"
#--------------------------------------------------------------------
if ! sf -r "$OUT/before-lower.bin" -S "$FLASH_BASE:$HALF" >"$OUT/backup.log" 2>&1; then
    red "Auslesen fehlgeschlagen - vermutlich Lesesperre (RDP) aktiv."
    echo
    echo "Entsperren geht nur mit Massenloeschung:  stm32flash -b $BAUD -k $PORT"
    echo "Danach ist die Werksfirmware weg. Zurueck kommst du mit:"
    echo "    stm32flash -b $BAUD -v -w $STOCK_HEX $PORT"
    echo
    ylw "Zur Aktivierung: die -064 startet nach einer Massenloeschung ohne"
    ylw "Codeabfrage durch - am 2026-11-05 an dieser Platine geprueft. Bei"
    ylw "neueren Versionen wie der -122 ist das offen; dort kann ein Code"
    ylw "faellig werden. Den gibt JYE Tech kostenlos heraus, Mail an"
    ylw "jyetek@gmail.com mit der 8-stelligen PID aus dem Geraetemenue."
    echo
    echo "Wenn du das akzeptierst:  SKIP_BACKUP=1 $0 $PORT"
    [ "${SKIP_BACKUP:-0}" = "1" ] || exit 1
    ylw "SKIP_BACKUP gesetzt - weiter ohne Backup."
else
    grn "Backup: $OUT/before-lower.bin ($(stat -c%s "$OUT/before-lower.bin") Bytes)"
fi

#--------------------------------------------------------------------
hdr "3/6  Testmuster erzeugen"
#--------------------------------------------------------------------
head -c "$HALF" /dev/urandom > "$OUT/pattern.bin"
echo "64 KB Zufallsdaten, sha256: $(sha256sum "$OUT/pattern.bin" | cut -d' ' -f1)"

#--------------------------------------------------------------------
hdr "4/6  In die obere Haelfte schreiben ($UPPER_BASE)"
#--------------------------------------------------------------------
WRITE_OK=1
sf -w "$OUT/pattern.bin" -S "$UPPER_BASE" 2>&1 | tee "$OUT/write.log" || WRITE_OK=0
grep -qi "failed\|error" "$OUT/write.log" && WRITE_OK=0
[ "$WRITE_OK" = "1" ] || ylw "Schreiben meldet Probleme - das ist bereits ein Befund."

#--------------------------------------------------------------------
hdr "5/6  Zuruecklesen und vergleichen"
#--------------------------------------------------------------------
READ_OK=1
sf -r "$OUT/readback.bin" -S "$UPPER_BASE:$HALF" >"$OUT/read.log" 2>&1 || READ_OK=0
MATCH=0
if [ "$READ_OK" = "1" ] && cmp -s "$OUT/pattern.bin" "$OUT/readback.bin"; then MATCH=1; fi

#--------------------------------------------------------------------
hdr "6/6  Aliasing-Kontrolle (untere 64 KB erneut lesen)"
#--------------------------------------------------------------------
ALIAS="unbekannt"
if [ -s "$OUT/before-lower.bin" ]; then
    if sf -r "$OUT/after-lower.bin" -S "$FLASH_BASE:$HALF" >/dev/null 2>&1; then
        cmp -s "$OUT/before-lower.bin" "$OUT/after-lower.bin" && ALIAS="nein" || ALIAS="JA"
    fi
fi

#--------------------------------------------------------------------
hdr "Ergebnis"
#--------------------------------------------------------------------
echo "Schreiben akzeptiert : $([ "$WRITE_OK" = 1 ] && echo ja || echo nein)"
echo "Zurueckgelesen       : $([ "$READ_OK"  = 1 ] && echo ja || echo nein)"
echo "Muster identisch     : $([ "$MATCH"    = 1 ] && echo ja || echo nein)"
echo "Untere Haelfte veraendert (Aliasing): $ALIAS"
echo
ylw "Zum Schluss JP1 und JP2 wieder entloeten."
echo

if [ "$ALIAS" = "JA" ]; then
    red "ALIASING ERKANNT - der Chip hat KEINE 128 KB."
    echo "Der Schreibzugriff oberhalb 64 KB ist auf die untere Haelfte"
    echo "durchgeschlagen und hat deine Firmware veraendert."
    echo
    echo "Jetzt wiederherstellen:"
    echo "    stm32flash -b $BAUD -v -w $STOCK_HEX $PORT"
    exit 2
fi

if [ "$MATCH" = 1 ]; then
    grn "BESTANDEN - die oberen 64 KB sind vorhanden und beschreibbar."
    echo
    echo "lnDSO150 laeuft damit im normalen Build (~95 KB, mit USB-DFU)."
    echo "Die Sparvariante brauchst du nicht."
    echo
    ylw "Einschraenkung: ST testet diese Zellen nicht. 'Funktioniert jetzt'"
    ylw "ist nicht dasselbe wie 'haelt die Datenerhaltung ueber Jahre'."
    exit 0
fi

red "NICHT BESTANDEN - keine nutzbaren 128 KB."
echo "lnDSO150 scheidet aus: der normale Build braucht ~95 KB, die"
echo "Sparvariante passt mit 64.820 B ebenfalls nicht in 62 KB."
echo "Uebrig bleiben die offizielle -122 und Open-DSO-150."
exit 3
