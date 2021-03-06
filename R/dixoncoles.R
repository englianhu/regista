#' Dixon-Coles model for estimating team strengths
#'
#' @description
#'
#' This is an implementation of the Dixon-Coles model for estimating soccer
#' teams' strength from goals scored and conceded:
#'
#' Dixon, Mark J., and Stuart G. Coles. "Modelling association football scores
#' and inefficiencies in the football betting market." Journal of the Royal
#' Statistical Society: Series C (Applied Statistics) 46, no. 2 (1997):
#' 265-280.
#'
#' @param hgoal A formula describing the home goals column in `data`, or a
#'   numeric vector containing the observed home goals for a set of games.
#' @param agoal A formula describing the away goals column in `data`, or a
#'   numeric vector containing the observed away goals for a set of games.
#' @param hteam A formula describing the home team column in `data`, or a
#'   vector containing the home team name for a set of games.
#' @param ateam A formula describing the away team column in `data`, or a
#'   vector containing the away team name for a set of games.
#' @param data Data frame, list or environment (or object coercible by
#' `as.data.frame` to a data frame) containing the variables in the model.
#' @param weights A formula describing an expression to calculate the weight for
#'   each game. All games weighted equally by default.
#' @param ... Arguments passed onto `dixoncoles_ext`.
#'
#' @return A list with component `par` containing the best set of parameters
#'   found. See `optim` for details.
#'
#' @importFrom lazyeval f_eval f_interp f_new uq
#' @importFrom rlang !! enquo eval_tidy f_rhs
#' @export
#' @examples
#' fit <- dixoncoles(hgoal, agoal, home, away,
#'                   data = premier_league_2010)
#'
dixoncoles <- function(hgoal, agoal, hteam, ateam, data, weights = 1, ...) {
  # Capture arguments with enquo
  hgoal <- enquo(hgoal)
  agoal <- enquo(agoal)
  hteam <- enquo(hteam)
  ateam <- enquo(ateam)

  # Check input
  hvar <- eval_tidy(hteam, data)
  avar <- eval_tidy(ateam, data)

  if (!(is.factor(hvar) & is.factor(avar))) {
    stop("home and away team variables should be factors (see factor_teams)")
  }
  if (!setequal(levels(hvar), levels(avar))) {
    warning("home and away team variables should have the same levels (see factor_teams)")
  }

  # Fit the model
  f1 <- f_new(uq(f_interp(~ off(uq(hteam)) + def(uq(ateam)) + hfa + 0)), uq(hgoal))
  f2 <- f_new(uq(f_interp(~ off(uq(ateam)) + def(uq(hteam)) + 0)),       uq(agoal))

  data$hfa <- TRUE

  res <- dixoncoles_ext(f1, f2, weights = !!enquo(weights), data = data, ...)

  # Hack to let predict.dixoncoles know to add HFA
  res$implicit_hfa <- TRUE

  res
}

#' A generic Dixon-Coles model for estimating team strengths
#'
#' @description
#'
#' This is an implementation of the Dixon-Coles model for estimating soccer
#' teams' strength from goals scored and conceded:
#'
#' Dixon, Mark J., and Stuart G. Coles. "Modelling association football scores
#' and inefficiencies in the football betting market." Journal of the Royal
#' Statistical Society: Series C (Applied Statistics) 46, no. 2 (1997):
#' 265-280.
#'
#' By specifying the model as a pair of formulas, it allows the user to
#' estimate the effect of parameters beyond team strength.
#'
#' @param f1 A formula describing the model for home goals.
#' @param f2 A formula describing the model for away goals.
#' @param weights A formula describing an expression to calculate the weight for
#'   each game.
#' @param data Data frame, list or environment (or object coercible by
#'   `as.data.frame` to a data frame) containing the variables in the model.
#' @param init Initial parameter values. If it is `NULL`, 0 is used for all
#'   values.
#' @param ... Arguments passed onto `optim`.
#'
#' @return A list with component `par` containing the best set of parameters
#'   found. See `optim` for details.
#'
#' @importFrom stats optim
#' @importFrom rlang enquo
#' @export
#' @examples
#' fit <- dixoncoles_ext(hgoal ~ off(home) + def(away) + hfa + 0,
#'                       agoal ~ off(away) + def(home) + 0,
#'                       weights = 1,  # All games weighted equally
#'                       data = premier_league_2010)
dixoncoles_ext <- function(f1, f2, weights, data, init = NULL, ...) {
  weights <- enquo(weights)

  # Handle args to pass onto optim including defaults
  dots <- list(...)
  if (!("method" %in% names(dots))) {
    dots["method"] <- "BFGS"
  }

  # Wrangle data and intial params
  modeldata <- .dc_modeldata(f1, f2, weights, data)

  if (is.null(init)) {
    params <- rep_len(0, length(modeldata$vars) + 1)
    names(params) <- c(modeldata$vars, "rho")
  } else {
    params <- init
  }

  # Create arguments to optim
  # We need to do this + do.call so that we can pass on ... with default args
  # Maybe there's a better way using rlang::list2?
  args <- c(
    list(par       = params,
         fn        = .dc_objective_function,
         modeldata = modeldata),
    dots
  )

  res <- do.call(optim, args)

  res$par <- .normalise_off_params(res$par)

  res$f1 <- f1
  res$f2 <- f2
  res$weights <- weights

  res$implicit_hfa <- FALSE
  res$data <- data

  structure(res, class = "dixoncoles")
}

