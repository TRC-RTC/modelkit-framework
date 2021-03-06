# IMPORTANT: To run any of the tasks in this file, use "modelkit rake <task>"!

if (not defined?(Modelkit))
  begin
    require("modelkit")
  rescue LoadError => exception
    args = ARGV.join(" ")
    puts exception
    puts "NOTE: This rakefile requires the Modelkit library. Make sure that you have the\nModelkit gem installed in your local Rubygems environment, or try running the\nrakefile using your stand-alone installation of Modelkit by typing:\n  modelkit rake #{args}"
    exit
  end
end

program_name = defined?(Modelkit::CLI) ? "modelkit rake" : "rake"

require("modelkit/config")
require("modelkit/parametrics/template")
require("modelkit/energyplus")

require("fileutils")
require("csv")
require_relative("util")


root_dir = File.expand_path(__dir__)
runs_dir = "#{root_dir}/runs"
templates_dir = "#{root_dir}/templates"
global_pxv_path = "#{root_dir}/global.pxv"

CONFIG = Modelkit::Config.new("#{root_dir}/.modelkit-config")

idd_path = "#{CONFIG["energyplus-run.engine"]}/Energy+.idd"
weather_dir = CONFIG["cbecc-com-weather"]


RUN_COMMAND = {
  "cbecc-com" => "\"#{CONFIG["cbecc-com-path"]}\" -pa -nogui \"%<input_file>s\"",
  "cbecc-res" => "\"#{CONFIG["cbecc-res-path"]}\" -pa -nogui \"%<input_file>s\"",
  "energyplus" => "modelkit-energyplus energyplus-run --weather=\"%<weather_file>s\" \"%<input_file>s\"",
  "cse" => "\"#{CONFIG["cse-path"]}\" -b \"%<input_file>s\""
}

INPUT_FILE_EXT = {
  "cbecc-com" => "cibd22",
  "cbecc-res" => "ribd22",
  "energyplus" => "idf",
  "cse" => "cse"
}

ESC_LINE = {
"cbecc-com" => "// ",
"cbecc-res" => "// ",
"energyplus" => "! ",
"cse" => "// "
}

analysis_name = ENV["analysis"]
if (analysis_name.nil? and not ARGV.empty?)
  puts "You must specify the name of the analysis. For example:\n"
  puts "  #{program_name} analysis=hvac run"
  exit
end

climate_pattern = ENV["climate"] || "*"
case_pattern = ENV["case"] || "*"


max_workers = CONFIG["max-workers"]
if (max_workers.nil?)
  max_workers = 1
end
QUEUE = WorkQueue.new(max_workers, nil)


trap("INT") do  # Ctrl+C (polite kill)
  puts "\nCanceling all simulation runs."
  if ($child_pids)
    $child_pids.each { |pid| Process.kill("KILL", pid) }
  end
  exit
end


task :default do
  puts "There is no default task defined. To see the allowed list of tasks, type:"
  puts "  modelkit rake --tasks"
end


desc "Clean/delete previous runs"
task :clean do |task|
  puts "Cleaning runs for: #{analysis_name}"

  runs_dir = "#{root_dir}/analysis/#{analysis_name}/runs"

  #Dir.glob("#{analysis_dir}/runs/**/cz*")

  FileUtils.rm_rf(runs_dir)
  FileUtils.mkdir_p(runs_dir)
  puts "Clean completed."
end


