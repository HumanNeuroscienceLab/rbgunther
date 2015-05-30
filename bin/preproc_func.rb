#!/usr/bin/env ruby
# 
#  preproc_func.rb
#
#  Following commands are run
#  1. Motion Correct, Skull Strip, Smoothing, Temporal Filter, Normalization => `func_filter.rb`
#  2. Register => `func_register_to_highres.rb` and `func_register_to_standard.rb`
#  3. Compcor
#  4. Concatenate runs => internal
#  
#  Created by Zarrar Shehzad on 2014-12-30
# 

# require 'pry'
# binding.pry


###
# SETUP
###

require 'pathname'
SCRIPTDIR   = Pathname.new(__FILE__).realpath.dirname.dirname
SCRIPTNAME  = Pathname.new(__FILE__).basename.sub_ext("")
CDIR        = SCRIPTDIR + "bin/"
DDIR        = SCRIPTDIR + "data/"

# add lib directory to ruby path
$: << SCRIPTDIR + "lib" # will be scriptdir/lib
$: << SCRIPTDIR + "bin" # will be scriptdir/bin

require 'fileutils'
require 'for_commands.rb' # provides various function such as 'run'
require 'for_afni.rb'     # functions specific to afni
require 'colorize'        # allows adding color to output
require 'erb'             # for interpreting erb to create report pages
require 'trollop'         # command-line parsing
require 'ostruct'         # for storing/accessing anat paths

# Process command-line inputs
p = Trollop::Parser.new do
  banner "Usage: #{File.basename($0)} -i func_run01.nii.gz ... func_runN.nii.gz -s subject-id -n func-name --sd subjects-directory (--threads num-threads --overwrite)\n"
  opt :inputs, "Input functional images", :type => :strings, :required => true
  opt :subject, "Subject ID", :type => :string, :required => true
  opt :sd, "Directory with subject folders", :type => :string, :required => true
  opt :name, "Name of functional data for output directory", :type => :string, :required => true
  opt :tr, "TR of your functional data", :type => :string, :required => true
  opt :keep, "Keep any intermediate files or working directories (e.g., motion correct and register to highres)", :default => false
  
  opt :fwhm, "Smoothness level in mm (0 = skip)", :type => :float, :required => true
  opt :save_unsmooth, "If fwhm given, then will also save unsmoothed output", :default => false
  opt :hp, "High-pass filter in seconds (-1 = skip)", :type => :float, :required => true
  
  opt :nobbr, "Skips doing BBR", :default => false
  
  opt :do, "Steps of preprocessing to complete. Options are: all (default), filter (motion correction, smoothing, filtering), register, compcor, concat, and unsmooth", :default => ["all"], :type => :strings
  
  opt :qadir, "Output directory with fmriqa results", :type => :string
  
  opt :threads, "Number of OpenMP threads to use with AFNI (otherwise defaults to environmental variable OMP_NUM_THREADS if set -> #{ENV['OMP_NUM_THREADS']})", :type => :integer, :default => 1
  
  opt :ext, "File extensions to use in all outputs", :type => :string, :default => ".nii.gz"
  opt :overwrite, "Overwrite existing output", :default => false
end
opts = Trollop::with_standard_exception_handling p do
  raise Trollop::HelpNeeded if ARGV.empty? # show help screen
  p.parse ARGV
end

# Gather inputs
inputs    = opts[:inputs].collect{|input| input.path.expand_path}
str_inputs= inputs.join " "
subject   = opts[:subject]
basedir   = opts[:sd].path.expand_path
name      = opts[:name]
tr        = opts[:tr]
keep      = opts[:keep]

fwhm      = opts[:fwhm]
hp        = opts[:hp]

nobbr     = opts[:nobbr]  

qadir     = opts[:qadir]
qadir     = qadir.path.expand_path unless qadir.nil?

ext       = opts[:ext]
overwrite = opts[:overwrite]

threads   = opts[:threads]
threads   = ENV['OMP_NUM_THREADS'].to_i if threads.nil? and not ENV['OMP_NUM_THREADS'].nil?
threads   = 1 if threads.nil?

