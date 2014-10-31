#!/usr/bin/env ruby
# 
#  motion_correct.rb
#  
#  This script applies motion correction using AFNI's 3dvolreg across runs.
#  Correction is done to the average functional image in two stages.
#
#  Created by Zarrar Shehzad on 2014-09-01
# 

#require 'pry'
#binding.pry

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
def func_motion_correct(l, args = [], opts = {})
  cmdline = cli_wrapper(args, opts)
  l.info "Running: #{Pathname.new(__FILE__).basename} #{cmdline}"
  func_motion_correct!(cmdline, l)
end

def func_motion_correct!(cmdline = ARGV, l = nil)
  ###
  # USER ARGS
  ###

  # Process command-line inputs
  p = Trollop::Parser.new do
    banner "Usage: #{File.basename($0)} -o output-directory -w working-directory --keepworking -i func-file1 ... func-fileN\n"
    opt :inputs, "Path to functional runs to motion correct", :type => :strings, :required => true
    opt :outprefix, "Output prefix", :type => :string, :required => true
    opt :working, "Path to working directory", :type => :string, :required => true
    opt :keepworking, "Keep working directory", :default => false
  
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
  outprefix= opts[:outprefix].path.expand_path
  workdir = opts[:working].path.expand_path
  keepwork= opts[:keepworking]
  
  ext         = opts[:ext]
  overwrite   = opts[:overwrite]
  
  log_prefix  = opts[:log]
  log_prefix  = log_prefix.path.expand_path unless log_prefix.nil?
  l           = create_logger(log_prefix, overwrite) if l.nil?
  
  
  ###
  # RUN COMMANDS
  ###
  
  # Set AFNI_DECONFLICT
  set_afni_to_overwrite if overwrite

  ###
  # First Pass
  ###

  l.info "First Pass"

  l.info "Checking inputs"
  l.fatal("inputs don't exist") if any_inputs_dont_exist l, *inputs
  inputs = inputs.collect{|input| input.realpath}

  l.info "Checking outputs"
  l.fatal("working directory '#{workdir}' exists, exiting") if !overwrite and workdir.exist?
  l.fatal("some output files exist, exiting") if !overwrite and all_outputs_exist l, "#{outprefix}_run01_maxdisp.1D", "#{outprefix}_run01_dfile.1D", "#{outprefix}_run01_mat_vr_aff12.1D", "#{outprefix}_run01_epi_volreg#{ext}"
  outprefix.dirname.mkdir if not outprefix.dirname.directory?
  
  l.info "Changing directory to '#{workdir}'"
  workdir.mkdir if not workdir.directory?
  workdir = workdir.realpath
  Dir.chdir workdir
  
  inputs.each_with_index do |input,i|
  	ri = "%02i" % (i + 1)
  	l.info "Generate motion-corrected mean EPI for run #{ri}"
    # Mean EPI of non-motion-corrected data
  	l.cmd "3dTstat -mean -prefix iter0_mean_epi_r#{ri}#{ext} #{input}"
    # Apply motion correction to mean EPI
    l.cmd "3dvolreg -verbose -zpad 4 \
    	   -base iter0_mean_epi_r#{ri}#{ext} \
         -prefix iter0_epi_volreg_r#{ri}#{ext} \
         -cubic \
         #{input}"
    # New mean EPI of motion-corrected data
    l.cmd "3dTstat -mean -prefix iter1_mean_epi_r#{ri}#{ext} iter0_epi_volreg_r#{ri}#{ext}"
  end

  # Combine mean EPIs from each run
  l.info "Combine mean EPIs from each run"
  l.cmd "3dTcat -prefix iter1_mean_epis#{ext} iter1_mean_epi_r*#{ext}"

  # Get mean EPI across runs
  l.info "Get mean EPI across runs"
  l.cmd "3dTstat -mean -prefix iter1_mean_mean_epi#{ext} iter1_mean_epis#{ext}"


  ###
  # Second Pass
  ###

  l.info "Second Pass"
  
  # Register mean EPIs from each run to each other
  l.info "Motion correct the mean EPIs"
  l.cmd "3dvolreg -verbose -zpad 4 \
  	   -base iter1_mean_mean_epi#{ext} \
       -prefix iter2_mean_epis_volreg#{ext} \
       -cubic \
       iter1_mean_epis#{ext}"

  # Take the mean of motion-corrected mean EPIs
  l.info "Get mean EPI across the mean EPIs"
  l.cmd "3dTstat -mean -prefix iter2_mean_mean_epi#{ext} iter2_mean_epis_volreg#{ext}"


  ###
  # Third and Final Pass
  ###

  l.info "Third and Final Pass"

  inputs.each_with_index do |input,i|
  	ri = "%02i" % (i + 1)
  	l.info "Motion correct run #{ri}"
    # Apply motion correction to prior mean EPI
    l.cmd "3dvolreg -verbose -zpad 4 \
    	   -base iter2_mean_mean_epi#{ext} \
         -maxdisp1D iter3_maxdisp_r#{ri}.1D \
         -1Dfile iter3_dfile_r#{ri}.1D \
         -1Dmatrix_save iter3_mat_r#{ri}_vr_aff12.1D \
         -prefix iter3_epi_volreg_r#{ri}#{ext} \
         -twopass \
         -Fourier \
         #{input}"
    # New mean EPI of motion-corrected data
    l.cmd "3dTstat -mean -prefix iter3_mean_epi_r#{ri}#{ext} iter3_epi_volreg_r#{ri}#{ext}"
  end

  # Combine mean EPIs from each run
  l.info "Combine mean EPIs"
  l.cmd "3dTcat -prefix iter3_mean_epis#{ext} iter3_mean_epi_r*#{ext}"

  # Get mean EPI across runs
  l.info "Get mean EPI across runs"
  l.cmd "3dTstat -mean -prefix iter3_mean_mean_epi#{ext} iter3_mean_epis#{ext}"
  
  
  ###
  # Save
  ###

  l.info "Saving"
  
  # This takes as input a filename in the working directory
  # and then an output file
  # It will mv the file 
  # and then create a soft-link to from old to new location
  def move_file(l, infile, outfile)
    l.cmd "mv #{infile} #{outfile}"
    l.cmd "ln -s #{outfile} #{infile}"
  end
  
  # Here we move the relevant outputs and then create a soft-link in the working directory
  l.info "Save output files"
  inputs.each_with_index do |input,i|
  	ri = "%02i" % (i + 1)
  	l.info "run #{ri}"
    move_file l, "iter3_maxdisp_r#{ri}.1D", "#{outprefix}_run#{ri}_maxdisp.1D"
    move_file l, "iter3_dfile_r#{ri}.1D", "#{outprefix}_run#{ri}_dfile.1D"
    move_file l, "iter3_mat_r#{ri}_vr_aff12.1D", "#{outprefix}_run#{ri}_mat_vr_aff12.1D"
    move_file l, "iter3_epi_volreg_r#{ri}#{ext}", "#{outprefix}_run#{ri}_volreg#{ext}"
  end
  # make a single file of registration params and get mean
  l.cmd "cat iter3_dfile_r??.1D > #{outprefix}_runall_dfile.1D"
  move_file l, "iter3_mean_mean_epi#{ext}", "#{outprefix}_mean#{ext}"


  ###
  # Framewise Displacement
  ###

  l.info "Calculate framewise displacement"

  inputs.each_with_index do |input,i|
  	ri = "%02i" % (i + 1)
  	l.info "run #{ri}"
    l.cmd "python #{CDIR}func_motion_fd.py #{outprefix}_run#{ri}_mat_vr_aff12.1D #{outprefix}_run#{ri}_fd"
  end
  l.cmd "cat #{outprefix}_run??_fd_abs.1D > #{outprefix}_runall_fd_abs.1D"
  l.cmd "cat #{outprefix}_run??_fd_rel.1D > #{outprefix}_runall_fd_rel.1D"


  ###
  # Visualization
  ###
  
  l.info "Plot Motion"

  # get range of 6 motion parameters
  rot_max   = `3dBrickStat -absolute -max -slow #{outprefix}_runall_dfile.1D'[0..2]'\\'`.strip.to_f
  disp_max  = `3dBrickStat -absolute -max -slow #{outprefix}_runall_dfile.1D'[3..5]'\\'`.strip.to_f
  rot_max   = 1.025*rot_max # pad by 5%
  disp_max  = 1.025*disp_max # pad by 5%
  l.info "setting rotations range to #{rot_max} radians"
  l.info "setting displacements range to #{disp_max} mm"
  
  # get range of fd
  abs_max   = `3dBrickStat -absolute -max -slow #{outprefix}_runall_fd_abs.1D\\'`.strip.to_f
  abs_max   = 1.025*abs_max
  l.info "setting absolute fd range to #{abs_max} mm"
  # note that the relative fd will always be set to a minimum max range of 2mm
  rel_max   = `3dBrickStat -absolute -max -slow #{outprefix}_runall_fd_rel.1D\\'`.strip.to_f
  rel_max   = 2.0 if rel_max < 2.0
  rel_max   = 1.025*rel_max
  l.info "setting relative fd range to #{rel_max} mm"
  # adjust the height of relative fd relative to the max
  rel_height= (rel_max * 144.0/2.05).to_i
  
  inputs.each_with_index do |input,i|
  	ri = "%02i" % (i + 1)
  	l.info "\n== run #{ri}"
    l.cmd "fsl_tsplot -i #{outprefix}_run#{ri}_dfile.1D \
          -t 'Run #{ri} - Rotations (radians)' \
          --ymin=-#{rot_max} --ymax=#{rot_max} \
          -u 1 --start=1 --finish=3 \
          -a roll,pitch,yaw \
          -w 640 -h 144 \
          -o #{outprefix}_run#{ri}_plot_rot.png"
    l.cmd "fsl_tsplot -i #{outprefix}_run#{ri}_dfile.1D \
          -t 'Run #{ri} - Translations (mm)' \
          --ymin=-#{disp_max} --ymax=#{disp_max} \
          -u 1 --start=4 --finish=6 \
          -a dS,dL,dP \
          -w 640 -h 144 \
          -o #{outprefix}_run#{ri}_plot_trans.png"
    l.cmd "fsl_tsplot -i #{outprefix}_run#{ri}_fd_abs.1D \
          -t 'Run #{ri} - Mean Displacement (mm) - Absolute' \
          -u 1 -w 640 -h 144 \
          -o #{outprefix}_run#{ri}_plot_fd_abs.png"
    l.cmd "fsl_tsplot -i #{outprefix}_run#{ri}_fd_rel.1D \
          --ymin=0 --ymax=#{rel_max} \
          -t 'Run #{ri} - Mean Displacement (mm) - Relative' \
          -u 1 -w 640 -h #{rel_height} \
          -o #{outprefix}_run#{ri}_plot_fd_rel.png"
  end


  ###
  # For Later Regressions
  ###

  l.info "Create Files For Later Regressions"

  l.info "collecting the run lengths"
  runlengths = inputs.each_with_index.collect do |input,i|
    ri = "%02i" % (i + 1)
    nvols = `fslnvols #{outprefix}_run#{ri}_volreg#{ext}`
    nvols.chomp
  end
  srunlengths = runlengths.join(' ')

  l.info "compute de-meaned motion parameters (for use in regression)"
  l.cmd "1d_tool.py -infile #{outprefix}_runall_dfile.1D -set_run_lengths #{srunlengths} -demean -write #{outprefix}_motion_demean.1D"

  l.info "compute motion parameter derivatives (just to have)"
  l.cmd "1d_tool.py -infile #{outprefix}_runall_dfile.1D \
        -set_run_lengths #{srunlengths} \
        -derivative -demean \
        -write #{outprefix}_motion_deriv_demean.1D"

  l.info "create file for censoring motion"
  l.cmd "1d_tool.py -infile #{outprefix}_runall_dfile.1D \
        -set_run_lengths #{srunlengths} \
        -show_censor_count -censor_prev_TR \
        -censor_motion 1.25 #{outprefix}_motion" # TODO: have the amount of motion be a user argument
  

  ###
  # Save all this to an html page
  ###

  # call ...


  ###
  # Finalize
  ###

  l.info "Clean up"

  if not keepwork
    l.info "Removing working directory"
    l.cmd "rm #{workdir}/*"
    l.cmd "rmdir #{workdir}"
  end
  
  # Unset AFNI_DECONFLICT
  reset_afni_deconflict if overwrite
end


if __FILE__==$0
  func_motion_correct!
end
