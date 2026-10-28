# =============================================================================
# simulation(), Phase 3: Zahlungs- und Abrechnungshelfer der Tagesschleife
# =============================================================================

#' Phase 3 von simulation(): Helfer fuer Kaeufe mit Gebuehr, Zahlungen und Steuerabrechnung
#'
#' Zweck: erzeugt die Hilfsfunktionen, die Tagesschleife und Jahresabschluss gemeinsam nutzen
#' (Kauf mit Sparplan- bzw. Ordergebuehr, Verkaufsmenge nach Steuer und Gebuehr,
#' Steuerzahlung mit Zwangsverkauf, Abrechnung von Vorabpauschale, Paragraf-23-Steuer und
#' Erstattung aus der Guenstigerpruefung). Die Helfer teilen den Zaehler der nicht gedeckten
#' Steuerzahlungen (tax_unpaid_total).
#' Eingabe: cfg (aus .sim_check_inputs), fl (Flags aus .sim_build_schedule), details.
#' Ausgabe: Liste der Helfer (Namen wie im Code: .buy_with_fee, .sell_count_net,
#' .pay_one, .pay_tax, .pay_vp, .settle_p23, .gp_pending, .settle_gp, .vp_taxes, .settle_vp) und
#' tax_unpaid() (Summe der nicht gedeckten Steuerzahlungen in EUR).
#' @keywords internal
#' @noRd
.sim_make_actions <- function(cfg, fl, details) {
  tax_mode <- cfg$tax_mode; tax_rate <- cfg$tax_rate; effective_tax_rate <- cfg$effective_tax_rate
  marginal_tax_rate <- cfg$marginal_tax_rate; private_sale_threshold <- cfg$private_sale_threshold
  use_sparer_pauschbetrag <- cfg$use_sparer_pauschbetrag; fractions <- cfg$fractions
  fees_on <- cfg$fees_on; fee_order <- cfg$fee_order; fee_dca <- cfg$fee_dca; tariff_env <- cfg$tariff_env
  flag_date <- fl$flag_date; flag_assets <- fl$flag_assets; flag_dca <- fl$flag_dca
  strategy_types <- fl$strategy_types; tax_regimes <- fl$tax_regimes; spread_rates <- fl$spread_rates

  # R1-04: Kauf eines Buy-and-Hold-Assets am Sparplantag mit dca_fee, sonst order_fee.
  # R2-01: am ersten Tag enthaelt das Cash auch das Startkapital -> dieses mit order_fee,
  # nur der Sparraten-Anteil (flows des Tages) mit dca_fee (zwei Orders)
  .buy_with_fee <- function(sim_mem, name, time, reason) {
    if (fees_on && flag_dca[time] && strategy_types[[name]] == "bnh") {
      money <- sim_mem[["status"]][[name]][["money"]]
      dca_part <- min(max(0, sim_mem[["report"]][[name]][["flows"]][time]), money)
      if (time == 1L && money - dca_part > 0.005) {
        .fee_env$current <- fee_order
        sim_mem[["status"]][[name]][["money"]] <- money - dca_part
        sim_mem <- .perform_trade_buy(input = sim_mem, name = name, index = time, reason = reason,
                                     spread = spread_rates[[name]], fractions = fractions, details = details)
        sim_mem[["status"]][[name]][["money"]] <- sim_mem[["status"]][[name]][["money"]] + dca_part
      }
      .fee_env$current <- fee_dca
    }
    sim_mem <- .perform_trade_buy(input = sim_mem, name = name, index = time, reason = reason,
                                 spread = spread_rates[[name]], fractions = fractions, details = details)
    if (fees_on) .fee_env$current <- fee_order
    sim_mem
  }

  # Verkaufsmenge, deren Erloes nach Steuer UND Ordergebuehr 'need' deckt (R1-18).
  # Ohne Ordergebuehr identisch mit .calculate_sell_count(target = need). Steuerschaetzung mit dem
  # effektiven Satz (Guenstigerpruefung), wie beim Verkauf selbst (R3a-04).
  # round_up = TRUE (Zwangsverkauf fuer eine Zahlung, R3a-03): bei fractions = FALSE die
  # aufgerundete statt der naechstliegenden Stueckzahl (fifo_price = NULL: Verkauf rechnet FIFO selbst)
  .sell_count_net <- function(sim_mem, name, need, time, round_up = FALSE) {
    fr <- fractions || round_up
    sc_of <- function(target) .calculate_sell_count(
      input = sim_mem, name = name, target = target, index = time,
      spread = spread_rates[[name]], fractions = fr,
      tax_mode = tax_mode, tax_rate = effective_tax_rate,
      marginal_tax_rate = marginal_tax_rate, tax_regime = tax_regimes[[name]])
    fee <- .fee_env$current
    target <- need
    if (!is.null(fee)) {
      px <- .apply_spread(sim_mem[["market"]][[name]][["asset_price"]][time], spread_rates[[name]], "sell")
      for (k in 1:3) target <- need + .fee_amount(fee, max(sc_of(target)[["sell_count"]], 1e-12) * px)
    }
    res <- sc_of(target)
    if (round_up && !fractions && res[["sell_count"]] > 0)
      res <- list(sell_count = min(sim_mem[["status"]][[name]][["count"]], ceiling(res[["sell_count"]] - 1e-9)),
                  fifo_price = NULL)
    res
  }

  # Zahlung (Steuer) aus einem Asset: Fall A Cash, Fall B Zwangsverkauf zum Geldkurs (Spread,
  # Ordergebuehr) zu den Kursen von flag_date[time]. R3a-03: Stueckzahl aufgerundet und bei
  # Restfehlbetrag nachverkauft, nie still auf 0 gekappt. Rueckgabe: list(sim_mem,
  # unpaid = nicht gedeckter Rest, wenn das Asset keinen Bestand mehr hat).
  .pay_one <- function(sim_mem, name, amount, time, label) {
    money <- sim_mem[["status"]][[name]][["money"]]
    if (money >= amount) {
      sim_mem[["status"]][[name]][["money"]] <- money - amount
      if (details) {
        cat(sprintf("Steuerereignis:\tZahlung %s %.2f EUR f\u00fcr %s aus dem Geldbestand am %s\n",
                    label, amount, name, flag_date[time]))
      }
      return(list(sim_mem = sim_mem, unpaid = 0))
    }
    remaining <- amount
    if (money > 0) {
      remaining <- amount - money
      sim_mem[["status"]][[name]][["money"]] <- 0
      if (details) {
        cat(sprintf("Steuerereignis:\tTeilzahlung %s %.2f EUR aus dem Geldbestand am %s\n",
                    label, money, flag_date[time]))
      }
    }
    c0 <- sim_mem[["status"]][[name]][["money"]]
    raised <- function(sm) sm[["status"]][[name]][["money"]] - c0
    for (k in 1:10) {
      short <- remaining - raised(sim_mem)
      if (short <= 0.005 || sim_mem[["status"]][[name]][["count"]] <= 0) break   # Rest < 1/2 Cent: Rundung
      sell_result <- .sell_count_net(sim_mem, name, short, time, round_up = TRUE)
      n_sell <- sell_result[["sell_count"]]
      if (k > 1 || !(n_sell > 0))   # Nachverkauf: mindestens ein Stueck bzw. der Rest
        n_sell <- max(n_sell, if (fractions) min(sim_mem[["status"]][[name]][["count"]], 1e-6) else min(1, sim_mem[["status"]][[name]][["count"]]))
      before <- raised(sim_mem)
      sim_mem <- .perform_trade_sell(
        input = sim_mem, count = n_sell,
        price = sell_result[["fifo_price"]], name = name, index = time,
        tax_mode = tax_mode, tax_rate = tax_rate,
        effective_tax_rate = effective_tax_rate,
        marginal_tax_rate = marginal_tax_rate,
        private_sale_threshold = private_sale_threshold,
        use_sparer_pauschbetrag = use_sparer_pauschbetrag,
        tax_regime = tax_regimes[[name]], reason = "Steuerereignis:",
        spread = spread_rates[[name]], details = details)
      if (raised(sim_mem) <= before) break           # kein Erloes (z. B. Gebuehr > Erloes)
    }
    short <- remaining - raised(sim_mem)
    unpaid <- 0
    if (short <= 0.005) {                            # gedeckt (Rest < 1/2 Cent: Rundung der Bisektion, bleibt sichtbar)
      sim_mem[["status"]][[name]][["money"]] <- sim_mem[["status"]][[name]][["money"]] - remaining
    } else {                                         # Asset erschoepft: Erloes zahlen, Rest offen
      sim_mem[["status"]][[name]][["money"]] <- c0
      unpaid <- short
    }
    if (details && remaining - unpaid > 0) {
      cat(sprintf("\t\t=> Anteile verkauft f\u00fcr den Rest von %.2f EUR (%s)\n", remaining - unpaid, label))
    }
    list(sim_mem = sim_mem, unpaid = unpaid)
  }

  # Zahlung einer Steuer, die 'name' zugeordnet ist; reicht das Asset nicht, zahlen die uebrigen
  # Assets (nach Wert absteigend, je Cash vor Verkauf). Ein danach offener Rest bleibt als negativer
  # Geldbestand (Steuerschuld) bei 'name' stehen (Warnung).
  tax_unpaid_total <- 0   # Summe nicht gedeckter Steuerzahlungen (Grundlage fuer tax_report$open_tax_debt)
  .pay_tax <- function(sim_mem, name, amount, time, label) {
    r <- .pay_one(sim_mem, name, amount, time, label)
    sim_mem <- r$sim_mem; unpaid <- r$unpaid
    if (unpaid > 1e-6) {
      others <- setdiff(flag_assets, name)
      val <- vapply(others, function(nm) sim_mem[["status"]][[nm]][["count"]] * sim_mem[["market"]][[nm]][["asset_price"]][time] +
                                           max(0, sim_mem[["status"]][[nm]][["money"]]), numeric(1))
      for (nm in others[order(-val)]) {
        if (unpaid <= 1e-6) break
        if (!(val[[nm]] > 0)) next
        r <- .pay_one(sim_mem, nm, unpaid, time, label)
        sim_mem <- r$sim_mem; unpaid <- r$unpaid
      }
    }
    if (unpaid > 1e-6) {
      sim_mem[["status"]][[name]][["money"]] <- sim_mem[["status"]][[name]][["money"]] - unpaid
      tax_unpaid_total <<- tax_unpaid_total + unpaid
      warning(sprintf("simulation: %s von %.2f EUR am %s: das Depot reicht nicht aus; %.2f EUR bleiben als negativer Geldbestand (Steuerschuld) bei '%s'.",
                      label, amount, format(flag_date[time]), unpaid, name), call. = FALSE)
    }
    sim_mem
  }

  # § 18 Abs. 3 InvStG: begleicht eine festgesetzte Vorabpauschale (Fall A: Cash,
  # Fall B: Zwangsverkauf) zu den Kursen von flag_date[time] und verbucht den Entry.
  # prepaid (A7-11): bereits im Vorjahr (Zwangsverkauf am 31.12.) gezahlter Betrag; nur die Differenz
  # zur endgueltigen Steuer wird nachgezahlt bzw. dem Cash gutgeschrieben
  .pay_vp <- function(sim_mem, name, tax_debt, time, meta, prepaid = 0) {
    if (prepaid == 0) {
      sim_mem <- .pay_tax(sim_mem, name, tax_debt, time, "Vorabpauschale")
    } else if (tax_debt - prepaid > 1e-9) {
      sim_mem <- .pay_tax(sim_mem, name, tax_debt - prepaid, time, "Vorabpauschale")
    } else if (tax_debt - prepaid < -1e-9) {
      sim_mem[["status"]][[name]][["money"]] <- sim_mem[["status"]][[name]][["money"]] + (prepaid - tax_debt)
    }
    sim_mem[["totals"]][["total_taxes"]] <- sim_mem[["totals"]][["total_taxes"]] + tax_debt
    trades_entry <- list(
      event_date = flag_date[time],
      assessment_date = meta[["assessment_date"]],
      event_type = "Vorabpauschale",
      flat_rate_gross = meta[["flat_rate"]],
      bonus_applied = meta[["bonus"]],
      flat_rate_taxable = meta[["flat_rate"]] * (1 - meta[["bonus"]]),
      spb_used = meta[["spb_used"]],
      taxes_paid = tax_debt
    )
    sim_mem[["trades"]][[name]][["tax_count"]] <- sim_mem[["trades"]][[name]][["tax_count"]] + 1
    sim_mem[["trades"]][[name]][["taxes"]][[sim_mem[["trades"]][[name]][["tax_count"]]]] <- trades_entry
    sim_mem
  }

  # R3a-02: § 23-Steuer des Vorjahres (in .handle_year_change festgesetzt und in total_taxes gebucht)
  # aus dem Depot zahlen, am Abrechnungstag der Vorabpauschale (nach dieser) bzw. am letzten Tag
  # R9-02: Im Tarifweg ist p23_due die Nachzahlung der Jahresveranlagung (Paragraf-23-Steuer, Wirkung der
  # Kirchensteuer-Sonderausgaben, Guenstigerpruefung), auch ohne Paragraf-23-Gewinn; die details-Ausgabe
  # und die Bezeichnung der Zahlung nennen deshalb die Veranlagung und ihre Bestandteile (nur Text)
  .settle_p23 <- function(sim_mem, time) {
    due <- sim_mem[["totals"]][["p23_due"]]
    sim_mem[["totals"]][["p23_due"]] <- NULL
    info <- if (!is.null(tariff_env)) tariff_env$due_info
    if (!is.null(tariff_env)) tariff_env$due_info <- NULL
    label <- if (length(info)) sprintf("Steuer aus der Veranlagung %s",
                                       paste(vapply(info, function(i) as.character(i$year), ""), collapse = "/")) else "\u00a7 23-Steuer"
    if (details && length(info) && any(due > 0)) {
      for (i in info) {
        rest <- i$D - i$p23 - i$ded
        cat(sprintf("Steuerereignis:\tVeranlagung %d: Nachzahlung %.2f EUR (davon \u00a7 23 %.2f EUR, Kirchensteuer-Sonderausgaben %.2f EUR%s) am %s, aufgeteilt %s\n",
                    i$year, i$D, i$p23, i$ded, if (abs(rest) >= 0.005) sprintf(", G\u00fcnstigerpr\u00fcfung %.2f EUR", rest) else "",
                    flag_date[time], if (i$by_p23) "nach dem \u00a7 23-Jahressaldo je Asset" else "zu gleichen Teilen auf die Assets"))
      }
    }
    for (nm in names(due)) {
      if (!(due[[nm]] > 0)) next
      if (details) {
        if (length(info)) cat(sprintf("\t\t=> Anteil %s: %.2f EUR\n", nm, due[[nm]]))
        else cat(sprintf("Steuerereignis:\t\u00a7 23 EStG: Steuer %.2f EUR (%s) am %s\n", due[[nm]], nm, flag_date[time]))
      }
      sim_mem <- .pay_tax(sim_mem, nm, due[[nm]], time, label)
      sim_mem[["trades"]][[nm]][["tax_count"]] <- sim_mem[["trades"]][[nm]][["tax_count"]] + 1
      sim_mem[["trades"]][[nm]][["taxes"]][[sim_mem[["trades"]][[nm]][["tax_count"]]]] <-
        list(event_date = flag_date[time], event_type = "Private sale tax", taxes_paid = due[[nm]])
    }
    sim_mem
  }

  # Tarifweg: Erstattung aus der Guenstigerpruefung (§ 32d Abs. 6 EStG) am Abrechnungstag dem Cash
  # gutschreiben (Aufteilung nach Zielgewicht 'actual' wie die Erstattung T-2); in total_taxes bereits
  # beim Jahresabschluss abgezogen
  .gp_pending <- function() !is.null(tariff_env) && tariff_env$refund_due > 0
  .settle_gp <- function(sim_mem, time) {
    refund <- tariff_env$refund_due; tariff_env$refund_due <- 0
    w <- vapply(flag_assets, function(nm) sim_mem[["status"]][[nm]][["actual"]] %||% 0, numeric(1))
    w <- if (sum(w) > 0) w / sum(w) else rep(1 / length(flag_assets), length(flag_assets))
    for (nm in flag_assets) sim_mem[["status"]][[nm]][["money"]] <- sim_mem[["status"]][[nm]][["money"]] + refund * w[[nm]]
    if (details) cat(sprintf("Steuerereignis:\tG\u00fcnstigerpr\u00fcfung: Erstattung %.2f EUR in den Geldbestand am %s\n", refund, flag_date[time]))
    sim_mem
  }

  # Steuer der offenen Vorabpauschalen mit den aktuellen Toepfen berechnen (bucht in totals, zahlt nicht)
  .vp_taxes <- function(sim_mem, pend) {
    # A7-04: mehrere Vorabpauschalen am selben Tag gemeinsam mit Verlusttopf und Sparer-Pauschbetrag
    # verrechnen und Steuer/Pauschbetrag anteilig nach der VP nach Teilfreistellung aufteilen (wie § 23),
    # damit das Ergebnis nicht von der Reihenfolge der Assets in 'strategy' abhaengt
    res <- vector("list", length(pend))
    if (length(pend) > 1L) {
      taxable <- vapply(pend, function(p) p[["flat_rate"]] * (1 - p[["bonus"]]), numeric(1))
      pooled <- .calculate_vorabpauschale_tax(flat_rate = sum(taxable), bonus = 0, totals = sim_mem[["totals"]],
                                             tax_rate = effective_tax_rate, use_spb = use_sparer_pauschbetrag)
      sim_mem[["totals"]] <- pooled$totals
      share <- if (sum(taxable) > 0) taxable / sum(taxable) else rep(1 / length(pend), length(pend))
      for (j in seq_along(pend)) res[[j]] <- list(tax = pooled$tax * share[j], spb_used = pooled$spb_used * share[j])
    } else if (length(pend) == 1L) {
      p <- pend[[1]]
      r1 <- .calculate_vorabpauschale_tax(flat_rate = p[["flat_rate"]], bonus = p[["bonus"]], totals = sim_mem[["totals"]],
                                         tax_rate = effective_tax_rate, use_spb = use_sparer_pauschbetrag)
      sim_mem[["totals"]] <- r1$totals
      res[[1]] <- list(tax = r1$tax, spb_used = r1$spb_used)
    }
    list(sim_mem = sim_mem, res = res)
  }

  # § 18 Abs. 3 InvStG: Zufluss der am 31.12. festgesetzten Vorabpauschalen. Die Steuer
  # (Teilfreistellung, § 20-Verlusttopf, Sparer-Pauschbetrag, Guenstigerpruefung) wird
  # mit den Toepfen des Zuflussjahres berechnet (Aufruf nach .handle_year_change);
  # die VP zaehlt damit als Kapitalertrag des Zuflussjahres. prepaid: je offener VP bereits gezahlter
  # Betrag (A7-11, Ende am 31.12.)
  .settle_vp <- function(sim_mem, time, prepaid = NULL) {
    pend <- sim_mem[["totals"]][["vp_pending"]]
    sim_mem[["totals"]][["vp_pending"]] <- NULL
    v <- .vp_taxes(sim_mem, pend); sim_mem <- v$sim_mem
    for (j in seq_along(pend)) {
      p <- pend[[j]]; result <- v$res[[j]]
      pre <- if (is.null(prepaid)) 0 else prepaid[j]
      if (details) {
        cat(sprintf("Steuerereignis:\tVorabpauschale %s (festgesetzt %s): %.2f EUR, nach TFS %.2f EUR, SPB %.2f EUR, Steuer %.2f EUR am %s\n",
                    p[["name"]], format(p[["assessment_date"]]), p[["flat_rate"]], p[["flat_rate"]] * (1 - p[["bonus"]]),
                    result$spb_used, result$tax, flag_date[time]))
      }
      if (result$tax > 0 || pre > 0) {
        sim_mem <- .pay_vp(sim_mem, p[["name"]], result$tax, time,
                           list(flat_rate = p[["flat_rate"]], bonus = p[["bonus"]],
                                spb_used = result$spb_used, assessment_date = p[["assessment_date"]]), prepaid = pre)
      }
    }
    sim_mem
  }

  list(.buy_with_fee = .buy_with_fee, .sell_count_net = .sell_count_net,
       .pay_one = .pay_one, .pay_tax = .pay_tax, .pay_vp = .pay_vp, .settle_p23 = .settle_p23,
       .gp_pending = .gp_pending, .settle_gp = .settle_gp, .vp_taxes = .vp_taxes, .settle_vp = .settle_vp,
       tax_unpaid = function() tax_unpaid_total)
}
