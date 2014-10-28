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

# Process command-line inputs
p = Trollop::Parser.new do
  banner "Usage: #{File.basename($0)} -i input -o output -overwrite\n"
  opt :input, "Path to functional runs to motion correct", :type => :string, :required => true
  opt :output, "Path to output directory", :type => :string, :required => true
  opt :overwrite, "Overwrite any output", :default => false
end
opts = Trollop::with_standard_exception_handling p do
  raise Trollop::HelpNeeded if ARGV.empty? # show help screen
  p.parse ARGV
end

# Gather inputs
input   = opts[:input]
output  = opts[:output]]
overwrite = opts[:overwrite]
if overwrite
  ow_opt = " -overwrite"
else
  ow_opt = ""
end

# html output    
#layout_file       = SCRIPTDIR + "etc/layout.html.erb"
#body_file         = SCRIPTDIR + "etc/01_preprocessing/#{SCRIPTNAME}.html.erb"
#report_file       = "#{@qadir}/01_PreProcessed_#{SCRIPTNAME}.html"
#@body             = ""


###
# Deoblique and Reorient
###

puts "\n= Orient\n".white.on_blue

puts "\n== Checking inputs".magenta
next if any_inputs_dont_exist_including *inputs

puts "\n== Deoblique".magenta
run "3drefit -deoblique #{input}"

puts "\n== Reorient".magenta
run "3dresample#{ow_opt} -orient RPI \
-prefix #{output} \
-inset #{input}"
