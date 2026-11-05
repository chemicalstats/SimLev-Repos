#!/usr/bin/env python3
# tests/werkzeuge/gleichlauf/run.py – Gleichlaufprüfung (seit 1.0.0; seit 1.4.1 unter tests/; bis 1.5.1 run.sh):
# erzeugt die Referenzfälle mit dem aktuellen R neu – alle Fälle der Generatoren, nicht nur die im Katalog abgelegten –
# und vergleicht Python und Julia streng dagegen (NA != NaN, Vorzeichen der Null, Ausgaben, Warnungen).
#
#   tests/werkzeuge/gleichlauf/run.py [--quick | --full] [--out ORDNER] [--no-build] [--ref KENNUNG] [bereich ...]
#
#   --quick     jede 20. Fall-Kennung (Prüfsumme, SIMLEV_GEN_SUBSET=20), kleine Engine-Läufe und kleine
#               Zufallsprüfungen (Standard)
#   --full      alle Fälle, Engine-Läufe wie im Katalog (500 bzw. 1000 Zufallsfälle), volle Zufallsprüfungen
#               und faelle_diff: die neu erzeugten Katalogdateien müssen Byte für Byte tests/<gruppe>/faelle entsprechen
#   --out DIR   Arbeitsordner (Standard tests/werkzeuge/gleichlauf/out; relativ zur Repo-Wurzel); darin rlib/, faelle/
#               (Auswahl wie im Katalog), faelle/alle/ (alle Fälle), cases/, stress/, fuzz/, Protokolle *.txt und bericht.txt
#   --no-build  R, Python und Julia nicht neu bauen (R-Bibliothek DIR/rlib muss bestehen)
#   --ref K     (seit 1.6.0) alle Zufallsprüfungen aus FUZZ_REF gegen die Referenz K aus REFLIBS (z. B. 152) statt
#               gegen ihre eigene; Beleg der Bitgleichheit eines Umbaus gegen die letzte Fassung
#   bereich ... nur diese Generatoren tests/gleichlauf/erzeugen/<bereich>.R (engine mit Engine-Läufen)
#
# Schritte: 1 bauen (R CMD INSTALL --preclean, Python build_ext --inplace --force, Julia Pkg.build), core/sync.py --check;
# 2 Zufallsprüfung der Engine tests/werkzeuge/zufall/engine_faelle.R und engine_stress.R (nur hier, nichts abgelegt;
# packen.py -> faelle/alle/zufall_engine); 3 Bereiche erzeugen (SIMLEV_GEN_ALLE=1); 3b Breitenprüfung: die bisherigen
# Einzelfälle der Bereiche (tests/werkzeuge/breite/<bereich>.R, nichts abgelegt -> faelle/alle/breite_<bereich>);
# 4 Python und Julia gegen faelle/alle (tests/werkzeuge/gleichlauf/vergleich.{py,jl}); 4b faelle_diff (nur --full; in
# der Teilmenge ziehen manche Generatoren ihre Eingaben in anderer Folge); 5 Zufallsprüfungen mit R als Orakel (ohne
# Bereichsliste immer, mit Liste nur bei --full), Fälle werden nicht abgelegt:
#   date_fuzz.R + _cmp.{py,jl} Datumsformat (auch Schalter, %OS), as.Date  quick 500, full 10000 Formate (+ Hälfte %OS)
#   rbase_fuzz.R + _cmp.{py,jl} Kerne core/slc_rbase*.cpp (Summen, order …)  quick 200, full 5000 Fälle je Kern
#   tariff_fuzz.R (1.3.0)       Tarifkern core/tariff_core_impl.h gegen      quick 200, full 10000 Fälle je Teil
#                              .tariff_income_tax/.tariff_soli/.tariff_close (nur R; Kern in allen Sprachen gleich)
#   sim_fuzz.R (1.4.0)         simulation() mit allen Bausteinen; Referenz  quick 300, full 2000 Fälle
#                              aus R 1.3.0 (Pflicht: SIMLEV_FUZZ_REFLIB, Standard /home/claude/rlib130), dagegen
#                              R neu (sim_fuzz_cmp.py), Python und Julia (vergleich.{py,jl}); bitgleich mit
#                              Ausgabe, print(), Warnungen und Fehlertexten
#   sched_fuzz.R (1.4.0)       Datums-Fuzz der Vorbereitung im Kern         quick 300, full 2000 Fälle
#                              (core/prepare_core_impl.h); Referenz aus R 1.3.0 wie sim_fuzz
#   metric_fuzz.R (1.4.0)       Fuzz der Kennzahlen (core/evaluate_core_impl.h) quick 300, full 2000 Fälle
#                              .xirr_rate direkt und simulation(); Referenz aus R 1.3.0 wie sim_fuzz
#   approx_fuzz.R (1.5.0)      approx/approxfun (core/slc_rbase.cpp, sl_r_approx) quick 300, full 2000 Fälle
#                              und planning_goal; Referenz aus R 1.4.2 (Pflicht: SIMLEV_FUZZ_REFLIB142, Standard
#                              /home/claude/rlib142), dagegen R neu, Python und Julia wie sim_fuzz
#   wd_fuzz.R (1.5.0)          Auswertung der Entnahme (core/withdrawal_core_impl.h) quick 300, full 2000 Fälle
#                              withdrawal_perfect_rate, withdrawal_simulation (Horizont, Steuer, Tarifweg),
#                              withdrawal_max_rate; Referenz aus R 1.4.2 wie approx_fuzz
#   hmm_fuzz.R (1.5.0)         regime_hmm (HMM-EM im Kern, hmm_em)          quick 300, full 2000 Fälle
#   goal_fuzz.R (1.5.0)        planning_goal (Rekursion im Kern, goal_dp)   quick 300, full 2000 Fälle
#   pbo_fuzz.R (1.5.0)         overfit_pbo (CSCV im Kern, pbo_cscv)         quick 300, full 2000 Fälle
#                              alle drei mit Referenz aus R 1.4.2 wie approx_fuzz (pbo_fuzz seit 1.5.1 auch mit
#                              +-Inf und S >= 34)
#   nav_fuzz.R (1.5.1)         wrapper_nav (NAV im Kern, wrapper_nav_core)  quick 300, full 2000 Fälle
#   rolling_fuzz.R (1.5.1)     portfolio_rolling, result_analysis,          quick 300, full 2000 Fälle
#                              Periodenrenditen (Datum ganzzahlig, Fenster)
#   study_fuzz.R (1.5.1)       Studien über simulation() (Prüf-Cache je     quick 300, full 2000 Fälle
#                              Studie; r_conds: alle Meldungen in Reihenfolge)
#                              alle drei mit Referenz aus R 1.5.0 (Pflicht: SIMLEV_FUZZ_REFLIB150, Standard
#                              /home/claude/rlib150), dagegen R neu, Python und Julia wie sim_fuzz
#   libm_fuzz.R (1.5.2)        libm elementweise (Python in C), Ränge,      quick 300, full 2000 Fälle
#                              rebalance_trigger, doppelte Tage, Entropy Pooling; Referenz aus R 1.5.1 (Pflicht:
#                              SIMLEV_FUZZ_REFLIB151, Standard /home/claude/rlib151), dagegen R neu, Python, Julia
#   clust_fuzz.R, vec_fuzz.R, cor_fuzz.R, padj_fuzz.R, fmt_fuzz.R (1.6.0)   in den Kern verlagerte R-Nachbildungen:
#                              dist/hclust, cut/seq/median/sort, cor/cov2cor/scale, p.adjust/ecdf, sprintf/formatC/format/
#                              round; je quick 300, full 2000 Fälle; Referenz aus R 1.5.2 (Pflicht: SIMLEV_FUZZ_REFLIB152,
#                              Standard /home/claude/rlib152), dagegen R neu, Python, Julia
# 6 Abdeckung der Exporte durch die Katalogfälle (exporte.py). Ende 1, wenn eine Sprache abweicht, ein Schritt
# scheitert, R vom Katalog abweicht oder core/sync.py --check abweicht. Läufe nie parallel im selben Arbeitsordner.
# Python 3.10 oder neuer, nur Standardbibliothek.
#
# Neue Zufallsprüfung mit Referenz aus einer älteren R-Fassung (Muster wie sim_fuzz): eine Zeile in FUZZ_REF
# (Name, Fallzahl quick/full, Startwert, Referenz); Schritte, Protokolle fz_<name>_{ref,new,r,py,jl}.txt und die
# Zusammenfassung folgen daraus. Eine neue Referenzfassung: Eintrag in REFLIBS. Andere Schritte: in main() an der
# passenden Stelle mit step(...), die Protokolle dann in ZUSAMMENFASSUNG eintragen.
import datetime
import glob
import os
import re
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
HILFEN = ("ref_tools", "szenario_tools", "blocks_from_flat")   # in tests/gleichlauf/erzeugen, keine Generatoren

