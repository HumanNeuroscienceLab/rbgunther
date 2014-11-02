require 'colorize'
require 'pathname'
require 'fileutils'
require 'json'
require 'logger'
require 'time'
require 'open3'

# To be able to check if something is a Boolean
module Boolean; end
class TrueClass; include Boolean; end
class FalseClass; include Boolean; end


def softlink(source, target)
  puts "ln -s #{source} #{target}".green
  FileUtils.ln_s source, target
end

def input_doesnt_exist(path)
  retval = !File.exists?(path)
  puts "Input '#{path}' doesn't exist!".light_red if retval
  return retval
end

def output_exists(path)
  retval = File.exists?(path)
  puts "Output '#{path}' already exists.".red if retval
  return retval
end

def any_inputs_dont_exist_including(*paths)
  paths.reduce(false) {|retval,path| input_doesnt_exist(path) or retval }
end

def all_outputs_exist_including(*paths)
  paths.reduce(true) {|retval,path| output_exists(path) and retval }
end

def quit_if_inputs_dont_exist_including(*paths)
  abort("Exiting") if any_inputs_dont_exist_including(*paths)
end

def quit_if_all_outputs_exist_including(*paths)
  abort("Exiting") if all_outputs_exist_including(*paths)
end


def input_doesnt_exist2(l, path)
  retval = !File.exists?(path)
  l.error "Input '#{path}' doesn't exist!" if retval
  return retval
end

def output_exists2(l, path)
  retval = File.exists?(path)
  l.error "Output '#{path}' already exists." if retval
  return retval
end

def any_inputs_dont_exist(l, *paths)
  paths.reduce(false) {|retval,path| input_doesnt_exist2(l, path) or retval }
end

def all_outputs_exist(l, *paths)
  paths.reduce(true) {|retval,path| output_exists2(l, path) and retval }
end

def quit_if_inputs_dont_exist(l, *paths)
  l.fatal("CHECK INPUTS") if any_inputs_dont_exist(l, *paths)
end

def quit_if_all_outputs_exist(l, *paths)
  l.fatal("CHECK OUTPUTS") if all_outputs_exist(l, *paths)
end


# command-line wrapper
def cli_wrapper(args = [], opts = {})
  args = [] if args.nil?
  
  # Compile the command-line string
  cmdline = []
  
  # Add any options
  opts.each_pair do |k,v|
    opt = 
      if k.length == 1 then "-#{k}"
      else "--#{k}"
    end
    cmdline << opt
    if not v.is_a? Boolean
      if v.is_a? Array
        cmdline = cmdline + v
      else
        cmdline << v
      end
    end
  end
  
  # Add any arguments
  args.each do |arg|
    cmdline << arg
  end
  
  # Join together  
  return cmdline
end


# overload logger
# add custom function run with some alias like exec
# - this custom function would execute the command
# - and it would output to the command-line (STDOUT)
# - and it would save to a file
# - so for the last two points, it might call add per line
#require 'Open3'
#see http://devver.wordpress.com/2009/10/12/ruby-subprocesses-part_3/
#see http://ku1ik.com/2010/09/18/open3-and-the-pid-of-the-spawn.html

# code from dsz: 
# http://stackoverflow.com/questions/6407141/how-can-i-have-ruby-logger-log-output-to-stdout-as-well-as-file
class MultiLogger
    def initialize(*targets)
        @targets = targets
    end
    
    %w(add log debug info title warn error).each do |m|
        define_method(m) do |*args|
            @targets.map { |t| t.send(m, *args) }
        end
    end

    def fatal(*args)
      @targets.map { |t| t.fatal(*args) }
      abort("EXITING")
    end
    
    def command(progname = nil, &block)
      if block_given?
        cmd = yield
      else
        cmd = progname
        progname = nil
      end
      raise Exception("no command to run") if cmd.nil?
    
      # default progname
      if progname.nil?
        l = cmd.split
        progname = l[0]
      end
    
      # spit out command to be run
      @targets.map { |t| t.command(progname){cmd} }
    
      # start timer
      start_time = Time.now
    
      # run command and log output
      # see http://pivotallabs.com/how-to-simultaneously-display-and-capture-the-output-of-an-external-command-in-ruby/
      Open3.popen2e(cmd) do |i, oe, wt|
        @targets.map { |t| t.debug(progname){"pid is #{wt.pid}"} }
      
        i.close_write
        oe.each do |line|
          @targets.map { |t| t.command_out(progname){line.chomp} }
        end
      
        # check exit status and quit if needed
        exitstatus = wt.value.to_i
        if exitstatus != 0
          @targets.map { |t| t.error(progname){"nonzero exit code: #{exitstatus}"} }
        end
      end
        
      # end timer
      end_time = Time.now
      @targets.map { |t| t.debug(progname){"duration: %s seconds" % (end_time - start_time)} }
    end
    alias cmd command
end

