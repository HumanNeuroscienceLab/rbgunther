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
  
  # GLOBAL
  sub_commands = %w(afni fsl)
  global_opts = Trollop::options do
    banner "Register highres to standard."
    
    banner "\nOptions common to all registration approaches are given first followed by the name of the approach (afni or fsl) to use and then approach specific options. In the usage, anything in [] are required options while anything in () are optional."
    
    banner "\nUsage: #{File.basename($0)} [-i anat_brain.nii.gz -o output_directory] (--template MNI152_T1_2mm_brain.nii.gz --ext .nii.gz --log log_outprefix --overwrite) [method] (afni: --threads num_of_threads) (fsl: --input-head highres_head.nii.gz --template-head MNI152_T1_2mm.nii.gz) (ants: --threads num_of_threads)"
    
    banner "\n#{File.basename($0)} ... afni --help"
    banner "\n#{File.basename($0)} ... fsl --help"
    banner ""
    
    opt :input, "Anatomical brain or could be any other input", :type => :string, :required => true
    opt :template, "Template brain to be the target of warping", :type => :string, :default => File.join(ENV['FSLDIR'], "data", "standard", "MNI152_T1_2mm_brain.nii.gz")
    opt :output, "Path to output directory", :type => :string, :required => true
    
    opt :log, "Prefix for logging output to json and text files", :type => :string
    opt :ext, "File extensions to use in all inputs", :type => :string, :default => ".nii.gz"
    opt :overwrite, "Overwrite any output", :default => false
    
    stop_on sub_commands
  end

  cmd = ARGV.shift # get the subcommand
  cmd_opts = case cmd
    when "afni" # parse delete options
      Trollop::options do
        opt :threads, "Number of OpenMP threads to use with AFNI (otherwise defaults to environmental variable OMP_NUM_THREADS if set -> #{ENV['OMP_NUM_THREADS']}) (only method afni)", :type => :integer
      end
    when "fsl"  # parse copy options
      Trollop::options do
        opt :input_head, "Input anatomical with head (only method fsl)", :type => :string, :required => true
        opt :template_head, "Template head to be the target of warping (only method fsl)", :type => :string, :default => File.join(ENV['FSLDIR'], "data", "standard", "MNI152_T1_2mm.nii.gz")
        opt :template_mask, "Template head to be the target of warping (only method fsl)", :type => :string, :default => File.join(ENV['FSLDIR'], "data", "standard", "MNI152_T1_2mm_brain_mask_dil.nii.gz")
      end
    when "ants"
      Trollop::options do
        opt :threads, "Number of threads to use with ANTS (otherwise defaults to 1) (only method ants)", :type => :integer
      end
    else
      Trollop::die "unknown subcommand #{cmd.inspect}"
    end

  puts "Global options: #{global_opts.inspect}"
  puts "Subcommand: #{cmd.inspect}"
  puts "Subcommand options: #{cmd_opts.inspect}"
  puts "Remaining arguments: #{ARGV.inspect}"
  
  # Combine options
  method = cmd
  opts = global_opts.merge(cmd_opts)
  

  # Gather inputs
  input   = opts[:input].path.expand_path
  template= opts[:template].path.expand_path
  outdir  = opts[:output].path.expand_path
  
  anat_head  = opts[:input_head]
  anat_head  = anat_head.path.expand_path if not anat_head.nil?
  template_head  = opts[:template_head]
  template_head  = template_head.path.expand_path if not template_head.nil?
  template_mask  = opts[:template_mask]
  template_mask  = template_mask.path.expand_path if not template_mask.nil?
  
  ext        = opts[:ext]
  overwrite  = opts[:overwrite]
  log_prefix = opts[:log]
  log_prefix = log_prefix.path.expand_path unless log_prefix.nil?
  
  threads   = opts[:threads]
  if method == "afni"
    threads   = ENV['OMP_NUM_THREADS'].to_i if threads.nil? and not ENV['OMP_NUM_THREADS'].nil?
  elsif method == "ants"
    threads   = 1 if threads.nil?
  end
  
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
  if method == "afni"
    # Set AFNI_DECONFLICT
    set_afni_to_overwrite if overwrite
    # Set Threads
    set_omp_threads threads if not threads.nil?
  end
  
  
  ###
  # Setup Standard Brain
  ###
  
  l.cmd "3dcopy #{template} standard#{ext}"
  
  
  ###
  # Setup Anatomical Brain
  ###
  
  l.cmd "3dcopy #{input} highres#{ext}"
  
  
  if method == "afni"
    
    l.info "Unifize the standard brain"
    l.cmd "3dUnifize -input standard#{ext} -GM -prefix standard_unifized#{ext}"
    
    l.info "Unifize anatomical brain"
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
  
  elsif method == "fsl"
    
    ###
    # Setup Anatomical
    ###

    l.info "Setup heads and mask"
    l.cmd "3dcopy #{anat_head} highres_head#{ext}"
    l.cmd "3dcopy #{template_head} standard_head#{ext}"
    l.cmd "3dcopy #{template_mask} standard_mask#{ext}"
    
    
    ###
    # Do Linear Registration
    ###
    
    l.info "Linear registration"
    l.cmd "flirt \
    -in highres \
    -ref standard \
    -out highres2standard_linear \
    -omat highres2standard.mat \
    -cost corratio \
    -dof 12 -searchrx -90 90 -searchry -90 90 -searchrz -90 90 \
    -interp trilinear"
    
    l.info "Inverting affine matrix"
    l.cmd "convert_xfm -inverse -omat standard2highres.mat highres2standard.mat"
    
    
    ###
    # Do Linear Registration
    ###
    
    l.info "Non-linear registration"
    l.cmd "fnirt \
    --iout=highres2standard_head \
    --in=highres_head \
    --aff=highres2standard.mat \
    --cout=highres2standard_warp \
    --iout=highres2standard \
    --jout=highres2highres_jac \
    --config=T1_2_MNI152_2mm \
    --ref=standard_head \
    --refmask=standard_mask \
    --warpres=10,10,10"
    
    l.info "Apply non-linear registration"
    l.cmd "applywarp -i highres -r standard -o highres2standard -w highres2standard_warp"
    
    l.info "Invert non-linear warp"
    l.cmd "invwarp -w highres2standard_warp -r highres_head -o standard2highres_warp"
  
  elsif method == "ants"
    ENV['ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS'] = threads
  
    l.info "Register"
    l.cmd "antsRegistrationSyNQuick.sh -d 3 -f standard#{ext} -m highres#{ext} \
      -o ants_output -t s"
        
    l.info "Rename files"
    l.cmd "mv ants_output0GenericAffine.mat highres2standard.mat"
    l.cmd "3dcopy ants_output1InverseWarp.nii.gz standard2highres_warp#{ext}"
    l.cmd "3dcopy ants_output1Warp.nii.gz highres2standard_warp#{ext}"
    l.cmd "3dcopy ants_outputInverseWarped.nii.gz standard2highres#{ext}"
    l.cmd "3dcopy ants_outputWarped.nii.gz highres2standard#{ext}"
    l.cmd "rm ants_output*"
    
    l.info "Apply linear registration"
    l.cmd "antsApplyTransforms -d 3 -o highres2standard_linear.nii.gz \
      -t highres2standard.mat -r standard#{ext} -i highres#{ext}"
    
    l.info "Invert affine transformation"
    l.cmd "antsApplyTransforms -d 3 -o Linear[standard2highres.mat,1] \
      -t highres2standard.mat"
    
    l.info "Collapse transformations"    
    l.cmd "antsApplyTransforms -d 3 -o [highres2standard_collapsed_warp#{ext},1] \
      -t highres2standard_warp#{ext} -t highres2standard.mat \
      -r standard#{ext}"
    l.cmd "antsApplyTransforms -d 3 -o [standard2highres_collapsed_warp#{ext},1] \
      -t standard2highres.mat -t standard2highres_warp#{ext} \
      -r highres#{ext}"
  end


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
  if method == "afni"
    # Unset AFNI_DECONFLICT
    reset_afni_deconflict if overwrite
  end
end



# If script called from the command-line
if __FILE__==$0
  anat_register_to_standard!
end

