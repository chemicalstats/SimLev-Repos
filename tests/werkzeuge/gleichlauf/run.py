#!/usr/bin/env python3
# tests/werkzeuge/gleichlauf/run.py – Gleichlaufprüfung (seit 1.0.0; seit 1.4.1 unter tests/; bis 1.5.1 run.sh):
# erzeugt die Fälle der Generatoren mit dem aktuellen R neu – alle Fälle, nicht nur die im Katalog abgelegten – und
# vergleicht Python und Julia streng dagegen (NA != NaN, Vorzeichen der Null, Ausgaben, Warnungen); die Zufallsprüfungen
# aus FUZZ_REF vergleichen R neu, Python und Julia mit der abgelegten Referenz der Vorversion (seit 1.6.2 nur lesen).
#
#   tests/werkzeuge/gleichlauf/run.py [--quick | --full] [--out ORDNER] [--no-build] [--jobs N] [bereich ...]
#   tests/werkzeuge/gleichlauf/run.py --ref-erzeugen K [--ersetzen] [--jobs N] [name ...]
#
#   --quick     jede 20. Fall-Kennung (Prüfsumme, SIMLEV_GEN_SUBSET=20), kleine Engine-Läufe und kleine
#               Zufallsprüfungen (Standard)
#   --full      alle Fälle, Engine-Läufe wie im Katalog (500 bzw. 1000 Zufallsfälle), volle Zufallsprüfungen
#               und faelle_diff: die neu erzeugten Katalogdateien müssen Byte für Byte tests/<gruppe>/faelle entsprechen
#   --out DIR   Arbeitsordner (Standard tests/werkzeuge/gleichlauf/out; relativ zur Repo-Wurzel); darin rlib/, faelle/
#               (Auswahl wie im Katalog), faelle/alle/ (alle Fälle), cases/, stress/, fuzz/, Protokolle *.txt und bericht.txt
#   --no-build  R, Python und Julia nicht neu bauen (R-Bibliothek DIR/rlib muss bestehen)
#   --jobs N    (seit 1.6.2) höchstens N Schritte gleichzeitig (Standard 2 bzw. die Zahl der Prozessoren, wenn kleiner);
#               ein Schritt beginnt, sobald seine Voraussetzungen fertig sind (z. B. Python und Julia gegen die abgelegte
#               Referenz, während R die nächste Zufallsprüfung rechnet). --jobs 1: nacheinander wie bis 1.6.1. Seit 1.6.3
#               läuft Julia immer nur in einem Prozess zur Zeit (die übrigen Schritte daneben), und bereite Schritte beginnen
#               nach ihrer Dauer im letzten bericht.txt des Arbeitsordners (längste zuerst; ohne Angabe in der Reihenfolge
#               des Eintrags)
#   bereich ... nur diese Generatoren tests/gleichlauf/erzeugen/<bereich>.R (engine mit Engine-Läufen)
#
#   --ref-erzeugen K  (seit 1.6.2) einziger Weg zu den Referenzausgaben: erzeugt mit der R-Bibliothek der Kennung K aus
#               REFLIBS (eingefroren, z. B. R 1.6.2) die Zufallsfälle aller FUZZ_REF-Einträge mit Referenz K (oder nur
#               der genannten) für --quick und --full und legt sie unter REFDIR/K ab (Standard /home/claude/gleichlauf_ref,
#               Umgebung SIMLEV_GLEICHLAUF_REF): quick/<name>_fuzz.jsonl.gz, full/<name>_fuzz.jsonl.gz und manifest.json
#               (Kennung, Fassung der Bibliothek, R-Version, je Name und Modus Startwert, Fallzahl, SHA-256 der Datei und
#               des Skripts, seit 1.6.3 auch der Hilfsdateien, die das Skript mit source() lädt). Die Ablage entsteht mit
#               gzip -9 (SIMLEV_GZIP_STUFE=9; Arbeitsdateien seit 1.6.3 mit Stufe 1). Vorhandene Einträge bleiben, außer
#               mit --ersetzen. Baut und vergleicht nichts.
#
# Referenzen einmal je Versionsschritt (seit 1.6.2): Der übliche Lauf liest die Referenz nur. Fehlt sie, passen Fallzahl,
# Startwert oder Prüfsumme nicht, scheitert der Schritt mit einer Meldung (nichts wird still neu erzeugt). Neue
# Referenz nach einem Versionsschritt: R der neuen Fassung als eigene Bibliothek bauen und einfrieren, Eintrag in REFLIBS
# (nur die letzte Fassung), Referenz in FUZZ_REF umstellen, run.py --ref-erzeugen K. Die Referenzfälle des Katalogs
# tests/<gruppe>/faelle schreibt nur tests/werkzeuge/erzeugen.py (ref_tools.R verweigert das Schreiben in tests/ sonst).
#
# Schritte: 1 bauen (R CMD INSTALL --preclean, Python build_ext --inplace --force, Julia Pkg.build), core/sync.py --check;
# 2 Zufallsprüfung der Engine tests/werkzeuge/zufall/engine_faelle.R und engine_stress.R (nur hier, nichts abgelegt;
# packen.py -> faelle/alle/zufall_engine); 3 Bereiche erzeugen (SIMLEV_GEN_ALLE=1); 3b Breitenprüfung: die bisherigen
# Einzelfälle der Bereiche (tests/werkzeuge/breite/<bereich>.R, nichts abgelegt -> faelle/alle/breite_<bereich>);
# 4 Python und Julia gegen faelle/alle (tests/werkzeuge/gleichlauf/vergleich.{py,jl}); 4b faelle_diff (nur --full und
# ohne Bereichsliste, sonst SIMLEV_GEN_NUR_ALLE=1: die Dateien je Gruppe liest dann niemand; in der Teilmenge ziehen
# manche Generatoren ihre Eingaben in anderer Folge); 5 Zufallsprüfungen (ohne Bereichsliste immer, mit Liste nur bei
# --full), Fälle werden nicht abgelegt:
#   date_fuzz.R + _cmp.{py,jl} Datumsformat (auch Schalter, %OS), as.Date  quick 500, full 10000 Formate (+ Hälfte %OS)
#   rbase_fuzz.R + _cmp.{py,jl} Kerne core/slc_rbase*.cpp (Summen, order …)  quick 200, full 5000 Fälle je Kern
#   tariff_fuzz.R (1.3.0)       Tarifkern core/tariff_core_impl.h gegen      quick 200, full 10000 Fälle je Teil
#                              .tariff_income_tax/.tariff_soli/.tariff_close (nur R; Kern in allen Sprachen gleich)
#   (diese drei mit dem aktuellen R als Orakel: R-Basisfunktionen bzw. R-Code, frisch erzeugt)
#   FUZZ_REF (seit 1.4.0)      je Eintrag tests/werkzeuge/gleichlauf/<name>_fuzz.R, quick 300, full 2000 Fälle: R neu
#                              gegen die abgelegte Referenz (sim_fuzz_cmp.py), Python und Julia (vergleich.{py,jl})
#                              gegen dieselbe Referenz; bitgleich mit Ausgabe, print(), Warnungen und Fehlertexten.
#                              Seit 1.6.3 prüft je Sprache ein Prozess alle Referenzen (Protokoll weiter je Name).
#                              Familien: sim, sched, metric (simulation(), Vorbereitung, Kennzahlen; seit 1.4.0), approx,
#                              wd, hmm, goal, pbo (1.5.0), nav, rolling, study (1.5.1), libm (1.5.2), cal, boot, copula,
#                              mom, eigen, clust, vec, cor, padj, fmt (1.6.0), prec (1.6.2: expm1/log1p, CAGR,
#                              Periodenaggregation, Copula-Dichte, Fehler in ulp gegen Rmpfr); eigen seit 1.6.2 zusätzlich
#                              gegen eine hochgenaue Rechnung (Rmpfr). Seit 1.6.2 alle gegen eine Fassung (R 1.6.2, seit 1.6.3 R
#                              1.6.3; bis 1.6.1 gegen R 1.3.0 bis 1.5.2, je Familie die Fassung vor ihrem Umbau)
# 6 Abdeckung der Exporte durch die Katalogfälle (exporte.py). Ende 1, wenn eine Sprache abweicht, ein Schritt
# scheitert, R vom Katalog abweicht oder core/sync.py --check abweicht. Läufe nie parallel im selben Arbeitsordner.
# Python 3.10 oder neuer, nur Standardbibliothek.
#
# Neue Zufallsprüfung mit abgelegter Referenz (Muster wie sim_fuzz): eine Zeile in FUZZ_REF (Name, Fallzahl quick/full,
# Startwert, Referenz), dann run.py --ref-erzeugen K <name>; Schritte, Protokolle fz_<name>_{new,r,py,jl}.txt und die
# Zusammenfassung folgen daraus. Andere Schritte: in main() mit plan.add(...), die Protokolle dann in ZUSAMMENFASSUNG
# eintragen.
import datetime
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, os.path.dirname(HERE))
from erzeugen import bereiche  # noqa: E402  (Generatoren tests/gleichlauf/erzeugen/<bereich>.R, seit 1.6.3 nur dort)

