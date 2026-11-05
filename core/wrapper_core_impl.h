// core/wrapper_core_impl.h
// Fonds-Wrapper: Tagesschleife des Anteilswerts (NAV) von wrapper_nav() als gemeinsamer C++-Kern (seit 1.5.1; bis
// 1.5.0 in den Sprachen: R .wrapper_nav_calc in r/R/wrapper.R, Python _wrapper_nav_calc in simlev/wrapper.py, Julia
// _wrapper_nav_calc in src/wrapper.jl). Die innere Rechnung (simulation()), die Auswahl der NAV-Tage, das Jahr je
// Tag und die Meldungen bleiben in den Sprachen; der Kern rechnet nur die Schleife und meldet den ersten Tag mit
// nicht definiertem Anteilswert zurueck.
//
// Herkunft:           uebersetzt aus SimLev 1.5.0, r/R/wrapper.R (.wrapper_nav_calc, Schleife ueber t;
//                     .wrapper_is_leap)
// Rechte:             SimLev (eigener Code)
// Lizenz der Vorlage: GPL-3 (SimLev)
//
// Eingebunden von r/src/research_core.cpp (.Call C_wrapper_nav_core), python/src/_ext_research.cpp
// (simlev._ext.wrapper_nav_core) und core/simlev_cabi.cpp (simlev_c_wrapper_nav). Kanonisch in core/, Kopien ueber
// core/sync.py. Gleitkomma wie die uebrigen Kerne (kein fma, kein -ffast-math); die Rechenfolge je Zeile ist die
// der R-Fassung.
#ifndef SIMLEV_WRAPPER_CORE_IMPL_H
#define SIMLEV_WRAPPER_CORE_IMPL_H

#if defined(__FAST_MATH__)
#error "Gemeinsame Kerne duerfen nicht mit -ffast-math uebersetzt werden (Bitgleichheit)."
#endif
#if defined(__clang__)
#pragma STDC FP_CONTRACT OFF
#elif defined(_MSC_VER)
#pragma fp_contract (off)
#elif defined(__GNUC__) && (defined(__FP_FAST_FMA) || defined(__FP_FAST_FMAF)) && !defined(SIMLEV_FP_CONTRACT_BY_FLAG)
#pragma GCC optimize ("fp-contract=off")
#endif

#include "simlev_core.h"
#include <cmath>
#include <cstdint>

namespace simlev {

// R's max(a, b) fuer zwei Zahlen (NA vor NaN wie rmax in summary.c)
static inline double wn_max2(double a, double b) {
  if (a != a || b != b) {
    if (a != a && simlev_is_na(a)) return a;
    return b != b ? b : a;
  }
  return b > a ? b : a;
}

// Schaltjahr wie .wrapper_is_leap (ganzzahliges Jahr)
static inline bool wn_is_leap(int64_t y) { return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0; }

// n NAV-Tage; G innerer Wert je Tag, day Tageszahl (Tage seit 1970), yr Kalenderjahr je Tag, fee und pf Verwaltungs-
// und Performancegebuehr in Prozent, S Volumen (Startwert der inneren Rechnung), d0 erster Tag der inneren Rechnung.
// Ausgaben je Tag nav, gross, fee_t, acc_t (perf_fee), paid_t (perf_paid), hwm. Rueckgabe -1 oder der erste Tag t
// (0-basiert), an dem der Anteilswert nicht definiert ist (!(G_prev > 0) || !is.finite(g) || !(g > 0)); die Sprache
// meldet ihn mit G[t] und G_prev = (t == 0 ? S : G[t - 1]). Bis dahin sind die Ausgaben gefuellt, danach unbestimmt.
static int64_t wrapper_nav_core(int64_t n, const double* G, const double* day, const int64_t* yr, double fee, double pf,
                                double S, double d0, double* nav, double* gross, double* fee_t, double* acc_t,
                                double* paid_t, double* hwm) {
  double U = 100, H = 100, G_prev = S, d_prev = d0;
  for (int64_t t = 0; t < n; ++t) {
    const double g = G[t];
    if (!(G_prev > 0) || !std::isfinite(g) || !(g > 0)) return t;
    const double D = wn_is_leap(yr[t]) ? 366 : 365;
    const double a = U * (g / G_prev);
    const double k = fee / 100 * (day[t] - d_prev) / D;
    fee_t[t] = a * k;
    U = a - fee_t[t];
    acc_t[t] = pf / 100 * wn_max2(0, U - H);
    nav[t] = U - acc_t[t];
    paid_t[t] = 0;
    if (t < n - 1 && yr[t + 1] != yr[t]) {         // letzter NAV-Tag des Kalenderjahres (nicht der letzte insgesamt)
      paid_t[t] = acc_t[t];
      U = nav[t];
      H = wn_max2(H, U);
    }
    gross[t] = 100 * g / S;
    hwm[t] = H;
    G_prev = g; d_prev = day[t];
  }
  return -1;
}

}  // namespace simlev

#endif
