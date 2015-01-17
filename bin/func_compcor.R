#!/usr/bin/env Rscript

# This will read in white-matter and csf mask
# and functional data (unsmoothed)
# if there is a registration transformation
# this will transform the masks to func space
# the masks will be eroded by 2 for wm (no change for csf)
# and the time-series will be extracted from those areas
# we can optionally apply a high-pass filter to this data
# finally it can be read into R and a PCA can be applied
# we can use the method in the paper (simulations) to 
# determine the optimal number of components (or can choose top 5)

#--- User Args ---#

suppressPackageStartupMessages(library("optparse"))
suppressPackageStartupMessages(library("stringr"))

option_list <- list(
  make_option(c("-i", "--input"), help="Functional data file", metavar="3D+time"), 
  make_option(c("-m", "--mask"), help="Functional brain mask", metavar="3D"), 
  make_option(c("-w", "--white"), help="White matter mask(s). More than one mask file can be given but must be within quotes (e.g., 'left_white.nii.gz right_white.nii.gz'", metavar="3Ds"), 
  make_option(c("-c", "--csf"), help="CSF mask(s). More than one mask file can be given but must be within quotes (e.g., 'left_csf.nii.gz right_csf.nii.gz'", metavar="3Ds"), 
  make_option(c("-r", "--reg"), help="Directory with AFNI registration info", metavar="dirpath"), 
  make_option("--hp", type="integer", help="High-pass filter to use on the extracted time-series", metavar="dirpath"), 
  
  make_option("--ncomp", type="integer", help="Manually define number of components to keep", metavar="int"), 
  make_option("--nauto", help="Automatically define number of components to remove based on eigen values and elbow method", default=FALSE), 
  make_option("--nsim", type="integer", help="Automatically define number of components to remove based on N simulations", metavar="int"), 
    
  make_option(c("-o", "--output"), help="Output directory", metavar="1D"), 

  make_option("--threads", default=1, help="number of threads to run in parallel", metavar="N"), 
  make_option(c("-f", "--force"), action="store_true", default=FALSE, help="Will overwrite any existing output (default is to crash if output exists)."), 
  make_option(c("-v", "--verbose"), action="store_true",help="Print extra output [default]"),
  make_option(c("-q", "--quiet"), action="store_false", default=FALSE, dest="verbose", help="Print little output")
)

opts <- parse_args(OptionParser(usage = "%prog [options]", option_list = option_list))

## For testing
#opts <- c()
#basedir <- "/mnt/nfs/psych/faceMemoryMRI/analysis/subjects/tb9226"
#opts$input <- file.path(basedir, "Questions/mc/func_run01_volreg.nii.gz")
#opts$white <- file.path(basedir, "anat/freesurfer/volume", c("left_cerebral_white_matter.nii.gz", "right_cerebral_white_matter.nii.gz"))
#opts$csf <- file.path(basedir, "anat/freesurfer/volume", c("left_lateral_ventricle.nii.gz", "right_lateral_ventricle.nii.gz", "csf.nii.gz"))
#opts$reg <- file.path(basedir, "Questions/reg")
#opts$hp <- 200
#opts$output <- file.path(basedir, "Questions/compcor")
#opts$mask <- file.path(basedir, "Questions/func_mean_brain_mask.nii.gz")
#opts$threads <- 16
#opts$force <- TRUE
#opts$ncomp <- NULL; opts$nauto <- FALSE; opts$nsim <- 100
#opts$verbose <- T


# split white and csf inputs
if (!is.null(opts$white)) {
  opts$white  <- str_replace_all(str_trim(opts$white), "  ", " ")
  opts$white  <- strsplit(opts$white, " ")[[1]]
}
if (!is.null(opts$csf)) {
  opts$csf  <- str_replace_all(str_trim(opts$csf), "  ", " ")
  opts$csf <- strsplit(opts$csf, " ")[[1]]
}


#--- Checks ---#

# Check required options
if (is.null(opts$input)) stop("You must specify the input functional data -i/--input")
if (is.null(opts$mask)) stop("You must specify the input mask -m/--mask")
if (is.null(opts$white)) stop("You must specify the input white-matter roi -w/--white")
if (is.null(opts$csf)) stop("You must specify the input CSF roi -c/--csf")
if (is.null(opts$output)) stop("You must specify the output directory -o/--output")

