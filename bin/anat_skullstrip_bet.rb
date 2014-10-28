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

require 'fileutils'


###
# SETUP
###

require 'pathname'
SCRIPTDIR   = Pathname.new(__FILE__).realpath.dirname.dirname
SCRIPTNAME  = Pathname.new(__FILE__).basename.sub_ext("")

# add lib directory to ruby path
$: << SCRIPTDIR + "lib" # will be scriptdir/lib

require 'for_commands.rb' # provides various function such as 'run'
require 'colorize'        # allows adding color to output
require 'erb'             # for interpreting erb to create report pages
require 'trollop'         # command-line parsing
require 'tempfile'

# Process command-line inputs
p = Trollop::Parser.new do
  banner "Usage: #{File.basename($0)} -h input_head.nii.gz -b output_brain.nii.gz -m output_brain_mask.nii.gz (--overwrite)\n"
  opt :head, "Input anatomical file", :type => :string, :required => true
  opt :brain, "Output brain file", :type => :string
  opt :mask, "Output mask file", :type => :string
  opt :nobias, "Won't correct for the bias field and neck", :default => false
  opt :args, "Other arguments to supply manually '-R'", :type => :string
  opt :plot, "Produce plots (must also output mask)", :default => false
  opt :overwrite, "Overwrite any output (TODO)", :default => false
end
opts = Trollop::with_standard_exception_handling p do
  raise Trollop::HelpNeeded if ARGV.empty? # show help screen
  p.parse ARGV
end

# Gather inputs
head    = opts[:head].path.expand_path
brain   = opts[:brain]
brain   = brain.path.expand_path unless brain.nil?
mask    = opts[:mask]
mask    = mask.path.expand_path unless mask.nil?
nobias  = opts[:nobias]
args    = opts[:args]
plot    = opts[:plot]
overwrite = opts[:overwrite]

# html output    
#layout_file       = SCRIPTDIR + "etc/layout.html.erb"
#body_file         = SCRIPTDIR + "etc/01_preprocessing/#{SCRIPTNAME}.html.erb"
#report_file       = "#{@qadir}/01_PreProcessed_#{SCRIPTNAME}.html"
#@body             = ""


###
# Skull-Strip
###

puts "\n= Skull-Strip\n".white.on_blue

puts "\n== Checking inputs".magenta
quit_if_inputs_dont_exist_including head

puts "\n== Checking outputs".magenta
abort("One output must be specified") if brain.nil? and mask.nil?
if overwrite
  ow_opts=" --force"
else
  ow_opts=""
  quit_if_all_outputs_exist_including(brain) unless brain.nil?
  quit_if_all_outputs_exist_including(mask) unless mask.nil?
end
# Since FSL always outputs the brain image, we will give one if it doesn't exist
orig_brain = brain
brain = Tempfile.new('brain') if brain.nil?

puts "\n== Running command".magenta
cmd = "bet #{head} #{brain}"
cmd += " -B" unless nobias
cmd += " #{args}" unless args.nil?
cmd += " -m" unless mask.nil?
run cmd

puts "\n== Cleaning up outputs".magenta
File.delete(brain) if orig_brain.nil?
File.rename("#{brain.rmext}_mask.nii.gz", mask) unless mask.nil?

if plot
  raise "Must specify mask with plot option" if mask.nil?
  puts "\n== Plotting".magenta
  run "slicer.py#{ow_opts} --crop -w 5 -l 4 -s axial #{head} #{mask.dirname}/#{head.basename.rmext}_axial.png"
  run "slicer.py#{ow_opts} --crop -w 5 -l 4 -s sagittal #{head} #{mask.dirname}/#{head.basename.rmext}_sagittal.png"
  run "slicer.py#{ow_opts} --crop -w 5 -l 4 -s axial --overlay #{mask} 1 1 -t #{head} #{mask.rmext}_axial.png"
  run "slicer.py#{ow_opts} --crop -w 5 -l 4 -s sagittal --overlay #{mask} 1 1 -t #{head} #{mask.rmext}_sagittal.png"
end