# Fallzahlen je Modus: Teilmenge der Kennungen, Engine-Läufe (engine_faelle, engine_stress), Zufallsprüfungen
MODUS = {
    "quick": dict(sub=20, ng=10, ns=20, date=500, rbase=200, tariff=200),
    "full": dict(sub=1, ng=500, ns=1000, date=10000, rbase=5000, tariff=10000),
}
# Referenzbibliotheken älterer R-Fassungen (Pflicht für FUZZ_REF): Kennung -> (Fassung, Umgebungsvariable, Standard)
REFLIBS = {
    "130": ("1.3.0", "SIMLEV_FUZZ_REFLIB", "/home/claude/rlib130"),
    "142": ("1.4.2", "SIMLEV_FUZZ_REFLIB142", "/home/claude/rlib142"),
    "150": ("1.5.0", "SIMLEV_FUZZ_REFLIB150", "/home/claude/rlib150"),
    "151": ("1.5.1", "SIMLEV_FUZZ_REFLIB151", "/home/claude/rlib151"),
    "152": ("1.5.2", "SIMLEV_FUZZ_REFLIB152", "/home/claude/rlib152"),
}
# Zufallsprüfungen mit Referenz aus einer älteren R-Fassung, in dieser Reihenfolge:
# (Name: tests/werkzeuge/gleichlauf/<name>_fuzz.R, Fälle quick, Fälle full, Startwert, Referenz aus REFLIBS)
FUZZ_REF = [
    ("sim", 300, 2000, 20261101, "130"),      # simulation() (seit 1.4.0)
    ("sched", 300, 2000, 20261102, "130"),    # Termine, Kalender, Flags der Vorbereitung im Kern (seit 1.4.0)
    ("metric", 300, 2000, 20261103, "130"),   # Kennzahlen, Auswertung im Kern (seit 1.4.0)
    # in 1.5.0 in den Kern verlagerte Teile (approx, Entnahme-Auswertung, HMM-EM, Zielplanung, CSCV)
    ("approx", 300, 2000, 20261104, "142"),
    ("wd", 300, 2000, 20261105, "142"),
    ("hmm", 300, 2000, 20261106, "142"),
    ("goal", 300, 2000, 20261107, "142"),
    ("pbo", 300, 2000, 20261108, "142"),
    ("nav", 300, 2000, 20261109, "150"),
    ("rolling", 300, 2000, 20261110, "150"),
    ("study", 300, 2000, 20261111, "150"),
    ("libm", 300, 2000, 20261112, "151"),     # in 1.5.2 schneller in Python (libm in C, Ränge, Dubletten, Trigger)
    # in 1.6.0 (K38a) in den Kern verlagert bzw. beschleunigt: Kalenderauffüllung (cal), Pfadaufbau im Bootstrap (boot),
    # t-Copula, optimize und qt/pt auf Threads (copula), Momentum-Scores (mom), Eigenzerlegung (eigen)
    ("cal", 300, 2000, 20261113, "152"),
    ("boot", 300, 2000, 20261114, "152"),
    ("copula", 300, 2000, 20261115, "152"),
    ("mom", 300, 2000, 20261116, "152"),
    ("eigen", 300, 2000, 20261117, "152"),
    # in 1.6.0 in den Kern verlagerte R-Nachbildungen (K38b; approx_fuzz.R erweitert um filter und regularize.values)
    ("clust", 300, 2000, 20261118, "152"),    # dist, hclust (core/slc_rbase_clust.cpp)
    ("vec", 300, 2000, 20261119, "152"),      # cut/.bincode, seq.int, median, sort (core/slc_rbase_vec.cpp)
    ("cor", 300, 2000, 20261120, "152"),      # cor/cov mit Rängen, cov2cor, scale (core/slc_rbase_cor.cpp)
    ("padj", 300, 2000, 20261121, "152"),     # p.adjust, ecdf (core/slc_rbase_models.cpp)
    ("fmt", 300, 2000, 20261122, "152"),      # sprintf, formatC, format, round/signif (core/slc_rbase_fmt.cpp)
]
# Protokolle der Zusammenfassung (Schritt 7) mit Zeilen nach MUSTER; danach je FUZZ_REF fz_<name>_{r,py,jl}
ZUSAMMENFASSUNG = ["faelle_diff", "fz_date_py", "fz_date_jl", "fz_rbase_py", "fz_rbase_jl", "fz_tariff"]
MUSTER = re.compile(r"textgleich|gleich$|gleich \(|^Gesamt|^GESAMT|^sim_fuzz|^[a-z0-9_]+ +[0-9]+ +[0-9]+/[0-9]+")