# Check that at least one component option given
if (is.null(opts$ncomp) & !opts$nauto & is.null(opts$nsim)) {
  stop("You must specify at least one component selection approach: --ncomp, --nauto, or --nsim")
}

# Check inputs
if (!file.exists(opts$input)) stop("Input functional data file doesn't exist: ", opts$input)
if (!file.exists(opts$mask)) stop("Input functional brain mask doesn't exist: ", opts$mask)
if (!all(file.exists(opts$white))) stop("Input white-matter ROI file(s) don't exist: ", paste(opts$white[!file.exists(opts$white)], collapse=", "))
if (!all(file.exists(opts$csf))) stop("Input CSF ROI file(s) doesn't exist: ", paste(opts$csf[!file.exists(opts$csf)], collapse=", "))

# Check outputs
if (file.exists(opts$output)) {
  if (opts$force) {
    cat(sprintf("Output directory %s already exists, removing\n", opts$output))
    ofiles <- list.files(opts$output, full.names=T)
    success <- file.remove(ofiles)
    if (!all(success)) stop("Unable to remove output files: ", ofiles)
    success <- file.remove(opts$output)
    if (!success) stop("Unable to remove output directory: ", opts$output)  
  } else {
    stop("Output directory already exists (consider using -f/--force).")
  }
}


#--- SETUP 1 ---#

# change directory to the output
if (!file.exists(opts$output)) dir.create(opts$output)
curdir <- getwd()
setwd(opts$output)

# logging
logfile <- file.path(opts$output, "log.txt")
cat("", file=logfile)


#--- Functions ---#

vcat <- function(msg, ..., newline=T) {
  if (newline) msg <- paste(msg, "\n", sep="")
  if (opts$verbose) cat(sprintf(msg, ...))
  cat(sprintf(msg, ...), file=logfile, append=T)
  invisible(NULL)
}

#' Executes on the command-line with sprintf
run <- function(cmd, ..., intern=FALSE) {
  vcat(paste("x:", cmd), ...)
  system(sprintf(cmd, ...), intern=intern)
}


#--- SETUP 2 ---#

vcat("\nLoading libraries")
suppressMessages(library(niftir))
suppressMessages(library(plyr))
suppressMessages(library(doMC))
suppressMessages(library(nFactors))

vcat("Setting %i threads", opts$threads)
registerDoMC(opts$threads)
Sys.setenv(OMP_NUM_THREADS=opts$threads)


#--- Prepare Masks ---#

vcat("\nPREPARE MASKS")

vcat("\nPrepare white-matter")

  vcat("...combine masks")
  cmd <- "3dMean -mask_union -prefix white_matter_in_highres.nii.gz %s"
  run(cmd, paste(opts$white, collapse=" "))

  if (!is.null(opts$reg)) {
    vcat("...register")
    cmd <- "gen_applywarp.rb -i white_matter_in_highres.nii.gz -r %s -w 'highres-to-exfunc' -o white_matter_in_func.nii.gz --interp nn"
    run(cmd, opts$reg)
  } else {
    vcat("...no registration")
    run("ln -sf white_matter_in_highres.nii.gz white_matter_in_func.nii.gz")
  }
  run("fslcpgeom %s white_matter_in_func.nii.gz -d", opts$mask)
  
  vcat("...erode the WM mask by 2 voxels")
  run("3dmask_tool -input white_matter_in_func.nii.gz -dilate_inputs -2 -prefix white_matter_in_func_erode.nii.gz")
  
  vcat("...deoblique + reorient")
  run("3drefit -deoblique white_matter_in_func_erode.nii.gz")
  run("3dresample -overwrite -inset white_matter_in_func_erode.nii.gz -orient RPI -prefix white_matter_in_func_erode.nii.gz")
  
  vcat("...mask")
  run("3dcalc -a white_matter_in_func_erode.nii.gz -b %s -expr 'step(a)*step(b)' -prefix white_matter.nii.gz", opts$mask)
  
