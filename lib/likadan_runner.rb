require 'selenium-webdriver'
require 'diffux_core/snapshot_comparer'
require 'diffux_core/snapshot_comparison_image/base'
require 'diffux_core/snapshot_comparison_image/gutter'
require 'diffux_core/snapshot_comparison_image/before'
require 'diffux_core/snapshot_comparison_image/overlayed'
require 'diffux_core/snapshot_comparison_image/after'
require 'chunky_png'
require 'likadan_utils'
require 'fileutils'

def resolve_viewports(example)
  configured_viewports = LikadanUtils.config['viewports']

  (example['options']['viewports'] || [configured_viewports.first.first]).map do |viewport|
    configured_viewports[viewport].merge('name' => viewport)
  end
end

begin
  driver = Selenium::WebDriver.for LikadanUtils.config['driver'].to_sym
rescue Selenium::WebDriver::Error::WebDriverError
  # "unable to obtain stable firefox connection in 60 seconds"
  #
  # This seems to happen sporadically for some versions of Firefox, so we want
  # to retry it in case it will work the second time around.
  driver = Selenium::WebDriver.for LikadanUtils.config['driver'].to_sym
end

begin
  driver.manage.timeouts.script_timeout = 3 # move to config?
  driver.navigate.to LikadanUtils.construct_url('/')

  # Check for errors during startup
  errors = driver.execute_script('return window.likadan.errors;')
  unless errors.empty?
    fail "JavaScript errors found during initialization: \n#{errors.inspect}"
  end

  while current = driver.execute_script('return window.likadan.next()') do
    resolve_viewports(current).each do |viewport|
      # Resize window to the right size before rendering
      driver.manage.window.resize_to(viewport['width'], viewport['height'])

      # Render the example

      # WebDriver's `execute_async_script` takes a string that is executed in
      # the context of a function. `execute_async_script` injects a callback
      # function as this function's argument here. WebDriver will wait until
      # this callback is called (if it is passed a value it will pass that
      # through to Rubyland), or until WebDriver's `script_timeout` is reached,
      # before continuing. Since we don't define the signature of this function,
      # we can't name the argument so we access it using JavaScript's magic
      # arguments object and pass it down to `renderCurrent()` which calls it
      # when it is done--either synchronously if our example doesn't take an
      # argument, or asynchronously via the Promise and `done` callback if it
      # does.
      script = <<-EOS
        var doneFunc = arguments[arguments.length - 1];
        window.likadan.renderCurrent(doneFunc);
      EOS
      rendered = driver.execute_async_script(script)

      if error = rendered['error']
        puts <<-EOS
          Error while rendering "#{current['name']}" @#{viewport['name']}:
            #{rendered['error']}
          Debug by pointing your browser to
          #{LikadanUtils.construct_url('/', name: current['name'])}
        EOS
        next
      end
      output_file = LikadanUtils.path_to(
        current['name'], viewport['name'], 'candidate.png')

      # Create the folder structure if it doesn't already exist
      unless File.directory?(dirname = File.dirname(output_file))
        FileUtils.mkdir_p(dirname)
      end

      # Save and crop the screenshot
      driver.save_screenshot(output_file)
      cropped = ChunkyPNG::Image.from_file(output_file)
      cropped.crop!(rendered['left'],
                    rendered['top'],
                    [rendered['width'], 1].max,
                    [rendered['height'], 1].max)
      cropped.save(output_file)

      print "Checking \"#{current['name']}\" at [#{viewport['name']}]... "

      # Run the diff if needed
      baseline_file = LikadanUtils.path_to(current['name'], viewport['name'], 'baseline.png')

      if File.exist? baseline_file
        comparison = Diffux::SnapshotComparer.new(
          ChunkyPNG::Image.from_file(baseline_file),
          cropped
        ).compare!

        if img = comparison[:diff_image]
          diff_output = LikadanUtils.path_to(current['name'], viewport['name'], 'diff.png')
          img.save(diff_output)
          puts "#{comparison[:diff_in_percent].round(1)}% (#{diff_output})"
        else
          File.delete(output_file)
          puts 'No diff.'
        end
      else
        File.rename(output_file, baseline_file)
        puts "First snapshot created (#{baseline_file})"
      end
    end
  end
ensure
  driver.quit
end
