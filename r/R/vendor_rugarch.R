# =============================================================================
#  vendor_rugarch.R  —  uebernommene Teile des R-Pakets rugarch
# -----------------------------------------------------------------------------
#  Paket:     rugarch 1.5-6 (CRAN, 2026-07-18), Dateien R/rugarch-methods.R,
#             R/rugarch-sgarch.R, R/rugarch-gjrgarch.R, R/rugarch-series.R,
#             R/rugarch-helperfn.R, R/rugarch-startpars.R,
#             R/rugarch-cwrappers.R, R/rugarch-solvers.R, R/rugarch-kappa.R,
#             R/rugarch-distributions.R und R/rugarch-numderiv.R
#  Autoren:   Alexios Galanos [aut, cre, cph], Tobias Kley [ctb]
#  Lizenz:    GPL-3
#  Angepasst fuer SimLev (siehe inst/COPYRIGHTS):
#    * uebernommen ist der Weg, den .fit_garch11() erreicht (bootstrap() mit
#      "garch"/"gjr_garch", die Kopplung .fit_cross(), dependence_dcc(),
#      dependence_analysis()):
#        spec <- ugarchspec(variance.model = list(model = "sGARCH" bzw.
#                  "gjrGARCH", garchOrder = c(1, 1)), mean.model =
#                  list(armaOrder = c(0, 0), include.mean = TRUE),
#                  distribution.model = "norm")
#        fit <- ugarchfit(spec, data = e, solver = "hybrid"); coef(fit)
#      als interne Funktionen .rugarch_ugarchspec(), .rugarch_ugarchfit()
#      und .rugarch_coef() mit den Funktionen, die sie rufen (Namen
#      .rugarch_<name>; eps und TinY heissen .rugarch_eps und .rugarch_TinY)
#    * Argumente, Pruefungen und Meldungen bleiben. Was weitere, nicht
#      uebernommene Teile von rugarch braucht, bricht mit einem Fehler ab:
#      andere Modelle als sGARCH/gjrGARCH, andere Verteilungen als "norm",
#      ARMA-Terme, ARFIMA, GARCH-in-Mean, externe Regressoren, nur feste
#      Parameter (ugarchfilter), die Solver "lbfgs" und "nloptr", gosolnp
#      mit parallel = TRUE und Daten, die keine numerischen Vektoren sind
#    * S4-Klassen: spec und fit sind Listen der Klassen "uGARCHspec" und
#      "uGARCHfit" mit den Elementen model bzw. fit und model (statt der
#      Slots @model, @fit); coef(fit) ist .rugarch_coef(fit)
#    * .extractdata() ohne die Pakete xts und zoo: der Weg von as.xts() fuer
#      numerische Vektoren (Index aus den Namen, sonst Datumsfolge ab
#      1970-01-02) in Basis-R (.rugarch_as_xts_vec())
#    * die Likelihood rechnet der C-Code von rugarch (src/vendor_rugarch.c);
#      statt .C("sgarchfilterC"/"gjrgarchfilterC", ...) rufen die
#      Likelihood-Funktionen .Call-Huellen, die wie .C pruefen und kopieren
#      (src/init.c registriert nur .Call-Routinen)
#    * Rsolnp::solnp/gosolnp und truncnorm::rtruncnorm sind ebenfalls
#      uebernommen (.rsolnp_solnp, .rsolnp_gosolnp in R/vendor_rsolnp.R,
#      .truncnorm_rtruncnorm in R/vendor_truncnorm.R); statt
#      numDeriv::hessian/jacobian rechnet SimLevs eigenstaendig geschriebene
#      Richardson-Extrapolation (.sl_richardson_hessian,
#      .sl_richardson_jacobian in R/richardson.R, gegen numDeriv als
#      Pruef-Orakel bitgleich)
#    * die Funktionsruempfe sind sonst unveraendert; Kommentare "SimLev:"
#      markieren jede Aenderung. Rechnung, Startwerte, Schranken, Solver-
#      Kette (solnp -> nlminb -> zweimal gosolnp, mit set.seed aus der
#      Uhrzeit), Hesse-Matrix, robuste Kovarianz, Warnungen und Ergebnis
#      (coef) sind die von rugarch.
# =============================================================================

# rugarch-helperfn.R: Konstanten (eps, TinY)
.rugarch_eps <- .Machine$double.eps
.rugarch_TinY <- 1.0e-8

