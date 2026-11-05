/*
 * core/simlev_core.h -- Gemeinsame Kerne von R, Python und Julia: Aufbau, Host-Schnittstelle,
 * Rueckmeldungen, Gleitkomma-Regeln
 *
 * GEMEINSAME QUELLE FUER R, PYTHON UND JULIA. Jeder geteilte native Kern ist geteilt in die
 * Rechnung (<datei>_impl.h; ohne R- und Python-Header) und die Huellen (R:
 * r/src/<datei>.cpp mit den .Call-Funktionen; Python: python/src/_ext_<kern>.cpp im Modul
 * simlev._ext). Kanonisch sind die Dateien in core/; R und Python
 * bauen aus Byte-fuer-Byte-Kopien in r/src/ bzw. python/src/core/ (core/sync.py
 * --write/--check). Aenderungen nur in core/, danach kopieren. Julia ist der dritte
 * Host (C-ABI-Huelle core/simlev_cabi.cpp, Kopie in julia/deps/core/; bis 1.1.0 eigene Ports).
 * Zufallszahlen zieht keiner der geteilten Kerne (seit 1.0.0);
 * die frueheren Bootstrap-, DCC- und MS-GARCH-Kerne rechnet die C-Bibliothek slc
 * (core/slc_*.cpp).
 *
 * Host-Schnittstelle. Ein Kern sieht seinen Host nur ueber diese Namen; die
 * einbindende Huelle definiert sie vorher (R: simlev_capi.h, Abschnitt "R als Host der
 * gemeinsamen Kerne"; Python: python/src/_ext_common.h, Engine _ext_engine.cpp; Julia:
 * core/simlev_cabi.cpp, Fehler als C++-Ausnahme, die die Huelle in einen Rueckgabecode umsetzt):
 *
 *   simlev_host::NumVec, IntVec   Sicht auf einen Vektor (sexp, ptr, len; v[i], size(),
 *                                 begin(), end())
 *   simlev_host::NumMat           Sicht auf eine Matrix (spaltenweise; m(i, j), nrow())
 *   SIMLEV_NA                     R's NA_real_ (Python: simlev_na_real())
 *   SIMLEV_FAIL(fmt, ...)         Fehler mit Text (printf-Format, UTF-8); kehrt nicht
 *                                 zurueck. R: stop() mit genau diesem Text (sl::stop);
 *                                 Python: ValueError mit dem Text, den die Python-Seite in
 *                                 die Fehlerklasse des reinen Python-Kerns umsetzt.
 *   SIMLEV_CHECK_INTERRUPT()      Benutzerabbruch pruefen; kehrt bei Abbruch nicht
 *                                 zurueck. R: sl::check_interrupt() wie bisher; Python:
 *                                 PyErr_CheckSignals() (KeyboardInterrupt), der Kern laeuft
 *                                 dazu mit gehaltener GIL.
 *   SIMLEV_NUM, SIMLEV_MATRIX,    Ergebnisfelder anlegen bzw. kopieren (R: neue
 *   SIMLEV_COPY(_VEC)             R-Vektoren; Python: Speicher je Thread, die Huelle
 *                                 kopiert nach dem Kern in Python-Objekte)
 *   SIMLEV_LIST, SIMLEV_DONE,     Ergebnis zurueckgeben (benannte Liste bzw. Vektor;
 *   SIMLEV_SET_FLAG               Python: Tupel), Attribut setzen
 *
 * Seit 1.6.3 entfallen (von keinem Kern genutzt): SIMLEV_WARN, SIMLEV_INT, SIMLEV_CLONE,
 * SIMLEV_R_FINITE, SIMLEV_NA_INTEGER und simlev_host::LglVec.
 *
 * Die Tagesengine (engine_core_impl.h) und der Tarifkern (tariff_core_impl.h) haben
 * eigenen Zustand und brauchen vom Host nur die Gleitkomma-Regeln dieser Datei. Die
 * frueheren Engine-Kerne (simulation_core_impl.h, fifo_core_impl.h, tax_core_impl.h) auf
 * dem Simulationszustand des Hosts (simlev_host::Obj) sind seit 1.4.0 entfallen.
 *
 * Fuer R stehen hinter allen Namen genau die Aufrufe, die vor der Teilung im Kern
 * standen (geprueft per Disassemblierung).
 *
 * NA vor NaN: Treffen in einer Operation zwei NaN zusammen, haengt die Nutzlast des
 * Ergebnisses in der Hardware davon ab, welcher Operand im Register liegt; das waehlt der
 * Compiler (Operandenreihenfolge, Registerwahl), R, Python und Julia konnten daher
 * verschiedene NaN liefern. Die Engine-Kerne rechnen jede Operation, deren beide
 * Operanden aus Eingaben stammen (also beide NaN sein koennen), ueber simlev_add,
 * simlev_sub, simlev_mul und simlev_div mit der festen Regel:
 *   1. Ist das Ergebnis keine NaN, bleibt es unveraendert (normale Zahlen bitgleich).
 *   2. Sonst hat NA Vorrang: ist ein Operand NA (Nutzlast 1954), ist das Ergebnis dieses
 *      NA, still gemacht (0x7FF80000000007A2; Vorzeichen des Operanden); bei zwei NA das
 *      linke.
 *   3. Sonst das NaN des linken, dann des rechten Operanden (still gemacht), wie die
 *      Hardware bei einem NaN-Operanden.
 *   4. Entsteht die NaN erst in der Operation (Inf - Inf, 0 * Inf, 0 / 0), bleibt die
 *      der Hardware (x86-64: 0xFFF8000000000000).
 * Operationen mit einer Konstanten oder einem stets endlichen Wert brauchen die Regel
 * nicht (bei nur einem NaN-Operanden ist das Ergebnis eindeutig).
 *
 * Gleitkomma: jede Kerndatei bricht bei -ffast-math ab und schaltet das
 * Zusammenziehen von a * b + c zu fma ab (Pragma; unter GCC nur, wo fma ueberhaupt
 * erzeugt werden kann, siehe dort; Python setzt SIMLEV_FP_CONTRACT_BY_FLAG und
 * uebersetzt mit -ffp-contract=off). Kein long double (seit 1.1.0: kompensierte Summen in
 * der Tagesengine, ganzzahlig und double-double in kendall_tau_core; vorher wie R 80 Bit auf
 * x86-64, 128 Bit auf aarch64). exp, log, pow, sqrt aus der libm des Systems.
 *
 * Diese Datei ist reines C99 und auch aus C++ nutzbar.
 */
