#!/usr/bin/env ruby
# 
#  skullstrip.rb
#  
#  Removes the non-brain portions of your EPI image.
#  
#  Created by Zarrar Shehzad on 2014-10-05
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
def func_skullstrip(l, args = [], opts = {})
  cmdline = cli_wrapper(args, opts)
  func_skullstrip!(cmdline, l)
end

def func_skullstrip!(cmdline = ARGV, l = nil)
  ###
  # USER ARGS
  ###

  # Process command-line inputs
  p = Trollop::Parser.new do
    banner "Usage: #{File.basename($0)} -h input_head.nii.gz -b output_brain.nii.gz -m output_brain_mask.nii.gz (--dilate 1 --overwrite)\n"
    opt :head, "Input head file", :type => :string, :required => true
    opt :brain, "Output brain file", :type => :string
    opt :mask, "Output mask file", :type => :string
    opt :dilate, "Amount to dilate brain", :default => 1
    opt :plot, "Produce plots (must also output mask)", :default => false
  
    opt :log, "Prefix for logging output to json and text files", :type => :string
    opt :ext, "File extensions to use in all outputs", :type => :string, :default => ".nii.gz"
    opt :overwrite, "Overwrite any output (TODO)", :default => false
  end
  opts = Trollop::with_standard_exception_handling p do
    raise Trollop::HelpNeeded if cmdline.empty? # show help screen
    p.parse cmdline
  end

  # Gather inputs
  head    = opts[:head].path.expand_path
  brain   = opts[:brain]
  brain   = brain.path.expand_path unless brain.nil?
  mask    = opts[:mask]
  mask    = mask.path.expand_path unless mask.nil?
  dilate  = opts[:dilate]
  plot    = opts[:plot]

  ext     = opts[:ext]
  overwrite = opts[:overwrite]
  
  log_prefix  = opts[:log]
  log_prefix  = log_prefix.path.expand_path unless log_prefix.nil?
  l           = create_logger(log_prefix, overwrite) if l.nil?
  
  
  ###
  # RUN COMMANDS
  ###

  # Set AFNI_DECONFLICT
  set_afni_to_overwrite if overwrite

  l.info "Checking inputs"
  quit_if_inputs_dont_exist l, head

  l.info "Checking outputs"
  l.fatal("One output must be specified") if brain.nil? and mask.nil?
  if not overwrite
    quit_if_all_outputs_exist(l, brain) if not brain.nil?
    quit_if_all_outputs_exist(l, mask) if not mask.nil?
  end
  # Since AFNI always outputs the mask image, we will give one if it doesn't exist
  orig_mask = mask
  mask = Tempfile.new('mask').path.path.expand_path if mask.nil?

  l.info "Running command"
  cmd = "3dAutomask -dilate #{dilate} -prefix #{mask}"
  cmd += " -apply_prefix #{brain}" if not brain.nil?
  cmd += " #{head}"
  l.cmd cmd

  if plot
    l.info "Plotting"
    sl_opts = " --crop --scale 2"  
    sl_opts += " --force" if overwrite
    l.cmd "slicer.py#{sl_opts} -w 4 -l 3 -s axial #{head} #{mask.dirname}/#{head.basename.rmext}_axial.png"
    l.cmd "slicer.py#{sl_opts} -w 4 -l 3 -s sagittal #{head} #{mask.dirname}/#{head.basename.rmext}_sagittal.png"
    l.cmd "slicer.py#{sl_opts} -w 4 -l 3 -s axial --overlay #{mask} 1 1 -t #{head} #{mask.rmext}_axial.png"
    l.cmd "slicer.py#{sl_opts} -w 4 -l 3 -s sagittal --overlay #{mask} 1 1 -t #{head} #{mask.rmext}_sagittal.png"
  end

  l.info "Cleaning up outputs"
  File.delete(mask) if orig_mask.nil?

  # Unset AFNI_DECONFLICT
  reset_afni_deconflict if overwrite
end


if __FILE__==$0
  func_skullstrip!
end
