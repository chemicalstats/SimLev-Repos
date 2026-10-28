# REnv – Umgebungsschalter `SIMLEV_*`: die einzige Stelle, an der Julia sie liest oder setzt.
#
# Alle übrigen Stellen (Paket, Vorkompilierung, Tests, Werkzeuge) holen die Werte über diese
# Funktionen. Jede Funktion liest `ENV` bei jedem Aufruf neu; wann gelesen wird, bestimmt der
# Aufrufer (z. B. `reftree.jl` beim Laden, `_collate.jl` beim ersten Vergleich nach
# `collate_reset()`, `precompile.jl` beim Vorkompilieren).
#
# | Schalter                     | Zweck                                                          | Art         |
# |------------------------------|----------------------------------------------------------------|-------------|
# | SIMLEV_COLLATE               | Sortierung: icu:<Locale> (icu:root wie R unter C.UTF-8) oder C | Nutzer      |
# | SIMLEV_ICU                   | Pfad zur ICU-Bibliothek (libicui18n)                           | Nutzer      |
# | SIMLEV_LAX_NA                | 1: NA = NaN im Vergleich mit den Referenzfällen                | Prüfung     |
# | SIMLEV_STRICT_ZERO           | 0: -0 = +0 im Vergleich mit den Referenzfällen                 | Prüfung     |
# | SIMLEV_FULL_TESTS            | 1: Pkg.test() prüft alle Modul-Fälle statt einer Auswahl       | Prüfung     |
# | SIMLEV_GOLDEN_DIR            | anderer Wurzelordner der Engine-Fälle (cases/, extra/)         | Prüfung     |
# | SIMLEV_SKIP_PRECOMPILE       | 1: keine Arbeitslast beim Vorkompilieren                       | Entwicklung |
# | SIMLEV_SKIP_PRECOMPILE_EXT   | 1: Arbeitslast ohne die Erweiterungsmodule                     | Entwicklung |
# | SIMLEV_LEGACY_TESTS          | 1: alte Tests und Referenzvergleiche laufen (Etappe 9: sonst aus) | Prüfung     |
# | SIMLEV_MODULE_DIR            | anderer Ordner der Modul-Fälle (compare_reference.jl, Gleichlauf) | Prüfung     |
# | SIMLEV_CC                    | C-Compiler für Pkg.build (gelesen in deps/build.jl, Etappe 9.1)  | Bau         |
#
# Seit Etappe 9.6c (Entwurf C.6 Nr. 10) entfallen SIMLEV_LAPACK (keine System-LAPACK) und
# SIMLEV_R_SYS_TIME (feste Uhr für gosolnp).
module REnv

"Name => (Zweck, Art)."
const SWITCHES = (
    "SIMLEV_COLLATE" => ("Sortierung: icu:<Locale> (icu:root wie R unter C.UTF-8) oder C (Bytes)", "Nutzer"),
    "SIMLEV_ICU" => ("Pfad zur ICU-Bibliothek (libicui18n)", "Nutzer"),
    "SIMLEV_LAX_NA" => ("1: NA = NaN im Vergleich mit den Referenzfällen", "Prüfung"),
    "SIMLEV_STRICT_ZERO" => ("0: -0 = +0 im Vergleich mit den Referenzfällen", "Prüfung"),
    "SIMLEV_FULL_TESTS" => ("1: Pkg.test() prüft alle Modul-Fälle statt einer Auswahl", "Prüfung"),
    "SIMLEV_GOLDEN_DIR" => ("anderer Wurzelordner der Engine-Fälle (cases/, extra/)", "Prüfung"),
    "SIMLEV_SKIP_PRECOMPILE" => ("1: keine Arbeitslast beim Vorkompilieren", "Entwicklung"),
    "SIMLEV_SKIP_PRECOMPILE_EXT" => ("1: Arbeitslast ohne die Erweiterungsmodule", "Entwicklung"),
    "SIMLEV_LEGACY_TESTS" => ("1: alte Tests und Referenzvergleiche laufen (Etappe 9: sonst ausgesetzt)", "Prüfung"),
    "SIMLEV_MODULE_DIR" => ("anderer Ordner der Modul-Fälle (compare_reference.jl, Gleichlauf)", "Prüfung"),
    "SIMLEV_CC" => ("C-Compiler für Pkg.build (gelesen in deps/build.jl, das SimLev nicht laden kann)", "Bau"),
)

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
"`SIMLEV_FULL_TESTS=1`: alle Modul-Fälle in `Pkg.test()`."
full_tests() = get(ENV, "SIMLEV_FULL_TESTS", "0") == "1"
"`SIMLEV_GOLDEN_DIR`, sonst `default`."
golden_dir(default) = get(ENV, "SIMLEV_GOLDEN_DIR", default)
"`SIMLEV_LEGACY_TESTS=1`: alte Tests und Referenzvergleiche laufen (Etappe 9, Entwurf C.7)."
legacy_tests() = get(ENV, "SIMLEV_LEGACY_TESTS", "") == "1"
"`SIMLEV_MODULE_DIR`, sonst `default`."
module_dir(default) = get(ENV, "SIMLEV_MODULE_DIR", default)
"Setzt `SIMLEV_COLLATE = value`, falls nicht gesetzt; `true`, wenn gesetzt wurde."
set_collate_default!(value = "icu:root") = haskey(ENV, "SIMLEV_COLLATE") ? false : (ENV["SIMLEV_COLLATE"] = value; true)

# ── Entwicklung ─────────────────────────────────────────────────────────────
"`SIMLEV_SKIP_PRECOMPILE=1`: keine Arbeitslast beim Vorkompilieren."
skip_precompile() = get(ENV, "SIMLEV_SKIP_PRECOMPILE", "0") == "1"
"`SIMLEV_SKIP_PRECOMPILE_EXT=1`: Arbeitslast ohne die Erweiterungsmodule."
skip_precompile_ext() = get(ENV, "SIMLEV_SKIP_PRECOMPILE_EXT", "0") == "1"

end # module