# Fallzahlen je Modus: Teilmenge der Kennungen, Engine-Läufe (engine_faelle, engine_stress), Zufallsprüfungen
MODUS = {
    "quick": dict(sub=20, ng=10, ns=20, date=500, rbase=200, tariff=200),
    "full": dict(sub=1, ng=500, ns=1000, date=10000, rbase=5000, tariff=10000),
}
# Referenz der Vorversion (seit 1.6.2 nur eine): Kennung -> (Fassung, Umgebungsvariable der Bibliothek, Standard).
# Die Bibliothek wird nur von --ref-erzeugen gelesen; der übliche Lauf liest die abgelegten Ausgaben unter REFDIR/K.
REFLIBS = {
    "163": ("1.6.3", "SIMLEV_FUZZ_REFLIB163", "/home/claude/rlib163"),
}
# Julia: Bau ohne Grenze; die Vergleiche mit --heap-size-hint=2G (JULIA_VGL). Der Vergleich liest seit 1.6.3 Fall für
# Fall, ein Prozess prüft aber alle FUZZ_REF-Familien; ohne Grenze wuchs er bei --full bis 4 GB und wurde neben R
# (eigen_fuzz full mit Rmpfr, 2 GB) bei 7 GB Speicher beendet.
JULIA = ["julia", "--project=julia"]
JULIA_VGL = [*JULIA, "--heap-size-hint=2G"]
REFDIR_VAR, REFDIR_STANDARD = "SIMLEV_GLEICHLAUF_REF", "/home/claude/gleichlauf_ref"
# Zufallsprüfungen mit abgelegter Referenz, in dieser Reihenfolge:
# (Name: tests/werkzeuge/gleichlauf/<name>_fuzz.R, Fälle quick, Fälle full, Startwert, Referenz aus REFLIBS)
FUZZ_REF = [
    ("sim", 300, 2000, 20261101, "163"),      # simulation() (seit 1.4.0)
    ("sched", 300, 2000, 20261102, "163"),    # Termine, Kalender, Flags der Vorbereitung im Kern (seit 1.4.0)
    ("metric", 300, 2000, 20261103, "163"),   # Kennzahlen, Auswertung im Kern (seit 1.4.0)
    # in 1.5.0 in den Kern verlagerte Teile (approx, Entnahme-Auswertung, HMM-EM, Zielplanung, CSCV)
    ("approx", 300, 2000, 20261104, "163"),
    ("wd", 300, 2000, 20261105, "163"),
    ("hmm", 300, 2000, 20261106, "163"),
    ("goal", 300, 2000, 20261107, "163"),
    ("pbo", 300, 2000, 20261108, "163"),
    ("nav", 300, 2000, 20261109, "163"),
    ("rolling", 300, 2000, 20261110, "163"),
    ("study", 300, 2000, 20261111, "163"),
    ("libm", 300, 2000, 20261112, "163"),     # in 1.5.2 schneller in Python (libm in C, Ränge, Dubletten, Trigger)
    # in 1.6.0 (K38a) in den Kern verlagert bzw. beschleunigt: Kalenderauffüllung (cal), Pfadaufbau im Bootstrap (boot),
    # t-Copula, optimize und qt/pt auf Threads (copula), Momentum-Scores (mom), Eigenzerlegung (eigen; seit 1.6.2
    # Householder + QL, dazu Genauigkeit gegen Rmpfr)
    ("cal", 300, 2000, 20261113, "163"),
    ("boot", 300, 2000, 20261114, "163"),
    ("copula", 300, 2000, 20261115, "163"),
    ("mom", 300, 2000, 20261116, "163"),
    ("eigen", 300, 2000, 20261117, "163"),
    # in 1.6.0 in den Kern verlagerte R-Nachbildungen (K38b; approx_fuzz.R erweitert um filter und regularize.values)
    ("clust", 300, 2000, 20261118, "163"),    # dist, hclust (core/slc_rbase_clust.cpp)
    ("vec", 300, 2000, 20261119, "163"),      # cut/.bincode, seq.int, median, sort (core/slc_rbase_vec.cpp)
    ("cor", 300, 2000, 20261120, "163"),      # cor/cov mit Rängen, cov2cor, scale (core/slc_rbase_cor.cpp)
    ("padj", 300, 2000, 20261121, "163"),     # p.adjust, ecdf (core/slc_rbase_models.cpp)
    ("fmt", 300, 2000, 20261122, "163"),      # sprintf, formatC, format, round/signif (core/slc_rbase_fmt.cpp)
    # seit 1.6.2: genauere Formeln (expm1/log1p, CAGR, Periodenaggregation, Copula-Dichte), Fehler in ulp gegen Rmpfr
    ("prec", 300, 2000, 20261123, "163"),
]
# Protokolle der Zusammenfassung (Schritt 7) mit Zeilen nach MUSTER; danach je FUZZ_REF fz_<name>_{r,py,jl}
ZUSAMMENFASSUNG = ["faelle_diff", "fz_date_py", "fz_date_jl", "fz_rbase_py", "fz_rbase_jl", "fz_tariff"]
MUSTER = re.compile(r"textgleich|gleich$|gleich \(|^Gesamt|^GESAMT|^sim_fuzz|^[a-z0-9_]+ +[0-9]+ +[0-9]+/[0-9]+|ulp")

