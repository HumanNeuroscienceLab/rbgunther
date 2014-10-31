#!/usr/bin/env ruby
# 
#  smooth.rb
#  
#  Smooths your functional data only within a mask.
#  
#  Created by Zarrar Shehzad on 2014-10-03
# 

# require 'pry'
# binding.pry

###
# SETUP
###

require 'pathname'
require 'fileutils'
require 'colorize'        # allows adding color to output
require 'erb'             # for interpreting erb to create report pages
require 'trollop'         # command-line parsing
require 'tempfile'

# If script called from the command-line
if __FILE__==$0
  SCRIPTDIR   = Pathname.new(__FILE__).realpath.dirname.dirname
  SCRIPTNAME  = Pathname.new(__FILE__).basename.sub_ext("")

  # add lib directory to ruby path
  $: << SCRIPTDIR + "lib" # will be scriptdir/lib
  $: << SCRIPTDIR + "bin" unless $:.include?(SCRIPTDIR + "bin")
end

require 'for_commands.rb' # provides various function such as 'run'
require 'for_afni.rb' # provides various function such as 'run'


###
# DO IT
###

# Create a function that wraps around the cmdline runner
# anat_skullstrip(l, args = [], opts = {})
def func_smooth(l, args = [], opts = {})
  cmdline = cli_wrapper(args, opts)
  l.info "Running: #{Pathname.new(__FILE__).basename} #{cmdline}"
  func_smooth!(cmdline, l)
end

def func_smooth!(cmdline = ARGV, l = nil)
  ###
  # USER ARGS
  ###

  # Process command-line inputs
  p = Trollop::Parser.new do
    banner "Usage: #{File.basename($0)} -i input --fwhm 4 -o output (--overwrite)\n"
    opt :fwhm, "FWHM or smoothness level to apply to input data", :type => :string, :required => true
    opt :input, "Path to input unsmoothed functional data", :type => :string, :required => true
    opt :mask, "Path to brain mask for functional data (will only smooth within the mask)", :type => :string, :required => true
    opt :output, "Path to output smoothed functional data", :type => :string, :required => true
    
    opt :threads, "Number of OpenMP threads to use with AFNI (otherwise defaults to environmental variable OMP_NUM_THREADS if set -> #{ENV['OMP_NUM_THREADS']})", :type => :integer
    
    opt :log, "Prefix for logging output to json and text files", :type => :string
    opt :ext, "File extensions to use in all outputs", :type => :string, :default => ".nii.gz"
    opt :overwrite, "Overwrite any output", :default => false
  end
  opts = Trollop::with_standard_exception_handling p do
    raise Trollop::HelpNeeded if cmdline.empty? # show help screen
    p.parse cmdline
  end

  # Gather inputs
  fwhm    = opts[:fwhm]
  input   = opts[:input].path.expand_path
  output  = opts[:output].path.expand_path
  mask    = opts[:mask].path.expand_path
  
  ext       = opts[:ext]
  overwrite = opts[:overwrite]
  
  threads   = opts[:threads]
  threads   = ENV['OMP_NUM_THREADS'].to_i if threads.nil? and not ENV['OMP_NUM_THREADS'].nil?
  
  log_prefix  = opts[:log]
  log_prefix  = log_prefix.path.expand_path unless log_prefix.nil?
  l           = create_logger(log_prefix, overwrite) if l.nil?    
  
  
  ###
  # RUN COMMANDS
  ###
  
  # Set AFNI_DECONFLICT
  set_afni_to_overwrite if overwrite
  # Set Threads
  set_omp_threads threads if not threads.nil?
  
  l.info "Checking inputs"
  quit_if_inputs_dont_exist l, input, mask

  l.info "Checking outputs"
  quit_if_all_outputs_exist_including(output) if not overwrite

  l.info "Blurring data"
  l.cmd "3dBlurInMask -input #{input} -FWHM #{fwhm} -mask #{mask} -prefix #{output}"
  
  # Unset AFNI_DECONFLICT
  reset_afni_deconflict if overwrite
end


if __FILE__==$0
  func_smooth!
end