# rugarch-methods.R: .ugarchspec
.rugarch_ugarchspec = function(variance.model = list(model = "sGARCH", garchOrder = c(1,1),
				submodel = NULL, external.regressors = NULL, variance.targeting = FALSE),
		mean.model = list(armaOrder = c(1,1), include.mean = TRUE, archm = FALSE,
				archpow = 1, arfima = FALSE, external.regressors = NULL, archex = FALSE),
		distribution.model = "norm", start.pars = list(), fixed.pars = list())
{
	# some checks and preparation to be passed on to specific models by switch
	modelinc = rep(0, 22)
	# set the custom variance target to NA
	modelinc[22] = NA
	# [19] from aux to xi to accomodate realGARCH model (25-12-2014)
	names(modelinc) = c("mu", "ar", "ma", "arfima", "archm", "mxreg", "omega", "alpha",
			"beta", "gamma", "eta1", "eta2", "delta", "lambda", "vxreg", "skew", "shape",
			"ghlambda", "xi", "aux", "aux", "aux")
	modeldesc = list()
	modeldata = list()

	# check the option parameters specified and stop on error
	mm = match(names(mean.model), c("armaOrder", "include.mean", "archm", "archpow", "arfima", "external.regressors", "archex"))
	if(any(is.na(mm))){
		idx = which(is.na(mm))
		enx = NULL
		for(i in 1:length(idx)) enx = c(enx, names(mean.model)[idx[i]])
		warning(paste(c("unidentified option(s) in mean.model:\n", enx), sep="", collapse=" "), call. = FALSE, domain = NULL)
	}
	vm = match(names(variance.model), c("model", "garchOrder", "submodel", "external.regressors", "variance.targeting"))
	if(any(is.na(vm))){
		idx = which(is.na(vm))
		enx = NULL
		for(i in 1:length(idx)) enx = c(enx, names(variance.model)[idx[i]])
		warning(paste(c("unidentified option(s) in variance.model:\n", enx), sep="", collapse=" "), call. = FALSE, domain = NULL)
	}

	# distribution model
	if(is.null(distribution.model)) modeldesc$distribution = "norm"
	valid.distribution = c("norm", "snorm", "std", "sstd","ged", "sged", "nig", "ghyp", "jsu", "ghst")
	distribution = distribution.model

	if(!is.character(distribution[1]))
		stop("\nugarchspec-->error: cond.distribution argument must be a character")

	if(!any(distribution==valid.distribution))
		stop("\nugarchspec-->error: the cond.distribution does not appear to be a valid choice.")

	if(length(distribution)!=1) distribution = distribution[1]
	# SimLev: nur die Normalverteilung uebernommen (garchdistribution, pneg)
	if(distribution != "norm") stop(paste0("rugarch-Uebernahme: ugarchspec mit distribution.model = \"", distribution, "\" nicht uebernommen"), call. = FALSE)

	modeldesc$distribution = distribution
	modeldesc$distno = which(distribution == valid.distribution)
	di = .rugarch_DistributionBounds(distribution)
	modelinc[16] = di$include.skew
	modelinc[17] = di$include.shape
	modelinc[18] = di$include.ghlambda
	# the last aux value is the distribution number
	modelinc[21] = modeldesc$distno
	# variance model:
	vmodel = list()

	valid.model = c("sGARCH", "eGARCH", "gjrGARCH", "tGARCH", "fGARCH", "iGARCH", "fiGARCH","apARCH", "csGARCH", "mcsGARCH","realGARCH")
	if(is.null(variance.model$model)){
		modeldesc$vmodel = "sGARCH"
	} else{
		modeldesc$vmodel = variance.model$model[1]

		if(!is.character(modeldesc$vmodel))
			stop("\nugarchspec-->error: garch model argument must be a character.\n", call. = FALSE)

		if(!any(modeldesc$vmodel == valid.model))
			stop("\nugarchspec-->error: the garch model does not appear to be a valid choice.\n", call. = FALSE)

		# SimLev: nur sGARCH und gjrGARCH uebernommen (fGARCH-Untermodelle entfallen)
		if(!any(modeldesc$vmodel == c("sGARCH", "gjrGARCH")))
			stop(paste0("rugarch-Uebernahme: ugarchspec mit model = \"", modeldesc$vmodel, "\" nicht uebernommen"), call. = FALSE)
	}

	# depending on model include the additional parameters
	if(is.null(variance.model$garchOrder)){
		modelinc[8] = 1
		modelinc[9] = 1
	} else{
		modelinc[8] = variance.model$garchOrder[1]
		modelinc[9] = variance.model$garchOrder[2]
	}

	if( modeldesc$vmodel == "gjrGARCH" ) modelinc[10] = modelinc[8]
	# SimLev: die Sonderfaelle von eGARCH, fiGARCH, apARCH, fGARCH, csGARCH, iGARCH
	# und realGARCH entfallen (Modelle nicht uebernommen)

	modeldata$vexdata = variance.model$external.regressors
	# SimLev: externe Regressoren in der Varianzgleichung nicht uebernommen
	if( !is.null(variance.model$external.regressors) ) stop("rugarch-Uebernahme: ugarchspec mit variance.model$external.regressors nicht uebernommen", call. = FALSE)

	if(is.null(variance.model$variance.targeting)){
		modelinc[7] = 1
	} else{
		if(is.logical(variance.model$variance.targeting)){
			modelinc[7] = as.integer( 1 - variance.model$variance.targeting )
		} else{
			modelinc[7] = 0
			modelinc[22] = as.numeric(variance.model$variance.targeting)
		}
	}

	# mean model:
	if(is.null(mean.model$armaOrder)){
		modelinc[2] = modelinc[3] = 1
	} else{
		modelinc[2] = mean.model$armaOrder[1]
		modelinc[3] = mean.model$armaOrder[2]
	}
	# SimLev: ARMA-Terme (arima, arfimaxfilterC) nicht uebernommen
	if(modelinc[2] > 0 || modelinc[3] > 0) stop("rugarch-Uebernahme: ugarchspec mit armaOrder != c(0, 0) nicht uebernommen", call. = FALSE)
	if(is.null(mean.model$include.mean)) modelinc[1] = 1 else modelinc[1] = as.integer( mean.model$include.mean )

	if(is.null(mean.model$archm) || !mean.model$archm){
		modelinc[5] = 0
	} else{
		# SimLev: GARCH-in-Mean nicht uebernommen
		stop("rugarch-Uebernahme: ugarchspec mit archm = TRUE nicht uebernommen", call. = FALSE)
	}


	if(is.null(mean.model$arfima)) modelinc[4] = 0 else modelinc[4] = as.integer( mean.model$arfima )
	# SimLev: ARFIMA (.fracdiff) nicht uebernommen
	if(modelinc[4] > 0) stop("rugarch-Uebernahme: ugarchspec mit arfima = TRUE nicht uebernommen", call. = FALSE)

	modeldata$mexdata = mean.model$external.regressors
	# SimLev: externe Regressoren in der Mittelwertgleichung nicht uebernommen
	if( !is.null(mean.model$external.regressors) ) stop("rugarch-Uebernahme: ugarchspec mit mean.model$external.regressors nicht uebernommen", call. = FALSE)

	if(is.null(mean.model$archex) || !mean.model$archex){
		modelinc[20] = 0
	} else{
		if(modeldesc$vmodel=="mcsGARCH") stop("\narchex not supported by mcsGARCH model.")
		modelinc[20] = as.integer( mean.model$archex )
		if(modelinc[6] == 0) stop("\narchex cannot be used without external.regressors!!\n", call. = FALSE)
		if(modelinc[6] < modelinc[20]) stop("\narchex cannot be greater than number of external.regressors!!\n", call. = FALSE)
	}

	maxOrder = max(modelinc[c(2,3,8,9)])
	modelnames = .rugarch_expand.model(modelinc)


	fmodel = NULL
	# SimLev: fGARCH (.fgarchModel, .fmodelBounds) nicht uebernommen


	pos = 1
	pos.matrix = matrix(0, ncol = 3, nrow = 21)
	colnames(pos.matrix) = c("start", "stop", "include")
	rownames(pos.matrix) = c("mu", "ar", "ma", "arfima", "archm", "mxreg", "omega", "alpha",
			"beta", "gamma", "eta1", "eta2", "delta", "lambda", "vxreg", "skew", "shape",
			"ghlambda", "xi", "aux", "aux")

	# check if there are starting or fixed
	# check that it is included in the optimization
	# check that it is needed in the model


	# SimLev: Positionen fuer fGARCH entfallen
	{
		for(i in 1:21){
			if( modelinc[i] > 0 ){
				pos.matrix[i,1:3] = c(pos, pos+modelinc[i]-1, 1)
				pos = max(pos.matrix[1:i,2]+1)
			}
		}
	}
	nn = length(modelnames)
	modelmatrix = matrix(0, ncol = 3, nrow = nn)
	rownames(modelmatrix) = modelnames
	colnames(modelmatrix) = c("opt", "fixed", "start")
	fixed.names = names(fixed.pars)
	fp = charmatch(fixed.names, modelnames)

	if(!is.null(fixed.names) && any(!is.na(fp))){
		fixed = fp[!is.na(fp)]
		modelmatrix[fixed,2] = 1
		fz = charmatch(modelnames, fixed.names)
		fz = fz[!is.na(fz)]
		fixed.pars = fixed.pars[fz]
		names(fixed.pars) = fixed.names[fz]
	} else{
		fixed.pars = NULL
	}
	modelmatrix[,1] = 1 - modelmatrix[,2]
	start.names = names(start.pars)
	sp = charmatch(start.names, modelnames)
	if(!is.null(start.names) && any(!is.na(sp))){
		start = sp[!is.na(sp)]
		modelmatrix[start,3] = 1
		sz = charmatch(modelnames, start.names)
		sz = sz[!is.na(sz)]
		start.pars = start.pars[sz]
	} else{
		start.pars = NULL
	}


	##################################################################
	# Parameter Matrix
	mm = sum(modelinc[c(2,3,6,8,9,10,11,12,15)])
	mm = mm - length( which(modelinc[c(2,3,6,8,9,10,11,12,15)]>0) )
	pars = matrix(0, ncol = 6, nrow = 19 + mm)
	colnames(pars) = c("Level", "Fixed", "Include", "Estimate", "LB", "UB")
	pidx = matrix(NA, nrow = 19, ncol = 2)
	colnames(pidx) = c("begin", "end")
	rownames(pidx) =  c("mu", "ar", "ma", "arfima", "archm", "mxreg", "omega", "alpha",
			"beta", "gamma", "eta1", "eta2", "delta", "lambda", "vxreg", "skew", "shape",
			"ghlambda","xi")
	fixed.names = names(fixed.pars)
	pnames = NULL
	nx = 0
	if(pos.matrix[1,3]==1){
		pars[1, 3] = 1
		pars[1, 1] = 0
		if(any(substr(fixed.names, 1, 2)=="mu")) pars[1,2] = 1 else pars[1,4] = 1

	}
	pidx[1,1] = 1
	pidx[1,2] = 1
	pnames = c(pnames, "mu")
	nx = 1
	pn = 1
	pidx[2,1] = 2
	if(pos.matrix[2,3] == 1){
		pn = length( seq(pos.matrix[2,1], pos.matrix[2,2], by = 1) )
		for(i in 1:pn){
			pars[(nx+i), 1] = 0
			pars[(nx+i), 3] = 1
			nnx = paste("ar", i, sep="")
			sp = na.omit(match(fixed.names, nnx))
			if(length(sp)>0) pars[(nx+i), 2] = 1 else pars[(nx+i), 4] = 1
			pnames = c(pnames, nnx)
		}
	} else{
		pnames = c(pnames, "ar")
	}
	pidx[2,2] = 1+pn

	nx = nx + pn
	pn = 1
	pidx[3,1] = nx+1
	if(pos.matrix[3,3] == 1){
		pn = length( seq(pos.matrix[3,1], pos.matrix[3,2], by = 1) )
		for(i in 1:pn){
			pars[(nx+i), 1] = 0
			pars[(nx+i), 3] = 1
			nnx = paste("ma", i, sep="")
			sp = na.omit(match(fixed.names, nnx))
			if(length(sp)>0) pars[(nx+i), 2] = 1 else pars[(nx+i), 4] = 1
			pnames = c(pnames, nnx)
		}
	} else{
		pnames = c(pnames, "ma")
	}
	pidx[3,2] = nx+pn

	nx = nx + pn
	pn = 1
	pidx[4,1] = nx+1
	if(pos.matrix[4,3]==1){
		pars[nx+pn, 3] = 1
		pars[nx+pn, 1] = 0
		if(any(substr(fixed.names, 1, 6)=="arfima")) pars[nx+pn,2] = 1 else pars[nx+pn,4] = 1
	}
	pnames = c(pnames, "arfima")
	pidx[4,2] = nx+pn

	nx = nx + pn
	pn = 1
	pidx[5,1] = nx+1
	if(pos.matrix[5,3]==1){
		pars[nx+pn, 3] = 1
		pars[nx+pn, 1] = 0
		if(any(substr(fixed.names, 1, 5)=="archm")) pars[nx+pn,2] = 1 else pars[nx+pn,4] = 1
	}
	pnames = c(pnames, "archm")
	pidx[5,2] = nx+pn

	nx = nx + pn
	pn = 1
	pidx[6,1] = nx+1
	if(pos.matrix[6,3]==1){
		pn = length( seq(pos.matrix[6,1], pos.matrix[6,2], by = 1) )
		for(i in 1:pn){
			pars[(nx+i), 1] = 0
			pars[(nx+i), 3] = 1
			nnx = paste("mxreg", i, sep="")
			sp = na.omit(match(fixed.names, nnx))
			if(length(sp)>0) pars[(nx+i), 2] = 1 else pars[(nx+i), 4] = 1
			pnames = c(pnames, nnx)
		}
	} else{
		pnames = c(pnames, "mxreg")
	}
	pidx[6,2] = nx+pn

	nx = nx + pn
	pn = 1
	pidx[7,1] = nx+1
	if(pos.matrix[7,3]==1){
		pars[nx+pn, 3] = 1
		pars[nx+pn, 1] = 0
		if(any(substr(fixed.names, 1, 5)=="omega")) pars[nx+pn,2] = 1 else pars[nx+pn,4] = 1
	}
	pnames = c(pnames, "omega")
	pidx[7,2] = nx+pn

	nx = nx + pn
	pn = 1
	pidx[8,1] = nx+1
	if(pos.matrix[8,3]==1){
		pn = length( seq(pos.matrix[8,1], pos.matrix[8,2], by = 1) )
		for(i in 1:pn){
			pars[(nx+i), 1] = 0
			pars[(nx+i), 3] = 1
			nnx = paste("alpha", i, sep="")
			sp = na.omit(match(fixed.names, nnx))
			if(length(sp)>0) pars[(nx+i), 2] = 1 else pars[(nx+i), 4] = 1
			pnames = c(pnames, nnx)
		}
	} else{
		pnames = c(pnames, "alpha")
	}
	pidx[8,2] = nx+pn

	nx = nx + pn
	pn = 1
	pidx[9,1] = nx+1
	if(pos.matrix[9,3]==1){
		pn = length( seq(pos.matrix[9,1], pos.matrix[9,2], by = 1) )
		for(i in 1:pn){
			pars[(nx+i), 1] = 0
			pars[(nx+i), 3] = 1
			nnx = paste("beta", i, sep="")
			sp = na.omit(match(fixed.names, nnx))
			if(length(sp)>0) pars[(nx+i), 2] = 1 else pars[(nx+i), 4] = 1
			pnames = c(pnames, nnx)
		}
		# SimLev: Sonderfall iGARCH entfaellt
	} else{
		pnames = c(pnames, "beta")
	}
	pidx[9,2] = nx+pn

	nx = nx + pn
	pn = 1
	pidx[10,1] = nx+1

	if(pos.matrix[10,3]==1){
		pn = length( seq(pos.matrix[10,1], pos.matrix[10,2], by = 1) )
		for(i in 1:pn){
			pars[(nx+i), 1] = 0
			pars[(nx+i), 3] = 1
			nnx = paste("gamma", i, sep="")
			sp = na.omit(match(fixed.names, nnx))
			if(length(sp)>0) pars[(nx+i), 2] = 1 else pars[(nx+i), 4] = 1
			pnames = c(pnames, nnx)
		}
	} else{
		pnames = c(pnames, "gamma")
	}
	pidx[10,2] = nx+pn

	nx = nx + pn
	pn = 1
	pidx[11,1] = nx+1

	if(pos.matrix[11,3]==1){
		pn = length( seq(pos.matrix[11,1], pos.matrix[11,2], by = 1) )
		for(i in 1:pn){
			pars[(nx+i), 1] = 0
			pars[(nx+i), 3] = 1
			nnx = paste("eta1", i, sep="")
			sp = na.omit(match(fixed.names, nnx))
			if(length(sp)>0) pars[(nx+i), 2] = 1 else pars[(nx+i), 4] = 1
			pnames = c(pnames, nnx)
		}
	} else{
		pnames = c(pnames, "eta1")
	}
	pidx[11,2] = nx+pn

	nx = nx + pn
	pn = 1
	pidx[12,1] = nx+1

	if(pos.matrix[12,3]==1){
		pn = length( seq(pos.matrix[12,1], pos.matrix[12,2], by = 1) )
		for(i in 1:pn){
			pars[(nx+i), 1] = 0
			pars[(nx+i), 3] = 1
			nnx = paste("eta2", i, sep="")
			sp = na.omit(match(fixed.names, nnx))
			if(length(sp)>0) pars[(nx+i), 2] = 1 else pars[(nx+i), 4] = 1
			pnames = c(pnames, nnx)
		}
	} else{
		pnames = c(pnames, "eta2")
	}
	pidx[12,2] = nx+pn

	nx = nx + pn
	pn = 1
	pidx[13,1] = nx+1

	if(pos.matrix[13,3]==1){
		pars[nx+pn, 3] = 1
		pars[nx+pn, 1] = 0
		if(any(substr(fixed.names, 1, 5)=="delta")) pars[nx+pn,2] = 1 else pars[nx+pn,4] = 1
	}
	# SimLev: Sonderfall fGARCH (delta) entfaellt
	pidx[13,2] = nx+pn

	pnames = c(pnames, "delta")

	nx = nx + pn
	pn = 1
	pidx[14,1] = nx+1

	if(pos.matrix[14,3]==1){
		pars[nx+pn, 3] = 1
		pars[nx+pn, 1] = 0
		if(any(substr(fixed.names, 1, 6)=="lambda")) pars[nx+pn,2] = 1 else pars[nx+pn,4] = 1
	}
	# SimLev: Sonderfall fGARCH (lambda) entfaellt
	pidx[14,2] = nx+pn

	pnames = c(pnames, "lambda")

	nx = nx + pn
	pn = 1
	pidx[15,1] = nx+1

	if(pos.matrix[15,3]==1){
		pn = length( seq(pos.matrix[15,1], pos.matrix[15,2], by = 1) )
		for(i in 1:pn){
			pars[(nx+i), 1] = 0
			pars[(nx+i), 3] = 1
			nnx = paste("vxreg", i, sep="")
			sp = na.omit(match(fixed.names, nnx))
			if(length(sp)>0) pars[(nx+i), 2] = 1 else pars[(nx+i), 4] = 1
			pnames = c(pnames, nnx)
		}
	} else{
		pnames = c(pnames, "vxreg")

	}
	pidx[15,2] = nx+pn

	nx = nx + pn
	pn = 1
	pidx[16,1] = nx+1

	if(pos.matrix[16,3]==1){
		pars[nx+pn, 3] = 1
		pars[nx+pn, 1] = 0
		if(any(substr(fixed.names, 1, 4)=="skew")) pars[nx+pn,2] = 1 else pars[nx+pn,4] = 1
	}
	pidx[16,2] = nx+pn

	pnames = c(pnames, "skew")

	nx = nx + pn
	pn = 1
	pidx[17,1] = nx+1

	if(pos.matrix[17,3]==1){
		pars[nx+pn, 3] = 1
		pars[nx+pn, 1] = 0
		if(any(substr(fixed.names, 1, 5)=="shape")) pars[nx+pn,2] = 1 else pars[nx+pn,4] = 1
	}
	pnames = c(pnames, "shape")
	pidx[17,2] = nx+pn

	nx = nx + pn
	pn = 1
	pidx[18,1] = nx+1

	if(pos.matrix[18,3]==1){
		pars[nx+pn, 3] = 1
		pars[nx+pn, 1] = 0
		if(any(substr(fixed.names, 1, 8)=="ghlambda")) pars[nx+pn,2] = 1 else pars[nx+pn,4] = 1
	}
	pidx[18,2] = nx+pn
	pnames = c(pnames, "ghlambda")

	nx = nx + pn
	pn = 1
	pidx[19,1] = nx+1

	if(pos.matrix[19,3]==1){
		pars[nx+pn, 3] = 1
		pars[nx+pn, 1] = 0
		if(any(substr(fixed.names, 1, 2)=="xi")) pars[nx+pn,2] = 1 else pars[nx+pn,4] = 1
	}
	pidx[19,2] = nx+pn
	pnames = c(pnames, "xi")


	rownames(pars) = pnames

	zf = match(fixed.names, rownames(pars))
	if( length(zf)>0 ) pars[zf, 1] = unlist(fixed.pars)
	pars[,"LB"] = NA
	pars[,"UB"] = NA
	model = list(modelinc = modelinc, modeldesc = modeldesc, modeldata = modeldata, pars = pars,
			start.pars = start.pars, fixed.pars = fixed.pars, maxOrder = maxOrder,
			pos.matrix = pos.matrix, fmodel = fmodel, pidx = pidx)
	# SimLev: Liste der Klasse "uGARCHspec" statt S4-Objekt new("uGARCHspec", model = model);
	# die Pruefung fuer fiGARCH entfaellt
	ans = structure(list(model = model), class = "uGARCHspec")
	return(ans)
}

# rugarch-methods.R: .expand.model
.rugarch_expand.model = function(model){
	modelnames = NULL
	for(i in 1:21){
		if(model[i]>0){
			if(any(c(2,3,6,8,9,10,11,12,15) == i)){
				modelnames = c(modelnames, paste(names(model)[i], 1:model[i], sep = ""))
			} else{
				modelnames = c(modelnames, names(model)[i])
			}
		}
	}
	return( modelnames )
}