#ifndef SIMLEV_CORE_H
#define SIMLEV_CORE_H

#include <limits.h>
#include <stdint.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

/* R's NA_real_ (signalisierendes NaN mit Nutzlast 1954, 0x7FF00000000007A2) */
static inline double simlev_na_real(void)
{
    const uint64_t bits = UINT64_C(0x7FF00000000007A2);
    double x;
    memcpy(&x, &bits, sizeof x);
    return x;
}
#define SIMLEV_NA_REAL (simlev_na_real())

/* NA vor NaN (Regel oben): Hilfen der Engine-Kerne */
static inline uint64_t simlev_bits_(double x)
{
    uint64_t b;
    memcpy(&b, &x, sizeof b);
    return b;
}
static inline double simlev_quiet_(double x)              /* NaN still machen (Bit 51) */
{
    const uint64_t b = simlev_bits_(x) | UINT64_C(0x0008000000000000);
    double y;
    memcpy(&y, &b, sizeof y);
    return y;
}
static inline int simlev_is_na(double x)                  /* wie R_IsNA: NaN mit Nutzlast 1954 */
{
    return x != x && (uint32_t) simlev_bits_(x) == 1954u;
}
static inline double simlev_nan2_(double r, double a, double b)
{
    if (r == r) return r;
    if (simlev_is_na(a)) return simlev_quiet_(a);
    if (simlev_is_na(b)) return simlev_quiet_(b);
    if (a != a) return simlev_quiet_(a);
    if (b != b) return simlev_quiet_(b);
    return r;
}
static inline double simlev_add(double a, double b) { return simlev_nan2_(a + b, a, b); }
static inline double simlev_sub(double a, double b) { return simlev_nan2_(a - b, a, b); }
static inline double simlev_mul(double a, double b) { return simlev_nan2_(a * b, a, b); }
static inline double simlev_div(double a, double b) { return simlev_nan2_(a / b, a, b); }

/* R's min(a, b) bzw. max(a, b) fuer zwei Zahlen (NA vor NaN, sonst das NaN von b, dann a; nicht die Regel von
 * simlev_nan2_) und R's & dreiwertig (0 FALSE, 1 TRUE, 2 NA); seit 1.6.3 hier gemeinsam fuer Tagesengine und
 * Auswertung (vorher je eine Kopie in engine_core_impl.h und evaluate_core_impl.h) */
static inline double simlev_r_nan2_(double a, double b)
{
    if (a != a && simlev_is_na(a)) return a;
    if (b != b) return b;
    return a;
}
static inline double simlev_r_min2(double a, double b) { return (a != a || b != b) ? simlev_r_nan2_(a, b) : (b < a ? b : a); }
static inline double simlev_r_max2(double a, double b) { return (a != a || b != b) ? simlev_r_nan2_(a, b) : (b > a ? b : a); }
static inline int simlev_r_and(int a, int b) { return (a == 0 || b == 0) ? 0 : ((a == 2 || b == 2) ? 2 : 1); }

#ifdef __cplusplus
}
#endif

#endif
