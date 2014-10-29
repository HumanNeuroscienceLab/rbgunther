#!/usr/bin/env ruby
# 
#  reorient.rb
#  
#  This converts freesurfer output into SUMA format.
#  Many thanks to http://openwetware.org/wiki/Beauchamp:UseCortSurfMod
#  
#  Created by Zarrar Shehzad on 2014-10-27
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


###
# DO IT
###

# Create a function that wraps around the cmdline runner
# anat_skullstrip(l, args = [], opts = {})
def anat_suma(l, args = [], opts = {})
  cmdline = cli_wrapper(args, opts)
  anat_suma!(cmdline, l)
end

def anat_suma!(cmdline = ARGV, l = nil)
  ###
  # USER ARGS
  ###
  
  # Process command-line inputs
  p = Trollop::Parser.new do
    banner "Usage: #{Pathname.new(__FILE__).basename} -f /path/to/freesurfer/subjects/subdir -o output-directory (--no-autorecon2 --no-autorecon3 --log nil --ext .nii.gz --overwrite)\n"
    opt :freedir, "Freesurfer output subjects directory INCLUDING subject in path (will also serve as output via $freedir/SUMA for freesurfer => SUMA files)", :type => :string, :required => true
    opt :anatreg, "Outputs of previously run highres-to-standard registration directory (will also serve as part of the output for SUMA files)", :type => :string, :required => true
    opt :dxyz, "Output resolution (this should be the same one you have your 4D exfunc2highres data in)", :type => :float, :required => true
    
    opt :log, "Prefix for logging output to json and text files", :type => :string
    opt :ext, "File extensions to use in all outputs", :type => :string, :default => ".nii.gz"
    opt :overwrite, "Overwrite any output", :default => false
  end
  opts = Trollop::with_standard_exception_handling p do
    raise Trollop::HelpNeeded if cmdline.empty? # show help screen
    p.parse cmdline
  end

  # Gather inputs
  dxyz    = opts[:dxyz]
  anat_regdir = opts[:anatreg].path.expand_path
  freedir = opts[:freedir].path.expand_path
  sd      = freedir.dirname
  subject = freedir.basename
  
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
  quit_if_inputs_dont_exist(l, anat_regdir, "#{anat_regdir}/highres#{ext}", freedir, "#{freedir}/mri", "#{freedir}/surf")
  
  l.info "Checking outputs"
  if not overwrite
    quit_if_all_outputs_exist(l, "#{freedir}/SUMA")
  end
  
  l.info "Setup"
  set_afni_to_overwrite if overwrite  # Set AFNI_DECONFLICT
  
  
  l.info "Converting freesurfer output to use with SUMA"
  l.cmd "rm -r #{freedir}/SUMA" if overwrite
  
  l.info "Changing into '#{freedir}'"
  Dir.chdir freedir
  
  l.cmd "@SUMA_Make_Spec_FS -sid #{subject} -GIFTI -inflate 200 -inflate 400 -inflate 600 -inflate 800"
  
  l.info "To view just the anatomical in SUMA, run the following:"
  l.info "cd #{freedir}/SUMA"
  l.info "afni -niml &"
  l.info "suma -spec tb9226_both.spec -sv tb9226_SurfVol.nii"
  
  l.info "Changing into '#{anat_regdir}'"
  Dir.chdir anat_regdir
  
  tmpfile = Tempfile.new('highres')
  l.info "creating temporary file #{tmpfile.path}"
  l.cmd "3dcopy #{anat_regdir}/highres#{ext} #{tmpfile.path}"
  l.cmd "@SUMA_AlignToExperiment \
    -exp_anat #{tmpfile.path}+orig \
    -surf_anat #{freedir}/SUMA/#{subject}_SurfVol.nii \
    -atlas_followers \
    -out_dxyz #{dxyz} \
    -prefix highres2surf"
  l.info "deleting temporary file #{tmpfile.path}"
  tmpfile.close
  tmpfile.unlink
  
  
  l.info "Clean-Up"
  reset_afni_deconflict if overwrite  # Unset AFNI_DECONFLICT
  
end

if __FILE__==$0
  anat_suma!
end
