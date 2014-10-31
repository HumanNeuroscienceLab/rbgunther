#!/usr/bin/env ruby
# 
#  func_register_to_standard.rb
#  
#  The script depends on already completed functional and anatomical registrations.
#  
#  Given those outputs as inputs, it will:
#  - copy over files from the anat-to-std registration into the current functional directory
#  - combine func-anat-standard transforms
#  - invert the combined transform
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
def func_register_to_standard(l, args = [], opts = {})
  cmdline = cli_wrapper(args, opts)
  l.info "Running: #{Pathname.new(__FILE__).basename} #{cmdline}"
  func_register_to_standard!(cmdline, l)
end

def func_register_to_standard!(cmdline = ARGV, l = nil)
  ###
  # USER ARGS
  ###

  # Process command-line inputs
  p = Trollop::Parser.new do
    banner "Usage: #{File.basename($0)} -e func-regdir -a anat-regdir (--overwrite)\n"
    opt :epireg, "Outputs of previously run func-to-highres registration directory", :type => :string, :required => true
    opt :anatreg, "Outputs of previously run highres-to-standard registration directory (assumes that non-linear has been run)", :type => :string, :required => true
    
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
  epi_regdir  = opts[:epireg].path.expand_path
  anat_regdir = opts[:anatreg].path.expand_path
  
  ext         = opts[:ext]
  overwrite   = opts[:overwrite]
  
  threads   = opts[:threads]
  threads   = ENV['OMP_NUM_THREADS'].to_i if threads.nil? and not ENV['OMP_NUM_THREADS'].nil?
  
  log_prefix  = opts[:log]
  log_prefix  = log_prefix.path.expand_path unless log_prefix.nil?
  l           = create_logger(log_prefix, overwrite) if l.nil?


  ###
  # RUN COMMANDS
  ###
  
  ###
  # Checks and Setup
  ###

  l.info "Checks and Setup"

  # Set AFNI_DECONFLICT
  set_afni_to_overwrite if overwrite
  # Set Threads
  set_omp_threads threads if not threads.nil?

  l.info "Checking inputs"
  quit_if_inputs_dont_exist l, epi_regdir, anat_regdir

  # TODO: check anat inputs
  # TODO: check outputs

  #puts "\n== Checking outputs".magenta
  #quit_if_all_outputs_exist(l, workdir) if not overwrite
  #quit_if_all_outputs_exist(l, regmat, epi2anat) if not overwrite

  l.info "Changing directory to #{epi_regdir}"
  Dir.chdir epi_regdir


  ###
  # Copy over anat inputs
  ###

  l.info "Soft-link anatomical inputs"

  FileUtils.ln_sf Dir.glob("#{anat_regdir}/*"), epi_regdir, :verbose => true
  # TODO: only soft-link needed files


  ###
  # Combine transforms
  ###

  l.info "Combining epi-to-anat and anat-to-std affine transforms"
  l.cmd "3dNwarpCat -prefix exfunc2standard.1D -warp2 exfunc2highres.1D -warp1 highres2standard.1D"


  ###
  # Invert transform
  ###

  l.info "Inverting exfunc2standard"
  l.cmd "3dNwarpCat -prefix standard2exfunc.1D -iwarp -warp1 exfunc2standard.1D"


  ###
  # Apply transforms
  ###

  l.info "Apply transforms"

  l.info "Linear"
  l.cmd "3dAllineate \
  -source exfunc#{ext} \
  -master standard#{ext} \
  -1Dmatrix_apply exfunc2standard.1D \
  -prefix exfunc2standard_linear#{ext}"
  
  l.info "Non-Linear"
  l.cmd "3dNwarpApply \
  -nwarp 'highres2standard_WARP#{ext} exfunc2standard.1D' \
  -source exfunc#{ext} \
  -master standard#{ext} \
  -prefix exfunc2standard#{ext}"
  
  
  ###
  # Pictures
  ###

  l.info "Pretty Pictures"
  
  if overwrite
    sl_opts=" --force" # for slicer.py
  else
    sl_opts=""
  end
  l.info "slicer.py#{sl_opts} --auto -r standard#{ext} exfunc2standard_linear#{ext} exfunc2standard_linear.png"
  l.info "slicer.py#{sl_opts} --auto -r standard#{ext} exfunc2standard#{ext} exfunc2standard.png"
  
  
  ###
  # Quality Check
  ###
  
  l.info "Correlating highres with standard"
  
  cor_lin = `3ddot -docor -mask standard#{ext} exfunc2standard_linear#{ext} standard#{ext}`.strip.to_f
  cor_nonlin = `3ddot -docor -mask standard#{ext} exfunc2standard#{ext} standard#{ext}`.strip.to_f
  
  l.info "linear exfunc2standard vs standard: #{cor_lin}"
  l.info "non-linear exfunc2standard vs standard: #{cor_nonlin}"
  
  l.info "saving quality measure to file: quality_exfunc2standard.txt"
  File.open('quality_exfunc2standard.txt', 'w') do |f1|
    f1.puts "#{cor_lin} # linear exfunc2standard vs standard\n"
    f1.puts "#{cor_nonlin} # non-linear exfunc2standard vs standard"
  end


  ###
  # Clean up
  ###

  l.info "Clean up"

  # Unset AFNI_DECONFLICT
  reset_afni_deconflict if overwrite
end


if __FILE__==$0
  func_register_to_standard!
end
