# =============================================================================
#  vendor_imputets.R  —  uebernommene Teile des R-Pakets imputeTS
# -----------------------------------------------------------------------------
#  Paket:     imputeTS 3.4 (CRAN, 2025-08-25), Dateien R/na_interpolation.R
#             und R/na_locf.R
#  Autoren:   Steffen Moritz [aut, cre, cph], Sebastian Gatscha [aut],
#             Earo Wang [ctb], Ron Hause [ctb]
#  Lizenz:    GPL-3
#  Angepasst fuer SimLev (siehe inst/COPYRIGHTS):
#    * na_interpolation() und na_locf() als interne Funktionen
#      .imputets_na_interpolation() und .imputets_na_locf(); die
#      Funktionsruempfe sind unveraendert bis auf die Aufrufe der
#      uebernommenen Funktionen unter ihren neuen Namen
#    * uebernommen ist der Weg, den SimLev erreicht:
#      na_interpolation(option = "stine") mit stinepack::stinterp (als
#      .stinepack_stinterp, R/vendor_stinepack.R) und na_locf() fuer NA am
#      Rand der Stineman-Interpolation (na_remaining = "rev", Optionen
#      "locf" und "nocb"), dazu unveraendert na_interpolation(option =
#      "linear") mit stats::approx (rule = 2, sofern rule nicht ueber ...
#      gesetzt ist; methods::hasArg("rule") mit dem Namen als Zeichenkette,
#      damit R CMD check keine NOTE meldet); Argumente, Pruefungen, Matrix-Eingaben,
#      maxgap und Meldungen bleiben. option = "spline" sowie
#      na_remaining = "rm"/"mean" brechen mit einem Fehler ab, statt spline,
#      na_remove oder na_mean zu nutzen (nicht uebernommen)
#    * der C++-Kern locf aus imputeTS src/locf.cpp steht mit unveraenderter
#      Rechnung in src/vendor_imputets.cpp und wird ueber .imputets_locf()
#      (R/cores.R, .Call) gerufen
#  Genutzt von .fill_na() (backcast_fit() und backcast() mit
#  index_fill = "stine" bzw. fill = "stine").
# =============================================================================