status = 0
rep = None


def note(text):
    """Zeile auf die Konsole und in bericht.txt."""
    b = (text + "\n").encode("utf-8", "surrogateescape")
    sys.stdout.buffer.write(b)
    sys.stdout.buffer.flush()
    with open(rep, "ab") as h:
        h.write(b)


def step(name, log, cmd, env=None, cwd=None):
    """Schritt mit Protokoll log (stdout und stderr); Ergebniszeile in den Bericht; False und status = 1 bei Fehler."""
    global status
    t0 = int(time.time())
    with open(log, "wb") as h:
        try:
            rc = subprocess.run(cmd, stdout=h, stderr=subprocess.STDOUT, cwd=cwd,
                                env=None if env is None else {**os.environ, **env}).returncode
        except OSError as e:   # Programm fehlt (Shell: Rückgabewert 127, Meldung im Protokoll)
            h.write(("run.py: %s: %s\n" % (cmd[0], e.strerror)).encode())
            rc = 127
    if rc == 0:
        note("ok      %s (%d s)" % (name, int(time.time()) - t0))
        return True
    note("FEHLER  %s (%d s; Protokoll %s)" % (name, int(time.time()) - t0, log))
    status = 1
    return False


def lies_zeilen(path):
    with open(path, encoding="utf-8", errors="surrogateescape", newline="") as h:
        z = h.read().split("\n")
    return z[:-1] if z and z[-1] == "" else z


