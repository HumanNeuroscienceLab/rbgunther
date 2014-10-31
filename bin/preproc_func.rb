#!/usr/bin/env ruby
# 
#  preproc_func.rb
#
#  Following commands are run
#  1. Motion Correct => `func_motion_correct.rb`
#  2. Skull Strip => `func_skullstrip.rb`
#  3. Register => `func_register_to_highres.rb` and `func_register_to_standard.rb`
#  4. Apply Register => `gen_applywarp.rb`
#  5. Smooth => `func_smooth.rb`
#  6. Scale => `func_scale.rb`
#  7. Concatenate runs => internal
#
#  Note that for final output, I should have it both smoothed and unsmoothed.
#  
#  Created by Zarrar Shehzad on 2014-10-12
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
  
  opt :res_highres, "Resolution for functional time-series in highres space (e.g., if you want 2.5mm resolution to match your EPI; default is to use highres resolution)", :type => :string, :required => true
  opt :res_standard, "Resolution for functional time-series in standard space (e.g., if you want 2.5mm resolution to match your EPI; default is to use standard resolution)", :type => :string, :required => true
  opt :fwhms_highres, "Smoothness levels to apply to data in highres space", :type => :floats, :required => true
  opt :fwhms_standard, "Smoothness levels to apply to data in highres space", :type => :floats, :required => true
  
  opt :qadir, "Output directory with fmriqa results", :type => :string
  
  opt :threads, "Number of OpenMP threads to use with AFNI (otherwise defaults to environmental variable OMP_NUM_THREADS if set -> #{ENV['OMP_NUM_THREADS']})", :type => :integer
  
  opt :ext, "File extensions to use in all outputs", :type => :string, :default => ".nii.gz"
  opt :overwrite, "Overwrite existing output", :default => false
end
opts = Trollop::with_standard_exception_handling p do
  raise Trollop::HelpNeeded if ARGV.empty? # show help screen
  p.parse ARGV
end

# Gather inputs
inputs    = opts[:inputs].collect{|input| input.path.expand_path}
subject   = opts[:subject]
basedir   = opts[:sd].path.expand_path
name      = opts[:name]
tr        = opts[:tr]
keep      = opts[:keep]

res_highres     = opts[:res_highres]
res_standard    = opts[:res_highres]
fwhms_highres   = opts[:fwhms_highres]
fwhms_standard  = opts[:fwhms_standard]

qadir     = opts[:qadir]
qadir     = qadir.path.expand_path unless qadir.nil?

ext       = opts[:ext]
overwrite = opts[:overwrite]

threads   = opts[:threads]
threads   = ENV['OMP_NUM_THREADS'].to_i if threads.nil? and not ENV['OMP_NUM_THREADS'].nil?
threads   = 1 if threads.nil?

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
  brain:  "#{anatdir}/brain#{ext}", 
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
  mc:     OpenStruct.new({
    dir: "#{funcdir}/mc".path, 
    prefix: "#{funcdir}/mc/func", # outprefix
    workdir: "#{funcdir}/mc_work".path, 
    output: pruns.collect{|ri| "#{funcdir}/mc/func_run#{ri}_volreg#{ext}" }, 
    transform: pruns.collect{|ri| "#{funcdir}/mc/func_run#{ri}_mat_vr_aff12.1D" }, 
    maxdisp: pruns.collect{|ri| "#{funcdir}/mc/func_run#{ri}_maxdisp.1D" }, 
    motion: pruns.collect{|ri| "#{funcdir}/mc/func_run#{ri}_dfile.1D" }
  }), 
  head:   "#{funcdir}/func_mean#{ext}", 
  brain:  "#{funcdir}/func_mean_brain#{ext}", 
  mask:   "#{funcdir}/func_mean_brain_mask#{ext}", 
  regdir: "#{funcdir}/reg", 
  regworkdir: "#{funcdir}/reg_work", 
  highres: OpenStruct.new({
    dir: "#{funcdir}/to_highres".path, 
    brain: "#{funcdir}/to_highres/mean_brain.nii.gz", 
    mask: "#{funcdir}/to_highres/mask.nii.gz", 
    underlay: "#{funcdir}/to_highres/underlay.nii.gz", 
    mc: pruns.collect{|ri| "#{funcdir}/to_highres/func_run#{ri}_volreg#{ext}" },            # intermediate file
    smooth: pruns.collect{|ri| "#{funcdir}/to_highres/func_run#{ri}_volreg_fwhm%s#{ext}" }, # intermediate file
    scale: pruns.collect{|ri| "#{funcdir}/to_highres/func_run#{ri}_volreg_fwhm%s_scale#{ext}" }, # intermediate file
    final: pruns.collect{|ri| "#{funcdir}/to_highres/func_preproc_fwhm%s_run#{ri}#{ext}" }, 
    concatenate_prefix: "#{funcdir}/to_highres/func_preproc_fwhm%s_concat", 
    concatenate_blur: "#{funcdir}/to_highres/func_preproc_fwhm%s_concat_blur.1D"
  }), 
  standard: OpenStruct.new({
    dir: "#{funcdir}/to_standard".path, 
    brain: "#{funcdir}/to_standard/mean_brain.nii.gz", 
    mask: "#{funcdir}/to_standard/mask.nii.gz", 
    underlay: "#{funcdir}/to_standard/underlay.nii.gz", 
    mc: pruns.collect{|ri| "#{funcdir}/to_standard/func_run#{ri}_volreg#{ext}" },           # intermediate file
    smooth: pruns.collect{|ri| "#{funcdir}/to_standard/func_run#{ri}_volreg_fwhm%s#{ext}" },# intermediate file 
    scale: pruns.collect{|ri| "#{funcdir}/to_standard/func_run#{ri}_volreg_fwhm%s_scale#{ext}" }, # intermediate file
    final: pruns.collect{|ri| "#{funcdir}/to_standard/func_preproc_fwhm%s_run#{ri}#{ext}" }, 
    concatenate_prefix: "#{funcdir}/to_standard/func_preproc_fwhm%s_concat", 
    concatenate_blur: "#{funcdir}/to_standard/func_preproc_fwhm%s_concat_blur.1D"
  })
})

