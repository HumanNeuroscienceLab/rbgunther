#!/usr/bin/env ruby
# 
#  preproc_anat.rb
#
#  Some outputs:
# => subject dir: subjects_directory/subject
# => anat dir:    subjects_directory/subject/anat
# => reg dir:     subjects_directory/subject/anat/reg
# => seg dir:     subjects_directory/subject/anat/segment
#
#  Created by Zarrar Shehzad on 2014-10-06
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

# default template
default_template = File.join(ENV['FSLDIR'], "data", "standard", "MNI152_T1_1mm_brain.nii.gz")

require 'fileutils'
require 'for_commands.rb' # provides various function such as 'run'
require 'for_afni.rb'     # functions specific to afni
require 'colorize'        # allows adding color to output
require 'erb'             # for interpreting erb to create report pages
require 'trollop'         # command-line parsing
require 'ostruct'         # for storing/accessing anat paths

# Process command-line inputs
p = Trollop::Parser.new do
  banner "Usage: #{File.basename($0)} -i highres.nii.gz -s subject-id --sd subjects-directory --freedir freesurfer-subjects-directory (--threads num-threads --overwrite)\n"
  opt :input, "Input anatomical image", :type => :string, :required => true
  opt :subject, "Subject ID", :type => :string, :required => true
  opt :sd, "Directory with subject folders", :type => :string, :required => true
  opt :freedir, "Freesurfer subjects directory", :type => :string # or default to something #TODO: option to skip freesurfer if run?
  opt :template, "Brain template to use for registration", :type => :string, :default => default_template
  opt :dxyz, "Resolution for the SUMA aligned output. Should be that of your exfunc.", :type => :string, :required => true
  
  opt :threads, "Number of OpenMP threads to use with AFNI (otherwise defaults to environmental variable OMP_NUM_THREADS if set -> #{ENV['OMP_NUM_THREADS']})", :type => :integer
  
  opt :ext, "File extensions to use in all outputs", :type => :string, :default => ".nii.gz"
  opt :overwrite, "Overwrite existing output", :default => false
end
opts = Trollop::with_standard_exception_handling p do
  raise Trollop::HelpNeeded if ARGV.empty? # show help screen
  p.parse ARGV
end

# Gather inputs
input     = opts[:input].path.expand_path
subject   = opts[:subject]
basedir   = opts[:sd].path.expand_path
freedir   = opts[:freedir]
template  = opts[:template].path.expand_path
dxyz      = opts[:dxyz]

# Additional paths
subdir    = basedir + subject
outdir    = subdir + "anat"

ext       = opts[:ext]
overwrite = opts[:overwrite]

threads   = opts[:threads]
threads   = ENV['OMP_NUM_THREADS'].to_i if threads.nil? and not ENV['OMP_NUM_THREADS'].nil?
threads   = 1 if threads.nil?

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

# TODO: update the functions to take the logger
# Set AFNI_DECONFLICT
set_afni_to_overwrite if overwrite
# Set Threads
set_omp_threads threads if not threads.nil?

l.info "Checking input(s)"
quit_if_inputs_dont_exist(l, input)

l.info "Checking output(s)"
basedir.mkdir if not basedir.directory?
subdir.mkdir if not subdir.directory?
quit_if_all_outputs_exist(l, outdir) if not overwrite
outdir.mkdir if not outdir.directory?

l.info "Creating file-backed logger"
l = create_logger("#{outdir}/report/log", overwrite)

l.info "Generating output directory/file structure"
anat = OpenStruct.new({
  head:   "#{outdir}/head.nii.gz", 
  brain:  "#{outdir}/brain.nii.gz", 
  mask:   "#{outdir}/brain_mask.nii.gz", 
  head_prefix: "#{outdir}/head",          # use prefix for png outputs
  mask_prefix: "#{outdir}/brain_mask", 
  regdir: "#{outdir}/reg", 
  segdir: "#{outdir}/segment", 
  repdir: "#{outdir}/report"
})
l.debug "anat directory: #{outdir}"
anat.to_h.each_pair do |k,v|
  l.debug "* #{k} => #{v}"
end


###
# Copy over input data
###

l.title "Copy input data into our output directory"
l.cmd "3dcopy#{af_opts} #{input} #{anat.head}"


###
# Skull-Strip
###

l.title "Skull Strip"
require 'anat_skullstrip.rb'
anat_skullstrip l, nil, :head => anat.head, :outdir => outdir.to_s, :freedir => "#{freedir}/#{subject}", :threads => threads.to_s, :plot => true, **rb_opts


###
# Register
###

l.title "Register anatomical to standard space"
require 'anat_register_to_standard.rb'
anat_register_to_standard l, nil, :input => anat.brain, :template => template.to_s, :output => anat.regdir, :threads => threads.to_s, **rb_opts


###
# Segment
###

l.title "Segment the brain"
require 'anat_segment.rb'
anat_segment l, nil, :input => anat.brain, :reg => anat.regdir, :output => anat.segdir, **rb_opts


###
# Freesurfer
###

l.title "Freesurfer the brain"
require 'anat_freesurfer.rb'
anat_freesurfer l, nil, :freedir => "#{freedir}/#{subject}", :outdir => "#{outdir}/freesurfer", :threads => threads.to_s, **rb_opts


###
# SUMA
###

l.title "Freesurfer to SUMA the brain"
require 'anat_suma.rb'
anat_suma l, nil, :freedir => "#{freedir}/#{subject}", :anatreg => anat.regdir, :dxyz => dxyz, **rb_opts


###
# HTML Page
###

l.title "Generate log/report pages"

l.cmd "mkdir #{anat.repdir}" if not anat.repdir.path.directory?

# TODO: put ln_s and ln_sf or fileutils.ln_... into the logger
FileUtils.ln_sf "#{SCRIPTDIR}/html/css", "#{anat.repdir}/", :verbose => true
FileUtils.ln_sf "#{SCRIPTDIR}/html/js", "#{anat.repdir}/", :verbose => true
FileUtils.ln_sf "#{SCRIPTDIR}/html/img", "#{anat.repdir}/", :verbose => true

# html output    
layout_file     = SCRIPTDIR + "html/anat/layout.html.erb"

# main variables
@subject        = subject
@anat           = anat
@aclass         = "class='active'"

# loop through each page
page_names      = ["index", "skull_strip", "registration"]
page_titles     = ["Home", "Skull Stripping", "Registration"]
page_names.each_with_index do |name, i|
  l.info "...#{name}"
  
  report_file     = "#{anat.repdir}/#{name}.html"
  body_file       = SCRIPTDIR + "html/anat/#{name}.html.erb"
  @title    = "#{page_titles[i]} - Anatomical - Subject: #{subject}"
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

l.title "Clean-Up"

# Unset AFNI_DECONFLICT
reset_afni_deconflict if overwrite

# Unset Threads
reset_omp_threads if not threads.nil?
