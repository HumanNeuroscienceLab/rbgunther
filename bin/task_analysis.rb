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
def task_analysis(l, args = [], opts = {})
  cmdline = cli_wrapper(args, opts)
  l.info "Running: #{Pathname.new(__FILE__).basename} #{cmdline}"
  task_analysis(cmdline, l)
end

def task_analysis!(cmdline = ARGV, l = nil)
  ###
  # USER ARGS
  ###
  
  # Process command-line inputs
  p = Trollop::Parser.new do
    banner "Usage: #{File.basename($0)} -i input1 input2 ... input3 -s label file model -s label file model --tr 1 --polort 0 -m mask -o output-directory [--oresiduals]"
    opt :inputs, "Input functionals", :type => :strings, :required => true
    opt :mask, "Mask file path", :type => :string, :required => true
    opt :bg, "Background image", :type => :string, :required => true
    opt :output, "Output directory", :type => :string, :required => true, :short => :o
    
    opt :local, "Force local timing, see -local_times in 3dDeconvolve", :default => false
    opt :global, "Force global timing, see -global_times in 3dDeconvolve", :default => false
    
    opt :stim, "Stimulus information: label file-path model", :type => :strings, :required => true, :multi => true
    opt :stim_am2, "Stimulus (amplitude-duration modulated) information: label file-path model", :type => :strings, :multi => true
    opt :glt, "Contrast information (this is on top of any main effects of the stimulus information): label contrast", :type => :strings, :required => true, :multi => true
    
    opt :tr, "TR of input functionals", :type => :string, :required => true
    opt :polort, "Polort (can be -1 for nothing)", :type => :string, :default => "0"
    opt :oresiduals, "Output residuals of task-analysis model fitting", :default => false
    
    opt :motion, "AFNI motion parameters to include as covariates", :type => :string
    opt :covars, "Additional covariate (e.g., compcor). Two arguments must be given: label filepath", :type => :strings
    
    opt :regdir, "A registration directory in the style of fsl. If given, then will transform outputs into standard space", :type => :string
    opt :freedir, "Subject directory for freesurfer outputs. Should be $SUBJECTS_DIR/subject", :type => :string
    
    opt :tostandard, "Will register to standard space if regdir is specified", :default => false
    opt :tohighres, "Will register to highres space if regdir is also specified", :default => false
    opt :tosurf, "Will register to native surface space if regdir and freedir is also specified", :default => false
    
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
  
  local_t = opts[:local]
  global_t= opts[:global]
  
  stims   = opts[:stim]
  stims_am2 = opts[:stim_am2]
  glts    = opts[:glt]
  
  tr      = opts[:tr]
  polort  = opts[:polort]
  oresiduals = opts[:oresiduals]
  
  motion  = opts[:motion].path.expand_path
  covars  = opts[:covars]
  unless covars.nil?
    covar_label = covars[0]
    covar_fname = covars[1].path.expand_path
  end
  
  regdir      = opts[:regdir]
  regdir      = regdir.path.expand_path unless regdir.nil?
  freedir     = opts[:freedir]
  freesubj    = freedir.path.basename.to_s unless freedir.nil?
  freedir     = freedir.path.expand_path.dirname.to_s unless freedir.nil?
  tostandard  = opts[:tostandard]
  tohighres   = opts[:tohighres]
  tosurf      = opts[:tosurf]
  
  threads     = opts[:threads]
  ext         = opts[:ext]
  overwrite   = opts[:overwrite]
  
  l           = create_logger()
    
  # Set options to pass to afni
  af_opts =
    if overwrite then " -overwrite"
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
  l.cmd "mkdir #{outdir}/evs 2> /dev/null"
  
  cmd = ["3dDeconvolve"]
  cmd.push(af_opts) unless af_opts == ""
  
  # Input and input options
  cmd.push "-input #{str_inputs}"
  cmd.push "-force_TR #{tr}"
  cmd.push "-polort #{polort}"
  
  # Local vs global timing
  cmd.push "-global_times" if global_t
  cmd.push "-local_times" if local_t
  
  # Stimulus options
  refc = cmd.count
  nstims = stims.count
  stims.each_with_index do |stim,i|
    label = stim[0]; timing_fname = stim[1]; model = stim[2]
    cmd.push "-stim_times #{i+1} '#{timing_fname}' '#{model}'"
    cmd.push "-stim_label #{i+1} #{label}"
    # copy over stimulus parameters
    l.cmd "cp #{timing_fname} #{outdir}/evs/timing_#{label}.1D"
  end
  
  # Stimulus AM2 options
  if stims_am2.count > 0
    stims_am2.each_with_index do |stim,i|
      nstims += 1
      label = stim[0]; timing_fname = stim[1]; model = stim[2]
      cmd.push "-stim_times_AM2 #{nstims} '#{timing_fname}' '#{model}'"
      cmd.push "-stim_label #{nstims} #{label}"
      # copy over stimulus parameters
      l.cmd "cp #{timing_fname} #{outdir}/evs/timing_#{label}.1D"
    end
  end
  
  # Motion covariates
  unless motion.nil?
    motion_labels = ['roll', 'pitch', 'yaw', 'dS', 'dL', 'dP']
    (1..6).each_with_index do |num,i|
      ind = nstims + num
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
  
  # Contrasts
  nglts = glts.count
  cmd.push "-num_glt #{nglts}"
  glts.each_with_index do |glt, i|
    label = glt[0]; con = glt[1]
    cmd.push "-glt_label #{i+1} #{label}"
    cmd.push "-gltsym '#{con}'"
  end
  
  # Output and output options
  cmd.push "-noFDR"
  cmd.push "-nobucket"
  cmd.push "-x1D #{outdir}/xmat.1D"
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
  cmd.push "-tout -noFDR"
  cmd.push "-Rbuck #{outdir}/stats_bucket#{ext}"
  cmd.push "-Rerrts #{outdir}/residuals#{ext}"
  
  cmd.push "-verb" # TODO: add verbose option
  
  # Combine and run
  l.cmd cmd.join(" ")
  
  
  #--- SPLIT OUTPUT ---#
  
  l.title "Splitting output bucket"
  
  # degrees of freedom needed for any t2z conversion
  stats=`3dAttribute BRICK_STATAUX #{outdir}/stats_bucket#{ext}`
  df=stats.split[4]
  l.info "- degrees of freedom = #{df}"
  l.cmd "echo #{df} > #{outdir}/degrees_of_freedom.txt"
  
  # labels
  stim_labels = stims.collect{|stim| stim[0]}
  glt_labels = glts.collect{|glt| glt[0]}
  labels = stim_labels + glt_labels
  
  # split
  statdir = "#{outdir}/stats"
  l.cmd "mkdir #{statdir}"
  labels.each_with_index do |label,i|
    l.info "extracting #{label}"
    l.cmd "3dcalc#{af_opts} -a #{outdir}/stats_bucket#{ext}'[#{label}#0_Coef]' -expr a -prefix #{statdir}/coef_#{label}#{ext} -float"
    l.cmd "3dcalc#{af_opts} -a #{outdir}/stats_bucket#{ext}'[#{label}#0_Tstat]' -expr a -prefix #{statdir}/tstat_#{label}#{ext} -float"
    l.cmd "3dcalc#{af_opts} -a #{outdir}/stats_bucket#{ext}'[#{label}#0_Tstat]' -expr 'fitt_t2z(a,#{df})' -prefix #{statdir}/zstat_#{label}#{ext} -float"
  end
  
  
  #--- TSNR ---#
  
  l.title "TSNR"
  
  l.info "concatenate inputs"
  # create an all_runs dataset to match the fitts, errts, etc.
  # we will only need this for the TSNR and for the blurring
  # this will be deleted afterwards
  l.cmd "3dTcat#{af_opts} -tr #{tr} -prefix #{outdir}/tmp_all_runs#{ext} #{str_inputs}"
  
  l.info "compute TSNR"
  # create a temporal signal to noise ratio dataset 
  #    signal: if 'scale' block, mean should be 100
  #    noise : compute standard deviation of errts
  l.cmd "3dTstat#{af_opts} -mean -prefix #{outdir}/mean_signal#{ext} #{outdir}/tmp_all_runs#{ext}"
  l.cmd "3dTstat#{af_opts} -stdev -prefix #{outdir}/mean_noise#{ext} #{outdir}/residuals#{ext}"
  l.cmd "3dcalc#{af_opts} -a #{outdir}/mean_signal.nii.gz \
         -b #{outdir}/mean_noise.nii.gz       \
         -c #{mask}                           \
         -expr 'c*a/b' -prefix #{outdir}/tsnr.nii.gz"
  
  
  #--- BLUR ESTIMATION ---#
  
  l.title "Blur Estimation"
  
  # get counts of the tr
  tr_counts = inputs.collect{|input| `fslnvols #{input}`.strip.to_i }
  
  # compute blur estimates
  l.cmd "rm -f #{outdir}/blur_est.1D"
  l.cmd "touch #{outdir}/blur_est.1D"   # start with empty file
  
  # -- estimate blur for each run in epits --
  l.info "estimate blur for each run in input data"
  l.cmd "rm -f #{outdir}/blur_epits.1D"
  l.cmd "touch #{outdir}/blur_epits.1D"
  b0=0     # first index for current run
  b1=-1    # will be last index for current run
  tr_counts.each do |reps|
    b1 = b1 + reps   # last index for current run
    l.cmd "3dFWHMx -detrend -mask #{mask} \
        #{outdir}/tmp_all_runs.nii.gz'[#{b0}..#{b1}]' >> #{outdir}/blur_epits.1D"
    b0 = b0 + reps  # first index for next run
  end
  # compute average blur and append
  blurs=`3dTstat -mean -prefix - #{outdir}/blur_epits.1D\\'`.strip
  blurs=blurs.gsub(/\s+/, ' ')
  l.info "average epits blurs: #{blurs}"
  l.cmd "echo '#{blurs}   # epits blur estimates' >> #{outdir}/blur_est.1D"
  
  # -- estimate blur for each run in errts --
  l.info "estimate blur for each run in residuals following REML fit"
  l.cmd "rm -f #{outdir}/blur_errts.1D"
  l.cmd "touch #{outdir}/blur_errts.1D"
  b0=0     # first index for current run
  b1=-1    # will be last index for current run
  tr_counts.each do |reps|
    b1 = b1 + reps   # last index for current run
    l.cmd "3dFWHMx -detrend -mask #{mask} \
          #{outdir}/residuals.nii.gz'[#{b0}..#{b1}]' >> #{outdir}/blur_errts.1D"
    b0 = b0 + reps   # first index for next run
  end
  # compute average blur and append
  blurs=`3dTstat -mean -prefix - #{outdir}/blur_errts.1D\\'`.strip
  blurs=blurs.gsub(/\s+/, ' ')
  l.info "average errts blurs: #{blurs}"
  l.cmd "echo '#{blurs}   # errts blur estimates' >> #{outdir}/blur_est.1D"
  
  # add 3dClustSim results as attributes to the stats dset
  l.info "run cluster threshold simulations"
  fxyz=`tail -1 #{outdir}/blur_est.1D | awk '{print $1,$2,$3}'`.strip
  l.cmd "3dClustSim#{af_opts} -both -NN 123 -mask #{mask} \
             -fwhmxyz #{fxyz} -prefix #{outdir}/ClustSim"
  l.cmd "3drefit#{af_opts} -atrstring AFNI_CLUSTSIM_MASK file:ClustSim.mask           \
            -atrstring AFNI_CLUSTSIM_NN1  file:ClustSim.NN1.niml            \
            -atrstring AFNI_CLUSTSIM_NN2  file:ClustSim.NN2.niml            \
            -atrstring AFNI_CLUSTSIM_NN3  file:ClustSim.NN3.niml            \
            #{outdir}/stats_bucket#{ext}"

            
  #--- OTHER OUTPUTS ---#

  l.title "Other outputs"

  l.info "Copy mask and background image"
  l.cmd "fslmaths #{mask} #{outdir}/mask.nii.gz"
  l.cmd "fslmaths #{bg} #{outdir}/bgimage.nii.gz"
  
  
  #--- EASYTHRESH ---#
  
  l.title "EasyThresh"
  
  l.info "estimate image smoothness"
  # estimate image smoothness
  l.info "sm=`smoothest -d #{df} -m #{mask} -r #{outdir}/residuals#{ext}`"
  sm=`smoothest -d #{df} -m #{mask} -r #{outdir}/residuals#{ext}`.strip.split
  dlh=sm[1]
  volume=sm[3]
  resels=sm[5]
  l.info "- DLH: #{dlh}; VOLUME: #{volume}; RESELS: #{resels}"
  l.cmd "echo 'DLH: #{dlh}' > smoothest_errts_fsl.1D"
  l.cmd "echo 'VOLUME: #{volume}' >> smoothest_errts_fsl.1D"
  l.cmd "echo 'RESELS: #{resels}' >> smoothest_errts_fsl.1D"
  
  l.info "threshold zstat images"
  l.cmd "mkdir #{outdir}/rendered_stats"
  # thresholds see top of program
  # start converting (save as floats)
  vthr = 1.96
  cthr = 0.05
  labels.each do |label|
    l.info "- #{label} cluster correction"
    l.cmd "cluster -i #{statdir}/zstat_#{label}.nii.gz -t #{vthr} -p #{cthr} --volume=#{volume} -d #{dlh} -o #{statdir}/cluster_mask_#{label}.nii.gz --othresh=#{statdir}/thresh_zstat_#{label}.nii.gz > #{statdir}/cluster_#{label}.txt # --mm"
    
    l.info "- #{label} visualization"
    vmax=`fslstats #{statdir}/thresh_zstat_#{label}.nii.gz -R | awk '{print $2}'`.strip
    l.cmd "overlay 1 0 #{bg} -a #{statdir}/thresh_zstat_#{label}.nii.gz #{vthr} #{vmax} #{outdir}/rendered_stats/thresh_zstat_#{label}.nii.gz"
    l.cmd "slicer #{outdir}/rendered_stats/thresh_zstat_#{label}.nii.gz -S 2 750 #{outdir}/rendered_stats/thresh_zstat_#{label}.png"
  end
  
  
  #--- TO SURFACE ---#
  
  if not regdir.nil? and not freedir.nil? and tosurf
    l.title "Transform output to surface space"
    
    ENV['SUBJECTS_DIR'] = freedir.to_s
    regfile = "#{regdir}/freesurfer/anat2exf.register.dat"
    
    l.cmd "ln -sf #{regdir} #{outdir}/reg"
    l.cmd "mkdir #{outdir}/reg_surf 2> /dev/null"
    l.cmd "mkdir #{outdir}/reg_surf/stats 2> /dev/null"
    
    ["lh", "rh"].each do |hemi|
      l.info "=== hemi: #{hemi} ==="
      
      # transform mask
      l.cmd "mri_vol2surf --src #{outdir}/mask#{ext} --srcreg #{regfile} --trgsubject #{freesubj} --hemi #{hemi} --surf white --out #{outdir}/reg_surf/mask.nii.gz --sd #{freedir}"
      
      # transform each of the stat images
      labels.each_with_index do |label,i|
        l.info "transforming #{label}"
        
        l.cmd "mri_vol2surf --src #{statdir}/coef_#{label}#{ext} --srcreg #{regfile} --trgsubject #{freesubj} --hemi #{hemi} --surf white --out #{outdir}/reg_surf/stats/coef_#{label}.mgh --sd #{freedir}"
        l.cmd "mri_vol2surf --src #{statdir}/tstat_#{label}#{ext} --srcreg #{regfile} --trgsubject #{freesubj} --hemi #{hemi} --surf white --out #{outdir}/reg_surf/stats/tstat_#{label}.mgh --sd #{freedir}"
        l.cmd "mri_vol2surf --src #{statdir}/zstat_#{label}#{ext} --srcreg #{regfile} --trgsubject #{freesubj} --hemi #{hemi} --surf white --out #{outdir}/reg_surf/stats/zstat_#{label}.mgh --sd #{freedir}"
      end
      
      l.info "=== ==="
    end        
  end
  
  
  #--- TO HIGHRES ---#
  
  if not regdir.nil? and tohighres
    l.title "Transform output to highres space"
    
    l.cmd "ln -sf #{regdir} #{outdir}/reg"
    l.cmd "mkdir #{outdir}/reg_highres 2> /dev/null"
    
    require 'gen_applywarp.rb'
    warp_cmd = "exfunc-to-highres"
    
    # transform mask and bg
    gen_applywarp l, nil, :reg => regdir.to_s, :input => "#{outdir}/mask#{ext}", 
      :warp => warp_cmd, :output => "#{outdir}/reg_highres/mask#{ext}", 
      :interp => "nn", **rb_opts
    gen_applywarp l, nil, :reg => regdir.to_s, :input => "#{outdir}/bgimage#{ext}", 
      :warp => warp_cmd, :output => "#{outdir}/reg_highres/bgimage#{ext}", 
      :interp => "spline", **rb_opts
    
    # also transform stat images
    l.cmd "mkdir #{outdir}/reg_highres/stats 2> /dev/null"
    labels.each_with_index do |label,i|
      l.info "transforming #{label}"
      
      gen_applywarp l, nil, :reg => regdir.to_s, :input => "#{statdir}/coef_#{label}#{ext}", 
        :warp => warp_cmd, :output => "#{outdir}/reg_highres/stats/coef_#{label}#{ext}", 
        :mask => "#{outdir}/reg_highres/mask#{ext}", :interp => "spline", **rb_opts
      gen_applywarp l, nil, :reg => regdir.to_s, :input => "#{statdir}/tstat_#{label}#{ext}", 
        :warp => warp_cmd, :output => "#{outdir}/reg_highres/stats/tstat_#{label}#{ext}", 
        :mask => "#{outdir}/reg_highres/mask#{ext}", :interp => "spline", **rb_opts
      gen_applywarp l, nil, :reg => regdir.to_s, :input => "#{statdir}/zstat_#{label}#{ext}", 
        :warp => warp_cmd, :output => "#{outdir}/reg_highres/stats/zstat_#{label}#{ext}", 
        :mask => "#{outdir}/reg_highres/mask#{ext}", :interp => "spline", **rb_opts      
    end
  end
  
  
  #--- TO STANDARD ---#
  
  # if given a regdir, this will transform the outputs to standard space
  if not regdir.nil? and tostandard
    l.title "Transform output to standard space"
    
    l.cmd "ln -sf #{regdir} #{outdir}/reg"
    l.cmd "mkdir #{outdir}/reg_standard 2> /dev/null"
    
    require 'gen_applywarp.rb'
    warp_cmd = "exfunc-to-standard"
    
    # transform mask and bg
    gen_applywarp l, nil, :reg => regdir.to_s, :input => "#{outdir}/mask#{ext}", 
      :warp => warp_cmd, :output => "#{outdir}/reg_standard/mask#{ext}", 
      :interp => "nn", **rb_opts
    gen_applywarp l, nil, :reg => regdir.to_s, :input => "#{outdir}/bgimage#{ext}", 
      :warp => warp_cmd, :output => "#{outdir}/reg_standard/bgimage#{ext}", 
      :interp => "spline", **rb_opts
    
    # also transform stat images
    l.cmd "mkdir #{outdir}/reg_standard/stats 2> /dev/null"
    labels.each_with_index do |label,i|
      l.info "transforming #{label}"
      
      gen_applywarp l, nil, :reg => regdir.to_s, :input => "#{statdir}/coef_#{label}#{ext}", 
        :warp => warp_cmd, :output => "#{outdir}/reg_standard/stats/coef_#{label}#{ext}", 
        :mask => "#{outdir}/reg_standard/mask#{ext}", :interp => "spline", **rb_opts
      gen_applywarp l, nil, :reg => regdir.to_s, :input => "#{statdir}/tstat_#{label}#{ext}", 
        :warp => warp_cmd, :output => "#{outdir}/reg_standard/stats/tstat_#{label}#{ext}", 
        :mask => "#{outdir}/reg_standard/mask#{ext}", :interp => "spline", **rb_opts
      gen_applywarp l, nil, :reg => regdir.to_s, :input => "#{statdir}/zstat_#{label}#{ext}", 
        :warp => warp_cmd, :output => "#{outdir}/reg_standard/stats/zstat_#{label}#{ext}", 
        :mask => "#{outdir}/reg_standard/mask#{ext}", :interp => "spline", **rb_opts      
    end
  end
  
  
  #--- END ---#
  
  l.title "Clean up"
  
  l.cmd "rm #{outdir}/tmp_all_runs#{ext}"
  l.cmd "rm #{outdir}/residuals#{ext}" unless oresiduals
  
  # Unset AFNI_DECONFLICT
  reset_afni_deconflict if overwrite
end


if __FILE__==$0
  task_analysis!
end