# rugarch-distributions.R: .DistributionBounds
.rugarch_DistributionBounds = function(distribution)
{
	ghlambda = 0
	ghlambda.LB = 0
	ghlambda.UB = 0
	if (distribution == "norm"){
		skew 	= 0
		skew.LB = 0
		skew.UB = 0
		shape 	= 0
		shape.LB = 0
		shape.UB = 0}
	# SimLev: die Grenzen der uebrigen Verteilungen entfallen (nur "norm" uebernommen)
	# johnson has 2 shape parameters. The second one we model with the "skew"
	# representation in rugarch
	skewed.dists = c("snorm", "sged", "sstd", "nig", "ghyp", "jsu", "ghst")
	shaped.dists = c("ged", "sged", "std", "sstd", "nig", "ghyp", "jsu", "ghst")
	skew0  = 0
	shape0 = 0
	if(any(skewed.dists == distribution)) include.skew=TRUE else include.skew=FALSE
	if(any(shaped.dists == distribution)) include.shape=TRUE else include.shape=FALSE
	if(distribution == "ghyp") include.ghlambda = TRUE else include.ghlambda = FALSE
	return( list(shape = shape, shape.LB = shape.LB, shape.UB = shape.UB, skew = skew,
					skew.LB = skew.LB, skew.UB = skew.UB, include.skew = include.skew, 
					include.shape = include.shape, skew0 = skew0, shape0 = shape0,
					include.ghlambda = include.ghlambda, ghlambda = ghlambda, 
					ghlambda.LB = ghlambda.LB, ghlambda.UB = ghlambda.UB) )
}

# rugarch-methods.R: .ugarchfit
.rugarch_ugarchfit = function(spec, data, out.sample = 0, solver = "solnp", solver.control = list(),
		fit.control = list(stationarity = 1, fixed.se = 0, scale = 0, rec.init = 'all', trunclag = 1000),
		numderiv.control = list(grad.eps=1e-4, grad.d=0.0001, grad.zero.tol=sqrt(.Machine$double.eps/7e-7),
				hess.eps=1e-4, hess.d=0.1, hess.zero.tol=sqrt(.Machine$double.eps/7e-7), r=4, v=2),...)
{
	default.numd = list(grad.eps=1e-4, grad.d=0.0001, grad.zero.tol=sqrt(.Machine$double.eps/7e-7),
			hess.eps=1e-4, hess.d=0.1, hess.zero.tol=sqrt(.Machine$double.eps/7e-7), r=4, v=2)
	idx1 = na.omit(match(names(numderiv.control), names(default.numd)))
	idx2 = na.omit(match(names(default.numd), names(numderiv.control)))
	if(length(idx1)>0){
		default.numd[idx1] = numderiv.control[idx2]
	}

	# SimLev: spec$model statt spec@model; nur sGARCH und gjrGARCH uebernommen
	# (die uebrigen Modelle laesst .rugarch_ugarchspec nicht zu)
	return( switch(spec$model$modeldesc$vmodel,
					sGARCH = .rugarch_sgarchfit(spec = spec, data = data, out.sample = out.sample, solver = solver,
							solver.control = solver.control, fit.control = fit.control, numderiv.control = default.numd),
					gjrGARCH = .rugarch_gjrgarchfit(spec = spec, data = data, out.sample = out.sample, solver = solver,
							solver.control = solver.control, fit.control = fit.control, numderiv.control = default.numd)) )
}

# rugarch-methods.R: .ugarchfitcoef
.rugarch_coef = function(object)
{
	object$fit$coef
}

# rugarch-sgarch.R: .sgarchfit
.rugarch_sgarchfit = function(spec, data, out.sample = 0, solver = "solnp", solver.control = list(),
		fit.control = list(stationarity = 1, fixed.se = 0, scale = 0, rec.init = 'all', trunclag = 1000),
		numderiv.control = list(grad.eps=1e-4, grad.d=0.0001, grad.zero.tol=sqrt(.Machine$double.eps/7e-7),
				hess.eps=1e-4, hess.d=0.1, hess.zero.tol=sqrt(.Machine$double.eps/7e-7), r=4, v=2))
{
	tic = Sys.time()
	if(is.null(solver.control$trace)) trace = 0 else trace = solver.control$trace

	if(is.null(fit.control$stationarity)) fit.control$stationarity = TRUE
	if(is.null(fit.control$fixed.se)) fit.control$fixed.se = FALSE
	if(is.null(fit.control$scale)) fit.control$scale = FALSE
	if(is.null(fit.control$rec.init)) fit.control$rec.init = 'all'
	if(is.null(fit.control$trunclag)) fit.control$trunclag = 1000
	mm = match(names(fit.control), c("stationarity", "fixed.se", "scale", "rec.init", "trunclag"))
	if(any(is.na(mm))){
		idx = which(is.na(mm))
		enx = NULL
		for(i in 1:length(idx)) enx = c(enx, names(fit.control)[idx[i]])
		warning(paste(c("unidentified option(s) in fit.control:\n", enx), sep="", collapse=" "), call. = FALSE, domain = NULL)
	}
	# if we have external regressors in variance turn off scaling
	if(spec$model$modelinc[15] > 0) fit.control$scale = FALSE
	# if we have arch-in-mean turn off scaling
	if(spec$model$modelinc[5] > 0) fit.control$scale = FALSE

	# if there are fixed pars we do no allow scaling as there would be no way of mixing scaled
	# amd non scaled parameters
	if(sum(spec$model$pars[,2]) > 0) fit.control$scale = FALSE
	xdata = .rugarch_extractdata(data)
	if(!is.numeric(out.sample)) stop("\nugarchfit-->error: out.sample must be numeric\n")
	if(as.numeric(out.sample)<0) stop("\nugarchfit-->error: out.sample must be positive\n")
	n.start = round(out.sample,0)
	n = length(xdata$data)
	if((n-n.start)<100) warning("\nugarchfit-->waring: using less than 100 data\n points for estimation\n")
	#if((n-n.start)<100) stop("\nugarchfit-->error: function requires at least 100 data\n points to run\n")
	data = xdata$data[1:(n-n.start)]
	index = xdata$index[1:(n-n.start)]
	origdata = xdata$data
	origindex = xdata$index
	period = xdata$period
	# arglist replaces the use of custom environments (resolves the problem of
	# non-shared environment in parallel estimation, particularly windows)
	garchenv = new.env(hash = TRUE)
	arglist = list()
	arglist$garchenv <- garchenv
	arglist$pmode = 0
	model = spec$model
	modelinc = model$modelinc
	pidx = model$pidx
	# expand the spec object and assign spec lists
	if(modelinc[6] > 0){
		mexdata = model$modeldata$mexdata[1:(n-n.start), , drop = FALSE]
	} else{
		mexdata = NULL
	}

	if(modelinc[15] > 0){
		vexdata = model$modeldata$vexdata[1:(n-n.start), ,drop = FALSE]
	} else{
		vexdata = NULL
	}
	arglist$index = index
	arglist$trace = trace
	m =  model$maxOrder
	# store length of data for easy retrieval
	model$modeldata$T = T = length(as.numeric(data))
	dist = model$modeldesc$distribution
	if(fit.control$scale) dscale = sd(data) else dscale = 1
	zdata = data/dscale
	recinit = .rugarch_checkrec(fit.control$rec.init, T)
	arglist$data = zdata
	arglist$recinit = recinit
	arglist$dscale = dscale
	arglist$model = model
	ipars = model$pars
	# Optimization Starting Parameters Vector & Bounds
	tmp = .rugarch_garchstart(ipars, arglist)
	####################################################
	# Scale Omega in order to avoid problems: (25-01-2013)
	#arglist$omegascale = 1/1e8
	#tmp$ipars["omega",c(1,5,6)] = tmp$ipars["omega",c(1,5,6)]  *1e8
	####################################################

	ipars = arglist$ipars = tmp$pars
	arglist$tmph  = tmp$tmph
	# we now split out any fixed parameters
	estidx = as.logical( ipars[,4] )
	arglist$estidx = estidx
	arglist$fit.control = fit.control
	npars = sum(estidx)
	if(any(ipars[,2]==1)){
		if(npars == 0){
			if(fit.control$fixed.se==0) {
				# if all parameters are fixed an no standard erros are to
				# be calculated then we return a ugarchfilter object
				warning("\nugarchfit-->warning: all parameters fixed...returning ugarchfilter object instead\n")
				# SimLev: ugarchfilter nicht uebernommen
				stop("rugarch-Uebernahme: ugarchfit mit ausschliesslich festen Parametern (ugarchfilter) nicht uebernommen", call. = FALSE)
			} else{
				# if all parameters are fixed but we require standard errors, we
				# skip the solver
				use.solver = 0
				ipars[ipars[,2]==1, 4] = 1
				ipars[ipars[,2]==1, 2] = 0
				arglist$ipars = ipars
				estidx = as.logical( ipars[,4] )
				arglist$estidx = estidx
			}
		} else{
			# with some parameters fixed we extract them (to be rejoined at end)
			# so that they do not enter the solver
			use.solver = 1
		}
	} else{
		use.solver = 1
	}
	# start counter
	assign("rugarch_llh", 1, envir = garchenv)
	# assign solver constraints (solnp directly else exterior type penalty
	# for other solvers)
	if(fit.control$stationarity == 1 && modelinc[15] == 0){
		cb = .rugarch_garchconbounds()
		Ifn = .rugarch_sgarchcon
		ILB = cb$LB
		IUB = cb$UB
		if(solver == "solnp" | solver == "gosolnp" | solver == "hybrid") fit.control$stationarity = 0
	} else{
		Ifn = NULL
		ILB = NULL
		IUB = NULL
	}
	# conditions controls the non-solnp solver penalty
	arglist$fit.control = fit.control
	if(use.solver){
		parscale = rep(1, length = npars)
		names(parscale) = rownames(ipars[estidx,])
		if(modelinc[1] > 0) parscale["mu"] = abs(mean(zdata))
		if(modelinc[7] > 0) parscale["omega"] = var(zdata)
		arglist$returnType = "llh"
		solution = .rugarch_garchsolver(solver, pars = ipars[estidx, 1], fun = .rugarch_sgarchLLH,
				Ifn, ILB, IUB, gr = NULL, hessian = NULL, parscale = parscale,
				control = solver.control, LB = ipars[estidx, 5],
				UB = ipars[estidx, 6], ux = NULL, ci = NULL, mu = NULL, arglist)
		sol = solution$sol
		hess = solution$hess
		timer = Sys.time()-tic
		if(!is.null(sol$par)){
			ipars[estidx, 1] = sol$par
			if(modelinc[7]==0){
				# call it once more to get omega
				tmpx = .rugarch_sgarchLLH(sol$par, arglist)
				ipars[pidx["omega",1], 1] = get("omega", garchenv)
			}
			if(sum(ipars[,2]) == 0){
				if(modelinc[1] > 0) ipars[pidx["mu",1]:pidx["mu",2], 1] = ipars[pidx["mu",1]:pidx["mu",2], 1] * dscale
				if(modelinc[6] > 0){
					ipars[pidx["mxreg", 1]:pidx["mxreg", 2], 1] = ipars[pidx["mxreg", 1]:pidx["mxreg", 2], 1] * dscale
				}
				ipars[pidx["omega",1], 1] = ipars[pidx["omega",1],1] * dscale^2
			}
		} else{
			ipars[estidx, 1] = NA
		}
		arglist$ipars = ipars
		convergence = sol$convergence
		if(convergence != 0) warning("\nugarchfit-->warning: solver failer to converge.")
	} else{
		solution = NULL
		hess = NULL
		timer = Sys.time()-tic
		convergence = 0
		sol = list()
		sol$message = "all parameters fixed"
	}
	fit = list()
	# check convergence else write message/return
	# create a copy of ipars in case we need to change it below to calculate standard errors
	# which we will need to reset later (because for example, infocriteria uses estimated
	# parameters, not fixed.
	ipars2 = ipars
	if(convergence == 0){
		arglist$dscale = 1
		if(sum(ipars[,2]) > 0 && fit.control$fixed.se == 1){
			ipars[ipars[,2]==1, 4] = 1
			ipars[ipars[,2]==1, 2] = 0
			arglist$ipars = ipars
			estidx = as.logical( ipars[,4] )
			arglist$estidx = estidx
		}
		arglist$data = data
		fit = .rugarch_makefitmodel(garchmodel = "sGARCH", f = .rugarch_sgarchLLH, T = T, m = m,
				timer = timer, convergence = convergence, message = sol$message,
				hess = hess, arglist = arglist, numderiv.control = numderiv.control)
		model$modelinc[7] = modelinc[7]
		model$modeldata$data = origdata
		model$modeldata$index = origindex
		model$modeldata$period = period
		model$pars[, 1] = fit$ipars[,1]
		model$pars[, 5:6] = ipars2[,5:6]
		fit$ipars[, 4] = ipars2[, 4]
		fit$ipars[, 2] = ipars2[, 2]
		fit$ipars[, 5:6] = ipars2[,5:6]
		# make sure omega is now included (for working with object post-estimation)
		fit$ipars["omega", 3] = 1
		model$pars["omega", 3] = 1
	} else{
		fit$message = sol$message
		fit$convergence = 1
		model$modeldata$data = origdata
		model$modeldata$index = origindex
		model$modeldata$period = period
	}
	# make model list to return some usefule information which
	# will be called by other functions (show, plot, sim etc)
	model$n.start = n.start
	fit$solver = solution
	# SimLev: Liste der Klasse "uGARCHfit" statt S4-Objekt new("uGARCHfit", fit = fit, model = model)
	ans = structure(list(fit = fit, model = model), class = "uGARCHfit")
	return(ans)
}

