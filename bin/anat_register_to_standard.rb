#!/usr/bin/env ruby
# 
#  anat_register_to_standard.rb
#  
#  Created by Zarrar Shehzad on 2014-10-01
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
# anat_register_to_standard(l, args = [], opts = {})
def anat_register_to_standard(l, args = [], opts = {})
  cmdline = cli_wrapper(args, opts)
  l.info "Running: #{Pathname.new(__FILE__).basename} #{cmdline}"
  anat_register_to_standard!(cmdline, l)
end

def anat_register_to_standard!(cmdline = ARGV, l = nil)
  ###
  # USER ARGS
  ###
  
  # Process command-line inputs
  p = Trollop::Parser.new do
    banner "Usage: #{Pathname.new(__FILE__).basename} -i anat_brain.nii.gz -o output_directory (--overwrite)\n"
    opt :input, "Anatomical brain or could be any other input", :type => :string, :required => true
    opt :template, "Template brain to be the target of warping", :type => :string, :default => File.join(ENV['FSLDIR'], "data", "standard", "MNI152_T1_1mm_brain.nii.gz")
    opt :output, "Path to output directory", :type => :string, :required => true
    
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
  input   = opts[:input].path.expand_path
  template= opts[:template].path.expand_path
  outdir  = opts[:output].path.expand_path

  ext        = opts[:ext]
  overwrite  = opts[:overwrite]
  log_prefix = opts[:log]
  log_prefix = log_prefix.path.expand_path unless log_prefix.nil?
  
  threads   = opts[:threads]
  threads   = ENV['OMP_NUM_THREADS'].to_i if threads.nil? and not ENV['OMP_NUM_THREADS'].nil?
  
  # Setup logger if needed
  l = create_logger(log_prefix, overwrite) if l.nil?
  
  
  ###
  # RUN COMMANDS
  ###
  
  ###
  # Checks and Setup
  ###

  l.info "Checking inputs"
  quit_if_inputs_dont_exist(l, input, template)

  l.info "Checking outputs"
  quit_if_all_outputs_exist(l, outdir) if not overwrite
  outdir.mkdir if not outdir.directory?

  l.info "Changing directory to #{outdir}"
  Dir.chdir outdir

  l.info "Setup"
  # Set AFNI_DECONFLICT
  set_afni_to_overwrite if overwrite
  # Set Threads
  set_omp_threads threads if not threads.nil?


  ###
  # Setup Standard Brain
  ###

  l.info "Unifize the standard brain"
  l.cmd "3dcopy #{template} standard#{ext}"
  l.cmd "3dUnifize -input standard#{ext} -GM -prefix standard_unifized#{ext}"


  ###
  # Setup Anatomical Brain
  ###

  l.info "Unifize anatomical brain"
  l.cmd "3dcopy #{input} highres#{ext}"
  l.cmd "3dUnifize -GM -prefix highres_unifized#{ext} -input highres#{ext}"


  ###
  # Do Linear Registration
  ###

  l.info "Linear registration"
  # Parametric registration, linear interpolation by default for optimization, cubic interpolation for final transformation
  # Not sure if I need source automask
  l.cmd "3dAllineate \
  -source highres_unifized#{ext} -source_automask \
  -base standard_unifized#{ext} \
  -prefix highres2standard_linear#{ext} \
  -1Dmatrix_save highres2standard.1D \
  -twopass -cost lpa \
  -autoweight -fineblur 3 -cmass"

  l.info "Inverting affine matrix"
  l.cmd "3dNwarpCat -prefix standard2highres.1D -iwarp -warp1 highres2standard.1D"


  ###
  # Do Non-Linear Registration
  ###

  l.info "Non-Linear registration"

  # Non-parametric registration, uses cubic and Hermite quintic basis functions
  l.cmd "3dQwarp \
  -source highres2standard_linear#{ext} \
  -base standard_unifized#{ext} \
  -prefix highres2standard#{ext} \
  -duplo -useweight -nodset -blur 0 3"

  # Apply that warp to the original input
  l.cmd "3dNwarpApply \
  -nwarp 'highres2standard_WARP#{ext} highres2standard.1D' \
  -source highres#{ext} \
  -master standard#{ext} \
  -prefix highres2standard#{ext}"

  l.info "Inverting warp"
  l.cmd "3dNwarpCat -prefix standard2highres_WARP#{ext} -iwarp -warp1 highres2standard_WARP#{ext}"


  ###
  # Pictures
  ###

  l.info "Pretty pictures"

  if overwrite
    sl_opts=" --force" # for slicer.py
  else
    sl_opts=""
  end
  l.cmd "slicer.py#{sl_opts} --auto -r standard#{ext} highres2standard_linear#{ext} highres2standard_linear.png"
  l.cmd "slicer.py#{sl_opts} --auto -r standard#{ext} highres2standard#{ext} highres2standard.png"


  ###
  # Quality Check
  ###

  l.info "Correlating highres with standard for quality check"
  
  cor_lin = `3ddot -docor -mask standard#{ext} highres2standard_linear#{ext} standard#{ext}`.strip.to_f
  cor_nonlin = `3ddot -docor -mask standard#{ext} highres2standard#{ext} standard#{ext}`.strip.to_f
  
  l.info "linear highres2standard vs standard: #{cor_lin}"
  l.info "non-linear highres2standard vs standard: #{cor_nonlin}"
  
  l.info "saving results to file: #{outdir}/quality_highres2standard.txt"
  File.open('quality_highres2standard.txt', 'w') do |f1|
    f1.puts "#{cor_lin} # linear higres2standard vs standard\n"
    f1.puts "#{cor_nonlin} # non-linear higres2standard vs standard"
  end


  ###
  # Clean Up
  ###

  l.info "Clean up"
  # Unset AFNI_DECONFLICT
  reset_afni_deconflict if overwrite
end


# If script called from the command-line
if __FILE__==$0
  anat_register_to_standard!
end

