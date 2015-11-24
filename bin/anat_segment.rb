#!/usr/bin/env ruby
# 
#  reorient.rb
#  
#  This will deoblique and reorient the input image to play nice with AFNI.
#  
#  Created by Zarrar Shehzad on 2014-10-02
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
  DDIR        = SCRIPTDIR + "data/"

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
def anat_segment(l, args=[], opts={})
  cmdline = cli_wrapper(args, opts)
  l.info "Running: #{Pathname.new(__FILE__).basename} #{cmdline}"
  anat_segment!(cmdline, l)
end

def anat_segment!(cmdline = ARGV, l = nil)
  ###
  # USER ARGS
  ###
  
  # Process command-line inputs
  p = Trollop::Parser.new do
    banner "Usage: #{Pathname.new(__FILE__).basename} -i input_brain.nii.gz -o output_prefix (--overwrite)\n"
    opt :input, "Input skull-stripped anatomical file", :type => :string, :required => true
    opt :reg, "Registration directory in order to help match the tissue types", :type => :string, :required => true
    opt :output, "Output directory", :type => :string
    opt :args, "Other arguments to supply manually (note: -B -g -p are already used)", :type => :string
  
    opt :log, "Prefix for logging output to json and text files", :type => :string
    opt :ext, "File extensions to use in all outputs (DOESN'T WORK HERE)", :type => :string, :default => ".nii.gz"
    opt :overwrite, "Overwrite any output (TODO)", :default => false
  end
  opts = Trollop::with_standard_exception_handling p do
    raise Trollop::HelpNeeded if cmdline.empty? # show help screen
    p.parse cmdline
  end

  # Gather inputs
  input   = opts[:input].path.expand_path
  regdir  = opts[:reg].path.expand_path
  outdir  = opts[:output].path.expand_path
  args    = opts[:args]

  highres = outdir + "highres.nii.gz"
  outprefix = outdir + "highres"

  ext        = opts[:ext]
  overwrite  = opts[:overwrite]
  log_prefix = opts[:log]
  log_prefix = log_prefix.path.expand_path unless log_prefix.nil?
  # Setup logger if needed
  l = create_logger(log_prefix, overwrite) if l.nil?


  ###
  # Segment
  ###

  l.info "Checking inputs"
  quit_if_inputs_dont_exist(l, input)

  l.info "Checking outputs"
  quit_if_all_outputs_exist(l, outdir) if not overwrite
  outdir.mkdir if not outdir.directory?

  l.info "Changing directory to #{outdir}"
  Dir.chdir outdir

  l.info "Soft-link inputs"
  l.cmd "ln -sf #{input} #{highres}"

  l.info "Segment"
  cmd = "fast -B -g -p o #{outprefix}"
  cmd += " #{args}" if not args.nil?
  cmd += " #{highres}"
  l.cmd cmd
  
  l.info "Get tissue priors"
  require 'gen_applywarp.rb'
  gen_applywarp l, nil, :input => "#{DDIR}mni152_gray_prob.nii.gz", :reg => regdir.to_s, 
    :warp => 'standard-to-highres', :output => "#{outdir}/prior_gray_prob.nii.gz", 
    :overwrite => overwrite, :ext => ext, :linear => true
  gen_applywarp l, nil, :input => "#{DDIR}mni152_white_prob.nii.gz", :reg => regdir.to_s, 
    :warp => 'standard-to-highres', :output => "#{outdir}/prior_white_prob.nii.gz", 
    :overwrite => overwrite, :ext => ext, :linear => true
  gen_applywarp l, nil, :input => "#{DDIR}mni152_csf_prob.nii.gz", :reg => regdir.to_s, 
    :warp => 'standard-to-highres', :output => "#{outdir}/prior_csf_prob.nii.gz", 
    :overwrite => overwrite, :ext => ext, :linear => true
  
  l.info "Find the correlations between individual segmentations and tissue priors"
  cor_with_gray = (0..2).collect do |i|
    `3ddot -docor #{outdir}/prior_gray_prob.nii.gz #{outdir}/highres_prob_#{i}.nii.gz`.chomp("\t\n").to_f
  end
  cor_with_white = (0..2).collect do |i|
    `3ddot -docor #{outdir}/prior_white_prob.nii.gz #{outdir}/highres_prob_#{i}.nii.gz`.chomp("\t\n").to_f
  end
  cor_with_csf = (0..2).collect do |i|
    `3ddot -docor #{outdir}/prior_csf_prob.nii.gz #{outdir}/highres_prob_#{i}.nii.gz`.chomp("\t\n").to_f
  end

  l.info "Determine image with max correlation for each segmentation"
  ind_gray  = cor_with_gray.index(cor_with_gray.max)
  ind_white = cor_with_white.index(cor_with_white.max)
  ind_csf   = cor_with_csf.index(cor_with_csf.max)
  
  # not the most elegant way to resolve the issue
  if ind_gray == ind_csf
    if cor_with_gray[ind_gray] >= cor_with_csf[ind_gray]
      cor_with_csf[ind_gray] = 0.0
      ind_csf = cor_with_csf.index(cor_with_csf.max)
    else
      cor_with_gray[ind_gray] = 0.0
      ind_gray = cor_with_gray.index(cor_with_gray.max)
    end
  end
  
  l.fatal("Duplicate probability map #{ind_gray} identified for gray and white matter") if ind_gray == ind_white
  l.fatal("Duplicate probability map #{ind_white} identified for white matter and csf") if ind_white == ind_csf
  l.fatal("Duplicate probability map #{ind_csf} identified for gray matter and csf") if ind_gray == ind_csf

  l.info "Soft-linking gray = #{ind_gray}, white = #{ind_white}, csf = #{ind_csf}"
  ## probability maps
  l.cmd "ln -sf #{outdir}/highres_prob_#{ind_gray}.nii.gz #{outdir}/highres_gray_prob.nii.gz"
  l.cmd "ln -sf #{outdir}/highres_prob_#{ind_white}.nii.gz #{outdir}/highres_white_prob.nii.gz"
  l.cmd "ln -sf #{outdir}/highres_prob_#{ind_csf}.nii.gz #{outdir}/highres_csf_prob.nii.gz"
  ## segmentations
  l.cmd "ln -sf #{outdir}/highres_seg_#{ind_gray}.nii.gz #{outdir}/highres_gray_seg.nii.gz"
  l.cmd "ln -sf #{outdir}/highres_seg_#{ind_white}.nii.gz highres_white_seg.nii.gz"
  l.cmd "ln -sf #{outdir}/highres_seg_#{ind_csf}.nii.gz #{outdir}/highres_csf_seg.nii.gz"

end


# If script called from the command-line
if __FILE__==$0
  anat_segment!
end