# rugarch-sgarch.R: .sgarchLLH
.rugarch_sgarchLLH = function(pars, arglist)
{
	# prepare inputs
	data = arglist$data
	returnType = arglist$returnType
	garchenv = arglist$garchenv
	# rejoin fixed and pars
	model = arglist$model
	estidx = arglist$estidx
	idx = model$pidx
	ipars = arglist$ipars
	ipars[estidx, 1] = pars
	trace = arglist$trace
	T = length(data)
	dscale = arglist$dscale
	recinit = arglist$recinit
	fit.control = arglist$fit.control
	m = model$maxOrder
	N = c(m,T)
	# SimLev: ohne zoo::coredata (externe Regressoren nicht uebernommen, beide NULL)
	mexdata = model$modeldata$mexdata[1:T,, drop = FALSE]
	vexdata = model$modeldata$vexdata[1:T,, drop = FALSE]
	distribution = model$modeldesc$distribution
	modelinc = model$modelinc
	# distribution number
	# 1 = norm, 2=snorm, 3=std, 4=sstd, 5=ged, 6=sged, 7=nig
	dist = model$modeldesc$distno
	hm = arglist$tmph
	rx = .rugarch_arfimaxfilter(modelinc[1:21], pars = ipars[,1], idx = idx, mexdata = mexdata, h = hm, data = data, N = N)
	res = rx$res
	zrf = rx$zrf
	res[is.na(res) | !is.finite(res) | is.nan(res)] = 0
	# sgarch persistence value
	kappa = 1
	persist = (sum(ipars[idx["alpha",1]:idx["alpha",2],1]) + sum(ipars[idx["beta",1]:idx["beta",2],1]))
	# recursion initialization
	mvar = ifelse(recinit$type==1, mean(res[1:recinit$n]*res[1:recinit$n]), .rugarch_backcastv(res, T, recinit$n))
	if(modelinc[15]>0) {
		mv = sum(apply(matrix(vexdata, ncol = modelinc[15]), 2, "mean")*ipars[idx["vxreg",1]:idx["vxreg",2],1])
	} else{
		mv = 0
	}
	hEst = mvar
	# variance targeting
	if(modelinc[7]>0){
		ipars[idx["omega",1],1] = max(.rugarch_eps, ipars[idx["omega",1],1])
	} else{
		mvar2 = ifelse(!is.na(modelinc[22]), modelinc[22]/dscale, mvar)
		ipars[idx["omega",1],1] = mvar2 * (1 - persist) - mv
		assign("omega", ipars[idx["omega",1],1], garchenv)
	}
	if(is.na(hEst) | !is.finite(hEst) | is.nan(hEst)) hEst = var(data) * (1 - persist)
	# if we have external regressors in variance equation we cannot have
	# stationarity checks in likelihood. Stationarity conditions not valid for
	# solnp solver which implements them internally as constraints.
	if(fit.control$stationarity == 1 && modelinc[15] == 0){
		if(!is.na(persist) && persist >= 1){
			if(arglist$pmode!=1){
				return(llh = get("rugarch_llh", garchenv) + 0.1*(abs(get("rugarch_llh", garchenv))))
			} else{
				return(llh = 1e10)
			}
		}
	}
	if(modelinc[6]>0) mexdata = as.double(as.vector(mexdata)) else mexdata = double(1)
	if(modelinc[15]>0) vexdata = as.double(as.vector(vexdata)) else vexdata = double(1)
	# modelinc (1:21) since 22 is either NA or numeric and no longer needed (paased to ipars if used)
	# SimLev: .Call-Huelle (src/vendor_rugarch.c) statt .C("sgarchfilterC", ..., PACKAGE = "rugarch");
	# sie prueft und kopiert die Argumente wie .C und gibt die Liste der Argumente zurueck
	ans = try( .Call(C_rugarch_sgarchfilterC, list(model = as.integer(modelinc[1:21]),
					pars = as.double(ipars[,1]), idx = as.integer(idx[,1]-1),
					hEst = as.double(hEst), x = as.double(data), res = as.double(res),
					e = double(T), mexdata = mexdata, vexdata = vexdata,
					zrf = as.double(zrf), constm = double(T), condm = double(T),
					m = as.integer(m), T = as.integer(T), h = double(T),
					z = double(T), llh = double(1), LHT = double(T))), silent = TRUE )

	if(inherits(ans, "try-error")){
		if(arglist$pmode!=1){
			assign("rugarch_csol", 1, envir = garchenv)
			assign("rugarch_filtermessage", ans, envir = garchenv)
			if( trace > 0 ) cat(paste("\narfimafit-->warning: ", get("rugarch_filtermessage", garchenv),"\n", sep=""))
			return(llh = (get("rugarch_llh", garchenv) + 0.1*(abs(get("rugarch_llh", garchenv)))))
		} else{
			return(llh = 1e10)
		}
	} else{
		if(arglist$pmode!=1){
			assign("rugarch_csol", 0, envir = garchenv)
		}
	}
	z = ans$z
	h = ans$h
	epsx = ans$res
	llh = ans$llh

	if(is.finite(llh) && !is.na(llh) && !is.nan(llh)){
		if(arglist$pmode!=1) assign("rugarch_llh", llh, envir = garchenv)
	} else {
		if(arglist$pmode!=1) llh = (get("rugarch_llh", garchenv) + 0.1*(abs(get("rugarch_llh", garchenv)))) else llh = 1e10
	}


	# LHT = raw scores
	# ? -ans$LHT[(m+1):T]
	LHT = -ans$LHT
	ans = switch(returnType,
			llh = llh,
			LHT = LHT,
			all = list(llh = llh, h = h, epsx = epsx, z = z, kappa = kappa,
					LHT = LHT, persistence = persist))
	return(ans)
}

# rugarch-gjrgarch.R: .gjrgarchfit
.rugarch_gjrgarchfit = function(spec, data, out.sample = 0, solver = "solnp", solver.control = list(),
		fit.control = list(stationarity = 1, fixed.se = 0, scale = 0, rec.init = 'all', trunclag  = 1000),
		numderiv.control = list(grad.eps=1e-4, grad.d=0.0001, grad.zero.tol=sqrt(.Machine$double.eps/7e-7),
				hess.eps=1e-4, hess.d=0.1, hess.zero.tol=sqrt(.Machine$double.eps/7e-7), r=4, v=2))
{
	tic = Sys.time()
	if(is.null(solver.control$trace)) trace = 0 else trace = solver.control$trace

	if(is.null(fit.control$stationarity)) fit.control$stationarity = TRUE
	if(is.null(fit.control$fixed.se)) fit.control$fixed.se = FALSE
	if(is.null(fit.control$scale)) fit.control$scale = FALSE
	if(is.null(fit.control$rec.init)) fit.control$rec.init = 'all'
	if(is.null(fit.control$trunclag)) fit.control$trunclag = 1000

	mm = match(names(fit.control), c("stationarity", "fixed.se", "scale", "rec.init", "trunclag"))
	if(any(is.na(mm))){
		idx = which(is.na(mm))
		enx = NULL
		for(i in 1:length(idx)) enx = c(enx, names(fit.control)[idx[i]])
		warning(paste(c("unidentified option(s) in fit.control:\n", enx), sep="", collapse=" "), call. = FALSE, domain = NULL)
	}
	# if we have external regressors in variance turn off scaling
	if(spec$model$modelinc[15] > 0) fit.control$scale = FALSE
	if(spec$model$modelinc[5] > 0) fit.control$scale = FALSE

	# if there are fixed pars we do no allow scaling as there would be no way of mixing scaled
	# amd non scaled parameters
	if(sum(spec$model$pars[,2]) > 0) fit.control$scale = FALSE
	xdata = .rugarch_extractdata(data)
	if(!is.numeric(out.sample)) stop("\nugarchfit-->error: out.sample must be numeric\n")
	if(as.numeric(out.sample)<0) stop("\nugarchfit-->error: out.sample must be positive\n")
	n.start = round(out.sample,0)
	n = length(xdata$data)
	if((n-n.start)<100) warning("\nugarchfit-->waring: using less than 100 data\n points for estimation\n")
	data = xdata$data[1:(n-n.start)]
	index = xdata$index[1:(n-n.start)]
	origdata = xdata$data
	origindex = xdata$index
	period = xdata$period
	# create a temporary environment to store values (deleted at end of function)
	garchenv = new.env(hash = TRUE)
	arglist = list()
	arglist$garchenv <- garchenv
	arglist$pmode = 0
	model = spec$model
	modelinc = model$modelinc
	pidx = model$pidx
	# expand the spec object and assign spec lists
	if(modelinc[6] > 0){
		mexdata = model$modeldata$mexdata[1:(n-n.start), , drop = FALSE]
	} else{
		mexdata = NULL
	}

	if(modelinc[15] > 0){
		vexdata = model$modeldata$vexdata[1:(n-n.start), ,drop = FALSE]
	} else{
		vexdata = NULL
	}
	arglist$index = index
	arglist$trace = trace
	m =  model$maxOrder
	model$modeldata$T = T = length(as.numeric(data))
	dist = model$modeldesc$distribution
	if(fit.control$scale) dscale = sd(data) else dscale = 1
	zdata = data/dscale
	recinit = .rugarch_checkrec(fit.control$rec.init, T)
	arglist$data = zdata
	arglist$recinit = recinit
	arglist$dscale = dscale
	arglist$model = model
	ipars = model$pars
	# Optimization Starting Parameters Vector & Bounds
	tmp = .rugarch_garchstart(ipars, arglist)
	ipars = arglist$ipars = tmp$pars
	arglist$tmph  = tmp$tmph
	# we now split out any fixed parameters
	estidx = as.logical( ipars[,4] )
	arglist$estidx = estidx
	arglist$fit.control = fit.control

	npars = sum(estidx)
	if(any(ipars[,2]==1)){
		if(npars == 0){
			if(fit.control$fixed.se==0) {
				# if all parameters are fixed an no standard erros are to
				# be calculated then we return a ugarchfilter object
				warning("\nugarchfit-->warning: all parameters fixed...returning ugarchfilter object instead\n")
				# SimLev: ugarchfilter nicht uebernommen
				stop("rugarch-Uebernahme: ugarchfit mit ausschliesslich festen Parametern (ugarchfilter) nicht uebernommen", call. = FALSE)
			} else{
				# if all parameters are fixed but we require standard errors, we
				# skip the solver
				use.solver = 0
				ipars[ipars[,2]==1, 4] = 1
				ipars[ipars[,2]==1, 2] = 0
				arglist$ipars = ipars
				estidx = as.logical( ipars[,4] )
				arglist$estidx = estidx
			}
		} else{
			# with some parameters fixed we extract them (to be rejoined at end)
			# so that they do not enter the solver
			use.solver = 1
		}
	} else{
		use.solver = 1
	}
	# start counter
	assign("rugarch_llh", 1, envir = garchenv)
	# assisgn solver constraints (solnp directly else exterior type penalty
	# for other solvers)

	if(fit.control$stationarity == 1 && modelinc[15] == 0){
		cb = .rugarch_garchconbounds()
		Ifn = .rugarch_gjrgarchcon
		ILB = cb$LB
		IUB = cb$UB
		if(solver == "solnp" | solver == "gosolnp" | solver == "hybrid") fit.control$stationarity = 0
	} else{
		Ifn = NULL
		ILB = NULL
		IUB = NULL
	}
	# conditions controls the non-solnp solver penalty
	arglist$fit.control = fit.control
	if(use.solver){
		parscale = rep(1, length = npars)
		names(parscale) = rownames(ipars[estidx,])
		if(modelinc[1] > 0) parscale["mu"] = abs(mean(zdata))
		if(modelinc[7] > 0) parscale["omega"] = var(zdata)
		arglist$returnType = "llh"
		solution = .rugarch_garchsolver(solver, pars = ipars[estidx, 1], fun = .rugarch_gjrgarchLLH,
				Ifn, ILB, IUB, gr = NULL, hessian = NULL, parscale = parscale,
				control = solver.control, LB = ipars[estidx, 5],
				UB = ipars[estidx, 6], ux = NULL, ci = NULL, mu = NULL,
				arglist)
		sol = solution$sol
		hess = solution$hess
		timer = Sys.time()-tic
		if(!is.null(sol$par)){
			ipars[estidx, 1] = sol$par
			if(modelinc[7]==0){
				# call it once more to get omega
				tmpx = .rugarch_gjrgarchLLH(sol$par, arglist)
				ipars[pidx["omega",1], 1] = get("omega", garchenv)
			}
			if(sum(ipars[,2]) == 0){
				if(modelinc[1] > 0) ipars[pidx["mu",1]:pidx["mu",2], 1] = ipars[pidx["mu",1]:pidx["mu",2], 1] * dscale
				if(modelinc[6] > 0){
					ipars[pidx["mxreg", 1]:pidx["mxreg", 2], 1] = ipars[pidx["mxreg", 1]:pidx["mxreg", 2], 1] * dscale
				}
				ipars[pidx["omega",1],1] = ipars[pidx["omega",1],1] * dscale^2
			}

		} else{
			ipars[estidx, 1] = NA
		}
		arglist$ipars = ipars
		convergence = sol$convergence
	} else{
		solution = NULL
		hess = NULL
		timer = Sys.time()-tic
		convergence = 0
		sol = list()
		sol$message = "all parameters fixed"
	}
	fit = list()
	# check convergence else write message/return
	ipars2 = ipars
	if(convergence == 0){
		arglist$dscale = 1
		if(sum(ipars[,2]) > 0 && fit.control$fixed.se == 1){
			ipars[ipars[,2]==1, 4] = 1
			ipars[ipars[,2]==1, 2] = 0
			arglist$ipars = ipars
			estidx = as.logical( ipars[,4] )
			arglist$estidx = estidx
		}
		arglist$data = data
		fit = .rugarch_makefitmodel(garchmodel = "gjrGARCH", f = .rugarch_gjrgarchLLH, T = T,
				m = m, timer = timer, convergence = convergence, message = sol$message,
				hess, arglist = arglist, numderiv.control = numderiv.control)
		model$modelinc[7] = modelinc[7]
		model$modeldata$data = origdata
		model$modeldata$index = origindex
		model$modeldata$period = period
		model$pars[, 1] = fit$ipars[,1]
		model$pars[, 5:6] = ipars2[,5:6]
		fit$ipars[, 4] = ipars2[, 4]
		fit$ipars[, 2] = ipars2[, 2]
		fit$ipars[, 5:6] = ipars2[,5:6]
		# make sure omega is now included (for working with object post-estimation)
		fit$ipars["omega", 3] = 1
		model$pars["omega", 3] = 1
	} else{
		fit$message = sol$message
		fit$convergence = 1
		model$modeldata$data = origdata
		model$modeldata$index = origindex
		model$modeldata$period = period
	}

	# make model list to return some usefule information which
	# will be called by other functions (show, plot, sim etc)
	model$n.start = n.start
	fit$solver = solution
	# SimLev: Liste der Klasse "uGARCHfit" statt S4-Objekt new("uGARCHfit", fit = fit, model = model)
	ans = structure(list(fit = fit, model = model), class = "uGARCHfit")
	return(ans)
}

