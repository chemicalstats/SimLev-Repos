// src/fifo_core.cpp
// .Call-Huellen der Engine-Kerne aus src/fifo_core_impl.h (Etappe 7.3a).
//
// Die Kerne (Rechnung und Zugriffe auf sim_mem) stehen seit Etappe 7.3a in
// src/fifo_core_impl.h (gemeinsam mit Python: simlev._ext; kanonisch in core/, F16); diese Datei
// bindet sie mit dem R-Host aus simlev_capi.h ein und enthaelt die .Call-Huellen
// (Umwandlung der Argumente wie frueher).

#include "simlev_capi.h"
#include "fifo_core_impl.h"

// ═══════════════════════════════════════════════════════════════════════════
// .Call-Huellen (registriert in init.c; R-Seite in R/cores.R)
// ═══════════════════════════════════════════════════════════════════════════

extern "C" SEXP C_sim_fifo_price(SEXP s_buys, SEXP s_units, SEXP s_front_index) {
  return sl::call([&]() {
    SEXP buys = sl::as_list(s_buys);
    double units = sl::as_double(s_units);
    int front_index = sl::as_int(s_front_index);
    return sl::wrap(simlev::calculate_fifo_price(buys, units, front_index));
  });
}

extern "C" SEXP C_sim_fifo_vp(SEXP s_buys, SEXP s_units, SEXP s_front_index) {
  return sl::call([&]() {
    SEXP buys = sl::as_list(s_buys);
    double units = sl::as_double(s_units);
    int front_index = sl::as_int(s_front_index);
    return sl::wrap(simlev::calculate_fifo_vp(buys, units, front_index));
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
    return simlev::calculate_private_sale_tax(buys, front_index, trade_count, sell_price, current_date);
  });
}

extern "C" SEXP C_sim_fifo_consume(SEXP s_input, SEXP s_name, SEXP s_trade_count) {
  return sl::call([&]() {
    SEXP input = sl::as_list(s_input);
    const char* name = sl::as_cstring(s_name);
    double trade_count = sl::as_double(s_trade_count);
    simlev::fifo_consume(input, name, trade_count);
    return R_NilValue;
  });
}
