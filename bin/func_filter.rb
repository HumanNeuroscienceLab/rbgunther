#!/usr/bin/env ruby
# 
#  func_filter.rb
#
#  Following commands are run
#  1. Motion Correct => `func_motion_correct.rb`
#  2. Skull Strip => `bet` (eventually move this out to func_skullstrip.rb)
#  3. Smooth => `susan` (eventually move this out to func_smooth.rb)
#  4. Intensity Normalize => `fslmaths -ing` (eventually move this out to func_scale.rb)
#  5. Highpass Filter => `fslmaths -bptf` (eventually move this out to func_bptf.rb)
#
#  Note that for final output, I should have it both smoothed and unsmoothed.
#  
#  Created by Zarrar Shehzad on 2014-12-20
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
def func_filter(l, args = [], opts = {})
  cmdline = cli_wrapper(args, opts)
  l.info "Running: #{Pathname.new(__FILE__).basename} #{cmdline}"
  func_filter!(cmdline, l)
end


def func_filter!(cmdline = ARGV, l = nil)
  #--- USER ARGS ---#

  # Process command-line inputs
  p = Trollop::Parser.new do
    banner "Usage: #{File.basename($0)} -o output-directory -w working-directory --keepworking -i func-file1 ... func-fileN\n"
    opt :inputs, "Path to functional runs to preprocess", :type => :strings, :required => true
    opt :outdir, "Output directory", :type => :string, :required => true
    opt :working, "Path to working directory", :type => :string, :required => true
    opt :keepworking, "Keep working directory", :default => false
    
    opt :fwhm, "Smoothness level in mm (0 = skip)", :type => :float, :required => true
    opt :hp, "High-pass filter in seconds (-1 = skip)", :type => :float, :required => true
    opt :lp, "Low-pass filter in seconds (-1 = skip)", :type => :float, :required => true, :default => -1
    
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
  outdir  = opts[:outdir].path.expand_path
  workdir = opts[:working].path.expand_path
  workprefix = "prefiltered_func_data"
  keepwork= opts[:keepworking]
  
  ext         = opts[:ext]
  overwrite   = opts[:overwrite]
  
  fwhm        = fwhm
  hp          = hp
  lp          = lp
  
  log_prefix  = opts[:log]
  log_prefix  = log_prefix.path.expand_path unless log_prefix.nil?
  l           = create_logger(log_prefix, overwrite) if l.nil?
  
  # Set options to pass to afni
  af_opts =
    if overwrite then " -overwrite"
    else ""
  end

  # Set options to pass to ruby functions/scripts
  rb_opts = {}
  rb_opts[:overwrite] = true if overwrite
  rb_opts[:ext] = ext
  
  # Runs
  nruns	    = inputs.count
  runs      = 1...(nruns+1)
  pruns     = runs.collect{|run| "%02i" % run}
  
  
  #--- SETUP ---#

  # Set AFNI_DECONFLICT
  set_afni_to_overwrite if overwrite

  l.info "Checking inputs"
  l.fatal("inputs don't exist") if any_inputs_dont_exist l, exfunc, infunc

  l.info "Checking outputs"
  l.fatal("working directory '#{workdir}' exists, exiting") if !overwrite and workdir.exist?
  l.fatal("some output files exist, exiting") if !overwrite and all_outputs_exist l, workdir
  outdir.mkdir if not outdir.directory?
  
  l.info "Changing directory to '#{workdir}'"
  workdir.mkdir if not workdir.directory?
  workdir = workdir.realpath
  Dir.chdir workdir
  
  
  #--- MOTION CORRECT ---#

  l.title "Motion Correct"
  
  require 'func_motion_correct.rb'
  func_motion_correct l, nil, :inputs => inputs, :outprefix => "#{outdir}/mc/func", 
    :working => "#{outdir}/mc_work", :keepworking => keepwork, **rb_opts
  
  
  #--- SKULL STRIP ---#
  
  l.title "Skull Strip"
  
  l.info "Bet"
  l.cmd "bet2 #{outdir}/mc/func_mean#{ext} -f 0.3 -n -m mask"
  l.cmd "immv mask_mask mask1"
  
  l.info "Apply initial masks"
  pruns.each do |run|
    l.info "...run #{run}"
    l.cmd "fslmaths #{outdir}/mc/func_run#{run}_volreg#{ext} -mas mask1 #{workprefix}_bet_run#{run}"
  end  
  
  l.info "Get the max of the robust range"
  robust_maxes = pruns.each.collect do |run|
    `fslstats #{workprefix}_bet_run#{run} -p 2 -p 98 | awk '{print $2}'`.to_f
  end
  robust_max = robust_maxes.max
  l.info "... robust_max = #{robust_max}"
  
  l.info "Threshold background signal using 10% of robust range"
  pruns.each do |run|
    l.cmd "fslmaths #{workprefix}_bet_run#{run} -thr #{robust_max.to_f * 0.1} -Tmin -bin mask2_run#{run} -odt char"
  end
  l.cmd "3dMean -mask_inter -prefix mask2#{ext} mask2_run*#{ext}"
  
  l.info "Get median value within the second more constrained mask"
  def median(array)
    sorted = array.sort
    len = sorted.length
    return (sorted[(len - 1) / 2] + sorted[len / 2]) / 2.0
  end
  median_vals = pruns.each.collect do |run|
    `fslmaths #{workprefix}_bet -k mask2`.to_f
  end
  median_val = median(median_vals)
  l.info "... median = #{median_val}"
  
  l.info "Dilate the constrained mask for the final liberal mask"
  l.cmd "fslmaths mask2 -dilF mask3"
  
  l.info "Apply final brain mask"
  pruns.each do |run|
    l.cmd "fslmaths #{outdir}/mc/func_run#{run}_volreg#{ext} -mas mask3 #{workprefix}_thresh_run#{run} -odt float"
  end
  
  l.info "Mean functional"
  pruns.each do |run|
    l.cmd "fslmaths #{workprefix}_thresh_run#{run} -Tmean mean_func_run#{run}"
  end
  l.cmd "3dMean -prefix mean_func#{ext} mean_func_run*#{ext}"
  
  
  #--- SMOOTHING ---#
  
  l.title "Smoothing"
  
  if fwhm == 0
    l.info "Skipping smoothing"
    pruns.each do |run|
      l.cmd "ln -sf #{workprefix}_thresh_run#{run}#{ext} #{workprefix}_smooth_run#{run}#{ext}"
    end
  else  
    l.info "Smoothing to #{fwhm}mm"
    brightness_thr = median_val.to_f * 0.75
    sigma = fwhm / Math.sqrt(8 * Math.log(2))
    pruns.each do |run|
      l.cmd "susan #{workprefix}_thresh_run#{run} #{brightness_thr} #{sigma} 3 1 1 mean_func #{brightness_thr} #{workprefix}_smooth_run#{run}"
      l.cmd "fslmaths #{workprefix}_smooth_run#{run} -mas mask3 #{workprefix}_smooth_run#{run}"
    end
  end
  
  
  #--- INTENSITY NORMALIZATION ---#
  
  l.title "Intensity Normalization"
  
  l.info "Mean 4D intensity normalization"
  pruns.each do |run|
    l.cmd "fslmaths #{workprefix}_smooth_run#{run} -ing 10000 #{workprefix}_intnorm_run#{run}"
  end
  
  
  #--- Band-Pass Filter ---#
  
  l.title "Band-Pass Filter"
  
  hp_sigma=hp/2.0 unless hp == -1
  lp_sigma=lp/2.0 unless lp == -1
  
  if (hp == -1) and (lp == -1)
    l.info "Skipping filter"
    l.cmd "ln -sf #{workprefix}_intnorm_run#{run} #{workprefix}_tempfilt_run#{run}"
  else
    l.cmd "Filtering"
    l.cmd "fslmaths #{workprefix}_intnorm_run#{run} -Tmean #{workprefix}_tempMean_run#{run}"
    l.cmd "fslmaths #{workprefix}_intnorm_run#{run} -bptf #{hp_sigma} #{lp_sigma} -add #{workprefix}_tempMean_run#{run} #{workprefix}_tempfilt_run#{run}"
  end
  
  
  #--- End ---#
  
  l.title "Copy output files"
  
  l.info "Mean Functionals"
  l.cmd "fslmaths mean_func#{ext} #{outdir}/mean_func#{ext}"
  l.cmd "ln -sf #{outdir}/mean_func#{ext} #{outdir}/example_func#{ext}"
  
  l.info "Mask"
  l.cmd "fslmaths mask3 #{outdir}/mask"
  
  l.info "Functional runs"
  pruns.each do |run|
    l.cmd "fslmaths #{workprefix}_tempfilt_run#{run} #{outdir}/filtered_func_run#{run}"
  end
  
  
  l.title "Clean up"

  # clean up the working directory
  if not keepwork
    l.info "Removing working directory"
    Dir.chdir outdir
    l.cmd "rm #{workdir}/*"
    l.cmd "rmdir #{workdir}"
  end
  
  # Unset AFNI_DECONFLICT
  reset_afni_deconflict if overwrite
  
end


if __FILE__==$0
  func_filter!
end
