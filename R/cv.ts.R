#Fix progress bar when using parallel backend?
#Add Garch, bats, tbats, fourrier, wavelets, and farima functions
#Fix RMSE calculation over all horizons
#Create tuning grids for forecast functions
#Add BoxCox.lambda method to tsControl

#best.ts: Return an object (for the best tune) with:
#	1. Data frame of parameters+error metric at selected horizon
#	2. Cross validated stats at each horizon+overall average for final model
#		2a. Additional row "best", where best model at each step (and horizon)
#			is used for the next
#	3. Data frame of best parameters at each point, selected by error metric at selected horizon
#	4. Best parameters for final model
#	5. Final model prediction data frame
#	6. Each step best model prediction data frame
#	7. Actuals data frame

#' Test if an object exists
#' @export
testObject <- function(object){
  exists(as.character(substitute(object)))
}

#' Default summary function
#' @export
tsSummary <- function(P,A) {
data.frame((as.data.frame(accuracy(P,A))))
}

#' Default Cross-validation control
#' @export
tseriesControl <- function(stepSize=1, maxHorizon=1, minObs=12, fixedWindow=TRUE,
                              summaryFunc=tsSummary, preProcess=FALSE, ppMethod='guerrero'){
  list(stepSize=stepSize,
       maxHorizon=maxHorizon,
       minObs=minObs,
       fixedWindow=fixedWindow,
       summaryFunc=summaryFunc,
       preProcess=preProcess,
       ppMethod=ppMethod)
}

