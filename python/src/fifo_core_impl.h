// ═══════════════════════════════════════════════════════════════════════════
// fifo_core_impl.cpp — C++-Ports der rechenintensiven Stellen im Verkaufspfad (aktive Strategien)
// (Dateiname aus der Rcpp-Zeit; seit 0.5.0 ueber R's C-Schnittstelle angebunden, simlev_capi.h)
// 1:1-Semantik zu den R-Originalen in simulation.R:
//   calculate_fifo_price, calculate_fifo_vorabpauschale,
//   calculate_private_sale_tax (§ 23 EStG inkl. kalendergenauer Jahresfrist
//   mit 29.02.-Sonderfall, § 188 Abs. 3 BGB), FIFO-Verbrauchsschleife aus perform_trade_sell
//   (inkl. proportionaler VP-Reduktion, F9) sowie update_fifo_front.
// Alle Schleifen brechen bei NULL-Lots ab bzw. ueberspringen sie genau wie die R-Vorlagen.
// sim_mem (.sim_fifo_consume_cpp): oberste Ebene ueber die Position, input[3] = trades
// (0-basiert; Feldfolge wie in simulation_core.cpp beschrieben, festgelegt in .SIM_MEM_LAYOUT,
// geprueft von .sim_check_layout()). Die Lots (remaining, vp) und fifo_front werden an Ort und
// Stelle geaendert; die uebrigen Funktionen lesen nur.
// ═══════════════════════════════════════════════════════════════════════════
//
// GEMEINSAME QUELLE FUER R UND PYTHON (Etappe 7.3a): Die Kerne arbeiten auf dem
// Simulationszustand des Hosts (R: die Listen von sim_mem; Python: die dict/list-
// Struktur sim aus simlev/_sim_phases.py) ueber die Zugriffe simlev_host::as_list,
// get, set, put, at, has, as_double, as_int, num_vec, named_list und die Makros
// SIMLEV_XLENGTH, SIMLEV_LENGTH, SIMLEV_IS_NULL, SIMLEV_STRING_AT (Schnittstelle in
// simlev_core.h). Fuer R sind das genau die frueheren Aufrufe aus simlev_capi.h
// (simlev_host nimmt den Namensraum sl auf), der Compiler erzeugt daher denselben
// Maschinencode wie vor der Teilung (geprueft per Disassemblierung); Python stellt
// dieselben Zugriffe auf seine Objekte (python/src/_ext_common.h, _ext_engine.cpp).
// R ruft die Kerne ueber die .Call-Huellen in src/fifo_core.cpp auf, Python ueber
// simlev._ext. Python baut aus einer Byte-fuer-Byte-Kopie in python/src/
// (python/tests/test_shared_c.py); Aenderungen nur hier vornehmen und danach
// kopieren. Die reinen Python-Kerne (simlev/_core.py) rechnen dasselbe und bleiben
// der Rueckfall.

#ifndef SIMLEV_FIFO_CORE_IMPL_H
#define SIMLEV_FIFO_CORE_IMPL_H

// Gleitkomma wie im Pilot (simlev_core.h): Abbruch bei -ffast-math; kein
// Zusammenziehen von a * b + c zu fma. Das Pragma steht nur dort, wo der Compiler
// fma ueberhaupt erzeugen kann (__FP_FAST_FMA, etwa aarch64 oder -mfma): auf
// x86-64 ohne FMA ist -ffp-contract=off wirkungslos, das GCC-Pragma optimize
// veraendert dort aber die Codeerzeugung der ganzen Datei (geprueft), und R soll
// denselben Maschinencode wie vor der Teilung ausfuehren. Python baut immer mit
// -ffp-contract=off (setup.py) und setzt SIMLEV_FP_CONTRACT_BY_FLAG.
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
#if !defined(SIMLEV_XLENGTH) || !defined(SIMLEV_STRING_AT)
#error "Vor diesem Kern den Host einbinden: R simlev_capi.h, Python _ext_common.h (siehe simlev_core.h)."
#endif

