// core/prepare_core_impl.h
// Vorbereitung von simulation() als gemeinsamer C++-Kern: Termine (calculate_dates_flags mit der
// Monatsarithmetik von seq.Date), Split-Termine, Tagesflags samt Verschieben von Terminen auf aufgefuellten
// Tagen, Aktivierung, Freibetragstermine, Jahreswechsel und VP-Abrechnungstage, Startgewichte und Anfangszustand.
// Ergebnis ist die flache Eingabe der Tagesengine (engine_core_impl.h: Tagesflags, flag_dca_n, Startindizes,
// Status nach den Startgewichten, Report am ersten Tag).
//
// Herkunft:           uebersetzt aus SimLev 1.3.0, r/R/sim_prepare.R (.sim_build_calendar ohne die Eingabepruefung,
//                     .sim_init_weights, .sim_build_schedule, Anfangszustand aus .sim_build_state) und
//                     r/R/sim_base.R (calculate_dates_flags, .calculate_split_flags); Vorlage der Uebersetzung war
//                     der typisierte Julia-Port (julia/src/sim_phases.jl, engine.jl)
// Rechte:             SimLev (eigener Code)
// Lizenz der Vorlage: GPL-3 (SimLev)
// Aenderungen:        Flags als Bitmaske je Tag (DayFlag der Engine); Datumswerte als Tageszahlen, Monatsarithmetik
//                     ganzzahlig statt ueber POSIXlt; die Texte der Eingabepruefung und die Umwandlung der Angaben
//                     (span, days, harvest_day) bleiben in den Sprachen.
//
// GEMEINSAME QUELLE FUER R, PYTHON UND JULIA (wie engine_core_impl.h, das diese Datei einbindet): R ueber
// r/src/engine_core.cpp (C_sim_engine_run mit der Vorbereitung, C_sim_dates_flags), Python ueber
// python/src/_ext_engine.cpp (sim_engine_run, sim_dates_flags), Julia ueber core/simlev_cabi.cpp (simlev_c_engine_run,
// simlev_c_dates_flags); einen eigenen Einsprung nur fuer die Vorbereitung gibt es nicht.
// Regeln wie engine_core_impl.h: kein globaler Zustand, Rechenfolge wie R, sum() ueber sl_r_sum.
//
// Datumsregeln (wie R; Tageszahlen seit 1970-01-01, proleptisch gregorianisch):
//   - Abgleich von Terminen mit den Tagen ueber die abgerundete Tageszahl (.sim_date_match), skip_start und
//     liquidate vergleichen den Termin exakt mit min(dates) bzw. max(dates).
//   - Periodenanfaenge wie seq(from = Monatserster von start, to = max(dates), by = "<step> months"/"years").
//   - anchor "start": as.Date("<Jahr>-<Monat>-<days>", "%Y-%m-%d"); den Tag liest der Host einmal je Wert von
//     days (dcode, 0 = NA), gueltig nur fuer Jahre 0 bis 9999 und Tage, die es im Monat gibt.
//   - anchor "end": Monats-, Quartals- bzw. Jahresende - (days - 1), beim Monat ohne Tage vor dem Monatsersten.

#ifndef SIMLEV_PREPARE_CORE_IMPL_H
#define SIMLEV_PREPARE_CORE_IMPL_H

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

#include "slc_rbase.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <utility>
#include <vector>

