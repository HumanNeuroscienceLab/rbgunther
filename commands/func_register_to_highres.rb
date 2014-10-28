#!/usr/bin/env ruby
# 
#  func_register_to_highres.rb
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
  $: << SCRIPTDIR + "commands" unless $:.include?(SCRIPTDIR + "commands")
end

require 'for_commands.rb' # provides various function such as 'run'
require 'for_afni.rb' # provides various function such as 'run'


###
# DO IT
###

# Create a function that wraps around the cmdline runner
# anat_skullstrip(l, args = [], opts = {})
def func_register_to_highres(l, args = [], opts = {})
  cmdline = cli_wrapper(args, opts)
  func_register_to_highres!(cmdline, l)
end

def func_register_to_highres!(cmdline = ARGV, l = nil)
  ###
  # USER ARGS
  ###

  # Process command-line inputs
  p = Trollop::Parser.new do
    banner "Usage: #{File.basename($0)} -e example_func_brain.nii.gz -a highres_brain.nii.gz -o output-directory (-w working-directory)\n"
    opt :epi, "Input functional brain (must be skull stripped)", :type => :string, :required => true
    opt :anat, "Input anatomical brain (must be skull stripped)", :type => :string, :required => true  
    opt :output, "Path to output directory", :type => :string, :required => true
  
    opt :dof, "Degrees of Freedom: shift_only (3), shift_rotate (6), shift_rotate_scale (9), or affine_general (12)", :type => :string, :default => "shift_rotate_scale"
    opt :cost, "Cost Function", :type => :string, :default => "lpc+ZZ"
  
    opt :working, "Path to save working directory (at the end)", :type => :string
    
    opt :threads, "Number of OpenMP threads to use with AFNI (otherwise defaults to environmental variable OMP_NUM_THREADS if set -> #{ENV['OMP_NUM_THREADS']})", :type => :integer
    
    opt :log, "Prefix for logging output to json and text files", :type => :string
    opt :ext, "File extensions to use in all outputs", :type => :string, :default => ".nii.gz"
    opt :overwrite, "Overwrite existing output", :default => false
  end
  opts = Trollop::with_standard_exception_handling p do
    raise Trollop::HelpNeeded if cmdline.empty? # show help screen
    p.parse cmdline
  end

  # Gather inputs
  epi       = opts[:epi].path.expand_path
  anat      = opts[:anat].path.expand_path

  dof       = opts[:dof]
  cost      = opts[:cost]

  outdir    = opts[:output].path.expand_path
  workdir   = opts[:working]
  workdir.path.expand_path if not workdir.nil?
  
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
  
  ###
  # Checks and Setup
  ###

  l.info "Checks and Setup"

  l.info "Checking inputs"
  quit_if_inputs_dont_exist l, epi, anat

  l.info "Checking outputs"
  quit_if_all_outputs_exist l, outdir if not overwrite
  quit_if_all_outputs_exist l, workdir if not overwrite and not workdir.nil?

  l.info "Creating and changing into temporary working directory"
  Dir.mktmpdir do |tmpworkdir|
    l.info "Changing directory to #{tmpworkdir}"
    Dir.chdir tmpworkdir
  
    ###
    # Get inputs
    ###

    l.info "Copying Inputs"

    l.cmd "3dcopy #{epi} #{tmpworkdir}/exfunc+orig"
    l.cmd "3dcopy #{anat} #{tmpworkdir}/highres+orig"


    ###
    # Build and run the command
    ###

    l.info "Build and run main command"

    cmd = "align_epi_anat.py -epi2anat \
    -epi exfunc+orig -epi_base 0 -anat highres+orig \
    -master_epi BASE \
    -cost #{cost} \
    -deoblique on -volreg off -tshift off \
    -anat_has_skull no -epi_strip None \
    -big_move \
    -Allineate_opts '-weight_frac 1.0 -maxrot 10 -maxshf 10 -VERB -warp #{dof} ' \
    -suffix _out"
    l.cmd cmd
  
  
    ###
    # Copy outputs
    ###

    l.info "Set outputs"
  
    l.info "Creating output directory '#{outdir}' if needed"
    outdir.mkdir if not outdir.directory?
  
    l.info "Changing directory to #{outdir}"
    Dir.chdir outdir

    l.info "Copy files"
    if overwrite
      cp = "cp -f"
    else
      cp = "cp"
    end
    l.cmd "#{cp} #{tmpworkdir}/exfunc_out_mat.aff12.1D #{outdir}/exfunc2highres.1D" # transform mat
    # l.cmd "3dcopy #{tmpworkdir}/exfunc_out+orig #{outdir}/exfunc2highres#{ext}"     # transform img
    l.cmd "3dcopy #{epi} #{outdir}/exfunc#{ext}"
    l.cmd "3dcopy #{anat} #{outdir}/highres#{ext}"
  
    l.info "Transforming exfunc to highres in highres space"
    l.cmd "3dAllineate -input #{outdir}/exfunc#{ext} \
      -base #{outdir}/highres#{ext} \
      -1Dmatrix_apply #{outdir}/exfunc2highres.1D \
      -master BASE \
      -prefix #{outdir}/exfunc2highres#{ext}"
  
    l.info "Inverting affine matrix (highres -> func)"
    l.cmd "3dNwarpCat -prefix #{outdir}/highres2exfunc.1D -iwarp -warp1 #{outdir}/exfunc2highres.1D"
    
    
    ###
    # Copy working directory
    ###

    l.info "Cleaning Up"

    if not workdir.nil?
      l.info "Saving working directory"
      FileUtils.cp Dir.glob("#{tmpworkdir}/*"), workdir
  #    FileUtils.remove Dir.glob("#{tmpworkdir}/*"), :verbose => true
    end  
  end # end of temporary directory
  
  
  ###
  # Pictures
  ###

  l.info "Pretty Pictures"

  if overwrite
    sl_opts=" --force" # for slicer.py
  else
    sl_opts=""
  end

  l.cmd "slicer.py#{sl_opts} -r #{outdir}/highres#{ext} #{outdir}/exfunc2highres#{ext} #{outdir}/exfunc2highres.png"


  ###
  # Quality Check
  ###

  l.info "Correlating highres with standard"

  cor_lin = `3ddot -docor -mask #{outdir}/highres#{ext} #{outdir}/exfunc2highres#{ext} #{outdir}/highres#{ext}`.strip.to_f

  l.info "linear exfunc2highres vs highres: #{cor_lin}"
  l.info "saving this to file: #{outdir}/quality_exfunc2highres.txt"
  File.open('quality_exfunc2highres.txt', 'w') do |f1|
    f1.puts "#{cor_lin} # exfunc2highres vs highres\n"
  end
  
  # Unset AFNI_DECONFLICT
  reset_afni_deconflict if overwrite
end


if __FILE__==$0
  func_register_to_highres!
end