# Dixon-Coles class ------------------------------------------------------------

#' @importFrom glue glue
#' @export
print.dixoncoles <- function(x, ...) {
  msg <- glue("Dixon-Coles model with specification:

               Home goals: {rlang::quo_text(x$f1)}
               Away goals: {rlang::quo_text(x$f2)}
               Weights   : {rlang::quo_text(x$weights)}")

  cat("\n")
  cat(msg)
  cat("\n\n")
  invisible(x)
}

#' Predict method for Dixon-Coles model fits
#'
#' @description
#'
#' Predicted rates or scorelines based on a Dixon Coles model object
#'
#' @param object Object of class inheriting from `dixoncoles`.
#' @param newdata A data frame in which to look for variables to predict
#' @param type Type of prediction (rates or scorelines).
#' @param up_to If `type = "scorelines"`, the maximum number of goals for which
#'   to calculate the probability of occurring in each match.
#' @param threshold If `type = "scorelines"`, scorelines with a probability
#'   below `threshold` will not be returned.
#' @param ... Arguments passed from other methods
#'
#' @return A list in which each element is a tibble. The contents of the tibble
#' depends on the value supplied to the `type` argument. These values are
#' enumerated for each possible value of `type` below:
#' \describe{
#'   \item{`rates`}{the side ("home" and "away") and the goalscoring rate of both teams}
#'   \item{`scorelines`}{the probability (`prob`) for each scoreline (`hgoal` and `agoal`)}
#'   \item{`outcomes`}{the probability (`prob`) of each outcome ("home_win", "draw" or "away_win") occurring}
#' }
#'
#' @export
predict.dixoncoles <- function(object, newdata = NULL,
                               type = c("rates", "scorelines", "outcomes"),
                               up_to = 50, threshold = sqrt(.Machine$double.eps),
                               ...) {
  type <- match.arg(type, c("rates", "scorelines", "outcomes"))

  if (is.null(newdata)) {
    newdata <- object$data
  }

  if (object$implicit_hfa == TRUE) {
    newdata$hfa <- TRUE
  }

  # Create model matrix for newdata
  modeldata <- .dc_modeldata(
    f1      = object$f1,
    f2      = object$f2,
    weights = rlang::quo(1),        # Weighting doesn't affect predictions
    data    = newdata,
    predict = TRUE
  )

  if (!identical(c(modeldata$vars, "rho"), names(object$par))) {
    stop(glue::glue("New data must have the same factor levels as the data used to fit.
                     See ?factor_teams"))
  }

  # Matrix multiplication to get Poisson means
  rate_info <- .dc_rate_info(object$par, modeldata)

  if (type == "scorelines") {
    return(.dc_predict_scorelines(rate_info, up_to, threshold))
  }

  if (type == "outcomes") {
    scorelines <- .dc_predict_scorelines(rate_info, up_to, threshold)
    outcomes <- purrr::map(scorelines, scorelines_to_outcomes)
    return(outcomes)
  }

  # Return rates if type == "rates" (default)
  rates <- purrr::map2(rate_info$home, rate_info$away, function(h, a) {
    tibble::tibble(side = c("home", "away"),
                   rate = c(h, a))
  })

  rates
}

# Broom methods ----------------------------------------------------------------

#' Tidy a Dixon-Coles model
#'
#' @description
#' Tidy summarises information about a fitted Dixon-Coles model.
#'
#' @param x A `dixoncoles` object created by `regista::dixoncoles()`
#' @param ... Additional arguments. Not used.
#'
#' @return A `tibble::tibble()` with one row for each parameter estimated by the
#' model.
#'
#' @importFrom purrr %>% %||% map_chr pluck
#' @export
tidy.dixoncoles <- function(x, ...) {
  parameter_names <- strsplit(names(x$par), "___")
  parameter_values <- x$par

  pluck_na <- function(y, ...) {
    pluck(y, ...) %||% NA_character_
  }

  tibble::tibble(parameter = map_chr(parameter_names, pluck, 1),
                 team      = map_chr(parameter_names, pluck_na, 2),
                 value     = parameter_values)
}

#' Augment data with information from a Dixon-Coles model
#'
#' @description
#' Append additional information about a set of matches.
#'
#' @param x A `dixoncoles` object created by `regista::dixoncoles`.
#' @param data A `data.frame` or `tibble::tibble` containing the original data.
#' @param newdata A `data.frame` or `tibble::tibble` object of new data to be predicted.
#' @param type.predict Type of prediction. Passed onto `regista::predict.dixoncoles`
#' @param ... Additional arguments. Not used.
#'
#' @return A `tibble::tibble()` with one row.
#'
#' @importFrom purrr %||%
#'
#' @export
augment.dixoncoles <- function(x, data = NULL, newdata, type.predict, ...) {
  if (missing(newdata)) {
    newdata <- data %||% x$data
  }

  augmented_data <- tibble::as_tibble(newdata)

  if (type.predict == "scorelines") {
    augmented_data$.scorelines <- predict.dixoncoles(x, newdata, type = type.predict)
    return(augmented_data)
  }

  if (type.predict == "outcomes") {
    augmented_data$.outcomes <- predict.dixoncoles(x, newdata, type = type.predict)
    return(augmented_data)
  }

  # Use rates by default
  augmented_data$.rates <- predict.dixoncoles(x, newdata, type = type.predict)
  augmented_data
}

# Internal functions -----------------------------------------------------------

#' Calculate the probability of scorelines occuring for a given set of matches
#' @keywords internal
#' @importFrom purrr map2
.dc_predict_scorelines <- function(rates, up_to, threshold) {
  # Calculate the probability of each scoreline for each game
  map2(
    rates$home,
    rates$away,
    .dc_predict_scorelines_once,
    rho       = rates$rho,
    up_to     = up_to,
    threshold = threshold
  )
}

#' Calculate the probability of scorelines occuring for a given match
#' @keywords internal
#' @importFrom stats dpois
#' @importFrom purrr map2_dbl
.dc_predict_scorelines_once <- function(home_rate, away_rate, rho, up_to, threshold) {
  home_probs <- dpois(0:up_to, home_rate)
  away_probs <- dpois(0:up_to, away_rate)

  scorelines <- expand.grid(hgoal = 0:up_to,
                            agoal = 0:up_to)

  hprob <- dpois(scorelines$hgoal, home_rate)
  aprob <- dpois(scorelines$agoal, away_rate)

  tau <- .tau(
    scorelines$hgoal,
    scorelines$agoal,
    home_rates = home_rate,
    away_rates = away_rate,
    rho = rho
  )

  scorelines$prob <- hprob * aprob * tau

  # Filter out the ~0% (< threshold) rows
  scorelines <- scorelines[scorelines$prob > threshold, ]

  tibble::as_tibble(scorelines)
}

# Auxiliary fitting functions --------------------------------------------------

#' Get model data for a Dixon-Coles model
#' @keywords internal
#' @importFrom purrr %>% map reduce flatten_chr
#' @importFrom rlang enquo eval_tidy f_lhs f_rhs
.dc_modeldata <- function(f1, f2, weights, data, predict = FALSE) {
  terms1 <- .quo_terms(f1)
  terms2 <- .quo_terms(f2)

  # Create the model matrices
  mat1 <-
    map(terms1, .term_matrix, data = data) %>%
    reduce(cbind)
  mat2 <-
    map(terms2, .term_matrix, data = data) %>%
    reduce(cbind)

  column_names <- unique(c(colnames(mat1), colnames(mat2)))

  # Fill in missing parameters
  mat1 <- reduce(column_names, .fill_if_missing, .init = mat1)
  mat2 <- reduce(column_names, .fill_if_missing, .init = mat2)

  # Ensure both matrices have the same column ordering
  # We have to use drop = FALSE to ensure that it retains it's dimensions when
  # there's just 1 observation (for instance when calling predict.dixoncoles)
  mat1 <- mat1[, column_names, drop = FALSE]
  mat2 <- mat2[, column_names, drop = FALSE]

  modeldata <- list(
    vars    = column_names,
    mat1    = mat1,
    mat2    = mat2,
    weights = eval_tidy(weights, data)
  )

  # Only add home/away goals if necessary
  if (predict == FALSE) {
    modeldata$y1 <- eval_tidy(f_lhs(f1), data)
    modeldata$y2 <- eval_tidy(f_lhs(f2), data)
  }

  modeldata
}

#' Function controlling dependence between home and away goals
#' @keywords internal
.tau <- function(hg, ag, home_rates, away_rates, rho) {

  # Initialise values to 1
  vals <- rep_len(1, length.out = length(hg))

  vals <- ifelse((hg == 0) & (ag == 0), 1 - home_rates * away_rates * rho, vals)
  vals <- ifelse((hg == 0) & (ag == 1), 1 + home_rates * rho, vals)
  vals <- ifelse((hg == 1) & (ag == 0), 1 + away_rates * rho, vals)
  vals <- ifelse((hg == 1) & (ag == 1), 1 - rho, vals)

  vals
}

#' Dixon-Coles negative log likelihood
#' @keywords internal
#' @importFrom stats dpois
.dc_negloglike <- function(hg, ag, home_rates, away_rates, rho, weights) {
  hprob <- dpois(hg, home_rates, log = TRUE)
  aprob <- dpois(ag, away_rates, log = TRUE)

  loglike <- hprob + aprob + log_quietly(.tau(hg, ag, home_rates, away_rates, rho))

  # Create weighted pseudo-log likelihood
  ploglike <- loglike * weights

  -sum(ploglike)
}

#' Get estimated rates for home and away goals
#' @keywords internal
.dc_rate_info <- function(params, modeldata) {
  rho <- params["rho"]
  rate_params <- matrix(params[names(params) != "rho"], nrow = 1)

  home_rates <- exp(rate_params %*% t(modeldata$mat1))
  away_rates <- exp(rate_params %*% t(modeldata$mat2))

  list(home = home_rates,
       away = away_rates,
       rho  = rho)
}

#' Dixon-Coles objective function
#' @keywords internal
.dc_objective_function <- function(params, modeldata) {
  rates <- .dc_rate_info(.normalise_off_params(params), modeldata)

  .dc_negloglike(
    modeldata$y1,
    modeldata$y2,
    rates$home,
    rates$away,
    rates$rho,
    modeldata$weights
  )
}

#' Normalise attack parameters to make the model identifable (mean = 1)
#' @keywords internal
.normalise_off_params <- function(params) {
  off_ixs <- startsWith(names(params), "off___")
  off_params <- params[off_ixs]

  params[off_ixs] <- params[off_ixs] - log(mean(exp(off_params)))

  params
}

#' Quote terms of a formula
#' @keywords internal
#' @importFrom rlang parse_expr caller_env
#' @importFrom purrr %>% map
#' @importFrom stats terms
.quo_terms <- function(f) {
  t <- terms(f)

  if (attr(t, "intercept")) {
    warning("Intercept term will be ignored")
  }

  t %>%
    attr("term.labels") %>%
    map(parse_expr)
}

#' Get a matrix of dummy variables from a factor
#' @keywords internal
#' @importFrom stats model.frame model.matrix
.make_dummies <- function(values) {
  mat <- model.matrix(
    ~ values - 1,
    model.frame(~ values - 1),
    contrasts = FALSE
  )
  colnames(mat) <- gsub("^values", "", colnames(mat))

  mat
}

#' Get a model matrix from an expression
#' @keywords internal
#' @importFrom rlang eval_tidy quo_name
.term_matrix <- function(expr, data) {
  values <- eval_tidy(expr, data)

  if (is.factor(values)) {
    return(.make_dummies(values))
  }

  matrix(values, dimnames = list(NULL, quo_name(expr)))
}

#' Add column to a matrix, if it doesn't exist
#' @keywords internal
.fill_if_missing <- function(mat, name) {
  if (!(name %in% colnames(mat))) {
    blank_column <- matrix(0, nrow = nrow(mat), ncol = 1,
                           dimnames = list(NULL, name))
    return(cbind(mat, blank_column))
  }
  mat
}