status = 0
rep = None
_lock = threading.Lock()


def note(text):
    """Zeile auf die Konsole und in bericht.txt."""
    b = (text + "\n").encode("utf-8", "surrogateescape")
    with _lock:
        sys.stdout.buffer.write(b)
        sys.stdout.buffer.flush()
        with open(rep, "ab") as h:
            h.write(b)


def fail():
    global status
    with _lock:
        status = 1


def step(name, log, cmd, env=None, cwd=None):
    """Schritt mit Protokoll log (stdout und stderr); Ergebniszeile in den Bericht; False und status = 1 bei Fehler."""
    t0 = time.time()
    with open(log, "wb") as h:
        try:
            rc = subprocess.run(cmd, stdout=h, stderr=subprocess.STDOUT, cwd=cwd,
                                env=None if env is None else {**os.environ, **env}).returncode
        except OSError as e:   # Programm fehlt (Shell: Rückgabewert 127, Meldung im Protokoll)
            h.write(("run.py: %s: %s\n" % (cmd[0], e.strerror)).encode())
            rc = 127
    if rc == 0:
        note("ok      %s (%d s)" % (name, int(time.time() - t0)))
        return True
    note("FEHLER  %s (%d s; Protokoll %s)" % (name, int(time.time() - t0), log))
    fail()
    return False


