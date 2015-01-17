#!/usr/bin/env ruby
# 
#  gen_applywarp.rb
#  
#  Applies your registration to your data. 
#  Assumes that the relevant registration has been run (EPI->Anat or Anat->Std)
#
#  Created by Zarrar Shehzad on 2014-10-07
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
  $: << SCRIPTDIR + "bin" unless $:.include?(SCRIPTDIR + "bin")
end

require 'for_commands.rb' # provides various function such as 'run'
require 'for_afni.rb' # provides various function such as 'run'


###
# DO IT
###

# Create a function that wraps around the cmdline runner
# anat_register_to_standard(l, args = [], opts = {})
def gen_applywarp(l, args=[], opts={})
  cmdline = cli_wrapper(args, opts)
  l.info "Running: #{Pathname.new(__FILE__).basename} #{cmdline}"
  gen_applywarp!(cmdline)
end

def gen_applywarp!(cmdline = ARGV, l = nil)
  print cmdline
  
  ###
  # USER ARGS
  ###
  
  # We have some global options and some options specific to our two approaches
  # to registration (afni and fsl)
  
  # GLOBAL
  #sub_commands = %w(afni fsl)
  #global_opts = Trollop::options do
  p = Trollop::Parser.new do
    banner "Usage: #{File.basename($0)} [-i input.nii.gz -r regdir -w transform_string -o output.nii.gz] (--interp mode --overwrite --master reference.nii.gz --ext .nii.gz --log log_outprefix --short --float) [method] (afni: --mcfile motion_params.1D --dxyz output_resolution --threads num_of_threads) (fsl: no subcommand options)"
    
    opt :input, "Source image that is to be transformed", :type => :string, :required => true
    opt :reg, "Outputs of previously run registration (assumes that non-linear has been run for anat-to-standard)", :type => :string, :required => true
    opt :warp, "Type of warp to use, can be: 'exfunc', 'highres', or 'standard' in the form of X-to-Y (e.g., highres-to-standard)", :type => :string, :required => true
    opt :output, "Output transformed image", :type => :string, :required => true
    opt :linear, "Only use linear (not non-linear) registration for highres-to-standard (default: false or nonlinear)", :default => false
    # afni: NN, linear, cubic, quintic, or wsinc5
    # fsl: nn, trilinear, sinc, and spline
    opt :interp, "Final interpolation to use (for afni this means the --ainterp or --final) and can be for afni: NN, linear, cubic, quintic, or wsinc5, fsl: nn, linear, sinc, and spline (spline only for non-linear)", :type => :string
    opt :master, "An image that defines the output grid (default: target image for the registration)", :type => :string
    
    opt :short, "Will force output to be shorts (default: auto)", :default => false
    opt :float, "Will force output to be floats (default: auto)", :default => false
    
    opt :log, "Prefix for logging output to json and text files", :type => :string
    opt :ext, "File extensions to use in all inputs", :type => :string, :default => ".nii.gz"
    opt :overwrite, "Overwrite any output", :default => false
    
    #stop_on sub_commands
  end
  opts = Trollop::with_standard_exception_handling p do
    raise Trollop::HelpNeeded if cmdline.empty? # show help screen
    p.parse cmdline
  end

  cmd = "fsl"
  #cmd = ARGV.shift # get the subcommand
  #cmd_opts = case cmd
  #  when "afni" # parse delete options
  #    Trollop::options do
  #      opt :mcfile, "For raw EPI run data, you must specify the transforms for motion correction (method=afni only)", :type => :string
  #
  #      opt :dxyz, "Grid of output, for instance if you want 2.5mm spacing to match your EPI (this is only possible with method=afni)", :type => :string
  #  
  #      opt :threads, "Number of OpenMP threads to use with AFNI (otherwise defaults to environmental variable OMP_NUM_THREADS if set -> #{ENV['OMP_NUM_THREADS']})", :type => :integer
  #    end
  #  when "fsl"  # parse copy options
  #    {}
  #  when nil # default will be fsl
  #    {}
  #  else
  #    Trollop::die "unknown subcommand #{cmd.inspect}"
  #  end

  #puts "Global options: #{global_opts.inspect}"
  #puts "Subcommand: #{cmd.inspect}"
  #puts "Subcommand options: #{cmd_opts.inspect}"
  #puts "Remaining arguments: #{ARGV.inspect}"
  
  # Combine options
  method = cmd
  #opts = global_opts.merge(cmd_opts)
  
  # Gather inputs
  input   = opts[:input].path.expand_path
  regdir  = opts[:reg].path.expand_path
  warp    = opts[:warp]
  linear  = opts[:linear]
  run     = opts[:run]
  mcfile  = opts[:mcfile]
  mcfile  = mcfile.path.expand_path if not mcfile.nil?
  
  output  = opts[:output].path.expand_path
  interp  = opts[:interp]
  master  = opts[:master]
  master  = master.path.expand_path if not master.nil?  
  dxyz    = opts[:dxyz]

  if opts[:short] and opts[:float]
    abort "Cannot specify both --short and --float"
  end

  ext     = opts[:ext]
  overwrite = opts[:overwrite]
  
  threads   = opts[:threads]
  threads   = ENV['OMP_NUM_THREADS'].to_i if threads.nil? and not ENV['OMP_NUM_THREADS'].nil?
  
  log_prefix = opts[:log]
  log_prefix = log_prefix.path.expand_path unless log_prefix.nil?
  # Setup logger if needed
  l = create_logger(log_prefix, overwrite) if l.nil?


  ###
  # Checks and Setup
  ###

  l.info "Setup"
  
  if method == "afni"
    # Set AFNI_DECONFLICT
    set_afni_to_overwrite if overwrite
    # Set Threads
    set_omp_threads threads if not threads.nil?
  end
  
  l.info "Process warp input"
  warp_list = warp.split("-")
  l.fatal("Error in parsing #{warp}. Must be X-to-Y.") if warp_list.count != 3
  source = warp_list[0]
  target = warp_list[2]
  warp_opts = ["exfunc", "highres", "standard"] # to check
  l.fatal("Incorrect source: #{source}. Must be exfunc, highres, or standard") if not warp_opts.include? source
  l.fatal("Incorrect target: #{target}. Must be exfunc, highres, or standard") if not warp_opts.include? target

  l.info "Checking inputs"
  quit_if_inputs_dont_exist l, input, regdir
  quit_if_inputs_dont_exist l, master unless master.nil?
  quit_if_inputs_dont_exist l, mcfile unless mcfile.nil?

  l.info "Checking outputs"
  quit_if_all_outputs_exist(l, output) if not overwrite

  l.info "Changing directory to '#{regdir}'"
  Dir.chdir regdir


  ###
  # Apply Non-Linear (for now) Registration
  ###

  l.info "Apply registration"
  
  # TODO: move specifics into some function/class
    
  if (target == "standard" or source == "standard") and not linear
    l.info "Non-Linear: #{source} => #{target}"
    
    if method == "afni"
      cmd = "3dNwarpApply \
      -source #{input}"
  
      if master.nil?
        cmd += " -master #{target}#{ext}"
      else
        cmd += " -master #{master}"
      end
  
      if target == "standard"
        nwarp = "highres2standard_WARP#{ext} #{source}2#{target}.1D"
      else
        nwarp = "standard2highres_WARP#{ext} #{source}2#{target}.1D"
      end
      #nwarp += " #{mcfile}" if not mcfile.nil?
      cmd += " -nwarp '#{nwarp}'"
      # go back to the old way of things
      cmd += " -affter #{mcfile}" if not mcfile.nil?
  
      cmd += " -dxyz #{dxyz}" if not dxyz.nil?
      cmd += " -ainterp #{interp}" if not interp.nil?
      cmd += " -short" if opts[:short]
      cmd += " -prefix #{output}"

      l.cmd cmd
    elsif method == "fsl"
      cmd = ["applywarp"]
      cmd.push "-i #{input}"
      
      if master.nil?
        cmd.push "-r #{target}#{ext}"
      else
        cmd.push "-r #{master}"
      end
      
      cmd.push "-w #{regdir}/#{source}2#{target}_warp#{ext}"
      # TODO: switch the mcfile to be your premat!
      cmd += " --premat=#{mcfile}" if not mcfile.nil?
      
      conversion = {:nn => "nn", :linear => "trilinear", :sinc => "sinc", :spline => "spline"}
      cmd.push "--interp=#{conversion[interp.to_sym]}" if not interp.nil?
      
      cmd.push "-d short" if opts[:short]
      cmd.push "-d float" if opts[:float]
      
      cmd.push "-o #{output}"
      l.cmd cmd.join(" ")
    end
  else # source/target are func or highres
    l.info "Linear: #{source} => #{target}"
    
    if method == "afni"
      # catenate volreg, epi2anat and tlrc transformations
      if mcfile.nil?
        matfile = "#{source}2#{target}.1D"
      else
        tmpfile = Tempfile.new("mc_#{source}2#{target}") 
        matfile = tmpfile.path
        l.cmd "cat_matvec -ONELINE \
        #{source}2#{target}.1D \
        #{mcfile} > #{matfile}"
      end

      cmd = "3dAllineate \
      -source #{input} \
      -1Dmatrix_apply #{matfile}"

      if master.nil?
        cmd += " -master #{target}#{ext}"
      else
        cmd += " -master #{master}"
      end
  
      cmd += " -mast_dxyz #{dxyz}" if not dxyz.nil?
      cmd += " -final #{interp}" if not interp.nil?
      cmd += " -float" if opts[:float]
      cmd += " -prefix #{output}"

      l.cmd cmd
  
      # If force short, then do the following:
      if opts[:short]
        cmd "3dcalc -overwrite -a #{output} -expr 'a' -prefix #{output} -short"
        l.cmd(cmd)
      end
    elsif method == "fsl"
      # actually can use applywarp for linear
      # $FSLDIR/bin/applywarp -i ${vepi} -r ${vrefhead} -o ${vout} --premat=${vout}.mat --interp=spline
      
      cmd = ["applywarp"]
      cmd.push "-i #{input}"
      
      if master.nil?
        cmd.push "-r #{target}#{ext}"
      else
        cmd.push "-r #{master}"
      end
      
      cmd.push " --premat=#{regdir}/#{source}2#{target}.mat"
      
      conversion = {:nn => "nn", :linear => "trilinear", :sinc => "sinc", :spline => "spline"}
      cmd.push "--interp=#{conversion[interp.to_sym]}" unless interp.nil?
      
      cmd.push "-d short" if opts[:short]
      cmd.push "-d float" if opts[:float]
      
      cmd.push "-o #{output}"
      
      l.cmd cmd.join(" ")
    end
  end


  
  ###
  # Clean Up
  ###

  l.title "Clean Up"

  if method == "afni"
    # Unset AFNI_DECONFLICT
    reset_afni_deconflict if overwrite
  end
end


# If script called from the command-line
if __FILE__==$0
  gen_applywarp!
end