# Steps to complete
do_opts   = ["filter", "register", "compcor", "concat", "unsmooth"]
do_steps  = opts[:do]
## deal with all
p.die(:do, "argument 'all' must be provided alone") if do_steps.include?("all") and do_steps.count > 1
do_steps  = do_opts.clone if do_steps[0] == 'all'
## deal with rest
steps     = Hash[do_opts.collect{ |v| [v, false] }]
do_steps.each do |step|
  p.die(:do, "unknown argument #{step}. must be one of #{do_opts.join(', ')}") if not do_opts.include? step
  steps[step] = true
end

# Additional paths
subdir    = basedir + subject
anatdir   = subdir + "anat"
funcdir   = subdir + name

nruns     = inputs.count
runs      = 1...(nruns+1)
pruns     = runs.collect{|run| "%02i" % run}

# Set options to pass to afni
af_opts =
  if overwrite then " -overwrite"
  else ""
end

# Set options to pass to ruby functions/scripts
rb_opts = {}
rb_opts[:overwrite] = true if overwrite
rb_opts[:ext] = ext

str_rb_opts = []
str_rb_opts.push "--overwrite" if overwrite
str_rb_opts.push "--ext #{ext}"
str_rb_opts = str_rb_opts.join " "

# just to the standard output for now
l = create_logger()


###
# Setup
###

l.title "Setup"

# Set AFNI_DECONFLICT
set_afni_to_overwrite if overwrite
# Set Threads
set_omp_threads threads if not threads.nil?

l.info "Generating input directory/file structure"
anat = OpenStruct.new({
  head: "#{anatdir}/head#{ext}", 
  brain: "#{anatdir}/brain#{ext}", 
  segdir: "#{anatdir}/segment", 
  wmseg: "#{anatdir}/segment/wmseg#{ext}", 
  regdir: "#{anatdir}/reg"
})

l.info "Checking input(s)"
quit_if_inputs_dont_exist l, *inputs
quit_if_inputs_dont_exist l, anatdir, anat.brain, anat.regdir

l.info "Generating output directory/file structure"
func = OpenStruct.new({
  dir: funcdir, 
  repdir: "#{funcdir}/report".path, 
  raw:    OpenStruct.new({
    dir: "#{funcdir}/raw".path, 
    inputs: pruns.collect{|ri| "#{funcdir}/raw/func_run#{ri}#{ext}" }, 
    all: pruns.collect{|ri| "#{funcdir}/raw/func_run#{ri}#{ext}" }.join(" ")
  }), 
  unfilter: OpenStruct.new({
    dir: "#{funcdir}/preproc_0mm".path, 
    workdir: "#{funcdir}/preproc_0mm/working".path, 
    output: pruns.collect{|ri| "#{funcdir}/preproc_0mm/filtered_func_run#{ri}#{ext}" }, 
  }), 
  filter: OpenStruct.new({
    dir: "#{funcdir}/preproc".path, 
    workdir: "#{funcdir}/preproc/working".path, 
    mc: "#{funcdir}/preproc/mc".path, 
    output: pruns.collect{|ri| "#{funcdir}/preproc/filtered_func_run#{ri}#{ext}" }, 
    transform: pruns.collect{|ri| "#{funcdir}/preproc/mc/func_run#{ri}_mat_vr.aff12.1D" }, 
    maxdisp: pruns.collect{|ri| "#{funcdir}/preproc/mc/func_run#{ri}_maxdisp.1D" }, 
    motion: pruns.collect{|ri| "#{funcdir}/preproc/mc/func_run#{ri}_dfile.1D" }
  }), 
  compcor: OpenStruct.new({
    dir: "#{funcdir}/preproc/compcor".path, 
    output: pruns.collect{|ri| "#{funcdir}/preproc/compcor/run#{ri}" }, 
    ts: pruns.collect{|ri| "#{funcdir}/preproc/compcor/run#{ri}/compcor_comps_nsim.1D" }, 
  }),
  brain: "#{funcdir}/mean_func#{ext}", 
  mask: "#{funcdir}/mask#{ext}", 
  motion: "#{funcdir}/motion.1D", 
  comps: "#{funcdir}/compcor.1D", 
  combine_prefix: "#{funcdir}/filtered_func_data", 
  combine_0mm_prefix: "#{funcdir}/filtered_func_0mm_data", 
  regdir: "#{funcdir}/reg"
})

