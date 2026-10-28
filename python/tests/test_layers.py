"""Schichtentest: kein Modul von ``simlev`` importiert eine höhere Schicht.

Schichten (Anhang F des Entwicklungsdokuments): 0 R-Interna, 1 Daten und Strategie,
2 Engine, 3 Analysen, 4 Ausgabe. Das Paket selbst (``simlev/__init__.py``) steht als
Schnittstelle über allen Schichten.

Gelesen wird der Quelltext (``ast``), nicht der geladene Zustand: alle ``import``- und
``from … import``-Anweisungen, auch in Funktionen, dazu die späten Zugriffe
``_ext("modul", "name")`` und ``importlib.import_module("simlev.…")`` mit festem Text.
Erlaubt sind Importe in dieselbe oder eine tiefere Schicht. Bekannte Ausnahmen stehen
mit Begründung in ``KNOWN``; eine neue Abweichung lässt den Test scheitern, ebenso eine
Ausnahme, die es nicht mehr gibt (dann aus ``KNOWN`` streichen).
"""
import ast
import os
import re

PKG = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "simlev")

TOP = 5   # Paketschnittstelle simlev/__init__.py

# Modul (ohne "simlev.") -> Schicht; alle Module unter simlev._r sind Schicht 0.
LAYERS = {
    # 0 R-Interna: dazu die C-Erweiterung mit den gemeinsamen Kernen von R und Python
    # (Etappe 7.3a, gebaut aus python/src/; importiert nichts, geladen von _r.env.ext())
    "_ext": 0,
    # 1 Daten und Strategie: Eingaben der Simulation (Reihen, Strategie, Signale, Tarif)
    "config": 1, "data_prep": 1, "backcast": 1, "bonds": 1, "signals": 1, "_signals_core": 1,
    "trigger": 1, "_tax_tariff": 1, "_dates": 1,
    # 2 Engine
    "engine": 2, "_sim_base": 2, "_sim_phases": 2, "_sim_loop": 2, "_sim_evaluate": 2, "_core": 2,
    "_sim_blocks": 2,   # Bausteine von simulation(): nutzen Engine-Helfer (_sim_base) und Daten-Schicht (config, _tax_tariff)
    "result": 2,
    "wrapper": 2,   # Fonds-Wrapper (Etappe 6.5c): rechnet den Anteilswert mit simulation()
    # 3 Analysen (je ein Modul, Kerne bei ihrem Modul)
    "bootstrap": 3, "_bootstrap_core": 3, "ms_garch": 3, "withdrawal": 3, "_withdrawal_core": 3,
    "dependence": 3, "_dependence_core": 3, "regimes": 3, "scenarios": 3, "optimize": 3,
    "_optimize_core": 3, "tactical": 3, "deep_analysis": 3, "planning": 3, "analysis_tests": 3,
    "overfitting": 3, "param_search": 3, "sensitivity": 3,
    # 4 Ausgabe
    "svg": 4, "dashboard": 4,
    # Paketschnittstelle
    "": TOP,
}

# (Modul, importiertes Modul) -> Begründung. Stand: Etappe 4.4; nicht repariert.
_PLOT = ("plot-Methode: die Grafikbausteine (_plot_method, _res_*/_ana_*/_grid_*/_alloc_*, "
         "_jl_*-Hilfen) liegen in svg (Schicht 4), die plot-Methoden beim Objekt")
KNOWN = {
    ("_r.reftree", ""): "Prüfwerkzeug der Referenzfälle: führt den Fallcode gegen das ganze Paket aus",
    ("config", "engine"): "_to_date nutzt _as_date der Engine (_sim_base, über engine), in der Funktion",
    ("result", "dashboard"): "plot(SimLevResult) ist plot_dashboard",
    ("result", "svg"): _PLOT,
    **{(m, "svg"): _PLOT for m in (
        "backcast", "bootstrap", "withdrawal", "dependence", "regimes", "optimize", "tactical",
        "deep_analysis", "planning", "analysis_tests", "overfitting", "param_search", "sensitivity")},
}


# C-Erweiterungen (ohne Python-Quelle; ob gebaut oder nicht): zählen als Module ohne eigene Importe
EXTENSIONS = ("_ext",)


def _modules():
    out = {m: None for m in EXTENSIONS}
    for dp, dn, fn in os.walk(PKG):
        dn[:] = [d for d in dn if d != "__pycache__"]
        for f in fn:
            if f.endswith(".py"):
                rel = os.path.relpath(os.path.join(dp, f), PKG)[:-3].replace(os.sep, ".")
                out["" if rel == "__init__" else rel.removesuffix(".__init__")] = os.path.join(dp, f)
    return out


def _layer(mod):
    return 0 if mod == "_r" or mod.startswith("_r.") else LAYERS[mod]