vcat("\nPrepare CSF")

  vcat("...combine masks")
  cmd <- "3dMean -mask_union -prefix csf_in_highres.nii.gz %s"
  run(cmd, paste(opts$csf, collapse=" "))

  if (!is.null(opts$reg)) {
    vcat("...register")
    cmd <- "gen_applywarp.rb -i csf_in_highres.nii.gz -r %s -w 'highres-to-exfunc' -o csf_in_func.nii.gz --interp nn"
    run(cmd, opts$reg)
  } else {
    vcat("...no registration")
    run("ln -sf csf_in_highres.nii.gz csf_in_func.nii.gz")
  }
  run("fslcpgeom %s csf_in_func.nii.gz -d", opts$mask)
  
  vcat("...mask")
  run("3dcalc -a csf_in_func.nii.gz -b %s -expr 'step(a)*step(b)' -prefix csf.nii.gz", opts$mask)
  
vcat("\nCount the number of voxels in each mask")
  
  nwm   <- run("3dBrickStat -count -non-zero white_matter.nii.gz", intern=TRUE)
  ncsf  <- run("3dBrickStat -count -non-zero csf.nii.gz", intern=TRUE)
  vcat("# of white-matter voxels: %s", nwm)
  vcat("# of CSF voxels: %s", ncsf)
  cat(sprintf("%s # white-matter\n%s # csf\n", nwm, ncsf), file="nvoxs_in_masks.txt")
  if ((as.integer(nwm) == 0) || (as.integer(ncsf) == 0)) {
    stop("One of the masks has 0 voxels!!!")
  }

vcat("\nCombine the WM and CSF masks")
run("3dcalc -a white_matter.nii.gz -b csf.nii.gz -expr 'step(a)+step(b)' -prefix mask_csf+wm.nii.gz")
run("fslcpgeom %s mask_csf+wm.nii.gz -d", opts$mask) # do this earlier?


#--- High-Pass Filter ---#

if (is.null(opts$hp)) {
  vcat("\nNO high-pass filter")
  infile <- opts$input
} else {
  vcat("\nHigh-pass filter")
  run("fslmaths %s -mas mask_csf+wm.nii.gz -Tmean tempMean.nii.gz", opts$input)
  run("fslmaths %s -mas mask_csf+wm.nii.gz -bptf %f -1 -add tempMean.nii.gz func_masked_data_bptf.nii.gz", opts$input, opts$hp/2.0)
  run("rm tempMean.nii.gz")
  infile <- "func_masked_data_bptf.nii.gz"
}
  

#--- PCA ---#

vcat("\nPCA")

vcat("...reading in data")
mask  <- read.mask("mask_csf+wm.nii.gz")
dat   <- read.big.nifti4d(infile)
bdat  <- do.mask(dat, mask)
dat   <- as.matrix(bdat)

vcat("...pca")
res   <- prcomp(dat, scale=TRUE)

if (!is.null(opts$ncomp)) {
  vcat("...using manual component selection approach")
  ncomps  <- opts$ncomp
  
  vcat("...selecting top %i components", ncomps)
  comps <- res$x[,1:ncomps]

  vcat("...saving components to")
  ofile <- file.path(opts$output, "compcor_comps_ncomp.1D")
  vcat(ofile)
  write.table(comps, file=ofile, row.names=F, col.names=F, quote=F)
}

if (opts$nauto) {
  vcat("...using auto component selection with elbow approach")
  nS      <- nScree(x=res$sdev)
  ncomps  <- nS$noc
  
  vcat("...selecting top %i components", ncomps)
  comps <- res$x[,1:ncomps]

  vcat("...saving components to")
  ofile <- file.path(opts$output, "compcor_comps_nauto.1D")
  vcat(ofile)
  write.table(comps, file=ofile, row.names=F, col.names=F, quote=F)
} 

if (!is.null(opts$nsim)) {
  vcat("...using auto component selection with simulation approach")
  perm.sdev <- laply(1:opts$nsim, function(i) {
    rdat <- matrix(rnorm(prod(dim(dat))), nrow(dat), ncol(dat))
    rres <- prcomp(rdat, scale=TRUE)
    rres$sdev
  }, .parallel=TRUE)
  pvals <- sapply(1:length(res$sdev), function(ci) {
    vec <- c(res$sdev[ci], perm.sdev[,ci])
    sum(vec[1]<=vec)/length(vec)
  })
  ncomps  <- sum(pvals<0.05)
  
  vcat("...selecting top %i components", ncomps)
  comps <- res$x[,1:ncomps]

  vcat("...saving components to")
  ofile <- file.path(opts$output, "compcor_comps_nsim.1D")
  vcat(ofile)
  write.table(comps, file=ofile, row.names=F, col.names=F, quote=F)
}