desc "Generate pxv files for cases"
task :cases do |task|
  analysis_dir = "#{root_dir}/analysis/#{analysis_name}"
  cases_path = "#{analysis_dir}/cases.csv"
  if (not File.exist?(cases_path))
    puts "File not found (cases.csv) at expected path: #{cases_path}"
    exit
  end

  puts "Cases: ANALYSIS=#{analysis_name} CASE=#{case_pattern} CLIMATE=#{climate_pattern}"

  cases_csv = CSV.read(cases_path, :headers=>true)
  cases_csv.each do |case_row|

    # Parse the row for this case.
    case_pxv = ""
    case_name = nil  # Have to do this so result stays in scope
    prototype_name = nil
    baseline_name = nil
    software_name = nil
    case_row.each do |header, value|
      if (header == "case")
        case_name = value

      elsif (header == "prototype")
        prototype_name = value

      elsif (header == "baseline")
        baseline_name = value

      elsif (match = header.match(/^\s*:(\w*)/))
        variable_name = match.captures.first
        if (value)
          case_pxv << ":#{variable_name}=>#{value_from_string(value)},\n"

          if (variable_name == "software")
            software_name = value
          end
        end
      end
    end

    next if (case_pattern != "*" and case_pattern != case_name)

    baseline_path = "#{root_dir}/baselines/#{prototype_name}/#{baseline_name}.csv"
    if (not File.exist?(baseline_path))
      puts "File not found (#{baseline_name}.csv) at expected path: #{baseline_path}"
      exit
    end

    baseline_csv = CSV.read(baseline_path, :headers=>true)
    baseline_csv.each do |baseline_row|

      # Parse the row for this baseline.
      baseline_pxv = ""
      weather_name = ""
      climate_name = nil  # Have to do this so result stays in scope
      baseline_row.each do |header, value|
        if (header == "climate")
          climate_name = value

        elsif (match = header.match(/^\s*:(\w*)/))
          variable_name = match.captures.first
          if (value)
            baseline_pxv << ":#{variable_name}=>#{value_from_string(value)},\n"
          end
          if (variable_name == "weather_station")
            weather_name = value
          end
        end
      end

      next if (climate_pattern != "*" and climate_pattern != climate_name)

      case_dir = "#{analysis_dir}/runs/#{case_name}/#{climate_name}"
      puts "  #{case_name}/#{climate_name}"
      FileUtils.mkdir_p(case_dir)
      File.write("#{case_dir}/prototype.txt", prototype_name)
      File.write("#{case_dir}/case.pxv", case_pxv)
      File.write("#{case_dir}/baseline.pxv", baseline_pxv)
      File.write("#{case_dir}/software.txt", software_name)
      File.write("#{case_dir}/weather.txt", weather_name)

      if (software_name == "energyplus")
        if (not defined?(IDD))
          puts "Opening Energy+.idd...\n"
          if (File.exists?(idd_path))
            IDD = OpenStudio::DataDictionary.open(idd_path)
          else
            raise("Energy+.idd not found: #{idd_path}")
            exit
          end
        end

        ddy_path = "#{weather_dir}/#{weather_name}.ddy"
        site_path = "#{case_dir}/location.pxt"
        generate_location_pxt(IDD, ddy_path, site_path)
      end
    end
  end

end


desc "Compose the simulation runs"
task :compose do |task|
  puts "Composing: ANALYSIS=#{analysis_name} CASE=#{case_pattern} CLIMATE=#{climate_pattern}"

  analysis_dir = "#{root_dir}/analysis/#{analysis_name}"

  paths = Dir.glob("#{analysis_dir}/runs/#{case_pattern}/#{climate_pattern}/case.pxv").sort  # Look for this file as a surrogate for input file
  paths.each do |path|
    case_dir = File.dirname(path)
    baseline_pxv_path = "#{case_dir}/baseline.pxv"
    case_pxv_path = "#{case_dir}/case.pxv"

    software_name = File.read("#{case_dir}/software.txt")
    out_path = "#{case_dir}/instance.#{INPUT_FILE_EXT[software_name]}"

    prototype_name = File.read("#{case_dir}/prototype.txt")
    root_path = "#{root_dir}/prototypes/#{software_name}/#{prototype_name}/root.pxt"

    puts "  #{case_dir}"
    Modelkit::Parametrics.compose(root_path,
      :annotate => true,
      #:indent => "    ",  # Turn off indent because it adds blank lines that CBECC does not like
      :"esc-line" => ESC_LINE[software_name],
      :dirs => "#{templates_dir}/#{software_name};#{case_dir}",
      :files => "#{case_pxv_path};#{baseline_pxv_path};#{global_pxv_path}",
      :output => out_path)
  end

end


