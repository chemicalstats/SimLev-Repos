#!/usr/bin/env python3
# Schnittstellen-Abgleich in einem Befehl (bis 1.5.1 run.sh): drei Auszüge erzeugen, vergleichen,
# api.json und STRUKTUR.md (Repo-Wurzel) schreiben.
#   tests/schnittstelle/run.py            Bericht, Rückgabewert 0
#   tests/schnittstelle/run.py --check    Rückgabewert 1 bei nicht erklärten Abweichungen
#                                        oder bei Abweichung vom eingefrorenen Stand (frozen/)
#   tests/schnittstelle/run.py --freeze   frozen/ neu schreiben; nur mit neuem Eintrag in CHANGES.md
#   tests/schnittstelle/run.py -v --md x.md   weitere Optionen gehen an compare_api.py
# Aus einem beliebigen Ordner; setzt LC_ALL=C.UTF-8. Python 3.10 oder neuer, nur Standardbibliothek.
# Die drei Auszüge laufen seit 1.6.3 zu zweit gleichzeitig (Julia zuerst); ihre Ausgaben erscheinen in der Reihenfolge
# R, Python, Julia.
import datetime
import difflib
import os
import re
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
OUT = os.path.join(HERE, "out")
FROZEN = os.path.join(HERE, "frozen")
CHANGES = os.path.join(HERE, "CHANGES.md")
SPR = ("r", "py", "jl")


class Abbruch(Exception):
    pass


def lies(path):
    with open(path, encoding="utf-8", errors="surrogateescape", newline="") as f:
        return f.read()


def zeilen(s):
    """Zeilen wie bei awk und grep (ohne leere Zeile nach dem letzten Zeilenende)."""
    z = s.split("\n")
    return z[:-1] if z and z[-1] == "" else z


def frozen_stand(path):
    """Stand der eingefrorenen Datei (erste Zeile ' "stand": "…",'), sonst ''."""
    for z in zeilen(lies(path)):
        m = re.fullmatch(r' "stand": "(.*)",', z)
        if m:
            return m.group(1)
    return ""


def newest_entry():
    """Neuester Eintrag in CHANGES.md: erste Überschrift "## JJJJ-MM-TT – Titel", darunter (bis zur nächsten
    Überschrift) "- Was: …" und "- Warum: …" mit Text. Meldet Fehler auf stderr und wirft Abbruch."""
    def fehler(msg):
        print("run.py --freeze: " + msg, file=sys.stderr)
        raise Abbruch()
    if not os.path.isfile(CHANGES):
        fehler("%s fehlt" % CHANGES)
    # Zeilen außerhalb von ```-Blöcken (die Vorlage oben in CHANGES.md zählt nicht)
    text, f = [], False
    for z in zeilen(lies(CHANGES)):
        if z.startswith("```"):
            f = not f
        elif not f:
            text.append(z)
    head = next((z[3:] for z in text if z.startswith("## ")), "")
    if not head:
        fehler('kein Eintrag ("## JJJJ-MM-TT – Titel") in CHANGES.md')
    m = re.match(r"([0-9]{4}-[0-9]{2}-[0-9]{2}) (–|-) .", head)
    try:
        datetime.date.fromisoformat(m.group(1)) if m else None
    except ValueError:
        m = None
    if not m:
        fehler('Überschrift "## %s" hat nicht die Form "## JJJJ-MM-TT – Titel"' % head)
    n, body = 0, []
    for z in text:
        if z.startswith("## "):
            n += 1
        elif n == 1:
            body.append(z)
    if not any(re.match(r"- Was: *[^ ]", z) for z in body):
        fehler('Eintrag "## %s" ohne "- Was: …"' % head)
    if not any(re.match(r"- Warum: *[^ ]", z) for z in body):
        fehler('Eintrag "## %s" ohne "- Warum: …"' % head)
    if text.count("## " + head) > 1:
        fehler('Überschrift "## %s" steht mehrfach in CHANGES.md' % head)
    return head


def diff_u(alt, neu, label_alt, label_neu):
    """Wie diff -u --label … (Ausgabe auf stdout; nur zur Ansicht)."""
    a, b = lies(alt).splitlines(keepends=True), lies(neu).splitlines(keepends=True)
    for z in difflib.unified_diff(a, b, label_alt, label_neu):
        sys.stdout.write(z if z.endswith("\n") else z + "\n\\ No newline at end of file\n")


def rufe(cmd, out=None, err=None):
    """Befehl ausführen (Ausgabe direkt oder in die offenen Dateien out, err), Rückgabewert (127, wenn das Programm fehlt)."""
    sys.stdout.flush()
    try:
        return subprocess.run(cmd, stdout=out, stderr=err).returncode
    except OSError as e:
        msg = "run.py: %s: %s" % (cmd[0], e.strerror)
        if err is None:
            print(msg, file=sys.stderr)
        else:
            err.write((msg + "\n").encode("utf-8", "surrogateescape"))
        return 127


