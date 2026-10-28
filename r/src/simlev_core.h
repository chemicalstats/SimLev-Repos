/*
 * core/simlev_core.h -- Gemeinsame Kerne von R und Python: Aufbau, Host-Schnittstelle,
 * Rueckmeldungen, Gleitkomma-Regeln (Etappe 7.3a, 7.3b; Ort seit 9.6c)
 *
 * GEMEINSAME QUELLE FUER R UND PYTHON. Jeder geteilte native Kern ist geteilt in die
 * Rechnung (<datei>_impl.h; ohne R- und Python-Header) und die Huellen (R:
 * r/src/<datei>.cpp mit den .Call-Funktionen; Python: python/src/_ext_<kern>.cpp im Modul
 * simlev._ext). Kanonisch sind die Dateien seit Etappe 9.6c (F16) in core/; R und Python
 * bauen aus Byte-fuer-Byte-Kopien in r/src/ bzw. python/src/core/ (tools/core_sync.py
 * --write/--check). Aenderungen nur in core/, danach kopieren. Julia hat eigene Ports
 * dieser Kerne (F2). Zufallszahlen zieht seit Etappe 9.6c keiner der geteilten Kerne mehr;
 * die frueheren Bootstrap-, DCC- und MS-GARCH-Kerne rechnet die C-Bibliothek slc
 * (core/slc_*.c).
 *
 * Host-Schnittstelle. Ein Kern sieht seinen Host nur ueber diese Namen; die
 * einbindende Huelle definiert sie vorher (R: simlev_capi.h, Abschnitt "R als Host der
 * gemeinsamen Kerne"; Python: python/src/_ext_common.h, Engine _ext_engine.cpp):
 *
 *   simlev_host::NumVec, IntVec   Sicht auf einen Vektor (sexp, ptr, len; v[i], size(),
 *                                 begin(), end())
 *   simlev_host::NumMat           Sicht auf eine Matrix (spaltenweise; m(i, j), nrow())
 *   SIMLEV_NA                     R's NA_real_ (Python: simlev_na_real())
 *   SIMLEV_FAIL(fmt, ...)         Fehler mit Text (printf-Format, UTF-8); kehrt nicht
 *                                 zurueck. R: stop() mit genau diesem Text (sl::stop);
 *                                 Python: ValueError mit dem Text, den die Python-Seite in
 *                                 die Fehlerklasse des reinen Python-Kerns umsetzt.
 *   SIMLEV_WARN(msg)              Warnung (R: Rf_warning; Python: warnings.warn);
 *                                 derzeit von keinem Kern genutzt.
 *   SIMLEV_CHECK_INTERRUPT()      Benutzerabbruch pruefen; kehrt bei Abbruch nicht
 *                                 zurueck. R: sl::check_interrupt() wie bisher; Python:
 *                                 PyErr_CheckSignals() (KeyboardInterrupt), der Kern laeuft
 *                                 dazu mit gehaltener GIL.
 *   SIMLEV_NUM, SIMLEV_MATRIX,    Ergebnisfelder anlegen bzw. kopieren (R: neue
 *   SIMLEV_COPY(_VEC), SIMLEV_CLONE  R-Vektoren; Python: Speicher je Thread, die Huelle
 *                                 kopiert nach dem Kern in Python-Objekte)
 *   SIMLEV_LIST, SIMLEV_DONE,     Ergebnis zurueckgeben (benannte Liste bzw. Vektor;
 *   SIMLEV_SET_FLAG               Python: Tupel), Attribut setzen
 *   SIMLEV_R_FINITE(x)            R_finite (Python: std::isfinite)
 *
 *   simlev_host::LglVec           logischer Vektor (R: sl::LglVec)
 *
 * Engine-Kerne (simulation_core_impl.h, fifo_core_impl.h, tax_core_impl.h) arbeiten auf
 * dem Simulationszustand des Hosts: simlev_host::Obj (R: SEXP, Python: PyObject*) mit
 * as_list, at, put, get, set, has, as_double, as_int, num_vec, named_list, new_num,
 * new_int, Date und SIMLEV_XLENGTH, SIMLEV_LENGTH, SIMLEV_IS_NULL, SIMLEV_STRING_AT,
 * SIMLEV_MARK_DATE.
 *
 * Fuer R stehen hinter allen Namen genau die Aufrufe, die vor der Teilung im Kern
 * standen; der R-Bau erzeugt daher denselben Maschinencode wie zuvor (geprueft per
 * Disassemblierung, Funktion fuer Funktion). Auch das Ergebnis bei zwei NaN in einer
 * Operation (welche Nutzlast bleibt) haengt davon ab.
 *
 * Gleitkomma: jede Kerndatei bricht bei -ffast-math ab und schaltet das
 * Zusammenziehen von a * b + c zu fma ab (Pragma; unter GCC nur, wo fma ueberhaupt
 * erzeugt werden kann, siehe dort; Python setzt SIMLEV_FP_CONTRACT_BY_FLAG und
 * uebersetzt mit -ffp-contract=off). long double wie in R (x86-64: 80 Bit). exp,
 * log, pow, sqrt aus der libm des Systems.
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

/* R's NA_real_ (signalisierendes NaN mit Nutzlast 1954, 0x7FF00000000007A2) und NA_integer_ */
static inline double simlev_na_real(void)
{
    const uint64_t bits = UINT64_C(0x7FF00000000007A2);
    double x;
    memcpy(&x, &bits, sizeof x);
    return x;
}
#define SIMLEV_NA_REAL (simlev_na_real())
#define SIMLEV_NA_INTEGER INT_MIN

#ifdef __cplusplus
}
#endif

#endif