desc "Run simulations"
task :run do |task|
  puts "Running: ANALYSIS=#{analysis_name} CASE=#{case_pattern} CLIMATE=#{climate_pattern}"
  puts "Type Ctrl+C to cancel all simulation runs."
  sleep(1)

  analysis_dir = "#{root_dir}/analysis/#{analysis_name}"

  paths = Dir.glob("#{analysis_dir}/runs/#{case_pattern}/#{climate_pattern}/case.pxv").sort  # Look for this file as a surrogate for input file
  paths.each do |path|
    case_dir = File.dirname(path)
    software_name = File.read("#{case_dir}/software.txt")
    input_file = "#{case_dir}/instance.#{INPUT_FILE_EXT[software_name]}"

    weather_name = File.read("#{case_dir}/weather.txt")
    weather_path = "#{weather_dir}/#{weather_name}.epw"

    if (File.exist?(input_file))
      short_name = "#{File.basename(File.dirname(case_dir))}/#{File.basename(case_dir)}"
      puts "Queueing: #{short_name}\n"

      command = sprintf(RUN_COMMAND[software_name], :input_file => input_file, :weather_file => weather_path)
      QUEUE.enqueue_b(command, case_dir) do |command, dir|
        puts "Running: #{short_name}\n"
        run_process(command, dir)
      end
    end
  end
  QUEUE.join  # Wait for all remaining jobs to finish
end


desc "Aggregate the simulation results"
task :results do |task|
  puts "Results: ANALYSIS=#{analysis_name} CASE=#{case_pattern} CLIMATE=#{climate_pattern}"

  analysis_dir = "#{root_dir}/analysis/#{analysis_name}"

  software_name_path = Dir.glob("#{analysis_dir}/runs/#{case_pattern}/#{climate_pattern}/software.txt").first
  software_name = File.read(software_name_path)

  case (software_name)
  when "cbecc-res", "cbecc-com"
    header = File.read("#{root_dir}/results-header-#{software_name}.csv")
    File.open("#{analysis_dir}/results.csv", "w") do |line|
      line.puts(header)  # Write the standard header

      instance_log_paths = Dir.glob("#{analysis_dir}/runs/#{case_pattern}/#{climate_pattern}/instance.log.csv").sort
      instance_log_paths.each do |path|
        case_dir = File.dirname(path)
        dir_name = "#{File.basename(File.dirname(case_dir))}/#{File.basename(case_dir)}"

        instance_log_csv = File.readlines(path)  # Read entire file into an Array
        line.puts("#{dir_name},#{instance_log_csv.last}")
      end
    end

  when "cse"
    header = File.read("#{root_dir}/results-header-#{software_name}.csv")
    File.open("#{analysis_dir}/results.csv", "w") do |line|
      line.puts(header)  # Write the standard header

      instance_annual_paths = Dir.glob("#{analysis_dir}/runs/#{case_pattern}/#{climate_pattern}/INSTANCE-ANNUAL.CSV").sort
      instance_annual_paths.each do |path|
        case_dir = File.dirname(path)
        dir_name = "#{File.basename(File.dirname(case_dir))}/#{File.basename(case_dir)}"

        instance_annual_csv = File.readlines(path)  # Read entire file into an Array
        elec_results = instance_annual_csv[4][19..-1].chomp!  # Get correct row and remove unwanted fields
        gas_results = instance_annual_csv[10][21..-1].chomp!

        line.puts("#{dir_name},#{elec_results},#{gas_results}")
      end
    end

  when "energyplus"
    query_path = "#{root_dir}/results-query-energyplus.txt"
    output_path = "#{analysis_dir}/results.csv"
    instance_paths = Dir.glob("#{analysis_dir}/runs/#{case_pattern}/#{climate_pattern}/instance-out.sql").sort
    batch_path = "#{analysis_dir}/batch.txt"
    File.open(batch_path, "w") do |file|
      instance_paths.each { |path| file.puts(path) }
    end

    command = "modelkit-energyplus energyplus-sql --query=\"#{query_path}\" --output=\"#{output_path}\" --batch=\"#{batch_path}\""
    system(command)

  else
    puts "ERROR: Unknown software specified '#{software_name}'"
  end
end
