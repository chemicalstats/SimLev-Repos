# Szenarien und Tabellen der Bereiche (seit 1.4.2): ein Szenario ist ein Test, der mehrere zusammengehörige Ergebnisse
# zugleich prüft (Teile); eine Tabelle prüft je Zeile „Eingabe -> Wert bzw. Meldung“. Code je Teil bzw. Zeile wird
# einmal je Sprache angegeben (R: letzter Ausdruck, Python und Julia: setzen `result`); der Vorspann `vor`
# (gemeinsame Objekte des Moduls) steht einmal vor dem Szenario bzw. vor jeder Tabellenzeile.
#
#   SZ(id, prueft, teile, vor, inp, gemein)  Szenario (Gruppe aus ref_init(modul, gruppe)): Ergebnis ist die benannte Liste
#                                     der Teile (Python dict, Julia NamedTuple); Teil mit druck = TRUE: zusätzlich
#                                     druck_<teil> = print()-Ausgabe (R capture.output, Python str, Julia show);
#                                     gemein = teil(...): einmal gerechnete Objekte, die alle Teile verwenden
#   teil(r, py, jl, druck = FALSE)    Teil eines Szenarios; jeder Teil rechnet in eigenem Gültigkeitsbereich
#                                     (R local, Python Funktion, Julia let); oben = TRUE: in Python und Julia auf
#                                     oberster Ebene (Code, der globale Namen setzt, z. B. für Bedingungen in R-Syntax)
#   TB(id, prueft, zeilen, vor, inp)  Tabelle; zeile(z, r, py, jl, print = FALSE) eine Zeile (eigener Aufruf)
#   inp                               Namen der Eingaben (globale Objekte des Generators) oder benannte Liste; bei teil()
#                                     bzw. zeile() eigene Eingaben des Teils bzw. der Zeile (benannte Liste; im Szenario bei
#                                     gleichem Namen mit anderem Wert als <name>__<teil> abgelegt und im Teil gebunden)
# Die Teile tragen die bisherige Fallkennung als Namen (Feld teile; tests/lib: fall("<modul>/<teil>")).

teil <- function(r, py, jl, druck = FALSE, inp = NULL, oben = FALSE) list(r = r, py = py, jl = jl, druck = druck, inp = inp, oben = oben)
# nur = "py" bzw. "jl" (seit 1.6.4): Zeile nur für diese Sprache (z. B. wenn die Eingabe der anderen Sprache eine andere
# Meldung ergibt, etwa ein Dateiname der eigenen Sprache); R rechnet die Erwartung wie sonst
zeile <- function(z, r, py, jl, print = FALSE, inp = NULL, nur = NULL) list(z = z, r = r, py = py, jl = jl, print = print, inputs = inp, nur = nur)

