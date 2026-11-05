#!/usr/bin/env python3
# tests/werkzeuge/erzeugen.py – Referenzfälle des Katalogs mit dem installierten R-Paket neu erzeugen
# (bis 1.5.1 erzeugen.sh).
#
#   R_LIBS=<R-Bibliothek mit SimLev> tests/werkzeuge/erzeugen.py [bereich ...]       (aus einem beliebigen Ordner)
#
# Ohne Liste alle Bereiche (je Bereich ein Generator tests/gleichlauf/erzeugen/<bereich>.R). Jeder Generator schreibt
# je Gruppe eine Datei tests/{gleichlauf,fehler,ausgabe}/faelle/<bereich>.jsonl.gz (Format und Auswahl in
# tests/gleichlauf/erzeugen/ref_tools.R). Danach zeigt git diff --stat tests die geänderten Dateien (Byte für Byte
# reproduzierbar); Python und Julia müssen dagegen bitgleich sein (tests/run.py).
# Je Bereich: Zeile "erzeugen <bereich>", dann die letzte Zeile der Standardausgabe des Generators (Meldungen auf
# stderr erscheinen sofort). Setzt LC_ALL=C.UTF-8 und SIMLEV_ERZEUGEN=1 (seit 1.6.2 der einzige Weg, auf dem die Generatoren
# in tests/ schreiben); SIMLEV_FAELLE_DIR, SIMLEV_GEN_SUBSET und SIMLEV_GEN_ALLE werden für die Generatoren entfernt. Bricht beim ersten scheiternden Generator mit dessen Rückgabewert ab.
# Python 3.10 oder neuer, nur Standardbibliothek.
import glob
import os
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
HILFEN = ("ref_tools", "szenario_tools", "blocks_from_flat")   # keine Generatoren


def bereiche():
    """Alle Generatoren tests/gleichlauf/erzeugen/<bereich>.R ohne die Hilfsdateien, in Byte-Reihenfolge."""
    return [n for n in (os.path.basename(g)[:-2] for g in sorted(glob.glob("tests/gleichlauf/erzeugen/*.R")))
            if n not in HILFEN]


def main(argv):
    os.environ["LC_ALL"] = "C.UTF-8"
    os.chdir(ROOT)
    env = {k: v for k, v in os.environ.items() if k not in ("SIMLEV_FAELLE_DIR", "SIMLEV_GEN_SUBSET", "SIMLEV_GEN_ALLE")}
    env["SIMLEV_ERZEUGEN"] = "1"   # seit 1.6.2: nur dieser Befehl schreibt in den Katalog (ref_tools.R prüft)
    for x in argv or bereiche():
        print("erzeugen " + x, flush=True)
        try:
            p = subprocess.run(["Rscript", "tests/gleichlauf/erzeugen/%s.R" % x], stdout=subprocess.PIPE, env=env)
        except OSError as e:   # Rscript fehlt: wie die Shell mit 127
            print("erzeugen.py: Rscript: %s" % e.strerror, file=sys.stderr)
            return 127
        d = p.stdout
        if d:   # wie tail -n 1
            sys.stdout.buffer.write(d[:-1].rsplit(b"\n", 1)[-1] + b"\n" if d.endswith(b"\n") else d.rsplit(b"\n", 1)[-1])
            sys.stdout.buffer.flush()
        if p.returncode:
            return p.returncode if p.returncode > 0 else 128 - p.returncode   # Signal wie in der Shell
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
