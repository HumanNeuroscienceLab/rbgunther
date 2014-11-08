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
  make_option(c("-i", "--output"), help="Input AFNI bucket file (e.g., output from 3dREMLfit)", metavar="bucket"), 
  make_option(c("-o", "--output"), help="Output time-series file (e.g., output from 3dREMLfit)", metavar="3d+time"), 
  make_option(c("-n", "--name"), help="Sub-brick name (e.g., for bio#1_Coef the name is bio). This option will search for all sub-bricks matching that name. This optional option must be specified with -t/--type", metavar="3d+time"),
  make_option(c("-t", "--type"), help="Sub-brick type (e.g., for bio#1_Coef the type is Coef). This option will search for all sub-bricks matching that type. This optional option must be specified with -n/--name", metavar="3d+time"),
  make_optuon(c("-d", "--datatype"), help="Set the output datatype. Options are: char, short, int, float, or double.", default="float")
  make_option(c("-f", "--force"), action="store_true", default=FALSE, help="Will overwrite any existing output (default is to crash if output exists)."),
  make_option(c("-v", "--verbose"), action="store_true",help="Print extra output [default]"),
  make_option(c("-q", "--quiet"), action="store_false", default=FALSE, dest="verbose", help="Print little output"),
)

opt <- parse_args(OptionParser(usage = "%prog [options]", option_list = option_list))

if (opt$verbose) {
  vcat <- function(msg, ...) cat(sprintf(msg, ...))
} else {
  vcat <- function(...) invisible(NULL)
}

# Check required options
if (is.null(opts$input)) stop("You must specify the input bucket -i/--input")
if (is.null(opts$output)) stop("You must specify the output time-series -o/--output")
  
if ((is.null(opts$name) && !is.null(opts$type)) || (!is.null(opts$name) && is.null(opts$type)) {
  stop("If specifying -n/--name and -t/--type, then must specify both options together")
}
if (!(opts$datatype %in% c("char", "short", "int", "float", "double"))) {
  stop("-d/--datatype must be one of char, short, int, float, or double")
}

# Check outputs
if (file.exists(opts$output)) {
  if (opts$force) {
    vcat("Output %s already exists, removing\n", opts$output)
    file.remove(opts$output)
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
suppressMessages(library(plyr))
#library(tools)
#rm_niigz <- function(fn) sub(".nii.gz", "", fn)

# Load functions related to afni
vcat("Sourcing afni_helpers.R\n")
source(file.path(scriptdir, "lib", "afni_helpers.R"))


###
# Split Up
###

vcat("Reading in data\n")
bucket      <- read.nifti.image(opts$input)
            
hdr         <- read.nifti.header(opts$input)
hdr$pixdim  <- hdr$pixdim[-3]
hdr$dim     <- hdr$dim[-3]

if (!is.null(opts$name) && !is.null(opts$type)) {
  labs      <- brick_labs(opts$input)
  search_str<- sprintf("%s#[0-9]+_%s", opts$name, opts$type)
  inds      <- grep(search_str, labs)
  vcat("Searched for %s\n", search_str)
  vcat("Extracting inds: %s\n", paste(inds, collapse=","))
} else {
  inds      <- 1:dim(bucket)[4]
  vcat("Converting all sub-bricks in bucket to 3D+time\n")
}

hdr$dim[4]  <- length(inds)
outts       <- bucket[,,,,inds]

vcat("Saving output '%s'\n", opts$output)
write.ts(outts, hdr, file=opts$output, odt=opts$datatype)
