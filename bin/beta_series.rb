#!/usr/bin/env ruby

# - afni threads/deconflict
# - deconvolve
# => ask for input(s) 
# => ask for TR
# => ask for polort
# => ask for the 'label file model' for each stimulus type
# => ask for output directory (me)
# - remlfit
# => mask
# => options for what to output? (maybe in the future)
# - extract the beta-series (delete the original beta-series output)
#
# Created by Zarrar Shehzad on 2014-12-20
# 

require 'pry'
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

  CDIR        = SCRIPTDIR + "bin/"
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
# anat_skullstrip(l, args = [], opts = {})
def beta_series(l, args = [], opts = {})
  cmdline = cli_wrapper(args, opts)
  l.info "Running: #{Pathname.new(__FILE__).basename} #{cmdline}"
  beta_series!(cmdline, l)
end


def beta_series!(cmdline = ARGV, l = nil)
  ###
  # USER ARGS
  ###

  # Process command-line inputs
  p = Trollop::Parser.new do
    banner "Usage: #{File.basename($0)} -i input1 input2 ... input3 -s label file model -s label file model --tr 1 --polort 0 -m mask -o output-directory [--oresiduals]"
    opt :inputs, "Input functionals", :type => :strings, :required => true
    opt :mask, "Mask file path", :type => :string, :required => true
    opt :bg, "Background image", :type => :string, :required => true
    opt :output, "Output directory", :type => :string, :required => true
    
    opt :stim, "Stimulus information: label file-path model", :type => :strings, :required => true, :multi => true
    
    opt :tr, "TR of input functionals", :type => :string, :required => true
    opt :polort, "Polort (can be -1 for nothing)", :type => :string, :default => "0"
    opt :oresiduals, "Output residuals of beta-series model fitting", :default => false
    opt :ofitted, "Output of fitted beta-series model", :default => false
    opt :keepstats, "Keep the output stats bucket", :default => false
    
    opt :motion, "AFNI motion parameters to include as covariates", :type => :string
    opt :covars, "Additional covariate (e.g., compcor). Two arguments must be given: label filepath", :type => :strings
    
    opt :regdir, "A registration directory in the style of fsl. If given, then will transform outputs into standard space", :type => :string
    opt :master, "Master file for registration", :type => :string
    
    opt :threads, "Number of OpenMP threads to use with AFNI (otherwise defaults to environmental variable OMP_NUM_THREADS if set -> #{ENV['OMP_NUM_THREADS']})", :type => :integer
    opt :ext, "File extensions to use in all outputs", :type => :string, :default => ".nii.gz"
    opt :overwrite, "Overwrite existing output", :default => false
  end
  opts = Trollop::with_standard_exception_handling p do
    raise Trollop::HelpNeeded if cmdline.empty? # show help screen
    p.parse cmdline
  end

  # Gather inputs
  inputs  = opts[:inputs].collect{|input| input.path.expand_path.to_s }
  str_inputs = inputs.join " "
  nruns	  = inputs.count
  mask    = opts[:mask].path.expand_path
  bg      = opts[:bg].path.expand_path
  outdir  = opts[:output].path.expand_path
  
  stims   = opts[:stim]
  
  tr      = opts[:tr]
  polort  = opts[:polort]
  oresiduals = opts[:oresiduals]
  ofitted = opts[:ofitted]
  keepstats = opts[:keepstats]
  
  motion  = opts[:motion].path.expand_path
  covars  = opts[:covars]
  unless covars.nil?
    covar_label = covars[0]
    covar_fname = covars[1].path.expand_path
  end
  
  regdir      = opts[:regdir]
  regdir      = regdir.path.expand_path unless regdir.nil?
  master      = opts[:master]
  master      = master.path.expand_path unless master.nil?
  
  threads     = opts[:threads]
  ext         = opts[:ext]
  overwrite   = opts[:overwrite]
  
  l           = create_logger()
  
  # Set options to pass to afni
  af_opts =
    if overwrite then "-overwrite"
    else ""
  end
  
  # Set options to pass to ruby functions/scripts (not used here)
  rb_opts = {}
  rb_opts[:overwrite] = true if overwrite
  rb_opts[:ext] = ext
  
  
  #--- SETUP ---#
  
  # Set AFNI_DECONFLICT
  set_afni_to_overwrite if overwrite
  # Set Threads
  set_omp_threads threads if not threads.nil?

  l.info "Checking inputs"
  l.fatal("inputs don't exist") if any_inputs_dont_exist l, *inputs, mask, bg

  l.info "Checking outputs" 
  l.fatal("some output files exist, exiting") if !overwrite and all_outputs_exist l, outdir
  l.cmd "mkdir #{outdir}/evs 2> /dev/null"
  
  l.info "Changing directory to '#{outdir}'"
  outdir.mkdir if not outdir.directory?
  outdir = outdir.realpath
  Dir.chdir outdir
  
  l.info "Logging"
  log_prefix  = "#{outdir}/log"
  log_prefix  = log_prefix.path.expand_path
  l           = create_logger(log_prefix, overwrite)
  
  
  #--- Deconvolve ---#
  
  l.title "Generating design matrix"
  
  l.info "Running deconvolve"
  
  cmd = ["3dDeconvolve"]
  cmd.push(af_opts) unless af_opts == ""
  
  # Input and input options
  cmd.push "-input #{str_inputs}"
  cmd.push "-force_TR #{tr}"
  cmd.push "-polort #{polort}"
  
  # Stimulus options
  refc = cmd.count
  nstims = stims.count
  stims.each_with_index do |stim,i|
    label = stim[0]; timing_fname = stim[1]; model = stim[2]
    cmd.push "-stim_times_IM #{i+1} '#{timing_fname}' '#{model}'"
    cmd.push "-stim_label #{i+1} #{label}"
    # copy over stimulus parameters
    l.cmd "cp #{timing_fname} #{outdir}/evs/timing_#{label}.1D"
  end
  
  # Motion covariates
  unless motion.nil?
    motion_labels = ['roll', 'pitch', 'yaw', 'dS', 'dL', 'dP']
    (1..6).each_with_index do |num,i|
      ind = stims.count + num
      cmd.push "-stim_file #{ind} #{motion}'[#{i}]'"
      cmd.push "-stim_base #{ind}"
      cmd.push "-stim_label #{ind} #{motion_labels[i]}"
    end
    # copy over motion parameters
    l.cmd "cp #{motion} #{outdir}/evs/motion.1D"
    nstims += 6
  end
  
  # Additional covariates
  unless covars.nil?
    ncovars=`head -n 1 #{covar_fname} | wc -w`.to_i    
    (1..ncovars).each_with_index do |num,i|
      ind = nstims + num
      cmd.push "-stim_file #{ind} #{covar_fname}'[#{i}]'"
      cmd.push "-stim_base #{ind}"
      cmd.push "-stim_label #{ind} #{covar_label}_#{num}"
    end
    # copy over covariates
    l.cmd "cp #{covar_fname} #{outdir}/evs/covars.1D"
    nstims += ncovars
  end
  
  # Number of stimulus time-series
  cmd.insert(refc, "-num_stimts #{nstims}")
  
  # Output and output options
  cmd.push "-noFDR"
  cmd.push "-nobucket"
  cmd.push "-x1D #{outdir}/xmat.1D"-
  cmd.push "-xjpeg #{outdir}/xmat.jpg"
  cmd.push "-x1D_stop"
  
  # combine and run
  l.cmd cmd.join(" ")
  
  
  #--- REMLfit ---#
  
  l.title "Apply regression"
  
  l.info "Running remlfit"
  
  cmd = ["3dREMLfit"]
  cmd.push(af_opts) unless af_opts == ""
  
  # Inputs
  cmd.push "-matrix #{outdir}/xmat.1D"
  cmd.push "-input '#{str_inputs}'"
  cmd.push "-mask #{mask}"
  
  # Outputs and output options
  cmd.push "-noFDR"
  cmd.push "-Rbuck #{outdir}/stats_bucket.nii.gz"
  cmd.push "-Rfitts #{outdir}/fitted.nii.gz" if ofitted
  cmd.push "-Rerrts #{outdir}/residuals.nii.gz" if oresiduals
  
  cmd.push "-verb" # TODO: add verbose option
  
  # Combine and run
  l.cmd cmd.join(" ")
  
  
  #--- SPLIT ---#
  
  l.title "Splitting beta-series"
  
  # degrees of freedom needed for any t2z conversion
  stats=`3dAttribute BRICK_STATAUX #{outdir}/stats_bucket.nii.gz`
  df=stats.split[3]
  l.info "- degrees of freedom = #{df}"
  l.cmd "echo #{df} > #{outdir}/degrees_of_freedom.txt"
  
  # split
  stims.each_with_index do |stim,i|
    label = stim[0]
    l.info "extracting #{label}"
    l.cmd "afni_buc2time.R -i #{outdir}/stats_bucket.nii.gz -s '#{label}#[0-9]+_Coef' -o #{outdir}/beta_series_#{label}.nii.gz"
  end
  
  # remove full bucket
  l.cmd "rm #{outdir}/stats_bucket.nii.gz" unless keepstats
  
  
  #--- OTHER OUTPUTS ---#
  
  l.title "Other outputs"
  
  l.info "Copy mask and background image"
  l.cmd "fslmaths #{mask} #{outdir}/mask.nii.gz"
  l.cmd "fslmaths #{bg} #{outdir}/bgimage.nii.gz"
  
  
  #--- TO STANDARD ---#
  
  # if given a regdir, this will transform the outputs to standard space
  if not regdir.nil?
    l.title "Transform output to standard space"
    
    l.cmd "ln -sf #{regdir} #{outdir}/reg"
    l.cmd "mkdir #{outdir}/reg_standard 2> /dev/null"
    
    # copy over master image
    l.cmd "fslmaths #{master} #{outdir}/master#{ext}" unless master.nil?
    
    require 'gen_applywarp.rb'
    warp_cmd = "exfunc-to-standard"
    
    reg_opts = rb_opts.clone
    reg_opts[:master] = master.to_s unless master.nil?
    
    # transform mask and bg
    gen_applywarp l, nil, :reg => regdir.to_s, :input => "#{outdir}/mask#{ext}", 
      :warp => warp_cmd, :output => "#{outdir}/reg_standard/mask#{ext}", 
      :interp => "nn", **reg_opts
    gen_applywarp l, nil, :reg => regdir.to_s, :input => "#{outdir}/bgimage#{ext}", 
      :warp => warp_cmd, :output => "#{outdir}/reg_standard/bgimage#{ext}", 
      :interp => "spline", **reg_opts
    
    # transform the beta-series
    stims.each_with_index do |stim,i|
      label = stim[0]
      gen_applywarp l, nil, :reg => regdir.to_s, :input => "#{outdir}/beta_series_#{label}#{ext}", 
        :warp => warp_cmd, :output => "#{outdir}/reg_standard/beta_series_#{label}#{ext}", 
        :interp => "spline", **reg_opts
    end
  end
  
  
  #--- END ---#
  
  l.title "Clean up"
  
  # Unset AFNI_DECONFLICT
  reset_afni_deconflict if overwrite
end


if __FILE__==$0
  beta_series!
end