def _deps(mod, path, mods):
    """Importierte Module von ``mod`` (ohne "simlev.", "" = Paket) mit Zeilennummer."""
    src = open(path, encoding="utf-8").read()
    pkg = mod.rsplit(".", 1)[0] if "." in mod else ""
    if os.path.basename(path) == "__init__.py":
        pkg = mod
    out = []

    def add(full, line):
        if full == "simlev" or full.startswith("simlev."):
            m = full[len("simlev."):] if full != "simlev" else ""
            while m and m not in mods:          # Name in einem Modul -> das Modul
                m = m.rsplit(".", 1)[0] if "." in m else ""
            if m != mod:
                out.append((m, line))

    for n in ast.walk(ast.parse(src)):
        if isinstance(n, ast.Import):
            for a in n.names:
                add(a.name, n.lineno)
        elif isinstance(n, ast.ImportFrom):
            if n.level:
                base = ["simlev"] + ([p for p in pkg.split(".") if p])
                base = base[:len(base) - (n.level - 1)] if n.level > 1 else base
                full = ".".join(base + ([n.module] if n.module else []))
            else:
                full = n.module or ""
            for a in n.names:                    # from simlev import _core: Untermodul
                sub = full + "." + a.name
                add(sub if sub[len("simlev."):] in mods else full, n.lineno)
    for m in re.finditer(r'\b_ext\(\s*"(\w+)"', src):
        add("simlev." + m.group(1), src.count("\n", 0, m.start()) + 1)
    for m in re.finditer(r'import_module\(\s*"(simlev(?:\.\w+)*)"\s*\)', src):
        add(m.group(1), src.count("\n", 0, m.start()) + 1)
    return out


def _violations():
    mods = _modules()
    found = {}
    for mod, path in sorted(mods.items()):
        if path is None:                         # C-Erweiterung
            continue
        for dep, line in _deps(mod, path, mods):
            if _layer(dep) > _layer(mod):
                found.setdefault((mod, dep), []).append(line)
    return found


def test_alle_module_zugeordnet():
    mods = {m for m in _modules() if not (m == "_r" or m.startswith("_r."))}
    assert sorted(mods - set(LAYERS)) == [], "Schicht fehlt in LAYERS"
    assert sorted(set(LAYERS) - mods) == [], "Modul aus LAYERS gibt es nicht mehr"


def test_keine_importe_in_hoehere_schichten():
    neu = {k: v for k, v in _violations().items() if k not in KNOWN}
    msg = ["simlev.%s (Schicht %d) importiert simlev.%s (Schicht %d), Zeile %s"
           % (m, _layer(m), d or "", _layer(d), ", ".join(map(str, ls))) for (m, d), ls in sorted(neu.items())]
    assert not neu, "\n".join(msg)


def test_bekannte_ausnahmen_aktuell():
    alt = sorted(set(KNOWN) - set(_violations()))
    assert not alt, "Ausnahme besteht nicht mehr, aus KNOWN streichen: %s" % alt


def test_schalter_nur_in_env():
    """Umgebungsschalter SIMLEV_* liest und setzt nur simlev/_r/env.py (Etappe 4.5)."""
    base = os.path.dirname(PKG)
    env = os.path.join(PKG, "_r", "env.py")
    pat = re.compile(r"""(environ|getenv)\b[^\n]*["']SIMLEV_""")
    hits = []
    for sub in ("simlev", "tests", "tools"):
        for dp, dn, fn in os.walk(os.path.join(base, sub)):
            dn[:] = [d for d in dn if d != "__pycache__"]
            for f in fn:
                p = os.path.join(dp, f)
                if f.endswith(".py") and os.path.abspath(p) != os.path.abspath(env):
                    for i, ln in enumerate(open(p, encoding="utf-8"), 1):
                        if pat.search(ln):
                            hits.append("%s:%d" % (os.path.relpath(p, base), i))
    assert not hits, "SIMLEV_* außerhalb von simlev/_r/env.py: " + ", ".join(hits)


def test_analysemodule_erst_bei_bedarf():
    """``import simlev`` lädt die Analysemodule (Schicht 3) nicht; der erste Zugriff lädt sie (4.7)."""
    import subprocess
    import sys
    code = (
        "import sys, types, simlev\n"
        "lazy = [m for m, l in __import__('test_layers').LAYERS.items() if l == 3]\n"
        "early = [m for m in lazy if 'simlev.' + m in sys.modules]\n"
        "d0 = dir(simlev)\n"
        "vals = [getattr(simlev, n) for n in simlev.__all__]\n"
        "assert dir(simlev) == d0, set(dir(simlev)) ^ set(d0)\n"
        "assert all(isinstance(getattr(simlev, m), types.ModuleType) and callable(getattr(simlev, m))\n"
        "           for m in ('backcast', 'bootstrap', 'param_search'))\n"
        "assert isinstance(simlev.deep_analysis, types.ModuleType) and not callable(simlev.deep_analysis)\n"
        "from simlev import SimLevHMM, bootstrap_study\n"
        "assert SimLevHMM.__module__ == 'simlev.regimes' and bootstrap_study is simlev.bootstrap.bootstrap_study\n"
        "print(','.join(early))\n")
    here = os.path.dirname(os.path.abspath(__file__))
    r = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True,
                       env=dict(os.environ, PYTHONPATH=os.pathsep.join([os.path.dirname(PKG), here])))
    assert r.returncode == 0, r.stderr
    assert r.stdout.strip() == "", "beim Import geladen: " + r.stdout
