# Tabellen der methodik-Tests (seit 1.4.2): je Paragraph bzw. Thema eine Tabelle „Größe -> erwarteter Wert, Quelle“.
#   tabelle(thema, <Zeile>, ...)  prüft die Zeilen der Reihe nach in der Umgebung des Aufrufers
# Zeilen (werden nicht als Funktion aufgerufen, sondern von tabelle() gelesen):
#   wert(ist, soll, quelle, tol)  expect_equal(ist, soll[, tolerance = tol])
#   ident(ist, soll, quelle)      expect_identical(ist, soll)
#   bed(bedingung, quelle)        stopifnot(bedingung)
#   pruef(<expect_…(…)>, quelle)  die Prüfung wörtlich (Meldungen, Klassen, Ungleichungen)
# quelle: Paragraph, Beispielrechnung oder Formel wie im Test bzw. Kommentar; sonst "Handrechnung (Herleitung im Test)".
tabelle <- function(thema, ...) {
  env <- parent.frame()
  zeilen <- as.list(substitute(list(...)))[-1]
  for (z in zeilen) {
    art <- as.character(z[[1]])
    a <- as.list(z)[-1]
    q <- a$quelle; a$quelle <- NULL
    lab <- function(x) sprintf("%s [%s: %s]", paste(deparse(x, width.cutoff = 500L), collapse = " "), thema, q)
    switch(art,
      wert = , ident = {
        tol <- a$tol; a$tol <- NULL
        args <- list(eval(a[[1]], env), eval(a[[2]], env), label = lab(a[[1]]),
                     expected.label = paste(deparse(a[[2]], width.cutoff = 500L), collapse = " "))
        if (!is.null(tol)) args$tolerance <- eval(tol, env)
        do.call(if (art == "wert") testthat::expect_equal else testthat::expect_identical, args)
      },
      bed = eval(as.call(c(as.name("stopifnot"), a)), env),
      pruef = eval(a[[1]], env),
      stop("tabelle: unbekannte Zeilenart ", art))
  }
  invisible(NULL)
}