def neu(*ordner):
    """Ordner leeren und neu anlegen (rm -rf; mkdir -p)."""
    for d in ordner:
        shutil.rmtree(d, ignore_errors=True)
        os.makedirs(d, exist_ok=True)


def main(argv):
    global rep, status
    os.environ["LC_ALL"] = "C.UTF-8"
    os.chdir(ROOT)
    mode, out, build, mods, ref_all = "quick", os.path.join(HERE, "out"), True, [], None
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--quick":
            mode = "quick"
        elif a == "--full":
            mode = "full"
        elif a == "--out":
            if i + 1 >= len(argv):
                print("run.py: --out ohne Ordner", file=sys.stderr)
                return 2
            out = argv[i + 1]
            i += 1
        elif a == "--no-build":
            build = False
        elif a == "--ref":
            if i + 1 >= len(argv) or argv[i + 1] not in REFLIBS:
                print("run.py: --ref ohne Kennung aus REFLIBS (%s)" % ", ".join(REFLIBS), file=sys.stderr)
                return 2
            ref_all = argv[i + 1]
            i += 1
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
    open(rep, "wb").close()
    o = lambda *p: os.path.join(out, *p)   # noqa: E731

    note("Gleichlauf %s (%s), Arbeitsordner %s" % (mode, datetime.datetime.now().astimezone().isoformat(timespec="seconds"), out))
    # 1. Bauen
    if build:
        os.makedirs(o("rlib"), exist_ok=True)
        # --preclean: make kennt die Header-Abhaengigkeiten nicht
        step("R CMD INSTALL", o("r_install.txt"), ["R", "CMD", "INSTALL", "--preclean", "-l", o("rlib"), "r"])
        step("Python build_ext --inplace", o("py_build.txt"), ["python3", "setup.py", "build_ext", "--inplace", "--force"], cwd="python")
        step("Julia Pkg.build", o("jl_build.txt"), ["julia", "--project=julia", "-e", "using Pkg; Pkg.build()"])
    step("core/sync.py --check", o("core_sync.txt"), ["python3", "core/sync.py", "--check"])

    # 2. Engine-Läufe (Engine-Format; alle Zufallsfälle werden verglichen, im Katalog liegt die Auswahl)
    os.environ["R_LIBS"] = o("rlib")
    engine = not mods
    if engine:
        mods = [m for m in (os.path.basename(g)[:-2] for g in sorted(glob.glob("tests/gleichlauf/erzeugen/*.R"))) if m not in HILFEN]
    for d in ("cases", "stress", "faelle"):
        shutil.rmtree(o(d), ignore_errors=True)
    os.makedirs(o("faelle"), exist_ok=True)
    if "engine" in mods:   # Zufallsprüfung der Engine, nichts abgelegt
        step("erzeugen Engine engine_faelle.R (%d)" % n["ng"], o("gen_engine_faelle.txt"),
             ["Rscript", "tests/werkzeuge/zufall/engine_faelle.R", o("cases"), str(n["ng"]), "4711"])
        step("erzeugen Engine engine_stress.R (%d)" % n["ns"], o("gen_engine_stress.txt"),
             ["Rscript", "tests/werkzeuge/zufall/engine_stress.R", o("stress"), str(n["ns"]), "90210"])
        os.makedirs(o("faelle", "alle"), exist_ok=True)
        step("packen Engine-Zufallsfälle", o("zufall_packen.txt"),
             ["python3", "-I", "tests/werkzeuge/zufall/packen.py", out, o("faelle", "alle", "zufall_engine.jsonl.gz")])

    # 3. Bereiche erzeugen: Auswahl nach faelle/, alle Fälle nach faelle/alle/
    gen = []
    for m in mods:
        if not os.path.isfile("tests/gleichlauf/erzeugen/%s.R" % m):
            note("FEHLER  Generator tests/gleichlauf/erzeugen/%s.R fehlt" % m)
            status = 1
            continue
        if step("erzeugen " + m, o("gen_%s.txt" % m), ["Rscript", "tests/gleichlauf/erzeugen/%s.R" % m],
                env={"SIMLEV_FAELLE_DIR": o("faelle"), "SIMLEV_GEN_SUBSET": str(n["sub"]), "SIMLEV_GEN_ALLE": "1"}):
            gen.append(m)

    # 3b. Breitenprüfung (seit 1.4.2): die bisherigen Einzelfälle der Bereiche (tests/werkzeuge/breite/<bereich>.R;
    # gleiche Zufallsfolge wie bis 1.4.1), nur hier verglichen, nichts abgelegt
    for m in mods:
        if not os.path.isfile("tests/werkzeuge/breite/%s.R" % m):
            continue
        if step("erzeugen Breite " + m, o("gen_breite_%s.txt" % m), ["Rscript", "tests/werkzeuge/breite/%s.R" % m],
                env={"SIMLEV_FAELLE_DIR": o("faelle", "alle"), "SIMLEV_GEN_SUBSET": str(n["sub"])}):
            gen.append("breite_" + m)

    # 4. Python und Julia gegen alle neu erzeugten Fälle
    cmp = [p for p in (o("faelle", "alle", m + ".jsonl.gz") for m in gen + ["zufall_engine"]) if os.path.isfile(p)]
    if cmp:
        step("Python vergleich.py", o("py_ref.txt"), ["python3", "tests/werkzeuge/gleichlauf/vergleich.py", *cmp])
        step("Julia vergleich.jl", o("jl_ref.txt"), ["julia", "--project=julia", "tests/werkzeuge/gleichlauf/vergleich.jl", *cmp])

    # 4b. R neu gegen den Katalog tests/<gruppe>/faelle (Byte für Byte; sonst tests/werkzeuge/erzeugen.py). Nur mit --full
    # und allen Bereichen: In der Teilmenge (--quick) ziehen manche Generatoren ihre zufälligen Eingaben in anderer Folge.
    if full and engine:
        step("R neu gegen tests/<gruppe>/faelle (faelle_diff.py)", o("faelle_diff.txt"),
             ["python3", "-I", "tests/werkzeuge/gleichlauf/faelle_diff.py", o("faelle")])

    # 5. Zufallsprüfungen (seit 1.3.0): Datumskern, slc_rbase-Kerne, Tarifkern, simulation(); R als Orakel
    if engine or full:
        fz = o("fuzz")
        neu(fz)
        os.makedirs(os.path.join(fz, "date"))
        os.makedirs(os.path.join(fz, "rbase"))
        f = lambda *p: os.path.join(fz, *p)   # noqa: E731
        if step("erzeugen date_fuzz (%d)" % n["date"], o("fz_date_gen.txt"),
                ["Rscript", "tests/werkzeuge/gleichlauf/date_fuzz.R", f("date"), str(n["date"])]):
            step("Python date_fuzz", o("fz_date_py.txt"), ["python3", "tests/werkzeuge/gleichlauf/date_fuzz_cmp.py", f("date")])
            step("Julia date_fuzz", o("fz_date_jl.txt"), ["julia", "--project=julia", "tests/werkzeuge/gleichlauf/date_fuzz_cmp.jl", f("date")])
        if step("erzeugen rbase_fuzz (%d je Kern)" % n["rbase"], o("fz_rbase_gen.txt"),
                ["Rscript", "tests/werkzeuge/gleichlauf/rbase_fuzz.R", f("rbase"), str(n["rbase"])]):
            step("Python rbase_fuzz", o("fz_rbase_py.txt"), ["python3", "tests/werkzeuge/gleichlauf/rbase_fuzz_cmp.py", f("rbase")])
            step("Julia rbase_fuzz", o("fz_rbase_jl.txt"), ["julia", "--project=julia", "tests/werkzeuge/gleichlauf/rbase_fuzz_cmp.jl", f("rbase")])
        step("R tariff_fuzz (%d je Teil)" % n["tariff"], o("fz_tariff.txt"),
             ["Rscript", "tests/werkzeuge/gleichlauf/tariff_fuzz.R", str(n["tariff"]), "20261101"])
        # Zufallsfälle mit Referenz aus einer älteren R-Fassung (FUZZ_REF); fehlt die Referenz, scheitert der Schritt
        for name, k_quick, k_full, seed, ref in FUZZ_REF:
            fassung, var, standard = REFLIBS[ref_all or ref]
            reflib = os.environ.get(var) or standard
            k = str(k_full if full else k_quick)
            r_file = "tests/werkzeuge/gleichlauf/%s_fuzz.R" % name
            ref_gz, new_gz = f(name + "_ref", name + "_fuzz.jsonl.gz"), f(name + "_new", name + "_fuzz.jsonl.gz")
            neu(f(name + "_ref"), f(name + "_new"))
            if not os.path.isdir(os.path.join(reflib, "SimLev")):
                note("FEHLER  %s_fuzz: Referenzbibliothek R %s fehlt (%s; %s)" % (name, fassung, reflib, var))
                status = 1
            elif (step("erzeugen %s_fuzz Referenz R %s (%s)" % (name, fassung, k), o("fz_%s_ref.txt" % name),
                       ["Rscript", r_file, k, str(seed)], env={"R_LIBS": reflib, "SIMLEV_FAELLE_DIR": f(name + "_ref")})
                  and step("erzeugen %s_fuzz R neu (%s)" % (name, k), o("fz_%s_new.txt" % name),
                           ["Rscript", r_file, k, str(seed)], env={"SIMLEV_FAELLE_DIR": f(name + "_new")})):
                step("Vergleich %s_fuzz R neu gegen R %s" % (name, fassung), o("fz_%s_r.txt" % name),
                     ["python3", "-I", "tests/werkzeuge/gleichlauf/sim_fuzz_cmp.py", ref_gz, new_gz])
                step("Python %s_fuzz gegen R %s" % (name, fassung), o("fz_%s_py.txt" % name),
                     ["python3", "tests/werkzeuge/gleichlauf/vergleich.py", ref_gz])
                step("Julia %s_fuzz gegen R %s" % (name, fassung), o("fz_%s_jl.txt" % name),
                     ["julia", "--project=julia", "tests/werkzeuge/gleichlauf/vergleich.jl", ref_gz])

    # 6. Abdeckung der Exporte durch den Katalog (Bericht; ohne Fall nur export_dashboard, schreibt eine Datei)
    with open(o("exporte.txt"), "wb") as h:
        try:
            subprocess.run(["python3", "tests/werkzeuge/gleichlauf/exporte.py"], stdout=h, stderr=subprocess.STDOUT)
        except OSError as e:
            h.write(("run.py: python3: %s\n" % e.strerror).encode())
    z = lies_zeilen(o("exporte.txt"))
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
    note("Gleichlauf: ABWEICHUNG oder Fehler (siehe oben)" if status else "Gleichlauf: R, Python und Julia gleich")
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