#' Interpolation fehlender Werte (aus imputeTS 3.4, na_interpolation)
#' @keywords internal
#' @noRd
.imputets_na_interpolation <- function(x, option = "linear", maxgap = Inf, ...) {

  # Variable 'data' is used for all transformations to the time series
  # 'x' needs to stay unchanged to be able to return the same ts class in the end
  data <- x

  #----------------------------------------------------------
  # Mulivariate Input
  # The next 20 lines are just for checking and handling multivariate input.
  #----------------------------------------------------------

  # Check if the input is multivariate
  if (!is.null(dim(data)[2]) && dim(data)[2] > 1) {
    # Go through columns and impute them by calling this function with univariate input
    for (i in 1:dim(data)[2]) {
      if (!anyNA(data[, i])) {
        next
      }
      # if imputing a column does not work - mostly because it is not numeric - the column is left unchanged
      tryCatch(
        data[, i] <- .imputets_na_interpolation(data[, i], option, maxgap),
        error = function(cond) {
          warning(paste(
            "na_interpolation: No imputation performed for column", i, "of the input dataset.
                Reason:", cond[1]
          ), call. = FALSE)
        }
      )
    }
    return(data)
  }

  #----------------------------------------------------------
  # Univariate Input
  # All relveant imputation / pre- postprocessing  code is within this part
  #----------------------------------------------------------

  else {
    missindx <- is.na(data)

    ##
    ## 1. Input Check and Transformation
    ##

    # 1.1 Check if NAs are present
    if (!anyNA(data)) {
      return(x)
    }

    # 1.2 special handling data types
    if (any(class(data) == "tbl")) {
      data <- as.vector(as.data.frame(data)[, 1])
    }

    # 1.3 Check for algorithm specific minimum amount of non-NA values
    if (sum(!missindx) < 2) {
      stop("At least 2 non-NA data points required in the time series to apply na_interpolation.")
    }

    # 1.4 Checks and corrections for wrong data dimension

    # Check if input dimensionality is not as expected
    if (!is.null(dim(data)[2]) && !dim(data)[2] == 1) {
      stop("Wrong input type for parameter x.")
    }

    # Altering multivariate objects with 1 column (which are essentially
    # univariate) to be dim = NULL
    if (!is.null(dim(data)[2])) {
      data <- data[, 1]
    }

    # 1.5 Check if input is numeric
    if (!is.numeric(data)) {
      stop("Input x is not numeric.")
    }

    ##
    ## End Input Check
    ##


    ##
    ## 2. Imputation Code
    ##

    n <- length(data)

    allindx <- 1:n
    indx <- allindx[!missindx]

    data_vec <- as.vector(data)

    # Linear Interpolation
    if (option == "linear") {
      # Check if 'rule' is used in function call, to allow parameter pass through for rule
      # Needed since parameter pass through via (...) to approx does not work, when value for 'rule' is also set in the code. 
      if (methods::hasArg("rule")) {  # SimLev: Name als Zeichenkette, gleiches Ergebnis ohne NOTE
        interp <- stats::approx(indx, data_vec[indx], 1:n, ...)$y
      }
      else {
        interp <- stats::approx(indx, data_vec[indx], 1:n, rule = 2, ...)$y
      }
    }
    # Spline Interpolation
    else if (option == "spline") {
      # SimLev: option = "spline" (spline) nicht uebernommen
      stop("imputeTS-Uebernahme: na_interpolation mit option = \"spline\" nicht uebernommen")
    }
    # Stineman Interpolation
    else if (option == "stine") {
      # SimLev: stinepack::stinterp als .stinepack_stinterp (R/vendor_stinepack.R)
      interp <- .stinepack_stinterp(indx, data_vec[indx], 1:n, ...)$y
      # avoid NAs at the beginning and end of series // same behavior like
      # for approx with rule = 2.
      if (any(is.na(interp))) {
        interp <- .imputets_na_locf(interp, na_remaining = "rev")
      }
    }
    # Wrong parameter option
    else {
      stop("Wrong parameter 'option' given. Value must be either 'linear', 'spline' or 'stine'.")
    }

    # Merge interpolated values back into original time series
    data[missindx] <- interp[missindx]

    ##
    ## End Imputation Code
    ##


    ##
    ## 3. Post Processing
    ##

    # 3.1 Check for Maxgap option

    # If maxgap = Inf then do nothing and when maxgap is lower than 0
    if (is.finite(maxgap) && maxgap >= 0) {

      # Get logical vector of the time series via is.na() and then get the
      # run-length encoding of it. The run-length encoding describes how long
      # the runs of FALSE and TRUE are
      rlencoding <- rle(is.na(x))

      # Runs smaller than maxgap (which shall still be imputed) are set FALSE
      rlencoding$values[rlencoding$lengths <= maxgap] <- FALSE

      # The original vector is being reconstructed by reverse.rls, only now the
      # longer runs are replaced now in the logical vector derived from is.na()
      # in the beginning all former NAs that are > maxgap are also FALSE
      en <- inverse.rle(rlencoding)

      # Set all positions in the imputed series with gaps > maxgap to NA
      # (info from en vector)
      data[en == TRUE] <- NA
    }

    ##
    ## End Post Processing
    ##


    ##
    ## 4. Final Output Formatting
    ##

    # Give back the object originally supplied to the function
    # (necessary for multivariate input with only 1 column)
    if (!is.null(dim(x)[2])) {
      x[, 1] <- data
      return(x)
    }

    ##
    ## End Final Output Formatting
    ##

    return(data)
  }
}

