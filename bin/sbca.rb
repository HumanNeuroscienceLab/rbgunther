#!/usr/bin/env ruby

# Compute seed-based connectivity analysis (sbca) for one subject
#
# Created by Zarrar Shehzad on 2014-12-30
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
def sbca(l, args = [], opts = {})
  cmdline = cli_wrapper(args, opts)
  l.info "Running: #{Pathname.new(__FILE__).basename} #{cmdline}"
  sbca!(cmdline, l)
end

def sbca!(cmdline = ARGV, l = nil)
  ###
  # USER ARGS
  ###
  
  # Input:
  # - ROI
  # - Input functional
  # - output prefix or output directory?
  # - mask
  # - fish_z? (optional)
  # - working directory (if specified, it will keep the working directory)
  # - regdir (optional)
  # - might want something similar (-w) for the ROI to go from the ROI space to the subject space
  # - in-space (default: exfunc)
  # - roi-space (default: standard)
  # - out-space (default: standard)
  # - ref (optional: to specify different output resolution)
  # - underlay (optional - needed for making picture of correlation map)
  
  # Process command-line inputs
  p = Trollop::Parser.new do
    banner "Usage: #{File.basename($0)} -f func_file.nii.gz -r roi_file.nii.gz -m mask_file.nii.gz -o output-directory"
    opt :roi, "ROI file", :type => :string, :required => true
    opt :func, "Functional file", :type => :string, :required => true
    opt :mask, "Mask file path (should be in same space as functional file)", :type => :string, :required => true
    opt :regdir, "Input registration directory", :type => :string, :required => true
    
    opt :space, "Indicate the spaces (exfunc, highres, or standard) of input/output files: --space roi-space func-space out-space", :type => :strings
    
    opt :outdir, "Output directory", :type => :string, :required => true
    
    opt :workdir, "Working directory (default is some temporary one)", :type => :string
    opt :linear, "Whether to use linear registration in any transformation (vs non-linear, the default)", :default => false
    opt :underlay, "Optional underlay image for visualization of correlation output. Defaults to file corresponding to space of functional in the regdir.", :type => :string
    opt :fwhm, "Amount to smooth final output (default: don't do this)", :type => :string
    
    opt :threads, "Number of OpenMP threads to use with AFNI (otherwise defaults to environmental variable OMP_NUM_THREADS if set -> #{ENV['OMP_NUM_THREADS']})", :type => :integer
    opt :ext, "File extensions to use in all outputs", :type => :string, :default => ".nii.gz"
    opt :overwrite, "Overwrite existing output", :default => false
  end
  opts = Trollop::with_standard_exception_handling p do
    raise Trollop::HelpNeeded if cmdline.empty? # show help screen
    p.parse cmdline
  end

  # Gather inputs
  func_file = opts[:func].path.expand_path
  roi_file  = opts[:roi].path.expand_path
  mask_file = opts[:mask].path.expand_path
  regdir    = opts[:regdir].path.expand_path
  
  spaces    = opts[:space]
  unless spaces.nil?
    Trollop::die("space option must have 3 arguments: --space roi-space func-space out-space") if spaces.count != 3
    roispace  = spaces[0]
    funcspace = spaces[1]
    outspace  = spaces[2]
  end
  
  outdir    = opts[:outdir].path.expand_path
  
  workdir   = opts[:workdir]
  workdir   = workdir.path.expand_path unless workdir.nil?
  linear    = opts[:linear]
  
  fwhm      = opts[:fwhm]
    
  threads     = opts[:threads]
  ext         = opts[:ext]
  overwrite   = opts[:overwrite]
  
  underlay  = opts[:underlay]
  underlay  = "#{regdir}/#{funcspace}#{ext}" if underlay.nil? and not spaces.nil?
  underlay  = underlay.path.expand_path if underlay.nil?
  
  # temporary logger
  l         = create_logger()
    
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
  l.fatal("inputs don't exist") if any_inputs_dont_exist l, roi_file, mask_file, func_file, regdir

  l.info "Checking outputs" 
  l.fatal("some output files exist, exiting") if !overwrite and all_outputs_exist l, outdir
  
  if not workdir.nil?
    l.info "Setup work directory: #{workdir}"
    workdir.mkdir if not workdir.directory?
  end
  
  l.info "Changing directory to '#{outdir}'"
  outdir.mkdir if not outdir.directory?
  outdir = outdir.realpath
  Dir.chdir outdir
  
  # Actually file logging now!
  log_prefix  = "#{outdir}/log"
  log_prefix  = log_prefix.path.expand_path
  l           = create_logger(log_prefix, overwrite)
  
  
  #--- FILE SETUP ---#
  
  l.info "Soft-linking registration directory"
  l.cmd "ln -sf #{regdir} #{outdir}/reg"
  
  l.info "Copy over underlay" unless underlay.nil?
  l.cmd "3dcopy #{underlay} #{outdir}/underlay#{ext}" unless underlay.nil?

  
  #--- 1. ROI to functional space ---#
  
  l.title "ROI to functional space"
  
  if spaces.nil? or roispace == funcspace
    l.cmd "3dcopy #{roi_file} #{outdir}/roi#{ext}"
  else
    require 'gen_applywarp.rb'
    roi_warp_cmd = "#{roispace}-to-#{funcspace}"
    gen_applywarp l, nil, :reg => regdir.to_s, :input => roi_file.to_s, 
      :warp => roi_warp_cmd, :output => "#{outdir}/roi#{ext}", :interp => "nn", **rb_opts
  end
  
  
  #--- 2. Correlate ---#
  
  l.title "Correlate"
    
  l.info "Extract mean time-series for ROI"
  l.cmd "3dmaskave -quiet -mask #{outdir}/roi#{ext} #{func_file} > #{outdir}/roi_ts.1D"
  
  l.info "Compute connectivity map"
  l.cmd "3dTcorr1D -prefix #{outdir}/corr_map#{ext} -mask #{mask_file} #{func_file} #{outdir}/roi_ts.1D"
  
  
  #--- 3. Fischer Z transform ---#
  
  l.title "Fischer-Z Transform"
  
  l.info "Transform but clamp correlations of 1 to 0.9999999999999999"
  l.cmd "3dcalc -a #{outdir}/corr_map#{ext} -expr 'equals(a,1)*atanh(0.9999999999999999) + not(equals(a,1))*atanh(a)' -prefix #{outdir}/fisherz_map#{ext}"
    
  
  #--- 4. Plots ---#
  
  # output: plot_ts, plot_conn
  ## plot of the mean ROI time-series
  l.cmd "fsl_tsplot -i #{outdir}/roi_ts.1D \
            -t 'ROI Time-Series' \
            -u 1 -w 640 -h 144 \
            -o #{outdir}/roi_ts.png"
  ## first get the correlation threshold with p < 0.01, two-tailed
  nvols=`fslnvols #{func_file}`.to_f
  rthr=`Rscript --vanilla -e 'library(fdrtool); qcor0(0.01/2, #{nvols}, lower.tail=F)' | awk '{print $2}'`.to_f
  ## second plot the correlation map
  if not underlay.nil?
    l.cmd "slicer.py --overlay #{outdir}/corr_map#{ext} #{rthr} 1 --show-negative -s axial -w 5 -l 4 #{outdir}/underlay#{ext} #{outdir}/thresh_corr_map.png"
  elsif not spaces.nil?
    l.cmd "slicer.py --overlay #{outdir}/corr_map#{ext} #{rthr} 1 --show-negative -s axial -w 5 -l 4 #{regdir}/#{funcspace}#{ext} #{outdir}/thresh_corr_map.png"
  end
  
  
  #--- 5. Apply transform of output to another space ---#
  
  unless spaces.nil? or funcspace == outspace
    require 'gen_applywarp.rb'
    out_warp_cmd = "#{funcspace}-to-#{outspace}"
    gen_applywarp l, nil, :input => "#{outdir}/corr_map#{ext}", 
      :reg => regdir.to_s, :warp => out_warp_cmd, 
      :output => "#{outdir}/corr_map_to_standard#{ext}", 
      **rb_opts
    gen_applywarp l, nil, :input => "#{outdir}/fisherz_map#{ext}", 
      :reg => regdir.to_s, :warp => out_warp_cmd, 
      :output => "#{outdir}/fisherz_map_to_standard#{ext}", 
      **rb_opts
    gen_applywarp l, nil, :input => mask_file.to_s, 
      :reg => regdir.to_s, :warp => out_warp_cmd, 
      :output => "#{outdir}/mask_to_standard#{ext}", 
      :interp => "nn", **rb_opts
      
    # plots
    l.cmd "slicer.py --overlay #{outdir}/corr_map_to_standard#{ext} #{rthr} 1 --show-negative -s axial -w 5 -l 4  #{outdir}/reg/#{outspace}#{ext} #{outdir}/thresh_corr_map_to_standard.png"
  end
  
  
  #--- 6. Apply some additional smoothing to output in standard space ---#
  unless fwhm.nil?
    require 'func_smooth.rb'
  
    # We only smooth the transformed data or if that doesn't exist
    # then will smooth the untransformed output
    if spaces.nil?
      suffix=""
      mask=mask_file.to_s
    else
      suffix="_to_#{outspace}"
      mask="#{outdir}/mask_to_standard#{ext}"
    end
    
    func_smooth l, nil, :input => "#{outdir}/corr_map#{suffix}#{ext}", 
      :mask => mask, :fwhm => fwhm, :output => "#{outdir}/corr_map#{suffix}_smooth#{ext}"
    func_smooth l, nil, :input => "#{outdir}/fisherz_map#{suffix}#{ext}", 
      :mask => mask, :fwhm => fwhm, :output => "#{outdir}/fisherz_map#{suffix}_smooth#{ext}"
    
    l.cmd "slicer.py --overlay #{outdir}/corr_map#{suffix}_smooth#{ext} #{rthr} 1 --show-negative -s axial -w 5 -l 4  #{outdir}/reg/#{outspace}#{ext} #{outdir}/thresh_corr_map#{suffix}_smooth.png"
  end

  
  #--- END ---#
  
  l.title "Clean up"
  
  # Unset AFNI_DECONFLICT
  reset_afni_deconflict if overwrite
end


if __FILE__==$0
  sbca!
end