class Plan:
    """Schritte mit Voraussetzungen; höchstens `jobs` gleichzeitig. Bereite Schritte beginnen nach Rang (seit 1.6.3:
    Dauer im letzten Bericht, längste zuerst; ohne Angabe in der Reihenfolge des Eintrags). Schritte derselben Gruppe
    laufen nie gleichzeitig (seit 1.6.3, statt „allein“: Julia ein Prozess zur Zeit, daneben die übrigen Schritte).
    Ein Schritt, dessen Voraussetzung scheiterte, entfällt (wie `a and b` bis 1.6.1)."""

    def __init__(self, jobs, dauer=None):
        self.jobs, self.items, self.dauer = max(1, jobs), [], dauer or {}

    def add(self, fn, deps=(), after=(), gruppe=None, vorn=False):
        """fn() -> bool (Name für den Rang: fn.name); deps: Nummern früherer Schritte, die gelingen müssen; after:
        Schritte, die nur fertig sein müssen (auch gescheitert); gruppe: höchstens ein Schritt der Gruppe zugleich;
        vorn: ohne Dauer im letzten Bericht vor allen anderen (lange Schritte). Liefert die Nummer des Schritts."""
        rang = -self.dauer.get(getattr(fn, "name", None), float("inf") if vorn else 0)
        self.items.append((fn, tuple(d for d in deps if d is not None), tuple(d for d in after if d is not None), gruppe,
                           rang))
        return len(self.items) - 1

    def run(self):
        n = len(self.items)
        state = ["warten"] * n            # warten, läuft, ok, fehler, entfällt
        folge = sorted(range(n), key=lambda i: (self.items[i][4], i))
        cv = threading.Condition()

        def work(i):
            try:
                ok = bool(self.items[i][0]())
            except Exception as e:   # noqa: BLE001 - Fehler des Ablaufs selbst melden, nicht hängen bleiben
                note("FEHLER  Ablauf: %r" % (e,))
                fail()
                ok = False
            with cv:
                state[i] = "ok" if ok else "fehler"
                cv.notify_all()

        with cv:
            while True:
                for i in range(n):        # Schritte mit gescheiterter Voraussetzung entfallen
                    if state[i] == "warten" and any(state[d] in ("fehler", "entfällt") for d in self.items[i][1]):
                        state[i] = "entfällt"
                running = state.count("läuft")
                belegt = {self.items[i][3] for i in range(n) if state[i] == "läuft"}
                for i in folge:
                    if running >= self.jobs:
                        break
                    fn, deps, after, gruppe, _ = self.items[i]
                    if (state[i] == "warten" and (gruppe is None or gruppe not in belegt)
                            and all(state[d] == "ok" for d in deps)
                            and all(state[d] in ("ok", "fehler", "entfällt") for d in after)):
                        state[i] = "läuft"
                        running += 1
                        belegt.add(gruppe)
                        threading.Thread(target=work, args=(i,), daemon=True).start()
                if not running:
                    break
                cv.wait()


def dauer_alt(path):
    """Dauer je Schritt aus einem früheren bericht.txt (Zeilen „ok      <Name> (<n> s)“, „FEHLER  <Name> (<n> s; …)“)."""
    d = {}
    for z in lies_zeilen(path) if os.path.isfile(path) else []:
        m = re.match(r"(?:ok|FEHLER) +(.*) \((\d+) s[;)]", z)
        if m:
            d[m.group(1)] = int(m.group(2))
    return d


def lies_zeilen(path):
    with open(path, encoding="utf-8", errors="surrogateescape", newline="") as h:
        z = h.read().split("\n")
    return z[:-1] if z and z[-1] == "" else z


def neu(*ordner):
    """Ordner leeren und neu anlegen (rm -rf; mkdir -p)."""
    for d in ordner:
        shutil.rmtree(d, ignore_errors=True)
        os.makedirs(d, exist_ok=True)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def refdir(k):
    return os.path.join(os.environ.get(REFDIR_VAR) or REFDIR_STANDARD, k)


def lies_manifest(k):
    p = os.path.join(refdir(k), "manifest.json")
    if not os.path.isfile(p):
        return None
    with open(p, encoding="utf-8") as h:
        return json.load(h)


def ref_pruefen(k, name, mode, faelle, seed):
    """Abgelegte Referenz der Zufallsprüfung `name` (Modus quick/full) prüfen: (Datei, None) oder (None, Meldung)."""
    hinweis = "tests/werkzeuge/gleichlauf/run.py --ref-erzeugen %s %s" % (k, name)
    m = lies_manifest(k)
    if m is None:
        return None, "Referenz %s fehlt (%s/manifest.json); erzeugen mit %s" % (k, refdir(k), hinweis)
    e = m.get("familien", {}).get(name, {}).get(mode)
    if e is None:
        return None, "Referenz %s ohne %s_fuzz (%s); erzeugen mit %s" % (k, name, mode, hinweis)
    if e.get("faelle") != faelle or e.get("startwert") != seed:
        return None, ("Referenz %s %s_fuzz (%s): %s Fälle, Startwert %s, erwartet %d und %d (FUZZ_REF geändert?); "
                      "neu mit %s --ersetzen" % (k, name, mode, e.get("faelle"), e.get("startwert"), faelle, seed, hinweis))
    f = os.path.join(refdir(k), e["datei"])
    if not os.path.isfile(f):
        return None, "Referenz %s %s_fuzz (%s): Datei %s fehlt; neu mit %s --ersetzen" % (k, name, mode, f, hinweis)
    if sha256(f) != e.get("sha256"):
        return None, "Referenz %s %s_fuzz (%s): Prüfsumme von %s falsch; neu mit %s --ersetzen" % (k, name, mode, f, hinweis)
    skript = os.path.join("tests", "werkzeuge", "gleichlauf", name + "_fuzz.R")
    if os.path.isfile(skript) and sha256(skript) != e.get("skript_sha256"):
        note("Hinweis %s_fuzz.R ist seit der Referenz %s geändert (Prüfsumme des Skripts); bei Abweichungen neu mit %s "
             "--ersetzen" % (name, k, hinweis))
    # seit 1.6.3 auch die Hilfsdateien des Skripts (ref_tools.R mit fuzz_case u. a.); ältere Manifeste haben sie nicht
    for h, v in sorted((e.get("hilfen_sha256") or {}).items()):
        if not os.path.isfile(h) or sha256(h) != v:
            note("Hinweis %s (von %s_fuzz.R geladen) ist seit der Referenz %s geändert (Prüfsumme); bei Abweichungen neu "
                 "mit %s --ersetzen" % (h, name, k, hinweis))
    return f, None


