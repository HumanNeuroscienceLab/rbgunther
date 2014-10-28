#!/usr/bin/env ruby
# 
#  scale.rb
#  
#  This will scale the functional data so it is scaled to 100
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
def func_scale(l, args = [], opts = {})
  cmdline = cli_wrapper(args, opts)
  func_scale!(cmdline, l)
end

def func_scale!(cmdline = ARGV, l = nil)
  ###
  # USER ARGS
  ###

  # Process command-line inputs
  p = Trollop::Parser.new do
    banner "Usage: #{File.basename($0)} -i input -m mask -o output (--overwrite)\n"
    opt :input, "Path to input functional data", :type => :string, :required => true
    opt :mask, "Path to brain mask for functional data", :type => :string, :required => true
    opt :output, "Path to output scaled functional data", :type => :string, :required => true
    opt :savemean, "Saves intermediate mean functional image", :default => false
    opt :float, "Force output to be saved as float", :default => false
  
    opt :log, "Prefix for logging output to json and text files", :type => :string
    opt :ext, "File extensions to use in all outputs", :type => :string, :default => ".nii.gz"
    opt :overwrite, "Overwrite any output", :default => false
  end
  opts = Trollop::with_standard_exception_handling p do
    raise Trollop::HelpNeeded if cmdline.empty? # show help screen
    p.parse cmdline
  end

  # Gather inputs
  input   = opts[:input].path.expand_path
  output  = opts[:output].path.expand_path
  mask    = opts[:mask].path.expand_path
  save    = opts[:savemean]
  tofloat = opts[:float]

  mean_epi= "#{input.to_s.rmext}_mean.nii.gz"
  
  ext       = opts[:ext]
  overwrite = opts[:overwrite]
  
  log_prefix  = opts[:log]
  log_prefix  = log_prefix.path.expand_path unless log_prefix.nil?
  l           = create_logger(log_prefix, overwrite) if l.nil?
  
  
  ###
  # RUN COMMANDS
  ###

  # scale each voxel time series to have a mean of 100
  # (be sure no negatives creep in)
  # (subject to a range of [0,200])

  # Set AFNI_DECONFLICT
  set_afni_to_overwrite if overwrite

  l.info "Checking inputs"
  quit_if_inputs_dont_exist l, input, mask

  l.info "Checking outputs"
  quit_if_all_outputs_exist(l, output) if not overwrite

  l.info "Calculating mean"
  l.cmd "3dTstat -prefix #{mean_epi} #{input}"

  l.info "Scaling data"
  cmd = "3dcalc -a #{input} -b #{mean_epi} -c #{mask} \
  -expr 'c * min(200, a/b*100)*step(a)*step(b)' \
  -prefix #{output}"
  cmd += " -datum float" if tofloat
  l.cmd cmd

  l.info "Cleaning up"
  l.cmd "rm -f #{mean_epi}" if not save
  
  # Unset AFNI_DECONFLICT
  reset_afni_deconflict if overwrite
end


if __FILE__==$0
  func_scale!
end
