#!/usr/bin/env ruby
# 
#  reorient.rb
#  
#  This runs freesurfer to do the skull stripping.
#  
#  Created by Zarrar Shehzad on 2014-10-24
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
end

require 'for_commands.rb' # provides various function such as 'run'
require 'for_afni.rb' # provides various function such as 'run'



###
# DO IT
###

# Create a function that wraps around the cmdline runner
# anat_skullstrip(l, args = [], opts = {})
def anat_skullstrip(l, args = [], opts = {})
  #require 'pry'
  #binding.pry
  cmdline = cli_wrapper(args, opts)
  anat_skullstrip!(cmdline, l)
end

def anat_skullstrip!(cmdline = ARGV, l = nil)
  ###
  # USER ARGS
  ###
  
  #require 'pry'
  #binding.pry
  #puts cmdline.join(" ")
  
  # Process command-line inputs
  p = Trollop::Parser.new do
    banner "Usage: #{Pathname.new(__FILE__).basename} -h input_head.nii.gz -o output-directory -f freesurfer-subjects-directory (--log nil --ext .nii.gz --overwrite)\n"
    opt :head, "Input anatomical file", :type => :string, :required => true
    opt :freedir, "Freesurfer output subjects directory (inluding subject in path)", :type => :string, :required => true
    opt :outdir, "Output directory", :type => :string, :required => true
    opt :plot, "Produce plots (must also output mask)", :default => false
    
    opt :log, "Prefix for logging output to json and text files", :type => :string
    opt :ext, "File extensions to use in all outputs", :type => :string, :default => ".nii.gz"
    opt :overwrite, "Overwrite any output", :default => false
  end
  opts = Trollop::with_standard_exception_handling p do
    raise Trollop::HelpNeeded if cmdline.empty? # show help screen
    p.parse cmdline
  end

  # Gather inputs
  head    = opts[:head].path.expand_path
  outdir  = opts[:outdir].path.expand_path
  plot    = opts[:plot]

  freedir = opts[:freedir].path.expand_path
  sd      = freedir.dirname
  subject = freedir.basename
  
  ext        = opts[:ext]
  overwrite  = opts[:overwrite]
  log_prefix = opts[:log]
  log_prefix = log_prefix.path.expand_path unless log_prefix.nil?
  # Setup logger if needed
  l = create_logger(log_prefix, overwrite) if l.nil?
  
  bias    = "#{outdir}/brain_biascorrected#{ext}"
  brain   = "#{outdir}/brain#{ext}"
  mask    = "#{outdir}/brain_mask#{ext}"  
  
  ###
  # RUN COMMANDS
  ###
    
  l.info "Checking inputs"
  quit_if_inputs_dont_exist(l, head)
  sd.mkdir unless sd.directory?

  l.info "Checking outputs"
  if not overwrite
    quit_if_all_outputs_exist(l, brain) unless brain.nil?
    quit_if_all_outputs_exist(l, mask) unless mask.nil?
  end
  
  l.info "Setup"
  set_afni_to_overwrite if overwrite  # Set AFNI_DECONFLICT
  
  outputs_exist = File.exist?("#{freedir}/mri/brainmask.mgz")
  if not outputs_exist or overwrite  
    l.info "Run freesurfer (only up to skull-stripping)"
    l.cmd "recon-all -i #{head} -s #{subject} -sd #{sd} -autorecon1"
  else
    l.warn "Skipping freesurfer since outputs exist"
  end
  
  l.info "Copy freesurfer outputs to our output folder"
  l.cmd "mri_convert -rl #{freedir}/mri/rawavg.mgz -rt nearest #{freedir}/mri/brainmask.mgz #{bias}"
  l.cmd "3dcalc -a #{bias} -expr 'step(a)' -prefix #{mask}"
  l.cmd "3dcalc -a #{head} -b #{mask} -expr 'a*b' -prefix #{brain}"

  if plot
    l.info "Generate pretty plots"
    if overwrite
      sl_opts=" --force" # for slicer.py
    else
      sl_opts=""
    end
    l.cmd "slicer.py#{sl_opts} --crop -w 5 -l 4 -s axial #{head} #{outdir}/#{head.basename.rmext}_axial.png"
    l.cmd "slicer.py#{sl_opts} --crop -w 5 -l 4 -s sagittal #{head} #{outdir}/#{head.basename.rmext}_sagittal.png"
    l.cmd "slicer.py#{sl_opts} --crop -w 5 -l 4 -s axial --overlay #{mask} 1 1 -t #{head} #{mask.rmext}_axial.png"
    l.cmd "slicer.py#{sl_opts} --crop -w 5 -l 4 -s sagittal --overlay #{mask} 1 1 -t #{head} #{mask.rmext}_sagittal.png"
  end
  
  
  l.info "Clean-Up"
  reset_afni_deconflict if overwrite  # Unset AFNI_DECONFLICT
  
end

if __FILE__==$0
  anat_skullstrip!
end
