// core/tariff_core_impl.h
// Einkommensteuertarif fuer die Entnahmephase (Tarifweg): tarifliche Einkommensteuer,
// Solidaritaetszuschlag, Kirchensteuer und Jahresabschluss mit § 23, Guenstigerpruefung und
// Kirchensteuer-Saldo des Vorjahres; reine Rechnung ohne Host-Objekte.
//
// GEMEINSAME QUELLE FUER R, PYTHON UND JULIA: eingebunden von withdrawal_core_impl.h (R ueber
// r/src/withdrawal_core.cpp, Python ueber python/src/_ext_withdrawal.cpp, Julia ueber
// core/simlev_cabi.cpp). Kanonisch in core/; R, Python und Julia bauen aus Byte-fuer-Byte-
// Kopien (core/sync.py --write/--check); Aenderungen nur in core/ vornehmen.
//
// Bitgleich zu den R-Funktionen, die simulation() im Tarifweg nutzt (r/R/tax_tariff.R und
// r/R/sim_base.R), in derselben Rechenfolge:
//   income_tax  .tariff_income_tax  T(x) = floor(round((a u + b) u + c, 6)), x = floor(zvE + 1e-9)
//   soli        .tariff_soli        min(Satz E, Milderung (E - Freigrenze)), auf volle Cent abgerundet
//   full        .tariff_full (Differenzen wie .tariff_diff in close ueber das Lambda df)
//   close       .tariff_close       Veranlagung eines Jahres (ohne Druck; die Jahreszeile in row)
// round(x, 6) ist R's fround (nmath/fround.c, R >= 4.0.0), wie r_round in Python und Julia.
// Geprueft per Zufallsvergleich gegen die R-Funktionen (Gleichlauf: tariff_fuzz.R ueber
// .wd_tariff_check).
//
// Parametervektor (Hosts bauen ihn aus tax_tariff() und tax_profile(), R: .wd_tariff_par):
//   [0] use_gp (0/1), [1] church_k (church_tax / 100), [2] kapest_rate (0.25 / (1 + 0.25 k)),
//   [3] Soli-Freigrenze (EUR), [4] Soli-Satz (Prozent), [5] Soli-Milderung (Prozent),
//   [6] Zahl der Zonen nz, dann je nz Werte ab, bezug, teiler, a, b, c.

#ifndef SIMLEV_TARIFF_CORE_IMPL_H
#define SIMLEV_TARIFF_CORE_IMPL_H

// Gleitkomma wie in den uebrigen Kernen (simlev_core.h): kein fast-math, kein fma.
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

#include <cmath>
#include <cstdint>
#include <cstring>
#include <vector>

#include "slc_rbase.h"

namespace simlev {

// Spalten der Jahreszeile (wie tax_report$tariff_years in simulation())
enum { TR_YEAR = 0, TR_ZVE, TR_KS_PAID, TR_KS_REFUNDED, TR_KS_NET, TR_ZVE_NET, TR_DED, TR_G23, TR_EST23, TR_SOLI23,
       TR_KIST23, TR_TAX23, TR_K, TR_ABG, TR_KABG, TR_EST_K, TR_SOLI_K, TR_KIST_K, TR_BURDEN_K, TR_X0, TR_X1, TR_FAV,
       TR_D, TR_REFUND, TR_KS_NEXT, TR_N };

// round(x, digits) wie R >= 4.0.0 (nmath/fround.c) fuer 0 < digits <= 308 (hier 6). Seit 1.6.3 rechnet sl_r_fround
// (slc_rbase.cpp) die endlichen Werte (gleiche Rechenfolge: (logb + 1/2) log10(2) + dig > 15, x 10^dig mit
// R_pow_di); NA/NaN bleiben x + digits (Tarifregel, anders als sl_r_fround mit NA bzw. R_NaN).
static inline double tariff_fround(double x, double digits) {
  if (std::isnan(x) || std::isnan(digits)) return x + digits;
  return sl_r_fround(x, digits);
}

// max/min wie R mit zwei Argumenten ohne NA: das erste, ausser das zweite ist groesser bzw. kleiner
static inline double tariff_max(double a, double b) { return b > a ? b : a; }
static inline double tariff_min(double a, double b) { return b < a ? b : a; }

struct TariffParts { double est, soli, kist, total; };

struct TariffCore {
  bool on = false, use_gp = false;
  double church_k = 0.0, kapest = 0.0, s_fg = 0.0, s_satz = 0.0, s_mild = 0.0;
  int nz = 0;
  std::vector<double> ab, bezug, teiler, a, b, c;

  // Parameter lesen (Aufbau oben); par leer = Tarifweg aus. Rueckgabe false bei falscher Laenge.
  template <class V> bool init(const V& par) {
    on = false;
    if (par.size() == 0) return true;
    if (par.size() < 7) return false;
    const double nzd = par[6];
    if (!(nzd >= 1.0) || nzd != std::floor(nzd) || (double) par.size() != 7.0 + 6.0 * nzd) return false;
    nz = (int) nzd;
    use_gp = par[0] != 0.0; church_k = par[1]; kapest = par[2];
    s_fg = par[3]; s_satz = par[4]; s_mild = par[5];
    ab.resize(nz); bezug.resize(nz); teiler.resize(nz); a.resize(nz); b.resize(nz); c.resize(nz);
    for (int j = 0; j < nz; j++) {
      ab[j] = par[7 + j]; bezug[j] = par[7 + nz + j]; teiler[j] = par[7 + 2 * nz + j];
      a[j] = par[7 + 3 * nz + j]; b[j] = par[7 + 4 * nz + j]; c[j] = par[7 + 5 * nz + j];
    }
    on = true;
    return true;
  }

