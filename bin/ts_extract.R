#!/usr/bin/env Rscript

# inputs:
# - data
# - roi
# - unweighted/weighted
# - single/multiple
# outputs:
# - fname

###
# User Args
###

suppressPackageStartupMessages(library("optparse"))

option_list <- list(
  make_option(c("-i", "--input"), help="Input functional data file", metavar="3D+time"), 
  make_option(c("-r", "--roi"), help="Input region-of-interest", metavar="3D"), 
  make_option(c("-o", "--output"), help="Output time-series file", metavar="1D"), 
  make_option(c("-w", "--weighted"), help="Take weighted average based on weights in ROI.", action="store_true", default=FALSE), 
  make_option(c("-m", "--multiple"), help="Look for multiple ROIs each with a unique value", action="store_true", default=FALSE), 
  make_option(c("-a", "--all"), help="Spit out all the voxels in the ROI", action="store_true", default=FALSE), 
  make_option(c("-d", "--digits"), help="Number of decimal places to keep (default is auto)", type="integer"), 
  make_option(c("-f", "--force"), action="store_true", default=FALSE, help="Will overwrite any existing output (default is to crash if output exists)."),
  make_option(c("-v", "--verbose"), action="store_true",help="Print extra output [default]"),
  make_option(c("-q", "--quiet"), action="store_false", default=FALSE, dest="verbose", help="Print little output")
)

opts <- parse_args(OptionParser(usage = "%prog [options]", option_list = option_list))

if (opts$verbose) {
  vcat <- function(msg, ..., newline=T) {
    if (newline) msg <- paste(msg, "\n", sep="")
    cat(sprintf(msg, ...))
  }
} else {
  vcat <- function(...) invisible(NULL)
}

# Check required options
if (is.null(opts$input)) stop("You must specify the input functional data -i/--input")
if (is.null(opts$roi)) stop("You must specify the input roi -r/--roi")
if (is.null(opts$output)) stop("You must specify the output time-series -o/--output")

# Check options
if ((opts$weighted + opts$multiple + opts$all)>1) {
  stop("Cannot have only one of -w/--weighted, -m/--multiple, or -a/--al.")
}

# Check inputs
if (!file.exists(opts$input)) stop("Input functional data file doesn't exist: ", opts$input)
if (!file.exists(opts$roi)) stop("Input ROI file doesn't exist: ", opts$roi)

# Check outputs
if (file.exists(opts$output)) {
  if (opts$force) {
    vcat("Output %s already exists, removing\n", opts$output)
    success <- file.remove(opts$output)
    if (!success) stop("Unable to remove output file: ", opts$output)
  } else {
    stop("Output file already exists (consider using -f/--force).")
  }
}

# Also save the script directory
argv      <- commandArgs(trailingOnly = FALSE)
scriptdir <- dirname(dirname(substring(argv[grep("--file=", argv)], 8)))


###
# Setup
###

# Libraries
vcat("Loading libraries")
suppressMessages(library(niftir))
suppressMessages(library(plyr))
#library(tools)
#rm_niigz <- function(fn) sub(".nii.gz", "", fn)

# Load functions related to afni
vcat("Sourcing afni_helpers.R")
source(file.path(scriptdir, "lib", "afni_helpers.R"))
#source(file.path("../../..", "libs", "afni_helpers.R"))


###
# Read in Data
###

# ROI
vcat("Read in ROI: %s", opts$roi)
rois    <- read.nifti.image(opts$roi)
mask    <- as.vector(rois>0)
rois    <- rois[mask]

# Data
vcat("Read in functional data: %s", opts$input)
dat     <- read.big.nifti(opts$input, shared=FALSE)
dat     <- deepcopy(dat, cols=mask, shared=FALSE)
dat     <- as.matrix(dat)


###
# Average TS
###