# rugarch-gjrgarch.R: .gjrgarchLLH
.rugarch_gjrgarchLLH = function(pars, arglist)
{
	# prepare inputs
	# rejoin fixed and pars
	data = arglist$data
	returnType = arglist$returnType
	garchenv = arglist$garchenv
	# rejoin fixed and pars
	model = arglist$model
	estidx = arglist$estidx
	idx = model$pidx
	ipars = arglist$ipars
	ipars[estidx, 1] = pars
	trace = arglist$trace
	T = length(data)
	dscale = arglist$dscale
	recinit = arglist$recinit
	fit.control = arglist$fit.control
	m = model$maxOrder
	N = c(m,T)
	# SimLev: ohne zoo::coredata (externe Regressoren nicht uebernommen, beide NULL)
	mexdata = model$modeldata$mexdata[1:T,, drop = FALSE]
	vexdata = model$modeldata$vexdata[1:T,, drop = FALSE]
	distribution = model$modeldesc$distribution
	modelinc = model$modelinc
	# distribution number
	# 1 = norm, 2=snorm, 3=std, 4=sstd, 5=ged, 6=sged, 7=nig
	dist = model$modeldesc$distno
	hm = arglist$tmph
	rx = .rugarch_arfimaxfilter(modelinc[1:21], ipars[,1], idx, mexdata = mexdata, h = hm, data = data, N = N)
	res = rx$res
	zrf = rx$zrf
	res[is.na(res) | !is.finite(res) | is.nan(res)] = 0

	sumalpha = sum(ipars[idx["alpha",1]:idx["alpha",2],1])
	sumbeta  = sum(ipars[idx["beta",1]:idx["beta",2],1])

	persist = sumalpha + sumbeta + sum(apply(as.data.frame(ipars[idx["gamma",1]:idx["gamma",2],1]), 1 , FUN=function(x)
						x * .rugarch_pneg(ipars[idx["ghlambda",1],1], ipars[idx["shape",1],1], ipars[idx["skew",1],1], distribution)))
	# unconditional sigma value
	mvar = ifelse(recinit$type==1, mean(res[1:recinit$n]*res[1:recinit$n]), .rugarch_backcastv(res, T, recinit$n))
	if(modelinc[15]>0) {
		mv = sum(apply(matrix(vexdata, ncol = modelinc[15]), 2, "mean")*ipars[idx["vxreg",1]:idx["vxreg",2],1])
	} else{
		mv = 0
	}
	hEst = mvar
	if(modelinc[7]>0){
		ipars[idx["omega",1],1] = max(.rugarch_eps, ipars[idx["omega",1],1])
	} else{
		mvar2 = ifelse(!is.na(modelinc[22]), modelinc[22]/dscale, mvar)
		ipars[idx["omega",1],1] = mvar2 * (1 - persist) - mv
		assign("omega", ipars[idx["omega",1],1], garchenv)
	}
	if(is.na(hEst) | !is.finite(hEst) | is.nan(hEst)) hEst = var(data) * (1 - persist)
	# if we have external regressors in variance equation we cannot have
	# stationarity checks in likelihood. Stationarity conditions not valid for
	# solnp sover which implements them internally as constraints.
	if(fit.control$stationarity == 1 && modelinc[15] == 0){
		if(!is.na(persist) && persist >= 1){
			if(arglist$pmode!=1){
				return(llh = get("rugarch_llh", garchenv) + 0.1*(abs(get("rugarch_llh", garchenv))))
			} else{
				return(llh = 1e10)
			}
		}
	}
	if(modelinc[6]>0) mexdata = as.double(as.vector(mexdata)) else mexdata = double(1)
	if(modelinc[15]>0) vexdata = as.double(as.vector(vexdata)) else vexdata = double(1)

	# SimLev: .Call-Huelle (src/vendor_rugarch.c) statt .C("gjrgarchfilterC", ..., PACKAGE = "rugarch");
	# sie prueft und kopiert die Argumente wie .C und gibt die Liste der Argumente zurueck
	ans = try( .Call(C_rugarch_gjrgarchfilterC, list(model = as.integer(modelinc[1:21]),
					pars = as.double(ipars[,1]), idx = as.integer(idx[,1]-1),
					hEst = as.double(hEst), x = as.double(data), res = as.double(res),
					nres = double(T), e = double(T), mexdata = mexdata,
					vexdata = vexdata, zrf = as.double(zrf), constm = double(T),
					condm = double(T), m = as.integer(m), T = as.integer(T),
					h = double(T), z = double(T), llh = double(1),
					LHT = double(T))), silent = TRUE )
	if(inherits(ans, "try-error")){
		if(arglist$pmode!=1){
			assign("rugarch_csol", 1, envir = garchenv)
			assign("rugarch_filtermessage", ans, envir = garchenv)
			if( trace > 0 ) cat(paste("\narfimafit-->warning: ", get("rugarch_filtermessage", garchenv),"\n", sep=""))
			return(llh = (get("rugarch_llh", garchenv) + 0.1*(abs(get("rugarch_llh", garchenv)))))
		} else{
			return(llh = 1e10)
		}
	} else{
		if(arglist$pmode!=1){
			assign("rugarch_csol", 0, envir = garchenv)
		}
	}
	z = ans$z
	h = ans$h
	epsx = ans$res
	llh = ans$llh

	if(is.finite(llh) && !is.na(llh) && !is.nan(llh)){
		if(arglist$pmode!=1) assign("rugarch_llh", llh, envir = garchenv)
	} else {
		if(arglist$pmode!=1) llh = (get("rugarch_llh", garchenv) + 0.1*(abs(get("rugarch_llh", garchenv)))) else llh = 1e10
	}

	# LHT = raw scores
	# ? -ans$LHT[(m+1):T]
	LHT = -ans$LHT
	ans = switch(returnType,
			llh = llh,
			LHT = LHT,
			all = list(llh = llh, h = h, epsx = epsx, z = z, kappa = kappa,
					LHT = LHT, persistence = persist))
	return(ans)
}

# rugarch-series.R: .extractdata
.rugarch_extractdata = function(data, warn = FALSE)
{
	# SimLev: statt as.xts(data), xts(), coredata() und index() (Pakete xts, zoo)
	# deren Weg fuer numerische Vektoren in Basis-R (.rugarch_as_xts_vec);
	# Matrizen, data.frames und Zeitreihenobjekte nicht uebernommen
	if(!is.null(dim(data)) || !is.atomic(data) || !is.numeric(data) || is.object(data))
		stop("rugarch-Uebernahme: ugarchfit nur fuer numerische Vektoren uebernommen", call. = FALSE)
	xdata = try(.rugarch_as_xts_vec(data), silent = TRUE)
	if(inherits(xdata, "try-error")){
		if(warn) warning("\nrugarch-->warning: data indexing not recognized by xts...coercing to Date with origin 1970-01-01.")
		if(is.data.frame(data) | is.matrix(data)) data = as.numeric(data[,1]) else data = as.numeric(data)
		data = unname(data)
		xdata = list(data = data, index = as.POSIXct(as.Date(seq_along(data), origin="1970-01-01")))
	}
	obj = list()
	obj$data = as.numeric(xdata$data)
	obj$index = xdata$index
	obj$period = median(diff(xdata$index))
	return(obj)
}

# SimLev: Nachbildung von xts::as.xts(x) fuer einen numerischen Vektor x
# (xts 0.13: as.xts.double ordnet nach as.POSIXct(names(x)), xts() sortiert,
# falls der Index nicht aufsteigend ist, und bricht bei nicht endlichem Index ab)
.rugarch_as_xts_vec = function(x)
{
	if(is.null(names(x)))
		stop("order.by must be either 'names()' or otherwise specified")
	order.by = do.call("as.POSIXct", list(names(x)))
	idx = as.numeric(order.by)
	n = length(idx)
	if(n > 1 && any(idx[-n] > idx[-1], na.rm = TRUE)){
		o = order(order.by)
		x = x[o]
		order.by = order.by[o]
		idx = idx[o]
	}
	if(any(!is.finite(idx)))
		stop("'order.by' cannot contain 'NA', 'NaN', or 'Inf'")
	return(list(data = unname(x), index = order.by))
}

# rugarch-helperfn.R: .checkrec
.rugarch_checkrec = function(init, T){
	if(is.null(init)){
		type = 1
		n = T
	} else{
		if(is.character(init)){
			if(init == "all"){
				type = 1
				n = T
			} else{
				warning("\nugarchfit-->warning: unrecognized option in rec.init...using 'all' option instead.\n")
				type = 1
				n = T
			}
		} else{
			if(init>=1){
				type = 1
				if(init<=T){
					n = round(init, 0)
				} else{
					n = T
					warning("\nugarchfit-->warning: rec.init value > n.obs (less out.sample)...setting value to n.obs instead.\n")
				}
			} else{
				if(init>0){
					type = 2
					n = init
				} else{
					warning("\nugarchfit-->warning: unrecognized option in rec.init...using 'all' option instead \n")
					type = 1
					n = T
				}
			}
		}
	}
	return(list(type = type, n = n))
}

# rugarch-helperfn.R: backcastv
.rugarch_backcastv = function(res, T, lambda, delta=2){
	s = mean(res^delta)
	v = (lambda^T)*s + (1-lambda)*sum(lambda^(0:(T-1))*(res^delta))
	return(v)
}

# rugarch-startpars.R: .garchstart
.rugarch_garchstart = function(pars, arglist)
{
	tmp = .rugarch_meqstartpars(pars, arglist)
	pars = tmp$pars
	tmph = tmp$temph
	# SimLev: nur sGARCH und gjrGARCH (.rugarch_aparchstart) uebernommen
	ans = switch(arglist$model$modeldesc$vmodel,
			sGARCH = .rugarch_aparchstart(pars, arglist),
			gjrGARCH = .rugarch_aparchstart(pars, arglist))
	return(list(pars = ans, tmph = tmph))
}

# rugarch-startpars.R: .meqstartpars
.rugarch_meqstartpars = function(pars, arglist)
{
	# Case 1 garchInMean yes:
	data = arglist$data
	model = arglist$model
	N = length(as.numeric(unlist(data)))
	modelinc = model$modelinc
	modeldesc = model$modeldesc
	idx = model$pidx
	mxreg = numeric()
	# SimLev: externe Regressoren, GARCH-in-Mean (ugarchfit, lm, arima0) und
	# ARMA-Startwerte (arima) entfallen (nicht uebernommen; .rugarch_ugarchspec
	# laesst sie nicht zu)
	mexdata = NULL
	tmph = 0
	if(modelinc[5]==0 && modelinc[2] == 0 && modelinc[3] == 0){
		y = data
		# SimLev: Zweig mit externen Regressoren (lm) entfaellt
		{
			if(modelinc[1]>0){
				pars[idx["mu", 1]:idx["mu", 2], 1] = mean(y)
			}
			#res=(data-mu)
		}
	}
	# assign("tmph", tmph, envir = garchenv)
	return(list(pars = pars, tmph = tmph))
}

# rugarch-startpars.R: .meqstart
.rugarch_meqstart = function(pars, arglist)
{
	data = arglist$data
	dscale = arglist$dscale
	model = arglist$model
	start.pars = model$start.pars
	start.names = names(start.pars)

	fixed.pars = model$fixed.pars
	fixed.names = names(fixed.pars)

	idx = model$pidx
	modelinc = model$modelinc

	# this is where we fix the bounds for the fixed parameters
	# fill and then the fixed.names to overwrite it...also for the
	# bounds

	if(modelinc[1]>0){
		# Need to control for this special case which sometimes occurs
		if(mean(data)==0){
			if(is.na(pars[idx["mu", 1]:idx["mu", 2], 5])) pars[idx["mu", 1]:idx["mu", 2], 5] = -0.5
			if(is.na(pars[idx["mu", 1]:idx["mu", 2], 6])) pars[idx["mu", 1]:idx["mu", 2], 6] =  0.5
		} else{
			if(is.na(pars[idx["mu", 1]:idx["mu", 2], 5])) pars[idx["mu", 1]:idx["mu", 2], 5] = -100*abs(mean(data))
			if(is.na(pars[idx["mu", 1]:idx["mu", 2], 6])) pars[idx["mu", 1]:idx["mu", 2], 6] =  100*abs(mean(data))
		}
			if(!is.null(start.pars$mu)) pars[idx["mu", 1]:idx["mu", 2], 1] = start.pars$mu[1]/dscale
			if(any(substr(fixed.names, 1, 2)=="mu")){
				pars[idx["mu", 1]:idx["mu", 2], 1] = as.numeric(fixed.pars$mu)
				pars[idx["mu", 1]:idx["mu", 2], 5] = fixed.pars$mu
				pars[idx["mu", 1]:idx["mu", 2], 6] = fixed.pars$mu
			}
	}

	# SimLev: ar, ma, archm, arfima und mxreg entfallen (nicht uebernommen;
	# .rugarch_ugarchspec laesst sie nicht zu)
	return( pars )
}

