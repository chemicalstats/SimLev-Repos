# REnv – Umgebungsschalter `SIMLEV_*`: die einzige Stelle, an der Julia sie liest oder setzt.
#
# Alle übrigen Stellen (Paket, Vorkompilierung, Tests, Werkzeuge) holen die Werte über diese
# Funktionen. Jede Funktion liest `ENV` bei jedem Aufruf neu; wann gelesen wird, bestimmt der
# Aufrufer (z. B. die Tests beim Laden, `_collate.jl` beim ersten Vergleich nach
# `collate_reset()`, `precompile.jl` beim Vorkompilieren).
#
# | Schalter                     | Zweck                                                          | Art         |
# |------------------------------|----------------------------------------------------------------|-------------|
# | SIMLEV_COLLATE               | Sortierung: icu:<Locale> (icu:root wie R unter C.UTF-8) oder C | Nutzer      |
# | SIMLEV_ICU                   | Pfad zur ICU-Bibliothek (libicui18n)                           | Nutzer      |
# | SIMLEV_LAX_NA                | 1: NA = NaN im Vergleich mit den Referenzfällen                | Prüfung     |
# | SIMLEV_STRICT_ZERO           | 0: -0 = +0 im Vergleich mit den Referenzfällen                 | Prüfung     |
# | SIMLEV_SKIP_PRECOMPILE       | 1: keine Arbeitslast beim Vorkompilieren                       | Entwicklung |
# | SIMLEV_SKIP_PRECOMPILE_EXT   | 1: Arbeitslast ohne die Erweiterungsmodule                     | Entwicklung |
# | SIMLEV_CXX                   | C++-Compiler für Pkg.build (deps/build.jl; seit 1.6.0, bis 1.5.2 SIMLEV_CC) | Bau |
# | SIMLEV_THREADS               | Threads der elementweisen Kerne (qt, pt; seit 1.6.0), höchstens und sonst Zahl der Prozessoren | Nutzer |
#
# Seit 1.0.0 entfallen SIMLEV_LAPACK (keine System-LAPACK) und
# SIMLEV_R_SYS_TIME (feste Uhr für gosolnp), SIMLEV_LEGACY_TESTS (Tests neu aufgebaut), seit 1.4.2
# SIMLEV_FULL_TESTS, SIMLEV_GOLDEN_DIR und SIMLEV_MODULE_DIR (Fälle bis 1.4.0; die Tests lesen SIMLEV_FAELLE_DIR).
# Seit 1.6.3 ohne die Konstante `SWITCHES` (ohne Leser; die Tabelle oben ist die Übersicht, wie in Python).
module REnv

# ── Nutzer ──────────────────────────────────────────────────────────────────
"`SIMLEV_COLLATE` (leer, wenn nicht gesetzt)."
collate() = get(ENV, "SIMLEV_COLLATE", "")
"`SIMLEV_ICU` (leer, wenn nicht gesetzt)."
icu_path() = get(ENV, "SIMLEV_ICU", "")

# ── Prüfung ─────────────────────────────────────────────────────────────────
"`SIMLEV_LAX_NA=1`: NA und NaN im Vergleich gleich (Voreinstellung: unterschieden)."
lax_na() = get(ENV, "SIMLEV_LAX_NA", "0") == "1"
"`SIMLEV_STRICT_ZERO` ungleich `0`: Vorzeichen der Null wird verglichen (Voreinstellung)."
strict_zero() = get(ENV, "SIMLEV_STRICT_ZERO", "1") != "0"
"Setzt `SIMLEV_COLLATE = value`, falls nicht gesetzt; `true`, wenn gesetzt wurde."
set_collate_default!(value = "icu:root") = haskey(ENV, "SIMLEV_COLLATE") ? false : (ENV["SIMLEV_COLLATE"] = value; true)

# ── Entwicklung ─────────────────────────────────────────────────────────────
"`SIMLEV_SKIP_PRECOMPILE=1`: keine Arbeitslast beim Vorkompilieren."
skip_precompile() = get(ENV, "SIMLEV_SKIP_PRECOMPILE", "0") == "1"
"`SIMLEV_SKIP_PRECOMPILE_EXT=1`: Arbeitslast ohne die Erweiterungsmodule."
skip_precompile_ext() = get(ENV, "SIMLEV_SKIP_PRECOMPILE_EXT", "0") == "1"

# ── Threads (seit 1.6.0) ────────────────────────────────────────────────────
"""`SIMLEV_THREADS` als ganze Zahl >= 1 (seit 1.6.4 nur ASCII-Ziffern, Entscheidungen 27, 65), sonst 0 (Höchstwert: Zahl
der Prozessoren); Begrenzung mit Hinweis in `SLib.nthreads` (seit 1.6.4, Entscheidung 41b); wie `.sl_nthreads` in R."""
function threads()
    v = strip(get(ENV, "SIMLEV_THREADS", ""), [' ', '\t', '\r', '\n'])   # "2.7", "0x10", "+3" wie andere Fehlwerte: 0
    n = !isempty(v) && all(c -> '0' <= c <= '9', v) ? tryparse(Int, v) : nothing
    return n === nothing || n < 1 || n >= 2^31 ? 0 : n
end

end # module