def hilfen(skript):
    """Dateien, die ein R-Skript mit source("…") lädt (Pfade ab der Repo-Wurzel), mit SHA-256."""
    with open(skript, encoding="utf-8") as h:
        pfade = re.findall(r'^\s*source\("([^"]+)"\)', h.read(), re.M)
    return {p: sha256(p) for p in sorted(set(pfade)) if os.path.isfile(p)}


def ref_erzeugen(k, namen, ersetzen, jobs, out):
    """--ref-erzeugen: Referenzausgaben der Kennung k mit der eingefrorenen R-Bibliothek (nur hier geschrieben)."""
    fassung, var, standard = REFLIBS[k]
    reflib = os.environ.get(var) or standard
    if not os.path.isdir(os.path.join(reflib, "SimLev")):
        note("FEHLER  Referenzbibliothek R %s fehlt (%s; %s)" % (fassung, reflib, var))
        return 1
    try:
        ver = subprocess.run(["Rscript", "-e", "cat(as.character(packageVersion('SimLev')), R.version.string, sep = '\\n')"],
                             env={**os.environ, "R_LIBS": reflib}, stdout=subprocess.PIPE, check=True).stdout.decode().split("\n")
    except (OSError, subprocess.CalledProcessError) as e:
        note("FEHLER  Rscript: %s" % e)
        return 1
    if ver[0] != fassung:
        note("FEHLER  %s enthält SimLev %s, erwartet %s (REFLIBS)" % (reflib, ver[0], fassung))
        return 1
    alle = [e for e in FUZZ_REF if e[4] == k]
    unbekannt = [x for x in namen if x not in [e[0] for e in alle]]
    if unbekannt:
        note("FEHLER  nicht in FUZZ_REF mit Referenz %s: %s" % (k, ", ".join(unbekannt)))
        return 1
    wahl = [e for e in alle if not namen or e[0] in namen]
    rd = refdir(k)
    os.makedirs(rd, exist_ok=True)
    m = lies_manifest(k) or {"kennung": k, "familien": {}}
    m.update(fassung=fassung, simlev=ver[0], r=ver[1], bibliothek=reflib)
    plan, ergebnis = Plan(jobs), {}
    note("Referenz %s erzeugen (SimLev %s, %s, %s) nach %s" % (k, ver[0], ver[1], reflib, rd))
    for name, k_quick, k_full, seed, _ in wahl:
        for mode, faelle in (("quick", k_quick), ("full", k_full)):
            if not ersetzen and mode in m["familien"].get(name, {}):
                note("bleibt  %s_fuzz %s (vorhanden; --ersetzen überschreibt)" % (name, mode))
                continue
            tmp = os.path.join(out, "ref_" + k, mode, name)

            def job(name=name, mode=mode, faelle=faelle, seed=seed, tmp=tmp):
                neu(tmp)
                if not step("Referenz %s_fuzz %s (%d) mit R %s" % (name, mode, faelle, fassung),
                            os.path.join(out, "ref_%s_%s_%s.txt" % (k, mode, name)),
                            ["Rscript", "tests/werkzeuge/gleichlauf/%s_fuzz.R" % name, str(faelle), str(seed)],
                            # Ablage wie bis 1.6.2 mit gzip -9 (Arbeitsdateien seit 1.6.3 mit Stufe 1)
                            env={"R_LIBS": reflib, "SIMLEV_FAELLE_DIR": tmp, "SIMLEV_GZIP_STUFE": "9"}):
                    return False
                os.makedirs(os.path.join(rd, mode), exist_ok=True)
                ziel = os.path.join(mode, name + "_fuzz.jsonl.gz")
                shutil.copyfile(os.path.join(tmp, name + "_fuzz.jsonl.gz"), os.path.join(rd, ziel))
                with _lock:
                    ergebnis[(name, mode)] = dict(
                        faelle=faelle, startwert=seed, datei=ziel, sha256=sha256(os.path.join(rd, ziel)),
                        skript_sha256=sha256("tests/werkzeuge/gleichlauf/%s_fuzz.R" % name),
                        hilfen_sha256=hilfen("tests/werkzeuge/gleichlauf/%s_fuzz.R" % name),
                        erzeugt=datetime.datetime.now().astimezone().isoformat(timespec="seconds"))
                return True
            plan.add(job)
    plan.run()
    for (name, mode), e in sorted(ergebnis.items()):
        m["familien"].setdefault(name, {})[mode] = e
    with open(os.path.join(rd, "manifest.json"), "w", encoding="utf-8") as h:
        json.dump(m, h, ensure_ascii=False, indent=1, sort_keys=True)
        h.write("\n")
    note("Referenz %s: %d Dateien neu, Manifest %s" % (k, len(ergebnis), os.path.join(rd, "manifest.json")))
    return status