#' Function to cross-validate a time series.
#' @export
cv.ts <- function(x, FUN, tsControl=tseriesControl(), xreg=NULL, progress=TRUE, packages=NULL, ...) {

	#Load required packages
	stopifnot(is.ts(x))
	stopifnot(is.data.frame(xreg) | is.matrix(xreg) | is.null(xreg))

	#Load parameters from the tsControl list
	stepSize <- tsControl$stepSize
	maxHorizon <- tsControl$maxHorizon
	minObs <- tsControl$minObs
	fixedWindow <- tsControl$fixedWindow
	summaryFunc <- tsControl$summaryFunc
	preProcess <- tsControl$preProcess
	ppMethod <- tsControl$ppMethod

	#Make sure xreg object is long enough for last set of forecasts
	if (! is.null(xreg)) {
		xreg <- as.matrix(xreg)

		if (nrow(xreg)<length(x)+maxHorizon) {
			warning('xreg object too short to forecast beyond the length of the time series.
					Appending NA values to xreg')
			nRows <- (length(x)+maxHorizon)-nrow(xreg)
			nCols <- dim(xreg)[2]
			addRows <- matrix(rep(NA,nCols*nRows),nrow=nRows, ncol=nCols)
			colnames(addRows) <- colnames(xreg)
			xreg <- rbind(xreg,addRows)
		}

	}

	#Define additional parameters
	freq <- frequency(x)
	n <- length(x)
	st <- tsp(x)[1]+(minObs-2)/freq

	#Create a matrix of actual values.
	#X is the point in time, Y is the forecast horizon
	#http://stackoverflow.com/questions/8140577/creating-a-matrix-of-future-values-for-a-time-series
	formatActuals <- function(x,maxHorizon) {
		actuals <- outer(seq_along(x), seq_len(maxHorizon), FUN="+")
		actuals <- apply(actuals,2,function(a) x[a])
		actuals
	}

	actuals <- formatActuals(x,maxHorizon)
	actuals <- actuals[minObs:(length(x)-1),,drop=FALSE]

	#Create a list of training windows
	#Each entry of this list will be the same length, if fixed=TRUE
	steps <- seq(1,(n-minObs),by=stepSize)

	#Set progressbar
	combine <- rbind
	if (progress) {
	  f <- function(){
	    pb <- txtProgressBar(1,length(steps)-1,style=3)
	    count <- 0
	    function(...) {
	      count <<- count + length(list(...)) - 1
	      setTxtProgressBar(pb,count)
	      Sys.sleep(0.01)
	      flush.console()
	      rbind(...)
	    }
	  }
	  combine <- f()
	}

	#At each point in time, calculate 'maxHorizon' forecasts ahead
	forecasts <- foreach(i=steps, .combine=combine, .multicombine=FALSE,
                  .packages=c('forecast', 'caret', packages), .export=c('testObject', 'tsSummary', 'tseriesControl')) %dopar% {

		if (is.null(xreg)) {
			if (fixedWindow) {
				xshort <- window(x, start=st+(i-minObs+1)/freq, end=st+i/freq)

			} else {
				xshort <- window(x, end=st + i/freq)
			}

      if (preProcess) {
        if (testObject(lambda)) {
          stop("Don't specify a lambda parameter when preProcess==TRUE")
        }
        stepLambda <- BoxCox.lambda(xshort, method=ppMethod)
        xshort <- BoxCox(xshort, stepLambda)
      }

			out <- FUN(xshort, h=maxHorizon, ...)

      if (preProcess) {
        out <- InvBoxCox(out, stepLambda)
      }

      return(out)

		} else if (! is.null(xreg)) {
			if (fixedWindow) {
				xshort <- window(x, start=st+(i-minObs+1)/freq, end=st+i/freq)
				xregshort <- xreg[((i):(i+minObs-1)),,drop=FALSE]
			} else {
				xshort <- window(x, end=st + i/freq)
				xregshort <- xreg[(1:(i+minObs-1)),,drop=FALSE]
			}
			newxreg <- xreg[(i+minObs):(i+minObs-1+maxHorizon),,drop=FALSE]

      if (preProcess) {
        if (testObject(lambda)) {
          stop("Don't specify a lambda parameter when preProcess==TRUE")
        }
        stepLambda <- BoxCox.lambda(xshort, method=ppMethod)
        xshort <- BoxCox(xshort, stepLambda)
      }

			out <- FUN(xshort, h=maxHorizon,
                xreg=xregshort, newxreg=newxreg, ...)

      if (preProcess) {
        out <- InvBoxCox(out, stepLambda)
      }

      return(out)
		}

	}

	#Extract the actuals we actually want to use
	actuals <- actuals[steps,,drop=FALSE]

	#Accuracy at each horizon
	out <- data.frame(
					plyr::ldply(1:maxHorizon,
						function(horizon) {
							P <- forecasts[,horizon,drop=FALSE]
							A <- na.omit(actuals[,horizon,drop=FALSE])
							P <- P[1:length(A)]
							P <- na.omit(P)
							A <- A[1:length(P)]
							summaryFunc(P,A)
						}
					)
				)

	#Add average accuracy, across all horizons
	overall <- colMeans(out)
	out <- rbind(out,overall)
  results <- data.frame(horizon=c(1:maxHorizon,'All'),out)

	#Add a column for which horizon and output
	return(list(actuals=actuals, forecasts=forecasts, results=results))
}



###########################
#Functions for testing MOVE TO EXAMPLES
###########################

if (FALSE){
  arimaForecast2 <- function(x,h,params,...) {
    require(forecast)
    order=c(params$p,params$d,params$q)
    Drift=params$Drift
    fit <- Arima(x, order=order, include.drift=Drift, ...)
    forecast(fit, h=h, level=99)$mean
  }

  best.ts <-  function(x, FUN, atHorizon, metric, tuneGrid, tsControl=tseriesControl(), ...) {
    out <- tuneGrid
    out[,metric] <- NA

    for (row in 1:nrow(tuneGrid)) {
      params <- tuneGrid[row,]
      tryCatch({
        result <- cv.ts(x, FUN, tsControl, params=params, ...)
        out[row,metric] <- result$results[atHorizon, metric]
      }, error = function(e) NA)
    }
    out
  }

  #model <- best.ts(a10, arimaForecast2,
  #                 atHorizon=1,
  #                 metric='MAPE',
  #                 tuneGrid=expand.grid(p=0:5, d=0:1, q=0:5, Drift=FALSE))
  #model
}