# Eingabe `n`: globales Objekt n, sonst Element n einer globalen Eingabeliste (z. B. I$d), wenn eindeutig
.sz_get <- function(n) {
  g <- globalenv()
  if (exists(n, envir = g, inherits = FALSE)) return(get(n, envir = g))
  kand <- Filter(function(v) is.list(v) && !is.data.frame(v) && n %in% names(v), mget(ls(g), envir = g))
  w <- unique(lapply(kand, `[[`, n))
  if (length(w) != 1L) stop("Eingabe '", n, "' nicht eindeutig (Listen: ", paste(names(kand), collapse = ", "), ")")
  w[[1]]
}
.sz_inp <- function(inp) if (is.list(inp)) inp else setNames(lapply(inp, .sz_get), inp)
.sz_vor <- function(vor, L, x) if (is.null(vor) || !nzchar(vor[[L]])) x else paste0(vor[[L]], "\n", x)
.sz_ein <- function(x, n) paste0(strrep(" ", n), strsplit(x, "\n", fixed = TRUE)[[1]], collapse = "\n")
# Namen, denen der Code auf oberster Ebene neu zuweist (Python, Julia)
.sz_zuweis <- function(x) {
  # Anweisungen trennen: ";" nur außerhalb von Klammern und Zeichenketten (in Julia trennt ";" auch Schlüsselargumente);
  # Zeichenketten: von ' bzw. " bis zum gleichen Zeichen ohne \ davor; danach folgende Leerzeichen/Tabs entfallen.
  # Seit 1.6.3 vektoriell (bis 1.6.2 eine Schleife je Zeichen, gleiches Ergebnis): nur die Anführungszeichen der Reihe nach
  ch <- strsplit(x, "")[[1]]; n <- length(ch)
  drin <- logical(n); q <- ""; von <- 0L
  for (i in which(ch == "'" | ch == "\"")) {
    if (!nzchar(q)) { q <- ch[i]; von <- i }
    else if (ch[i] == q && (i == 1L || ch[i - 1L] != "\\")) { drin[von:i] <- TRUE; q <- "" }
  }
  if (nzchar(q)) drin[von:n] <- TRUE
  d <- ifelse(drin, 0L, ifelse(ch %in% c("(", "[", "{"), 1L, ifelse(ch %in% c(")", "]", "}"), -1L, 0L)))
  tiefe <- cumsum(d) - d                                # Tiefe vor dem Zeichen
  for (i in which(ch == ";" & !drin & tiefe == 0L)) {
    ch[i] <- "\n"; j <- i + 1L; while (j <= n && ch[j] %in% c(" ", "\t")) { ch[j] <- ""; j <- j + 1L }
  }
  x <- paste(ch, collapse = "")
  m <- regmatches(x, gregexpr("(?m)^[A-Za-z_][A-Za-z0-9_]*(?=\\s*=[^=])", x, perl = TRUE))[[1]]
  unique(m)
}