namespace simlev_prepare {

// Teil:               civil_from_days, days_from_civil
// Herkunft:           übersetzt aus H. Hinnant, chrono-Compatible Low-Level Date Algorithms,
//                     https://howardhinnant.github.io/date_algorithms.html
// Rechte:             gemeinfrei ("Consider these donated to the public domain.")
// Lizenz der Vorlage: keine (gemeinfrei)
// Änderungen:         feste Ganzzahltypen long/int/unsigned statt Template-Parameter; Rückgabe über
//                     Referenzen (wie core/fifo_core_impl.h).
static inline void eng_civil(long z, int& y, int& m, int& d) {
  z += 719468L;
  const long era = (z >= 0 ? z : z - 146096L) / 146097L;
  const unsigned doe = static_cast<unsigned>(z - era * 146097L);
  const unsigned yoe = (doe - doe / 1460u + doe / 36524u - doe / 146096u) / 365u;
  const long yy = static_cast<long>(yoe) + era * 400L;
  const unsigned doy = doe - (365u * yoe + yoe / 4u - yoe / 100u);
  const unsigned mp = (5u * doy + 2u) / 153u;
  d = static_cast<int>(doy - (153u * mp + 2u) / 5u + 1u);
  m = static_cast<int>(mp + (mp < 10 ? 3 : -9));
  y = static_cast<int>(yy + (m <= 2));
}
static inline long eng_days(int y, int m, int d) {
  y -= m <= 2;
  const int era = (y >= 0 ? y : y - 399) / 400;
  const unsigned yoe = static_cast<unsigned>(y - era * 400);
  const unsigned doy = (153u * (m + (m > 2 ? -3 : 9)) + 2u) / 5u + d - 1u;
  const unsigned doe = yoe * 365u + yoe / 4u - yoe / 100u + doy;
  return era * 146097L + static_cast<long>(doe) - 719468L;
}
static inline int month_len(int y, int m) {
  static const int len[12] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
  const bool leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
  return m == 2 && leap ? 29 : len[m - 1];
}
// Tageszahl abgerundet; seit 1.6.4 (A-008) auf +-1e9 Tage begrenzt und NaN als +1e9, damit (long) nie aus NaN, +-Inf
// oder einem riesigen Wert umgewandelt wird (bis 1.6.3 undefiniert, danach Ganzzahlueberlauf; long hat unter Windows
// 32 Bit). Fuer Kalendertage (|z| < 1e9) unveraendert.
static inline long fl_day(double z) {
  if (!(z > -1e9)) return z != z ? 1000000000L : -1000000000L;
  if (!(z < 1e9)) return 1000000000L;
  return (long) std::floor(z);
}

// Termine eines Plans (calculate_dates_flags); on = 0: keine Termine
struct Sched {
  int on = 0;
  int years = 0;          // unit "year" (Schritt in Jahren), sonst Monate
  int quarter = 0;        // unit "quarter" (anchor "end": Ende der Dreimonatsperiode)
  int anchor_end = 0;     // anchor "end"
  int skip = 0;           // skip_start
  int has_days = 0;       // days angegeben (sonst Periodenanfang)
  int64_t step = 1;       // Monate (month: span, quarter: 3 span) bzw. Jahre, >= 1
  double start = 0.0;     // start_date (Tageszahl)
  int64_t nd = 0;
  const double* days = nullptr;   // days (nd)
  const int32_t* dcode = nullptr; // Tag aus as.Date("2000-1-<days>") (0 = NA), fuer anchor "start"
};

// calculate_dates_flags(): out[i] = 1, wenn dates[i] ein Termin ist (dates ohne NA).
// Seit 1.6.3 ein Schnellweg fuer lueckenlose Tage (abgerundet fd[0], fd[0] + 1, ...; so in prepare()): Suche und
// Treffer ueber den Index fd - fd[0] statt sortierter Tabelle und binary_search (gleiche Ganzzahllogik). Sonst
// (simlev_c_dates_flags mit ausgewaehlten Tagen) wie bisher.
// Vorarbeit auf den Tagen (seit 1.6.4, A-084, aus dates_flags herausgeloest): prepare() ruft dates_flags fuer
// Rebalancing und Sparplan auf denselben Tagen und rechnet sie nun einmal (bis 1.6.3 je Aufruf); gleiche Werte
struct DayInfo {
  bool finite = false;       // alle Tage endlich (|Tag| < 1e9)
  double dmin = 0.0, dmax = 0.0;
  bool gapless = true;       // abgerundet fd[0], fd[0] + 1, ...
  std::vector<long> fd;      // abgerundete Tage
  std::vector<long> table;   // sortierte fd (nur ohne Lueckenlosigkeit)
};
static inline DayInfo day_info(int64_t n, const double* dates) {
  DayInfo D;
  if (n < 1) return D;
  // seit 1.6.4 (A-008): nur endliche Tage (bis 1.6.3 lief die Monatsschleife bei einem Datum Inf endlos)
  for (int64_t i = 0; i < n; i++)
    if (!(std::fabs(dates[i]) < 1e9)) return D;
  D.finite = true;
  double dmin = dates[0], dmax = dates[0];
  for (int64_t i = 1; i < n; i++) {
    if (dates[i] < dmin) dmin = dates[i];
    if (dates[i] > dmax) dmax = dates[i];
  }
  D.dmin = dmin;
  D.dmax = dmax;
  D.fd.resize((std::size_t) n);
  for (int64_t i = 0; i < n; i++) D.fd[i] = fl_day(dates[i]);
  bool gapless = true;
  for (int64_t i = 1; i < n && gapless; i++) gapless = D.fd[i] == D.fd[0] + i;
  D.gapless = gapless;
  if (!gapless) {
    D.table = D.fd;
    std::sort(D.table.begin(), D.table.end());
  }
  return D;
}
static inline void dates_flags(int64_t n, const DayInfo& D, const Sched& S, int liquidate, int32_t* out) {
  for (int64_t i = 0; i < n; i++) out[i] = 0;
  if (!S.on || n < 1) return;
  if (!(std::fabs(S.start) < 1e9)) return;
  if (!D.finite) return;
  const double dmin = D.dmin, dmax = D.dmax;
  const std::vector<long>& fd = D.fd;
  const std::vector<long>& table = D.table;
  const bool gapless = D.gapless;
  std::vector<char> mark;   // Schnellweg: mark[z - fd[0]] = 1 fuer jeden Termin z
  if (gapless) mark.assign((std::size_t) n, 0);
  auto in_dates = [&](long z) {
    return gapless ? (z >= fd[0] && z - fd[0] < (long) n) : std::binary_search(table.begin(), table.end(), z);
  };
  std::vector<long> hit;
  auto take = [&](double s) {   // Termin s (NaN = NA) nach den Regeln von R uebernehmen
    if (s != s || !in_dates(fl_day(s))) return;
    if (S.skip && s == dmin) return;
    if (liquidate && s == dmax) return;
    if (gapless) mark[(std::size_t) (fl_day(s) - fd[0])] = 1;
    else hit.push_back(fl_day(s));
  };
  int sy, sm, sd, ty, tm, td;
  eng_civil(fl_day(S.start), sy, sm, sd);
  eng_civil(fl_day(dmax), ty, tm, td);
  const int64_t step = S.step < 1 ? 1 : S.step;
  const int64_t k0 = S.years ? (int64_t) sy : (int64_t) sy * 12 + (sm - 1);
  const int64_t k1 = S.years ? (int64_t) ty : (int64_t) ty * 12 + (tm - 1);
  for (int64_t k = k0; k <= k1; k += step) {
    const int y = S.years ? (int) k : (int) ((k >= 0 ? k : k - 11) / 12);
    const int mon = S.years ? 1 : (int) (k - 12 * (int64_t) y) + 1;
    const long base = eng_days(y, mon, 1);
    if (!S.has_days) {
      take((double) base);
      continue;
    }
    for (int64_t j = 0; j < S.nd; j++) {
      const double dd = S.days[j];
      if (!S.anchor_end) {
        const int dc = S.dcode[j];
        take(y >= 0 && y <= 9999 && dc >= 1 && dc <= month_len(y, mon) ? (double) eng_days(y, mon, dc) : NAN);
      } else if (S.years) {
        take((double) eng_days(y, 12, 31) - (dd - 1));
      } else if (!S.quarter) {
        const double d_end = (double) (mon == 12 ? eng_days(y + 1, 1, 1) : eng_days(y, mon + 1, 1)) - 1 - (dd - 1);
        take(d_end < (double) base ? NAN : d_end);
      } else {
        const int em = mon + 3 > 12 ? mon + 3 - 12 : mon + 3, ey = mon + 3 > 12 ? y + 1 : y;
        take((double) eng_days(ey, em, 1) - 1 - (dd - 1));
      }
    }
  }
  if (gapless) {
    for (int64_t i = 0; i < n; i++) out[i] = mark[(std::size_t) i];
    return;
  }
  std::sort(hit.begin(), hit.end());
  for (int64_t i = 0; i < n; i++) out[i] = std::binary_search(hit.begin(), hit.end(), fd[i]) ? 1 : 0;
}
static inline void dates_flags(int64_t n, const double* dates, const Sched& S, int liquidate, int32_t* out) {
  if (!S.on || n < 1) {
    for (int64_t i = 0; i < n; i++) out[i] = 0;
    return;
  }
  dates_flags(n, day_info(n, dates), S, liquidate, out);
}

// Tagesflags (Bits wie simlev_engine::DayFlag)
enum PrepFlag : uint32_t {
  P_SLOW = 1u << 0, P_YEAR = 1u << 1, P_ACTIVE = 1u << 2, P_SPLIT = 1u << 3, P_DCA = 1u << 4, P_TRADE = 1u << 5,
  P_REBAL = 1u << 6, P_HARVEST = 1u << 7, P_TAXES = 1u << 8, P_LIQ = 1u << 9, P_EVENT = 1u << 10,
  P_VPSETTLE = 1u << 11, P_SLOWNA = 1u << 12, P_FILLED = 1u << 13
};

// Eingabe der Vorbereitung (Zeiger des Hosts)
struct PrepIn {
  int64_t n = 0, na = 0;
  const double* day = nullptr;             // flag_date (n), lueckenlos (abgerundet aufeinanderfolgend)
  const int32_t* filled = nullptr;         // flag_filled (n) oder nullptr
  double stopp = 0.0;                      // stopp_date
  int liquidate = 0;
  Sched dca, bal;                          // Sparplan- und Rebalancing-Termine
  const int32_t* event = nullptr;          // event_col als 0/1 (NA = 0) oder nullptr (ohne event_col)
  int event_replace = 0;                   // event_mode "replace"
  int split_on = 0;                        // split_mode und split_thresh gesetzt
  double split_lo = 0.0, split_hi = 0.0;
  int person = 0;                          // tax_mode "person"
  int harvest_on = 0;                      // harvest_mode und tax_mode "person"
  int harvest_md = 0;                      // Freibetrag ab Monat * 100 + Tag (harvest_day; > 1230: keiner)
  double start_value = 0.0;
  const double* const* price = nullptr;    // je Asset Kurse (n)
  const double* const* sig_buy = nullptr;  // je Asset Signale als double (0/1 bzw. Zahl, NA)
  const double* const* sig_sell = nullptr;
  const int32_t* style = nullptr;          // je Asset 0 bnh, 1 signal, 2 sonst
  const int32_t* no_split = nullptr;       // je Asset keine Splits (Fonds-Wrapper)
  const double* start = nullptr;           // je Asset start (Tageszahl)
  const double* share = nullptr;           // je Asset share
};

// Ausgabe (Speicher des Hosts): flags[n], dca_n[n], st0[8 na], rep0[3 na] (worth, money, total am ersten Tag),
// aux[3 na] (asset_start_indices, Tag mit asset_starts == flag_date bzw. 0, in initial_assets)
struct PrepOut {
  int32_t* flags = nullptr;
  double* dca_n = nullptr;
  double* st0 = nullptr;
  double* rep0 = nullptr;
  int32_t* aux = nullptr;
};

// Rueckgabe 0 in Ordnung, 1 Angaben fehlen, 2 Tage nicht lueckenlos, 3 kein Asset am ersten Tag handelbar
static inline int prepare(const PrepIn& I, const PrepOut& O) {
  const int64_t n = I.n, na = I.na;
  if (n < 1 || na < 1 || !I.day || !I.price || !I.sig_buy || !I.sig_sell || !I.style || !I.no_split || !I.start ||
      !I.share || !O.flags || !O.dca_n || !O.st0 || !O.rep0 || !O.aux)
    return 1;
  const double* day = I.day;
  const long z0 = fl_day(day[0]);
  for (int64_t i = 1; i < n; i++)
    if (fl_day(day[i]) != z0 + i) return 2;
  std::vector<char> filled((std::size_t) n, 0);
  bool any_filled = false;
  if (I.filled)
    for (int64_t i = 0; i < n; i++) any_filled |= (filled[i] = I.filled[i] != 0) != 0;
  std::vector<int> year((std::size_t) n), ym((std::size_t) n), md((std::size_t) n);
  {
    // Kalenderdatum je Tag: seit 1.6.3 einmal eng_civil(z0), danach Tag fuer Tag weitergezaehlt (Tage lueckenlos,
    // oben geprueft; gleiche Werte wie eng_civil(z0 + i))
    int y, m, d;
    eng_civil(z0, y, m, d);
    for (int64_t i = 0; i < n; i++) {
      year[i] = y; ym[i] = y * 12 + m; md[i] = m * 100 + d;
      if (d < month_len(y, m)) d++;
      else if (m < 12) { d = 1; m++; }
      else { d = 1; m = 1; y++; }
    }
  }
  // .sim_build_calendar: Termine
  std::vector<char> liq((std::size_t) n), reb((std::size_t) n), dca((std::size_t) n), ev((std::size_t) n, 0),
      trade((std::size_t) n), split((std::size_t) n, 0);
  std::vector<int32_t> tmp((std::size_t) n);
  for (int64_t i = 0; i < n; i++) liq[i] = I.liquidate && day[i] == I.stopp;
  const DayInfo di = day_info(n, day);   // seit 1.6.4 (A-084) einmal fuer beide Terminplaene
  dates_flags(n, di, I.bal, I.liquidate, tmp.data());
  for (int64_t i = 0; i < n; i++) reb[i] = (char) tmp[i];
  dates_flags(n, di, I.dca, I.liquidate, tmp.data());
  for (int64_t i = 0; i < n; i++) dca[i] = (char) tmp[i];
  if (I.event) {   // kein Rebalancing am Einstiegstag und (bei liquidate) am Liquidationstag
    for (int64_t i = 0; i < n; i++) {
      ev[i] = I.event[i] != 0 && day[i] != day[0] && (!I.liquidate || day[i] != I.stopp);
      reb[i] = I.event_replace ? ev[i] : (char) (reb[i] || ev[i]);
    }
  }
  for (int64_t i = 0; i < n; i++) trade[i] = !reb[i] && day[i] != I.stopp && !filled[i];
  if (I.split_on) {   // .calculate_split_flags: je Asset die Kursreihe nach jedem Split umrechnen (base = 100)
    std::vector<std::pair<int, double>> ops;
    for (int64_t a = 0; a < na; a++) {
      if (I.no_split[a]) continue;
      const double* p = I.price[a];
      ops.clear();
      for (int64_t i = 0; i < n; i++) {
        double cp = p[i];
        for (const auto& o : ops) cp = o.first ? cp * o.second : cp / o.second;
        if (cp > I.split_hi) {
          split[i] = 1;
          ops.emplace_back(0, cp / 100.0);
        } else if (cp < I.split_lo) {
          split[i] = 1;
          ops.emplace_back(1, 100.0 / cp);
        }
      }
    }
  }
  std::vector<double> dca_n((std::size_t) n);
  for (int64_t i = 0; i < n; i++) dca_n[i] = dca[i] ? 1.0 : 0.0;
  // V-1b: naechster Handelstag, am Monatsende der vorige (R: .shift_off_filled)
  auto target = [&](int64_t i) {
    int64_t j = i + 1;
    while (j < n && filled[j]) j++;
    if (j >= n || ym[j] != ym[i]) {
      j = i - 1;
      while (j >= 0 && filled[j]) j--;
    }
    return j;
  };
  auto shift = [&](std::vector<char>& f) {
    std::vector<int64_t> hit;
    for (int64_t i = 0; i < n; i++)
      if (f[i] && filled[i]) hit.push_back(i);
    for (int64_t i : hit) {
      const int64_t j = target(i);
      f[i] = 0;
      if (j >= 0 && j < n) f[j] = 1;
    }
  };
  if (any_filled) {
    shift(reb);
    std::vector<int64_t> hit;
    for (int64_t i = 0; i < n; i++)
      if (dca_n[i] != 0 && filled[i]) hit.push_back(i);
    for (int64_t i : hit) {   // Anzahl der Sparplantermine mitnehmen
      const int64_t j = target(i);
      if (j >= 0 && j < n) dca_n[j] = dca_n[j] + dca_n[i];
      dca_n[i] = 0.0;
    }
    shift(split);
    shift(liq);
    for (int64_t i = 0; i < n; i++) {
      if (liq[i]) { reb[i] = 0; dca_n[i] = 0.0; }
      dca[i] = dca_n[i] > 0;
      trade[i] = !reb[i] && day[i] != I.stopp && !filled[i];
    }
  }
  // .sim_init_weights: Startgewichte auf alle Assets bezogen, Startkapital auf die Start-Assets verteilt
  std::vector<double> sh_init, sh_all((std::size_t) na);
  for (int64_t a = 0; a < na; a++) {
    sh_all[a] = I.share[a];
    if (I.start[a] <= day[0]) sh_init.push_back(I.share[a]);
  }
  if (sh_init.empty()) return 3;
  const double isum = sl_r_sum((int64_t) sh_init.size(), sh_init.data(), 0);
  const double asum = sl_r_sum(na, sh_all.data(), 0);
  // .sim_build_schedule: Aktivierungstage (Start auf aufgefuellten Tagen verschoben), Startindizes
  std::vector<char> active((std::size_t) n, 0);
  for (int64_t a = 0; a < na; a++) {
    double s = I.start[a];
    const long k = fl_day(s) - z0;
    if (any_filled && k >= 0 && k < n && filled[k]) {
      int64_t j = target(k);
      j = std::max<int64_t>(std::min<int64_t>(j, n - 1), 0);
      s = day[j];
    }
    const long ks = fl_day(s) - z0;
    const bool in = ks >= 0 && ks < n;
    if (in) active[ks] = 1;
    const bool initial = I.start[a] <= day[0];
    int32_t* ax = O.aux + 3 * a;
    ax[0] = in ? (int32_t) ks + 1 : 1;
    ax[1] = in && day[ks] == s ? (int32_t) ks + 1 : 0;
    ax[2] = initial;
    const double sh = I.share[a];
    double* st = O.st0 + 8 * a;   // count, price, worth, money, total, target, actual, differ
    st[0] = st[1] = st[2] = 0.0;
    st[5] = sh;
    st[6] = sh / asum;
    st[7] = 0.0;
    st[3] = st[4] = initial ? I.start_value * (sh / isum) : 0.0;
    double* r0 = O.rep0 + 3 * a;
    r0[0] = 0.0;
    r0[1] = r0[2] = sh * I.start_value;
  }
  // Freibetrag: erster Handelstag ab harvest_day im Jahr (vor dem 31.12.)
  std::vector<char> harvest((std::size_t) n, 0);
  if (I.harvest_on) {
    int last = 0;
    bool seen = false;
    for (int64_t i = 0; i < n; i++) {
      if (md[i] < I.harvest_md || md[i] >= 1231 || filled[i] || (seen && year[i] == last)) continue;
      harvest[i] = 1;
      last = year[i];
      seen = true;
    }
  }
  bool has_bnh = false;
  for (int64_t a = 0; a < na; a++) has_bnh |= I.style[a] == 0;
  // Slow-Path dreiwertig wie R (NA aus Signalen: NA | FALSE = NA)
  std::vector<char> slow((std::size_t) n, 0);
  for (int64_t a = 0; a < na; a++) {
    if (I.style[a] != 1) continue;
    const double *b = I.sig_buy[a], *s = I.sig_sell[a];
    if (!b || !s) return 1;   // leere Zeiger nur ohne Signalstil (seit 1.6.1)
    for (int64_t i = 0; i < n; i++) {
      const int x = b[i] != b[i] ? 2 : b[i] != 0, y = s[i] != s[i] ? 2 : s[i] != 0;
      const int v = (x == 1 || y == 1) ? 1 : ((x == 2 || y == 2) ? 2 : 0);
      if (v == 1 || slow[i] == 1) slow[i] = 1;
      else if (v == 2) slow[i] = 2;
    }
  }
  std::vector<char> yc((std::size_t) n, 0), vp((std::size_t) n, 0);
  if (I.person) {
    for (int64_t i = 1; i < n; i++) yc[i] = year[i] > year[i - 1];
    for (int64_t ys = 1; ys < n; ys++) {
      if (!yc[ys]) continue;
      int64_t j = ys;
      while (j < n && filled[j] && year[j] == year[ys]) j++;
      // ohne Handelstag im Folgejahr am 1.1. abrechnen
      if (j >= n || year[j] != year[ys]) j = ys;
      vp[j] = 1;
    }
  }
  for (int64_t i = 0; i < n; i++) {
    const bool definite = active[i] || split[i] || dca[i] || reb[i] || md[i] == 1231 || liq[i] || harvest[i];
    int s = (definite || (has_bnh && i == 0) || vp[i]) ? 1 : slow[i];
    uint32_t f = 0;
    if (s == 1) f |= P_SLOW;
    if (s == 2) f |= P_SLOWNA;
    if (yc[i]) f |= P_YEAR;
    if (active[i]) f |= P_ACTIVE;
    if (split[i]) f |= P_SPLIT;
    if (dca[i]) f |= P_DCA;
    if (trade[i]) f |= P_TRADE;
    if (reb[i]) f |= P_REBAL;
    if (harvest[i]) f |= P_HARVEST;
    if (md[i] == 1231) f |= P_TAXES;
    if (liq[i]) f |= P_LIQ;
    if (ev[i]) f |= P_EVENT;
    if (vp[i]) f |= P_VPSETTLE;
    if (filled[i]) f |= P_FILLED;
    O.flags[i] = (int32_t) f;
    O.dca_n[i] = dca_n[i];
  }
  return 0;
}

// ── Flache Angaben der Hosts (R, Python, Julia) ─────────────────────────────────────────────────────
// Termine: si[SI_N] und start; days/dcode wie Sched
enum SchedInt { SI_ON = 0, SI_YEARS, SI_QUARTER, SI_END, SI_SKIP, SI_HAS_DAYS, SI_STEP, SI_N };
static inline Sched sched_of(const int32_t* si, double start, int64_t nd, const double* days, const int32_t* dcode) {
  Sched S;
  S.on = si[SI_ON]; S.years = si[SI_YEARS]; S.quarter = si[SI_QUARTER]; S.anchor_end = si[SI_END];
  S.skip = si[SI_SKIP]; S.has_days = si[SI_HAS_DAYS]; S.step = si[SI_STEP];
  S.start = start; S.nd = nd; S.days = days; S.dcode = dcode;
  return S;
}
// Laufangaben: pi[PI_N], pd[PD_N]; Termine des Sparplans (D) und des Rebalancings (B) je SI_N Werte ab PI_D bzw. PI_B
enum PrepInt { PI_LIQ = 0, PI_EV_REPLACE, PI_SPLIT_ON, PI_PERSON, PI_HARVEST_ON, PI_HARVEST_MD, PI_D,
               PI_B = PI_D + SI_N, PI_N = PI_B + SI_N };
enum PrepDbl { PD_STOPP = 0, PD_SPLIT_LO, PD_SPLIT_HI, PD_START_VALUE, PD_D_START, PD_B_START, PD_N };
struct PrepFlat {
  const int32_t* pi = nullptr;
  const double* pd = nullptr;
  const int32_t* filled = nullptr;   // n oder nullptr
  const int32_t* event = nullptr;    // n oder nullptr (ohne event_col)
  const double* start = nullptr;     // je Asset
  int64_t d_nd = 0, b_nd = 0;
  const double *d_days = nullptr, *b_days = nullptr;
  const int32_t *d_dcode = nullptr, *b_dcode = nullptr;
};
static inline void prep_from_flat(const PrepFlat& F, PrepIn& P) {
  P.filled = F.filled;
  P.event = F.event;
  P.start = F.start;
  P.liquidate = F.pi[PI_LIQ];
  P.event_replace = F.pi[PI_EV_REPLACE];
  P.split_on = F.pi[PI_SPLIT_ON];
  P.person = F.pi[PI_PERSON];
  P.harvest_on = F.pi[PI_HARVEST_ON];
  P.harvest_md = F.pi[PI_HARVEST_MD];
  P.stopp = F.pd[PD_STOPP];
  P.split_lo = F.pd[PD_SPLIT_LO];
  P.split_hi = F.pd[PD_SPLIT_HI];
  P.start_value = F.pd[PD_START_VALUE];
  P.dca = sched_of(F.pi + PI_D, F.pd[PD_D_START], F.d_nd, F.d_days, F.d_dcode);
  P.bal = sched_of(F.pi + PI_B, F.pd[PD_B_START], F.b_nd, F.b_days, F.b_dcode);
}

}  // namespace simlev_prepare

#endif  // SIMLEV_PREPARE_CORE_IMPL_H
