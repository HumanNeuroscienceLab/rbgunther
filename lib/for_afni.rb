require 'colorize'        # allows adding color to output

def set_afni_to_overwrite
  puts "setting afni to always overwrite".red
  # Save the old environmental if there is any
  ENV['OLD_AFNI_DECONFLICT']  = ENV['AFNI_DECONFLICT']
  # Set to overwrite
  ENV['AFNI_DECONFLICT']      = 'OVERWRITE'  
end

def reset_afni_deconflict
  # Check if there is any old setting, otherwise default to 'NO'
  if ENV['OLD_AFNI_DECONFLICT'].nil?
    puts "setting afni to never overwrite".red
    ENV['AFNI_DECONFLICT']      = 'NO'
  else
    puts "setting afni to AFNI_DECONFLICT=#{ENV['AFNI_DECONFLICT']}".red
    ENV['AFNI_DECONFLICT']      = ENV['OLD_AFNI_DECONFLICT']
    ENV['OLD_AFNI_DECONFLICT']  = nil
  end
end

def set_omp_threads(nthreads)
  puts "setting omp threads to #{nthreads}".red
  ENV['OLD_OMP_NUM_THREADS']  = ENV['OMP_NUM_THREADS']
  ENV['OMP_NUM_THREADS']      = nthreads.to_s
end

def reset_omp_threads
  # Check if there is any old setting
  if not ENV['OLD_OMP_NUM_THREADS'].nil?
    puts "resetting omp threads to #{ENV['OMP_NUM_THREADS']}".red
    ENV['OMP_NUM_THREADS']      = ENV['OLD_OMP_NUM_THREADS']
    ENV['OLD_OMP_NUM_THREADS']  = nil
  end
end