SZ <- function(id, prueft, teile, vor = NULL, inp = character(0), gemein = NULL) {
  inputs <- .sz_inp(inp)
  if (!is.null(gemein)) vor <- if (is.null(vor)) gemein[c("r", "py", "jl")] else
    setNames(lapply(c("r", "py", "jl"), function(L) paste0(vor[[L]], "\n", gemein[[L]])), c("r", "py", "jl"))
  glob <- c(names(inputs), .sz_zuweis(if (is.null(vor)) "" else paste(vor$py, vor$jl, sep = "\n")))
  n <- names(teile); stopifnot(length(n) == length(teile), all(grepl("^[A-Za-z][A-Za-z0-9_]*$", n)), !anyDuplicated(n))
  # eigene Eingaben der Teile: gleicher Wert -> gemeinsam, sonst umbenannt und im Teil gebunden
  bind <- setNames(vector("list", length(n)), n)
  for (k in n) for (v in names(teile[[k]]$inp)) {
    x <- teile[[k]]$inp[[v]]
    if (is.null(inputs[[v]])) inputs[[v]] <- x
    else if (!identical(inputs[[v]], x)) { inputs[[paste0(v, "__", k)]] <- x; bind[[k]] <- c(bind[[k]], v) }
  }
  bnd <- function(k, L) if (length(bind[[k]])) paste0(paste(sprintf(switch(L, r = "%s <- %s__%s", "%s = %s__%s"), bind[[k]], bind[[k]], k),
                                                          collapse = "\n"), "\n") else ""
  for (k in n) for (L in c("r", "py")) teile[[k]][[L]] <- paste0(bnd(k, L), teile[[k]][[L]])
  glob <- c(glob, names(inputs))
  dr <- vapply(teile, function(t) isTRUE(t$druck), NA)
  # R
  r_teile <- vapply(n, function(k) sprintf(".%s <- local({\n%s\n})", k, .sz_ein(teile[[k]]$r, 2)), "")
  r_erg <- unlist(lapply(n, function(k) c(sprintf("%s = .%s", k, k),
                                          if (dr[[k]]) sprintf("druck_%s = paste(capture.output(print(.%s)), collapse = \"\\n\")", k, k))))
  r <- paste(c(r_teile, sprintf("list(%s)", paste(r_erg, collapse = ",\n     "))), collapse = "\n")
  # Python: je Teil eine Funktion; neu zugewiesene globale Namen als Vorgabewerte
  py_teile <- vapply(n, function(k) {
    if (isTRUE(teile[[k]]$oben)) return(sprintf("%s\n_%s = result", teile[[k]]$py, k))
    g <- setdiff(intersect(.sz_zuweis(teile[[k]]$py), glob), bind[[k]])
    sprintf("def _%s(%s):\n%s\n    return result", k, paste(sprintf("%s=%s", g, g), collapse = ", "), .sz_ein(teile[[k]]$py, 4))
  }, "")
  py_erg <- unlist(lapply(n, function(k) c(sprintf(if (isTRUE(teile[[k]]$oben)) "result['%s'] = _%s" else "result['%s'] = _%s()", k, k),
                                           if (dr[[k]]) sprintf("result['druck_%s'] = str(result['%s'])", k, k))))
  py <- paste(c(py_teile, "result = {}", py_erg), collapse = "\n")
  # Julia: je Teil ein let-Block (using/import nach oben); neu zugewiesene globale Namen als let-Bindung
  jl_use <- character(0)
  jl_teile <- vapply(n, function(k) {
    z <- strsplit(teile[[k]]$jl, "\n", fixed = TRUE)[[1]]
    if (isTRUE(teile[[k]]$oben)) return(sprintf("%s\n_%s = result", teile[[k]]$jl, k))
    u <- grepl("^(using|import) ", z); jl_use <<- union(jl_use, z[u]); z <- sub("^const ", "", z[!u])
    g <- setdiff(intersect(.sz_zuweis(paste(z, collapse = "\n")), glob), bind[[k]])
    g <- c(sprintf("%s = %s__%s", bind[[k]], bind[[k]], k)[length(bind[[k]]) > 0], if (length(g)) sprintf("%s = %s", g, g))
    sprintf("_%s = let%s\n%s\n    result\nend", k, if (length(g)) paste0(" ", paste(g, collapse = ", ")) else "",
            .sz_ein(paste(z, collapse = "\n"), 4))
  }, "")
  jl_erg <- unlist(lapply(n, function(k) c(sprintf("%s = _%s", k, k), if (dr[[k]]) sprintf("druck_%s = _druck(_%s)", k, k))))
  jl <- paste(c(jl_use, if (any(dr)) "_druck(x) = chomp(sprint(show, MIME\"text/plain\"(), x))", jl_teile,
                sprintf("result = (%s,)", paste(jl_erg, collapse = ", "))), collapse = "\n")
  ref_case(id, r = .sz_vor(vor, "r", r), py = .sz_vor(vor, "py", py), jl = .sz_vor(vor, "jl", jl), inputs = inputs,
           print = FALSE, note = paste("prüft:", prueft))
  if (.ref_in_subset(id)) ref_case_extra(list(teile = as.list(n)))
  invisible(NULL)
}

TB <- function(id, prueft, zeilen, vor = NULL, inp = character(0)) {
  ref_tabelle(id, lapply(zeilen, function(z) {
    z$r <- .sz_vor(vor, "r", z$r); z$py <- .sz_vor(vor, "py", z$py); z$jl <- .sz_vor(vor, "jl", z$jl); z
  }), inputs = .sz_inp(inp), note = paste("prüft:", prueft))
}

# Eingaben eines bisherigen Falls: Namen aus der Momentaufnahme EIN[["<modul>/<id>"]] (Stand an der Stelle des Falls im
# alten Generator), sonst globales Objekt
ein <- function(key, namen) {
  x <- get0("EIN", envir = globalenv())[[key]]
  setNames(lapply(namen, function(n) if (n %in% names(x)) x[[n]] else .sz_get(n)), namen)
}