if (opts$multiple) {
  vcat("Averaging across multiple ROIs")
  
  urois <- sort(unique(rois))
  nrois <- length(urois)
  vcat("Found %s ROI(s)", nrois)
  
  ts <- laply(1:nrois, function(ri) {
    uroi <- urois[ri]
    rowMeans(dat[,rois==uroi])
  }, .drop=F)
  ts <- t(ts)
} else if (opts$weighted) {
  vcat("Weighted average of %i voxels", sum(mask))
  
  rois  <- rois/sum(rois)
  ts <- apply(dat, 1, function(regions) {
    sum(rois * regions)
  })
} else if (opts$all) {
  vcat("No averaging - get all time-series in ROI with %i voxels", sum(mask))
  ts <- dat
} else {
  vcat("Vanilla average across %i voxels", sum(mask))
  
  # check number of ROIs
  urois <- sort(unique(rois))
  nrois <- length(urois)
  if (nrois > 1) warning("Multiple ROIs found in ", opts$roi)
  
  ts      <- rowMeans(dat)
}

ts    <- as.matrix(ts)
if (!is.null(opts$digits)) ts <- round(ts, opts$digits)


###
# Save the time-series
###

vcat("Saving to %s", opts$output)
write.table(ts, file=opts$output, row.names=F, col.names=F)


# DIFFERENT TESTING COMMANDS

# 3dcalc -a /mnt/nfs/psych/faceMemoryMRI/analysis/subjects/tb9226/anat/rois/lh_antfusiform_face_gt_house.nii.gz -expr 'step(a)' -prefix tmp.nii.gz -short
# Rscript 10_extract_ts_subject.R -i /mnt/nfs/psych/faceMemoryMRI/analysis/subjects/tb9226/Questions/to_highres/func_preproc_fwhm5_run01.nii.gz -r tmp.nii.gz -o tmp.1D -v
# 3dROIstats -mask tmp.nii.gz -quiet /mnt/nfs/psych/faceMemoryMRI/analysis/subjects/tb9226/Questions/to_highres/func_preproc_fwhm5_run01.nii.gz > tmp_2.1D

# Rscript 10_extract_ts_subject.R --multiple -i /mnt/nfs/psych/faceMemoryMRI/analysis/subjects/tb9226/Questions/to_highres/func_preproc_fwhm5_run01.nii.gz -r /mnt/nfs/psych/faceMemoryMRI/analysis/subjects/tb9226/anat/rois/lh_antfusiform_face_gt_house_peaks.nii.gz -o tmp.1D -f -v
# 3dROIstats -mask /mnt/nfs/psych/faceMemoryMRI/analysis/subjects/tb9226/anat/rois/lh_antfusiform_face_gt_house_peaks.nii.gz -quiet /mnt/nfs/psych/faceMemoryMRI/analysis/subjects/tb9226/Questions/to_highres/func_preproc_fwhm5_run01.nii.gz > tmp_2.1D

# Rscript 10_extract_ts_subject.R --weighted -i /mnt/nfs/psych/faceMemoryMRI/analysis/subjects/tb9226/Questions/to_highres/func_preproc_fwhm5_run01.nii.gz -r /mnt/nfs/psych/faceMemoryMRI/analysis/subjects/tb9226/anat/rois/lh_antfusiform_face_gt_house.nii.gz -o tmp.1D -f -v
# msum=$( 3dBrickStat -non-zero -sum /mnt/nfs/psych/faceMemoryMRI/analysis/subjects/tb9226/anat/rois/lh_antfusiform_face_gt_house.nii.gz )
# 3dcalc -a /mnt/nfs/psych/faceMemoryMRI/analysis/subjects/tb9226/Questions/to_highres/func_preproc_fwhm5_run01.nii.gz -b /mnt/nfs/psych/faceMemoryMRI/analysis/subjects/tb9226/anat/rois/lh_antfusiform_face_gt_house.nii.gz -expr "a*(b/${msum})" -prefix tmp2.nii.gz
# 3dROIstats -mask tmp.nii.gz -nzsum -quiet tmp2.nii.gz > tmp_2.1D
