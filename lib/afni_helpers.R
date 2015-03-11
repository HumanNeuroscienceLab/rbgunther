load_my_bucket_data <- function(expr, infile, maskfile, priorfile=NULL) {
  # Get indices first in case error
  labs <- brick_labs(infile)
  inds <- grep(expr, labs)
  if (length(inds) == 0) stop("no inds found for ", infile, " with expression ", expr)
   
  func <- read.nifti.image(infile)
  mask <- read.mask(maskfile) 
  if (!is.null(priorfile)) {
    prior <- read.mask(priorfile)
    mask <- mask & prior
  }
  
  sfunc <- func[,,,,inds]
  dim(sfunc) <- c(prod(dim(sfunc)[1:3]), dim(sfunc)[4])
  sfunc <- sfunc[mask,]
  
  colnames(sfunc) <- labs[inds]
  
  sfunc
}

# Extract sub-brick labels from file
brick_labs <- function(fn) {
  ret <- system(sprintf("3dAttribute BRICK_LABS %s", fn), intern=T, ignore.stderr=T)
  ret <- strsplit(ret, "~")[[1]]
  ret
}

# Extracts sub-brick stat auxillary information (e.g., degrees-of-freedom)
# as a list with each element corresponding to a sub-brick
brick_stataux <- function(fn) {
  func_types <- list("fim", "thr", "corr", "tstat", "fstat", "zscore", "chisq", "betastat", "binomial", "gamma", "poisson", "bucket")
  labs <- brick_labs(fn)
  
  stataux <- system(sprintf("3dAttribute BRICK_STATAUX %s", fn), intern=T, ignore.stderr=T)
  stataux <- as.numeric(strsplit(stataux, " ")[[1]])
  
  list_stataux <- vector("list", length(labs))
  names(list_stataux) <- labs
  i <- 1
  while (i < length(stataux)) {
    ind <- stataux[i] + 1
    code <- stataux[i+1] + 1
    ftype <- func_types[code]
    n <- stataux[i+2]
    aux <- stataux[(i+3):(i+3+n-1)]
    list_stataux[[ind]] <- aux
    i <- i + 3 + n
  }
  
  list_stataux
}

xmat_labs <- function(fn) {
  str <- system(sprintf("grep ColumnLabels %s | sed s/'#  ColumnLabels = '//", fn), intern=T)
  str <- gsub("\"", "", str)
  cols <- strsplit(str, ' ; ')[[1]]
  cols
}