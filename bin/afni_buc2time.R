#!/usr/bin/env Rscript

# inputs:
# - bucket
# - label
# - otype
# outputs:
# - fname

###
# User Args
###

suppressPackageStartupMessages(library("optparse"))

option_list <- list(
  make_option(c("-i", "--input"), help="Input AFNI bucket file (e.g., output from 3dREMLfit)", metavar="bucket"), 
  make_option(c("-o", "--output"), help="Output time-series file (e.g., output from 3dREMLfit)", metavar="3d+time"), 
  make_option(c("-n", "--name"), help="Sub-brick name (e.g., for bio#1_Coef the name is bio). This option will search for all sub-bricks matching that name. This optional option must be specified with -t/--type", metavar="3d+time"),  
  make_option(c("-s", "--search"), help="Search for specified sub-bricks and filter. Search will be done with grep so can be regular expressians. Consider using -l/--list option to see if search gets the requested sub-bricks."),
  make_option(c("-l", "--list"), help="Will only list the sub-brick names and then quit", action="store_true", default=FALSE),
  make_option(c("-d", "--datatype"), help="Set the output datatype. Options are: char, short, int, float, or double.", default="float"), 
  make_option(c("-f", "--force"), action="store_true", default=FALSE, help="Will overwrite any existing output (default is to crash if output exists)."),
  make_option(c("-v", "--verbose"), action="store_true",help="Print extra output [default]"),
  make_option(c("-q", "--quiet"), action="store_false", default=FALSE, dest="verbose", help="Print little output")
)

opts <- parse_args(OptionParser(usage = "%prog [options]", option_list = option_list))

if (opts$verbose) {
  vcat <- function(msg, ...) cat(sprintf(msg, ...))
} else {
  vcat <- function(...) invisible(NULL)
}

# Check required options
if (is.null(opts$input)) stop("You must specify the input bucket -i/--input")
if (is.null(opts$output)) stop("You must specify the output time-series -o/--output")
if (!(opts$datatype %in% c("char", "short", "int", "float", "double"))) {
  stop("-d/--datatype must be one of char, short, int, float, or double")
}

# Check inputs
if (!file.exists(opts$input)) stop("Input bucket doesn't exist:", opts$input)

# Check outputs
if (file.exists(opts$output)) {
  if (opts$force) {
    vcat("Output %s already exists, removing\n", opts$output)
    success <- file.remove(opts$output)
    if (!success) stop("Unable to remove output file", opts$output)
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
vcat("Loading libraries\n")
suppressMessages(library(niftir))
#library(tools)
#rm_niigz <- function(fn) sub(".nii.gz", "", fn)

# Load functions related to afni
vcat("Sourcing afni_helpers.R\n")
source(file.path(scriptdir, "lib", "afni_helpers.R"))


###
# Dealing with Sub-Bricks
###

labs      <- brick_labs(opts$input)

if (!is.null(opts$search)) {
  inds    <- grep(opts$search, labs)
  vcat("Will extract inds: %s\n", paste(inds, collapse=","))
} else {
  inds    <- 1:dim(bucket)[4]
  vcat("Converting all sub-bricks in bucket to 3D+time\n")
}

if (opts$list) {
  labs    <- labs[inds]
  cat("# Labels\n")
  cat(paste(labs, collapse="\n"))
  cat("\n")
  quit()
}


###
# Split Up
###

vcat("Reading in data\n")
bucket      <- read.nifti.image(opts$input)
            
hdr         <- read.nifti.header(opts$input)
hdr$pixdim  <- hdr$pixdim[-4]
hdr$dim     <- hdr$dim[-4]

hdr$dim[4]  <- length(inds)
outts       <- bucket[,,,,inds]

vcat("Saving output '%s'\n", opts$output)
invisible(write.nifti(outts, hdr, outfile=opts$output, odt=opts$datatype))
