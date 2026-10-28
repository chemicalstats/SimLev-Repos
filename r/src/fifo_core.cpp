// ═══════════════════════════════════════════════════════════════════════════
// fifo_core.cpp — C++-Ports der rechenintensiven Stellen im Verkaufspfad (aktive Strategien)
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
#include "simlev_capi.h"
#include <algorithm>

static inline bool lot_is_null(SEXP b) {
  return Rf_isNull(b) || Rf_length(b) == 0;
}
static inline double lot_num(SEXP b, const char* fld) {
  return sl::as_double(sl::get(b, fld));
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
static double calculate_fifo_price(SEXP buys, double units, int front_index) {
  double units_trade = units;
  double total_price = 0.0;
  int i = front_index;              // 1-basiert wie in R
  const int n = Rf_xlength(buys);

  while (units_trade > 0 && i <= n) {
    SEXP bs = sl::at(buys, i - 1);
    if (lot_is_null(bs)) break;
    SEXP b = sl::as_list(bs);
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
static double calculate_fifo_vp(SEXP buys, double units, int front_index) {
  double units_trade = units;
  double total_vp = 0.0;
  int i = front_index;
  const int n = Rf_xlength(buys);

  while (units_trade > 0 && i <= n) {
    SEXP bs = sl::at(buys, i - 1);
    if (lot_is_null(bs)) break;
    SEXP b = sl::as_list(bs);
    double rem = lot_num(b, "remaining");
    if (rem > 0) {
      double sell = std::min(rem, units_trade);
      double lot_vp = sl::has(b, "vp") ? sl::as_double(sl::get(b, "vp")) : 0.0;
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
static SEXP calculate_private_sale_tax(SEXP buys, int front_index,
                                       double trade_count, double sell_price,
                                       int current_date) {
  double units_remaining = trade_count;
  int i = front_index;
  const int n = Rf_xlength(buys);
  double exempt_gain = 0, exempt_loss = 0, taxable_gain = 0, taxable_loss = 0;

  while (units_remaining > 0 && i <= n) {
    SEXP bs = sl::at(buys, i - 1);
    if (lot_is_null(bs)) break;
    SEXP b = sl::as_list(bs);
    double avail = lot_num(b, "remaining");
    if (avail > 0) {
      double sell = std::min(avail, units_remaining);
      int buy_days = static_cast<int>(sl::as_double(sl::get(b, "date")));   // Date -> Tage
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
  return sl::named_list(
    "exempt_gain",  exempt_gain,
    "exempt_loss",  exempt_loss,
    "taxable_gain", taxable_gain,
    "taxable_loss", taxable_loss,
    "total_gain",   exempt_gain - exempt_loss + taxable_gain - taxable_loss
  );
}

// FIFO-Verbrauch nach Verkauf (Port des Loops aus perform_trade_sell; .sim_fifo_consume_cpp)
// Mutiert remaining + vp in place; setzt fifo_front fort (update_fifo_front).
static void fifo_consume(SEXP input, const char* name, double trade_count) {
  SEXP trades = sl::as_list(sl::at(input, 3));   // Position 3 = trades (.SIM_MEM_LAYOUT); Aenderungen in place
  SEXP trades_name = sl::as_list(sl::get(trades, name));
  SEXP buys = sl::as_list(sl::get(trades_name, "buys"));
  const int buy_count = sl::as_int(sl::get(trades_name, "buy_count"));
  int front = sl::as_int(sl::get(trades_name, "fifo_front"));

  double units_remaining = trade_count;
  int i = front;

  while (units_remaining > 0 && i <= buy_count) {
    SEXP bs = sl::at(buys, i - 1);
    if (!lot_is_null(bs)) {
      SEXP b = sl::as_list(bs);
      double rem = lot_num(b, "remaining");
      if (rem > 0) {
        double red = std::min(rem, units_remaining);
        // F9: VP proportional VOR remaining reduzieren
        if (sl::has(b, "vp")) {
          double vp = sl::as_double(sl::get(b, "vp"));
          if (vp > 0 && rem > 0) sl::set(b, "vp", vp * (1.0 - red / rem));
        }
        sl::set(b, "remaining", rem - red);
        units_remaining -= red;
      }
    }
    ++i;
  }

  // update_fifo_front: vorruecken bis zum ersten Lot mit remaining > 0
  while (front <= buy_count) {
    SEXP bs = sl::at(buys, front - 1);
    if (lot_is_null(bs)) break;
    if (lot_num(sl::as_list(bs), "remaining") > 0) break;
    ++front;
  }
  sl::set(trades_name, "fifo_front", front);

  sl::set(trades, name, trades_name);
  sl::put(input, 3, trades);
}

// ═══════════════════════════════════════════════════════════════════════════
// .Call-Huellen (registriert in init.c; R-Seite in R/cores.R)
// ═══════════════════════════════════════════════════════════════════════════

extern "C" SEXP C_sim_fifo_price(SEXP s_buys, SEXP s_units, SEXP s_front_index) {
  return sl::call([&]() {
    SEXP buys = sl::as_list(s_buys);
    double units = sl::as_double(s_units);
    int front_index = sl::as_int(s_front_index);
    return sl::wrap(calculate_fifo_price(buys, units, front_index));
  });
}

extern "C" SEXP C_sim_fifo_vp(SEXP s_buys, SEXP s_units, SEXP s_front_index) {
  return sl::call([&]() {
    SEXP buys = sl::as_list(s_buys);
    double units = sl::as_double(s_units);
    int front_index = sl::as_int(s_front_index);
    return sl::wrap(calculate_fifo_vp(buys, units, front_index));
  });
}

extern "C" SEXP C_sim_private_sale_tax(SEXP s_buys, SEXP s_front_index, SEXP s_trade_count,
                                       SEXP s_sell_price, SEXP s_current_date) {
  return sl::call([&]() {
    SEXP buys = sl::as_list(s_buys);
    int front_index = sl::as_int(s_front_index);
    double trade_count = sl::as_double(s_trade_count);
    double sell_price = sl::as_double(s_sell_price);
    int current_date = sl::as_int(s_current_date);
    return calculate_private_sale_tax(buys, front_index, trade_count, sell_price, current_date);
  });
}

extern "C" SEXP C_sim_fifo_consume(SEXP s_input, SEXP s_name, SEXP s_trade_count) {
  return sl::call([&]() {
    SEXP input = sl::as_list(s_input);
    const char* name = sl::as_cstring(s_name);
    double trade_count = sl::as_double(s_trade_count);
    fifo_consume(input, name, trade_count);
    return R_NilValue;
  });
}