#' LOCF/NOCB (aus imputeTS 3.4, na_locf)
#' @keywords internal
#' @noRd
.imputets_na_locf <- function(x, option = "locf", na_remaining = "rev", maxgap = Inf) {

  # Variable 'data' is used for all transformations to the time series
  # 'x' needs to stay unchanged to be able to return the same ts class in the end
  data <- x


  #----------------------------------------------------------
  # Mulivariate Input
  # The next 20 lines are just for checking and handling multivariate input.
  #----------------------------------------------------------

  # Check if the input is multivariate
  if (!is.null(dim(data)[2]) && dim(data)[2] > 1) {
    # Go through columns and impute them by calling this function with univariate input
    for (i in 1:dim(data)[2]) {
      if (!anyNA(data[, i])) {
        next
      }
      # if imputing a column does not work - mostly because it is not numeric - the column is left unchanged
      tryCatch(
        data[, i] <- .imputets_na_locf(data[, i], option, na_remaining, maxgap),
        error = function(cond) {
          warning(paste(
            "na_locf: No imputation performed for column", i, "of the input dataset.
                Reason:", cond[1]
          ), call. = FALSE)
        }
      )
    }
    return(data)
  }


  #----------------------------------------------------------
  # Univariate Input
  # All relveant imputation / pre- postprocessing  code is within this part
  #----------------------------------------------------------

  else {
    missindx <- is.na(data)

    ##
    ## 1. Input Check and Transformation
    ##


    # 1.1 Check if NAs are present
    if (!anyNA(data)) {
      return(x)
    }

    # 1.2 special handling data types
    if (any(class(data) == "tbl")) {
      data <- as.vector(as.data.frame(data)[, 1])
    }

    # 1.3 Check for algorithm specific minimum amount of non-NA values
    if (all(missindx)) {
      stop("Input data has only NA values. At least 1 non-NA data point required in the time series to apply na_locf.")
    }


    # 1.4 Checks and corrections for wrong data dimension

    # Check if input dimensionality is not as expected
    if (!is.null(dim(data)[2]) && !dim(data)[2] == 1) {
      stop("Wrong input type for parameter x.")
    }

    # Altering multivariate objects with 1 column (which are essentially
    # univariate) to be dim = NULL
    if (!is.null(dim(data)[2])) {
      data <- data[, 1]
    }

    # 1.5 Check if input is numeric
    if (!is.numeric(data)) {
      stop("Input x is not numeric.")
    }

    ##
    ## End Input Check and Transformation
    ##


    ##
    ## 2. Imputation Code
    ##

    # 2.1 Perform locf or nocb

    # Input as vector
    data_vec <- as.vector(data)

    # Last observation carried forward // f = 0
    if (option == "locf") {
      # SimLev: C++-Kern locf als .imputets_locf (src/vendor_imputets.cpp)
      imputed <- .imputets_locf(data_vec, FALSE)
    }
    # Next observation carried backward // f = 1
    else if (option == "nocb") {
      imputed <- .imputets_locf(data_vec, TRUE)
    }
    # Wrong input
    else {
      stop("Wrong parameter 'option' given. Value must be either 'locf' or 'nocb'.")
    }

    data[missindx] <- imputed[missindx]


    # 2.2 Handle remaining NAs - na_remaining param

    # no remaining NAs or keep NAs selected -> do nothing
    if (!anyNA(data) || na_remaining == "keep") {
      # do nothing
    }
    # Replace NAs through locf/nocb from the other direction
    else if (na_remaining == "rev") {
      if (option == "locf") {
        data <- .imputets_na_locf(data, option = "nocb")
      }
      else if (option == "nocb") {
        data <- .imputets_na_locf(data, option = "locf")
      }
    }
    # Remove all NAs
    else if (na_remaining == "rm") {
      # SimLev: na_remove nicht uebernommen
      stop("imputeTS-Uebernahme: na_locf mit na_remaining = \"rm\" (na_remove) nicht uebernommen")
    }
    # Replace NAs with overall mean
    else if (na_remaining == "mean") {
      # SimLev: na_mean nicht uebernommen
      stop("imputeTS-Uebernahme: na_locf mit na_remaining = \"mean\" (na_mean) nicht uebernommen")
    }
    # Wrong Input
    else {
      stop("Wrong parameter 'na_remaining' given. Value must be either 'keep', 'rm', 'mean' or 'rev'.")
    }

    ##
    ## End Imputation Code
    ##


    ##
    ## 3. Post Processing
    ##

    # 3.1 Check for Maxgap option

    # If maxgap = Inf then do nothing and when maxgap is lower than 0
    if (is.finite(maxgap) && maxgap >= 0) {

      # Get logical vector of the time series via is.na() and then get the
      # run-length encoding of it. The run-length encoding describes how long
      # the runs of FALSE and TRUE are
      rlencoding <- rle(is.na(x))

      # Runs smaller than maxgap (which shall still be imputed) are set FALSE
      rlencoding$values[rlencoding$lengths <= maxgap] <- FALSE

      # The original vector is being reconstructed by reverse.rls, only now the
      # longer runs are replaced now in the logical vector derived from is.na()
      # in the beginning all former NAs that are > maxgap are also FALSE
      en <- inverse.rle(rlencoding)

      # Set all positions in the imputed series with gaps > maxgap to NA
      # (info from en vector)
      data[en == TRUE] <- NA
    }

    ##
    ## End Post Processing
    ##


    ##
    ## 4. Final Output Formatting
    ##

    # Give back the object originally supplied to the function
    # (necessary for multivariate input with only 1 column)
    if (!is.null(dim(x)[2])) {
      x[, 1] <- data
      return(x)
    }

    ##
    ## End Final Output Formatting
    ##

    return(data)
  }
}