l.info "Checking output(s)"
quit_if_all_outputs_exist(l, funcdir) if not overwrite

l.info "Creating output directories if needed"
basedir.mkdir if not basedir.directory?
subdir.mkdir if not subdir.directory?
funcdir.mkdir if not funcdir.directory?
func.raw.dir.mkdir if not func.raw.dir.exist?
func.mc.dir.mkdir if not func.mc.dir.directory?
func.highres.dir.mkdir if not func.highres.dir.directory?
func.standard.dir.mkdir if not func.standard.dir.directory?
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


###
# Motion Correct
###

l.title "Motion Correct"

require 'func_motion_correct.rb'
func_motion_correct l, nil, :inputs => func.raw.inputs, :outprefix => func.mc.prefix, 
  :working => func.mc.workdir.to_s, :keepworking => keep, **rb_opts

l.cmd "ln -sf #{func.mc.prefix}_mean#{ext} #{func.head}"


###
# Skull-Strip
###

l.title "Skull-Strip"

require 'func_skullstrip.rb'
func_skullstrip l, nil, :head => func.head, :brain => func.brain, :mask => func.mask, 
  :dilate => "1", :plot => true, **rb_opts


###
# Register
###

l.title "Registration"

require 'func_register_to_highres.rb'
extra_opts = rb_opts.clone
extra_opts['working'] = func.regworkdir if keep
func_register_to_highres l, nil, :epi => func.brain, :anat => anat.brain, 
  :output => func.regdir, :threads => threads.to_s, **extra_opts

require 'func_register_to_standard.rb'
func_register_to_standard l, nil, :epireg => func.regdir, :anatreg => anat.regdir, 
  :threads => threads.to_s, **rb_opts


l.title "Apply Registration to Brain Mask"
require 'gen_applywarp.rb'

l.info "to native space"
extra_opts = rb_opts.clone
extra_opts[:dxyz] = res_highres unless res_highres.nil?
gen_applywarp l, nil, :input => func.mask, :reg => func.regdir, 
  :warp => 'exfunc-to-highres', :output => func.highres.mask, :interp => 'NN', 
  :threads => threads.to_s, **extra_opts

l.info "to standard space"
extra_opts = rb_opts.clone
extra_opts[:dxyz] = res_standard unless res_standard.nil?
gen_applywarp l, nil, :input => func.mask, :reg => func.regdir, 
  :warp => 'exfunc-to-standard', :output => func.standard.mask, :interp => 'NN', 
  :threads => threads.to_s, **extra_opts


l.title "Apply Registration to Mean Brain"

