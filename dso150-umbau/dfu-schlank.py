#!/usr/bin/env python3
"""Schlanker DFU-Client fuer den lnDSO-Bootloader.

Warum nicht dfu-util: das schickt vor JEDEM Block ein eigenes SET_ADDRESS
(Kommentar im dfu-util-Quelltext: "highly inefficient, but ...") und laeuft
vorher eine komplette Loeschphase mit ERASE_PAGE-Befehlen durch. Zusammen
sind das ueber 450 Control-Transfers; vier Versuche sind daran gescheitert.

Der Bootloader braucht das gar nicht. In src/dfu.cpp:

    baseaddr = prog.addr + ((prog.blocknum - 2) * DFU_TRANSFER_SIZE);
    if (!_flash_page_is_erased(baseaddr))
        _flash_erase_page(baseaddr);
    _flash_program_buffer(baseaddr, (uint16_t*)prog.buf, prog.len);

Also: Adresse EINMAL setzen, dann fortlaufende Blocknummern ab 2 - der
Bootloader rechnet die Zieladresse selbst aus und loescht die Seite bei
Bedarf. Das sind ~190 Transfers statt 450, und der Befehl, der am
haeufigsten gescheitert ist (ERASE_PAGE), kommt gar nicht mehr vor.

Sicherheit: der Bootloader prueft jede Zieladresse selbst gegen
[0x08002000, 0x08020000). Seine eigenen 8 KB sind per Deskriptor als
"nur lesbar" deklariert und koennen hierueber nicht beschrieben werden.
"""
import argparse, struct, sys, time
import usb.core, usb.util

VID, PID = 0x1D50, 0x6021
OUT, IN = 0x21, 0xA1          # Class request, Interface
DETACH, DNLOAD, UPLOAD, GETSTATUS, CLRSTATUS, GETSTATE, ABORT = range(7)
CMD_SETADDR = 0x21
BLOCK = 1024

ZUSTAND = {0: "appIDLE", 1: "appDETACH", 2: "dfuIDLE", 3: "dnloadSYNC",
           4: "dnBUSY", 5: "dnloadIDLE", 6: "manifestSYNC", 7: "manifest",
           8: "manifestWaitReset", 9: "uploadIDLE", 10: "dfuERROR"}


class Dfu:
    def __init__(self, dev, intf=0):
        self.d, self.i = dev, intf

    def status(self):
        r = self.d.ctrl_transfer(IN, GETSTATUS, 0, self.i, 6, 3000)
        st = r[0]
        poll = r[1] | (r[2] << 8) | (r[3] << 16)
        return st, poll, r[4]

    def warte_bereit(self, grenze=40):
        """Pollt, bis der Bootloader nicht mehr beschaeftigt ist."""
        for _ in range(grenze):
            st, poll, state = self.status()
            if st != 0:
                raise RuntimeError(f"DFU-Status {st}, Zustand "
                                   f"{ZUSTAND.get(state, state)}")
            if state not in (3, 4):          # dnloadSYNC / dnBUSY
                return state
            time.sleep(max(poll, 1) / 1000.0)
        raise RuntimeError("bleibt beschaeftigt")

    def clear(self):
        try:
            self.d.ctrl_transfer(OUT, CLRSTATUS, 0, self.i, None, 3000)
        except usb.core.USBError:
            pass

    def aufraeumen(self):
        """In dfuIDLE bringen, egal wo wir anfangen."""
        for _ in range(6):
            st, _, state = self.status()
            if st != 0 or state == 10:
                self.clear(); continue
            if state in (3, 4):
                self.warte_bereit(); continue
            if state in (2, 5):
                return state
            self.d.ctrl_transfer(OUT, ABORT, 0, self.i, None, 3000)
        raise RuntimeError("komme nicht nach dfuIDLE")

    def dnload(self, block, daten):
        self.d.ctrl_transfer(OUT, DNLOAD, block, self.i, daten, 5000)
        return self.warte_bereit()

    def set_adresse(self, adr):
        self.dnload(0, struct.pack("<BI", CMD_SETADDR, adr))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("datei")
    ap.add_argument("--adresse", default="0x08002000")
    ap.add_argument("--versuche", type=int, default=5,
                    help="Wiederholungen pro Block bei Fehlern")
    ap.add_argument("--pause", type=float, default=0.0,
                    help="Sekunden Pause zwischen Bloecken")
    ap.add_argument("--kein-start", action="store_true",
                    help="am Ende nicht in die Anwendung springen")
    a = ap.parse_args()
    adr = int(a.adresse, 0)
    daten = open(a.datei, "rb").read()
    bloecke = [daten[i:i + BLOCK] for i in range(0, len(daten), BLOCK)]
    print(f"{a.datei}: {len(daten)} Bytes -> {len(bloecke)} Bloecke ab 0x{adr:08X}")

    dev = usb.core.find(idVendor=VID, idProduct=PID)
    if dev is None:
        print("Kein 1d50:6021 gefunden."); return 1
    cfg = dev.get_active_configuration()
    intf = cfg[(0, 0)]
    if intf.bInterfaceClass != 0xFE or intf.bInterfaceProtocol != 0x02:
        print(f"Nicht im DFU-Modus (class={intf.bInterfaceClass:#04x} "
              f"proto={intf.bInterfaceProtocol:#04x}). "
              f"OK-Taste beim Einschalten halten."); return 1
    usb.util.claim_interface(dev, intf.bInterfaceNumber)
    dfu = Dfu(dev, intf.bInterfaceNumber)

    print("Zustand:", ZUSTAND.get(dfu.aufraeumen(), "?"))
    dfu.set_adresse(adr)
    print(f"Adresse gesetzt auf 0x{adr:08X}")

    nachgefasst = 0
    t0 = time.time()
    for n, b in enumerate(bloecke):
        for versuch in range(1, a.versuche + 1):
            try:
                dfu.dnload(n + 2, b)
                break
            except Exception as e:
                if versuch == a.versuche:
                    print(f"\nBlock {n} endgueltig gescheitert: {e}")
                    print(f"  (Zieladresse waere 0x{adr + n*BLOCK:08X})")
                    return 2
                nachgefasst += 1
                print(f"\n  Block {n}, Versuch {versuch} fehlgeschlagen "
                      f"({type(e).__name__}) - neu aufsetzen")
                dfu.clear(); dfu.aufraeumen(); dfu.set_adresse(adr + n * BLOCK)
                # ab hier zaehlt die Blocknummer wieder ab 2
                try:
                    dfu.dnload(2, b); break
                except Exception:
                    time.sleep(0.2)
        else:
            return 2
        if a.pause:
            time.sleep(a.pause)
        fertig = (n + 1) * 100 // len(bloecke)
        print(f"\rSchreiben [{'#' * (fertig // 4):<25}] {fertig:3d}%  "
              f"Block {n+1}/{len(bloecke)}", end="", flush=True)

    dt = time.time() - t0
    print(f"\nFertig in {dt:.1f}s, {nachgefasst} Wiederholungen noetig.")

    if not a.kein_start:
        print("Anwendung starten ...")
        try:
            dev.ctrl_transfer(OUT, DNLOAD, 0, dfu.i, None, 3000)
            dfu.status()
        except usb.core.USBError:
            pass          # Geraet startet neu, Abbruch ist hier normal
        print("Neustart angestossen.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
