#!/usr/bin/env ruby
# 
#  reorient.rb
#  
#  This runs freesurfer to do the skull stripping.
#  
#  Created by Zarrar Shehzad on 2014-10-24
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

require 'ostruct'
require 'csv'


###
# DO IT
###

# Create a function that wraps around the cmdline runner
# anat_skullstrip(l, args = [], opts = {})
def anat_freesurfer(l, args = [], opts = {})
  #require 'pry'
  #binding.pry
  cmdline = cli_wrapper(args, opts)
  anat_freesurfer!(cmdline, l)
end

def anat_freesurfer!(cmdline = ARGV, l = nil)
  ###
  # USER ARGS
  ###
  
  #require 'pry'
  #binding.pry
  #puts cmdline.join(" ")
  
  # Process command-line inputs
  p = Trollop::Parser.new do
    banner "Usage: #{Pathname.new(__FILE__).basename} -f /path/to/freesurfer/subjects/subdir -o output-directory (--no-autorecon2 --no-autorecon3 --log nil --ext .nii.gz --overwrite)\n"
    opt :freedir, "Freesurfer output subjects directory (inluding subject in path) - will only run -autorecon2 or -autorecon3 so this directory must exist", :type => :string, :required => true
    opt :outdir, "Output directory for segmentation and labels", :type => :string, :required => true
    
    opt :no_autorecon2, "Skip autorecon2 step", :default => false
    opt :no_autorecon3, "Skip autorecon3 step", :default => false
    
    opt :threads, "Number of OpenMP threads to use with FreeSurfer (otherwise defaults to environmental variable OMP_NUM_THREADS if set -> #{ENV['OMP_NUM_THREADS']})", :type => :integer
    
    opt :log, "Prefix for logging output to json and text files", :type => :string
    opt :ext, "File extensions to use in all outputs", :type => :string, :default => ".nii.gz"
    opt :overwrite, "Overwrite any output", :default => false
  end
  opts = Trollop::with_standard_exception_handling p do
    raise Trollop::HelpNeeded if cmdline.empty? # show help screen
    p.parse cmdline
  end

  # Gather inputs
  outdir  = opts[:outdir].path.expand_path
  freedir = opts[:freedir].path.expand_path
  sd      = freedir.dirname
  subject = freedir.basename
  
  autorecon2 = !opts[:no_autorecon2]
  autorecon3 = !opts[:no_autorecon3]
  
  threads   = opts[:threads]
  threads   = ENV['OMP_NUM_THREADS'].to_i if threads.nil? and not ENV['OMP_NUM_THREADS'].nil?
  
  ext        = opts[:ext]
  overwrite  = opts[:overwrite]
  log_prefix = opts[:log]
  log_prefix = log_prefix.path.expand_path unless log_prefix.nil?
  # Setup logger if needed
  l = create_logger(log_prefix, overwrite) if l.nil?
  
  ###
  # RUN COMMANDS
  ###
  
  # set freesurfer subject dir
  l.info "Setting SUBJECTS_DIR=#{sd}"
  ENV['SUBJECTS_DIR'] = sd.to_s
  
  l.info "Checking inputs"
  quit_if_inputs_dont_exist(l, freedir, "#{freedir}/mri")
  
  l.info "Checking outputs"
  if not overwrite
    quit_if_all_outputs_exist(l, "#{outdir}/aseg#{ext}", "#{outdir}/aparc", "#{outdir}/misc", "#{freedir}/SUMA")
  end
  l.cmd "mkdir #{outdir} 2> /dev/null"
  
  l.info "Setup"
  set_afni_to_overwrite if overwrite  # Set AFNI_DECONFLICT
  
  if autorecon2
    outputs_exist = File.exist?("#{freedir}/mri/aseg.mgz") and File.exist?("#{freedir}/surf/lh.inflated")
    if not outputs_exist or overwrite
      l.info "Run freesurfer - autorecon2"
      l.cmd "recon-all -s #{subject} -sd #{sd} -autorecon2 -openmp #{threads}"
    else
      l.warn "Freesurfer autorecon2 output already exists, skipping!"
    end
  end  
  
  if autorecon3
    outputs_exist = File.exist?("#{freedir}/mri/aparc+aseg.mgz") and File.exist?("#{freedir}/mri/wmparc.mgz")
    if not outputs_exist or overwrite
      l.info "Run freesurfer - autorecon3"
      l.cmd "recon-all -s #{subject} -sd #{sd} -autorecon3 -openmp #{threads}"
    else
      l.warn "Freesurfer autorecon3 output already exists, skipping!"
    end
  end
  
  l.info "Copy freesurfer outputs to our output folder"
  
  l.info "Convert volume space labels from mgz to individual nifti files"
    l.cmd "mri_convert -rl #{freedir}/mri/rawavg.mgz -rt nearest #{freedir}/mri/aparc.a2009s+aseg.mgz #{outdir}/aparc.a2009s+aseg#{ext}"
    l.cmd "mri_convert -rl #{freedir}/mri/rawavg.mgz -rt nearest #{freedir}/mri/aparc+aseg.mgz #{outdir}/aparc+aseg#{ext}"
  l.cmd "mri_convert -rl #{freedir}/mri/rawavg.mgz -rt nearest #{freedir}/mri/aseg.mgz #{outdir}/aseg#{ext}"
  l.cmd "python #{SCRIPTDIR}/bin/anat_freesurfer_split.py #{outdir}/aseg#{ext} #{outdir}/volume"
  
  
  l.info "Generate atlas to native volume space transform"
  l.cmd "tkregister2 --mov #{freedir}/mri/rawavg.mgz --noedit \
    --s #{subject} --sd #{sd} \
    --regheader --reg #{freedir}/mri/register.dat"
  
  atlas_names  = [ "aparc", "aparc_a2009s", "aparc_DKTatlas40" ]
  atlas_names.each do |atlas_name|
  
    atlas_name2 = atlas_name.gsub("_", ".") # freesurfer file format
    
    l.info "Convert labels from the #{atlas_name} to native volume space"
    l.cmd "mkdir #{freedir}/label_#{atlas_name} 2> /dev/null"
    l.cmd "mkdir #{outdir}/#{atlas_name} 2> /dev/null"
    
    l.info "changing directory to #{freedir}/label_#{atlas_name}"
    Dir.chdir "#{freedir}/label_#{atlas_name}"
    
    ["lh", "rh"].each do |hemi|
      l.info "annotation to labels for #{hemi}"
      l.cmd "mri_annotation2label --subject #{subject} --sd #{sd} \
        --hemi #{hemi} --annotation '#{atlas_name2}' \
        --outdir #{freedir}/label_#{atlas_name}"
    
      l.info "labels to volumes"
      files = Dir.glob "#{freedir}/label_#{atlas_name}/#{hemi}.*.label"
      files.each do |file|
        region  = file.path.basename.to_s.split(".")[1]
        l.info "...#{region}"
        l.cmd "mri_label2vol --label #{hemi}.#{region}.label \
          --temp #{freedir}/mri/rawavg.mgz --subject #{subject} --hemi #{hemi} \
          --o #{outdir}/#{atlas_name}/#{hemi}_#{region}#{ext} --proj frac 0 1 .1 \
          --fillthresh .3 --reg #{freedir}/mri/register.dat"
      end
    end
    
  end
  
  l.info "Miscellaneous labels in #{freedir}/label"
  l.cmd "mkdir #{outdir}/misc 2> /dev/null"
  
  l.info "changing directory to #{freedir}/label"
  Dir.chdir "#{freedir}/label"
  
  ["lh", "rh"].each do |hemi|
    
    l.info "Convert miscellaneous labels to native volume space for #{hemi}"
    files = Dir.glob "#{freedir}/label/#{hemi}.*.label"
    files.each do |file|
      region  = file.path.basename.to_s.split(".")[1]
      l.info "...#{region}"
      l.cmd "mri_label2vol --label #{hemi}.#{region}.label \
        --temp #{freedir}/mri/rawavg.mgz --subject #{subject} --hemi #{hemi} \
        --o #{outdir}/misc/#{hemi}_#{region}#{ext} --proj frac 0 1 .1 \
        --fillthresh .3 --reg #{freedir}/mri/register.dat"
    end
    
  end
  
  
  l.info "Clean-Up"
  reset_afni_deconflict if overwrite  # Unset AFNI_DECONFLICT
  
end

if __FILE__==$0
  anat_freesurfer!
end