l.info "Checking output(s)"
quit_if_all_outputs_exist(l, funcdir) if not overwrite

l.info "Creating output directories if needed"
basedir.mkdir if not basedir.directory?
subdir.mkdir if not subdir.directory?
funcdir.mkdir if not funcdir.directory?
func.raw.dir.mkdir if not func.raw.dir.exist?
func.filter.dir.mkdir if not func.filter.dir.directory?
func.repdir.mkdir if not func.repdir.directory?

l.info "Creating file-backed logger"
l = create_logger("#{func.repdir}/log", overwrite)


###
# Copy over input data
###

l.title "Copy Input Data"
runs.each_with_index do |run,ri|
  l.cmd "ln -sf #{inputs[ri]} #{func.raw.inputs[ri]}"
end


if steps['filter']
  
  ###
  # Filter Data
  ###

  l.title "Filter"

  require 'func_filter.rb'
  func_filter l, nil, :inputs => func.raw.inputs, :outdir => func.filter.dir.to_s, 
    :working => func.filter.workdir.to_s, :keepworking => keep, 
    :fwhm => fwhm.to_s, :hp => hp.to_s, **rb_opts  
  
  l.cmd "3dcalc -a #{func.filter.dir}/mean_func#{ext} -expr a -prefix #{func.brain} -float"
  l.cmd "3dcalc -a #{func.filter.dir}/mask#{ext} -expr a -prefix #{func.mask} -byte"
  l.cmd "cp #{func.filter.mc}/func_motion_demean.1D #{func.motion}"
  
end

if steps['register']
  ###
  # Register
  ###

  l.title "Registration"

  require 'func_register_to_highres.rb'
  l.cmd "fslmaths #{anat.segdir}/highres_pve_2.nii.gz -thr 0.5 -bin #{anat.wmseg}"
  func_register_to_highres l, nil, :epi => func.brain.to_s, :anat => anat.brain.to_s, :output => func.regdir.to_s,  :anathead => anat.head.to_s, :wmseg => anat.wmseg.to_s, :nobbr => nobbr, **rb_opts
  
  require 'func_register_to_standard.rb'
  func_register_to_standard l, nil, :epireg => func.regdir.to_s, :anatreg => anat.regdir.to_s, **rb_opts
end

if steps['compcor']
  
  l.title "CompCor"
  
  func.compcor.dir.mkdir if not func.compcor.dir.directory?
  pruns.each_with_index do |run, ri|  
    l.info "run #{run}"
    l.cmd "func_compcor.R \
      -i #{func.filter.output[ri]} \
      -m #{func.mask} \
      -w '#{anatdir}/freesurfer/volume/left_cerebral_white_matter.nii.gz #{anatdir}/freesurfer/volume/right_cerebral_white_matter.nii.gz' \
      -c '#{anatdir}/freesurfer/volume/left_lateral_ventricle.nii.gz #{anatdir}/freesurfer/volume/right_lateral_ventricle.nii.gz #{anatdir}/freesurfer/volume/csf.nii.gz' \
      -r #{func.regdir} \
      --hp #{hp} \
      -o #{func.compcor.output[ri]} \
      --threads #{threads} \
      --nsim 100 \
      -v"
  end
  
  l.info "Combine compcor time-series"
  l.cmd "cat #{func.compcor.ts.join(' ')} > #{func.comps}"
  
end