  // .tariff_income_tax: ESt in vollen EUR
  double income_tax(double zve) const {
    const double x = tariff_max(0.0, std::floor(zve + 1e-9));
    int k = nz - 1;
    while (k > 0 && !(ab[k] <= x)) k--;
    const double u = (x - bezug[k]) / teiler[k];
    return tariff_max(0.0, std::floor(tariff_fround((a[k] * u + b[k]) * u + c[k], 6.0)));
  }
  // .tariff_soli: Soli in EUR (Bruchteile eines Cents entfallen)
  double soli(double est) const {
    if (!(est > s_fg)) return 0.0;
    const double v = tariff_min(s_satz / 100 * est, s_mild / 100 * (est - s_fg));
    return std::floor(tariff_fround(v * 100, 6.0)) / 100;
  }
  // .tariff_full
  TariffParts full(double x) const {
    const double e = income_tax(x), so = soli(e), ki = church_k * e;
    return TariffParts{e, so, ki, e + so + ki};
  }
  // .tariff_close ohne Druck: Saldo D (> 0 Nachzahlung, < 0 Erstattung), na ohne zvE (keine Veranlagung;
  // row und ks_next bleiben dann unveraendert). row (TR_N Werte, TR_YEAR setzt der Aufrufer) darf nullptr
  // sein; ks_next = Saldo des KiSt-Bescheids (Zahlung bzw. Erstattung im Folgejahr).
  double close(double zve, double ks_prev, double g23, double k_base, double abg_rate, double na,
               double* row, double& ks_next) const {
    if (std::isnan(zve)) return na;
    // F(zvE) einmal je Veranlagung; F(x) - F(zvE) fuer x == zvE ist exakt 0 (gleiche Werte), daher ohne Rechnung
    const TariffParts Fz = full(zve);
    // Seit 1.6.4 (A-087) full() je Veranlagung einmal je Argument (bis 1.6.3 bis zu 9 Aufrufe fuer etwa 5 Argumente):
    // Merker ueber das Bitmuster des Arguments, zvE selbst ueber Fz (full ist eine reine Funktion; gleiche Bits,
    // gleiche Werte)
    uint64_t bz;
    std::memcpy(&bz, &zve, sizeof bz);
    uint64_t mb[6];
    TariffParts mf[6];
    int mn = 0;
    auto F = [&](double x) -> TariffParts {
      uint64_t bx;
      std::memcpy(&bx, &x, sizeof bx);
      if (bx == bz) return Fz;
      for (int i = 0; i < mn; i++)
        if (mb[i] == bx) return mf[i];
      const TariffParts p = full(x);
      if (mn < 6) { mb[mn] = bx; mf[mn] = p; mn++; }
      return p;
    };
    auto dz = [&](double x) -> TariffParts {
      if (std::isnan(x) || x == zve) return TariffParts{0.0, 0.0, 0.0, 0.0};
      const TariffParts p = F(x);
      return TariffParts{p.est - Fz.est, p.soli - Fz.soli, p.kist - Fz.kist, p.total - Fz.total};
    };
    auto df = [&](double x1, double x0) -> TariffParts {   // .tariff_diff(x1, x0) ueber F; x1 == x0: exakt 0
      if (std::isnan(x1) || std::isnan(x0) || x1 == x0) return TariffParts{0.0, 0.0, 0.0, 0.0};
      const TariffParts p = F(x1), q = F(x0);
      return TariffParts{p.est - q.est, p.soli - q.soli, p.kist - q.kist, p.total - q.total};
    };
    const double k = tariff_max(0.0, k_base), abg = k * abg_rate;
    const double kabg = k * kapest * church_k;
    const bool gp_on = use_gp && k > 0;
    const double B0 = zve - ks_prev, B1 = B0 - kabg;
    const double X0 = dz(B0 + g23).total + abg;
    const double X1 = gp_on ? dz(B1 + g23 + k).total : na;
    const bool fav = gp_on && X1 < X0;
    const double Bx = fav ? B1 : B0;
    const double D = (fav ? X1 : X0) - abg;
    const TariffParts tot = dz(Bx + g23 + (fav ? k : 0.0));
    const double ks = tot.kist - (fav ? kabg : 0.0);
    ks_next = ks;
    if (row) {
      const TariffParts ded = dz(Bx), p23 = df(Bx + g23, Bx);
      TariffParts tk{na, na, na, na};
      if (use_gp) tk = df(B1 + g23 + k, B1 + g23);
      const double paid = tariff_max(0.0, ks_prev) + (fav ? kabg : 0.0), refunded = tariff_max(0.0, -ks_prev);
      row[TR_ZVE] = zve; row[TR_KS_PAID] = paid; row[TR_KS_REFUNDED] = refunded; row[TR_KS_NET] = paid - refunded;
      row[TR_ZVE_NET] = Bx; row[TR_DED] = ded.total;
      row[TR_G23] = g23; row[TR_EST23] = p23.est; row[TR_SOLI23] = p23.soli; row[TR_KIST23] = p23.kist;
      row[TR_TAX23] = p23.total;
      row[TR_K] = k; row[TR_ABG] = abg; row[TR_KABG] = kabg;
      row[TR_EST_K] = tk.est; row[TR_SOLI_K] = tk.soli; row[TR_KIST_K] = tk.kist; row[TR_BURDEN_K] = tk.total;
      row[TR_X0] = X0; row[TR_X1] = X1; row[TR_FAV] = fav ? 1.0 : 0.0;
      row[TR_D] = D; row[TR_REFUND] = tariff_max(0.0, -D); row[TR_KS_NEXT] = ks;
    }
    return D;
  }
};

}  // namespace simlev

#endif