class MyLogger < Logger
  module Severity
    DEBUG = 0
    INFO = 1
    COMMAND_OUT = 2
    COMMAND = 3
    TITLE = 4
    WARN = 5
    ERROR = 6
    FATAL = 7
    UNKNOWN = 8
  end
  include Severity
  
  SEV_LABEL = %w(DEBUG INFO COMMAND_OUT COMMAND TITLE WARN ERROR FATAL ANY)
  
  attr_reader :levels
  
  def initialize(*args)
    super
    
    @levels = {}
    MyLogger::SEV_LABEL.each_with_index {|label,idx| @levels[label] = idx}
  end
  
  # redo other logs
  def debug(progname = nil, &block)
    add(DEBUG, nil, progname, &block)
  end

  def info(progname = nil, &block)
    add(INFO, nil, progname, &block)
  end
  
  def command_out(progname = nil, &block)
    add(COMMAND_OUT, nil, progname, &block)
  end
  
  def command(progname = nil, &block)
    add(COMMAND, nil, progname, &block)
  end
  alias cmd command
  
  def title(progname = nil, &block)
    add(TITLE, nil, progname, &block)
  end
  
  def warn(progname = nil, &block)
    add(WARN, nil, progname, &block)
  end

  def error(progname = nil, &block)
    add(ERROR, nil, progname, &block)
  end

  def fatal(progname = nil, &block)
    add(FATAL, nil, progname, &block)
  end

  def unknown(progname = nil, &block)
    add(UNKNOWN, nil, progname, &block)
  end
  
  private
  
    def format_severity(severity)
      SEV_LABEL[severity] || 'ANY'
    end
end

# for now this will just overwrite outputs that already exist
def create_logger(outprefix=nil, overwrite=false)
  if outprefix.nil?
    stdout_log = MyLogger.new(STDOUT)
    stdout_log.level = MyLogger::DEBUG
    
    log = MultiLogger.new( stdout_log )
  else
    outdir = outprefix.path.dirname
    outdir.mkpath
    
    dt = Time.now.strftime("%Y-%m-%d_%H-%S")
    
    txt_file  = "#{outprefix}_#{dt}.txt".path
    json_file = "#{outprefix}_#{dt}.json".path
  
    raise "Log file '#{txt_file}' already exists" if txt_file.exist? and not overwrite
    raise "Log file '#{json_file}' already exists" if json_file.exist? and not overwrite
        
    # STDOUT
    # stderr_log = Logger.new(STDERR)
    stdout_log = MyLogger.new(STDOUT)
    stdout_log.level = MyLogger::DEBUG
  
    # TXT FILE
    txt_log = MyLogger.new(File.open(txt_file.to_s, 'w'))
    txt_log.level = MyLogger::DEBUG
  
    # JSON FILE
    json_log = MyLogger.new(File.open(json_file.to_s, 'w'))
    json_log.level = MyLogger::DEBUG
    json_log.formatter = proc do |severity, datetime, progname, msg|
      out = {
        'time' => datetime.utc.iso8601(3),
        'level' => severity,
        'level_id' => json_log.levels[severity]
      }
    
      out['progname'] = progname if progname
      out['msg'] = msg if msg
    
      out.to_json + "\n"
    end
  
    log = MultiLogger.new( stdout_log, txt_log, json_log )
    
    # keep an easier to find log file
    FileUtils.ln_sf txt_file, "#{outprefix}.txt", :verbose => true
    FileUtils.ln_sf json_file, "#{outprefix}.json", :verbose => true
  end
  
  return log
end

# require 'pry'
# binding.pry

# FUNCTION FOR TESTING
def tryitout
  $: << "."
  require 'for_commands'
  
  # STDOUT
  # stderr_log = Logger.new(STDERR)
  stdout_log = MyLogger.new(STDOUT)
  stdout_log.level = MyLogger::DEBUG
  
  # TXT FILE
  txt_log = MyLogger.new(File.open('test.log', 'w'))
  txt_log.level = MyLogger::DEBUG
  
  # JSON FILE
  json_log = MyLogger.new(File.open('test.json', 'w'))
  json_log.level = MyLogger::DEBUG
  json_log.formatter = proc do |severity, datetime, progname, msg|
    out = {
      'time' => datetime.utc.iso8601(3),
      'level' => severity,
      'level_id' => json_log.levels[severity]
    }
    # TODO: might also want to add stuff about the global program?
    
    out['progname'] = progname if progname
    out['msg'] = msg if msg
    
    out.to_json + "\n"
  end
  
  log = MultiLogger.new( stdout_log, txt_log, json_log )
  
  log.info "trying this cool thing"
  log.error "oops"
  log.cmd "echo me"
  
  # for the html output, i want each level to be a bit different
  # now i could also spit out a text file that i then parse with the javascript
  # next to the command, maybe have some status indicator?
end

# can call a function that will call the logger

# WARNING: this function will be deprecated
# Light wrapper around system
# prints command and any error messages if command fails
def run(command, error_message=nil)
  # print command
  l = command.split
  prog = l[0].light_blue
  args = l[1..-1].join(' ').green
  puts "%s %s" % [prog, args]
  
  # execute command
  retval = system "time #{command}"
  
  # show error message
  if not retval
    error_message ||= "Error: execution of ".light_red + prog + " failed".light_red
    puts error_message
    raise "program cannot proceed"
  end
  
  return retval
end

# Method to remove file extension including '.tar.gz' or '.nii.gz'
class String
  def rmext
    Pathname.new(self.chomp('.gz')).sub_ext("")
  end
  
  def path
    Pathname.new self
  end
end

class Pathname
  def rmext
    self.to_s.chomp('.gz').path.sub_ext('')
  end
  
  def path
    self
  end
end

def extnames(val)
  suffix = File.extname val
  if [".gz", ".bzip", ".bzip2", ".zip", ".xz"].include? suffix
    suffix = File.extname(val.chomp suffix) + suffix
  end
  suffix
end