def vergleich_ref(sprache, log, kopf, refs, protokoll):
    """Schritt: ein Prozess (vergleich.py bzw. vergleich.jl) prüft alle Referenzen refs = [(Name, Fassung, Datei)], je
    Name mit eigenem Protokoll protokoll(Name); danach je Name eine Zeile ok/FEHLER wie bis 1.6.2 je Prozess."""
    def job():
        cmd = list(kopf)
        for name, _, gz in refs:
            cmd += ["--protokoll", protokoll(name), gz]
            if os.path.isfile(protokoll(name)):
                os.remove(protokoll(name))
        ok = step("%s FUZZ_REF (%d Referenzen)" % (sprache, len(refs)), log, cmd)
        erg = {}
        for z in lies_zeilen(log) if os.path.isfile(log) else []:
            m = re.match(r"Datei (.*): (\d+)/(\d+) \((\d+) s\)$", z)
            if m:
                erg[m.group(1)] = (int(m.group(2)), int(m.group(3)), int(m.group(4)))
        for name, fassung, gz in refs:
            e = erg.get(gz)
            titel = "%s %s_fuzz gegen R %s" % (sprache, name, fassung)
            if e and e[0] == e[1] and e[1] > 0:
                note("ok      %s (%d s)" % (titel, e[2]))
            else:
                note("FEHLER  %s (%s; Protokoll %s)" % (titel, "%d s" % e[2] if e else "ohne Ergebnis", protokoll(name)))
                fail()
                ok = False
        return ok
    job.name = "%s FUZZ_REF (%d Referenzen)" % (sprache, len(refs))
    return job