# rugarch-startpars.R: .aparchstart
.rugarch_aparchstart = function(pars, arglist)
{
	data = arglist$data
	model = arglist$model
	dscale = arglist$dscale
	modelinc = model$modelinc
	start.pars = model$start.pars
	fixed.pars = model$fixed.pars
	idx = model$pidx
	fixed.names = names(fixed.pars)
	start.names = names(start.pars)
	pars = .rugarch_meqstart(pars, arglist)
	if(modelinc[7]>0){
		if(is.na(pars[idx["omega", 1]:idx["omega", 2], 5])) pars[idx["omega", 1]:idx["omega", 2], 5] = .rugarch_eps
		if(is.na(pars[idx["omega", 1]:idx["omega", 2], 6])) pars[idx["omega", 1]:idx["omega", 2], 6] = var(data)*1000
		if(is.null(start.pars$omega)) pars[idx["omega", 1]:idx["omega", 2], 1] = (var(data, na.rm = TRUE))/1000 else
			pars[idx["omega", 1]:idx["omega", 2], 1] = start.pars$omega[1]/dscale
		if(any(substr(fixed.names, 1, 5) == "omega")){
			pars[idx["omega", 1]:idx["omega", 2], 1] = as.numeric(fixed.pars$omega)
			pars[idx["omega", 1]:idx["omega", 2], 5] = fixed.pars$omega
			pars[idx["omega", 1]:idx["omega", 2], 6] = fixed.pars$omega
		}
	}
	if(modelinc[8]>0){
		gpnames = paste("alpha",1:modelinc[8],sep="")
		pxd = which(is.na(pars[idx["alpha", 1]:idx["alpha", 2], 5]))
		if(length(pxd)>0) pars[(idx["alpha", 1]:idx["alpha", 2])[pxd], 5] = 0
		pxd = which(is.na(pars[idx["alpha", 1]:idx["alpha", 2], 6]))
		if(length(pxd)>0) pars[(idx["alpha", 1]:idx["alpha", 2])[pxd], 6] =  1-.rugarch_TinY
		pars[idx["alpha", 1]:idx["alpha", 2], 1] = rep(0.05/modelinc[8], modelinc[8])
		sp = na.omit(match(start.names, gpnames))
		if(length(sp)>0){
			for(i in 1:length(sp)) pars[gpnames[sp[i]], 1] = as.numeric(start.pars[gpnames[sp[i]]])
		}
		sp = na.omit(match(fixed.names, gpnames))
		if(length(sp)>0){
			for(i in 1:length(sp)){
				pars[gpnames[sp[i]], 1] = as.numeric(fixed.pars[gpnames[sp[i]]])
				pars[gpnames[sp[i]], 5] = as.numeric(fixed.pars[gpnames[sp[i]]])
				pars[gpnames[sp[i]], 6] = as.numeric(fixed.pars[gpnames[sp[i]]])
			}
		}
	}

	if(modelinc[10] > 0){
		gqnames = paste("gamma",1:modelinc[10],sep="")
		pxd = which(is.na(pars[idx["gamma", 1]:idx["gamma", 2], 5]))
		if(length(pxd)>0) pars[(idx["gamma", 1]:idx["gamma", 2])[pxd], 5] = -1+.rugarch_TinY
		pxd = which(is.na(pars[idx["gamma", 1]:idx["gamma", 2], 6]))
		if(length(pxd)>0) pars[(idx["gamma", 1]:idx["gamma", 2])[pxd], 6] =  1-.rugarch_TinY
		pars[idx["gamma", 1]:idx["gamma", 2], 1] = rep(0.05/modelinc[10],modelinc[10])
		sp = na.omit(match(start.names, gqnames))
		if(length(sp)>0){
			for(i in 1:length(sp)) pars[gqnames[sp[i]], 1] = as.numeric(start.pars[gqnames[sp[i]]])
		}
		sp = na.omit(match(fixed.names, gqnames))
		if(length(sp)>0){
			for(i in 1:length(sp)){
				pars[gqnames[sp[i]], 1] = as.numeric(fixed.pars[gqnames[sp[i]]])
				pars[gqnames[sp[i]], 5] = as.numeric(fixed.pars[gqnames[sp[i]]])
				pars[gqnames[sp[i]], 6] = as.numeric(fixed.pars[gqnames[sp[i]]])
			}
		}
	}

	# SimLev: delta (apARCH) entfaellt
	if(modelinc[9] > 0){
		gqnames = paste("beta",1:modelinc[9],sep="")
		pxd = which(is.na(pars[idx["beta", 1]:idx["beta", 2], 5]))
		if(length(pxd)>0) pars[(idx["beta", 1]:idx["beta", 2])[pxd], 5] = 0
		pxd = which(is.na(pars[idx["beta", 1]:idx["beta", 2], 6]))
		if(length(pxd)>0) pars[(idx["beta", 1]:idx["beta", 2])[pxd], 6] =  1-.rugarch_TinY
		pars[idx["beta", 1]:idx["beta", 2], 1] = rep(0.9/modelinc[9], modelinc[9])
		sp = na.omit(match(start.names, gqnames))
		if(length(sp)>0){
			for(i in 1:length(sp)) pars[gqnames[sp[i]], 1] = as.numeric(start.pars[gqnames[sp[i]]])
		}
		sp = na.omit(match(fixed.names, gqnames))
		if(length(sp)>0){
			for(i in 1:length(sp)){
				pars[gqnames[sp[i]], 1] = as.numeric(fixed.pars[gqnames[sp[i]]])
				pars[gqnames[sp[i]], 5] = as.numeric(fixed.pars[gqnames[sp[i]]])
				pars[gqnames[sp[i]], 6] = as.numeric(fixed.pars[gqnames[sp[i]]])
			}
		}
	}
	# SimLev: vxreg entfaellt (externe Regressoren nicht uebernommen)
	pars = .rugarch_distributionstart(pars, model, start.pars, fixed.pars)

	return( pars )
}

# rugarch-startpars.R: .distributionstart
.rugarch_distributionstart = function(pars, model, start.pars, fixed.pars){
	modelinc = model$modelinc
	idx = model$pidx
	fixed.names = names(fixed.pars)
	start.names = names(start.pars)
	dbounds = .rugarch_DistributionBounds(distribution = model$modeldesc$distribution)
	if(modelinc[16]>0){
		if(is.na(pars[idx["skew", 1]:idx["skew", 2], 5])) pars[idx["skew", 1]:idx["skew", 2], 5] = dbounds$skew.LB
		if(is.na(pars[idx["skew", 1]:idx["skew", 2], 6])) pars[idx["skew", 1]:idx["skew", 2], 6] = dbounds$skew.UB
		if(is.null(start.pars$skew)) pars[idx["skew", 1]:idx["skew", 2], 1] = dbounds$skew else pars[idx["skew", 1]:idx["skew", 2], 1] = start.pars$skew[1]
		if(any(substr(fixed.names, 1, 4) == "skew")){
			pars[idx["skew", 1]:idx["skew", 2], 1] = as.numeric(fixed.pars$skew)
			pars[idx["skew", 1]:idx["skew", 2], 5] = as.numeric(fixed.pars$skew)
			pars[idx["skew", 1]:idx["skew", 2], 6] = as.numeric(fixed.pars$skew)
		}
	}
	if(modelinc[17]>0){
		if(is.na(pars[idx["shape", 1]:idx["shape", 2], 5])) pars[idx["shape", 1]:idx["shape", 2], 5] = dbounds$shape.LB
		if(is.na(pars[idx["shape", 1]:idx["shape", 2], 6])) pars[idx["shape", 1]:idx["shape", 2], 6] = dbounds$shape.UB
		if(is.null(start.pars$shape)) pars[idx["shape", 1]:idx["shape", 2], 1] = dbounds$shape else pars[idx["shape", 1]:idx["shape", 2], 1] = start.pars$shape[1]
		if(any(substr(fixed.names, 1, 5) == "shape")){
			pars[idx["shape", 1]:idx["shape", 2], 1] = as.numeric(fixed.pars$shape)
			pars[idx["shape", 1]:idx["shape", 2], 5] = as.numeric(fixed.pars$shape)
			pars[idx["shape", 1]:idx["shape", 2], 6] = as.numeric(fixed.pars$shape)
		}
	}
	if(modelinc[18]>0){
		if(is.na(pars[idx["ghlambda", 1]:idx["ghlambda", 2], 5])) pars[idx["ghlambda", 1]:idx["ghlambda", 2], 5] = dbounds$ghlambda.LB
		if(is.na(pars[idx["ghlambda", 1]:idx["ghlambda", 2], 6])) pars[idx["ghlambda", 1]:idx["ghlambda", 2], 6] = dbounds$ghlambda.UB
		if(is.null(start.pars$ghlambda)) pars[idx["ghlambda", 1]:idx["ghlambda", 2], 1] = dbounds$ghlambda else pars[idx["ghlambda", 1]:idx["ghlambda", 2], 1] = start.pars$ghlambda[1]
		if(any(substr(fixed.names, 1, 8) == "ghlambda")){
			pars[idx["ghlambda", 1]:idx["ghlambda", 2], 1] = as.numeric(fixed.pars$ghlambda)
			pars[idx["ghlambda", 1]:idx["ghlambda", 2], 5] = as.numeric(fixed.pars$ghlambda)
			pars[idx["ghlambda", 1]:idx["ghlambda", 2], 6] = as.numeric(fixed.pars$ghlambda)
		}
	}
	return(pars)
}

# rugarch-cwrappers.R: .arfimaxfilter
.rugarch_arfimaxfilter = function(model, pars, idx, mexdata, h, data, N)
{
	#if(model[1] == 0) pars[1,1] = 0
	m = as.integer(N[1])
	T = as.integer(N[2])
	if(length(h) <= 1) {
		h = double(length = T)
	} else{
		h = as.double(h)
	}
	data = as.double(data)
	# SimLev: ohne zoo::coredata; externe Regressoren nicht uebernommen
	{
		mexdata = as.double(0)
		imx = as.double(0)
	}
	res = double(length = T)
	# this routine is used for the mean residuals to initiate the recursion
	# so we ignore arfima before
	zrf = double(length = T)
	constm = double(length = T)
	condm = double(length = T)
	ans = list()
	# SimLev: ARMA-Filter (arfimaxfilterC) nicht uebernommen
	{
		ans = list()
		ans$res = data -  pars[idx[1,1]] - imx - pars[idx[5,1]]*(h^model[5])
		ans$zrf = zrf
		# SimLev: arfima (.fracdiff) entfaellt
		if(any(is.na(ans$res))) res[which(is.na(ans$res))]=0
		return(ans)
	}
}

# rugarch-solvers.R: .garchsolver
.rugarch_garchsolver = function(solver, pars, fun, Ifn, ILB, IUB, gr, hessian, parscale,
		control, LB, UB, ux=NULL, ci=NULL, mu=NULL, arglist)
{
	# SimLev: lbfgs (optim) und nloptr nicht uebernommen
	if(any(solver == c("lbfgs", "nloptr"))) stop(paste0("rugarch-Uebernahme: ugarchfit mit solver = \"", solver, "\" nicht uebernommen"), call. = FALSE)
	gocontrol = control
	control = .rugarch_getcontrol(solver, control)
	retval = switch(solver,
			hybrid = .rugarch_hybridsolver(pars, fun, Ifn, ILB, IUB, gr, hessian, parscale, gocontrol, LB, UB, arglist),
			nlminb = .rugarch_nlminbsolver(pars, fun, gr, hessian, parscale, control, LB, UB, arglist),
			solnp = .rugarch_solnpsolver(pars, fun, Ifn, ILB, IUB, control, LB, UB, arglist),
			gosolnp = .rugarch_gosolnpsolver(pars, fun, Ifn, ILB, IUB, gocontrol, LB, UB, arglist))
	return(retval)
}

# rugarch-solvers.R: .nlminbsolver
.rugarch_nlminbsolver = function(pars, fun, gr, hessian, parscale, control, LB, UB, arglist){
	ans = try(nlminb(start = pars, objective = fun, gradient = gr, hessian = hessian,
					arglist = arglist, scale = 1/parscale, control = control,
					lower = LB, upper = UB), silent = TRUE)
	if(inherits(ans, "try-error")){
		sol = list()
		sol$convergence = 1
		sol$message = ans
		sol$par = rep(NA, length(pars))
		names(sol$par) = names(pars)
	} else{
		sol = ans
	}
	hess = NULL
	return(list(sol = sol,hess = hess))
}

# rugarch-solvers.R: .solnpsolver
.rugarch_solnpsolver = function(pars, fun, Ifn, ILB, IUB, control, LB, UB, arglist){
	ans = try(.rsolnp_solnp(pars, fun = fun, eqfun = NULL, eqB = NULL, ineqfun = Ifn, ineqLB = ILB,
					ineqUB = IUB, LB = LB, UB = UB, control = control, arglist), silent = TRUE)
	if(inherits(ans,"try-error")){
		sol = list()
		sol$convergence = 1
		sol$message = ans
		sol$par = rep(NA, length(pars))
		names(sol$par) = names(pars)
		warning("\nrugarch-->warning: no convergence...\n")
	} else{
		sol = ans
	}
	hess = NULL
	return(list(sol = sol, hess = hess))
}