l.info "to native space"
extra_opts = rb_opts.clone
extra_opts[:dxyz] = res_highres unless res_highres.nil?
gen_applywarp l, nil, :input => func.brain, :reg => func.regdir, 
  :warp => 'exfunc-to-highres', :output => func.highres.brain, :interp => 'NN', 
  :threads => threads.to_s, **extra_opts

l.info "to standard space"
extra_opts = rb_opts.clone
extra_opts[:dxyz] = res_standard unless res_standard.nil?
gen_applywarp l, nil, :input => func.brain, :reg => func.regdir, 
  :warp => 'exfunc-to-standard', :output => func.standard.brain, :interp => 'NN', 
  :threads => threads.to_s, **extra_opts


l.title "Create the underlay"

l.info "to native space"
l.cmd "3dresample -inset #{func.regdir}/highres#{ext} -master #{func.highres.brain} -prefix #{func.highres.underlay}"

l.info "to standard space"
l.cmd "3dresample -inset #{func.regdir}/standard#{ext} -master #{func.standard.brain} -prefix #{func.standard.underlay}"


###
# Loop through each run
###

# This takes as input a filename in the working directory
# and then an output file
# It will mv the file 
# and then create a soft-link to from old to new location
def move_file(l, infile, outfile)
  l.cmd "mv #{infile} #{outfile}"
  l.cmd "ln -s #{outfile} #{infile}"
end

runs.each_with_index do |run,ri|
  l.title "Run #{run}"
  
  
  ###
  # Apply Register
  ###
  
  l.title "Apply Registration of 4D Functional Data"
  
  l.info "to native space"
  extra_opts = rb_opts.clone
  extra_opts[:dxyz] = res_highres unless res_highres.nil?
  gen_applywarp l, nil, :input => func.raw.inputs[ri], :reg => func.regdir, 
    :warp => 'exfunc-to-highres', :output => func.highres.mc[ri], :interp => 'NN', 
    :threads => threads.to_s, **extra_opts

  l.info "to standard space"
  extra_opts = rb_opts.clone
  extra_opts[:dxyz] = res_standard unless res_standard.nil?
  gen_applywarp l, nil, :input => func.raw.inputs[ri], :reg => func.regdir, 
    :warp => 'exfunc-to-standard', :output => func.standard.mc[ri], :interp => 'NN', 
    :threads => threads.to_s, **extra_opts
  
    
  ###
  # Smooth and Scale
  ###
  require 'func_smooth.rb' # TODO: use threads
  require 'func_scale.rb'
  
  # highres; messy i know
  fwhms_highres.each_with_index do |fwhm, fi|
    l.title "Smooth with #{fwhm}mm and then scale in highres space"
    sfwhm = fwhm.to_s.sub(".0", "")
    
    if fwhm == 0
      l.info "only masking to skip smoothing"
      l.cmd "3dcalc -a #{func.highres.mc[ri]} -b #{func.highres.mask} -expr 'a*step(b)' -prefix #{func.highres.smooth[ri] % sfwhm}"
    else
      l.info "#{fwhm}mm smoothing"
      func_smooth l, nil, :input => func.highres.mc[ri], :mask => func.highres.mask, 
        :fwhm => fwhm.to_s, :output => func.highres.smooth[ri] % sfwhm, 
        :threads => threads.to_s, **rb_opts
    end
    
    l.info "update the mask"
    l.cmd "fslmaths #{func.highres.smooth[ri] % sfwhm} -mas #{func.highres.mask} -Tmin -bin #{func.highres.mask}"
    
    l.info "scale (divide by mean)"
    func_scale l, nil, :input => func.highres.smooth[ri] % sfwhm, :mask => func.highres.mask, 
      :output => func.highres.scale[ri] % sfwhm, :savemean => true
    
    l.info "final soft-link"
    move_file l, func.highres.scale[ri] % sfwhm, func.highres.final[ri] % sfwhm
    
    if not keep
      l.info "clean up some unneeded files"
      FileUtils.remove [func.highres.smooth[ri] % sfwhm, func.highres.scale[ri] % sfwhm], :verbose => true
    end
  end
  
  # standard; messy i know
  fwhms_standard.each_with_index do |fwhm, fi|
    l.title "Smooth with #{fwhm}mm and then scale in standard space"
    sfwhm = fwhm.to_s.sub(".0", "")
    
    if fwhm == 0
      l.info "only masking to skip smoothing"
      l.cmd "3dcalc -a #{func.standard.mc[ri]} -b #{func.standard.mask} -expr 'a*step(b)' -prefix #{func.standard.smooth[ri] % sfwhm}"
    else
      l.info "#{fwhm}mm smoothing"
      func_smooth l, nil, :input => func.standard.mc[ri], :mask => func.standard.mask, 
        :fwhm => fwhm.to_s, :output => func.standard.smooth[ri] % sfwhm, 
        :threads => threads.to_s, **rb_opts
    end
    
    l.info "update the mask"
    l.cmd "fslmaths #{func.standard.smooth[ri] % sfwhm} -mas #{func.standard.mask} -Tmin -bin #{func.standard.mask}"
    
    l.info "scale (divide by mean)"
    func_scale l, nil, :input => func.standard.smooth[ri] % sfwhm, :mask => func.standard.mask, 
      :output => func.standard.scale[ri] % sfwhm, :savemean => true
    
    l.info "final soft-link"
    move_file l, func.standard.scale[ri] % sfwhm, func.standard.final[ri] % sfwhm
    
    if not keep
      l.info "clean up some unneeded files"
      FileUtils.remove [func.standard.smooth[ri] % sfwhm, func.standard.scale[ri] % sfwhm], :verbose => true
    end
  end
  
  if not keep
    l.info "Clean up some more unneded files".magenta
    FileUtils.remove [ func.highres.mc[ri], func.standard.mc[ri] ], :verbose => true
  end