def main(argv):
    global rep
    os.environ["LC_ALL"] = "C.UTF-8"
    os.chdir(ROOT)
    mode, out, build, mods, erzeugen, ersetzen = "quick", os.path.join(HERE, "out"), True, [], None, False
    jobs = min(2, os.cpu_count() or 1)
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--quick":
            mode = "quick"
        elif a == "--full":
            mode = "full"
        elif a in ("--out", "--jobs", "--ref-erzeugen"):
            if i + 1 >= len(argv):
                print("run.py: %s ohne Wert" % a, file=sys.stderr)
                return 2
            v = argv[i + 1]
            i += 1
            if a == "--out":
                out = v
            elif a == "--jobs":
                if not v.isdigit() or int(v) < 1:
                    print("run.py: --jobs braucht eine Zahl >= 1", file=sys.stderr)
                    return 2
                jobs = int(v)
            else:
                if v not in REFLIBS:
                    print("run.py: --ref-erzeugen ohne Kennung aus REFLIBS (%s)" % ", ".join(REFLIBS), file=sys.stderr)
                    return 2
                erzeugen = v
        elif a == "--ersetzen":
            ersetzen = True
        elif a == "--no-build":
            build = False
        elif a == "--ref":
            print("run.py: --ref entfällt seit 1.6.2 (eine abgelegte Referenz, REFLIBS); Referenz erzeugen mit --ref-erzeugen",
                  file=sys.stderr)
            return 2
        elif a.startswith("-"):
            print("run.py: unbekannte Option " + a, file=sys.stderr)
            return 2
        else:
            mods.append(a)
        i += 1
    n = MODUS[mode]
    full = mode == "full"
    os.makedirs(out, exist_ok=True)
    out = os.path.abspath(out)
    rep = os.path.join(out, "bericht.txt")
    dauer = dauer_alt(rep)            # Rang der Schritte (seit 1.6.3): Dauer im letzten Lauf in diesem Ordner
    open(rep, "wb").close()
    o = lambda *p: os.path.join(out, *p)   # noqa: E731
    if erzeugen:
        return ref_erzeugen(erzeugen, mods, ersetzen, jobs, out)

    t_start = time.time()
    note("Gleichlauf %s (%s), Arbeitsordner %s, %d Schritte gleichzeitig" % (
        mode, datetime.datetime.now().astimezone().isoformat(timespec="seconds"), out, jobs))
    plan = Plan(jobs, dauer)
    add = plan.add

    def S(name, *a, **k):
        fn = lambda: step(name, *a, **k)   # noqa: E731
        fn.name = name
        return fn
    JL = "julia"                     # Gruppe: Julia läuft in einem Prozess zur Zeit (Speicher, Übersetzung)

    # 1. Bauen (die drei Sprachen unabhängig voneinander)
    b_r = b_py = b_jl = None
    if build:
        os.makedirs(o("rlib"), exist_ok=True)
        # --preclean: make kennt die Header-Abhaengigkeiten nicht
        b_r = add(S("R CMD INSTALL", o("r_install.txt"), ["R", "CMD", "INSTALL", "--preclean", "-l", o("rlib"), "r"]))
        b_py = add(S("Python build_ext --inplace", o("py_build.txt"),
                     ["python3", "setup.py", "build_ext", "--inplace", "--force"], cwd="python"))
        b_jl = add(S("Julia Pkg.build", o("jl_build.txt"), [*JULIA, "-e", "using Pkg; Pkg.build()"]), gruppe=JL)
    add(S("core/sync.py --check", o("core_sync.txt"), ["python3", "core/sync.py", "--check"]))
    # 6. Abdeckung der Exporte durch den Katalog (liest nur tests/<gruppe>/faelle; seit 1.6.3 im Plan, Bericht danach)
    def exporte():
        with open(o("exporte.txt"), "wb") as h:
            try:
                subprocess.run(["python3", "tests/werkzeuge/gleichlauf/exporte.py"], stdout=h, stderr=subprocess.STDOUT)
            except OSError as e:
                h.write(("run.py: python3: %s\n" % e.strerror).encode())
        return True   # nur Bericht, wie bis 1.6.2
    add(exporte)

    # 2. Engine-Läufe (Engine-Format; alle Zufallsfälle werden verglichen, im Katalog liegt die Auswahl)
    os.environ["R_LIBS"] = o("rlib")
    engine = not mods
    if engine:
        mods = bereiche()
    for d in ("cases", "stress", "faelle"):
        shutil.rmtree(o(d), ignore_errors=True)
    os.makedirs(o("faelle", "alle"), exist_ok=True)
    gen, cmp = [], []                 # Schritte der Erzeugung, Dateien für Schritt 4
    if "engine" in mods:   # Zufallsprüfung der Engine, nichts abgelegt
        e1 = add(S("erzeugen Engine engine_faelle.R (%d)" % n["ng"], o("gen_engine_faelle.txt"),
                   ["Rscript", "tests/werkzeuge/zufall/engine_faelle.R", o("cases"), str(n["ng"]), "4711"]), [b_r])
        e2 = add(S("erzeugen Engine engine_stress.R (%d)" % n["ns"], o("gen_engine_stress.txt"),
                   ["Rscript", "tests/werkzeuge/zufall/engine_stress.R", o("stress"), str(n["ns"]), "90210"]), [b_r])
        gen.append(add(S("packen Engine-Zufallsfälle", o("zufall_packen.txt"),
                         ["python3", "-I", "tests/werkzeuge/zufall/packen.py", out, o("faelle", "alle", "zufall_engine.jsonl.gz")]),
                       [e1, e2]))
        cmp.append(o("faelle", "alle", "zufall_engine.jsonl.gz"))

    # 3. Bereiche erzeugen: Auswahl nach faelle/, alle Fälle nach faelle/alle/ (die Auswahl je Gruppe liest nur
    # faelle_diff.py, Schritt 4b; sonst schreibt der Generator sie nicht, SIMLEV_GEN_NUR_ALLE=1)
    nur_alle = {} if full and engine else {"SIMLEV_GEN_NUR_ALLE": "1"}
    for m in mods:
        if not os.path.isfile("tests/gleichlauf/erzeugen/%s.R" % m):
            note("FEHLER  Generator tests/gleichlauf/erzeugen/%s.R fehlt" % m)
            fail()
            continue
        gen.append(add(S("erzeugen " + m, o("gen_%s.txt" % m), ["Rscript", "tests/gleichlauf/erzeugen/%s.R" % m],
                         env={"SIMLEV_FAELLE_DIR": o("faelle"), "SIMLEV_GEN_SUBSET": str(n["sub"]), "SIMLEV_GEN_ALLE": "1",
                              **nur_alle}), [b_r]))
        cmp.append(o("faelle", "alle", m + ".jsonl.gz"))

    # 3b. Breitenprüfung (seit 1.4.2): die bisherigen Einzelfälle der Bereiche (tests/werkzeuge/breite/<bereich>.R;
    # gleiche Zufallsfolge wie bis 1.4.1), nur hier verglichen, nichts abgelegt
    for m in mods:
        if not os.path.isfile("tests/werkzeuge/breite/%s.R" % m):
            continue
        gen.append(add(S("erzeugen Breite " + m, o("gen_breite_%s.txt" % m), ["Rscript", "tests/werkzeuge/breite/%s.R" % m],
                         env={"SIMLEV_FAELLE_DIR": o("faelle", "alle"), "SIMLEV_GEN_SUBSET": str(n["sub"])}), [b_r]))
        cmp.append(o("faelle", "alle", "breite_" + m + ".jsonl.gz"))

    # 4. Python und Julia gegen alle neu erzeugten Fälle (nach allen Erzeugungen; gescheiterte fehlen in der Liste)
    def vergleich(sprache, log, cmd_kopf):
        def job():
            da = [p for p in cmp if os.path.isfile(p)]
            return step(sprache, log, cmd_kopf + da) if da else True
        job.name = sprache
        return job
    # (wartet auf alle Erzeugungen, auch gescheiterte: deren Datei fehlt dann in der Liste). Seit 1.6.3 liest der Vergleich
    # Fall für Fall (bis 1.6.2 alle Fälle zugleich, Julia rund 4 GB und deshalb allein)
    add(vergleich("Python vergleich.py", o("py_ref.txt"), ["python3", "tests/werkzeuge/gleichlauf/vergleich.py"]), [b_py], gen)
    add(vergleich("Julia vergleich.jl", o("jl_ref.txt"), [*JULIA_VGL, "tests/werkzeuge/gleichlauf/vergleich.jl"]),
        [b_jl], gen, gruppe=JL, vorn=True)

    # 4b. R neu gegen den Katalog tests/<gruppe>/faelle (Byte für Byte; sonst tests/werkzeuge/erzeugen.py). Nur mit --full
    # und allen Bereichen: In der Teilmenge (--quick) ziehen manche Generatoren ihre zufälligen Eingaben in anderer Folge.
    if full and engine:
        add(S("R neu gegen tests/<gruppe>/faelle (faelle_diff.py)", o("faelle_diff.txt"),
              ["python3", "-I", "tests/werkzeuge/gleichlauf/faelle_diff.py", o("faelle")]), [], gen)

    # 5. Zufallsprüfungen (seit 1.3.0): Datumskern, slc_rbase-Kerne, Tarifkern mit R als Orakel; FUZZ_REF gegen die
    # abgelegte Referenz
    if engine or full:
        fz = o("fuzz")
        neu(fz)
        os.makedirs(os.path.join(fz, "date"))
        os.makedirs(os.path.join(fz, "rbase"))
        f = lambda *p: os.path.join(fz, *p)   # noqa: E731
        g = add(S("erzeugen date_fuzz (%d)" % n["date"], o("fz_date_gen.txt"),
                  ["Rscript", "tests/werkzeuge/gleichlauf/date_fuzz.R", f("date"), str(n["date"])]), [b_r])
        add(S("Python date_fuzz", o("fz_date_py.txt"), ["python3", "tests/werkzeuge/gleichlauf/date_fuzz_cmp.py", f("date")]), [g, b_py])
        add(S("Julia date_fuzz", o("fz_date_jl.txt"), [*JULIA_VGL, "tests/werkzeuge/gleichlauf/date_fuzz_cmp.jl", f("date")]),
            [g, b_jl], gruppe=JL)
        g = add(S("erzeugen rbase_fuzz (%d je Kern)" % n["rbase"], o("fz_rbase_gen.txt"),
                  ["Rscript", "tests/werkzeuge/gleichlauf/rbase_fuzz.R", f("rbase"), str(n["rbase"])]), [b_r])
        add(S("Python rbase_fuzz", o("fz_rbase_py.txt"), ["python3", "tests/werkzeuge/gleichlauf/rbase_fuzz_cmp.py", f("rbase")]), [g, b_py])
        add(S("Julia rbase_fuzz", o("fz_rbase_jl.txt"), [*JULIA_VGL, "tests/werkzeuge/gleichlauf/rbase_fuzz_cmp.jl", f("rbase")]),
            [g, b_jl], gruppe=JL)
        add(S("R tariff_fuzz (%d je Teil)" % n["tariff"], o("fz_tariff.txt"),
              ["Rscript", "tests/werkzeuge/gleichlauf/tariff_fuzz.R", str(n["tariff"]), "20261101"]), [b_r])
        # Zufallsfälle gegen die abgelegte Referenz (FUZZ_REF); fehlt sie oder passt sie nicht, scheitert der Schritt.
        # Python und Julia je ein Prozess für alle Referenzen (seit 1.6.3; Protokolle weiter je Name)
        refs = []
        for name, k_quick, k_full, seed, ref in FUZZ_REF:
            fassung = REFLIBS[ref][0]
            k = k_full if full else k_quick
            r_file = "tests/werkzeuge/gleichlauf/%s_fuzz.R" % name
            ref_gz, msg = ref_pruefen(ref, name, mode, k, seed)
            if ref_gz is None:
                note("FEHLER  %s_fuzz: %s" % (name, msg))
                fail()
                continue
            new_gz = f(name + "_new", name + "_fuzz.jsonl.gz")
            neu(f(name + "_new"))
            g = add(S("erzeugen %s_fuzz R neu (%d)" % (name, k), o("fz_%s_new.txt" % name),
                      ["Rscript", r_file, str(k), str(seed)], env={"SIMLEV_FAELLE_DIR": f(name + "_new")}), [b_r])
            add(S("Vergleich %s_fuzz R neu gegen R %s" % (name, fassung), o("fz_%s_r.txt" % name),
                  ["python3", "-I", "tests/werkzeuge/gleichlauf/sim_fuzz_cmp.py", ref_gz, new_gz]), [g])
            refs.append((name, fassung, ref_gz))
        if refs:
            add(vergleich_ref("Python", o("fz_py.txt"), ["python3", "tests/werkzeuge/gleichlauf/vergleich.py"], refs,
                              lambda name: o("fz_%s_py.txt" % name)), [b_py])
            add(vergleich_ref("Julia", o("fz_jl.txt"), [*JULIA_VGL, "tests/werkzeuge/gleichlauf/vergleich.jl"], refs,
                              lambda name: o("fz_%s_jl.txt" % name)), [b_jl], gruppe=JL, vorn=True)
    plan.run()

    # 6. Abdeckung der Exporte durch den Katalog (ohne Fall nur export_dashboard, schreibt eine Datei)
    z = lies_zeilen(o("exporte.txt")) if os.path.isfile(o("exporte.txt")) else []
    note("        " + (z[0] if z else ""))

    # 7. Zusammenfassung: in den Bericht die Ergebniszeilen je Protokoll, auf die Konsole nur die Gesamtzeilen
    note("")
    gruppen = [(p, re.compile(r"bitgleich|^Gesamt"), re.compile(r"^Gesamt")) for p in ("py_ref", "jl_ref")]
    namen = ZUSAMMENFASSUNG + ["fz_%s_%s" % (name, s) for name, *_ in FUZZ_REF for s in ("r", "py", "jl")]
    gruppen += [(p, MUSTER, re.compile(r"^Gesamt|^GESAMT")) for p in namen]
    for p, muster, gesamt in gruppen:
        if not os.path.isfile(o(p + ".txt")):
            continue
        note("== " + p)
        z = lies_zeilen(o(p + ".txt"))
        with open(rep, "ab") as h:
            h.writelines((x + "\n").encode("utf-8", "surrogateescape") for x in z if muster.search(x))
        sys.stdout.buffer.writelines(("   " + x + "\n").encode("utf-8", "surrogateescape") for x in z if gesamt.search(x))
        sys.stdout.buffer.flush()
    note("Laufzeit %d s" % int(time.time() - t_start))
    note("Gleichlauf: ABWEICHUNG oder Fehler (siehe oben)" if status else "Gleichlauf: R, Python und Julia gleich")
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