# rugarch-solvers.R: .hybridsolver
.rugarch_hybridsolver = function(pars, fun, Ifn, ILB, IUB, gr, hessian, parscale, control, LB, UB, arglist){
	xcontrol = .rugarch_getcontrol("solnp", control)
	ans = .rugarch_solnpsolver(pars, fun, Ifn, ILB, IUB, xcontrol, LB, UB, arglist)
	if(ans$sol$convergence >= 1)
	{
		xcontrol = .rugarch_getcontrol("nlminb", control)
		if(xcontrol$trace) cat("\nTrying nlminb solver...\n")
		ans = .rugarch_nlminbsolver(pars, fun, gr, hessian, parscale, control=xcontrol, LB, UB, arglist = arglist)
		if(ans$sol$convergence>=1){
			if(xcontrol$trace) cat("\nTrying gosolnp solver...\n")
			ans = .rugarch_gosolnpsolver(pars, fun, Ifn, ILB, IUB, control, LB, UB, arglist)
			if(ans$sol$convergence>=1){
				# xcontrol = .getcontrol("nloptr", control)
				if(xcontrol$trace) cat("\nTrying gosolnp solver...\n")
				ans = .rugarch_gosolnpsolver(pars, fun, Ifn, ILB, IUB, control, LB, UB, arglist)
			}
		}
	}
	return(ans)
}

# rugarch-solvers.R: .gosolnpsolver
.rugarch_gosolnpsolver = function(pars, fun, Ifn, ILB, IUB, gocontrol, LB, UB, arglist){
	control = .rugarch_solnpctrl(gocontrol)
	gocontrol = .rugarch_gosolnpctrl(gocontrol)
	n.restarts = gocontrol$n.restarts
	doparallel = gocontrol$parallel
	pkg = gocontrol$pkg
	cores = gocontrol$cores
	rseed = gocontrol$rseed
	n.sim = gocontrol$n.sim
	op <- options()
	options(warn = 0)
	# use the truncated normal distribution
	distr.opt = vector(mode = "list", length = length(pars))
	for(i in 1:length(pars)){
		distr.opt[[i]]$mean = pars[i]
		distr.opt[[i]]$sd = ifelse(pars[i]==0, 0.1, sqrt(pars[i]^2)*2)
	}
	if(doparallel){
		# SimLev: parallele Auswertung (makePSOCKcluster) nicht uebernommen
		stop("rugarch-Uebernahme: gosolnp mit parallel = TRUE nicht uebernommen", call. = FALSE)
	} else{
		cl = NULL
	}
	ans = try(.rsolnp_gosolnp(pars = pars, fixed = NULL, fun = fun, eqfun = NULL,
			eqB = NULL, ineqfun = Ifn, ineqLB = ILB, ineqUB = IUB, LB = LB,
			UB = UB, control = control, distr = rep(2, length(LB)),
			distr.opt = distr.opt, n.restarts = n.restarts, n.sim = n.sim,
			cluster = cl, rseed = rseed, arglist),
	silent = TRUE)
	# SimLev: stopCluster entfaellt (keine parallele Auswertung)
	# return to normal mode
	arglist$pmode = 0
	if(inherits(ans,"try-error")){
		sol = list()
		sol$convergence = 1
		sol$message = ans
		sol$par = rep(NA, length(pars))
		names(sol$par) = names(pars)
	} else{
		sol = ans
	}
	hess = NULL
	options(op)
	return(list(sol = sol, hess = hess))
}

# rugarch-solvers.R: .getcontrol
.rugarch_getcontrol = function(solver, control)
{
	ans = switch(solver,
		nlminb = .rugarch_nlminbctrl(control),
		solnp = .rugarch_solnpctrl(control),
		gosolnp = .rugarch_gosolnpctrl(control))
	return(ans)
}

# rugarch-solvers.R: .nlminbctrl
.rugarch_nlminbctrl = function(control)
{
	if(is.null(control$eval.max)) control$eval.max = 2000
	if(is.null(control$trace)) control$trace = 0
	if(is.null(control$iter.max)) control$iter.max = 1500
	if(is.null(control$abs.tol)) control$abs.tol = 1e-20
	if(is.null(control$rel.tol)) control$rel.tol = 1e-10
	if(is.null(control$x.tol)) control$x.tol = 1.5e-8
	if(is.null(control$step.min)) control$step.min = 2.2e-14
	return(control)
}

# rugarch-solvers.R: .solnpctrl
.rugarch_solnpctrl = function(control){
	# parameters check is now case independent
	ans = list()
	params = unlist(control)
	if(is.null(params)) {
		ans$rho = 1
		ans$outer.iter = 50
		ans$inner.iter = 1800
		ans$delta = 1.0e-8
		ans$tol = 1.0e-8
		ans$trace = 0
	} else{
		npar = tolower(names(unlist(control)))
		names(params) = npar
		if(any(substr(npar, 1, 3) == "rho")) ans$rho = as.numeric(params["rho"]) else ans$rho = 1
		if(any(substr(npar, 1, 10) == "outer.iter")) ans$outer.iter = as.numeric(params["outer.iter"]) else ans$outer.iter = 50
		if(any(substr(npar, 1, 10) == "inner.iter")) ans$inner.iter = as.numeric(params["inner.iter"]) else ans$inner.iter = 1000
		if(any(substr(npar, 1, 5) == "delta")) ans$delta = as.numeric(params["delta"]) else ans$delta = 1.0e-8
		if(any(substr(npar, 1, 3) == "tol")) ans$tol = as.numeric(params["tol"]) else ans$tol = 1.0e-8
		if(any(substr(npar, 1, 5) == "trace")) ans$trace = as.numeric(params["trace"]) else ans$trace = 0
	}
	return(ans)
}

# rugarch-solvers.R: .gosolnpctrl
.rugarch_gosolnpctrl = function(control){
	# parameters check is now case independent
	ans = list()
	params = unlist(control)
	if(is.null(params)) {
		ans$parallel = FALSE
		ans$pkg = "snowfall"
		ans$cores= 2
		ans$n.restarts = 1
		ans$rseed
		ans$n.sim = 500
		ans$trace = 0
	} else{
		npar = tolower(names(unlist(control)))
		names(params) = npar
		ans$parallel.control = list()
		if(any(substr(npar, 1, 8) == "parallel")) ans$parallel = as.logical(params["parallel"]) else ans$parallel = FALSE
		if(any(substr(npar, 1, 3) == "pkg")) ans$pkg = unname(params["pkg"]) else ans$pkg = "snowfall"
		if(any(substr(npar, 1, 5) == "cores")) ans$cores = unname(params["cores"]) else ans$cores = 2
		if(any(substr(npar, 1, 10) == "n.restarts")) ans$n.restarts = as.numeric(params["n.restarts"]) else ans$n.restarts = 1
		if(any(substr(npar, 1, 5) == "rseed")) ans$rseed = as.numeric(params["rseed"]) else ans$rseed = NULL
		if(any(substr(npar, 1, 5) == "n.sim")) ans$n.sim = as.numeric(params["n.sim"]) else ans$n.sim = 500
		if(any(substr(npar, 1, 5) == "trace")) ans$trace = as.numeric(params["trace"]) else ans$trace = 0
	}
	return(ans)
}

# rugarch-solvers.R: .garchconbounds
.rugarch_garchconbounds = function(){
	return(list(LB = .rugarch_eps,UB = 0.999))
}

# rugarch-solvers.R: .sgarchcon
.rugarch_sgarchcon = function(pars, arglist){
	ipars = arglist$ipars
	estidx = arglist$estidx
	idx = arglist$model$pidx
	ipars[estidx, 1] = pars
	distribution = arglist$model$modeldesc$distribution
	con = .rugarch_persistsgarch1(pars = ipars[,1], idx, distribution = distribution)
	return(con)
}

# rugarch-solvers.R: .gjrgarchcon
.rugarch_gjrgarchcon = function(pars, arglist){
	ipars = arglist$ipars
	estidx = arglist$estidx
	idx = arglist$model$pidx
	ipars[estidx, 1] = pars
	distribution = arglist$model$modeldesc$distribution
	con = .rugarch_persistgjrgarch1(pars = ipars[,1], idx = idx, distribution = distribution)
	if(is.na(con)) con = 1
	return(con)
}

# rugarch-methods.R: .persistsgarch1
.rugarch_persistsgarch1 = function(pars, idx, distribution = "norm"){
	ps = sum(pars[idx["alpha",1]:idx["alpha",2]]) + sum(pars[idx["beta",1]:idx["beta",2]])
	return(ps)
}

# rugarch-methods.R: .persistgjrgarch1
.rugarch_persistgjrgarch1 = function(pars, idx, distribution = "norm"){
	alpha = pars[idx["alpha",1]:idx["alpha",2]]
	beta  = pars[idx["beta",1]:idx["beta",2]]
	gamma = pars[idx["gamma",1]:idx["gamma",2]]
	skew = pars[idx["skew",1]:idx["skew",2]]
	shape = pars[idx["shape",1]:idx["shape",2]]
	ghlambda = pars[idx["ghlambda",1]:idx["ghlambda",2]]

	ps = sum(beta)+ sum(alpha)+sum(apply(as.data.frame(gamma),1,FUN=function(x)
						x*.rugarch_pneg(ghlambda, shape, skew, distribution)))
	return(ps)
}

# rugarch-kappa.R: pneg
.rugarch_pneg<-function(ghlambda, shape, skew, cond.density,...)
{
	kappa = try(expr=integrate(.rugarch_pnegfunE, lower = -Inf, upper = 0, ghlambda, shape, skew, cond.density,...)[[1]],
			silent=TRUE)
	if(inherits(kappa, "try-error")){
		kappa<-NA}
	else{kappa<-integrate(.rugarch_pnegfunE, lower = -Inf, upper = 0, ghlambda, shape, skew, cond.density,...)[[1]]}
	
	kappa
}

# rugarch-kappa.R: .pnegfunE
.rugarch_pnegfunE<-function(x, ghlambda, shape, skew, cond.density,...)
{   # A function implemented by Alexios Galanos
	# Compute Expectation Value
	cond.density = cond.density[1]
	if (cond.density == "norm"){
		fun = dnorm(x)
	}
	else{
		# SimLev: die Dichten der uebrigen Verteilungen nicht uebernommen
		stop(paste0("rugarch-Uebernahme: pneg mit cond.density = \"", cond.density, "\" nicht uebernommen"), call. = FALSE)
	}
	# Return Value:
	fun
}