end


###
# Remove run effects and concatenate data
###

require 'func_combine_runs.rb'

fwhms_highres.each_with_index do |fwhm, fi|
  sfwhm = fwhm.to_s.sub(".0", "")
  
  l.title "Concatenate runs for #{sfwhm}mm smoothed data in highres space"
  func_combine_runs l, nil, :inputs => func.highres.final.collect{|f| f % sfwhm}, :mask => func.highres.mask, 
    :outprefix => func.highres.concatenate_prefix % sfwhm, :motion => "#{func.mc.prefix}_motion_demean.1D", 
    :tr => tr, :njobs => threads.to_s, **rb_opts
end

fwhms_standard.each_with_index do |fwhm, fi|
  sfwhm = fwhm.to_s.sub(".0", "")
  
  l.title "Concatenate runs for #{sfwhm}mm smoothed data in standard space"
  func_combine_runs l, nil, :inputs => func.standard.final.collect{|f| f % sfwhm}, :mask => func.standard.mask, 
    :outprefix => func.standard.concatenate_prefix % sfwhm, :motion => "#{func.mc.prefix}_motion_demean.1D", 
    :tr => tr, :njobs => threads.to_s, **rb_opts  
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

FileUtils.ln_sf "#{SCRIPTDIR}/html/css", "#{func.repdir}/", :verbose => true
FileUtils.ln_sf "#{SCRIPTDIR}/html/js", "#{func.repdir}/", :verbose => true
FileUtils.ln_sf "#{SCRIPTDIR}/html/img", "#{func.repdir}/", :verbose => true

# html output    
layout_file     = SCRIPTDIR + "html/func/layout.html.erb"

# main variables
@subject        = subject
@runs           = runs
@anat           = anat
@func           = func
@aclass         = "class='active'"
if not qadir.nil?
  @qahtml       = "#{qadir}/rawqa_#{subject}/index.html"
else
  @qahtml       = "#"
end

# loop through each page
page_names      = ["index", "motion", "skull_strip", "registration"]
page_titles     = ["Home", "Motion Correction", "Skull Stripping", "Registration"]
page_names.each_with_index do |name, i|
  l.info "...#{name}".magenta
  
  report_file     = "#{func.repdir}/#{name}.html"
  body_file       = SCRIPTDIR + "html/func/#{name}.html.erb"
  @title    = "#{page_titles[i]} - Functional - Subject: #{subject}"
  @active   = name
  
  # body
  @body     = ""
  text      = File.open(body_file).read
  erbified  = ERB.new(text).result(binding)
  @body    += "\n #{erbified} \n"
  
  # whole page
  text      = File.open(layout_file).read
  erbified  = ERB.new(text).result(binding)
  File.open(report_file, 'w') { |file| file.write(erbified) }
end


###
# Finalize
###

l.title "End"

# Unset AFNI_DECONFLICT
reset_afni_deconflict if overwrite

# Unset Threads
reset_omp_threads if not threads.nil?
