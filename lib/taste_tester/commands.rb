# Copyright 2013-present Facebook
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'taste_tester/server'
require 'taste_tester/host'
require 'taste_tester/config'
require 'taste_tester/client'
require 'taste_tester/logging'
require 'taste_tester/exceptions'

module TasteTester
  # Functionality dispatch
  module Commands
    extend TasteTester::Logging

    def self.start
      server = TasteTester::Server.new
      return if TasteTester::Server.running?

      server.start
    end

    def self.restart
      server = TasteTester::Server.new
      server.restart
    end

    def self.stop
      server = TasteTester::Server.new
      server.stop
    end

    def self.status
      server = TasteTester::Server.new
      if TasteTester::Server.running?
        logger.warn("Local taste-tester server running on port #{server.port}")
        if TasteTester::Config.no_repo && server.last_upload_time
          logger.warn("Last upload time was #{server.last_upload_time}")
        elsif !TasteTester::Config.no_repo && server.latest_uploaded_ref
          if server.last_upload_time
            logger.warn("Last upload time was #{server.last_upload_time}")
          end
          logger.warn('Latest uploaded revision is ' +
            server.latest_uploaded_ref)
        else
          logger.warn('No cookbooks/roles uploads found')
        end
      else
        logger.warn('Local taste-tester server not running')
      end
    end

    def self.run_parallel(mode, hosts, threaded_upload = false)
      all_threads = []
      long_running_threads = []
      running_threads = 0
      last_running_thread = 0
      return_code = {}
      server = TasteTester::Server.new
      upload_thread = nil
      if threaded_upload
        upload_thread = Thread.new do
          Thread.current.report_on_exception = true
          upload
        end
      end

      hosts.to_set.each do |hostname|
        # Poor man thread pool manager: keeping it simple
        if running_threads >= TasteTester::Config.parallel_hosts
          thread_status = _join_and_handle_ssh_exception(
            all_threads[last_running_thread], nil
          )
          return_code.merge! [thread_status].to_h
          last_running_thread += 1
        end
        host_thread = Thread.new do
          Thread.current.report_on_exception = false
          Thread.current[:status] = TasteTester::Host.new(hostname, server).send mode
        end
        # Set from the parent: the thread may not have started when we join it
        host_thread[:hostname] = hostname
        all_threads << host_thread
        running_threads += 1
      end

      # upload will raise on failure so no need of special handling
      upload_thread.join if upload_thread

      all_threads.drop(last_running_thread).each do |host_thread|
        thread_status = _join_and_handle_ssh_exception(host_thread)
        if thread_status.nil?
          # We timed out waiting for it to finish
          long_running_threads << host_thread
        else
          return_code.merge! [thread_status].to_h
        end
      end

      print_remaining = true
      while !long_running_threads.empty?
        if print_remaining
          host_list = long_running_threads.map { |t| t[:hostname] }.join ','
          printf("Still waiting on #{host_list} to finish...")
          print_remaining = false
        end
        long_running_threads.dup.each do |host_thread|
          thread_status = _join_and_handle_ssh_exception(host_thread, 5)
          unless thread_status.nil?
            long_running_threads.delete host_thread
            return_code.merge! [thread_status].to_h
            print_remaining = true
          end
        end
        if print_remaining
          printf("\n")
        else
          printf('.')
        end
      end
      return_code
    end

    def self._join_and_handle_ssh_exception(host_thread, limit = 15)
      hostname = host_thread[:hostname]
      logger.info("Joining thread for #{hostname}...")
      return if host_thread.join(limit).nil?
      return hostname, host_thread[:status]
    rescue TasteTester::Exceptions::AlreadyTestingError => e
      logger.error("User #{e.username} is already testing on #{hostname}")
      return hostname, 42
    rescue TasteTester::Exceptions::SshError
      logger.error("Cannot connect to #{hostname}")
      return hostname, 1
    rescue StandardError => e
      # Call error handling hook
      TasteTester::Hooks.post_error(TasteTester::Config.dryrun, e,
                                    __method__, hostname)
      # We do not re-raise here as we want to raise at the end
      return hostname, 69
    end

    def self.test
      do_upload = false
      hosts = TasteTester::Config.servers
      unless hosts
        logger.warn('You must provide a hostname')
        exit(1)
      end
      unless TasteTester::Config.yes
        printf("Set #{TasteTester::Config.servers} to test mode? [y/N] ")
        ans = STDIN.gets.chomp
        exit(1) unless ans =~ /^[yY](es)?$/
      end
      if TasteTester::Config.linkonly && TasteTester::Config.really
        logger.warn('Skipping upload at user request... potentially dangerous!')
      else
        if TasteTester::Config.linkonly
          logger.warn('Ignoring --linkonly because --really not set')
        end
        do_upload = true
      end
      unless TasteTester::Config.linkonly
        if TasteTester::Config.no_repo
          repo = nil
        else
          repo = BetweenMeals::Repo.get(
            TasteTester::Config.repo_type,
            TasteTester::Config.repo,
            logger,
          )
        end
        if repo && !repo.exists?
          fail "Could not open repo from #{TasteTester::Config.repo}"
        end
      end
      unless TasteTester::Config.skip_pre_test_hook ||
          TasteTester::Config.linkonly
        TasteTester::Hooks.pre_test(TasteTester::Config.dryrun, repo, hosts)
      end
      return_code = self.run_parallel(:test, hosts, do_upload)
      logger.warn("Return codes: #{return_code}")
      successful_hosts = return_code.select { |_, st| st.zero? }.keys
      unless TasteTester::Config.skip_post_test_hook ||
          TasteTester::Config.linkonly
        TasteTester::Hooks.post_test(TasteTester::Config.dryrun, repo,
                                     successful_hosts)
      end
      if successful_hosts.to_set == hosts.to_set
        # No exceptions, complete success: every host listed is now configured
        # to use our chef-zero instance.
        logger.info("All hosts (#{successful_hosts}) set to testing.")
        exit(0)
      end
      connect_failures = return_code.select { |_, st| st.to_i == 1 }.keys
      already_testing = return_code.select { |_, st| st.to_i == 42 }.keys
      if successful_hosts.empty?
        if connect_failures.length > 0
          # All the hosts we had failed, with at least one because of ssh
          logger.warn("All hosts (#{connect_failures}) failed to connect.")
          exit(1)
        end
        # All requested hosts are being tested by another user. We didn't change
        # their configuration.
        logger.warn("All hosts (#{already_testing}) already in testing.")
        exit(3)
      end
      # Otherwise, we got a mix of success and failure due to being tested by
      # another user. We'll be pessimistic and return an error because the
      # intent to taste test the complete list was not successful.
      # code.
      logger.info("Some hosts (#{successful_hosts}) set to testing.") if successful_hosts
      logger.warn("Some hosts (#{connect_failures}) failed to connect.") if connect_failures
      logger.warn("Some hosts (#{already_testing}) already in testing.") if already_testing
      exit(2)
    end

    def self.untest
      hosts = TasteTester::Config.servers
      unless hosts
        logger.error('You must provide a hostname')
        exit(1)
      end
      self.run_parallel(:untest, hosts)
    end

    def self.runchef
      hosts = TasteTester::Config.servers
      unless hosts
        logger.warn('You must provide a hostname')
        exit(1)
      end
      return_code = self.run_parallel(:runchef, hosts)
      return_code.each do |hostname, status|
        logger.warn("Finished #{TasteTester::Config.chef_client_command}" +
                    " on #{hostname} with status #{status}")
        if status.zero?
          msg = "#{TasteTester::Config.chef_client_command} was successful" +
                ' - please log to the host and confirm all the intended' +
                ' changes were made'
          logger.error msg.upcase
        end
      end
    end

    def self.keeptesting
      hosts = TasteTester::Config.servers
      unless hosts
        logger.warn('You must provide a hostname')
        exit(1)
      end
      self.run_parallel(:keeptesting, hosts)
    end

    def self.run_reverse_tunnels
      hosts = TasteTester::Config.servers
      unless hosts
        logger.warn('You must provide a hostname')
        exit(1)
      end

      # Make sure the local taste-tester server is up with the latest
      # cookbooks/roles uploaded, starting it if it isn't already running.
      upload unless TasteTester::Server.running?

      server = TasteTester::Server.new

      signal_names = %w{INT TERM HUP QUIT}
      signal_handlers = {}
      stop = false
      signal_handler = proc { stop = true }

      signal_names.each do |signal_name|
        signal_handlers[signal_name] = Signal.trap(signal_name, signal_handler)
      rescue ArgumentError
        # ignore unsupported signals
      end

      begin
        hosts.each do |hostname|
          TasteTester::Tunnel.kill(hostname)
          TasteTester::Tunnel.new(hostname, server).run
        end

        logger.warn(
          "Running reverse tunnels to localhost:#{server.port}. " \
          'Press Ctrl+C to stop.',
        )
        sleep 1 until stop
      ensure
        hosts.each do |hostname|
          TasteTester::Tunnel.kill(hostname)
        rescue StandardError => e
          logger.error(
            "Failed cleaning up tunnel on #{hostname} during shutdown: #{e}",
          )
        end

        signal_handlers.each do |signal_name, previous_handler|
          Signal.trap(signal_name, previous_handler)
        rescue ArgumentError
          # ignore unsupported signals
        end
      end
    end

    def self.upload
      server = TasteTester::Server.new
      # On a force-upload rather than try to clean up whatever's on the server
      # we'll restart chef-zero which will clear everything and do a full
      # upload
      if TasteTester::Config.force_upload
        server.restart
      else
        server.start
      end
      client = TasteTester::Client.new(server)
      client.skip_checks = true if TasteTester::Config.skip_repo_checks
      client.force = true if TasteTester::Config.force_upload
      client.upload
      if TasteTester::Config.parallel_hosts > 1
        logger.info "Upload was successful."
      end
    rescue StandardError => exception
      # We're trying to recover from common chef-zero errors
      # Most of them happen due to half finished uploads, which leave
      # chef-zero in undefined state
      errors = [
        'Cannot find a cookbook named',
        'Connection reset by peer',
        'Object not found',
      ]
      if errors.any? { |e| exception.to_s.match(/#{e}/im) }
        TasteTester::Config.force_upload = true
        unless @already_retried
          @already_retried = true
          retry
        end
      end
      logger.error('Upload failed')
      logger.error(exception.to_s)
      logger.error(exception.backtrace.join("\n"))
      exit 1
    end

    def self.impact
      # Use the repository specified in config.rb to calculate the changes
      # that may affect Chef. These changes will be further analyzed to
      # determine specific roles which may change due to modifed dependencies.
      repo = BetweenMeals::Repo.get(
        TasteTester::Config.repo_type,
        TasteTester::Config.repo,
        logger,
      )
      if repo && !repo.exists?
        fail "Could not open repo from #{TasteTester::Config.repo}"
      end

      changes = _find_changeset(repo)

      # Perform preliminary impact analysis. By default, use Knife to find
      # the roles dependent on modified cookbooks. Custom logic may provide
      # additional information by defining the find_impact plugin method.
      basic_impact = TasteTester::Hooks.find_impact(changes)
      basic_impact ||= _find_roles(changes)

      # Do any post processing required on the list of impacted roles, such
      # as looking up hostnames associated with each role. By default, pass
      # the preliminary results through unmodified.
      final_impact = TasteTester::Hooks.post_impact(basic_impact)
      final_impact ||= basic_impact

      # Print the calculated impact. If a print hook is defined that
      # returns true, then the default print function is skipped.
      unless TasteTester::Hooks.print_impact(final_impact)
        _print_impact(final_impact)
      end
    end

    def self._find_changeset(repo)
      # We want to compare changes in the current directory (working set) with
      # the "most recent" commit in the VCS. For SVN, this will be the latest
      # commit on the checked out repository (i.e. 'trunk'). Git/Hg may have
      # different tags or labels assigned to the default branch, (i.e. 'main',
      # 'stable', etc.) and should be configured if different than the default.
      start_ref = case repo
                  when BetweenMeals::Repo::Hg
                    TasteTester::Config.vcs_start_ref_hg
                  when BetweenMeals::Repo::Svn
                    repo.latest_revision
                  when BetweenMeals::Repo::Git
                    TasteTester::Config.vcs_start_ref_git
                  end
      end_ref = TasteTester::Config.vcs_end_ref

      changeset = BetweenMeals::Changeset.new(
        logger,
        repo,
        start_ref,
        end_ref,
        {
          :cookbook_dirs =>
            TasteTester::Config.relative_cookbook_dirs,
          :role_dir =>
            TasteTester::Config.relative_role_dir,
          :databag_dir =>
            TasteTester::Config.relative_databag_dir,
        },
        TasteTester::Config.track_symlinks,
      )

      return changeset
    end

    def self._find_roles(changes)
      if TasteTester::Config.relative_cookbook_dirs.length > 1
        logger.error('Knife deps does not support multiple cookbook paths.')
        logger.error('Please flatten the cookbooks into a single directory' +
                     ' or define the find_impact method in a local plugin.')
        exit(1)
      end

      cookbooks = Set.new(changes.cookbooks)
      roles = Set.new(changes.roles)
      databags = Set.new(changes.databags)

      if cookbooks.empty? && roles.empty?
        unless TasteTester::Config.json
          logger.warn('No cookbooks or roles have been modified.')
        end
        return Set.new
      end

      unless cookbooks.empty?
        logger.info('Modified Cookbooks:')
        cookbooks.each { |cb| logger.info("\t#{cb}") }
      end
      unless roles.empty?
        logger.info('Modified Roles:')
        roles.each { |r| logger.info("\t#{r}") }
      end
      unless databags.empty?
        logger.info('Modified Databags:')
        databags.each { |db| logger.info("\t#{db}") }
      end

      # Use Knife to list the dependecies for each role in the roles directory.
      # This creates a recursive tree structure that is then searched for
      # instances of modified cookbooks. This can be slow since it must read
      # every line of the Knife output, then search all roles for dependencies.
      # If you have a custom way to calculate these reverse dependencies, this
      # is the part you would replace.
      logger.info('Finding dependencies (this may take a minute or two)...')
      knife = Mixlib::ShellOut.new(
        "knife deps /#{TasteTester::Config.role_dir}/*.rb" +
        " --config #{TasteTester::Config.knife_config}" +
        " --chef-repo-path #{TasteTester::Config.absolute_base_dir}" +
        ' --tree --recurse',
      )
      knife.run_command
      knife.error!

      # Collapse the output from Knife into a hash structure that maps roles
      # to the set of their dependencies. This will ignore duplicates in the
      # Knife output, but must still process each line.
      logger.info('Processing Dependencies...')
      deps_hash = {}
      curr_role = nil

      knife.stdout.each_line do |line|
        elem = line.rstrip
        if elem.length == elem.lstrip.length
          curr_role = elem
          deps_hash[curr_role] = Set.new
        else
          deps_hash[curr_role].add(File.basename(elem, File.extname(elem)))
        end
      end

      # Now we can search for modified dependencies by iterating over each
      # role and checking the hash created earlier. Roles that have been
      # modified directly are automatically included in the impacted set.
      impacted_roles = Set.new(roles.map(&:name))
      deps_hash.each do |role, deplist|
        cookbooks.each do |cb|
          if deplist.include?(cb.name)
            impacted_roles.add(role)
            logger.info("\tFound dependency: #{role} --> #{cb.name}")
            break
          end
        end
      end

      return impacted_roles
    end

    def self._print_impact(final_impact)
      if TasteTester::Config.json
        puts JSON.pretty_generate(final_impact.to_a)
      elsif final_impact.empty?
        logger.warn('No impacted roles were found.')
      else
        logger.warn('The following roles have modified dependencies.' +
                    ' Please test a host in each of these roles.')
        final_impact.each { |r| logger.warn("\t#{r}") }
      end
    end
  end
end
