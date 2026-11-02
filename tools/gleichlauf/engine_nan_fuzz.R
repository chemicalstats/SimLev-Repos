# N10: R-Lauf der Zufallsprüfung der Engine-Kerne (Fälle aus engine_nan_fuzz.py gen); schreibt <ordner>/r.txt.
#   Rscript tools/gleichlauf/engine_nan_fuzz.R <ordner>
args <- commandArgs(TRUE)
d <- args[1]
ns <- asNamespace("SimLev")
.b <- function(h) readBin(as.raw(strtoi(substring(h, seq(1, 15, 2), seq(2, 16, 2)), 16L)), "double", n = 1L, endian = "big")
.S <- list(sNA = .b("7ff00000000007a2"), sqNA = .b("7ff80000000007a2"), smNA = .b("fff80000000007a2"),
           sNaN = .b("7ff8000000000000"), smNaN = .b("fff8000000000000"), sInf = Inf, smInf = -Inf, sm0 = -0)
.D <- function(x) structure(as.double(x), class = "Date")
source(file.path(d, "cases.R"))
STATUS <- c("count", "price", "worth", "money", "total", "target", "actual", "differ")
REPORT <- c("worth", "money", "flows", "total", "share")
LOT <- c("date", "count", "price", "remaining", "original", "vp")
TOTALS <- c("total_taxes", "loss_capital_gains", "sparer_pauschbetrag_remaining", "sparer_pauschbetrag_used_total",
            "cgt_base_taxed_ytd", "cgt_loss_added_ytd", "cgt_loss_used_ytd")
hx <- function(x) {
  x <- as.double(unclass(x))
  if (!length(x)) return("")
  r <- writeBin(x, raw(), endian = "big")
  h <- sprintf("%02x", as.integer(r))
  vapply(seq_along(x), function(i) paste(h[(8 * i - 7):(8 * i)], collapse = ""), "")
}
out <- character(0)
ln <- function(id, path, x, ints = FALSE) {
  v <- if (!length(x)) "" else if (ints) paste0("i", as.integer(x)) else hx(x)
  out[[length(out) + 1L]] <<- paste(id, path, paste(v, collapse = " "))
}
emit_sim <- function(id, sim, n0) {
  for (a in sim$assets) {
    for (f in STATUS) ln(id, sprintf("status/%s/%s", a, f), sim$status[[a]][[f]])
    for (f in REPORT) ln(id, sprintf("report/%s/%s", a, f), sim$report[[a]][[f]])
    t <- sim$trades[[a]]
    ln(id, sprintf("trades/%s/fifo_front", a), t$fifo_front, TRUE)
    n <- max(n0[[a]], t$buy_count)
    ln(id, sprintf("trades/%s/n", a), n, TRUE)
    for (j in seq_len(n)) {
      l <- t$buys[[j]]
      ln(id, sprintf("trades/%s/%d", a, j), vapply(LOT, function(f) if (is.null(l[[f]])) 0 else as.double(l[[f]]), 0))
    }
  }
}
for (c in CASES) {
  a <- c$a; id <- c$id; k <- c$k
  r <- tryCatch({
    if (!is.null(c$sim)) {
      sim <- c$sim
      n0 <- lapply(sim$trades, function(t) length(t$buys))
      for (nm in names(sim$trades)) sim$trades[[nm]]$buys <- c(sim$trades[[nm]]$buys, vector("list", 16L))
      switch(k,
        dca = .Call(ns$C_sim_dca_flows, sim, a$name, a$flows, a$index),
        buy_report = .Call(ns$C_sim_buy_report, sim, a$name, a$index, a$tc, a$tp, a$mp),
        sell_report = .Call(ns$C_sim_sell_report, sim, a$name, a$index, a$tc, a$tp, a$mp, a$cgt),
        total_report = .Call(ns$C_sim_total_report, sim, sim$assets, a$index),
        buy = .Call(ns$C_sim_buy, sim, a$name, a$index, a$tc, a$tp, a$mp),
        market_update = .Call(ns$C_sim_market_update, sim, sim$assets, a$index),
        market_update_batch = .Call(ns$C_sim_market_update_batch, sim, sim$assets, a$s, a$e),
        fifo_consume = .Call(ns$C_sim_fifo_consume, sim, a$name, a$tc))
      emit_sim(id, sim, n0)
    } else if (!is.null(c$totals)) {
      tt <- c$totals
      res <- if (k == "p20_tax") .Call(ns$C_sim_p20_tax, a$x, a$bonus, tt, a$rate, a$spb)
             else .Call(ns$C_sim_vp_tax, a$x, a$bonus, tt, a$rate, a$spb)
      for (f in names(res)) ln(id, paste0("res/", f), res[[f]])
      for (f in TOTALS) ln(id, paste0("totals/", f), tt[[f]])
    } else {
      b <- c$buys
      switch(k,
        fifo_price = ln(id, "res", .Call(ns$C_sim_fifo_price, b, a$units, a$front)),
        fifo_vp = ln(id, "res", .Call(ns$C_sim_fifo_vp, b, a$units, a$front)),
        private_sale_tax = {
          res <- .Call(ns$C_sim_private_sale_tax, b, a$front, a$tc, a$sp, a$date)
          for (f in names(res)) ln(id, paste0("res/", f), res[[f]])
        },
        flat_rate = {
          res <- .Call(ns$C_sim_flat_rate, b, a$front, a$br, a$ysp, a$mp, a$soy, a$eoy)
          ln(id, "res/total_vp", res$total_vp)
          ln(id, "res/lot_indices", res$lot_indices, TRUE)
          ln(id, "res/lot_vps", res$lot_vps)
        },
        sell_count = {
          res <- .Call(ns$C_sim_sell_count, b, a$front, a$target, a$tp, a$shares, a$fractions, a$regime, a$bonus,
                       a$pool, a$rate)
          for (f in names(res)) ln(id, paste0("res/", f), res[[f]])
        })
    }
    NULL
  }, error = function(e) e)
  if (inherits(r, "error")) out[[length(out) + 1L]] <- paste(id, "FEHLER", conditionMessage(r))
}
writeLines(out, file.path(d, "r.txt"))
cat("R:", length(out), "Zeilen\n")
