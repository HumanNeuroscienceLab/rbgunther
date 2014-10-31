#!/usr/bin/env ruby
# 
#  func_combine_runs.rb
#  
#  This script combines the imaging data and timing data across runs
#  using 3dDeconvolve (removing run effects) and timing_tool.py, respectively
#
#  Created by Zarrar Shehzad on 2014-10-14
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
def func_combine_runs(l, args = [], opts = {})
  cmdline = cli_wrapper(args, opts)
  l.info "Running: #{Pathname.new(__FILE__).basename} #{cmdline}"
  func_combine_runs!(cmdline, l)
end

def func_combine_runs!(cmdline = ARGV, l = nil)
  ###
  # USER ARGS
  ###

  # Process command-line inputs
  p = Trollop::Parser.new do
    banner "Usage: #{File.basename($0)} -i func-file1 ... func-fileN -m mask-file -o output-directory --tr 1 (--motion file --polort 2 --njobs 1 --overwrite)\n"
    opt :inputs, "Path to functional runs to combine", :type => :strings, :required => true
    opt :mask, "Path to mask", :type => :string, :required => true
    opt :outprefix, "Output prefix", :type => :string, :required => true
    opt :tr, "TR of data in seconds", :type => :string, :required => true
    opt :motion, "Path to 6 parameter motion time-series file (already concatenated across subjects). If provided, this will regress out motion effects.", :type => :string
    opt :polort, "Number of orthogonal polynomials (default of 2 includes mean, linear, and quadratic)", :default => 2
    opt :njobs, "Number of jobs to run in parallel", :default => 1
  
    opt :log, "Prefix for logging output to json and text files", :type => :string
    opt :ext, "File extensions to use in all outputs", :type => :string, :default => ".nii.gz"  
    opt :overwrite, "Overwrite existing output", :default => false
  end
  opts = Trollop::with_standard_exception_handling p do
    raise Trollop::HelpNeeded if cmdline.empty? # show help screen
    p.parse cmdline
  end

  # Gather inputs
  inputs  = opts[:inputs].collect{|input| input.path.expand_path}
  nruns	  = inputs.count
  mask    = opts[:mask].path.expand_path 
  outprefix= opts[:outprefix].path.expand_path
  tr      = opts[:tr]
  motion  = opts[:motion]
  motion  = motion.path.expand_path if not motion.nil?
  polort  = opts[:polort]
  njobs   = opts[:njobs]
  
  ext       = opts[:ext]
  overwrite = opts[:overwrite]
  
  log_prefix  = opts[:log]
  log_prefix  = log_prefix.path.expand_path unless log_prefix.nil?
  l           = create_logger(log_prefix, overwrite) if l.nil?
  
  # Additional paths
  outmat  = "#{outprefix}_design.1D"
  outpic  = "#{outprefix}_design.jpg"
  outdat  = "#{outprefix}#{ext}"
  outmean = "#{outprefix}_mean#{ext}"


  ###
  # RUN COMMANDS
  ###

  l.info "Setup"

  set_afni_to_overwrite if overwrite

  l.info "Checking inputs"
  quit_if_inputs_dont_exist(l, *inputs)
  quit_if_inputs_dont_exist(l, mask)
  quit_if_inputs_dont_exist(l, motion) unless motion.nil?

  l.info "Checking outputs"
  quit_if_all_outputs_exist(l, outmat, outpic, outdat, outmean) unless overwrite
  
  
  ###
  # Combine Runs
  ###

  l.info "Combine Runs"

  l.info "Deconvolve"

  if motion.nil?
    l.cmd "3dDeconvolve \
          -input #{inputs.join(' ')} \
          -mask #{mask} \
          -force_TR #{tr} \
          -polort #{polort} \
          -jobs #{njobs} \
          -noFDR \
          -nobucket \
          -x1D #{outmat} \
          -xjpeg #{outpic} \
          -errts  #{outdat}"
  else
    l.cmd "3dDeconvolve \
          -input #{inputs.join(' ')} \
          -mask #{mask} \
          -force_TR #{tr} \
          -polort #{polort} \
          -num_stimts 6 \
          -stim_file 1 #{motion}'[0]' -stim_base 1 -stim_label 1 roll  \
          -stim_file 2 #{motion}'[1]' -stim_base 2 -stim_label 2 pitch \
          -stim_file 3 #{motion}'[2]' -stim_base 3 -stim_label 3 yaw   \
          -stim_file 4 #{motion}'[3]' -stim_base 4 -stim_label 4 dS    \
          -stim_file 5 #{motion}'[4]' -stim_base 5 -stim_label 5 dL    \
          -stim_file 6 #{motion}'[5]' -stim_base 6 -stim_label 6 dP    \
          -jobs #{njobs} \
          -noFDR \
          -nobucket \
          -x1D #{outmat} \
          -xjpeg #{outpic} \
          -errts  #{outdat}"
  end

  l.info "Add back mean"
  l.cmd "3dTcat -prefix #{outprefix}_tmp_all_runs#{ext} #{inputs.join(' ')}"
  l.cmd "3dTstat -mean -prefix #{outmean} #{outprefix}_tmp_all_runs#{ext}"
  l.cmd "3dcalc -overwrite -a #{outdat} -b #{outmean} -c #{mask} -expr '(a+b)*step(c)' -prefix #{outdat}"
  l.cmd "rm -f #{outprefix}_tmp_all_runs#{ext}"


  ###
  # Finalize
  ###

  l.info "Cleaning up"
  
  reset_afni_deconflict if overwrite
end


if __FILE__==$0
  func_combine_runs!
end
