#!/usr/bin/env ruby
# 
#  gen_applywarp.rb
#  
#  Applies your registration to your data. 
#  Assumes that the relevant registration has been run (EPI->Anat or Anat->Std)
#
#  Created by Zarrar Shehzad on 2014-10-07
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
  DDIR        = SCRIPTDIR + "data/"

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
# anat_register_to_standard(l, args = [], opts = {})
def gen_applywarp(l, args=[], opts={})
  cmdline = cli_wrapper(args, opts)
  l.info "Running: #{Pathname.new(__FILE__).basename} #{cmdline}"
  gen_applywarp!(cmdline)
end

def gen_applywarp!(cmdline = ARGV, l = nil)
  ###
  # USER ARGS
  ###
  
  # Process command-line inputs
  p = Trollop::Parser.new do
    banner "Usage: #{File.basename($0)} -i source_image.nii.gz -r regdir -w transform_string -o output_image.nii.gz (--interp mode --dxyz voxel_size_in_mm --overwrite)\n"
    opt :input, "Source image that is to be transformed", :type => :string, :required => true
    opt :reg, "Outputs of previously run registration (assumes that non-linear has been run for anat-to-standard)", :type => :string, :required => true
    opt :warp, "Type of warp to use, can be exfunc, highres, or standard in the form of X-to-Y (e.g., highres-to-standard)", :type => :string, :required => true
    opt :linear, "Only use linear (not non-linear) registration for highres-to-standard (default: false or nonlinear)", :default => false
    opt :mcfile, "For raw EPI run data, you must specify the transforms for motion correction", :type => :string
  
    opt :output, "Output transformed image", :type => :string, :required => true
    opt :interp, "Final interpolation to use (for afni this means the --ainterp or --final) and can be NN, linear, cubic, quintic, or wsinc5", :type => :string
    opt :dxyz, "Grid of output, for instance if you want 2.5mm spacing to match your EPI", :type => :string
    opt :short, "Will force output to be shorts (default: auto)", :default => false
    opt :float, "Will force output to be floats (default: auto)", :default => false
    
    opt :threads, "Number of OpenMP threads to use with AFNI (otherwise defaults to environmental variable OMP_NUM_THREADS if set -> #{ENV['OMP_NUM_THREADS']})", :type => :integer
    
    opt :log, "Prefix for logging output to json and text files", :type => :string
    opt :ext, "File extensions to use in all inputs", :type => :string, :default => ".nii.gz"
    opt :overwrite, "Overwrite any output", :default => false
  end
  opts = Trollop::with_standard_exception_handling p do
    raise Trollop::HelpNeeded if cmdline.empty? # show help screen
    p.parse cmdline
  end

  # Gather inputs
  input   = opts[:input].path.expand_path
  regdir  = opts[:reg].path.expand_path
  warp    = opts[:warp]
  linear  = opts[:linear]
  run     = opts[:run]
  mcfile  = opts[:mcfile]
  mcfile  = mcfile.path.expand_path if not mcfile.nil?

  output  = opts[:output].path.expand_path
  interp  = opts[:interp]
  dxyz    = opts[:dxyz]

  if opts[:short] and opts[:float]
    abort "Cannot specify both --short and --float"
  end

  ext     = opts[:ext]
  overwrite = opts[:overwrite]
  
  threads   = opts[:threads]
  threads   = ENV['OMP_NUM_THREADS'].to_i if threads.nil? and not ENV['OMP_NUM_THREADS'].nil?
  
  log_prefix = opts[:log]
  log_prefix = log_prefix.path.expand_path unless log_prefix.nil?
  # Setup logger if needed
  l = create_logger(log_prefix, overwrite) if l.nil?


  ###
  # Checks and Setup
  ###

  l.info "Setup"
  # Set AFNI_DECONFLICT
  set_afni_to_overwrite if overwrite
  # Set Threads
  set_omp_threads threads if not threads.nil?
  
  l.info "Process warp input"
  warp_list = warp.split("-")
  l.fatal("Error in parsing #{warp}. Must be X-to-Y.") if warp_list.count != 3
  source = warp_list[0]
  target = warp_list[2]
  warp_opts = ["exfunc", "highres", "standard"] # to check
  l.fatal("Incorrect source: #{source}. Must be exfunc, highres, or standard") if not warp_opts.include? source
  l.fatal("Incorrect target: #{target}. Must be exfunc, highres, or standard") if not warp_opts.include? target

  l.info "Checking inputs"
  quit_if_inputs_dont_exist l, input, regdir

  l.info "Checking outputs"
  quit_if_all_outputs_exist(l, output) if not overwrite

  l.info "Changing directory to '#{regdir}'"
  Dir.chdir regdir


  ###
  # Apply Non-Linear (for now) Registration
  ###

  l.info "Apply registration"

  if (target == "standard" or source == "standard") and not linear
    l.info "Non-Linear: #{source} => #{target}"
    
    cmd = "3dNwarpApply \
    -source #{input} \
    -master #{target}#{ext}"
  
    if target == "standard"
      nwarp = "highres2standard_WARP#{ext} #{source}2#{target}.1D"
    else
      nwarp = "standard2highres_WARP#{ext} #{source}2#{target}.1D"
    end
    nwarp += " #{mcfile}" if not mcfile.nil?
    cmd += " -nwarp '#{nwarp}'"

    cmd += " -dxyz #{dxyz}" if not dxyz.nil?
    cmd += " -ainterp #{interp}" if not interp.nil?
    cmd += " -short" if opts[:short]
    cmd += " -prefix #{output}"
  
    l.cmd cmd
  else # source/target are func or highres
    l.info "Linear: #{source} => #{target}"
  
    # catenate volreg, epi2anat and tlrc transformations
    if mcfile.nil?
      matfile = "#{source}2#{target}.1D"
    else
      tmpfile = Tempfile.new("mc_#{source}2#{target}") 
      matfile = tmpfile.path
      l.cmd "cat_matvec -ONELINE \
      #{source}2#{target}.1D \
      #{mcfile} > #{matfile}"
    end
  
    cmd = "3dAllineate \
    -source #{input} \
    -master #{target}#{ext} \
    -1Dmatrix_apply #{matfile}"
  
    cmd += " -mast_dxyz #{dxyz}" if not dxyz.nil?
    cmd += " -final #{interp}" if not interp.nil?
    cmd += " -float" if opts[:float]
    cmd += " -prefix #{output}"
  
    l.cmd cmd
    
    # If force short, then do the following:
    if opts[:short]
      cmd "3dcalc -overwrite -a #{output} -expr 'a' -short"
      l.cmd(cmd)
    end
  end

  
  ###
  # Clean Up
  ###

  l.title "Clean Up"

  # Unset AFNI_DECONFLICT
  reset_afni_deconflict if overwrite
end


# If script called from the command-line
if __FILE__==$0
  gen_applywarp!
end