def rufe_alle(cmds):
    """Befehle wie rufe(), seit 1.6.3 zwei gleichzeitig (bei einem Prozessor nacheinander); der letzte (Julia, der längste
    Auszug) beginnt zuerst. Die Ausgabe je Befehl (stdout und stderr getrennt gesammelt, stdout zuerst) erscheint in der
    Reihenfolge der Befehle. Liefert die Rückgabewerte."""
    if (os.cpu_count() or 1) < 2:
        return [rufe(c) for c in cmds]
    tmp = tempfile.mkdtemp(prefix="simlev-api-")

    def arbeit(i):
        pfad = [os.path.join(tmp, "%d.%s" % (i, k)) for k in ("out", "err")]
        with open(pfad[0], "wb") as out, open(pfad[1], "wb") as err:
            return rufe(cmds[i], out, err), pfad

    try:
        with ThreadPoolExecutor(2) as ex:
            erg = {i: ex.submit(arbeit, i) for i in reversed(range(len(cmds)))}
            rcs = []
            for i in range(len(cmds)):
                rc, pfad = erg[i].result()
                for p, strom in zip(pfad, (sys.stdout, sys.stderr)):
                    strom.flush()
                    with open(p, "rb") as h:
                        shutil.copyfileobj(h, strom.buffer)
                    strom.flush()
                rcs.append(rc)
        return rcs
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main(argv):
    os.environ["LC_ALL"] = "C.UTF-8"
    sys.stdout.reconfigure(errors="surrogateescape")
    os.chdir(ROOT)
    check = freeze = False
    pass_ = []
    for a in argv:
        if a == "--freeze":
            freeze = True
        elif a == "--check":
            check = True
            pass_.append(a)
        else:
            pass_.append(a)
    if check and freeze:
        print("run.py: --check und --freeze nicht zusammen", file=sys.stderr)
        return 2

    opt = {f: [] for f in SPR}
    tmp = None
    if freeze:
        try:
            stand = newest_entry()
        except Abbruch:
            print("Abbruch: frozen/ bleibt unverändert. Erst einen Eintrag oben in tests/schnittstelle/CHANGES.md anlegen "
                  "(Datum, was sich ändert, warum).", file=sys.stderr)
            return 1
        for f in SPR:
            p = os.path.join(FROZEN, f + ".json")
            if os.path.isfile(p) and frozen_stand(p) == stand:
                print('run.py --freeze: frozen/%s.json hat schon den Stand "%s".' % (f, stand), file=sys.stderr)
                print("Abbruch: frozen/ bleibt unverändert. Für eine neue Festschreibung erst einen neuen Eintrag oben in "
                      "tests/schnittstelle/CHANGES.md anlegen (Datum, was sich ändert, warum).", file=sys.stderr)
                return 1
        tmp = tempfile.mkdtemp()
        for f in SPR:
            opt[f] = ["--frozen-out", os.path.join(tmp, f + ".json"), "--stand", stand]
    elif check:
        for f in SPR:
            opt[f] = ["--frozen-check", os.path.join(FROZEN, f + ".json")]
    try:
        return weiter(check, freeze, pass_, opt, tmp, stand if freeze else None)
    finally:
        if tmp:
            shutil.rmtree(tmp, ignore_errors=True)


def weiter(check, freeze, pass_, opt, tmp, stand):
    os.makedirs(OUT, exist_ok=True)
    for f in ("api_r.json", "api_py.json", "api_jl.json"):
        if os.path.lexists(os.path.join(OUT, f)):
            os.remove(os.path.join(OUT, f))
    fstatus = 1 if any(rufe_alle([
        ["Rscript", os.path.join(HERE, "api_r.R"), os.path.join(OUT, "api_r.json"), *opt["r"]],
        ["python3", os.path.join(HERE, "api_py.py"), os.path.join(OUT, "api_py.json"), *opt["py"]],
        ["julia", "--project=julia", os.path.join(HERE, "api_jl.jl"), os.path.join(OUT, "api_jl.json"), *opt["jl"]]])) else 0

    if freeze:
        if fstatus:
            print("Abbruch: Auszug fehlgeschlagen, frozen/ bleibt unverändert.", file=sys.stderr)
            return 1
        os.makedirs(FROZEN, exist_ok=True)
        for f in SPR:
            p = os.path.join(FROZEN, f + ".json")
            if os.path.isfile(p):
                diff_u(p, os.path.join(tmp, f + ".json"), "frozen/%s.json (alt)" % f, "frozen/%s.json (neu)" % f)
            shutil.copyfile(os.path.join(tmp, f + ".json"), p)
        print('frozen/ neu festgeschrieben: Stand "%s" (tests/schnittstelle/frozen/{r,py,jl}.json)' % stand)

    if check:
        # Der Stand in frozen/ muss ein Eintrag in CHANGES.md sein (nicht von Hand geändert)
        kopf = zeilen(lies(CHANGES)) if os.path.isfile(CHANGES) else []
        for f in SPR:
            p = os.path.join(FROZEN, f + ".json")
            if not os.path.isfile(p):
                continue
            s = frozen_stand(p)
            if "## " + s not in kopf:
                print('frozen/%s.json: Stand "%s" steht nicht in CHANGES.md (frozen/ nur mit run.py --freeze ändern)' % (f, s))
                fstatus = 1
        print("Eingefrorene Schnittstelle: ABWEICHUNG (siehe oben)" if fstatus else
              "Eingefrorene Schnittstelle: R, Python und Julia unverändert")

    status = rufe(["python3", os.path.join(HERE, "compare_api.py"), "--dir", OUT, *pass_])
    rc = rufe(["python3", os.path.join(HERE, "make_struktur.py")])
    if rc:   # wie set -e in der Shell-Fassung
        return rc if rc > 0 else 128 - rc
    if status < 0:
        status = 128 - status
    return status if status else fstatus


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