# rugarch-helperfn.R: .makefitmodel
.rugarch_makefitmodel = function(garchmodel, f, T, m, timer, convergence, message, hess, arglist,
		numderiv.control = list(grad.eps=1e-4, grad.d=0.0001, grad.zero.tol=sqrt(.Machine$double.eps/7e-7),
				hess.eps=1e-4, hess.d=0.1, hess.zero.tol=sqrt(.Machine$double.eps/7e-7), r=4, v=2))
{
	# Turn Stationarity Off for numerical derivative calculation
	fit.control = arglist$fit.control
	fit.control$stationarity = arglist$fit.control$stationarity = 0
	data = arglist$data
	ipars = arglist$ipars
	model = arglist$model
	estidx = arglist$estidx
	idx = model$pidx
	arglist$returnType = "llh"
	fit = vector(mode = "list")
	if(is.null(hess)){
		# SimLev: statt numDeriv::hessian(func = f, x = ..., method = "Richardson", method.args = list(...))
		# die eigene Richardson-Hesse-Matrix (R/richardson.R), gleiche Einstellungen
		fit$hessian = .sl_richardson_hessian(func = f, x = ipars[estidx, 1], eps = numderiv.control$hess.eps,
						d = numderiv.control$hess.d, zero.tol = numderiv.control$hess.zero.tol, r = numderiv.control$r,
						v = numderiv.control$v, arglist = arglist)
		# fit$hessian = .hessian2sided(f, ipars[estidx, 1], data = data, returnType = "llh", garchenv = garchenv)
		# fit$hessian = .hessian2sidedcpp(f, ipars[estidx, 1], arglist = arglist)
		E = eigen(fit$hessian)$values
		# approx. number of decimal places lost to roundoff/numerical estimation error
		if(any(E<0)){
			# This should silence the warnings
			condH = NaN
		} else{
			condH = log10(max(E)/min(E))
		}
	} else{
		fit$hessian = hess
		E = eigen(fit$hessian)$values
		if(any(E<0)){
			# This should silence the warnings
			condH = NaN
		} else{
			condH = log10(max(E)/min(E))
		}
	}
	fit$cvar = try(solve(fit$hessian), silent = TRUE)
	# (might also fail in which case user will see an error about the inversion failure)
	if(inherits(fit$cvar, "try-error")){
		zz = try(solve(.rugarch_hessian2sided(f, ipars[estidx, 1], arglist = arglist)), silent=TRUE)
		if(inherits(zz, "try-error")) {
			fit$cvar = NULL
			warning("\nrugarch-->warning: failed to invert hessian\n")
		} else{
			fit$cvar = zz
		}
	}
	#fit$grad = grad(func = f, x = ipars[estidx, 1], method="Richardson", method.args=list(eps=1e-4, d=0.001,
	#				zero.tol=sqrt(.Machine$double.eps/7e-7), r=6, v=2, show.details=FALSE), data = data, returnType = "llh", garchenv = garchenv)
	# this is the sum of the scores: apply(fit$scores, 2, "sum")
	arglist$returnType = "all"
	temp = f(pars = ipars[estidx, 1],	arglist = arglist)
	if(garchmodel == "fGARCH" || garchmodel == "apARCH"){
		# apARCH and fGARCH are calculated in sigma rather than sigma^d (since d is a variable
		# to be calculated, unlike sGARCH where it is fixed at 2)
		fit$var = temp$h^2
		fit$sigma = temp$h
	} else{
		fit$var = abs(temp$h)
		fit$sigma = sqrt(abs(temp$h))
	}
	if(garchmodel == "csGARCH") fit$q = temp$q
	if(garchmodel == "realGARCH"){
		fit$u = temp$u
		fit$tau = temp$tau
		fit$partial.log.likelihoods = temp$LHT1P
	}
	if(garchmodel == "fiGARCH"){
	  fit$eps = temp$eps
	  fit$ebar = temp$ebar
	  fit$be = temp$be
	}
	fit$condH = condH
	fit$z = temp$z
	fit$LLH = -temp$llh
	fit$log.likelihoods = temp$LHT
	fit$residuals = temp$epsx
	if(sum(ipars[,2])>0){
		pall = ipars[estidx | as.logical(ipars[,2]==1), 1]
		fixed = match(rownames(ipars[ipars[,2]==1, , drop = FALSE]), names(pall))
		fixedn = length(fixed)
		fNA = rep(NA, fixedn)
		nfixedn = length(pall) - fixedn
		fit$coef = pall
		if(is.null(fit$cvar)){
			fit$se.coef = rep(NA, nfixedn)
			fit$tval = rep(NA, nfixedn)
			# change here
			fit$matcoef = matrix(NA, ncol = 4, nrow = length(pall))
			fit$matcoef[-fixed,] = cbind(ipars[estidx, 1], fit$se.coef,
					fit$tval, rep(NA, nfixedn))
			fit$matcoef[fixed,] = cbind(fit$coef[fixed], fNA, fNA, fNA)
			fit$robust.se.coef = rep(NA, nfixedn)
			fit$robust.tval = rep(NA, nfixedn)
			fit$robust.matcoef = matrix(NA, ncol = 4, nrow = length(fit$coef))
			fit$robust.matcoef[-fixed,] = cbind(fit$coef[-fixed], fit$robust.se.coef,
					fit$robust.tval, rep(NA, nfixedn))
			fit$robust.matcoef[fixed,] = cbind(fit$coef[fixed], fNA, fNA, fNA)
			fit$hessian.message = "failed to invert hessian"
		} else{
			arglist$returnType = "LHT"
			tmp = .rugarch_robustvcv(fun = f, pars = ipars[estidx, 1], nlag = 0, hess = fit$hessian, n = T, arglist = arglist)
			fit$robust.cvar = tmp$vcv
			fit$A = tmp$A
			fit$B = tmp$B
			# SimLev: statt numDeriv::jacobian(..., method = "Richardson", method.args = list(...))
			# die eigene Richardson-Jacobi-Matrix (R/richardson.R), gleiche Einstellungen
			fit$scores = .sl_richardson_jacobian(func = f, x = ipars[estidx, 1], eps = numderiv.control$grad.eps,
							d = numderiv.control$grad.d, zero.tol = numderiv.control$grad.zero.tol, r = numderiv.control$r,
							v = numderiv.control$v, arglist = arglist)
			colnames(fit$scores) = names(ipars[estidx, 1])
			fit$se.coef = sqrt(diag(abs(fit$cvar)))
			fit$tval = fit$coef[-fixed]/fit$se.coef
			# change here
			fit$matcoef = matrix(NA, ncol = 4, nrow = length(fit$coef))
			fit$matcoef[-fixed,] = cbind(fit$coef[-fixed], fit$se.coef,
					fit$tval, 2*(1-pnorm(abs(fit$tval))))
			fit$matcoef[fixed,] = cbind(fit$coef[fixed], fNA,fNA, fNA)
			fit$robust.se.coef = sqrt(diag(fit$robust.cvar))
			fit$robust.tval = fit$coef[-fixed]/fit$robust.se.coef
			# change here
			fit$robust.matcoef = matrix(NA, ncol = 4, nrow = length(fit$coef))
			fit$robust.matcoef[-fixed,] = cbind(fit$coef[-fixed], fit$robust.se.coef,
					fit$robust.tval, 2*(1-pnorm(abs(fit$robust.tval))))
			fit$robust.matcoef[fixed,] = cbind(fit$coef[fixed], fNA, fNA, fNA)
			fit$hessian.message = NULL
		}
		if(model$modelinc[7] == 0){
			vtomega = ipars[idx["omega", 1], 1]
			names(vtomega) = "omega"
			fit$coef = c(fit$coef, vtomega)
			names(fit$coef)[length(fit$coef)] = "omega"
			fit$se.coef = c(fit$se.coef, NA)
			fit$tval = c(fit$tval, NA)
			# change here
			fit$matcoef = rbind(fit$matcoef, c(vtomega, NA, NA, NA))
			fit$robust.se.coef = c(fit$robust.se.coef, NA)
			fit$robust.tval = c(fit$robust.tval, NA)
			# change here
			fit$robust.matcoef = rbind(fit$robust.matcoef, c(vtomega, NA, NA, NA))
		}
	} else{
		fit$coef = ipars[estidx, 1]
		if(is.null(fit$cvar)){
			fit$se.coef = rep(NA,length(fit$coef))
			fit$tval = rep(NA,length(fit$coef))
			# change here
			fit$matcoef = cbind(fit$coef, fit$se.coef,
					fit$tval, rep(NA,length(fit$coef)))
			fit$robust.se.coef = rep(NA,length(fit$coef))
			fit$robust.tval = rep(NA,length(fit$coef))
			# change here
			fit$robust.matcoef = cbind(fit$coef, fit$robust.se.coef,fit$robust.tval,
					rep(NA,length(fit$coef)))
			fit$hessian.message = "failed to invert hessian"
		} else{
			nlag=min(floor(1.2*(T)^(1/3)),(T))
			arglist$returnType = "LHT"
			tmp = .rugarch_robustvcv(fun = f, pars = ipars[estidx,1], nlag = nlag, hess = fit$hessian, n = T, arglist = arglist)
			fit$robust.cvar = tmp$vcv
			fit$A = tmp$A
			fit$B = tmp$B
			# SimLev: statt numDeriv::jacobian(..., method = "Richardson", method.args = list(...))
			# die eigene Richardson-Jacobi-Matrix (R/richardson.R), gleiche Einstellungen
			fit$scores = .sl_richardson_jacobian(func = f, x = ipars[estidx, 1], eps = numderiv.control$grad.eps,
							d = numderiv.control$grad.d, zero.tol = numderiv.control$grad.zero.tol, r = numderiv.control$r,
							v = numderiv.control$v, arglist = arglist)
			colnames(fit$scores) = names(ipars[estidx, 1])
			fit$se.coef = sqrt(diag(abs(fit$cvar)))
			fit$tval = fit$coef/fit$se.coef
			# change here
			fit$matcoef = cbind(fit$coef, fit$se.coef,
					fit$tval, 2*(1-pnorm(abs(fit$tval))))
			fit$robust.se.coef = sqrt(diag(fit$robust.cvar))
			fit$robust.tval = fit$coef/fit$robust.se.coef
			# change here
			fit$robust.matcoef = cbind(fit$coef, fit$robust.se.coef,fit$robust.tval,
					2*(1-pnorm(abs(fit$robust.tval))))
			fit$hessian.message = NULL
		}
		# variance targeting case
		if(model$modelinc[7] == 0){
			vtomega = ipars[idx["omega", 1], 1]
			names(vtomega) = "omega"
			fit$coef = c(fit$coef, vtomega)
			names(fit$coef)[length(fit$coef)] = "omega"
			fit$se.coef = c(fit$se.coef, NA)
			fit$tval = c(fit$tval, NA)
			# change here
			fit$matcoef = rbind(fit$matcoef, c(vtomega, NA, NA, NA))

			fit$robust.se.coef = c(fit$robust.se.coef, NA)
			fit$robust.tval = c(fit$robust.tval, NA)
			# change here
			fit$robust.matcoef = rbind(fit$robust.matcoef, c(vtomega, NA, NA, NA))
		}
	}
	# return the correct indicators to the ipars (changed in the case of fixed pars and fixed.se = TRUE)
	ipars[,2:4] = model$pars[,2:4]
	dimnames(fit$matcoef) = list(names(fit$coef), c(" Estimate",
					" Std. Error", " t value", "Pr(>|t|)"))
	dimnames(fit$robust.matcoef) = list(names(fit$coef), c(" Estimate",
					" Std. Error", " t value", "Pr(>|t|)"))
	fit$fitted.values = data-fit$residuals
	fit$convergence = convergence
	fit$message = message
	fit$kappa = temp$kappa
	fit$persistence = temp$persistence
	fit$timer = timer
	fit$ipars = ipars
	return(fit)
}

# rugarch-numderiv.R: .hessian2sided
.rugarch_hessian2sided = function(f, x, ...)
{
	n = length(x)
	fx = f(x, ...)
	eps = .Machine$double.eps

	# Compute the stepsize (h)
	# h = eps^(1/3)*apply(as.data.frame(x), 1,FUN = function(z) max(abs(z), 1e-4))
	h = apply(as.data.frame(x), 1,FUN = function(z) max(abs(z*eps^(1/3)), 1e-9))
	xh = x+h
	h = xh-x
	if(length(h) == 1) ee = matrix(h, ncol = 1, nrow = 1) else ee = as.matrix(diag(h))

	# Compute forward and backward steps
	gp = vector(mode = "numeric", length = n)
	gp = apply(ee, 2, FUN = function(z) f(x+z, ...))
	gm = vector(mode="numeric",length=n)
	gm = apply(ee, 2, FUN = function(z) f(x-z, ...))
	H = h%*%t(h)
	Hm = H
	Hp = H
	# Compute "double" forward and backward steps
	for(i in 1:n){
		for(j in  i:n){
			Hp[i,j] = f(x+ee[,i]+ee[,j], ...)
			Hp[j,i] = Hp[i,j]
			Hm[i,j] = f(x-ee[,i]-ee[,j], ...)
			Hm[j,i] = Hm[i,j]
		}
	}
	#Compute the hessian
	for(i in 1:n){
		for(j in  i:n){
			H[i,j] = ( (Hp[i,j]-gp[i]-gp[j]+fx+fx-gm[i]-gm[j]+Hm[i,j]) /H[i,j] )/2
			H[j,i] = H[i,j]
		}
	}
	return(H)
}

# rugarch-numderiv.R: neweywestcv
.rugarch_neweywestcv = function(data, nlag = NULL, center = TRUE)
{
	# Long-run covariance estimation using Newey-West (Bartlett) weights
	#  if nlag empty=NULL NLAG=min(floor(1.2*T^(1/3)),T)
	N = dim(as.matrix(data))[1]
	if(is.null(nlag)) nlag=min(floor(1.2*N^(1/3)),N)
	if(center) data = apply(data, 2, FUN = function(x) scale(x, center = TRUE, scale = FALSE))
	# weights
	bw = (nlag+1-(seq(0,nlag,by=1)))/(nlag+1)
	cv = 1/N * t(data)%*%data
	for(i in 1:nlag){
		gmi = 1/N * (t(data[(i+1):N,])%*%data[1:(N-i),])
		gpp = gmi + t(gmi)
		cv = cv + bw[i+1]*gpp
	}
	return(cv)
}

# rugarch-numderiv.R: robustvcv
.rugarch_robustvcv = function(fun, pars, nlag = 0, hess, n, ...)
{
	k = length(pars)
	#h = apply(as.data.frame(pars), 1, FUN = function(x) max(abs(x*eps^(1/3)), 1e-7))
	h = apply(as.data.frame(pars), 1,FUN = function(z) max(abs(z*.rugarch_eps^(1/3)), 1e-9))
	hplus =  pars+h
	hminus = pars-h
	hparsminus = hparsplus = matrix(pars, ncol = k, nrow = k, byrow = T)
	diag(hparsplus) = hplus
	diag(hparsminus) = hminus

	likelihoodsminus = likelihoodsplus = .rugarch_zeros(n, k)
	likelihoodsplus =  apply(hparsplus, 1,  FUN = function(x) fun(x, ...))
	likelihoodsminus = apply(hparsminus, 1, FUN = function(x) fun(x, ...))

	scores = .rugarch_zeros(n,k)
	likpm = likelihoodsplus-likelihoodsminus
	scores = likpm/(2*.rugarch_repmat(t(h), n, 1))
	A = hess/n
	hess = A
	Ainv = try( solve(A), silent = TRUE )
	if( inherits(Ainv, "try-error")){
		info = 1
		vcv = NA
	} else{
		if(nlag>0){
			B = .rugarch_neweywestcv(scores, nlag)
			vcv = (Ainv%*%B%*%Ainv)/n
		} else{
			B = cov(scores)
			vcv = (Ainv%*%B%*%Ainv)/n
		}
		info = 0
	}
	return(list(vcv = vcv, B = B, A = A, info = info))
}

# rugarch-helperfn.R: repmat
.rugarch_repmat = function(a, n, m)
{
	kronecker(matrix(1, n, m), a)
}

# rugarch-helperfn.R: zeros
.rugarch_zeros = function(n = 1, m = 1)
{
	if(missing(m)) m = n
	sol = matrix(0, nrow = n, ncol = m)
	return(sol)
}