#include <algorithm>

namespace simlev {

static inline bool lot_is_null(simlev_host::Obj b) {
  return SIMLEV_IS_NULL(b) || SIMLEV_LENGTH(b) == 0;
}
static inline double lot_num(simlev_host::Obj b, const char* fld) {
  return simlev_host::as_double(simlev_host::get(b, fld));
}

// ── Kalender-Hilfsfunktionen (Howard Hinnant, exakt fuer den proleptischen gregorianischen Kalender)
static inline long days_from_civil(int y, int m, int d) {
  y -= m <= 2;
  const int era = (y >= 0 ? y : y - 399) / 400;
  const unsigned yoe = static_cast<unsigned>(y - era * 400);
  const unsigned doy = (153u * (m + (m > 2 ? -3 : 9)) + 2u) / 5u + d - 1u;
  const unsigned doe = yoe * 365u + yoe / 4u - yoe / 100u + doy;
  return era * 146097L + static_cast<long>(doe) - 719468L;
}
static inline void civil_from_days(long z, int& y, int& m, int& d) {
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
static inline bool is_leap(int y) {
  return (y % 4 == 0 && y % 100 != 0) || (y % 400 == 0);
}

// FIFO-gewichteter Einstandspreis (C++-Port von calculate_fifo_price; .sim_fifo_price_cpp)
static double calculate_fifo_price(simlev_host::Obj buys, double units, int front_index) {
  double units_trade = units;
  double total_price = 0.0;
  int i = front_index;              // 1-basiert wie in R
  const int n = SIMLEV_XLENGTH(buys);

  while (units_trade > 0 && i <= n) {
    simlev_host::Obj bs = simlev_host::at(buys, i - 1);
    if (lot_is_null(bs)) break;
    simlev_host::Obj b = simlev_host::as_list(bs);
    double rem = lot_num(b, "remaining");
    if (rem > 0) {
      double sell = std::min(rem, units_trade);
      total_price += sell * lot_num(b, "price");
      units_trade -= sell;
    }
    ++i;
  }
  return (units > 0) ? total_price / units : 0.0;
}

// Anteilige Vorabpauschale fuer FIFO-Verkauf (Port von calculate_fifo_vorabpauschale;
// .sim_fifo_vp_cpp)
static double calculate_fifo_vp(simlev_host::Obj buys, double units, int front_index) {
  double units_trade = units;
  double total_vp = 0.0;
  int i = front_index;
  const int n = SIMLEV_XLENGTH(buys);

  while (units_trade > 0 && i <= n) {
    simlev_host::Obj bs = simlev_host::at(buys, i - 1);
    if (lot_is_null(bs)) break;
    simlev_host::Obj b = simlev_host::as_list(bs);
    double rem = lot_num(b, "remaining");
    if (rem > 0) {
      double sell = std::min(rem, units_trade);
      double lot_vp = simlev_host::has(b, "vp") ? simlev_host::as_double(simlev_host::get(b, "vp")) : 0.0;
      if (rem > 0 && lot_vp > 0) {
        total_vp += sell * (lot_vp / rem);   // F9: Basis = remaining
      }
      units_trade -= sell;
    }
    ++i;
  }
  return total_vp;
}

// § 23 EStG lot-weise (Port von calculate_private_sale_tax; .sim_private_sale_tax_cpp)
// current_date als Integer (Tage seit 1970-01-01)
static simlev_host::Obj calculate_private_sale_tax(simlev_host::Obj buys, int front_index,
                                       double trade_count, double sell_price,
                                       int current_date) {
  double units_remaining = trade_count;
  int i = front_index;
  const int n = SIMLEV_XLENGTH(buys);
  double exempt_gain = 0, exempt_loss = 0, taxable_gain = 0, taxable_loss = 0;

  while (units_remaining > 0 && i <= n) {
    simlev_host::Obj bs = simlev_host::at(buys, i - 1);
    if (lot_is_null(bs)) break;
    simlev_host::Obj b = simlev_host::as_list(bs);
    double avail = lot_num(b, "remaining");
    if (avail > 0) {
      double sell = std::min(avail, units_remaining);
      int buy_days = static_cast<int>(simlev_host::as_double(simlev_host::get(b, "date")));   // Date -> Tage
      double buy_price = lot_num(b, "price");

      // T-3: "mehr als ein Jahr" kalendergenau (§§ 187 Abs. 1, 188 Abs. 2 BGB:
      // Fristende am gleichnamigen Tag des Folgejahres); Kauf am 29.02.: der Tag
      // fehlt im Folgejahr, Fristende 28.02. (§ 188 Abs. 3 BGB), ab 01.03. frei
      int y, m, d;
      civil_from_days(buy_days, y, m, d);
      long one_year_later;
      if (m == 2 && d == 29 && !is_leap(y + 1)) {
        one_year_later = days_from_civil(y + 1, 2, 28);
      } else {
        one_year_later = days_from_civil(y + 1, m, d);
      }
      bool is_exempt = current_date > one_year_later;

      double lot_gain = sell * (sell_price - buy_price);
      if (is_exempt) {
        if (lot_gain >= 0) exempt_gain += lot_gain; else exempt_loss += -lot_gain;
      } else {
        if (lot_gain >= 0) taxable_gain += lot_gain; else taxable_loss += -lot_gain;
      }
      units_remaining -= sell;
    }
    ++i;
  }
  return simlev_host::named_list(
    "exempt_gain",  exempt_gain,
    "exempt_loss",  exempt_loss,
    "taxable_gain", taxable_gain,
    "taxable_loss", taxable_loss,
    "total_gain",   exempt_gain - exempt_loss + taxable_gain - taxable_loss
  );
}

// FIFO-Verbrauch nach Verkauf (Port des Loops aus perform_trade_sell; .sim_fifo_consume_cpp)
// Mutiert remaining + vp in place; setzt fifo_front fort (update_fifo_front).
static void fifo_consume(simlev_host::Obj input, const char* name, double trade_count) {
  simlev_host::Obj trades = simlev_host::as_list(simlev_host::at(input, 3));   // Position 3 = trades (.SIM_MEM_LAYOUT); Aenderungen in place
  simlev_host::Obj trades_name = simlev_host::as_list(simlev_host::get(trades, name));
  simlev_host::Obj buys = simlev_host::as_list(simlev_host::get(trades_name, "buys"));
  const int buy_count = simlev_host::as_int(simlev_host::get(trades_name, "buy_count"));
  int front = simlev_host::as_int(simlev_host::get(trades_name, "fifo_front"));

  double units_remaining = trade_count;
  int i = front;

  while (units_remaining > 0 && i <= buy_count) {
    simlev_host::Obj bs = simlev_host::at(buys, i - 1);
    if (!lot_is_null(bs)) {
      simlev_host::Obj b = simlev_host::as_list(bs);
      double rem = lot_num(b, "remaining");
      if (rem > 0) {
        double red = std::min(rem, units_remaining);
        // F9: VP proportional VOR remaining reduzieren
        if (simlev_host::has(b, "vp")) {
          double vp = simlev_host::as_double(simlev_host::get(b, "vp"));
          if (vp > 0 && rem > 0) simlev_host::set(b, "vp", vp * (1.0 - red / rem));
        }
        simlev_host::set(b, "remaining", rem - red);
        units_remaining -= red;
      }
    }
    ++i;
  }

  // update_fifo_front: vorruecken bis zum ersten Lot mit remaining > 0
  while (front <= buy_count) {
    simlev_host::Obj bs = simlev_host::at(buys, front - 1);
    if (lot_is_null(bs)) break;
    if (lot_num(simlev_host::as_list(bs), "remaining") > 0) break;
    ++front;
  }
  simlev_host::set(trades_name, "fifo_front", front);

  simlev_host::set(trades, name, trades_name);
  simlev_host::put(input, 3, trades);
}

}  // namespace simlev

#endif