if steps['concat']
  
  ###
  # Remove run effects and concatenate data
  ###

  require 'func_combine_runs.rb'
  
  sfwhm = fwhm.to_s.sub(".0", "")
  l.title "Concatenate runs for #{sfwhm}mm smoothed data"
  if steps['compcor']
    func_combine_runs l, nil, :inputs => func.filter.output, :mask => func.mask.to_s, 
      :outprefix => func.combine_prefix.to_s, :motion => func.motion.to_s, :covars => ["compcor", func.comps.to_s], 
      :polort => "0", :tr => tr, :njobs => threads.to_s, **rb_opts  
  else
    func_combine_runs l, nil, :inputs => func.filter.output.to_s, :mask => func.mask.to_s, 
      :outprefix => func.combine_prefix.to_s, :motion => func.motion.to_s, 
      :polort => "0", :tr => tr, :njobs => threads.to_s, **rb_opts  
  end
  
end

if steps['unsmooth']
  if fwhm > 0
    l.title "Unsmoothed output"
    
    l.info "Filter"
    require 'func_filter.rb'
    func_filter l, nil, :inputs => func.raw.inputs, :outdir => func.unfilter.dir.to_s,
      :working => func.unfilter.workdir.to_s, :keepworking => keep, 
      :mcdir => func.filter.mc.to_s, :fwhm => "0", :hp => hp.to_s, **rb_opts
    
    l.info "Concatenate runs for unsmoothed data"
    require 'func_combine_runs.rb'
    if steps['compcor']
      func_combine_runs l, nil, :inputs => func.unfilter.output, :mask => func.mask.to_s, 
        :outprefix => func.combine_0mm_prefix.to_s, :motion => func.motion.to_s, :covars => ["compcor", func.comps.to_s], 
        :polort => "0", :tr => tr, :njobs => threads.to_s, **rb_opts  
    else
      func_combine_runs l, nil, :inputs => func.unfilter.output, :mask => func.mask.to_s, 
        :outprefix => func.combine_0mm_prefix.to_s, :motion => func.motion.to_s, 
        :polort => "0", :tr => tr, :njobs => threads.to_s, **rb_opts  
    end
  end
end

###
# HTML Page
###

# TODO:
# - test index
# - test motion
# - test skull-strip
# - test registration

l.title "Build Report Page"
l.warn "FOR NOW SKIPPING THE REPORT MAKING"

FileUtils.ln_sf "#{SCRIPTDIR}/html/css", "#{func.repdir}/", :verbose => true
FileUtils.ln_sf "#{SCRIPTDIR}/html/js", "#{func.repdir}/", :verbose => true
FileUtils.ln_sf "#{SCRIPTDIR}/html/img", "#{func.repdir}/", :verbose => true

## html output    
#layout_file     = SCRIPTDIR + "html/func/layout.html.erb"
#
## main variables
#@subject        = subject
#@runs           = runs
#@anat           = anat
#@func           = func
#@aclass         = "class='active'"
#if not qadir.nil?
#  @qahtml       = "#{qadir}/rawqa_#{subject}/index.html"
#else
#  @qahtml       = "#"
#end
#
## loop through each page
#page_names      = ["index", "motion", "skull_strip", "registration"]
#page_titles     = ["Home", "Motion Correction", "Skull Stripping", "Registration"]
#page_names.each_with_index do |name, i|
#  l.info "...#{name}".magenta
#  
#  report_file     = "#{func.repdir}/#{name}.html"
#  body_file       = SCRIPTDIR + "html/func/#{name}.html.erb"
#  @title    = "#{page_titles[i]} - Functional - Subject: #{subject}"
#  @active   = name
#  
#  # body
#  @body     = ""
#  text      = File.open(body_file).read
#  erbified  = ERB.new(text).result(binding)
#  @body    += "\n #{erbified} \n"
#  
#  # whole page
#  text      = File.open(layout_file).read
#  erbified  = ERB.new(text).result(binding)
#  File.open(report_file, 'w') { |file| file.write(erbified) }
#end


###
# Finalize
###

l.title "End"

# Unset AFNI_DECONFLICT
reset_afni_deconflict if overwrite

# Unset Threads
reset_omp_threads if not threads.nil?
