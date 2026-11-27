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

require 'fileutils'
require 'socket'

require 'between_meals/util'
require 'taste_tester/config'
require 'taste_tester/state'
require 'taste_tester/windows'

module TasteTester
  # Stateless chef-zero server management
  class Server
    include TasteTester::Config
    include TasteTester::Logging
    extend ::BetweenMeals::Util

    attr_accessor :user, :host, :bundle_dir

    def initialize
      @state = TasteTester::State.new
      @ref_file = TasteTester::Config.ref_file
      ref_dir = File.dirname(File.expand_path(@ref_file))
      @log_file = File.join(ref_dir, 'chef-zero.log')
      @fsroot = File.join(ref_dir, 'root')
      @zero_path = TasteTester::Config.chef_zero_path
      unless File.directory?(ref_dir)
        begin
          FileUtils.mkpath(ref_dir)
        rescue StandardError => e
          logger.warn("Chef temp dir #{ref_dir} missing and can't be created")
          logger.warn(e)
        end
      end
      if TasteTester::Config.bundle
        @bundle_dir = File.join(@fsroot, 'organizations/chef/file_store')
        FileUtils.mkpath(@bundle_dir)
      end

      @user = ENV['USER']

      # SSL and logging are obvious, but SSH is also required since it
      # determines if we listen only on localhost or not
      @need_restart = @state.ssl != TasteTester::Config.use_ssl ||
                      @state.logging != TasteTester::Config.chef_zero_logging ||
                      @state.ssh != TasteTester::Config.use_ssh_tunnels ||
                      @state.bundle != TasteTester::Config.bundle

      # If we are using SSH tunneling listen on localhost, otherwise listen
      # on all addresses - both v4 and v6. Note that on localhost, ::1 is
      # v6-only, so we default to 127.0.0.1 instead.
      if TasteTester::Config.use_ssh_tunnels
        @addrs = ['127.0.0.1']
        @host = 'localhost'
      else
        @addrs = ['::', '0.0.0.0']
        begin
          @host = TasteTester::Config.my_hostname || Socket.gethostname
        rescue StandardError
          logger.error('Unable to find fqdn')
          exit 1
        end
      end
    end

    def start
      if TasteTester::Server.running?
        if @need_restart
          logger.warn('Restarting taste-tester server for config change')
          stop_chef_zero
          @need_restart = false
        else
          return
        end
      else
        logger.warn('Starting taste-tester server')
      end
      @state.wipe
      write_config
      start_chef_zero
    end

    def stop
      logger.warn('Stopping taste-tester server')
      @state.wipe
      stop_chef_zero
    end

    def restart
      logger.warn('Restarting taste-tester server')
      if TasteTester::Server.running?
        stop_chef_zero
        @state.ref = nil
      end
      write_config
      start_chef_zero
    end

    def port
      @state.port
    end

    def port=(port)
      @state.port = port
    end

    def latest_uploaded_ref
      @state.ref
    end

    def latest_uploaded_ref=(ref)
      @state.ref = ref
    end

    def last_upload_time
      @state.last_upload_time
    end

    def last_upload_time=(time)
      @state.last_upload_time = time
    end

    def self.running?
      if TasteTester::State.port
        return chef_zero_running?(TasteTester::State.port,
                                  TasteTester::Config.use_ssl)
      end

      false
    end

    private

    def write_config
      knife = BetweenMeals::Knife.new(
        :logger => logger,
        :user => @user,
        :ssl => TasteTester::Config.use_ssl,
        :host => @host,
        :port => port,
        :role_dir => TasteTester::Config.roles,
        :cookbook_dirs => TasteTester::Config.cookbooks,
        :checksum_dir => TasteTester::Config.checksum_dir,
        :config => TasteTester::Config.knife_config,
      )
      knife.write_user_config
    end

    def start_chef_zero
      File.unlink(@log_file) if File.exist?(@log_file)
      @state.update({
                      :port => TasteTester::Config.chef_port,
                      :ssl => TasteTester::Config.use_ssl,
                      :ssh => TasteTester::Config.use_ssh_tunnels,
                      :logging => TasteTester::Config.chef_zero_logging,
                      :bundle => TasteTester::Config.bundle,
                    })
      logger.info("Starting chef-zero of port #{@state.port}")
      if windows?
        extend ::TasteTester::Windows
        start_win_chef_zero_server
      else
        hostarg = @addrs.map { |addr| "--host #{addr}" }.join(' ')
        cmd = +"#{chef_zero_path} #{hostarg} --port #{@state.port} -d"
        if TasteTester::Config.chef_zero_logging
          cmd << " --log-file #{@log_file}" +
            ' --log-level debug'
        end
        cmd << ' --ssl' if TasteTester::Config.use_ssl
        cmd << " --file-store #{@fsroot}" if TasteTester::Config.bundle
        Mixlib::ShellOut.new(cmd).run_command.error!
      end
    end

    # Pattern defaults to chef-zero; tests pass a unique marker so the real
    # pkill path runs without touching any live server.
    def stop_chef_zero(pattern = 'bin/chef-zero')
      if windows?
        extend ::TasteTester::Windows
        nuke_all_cz_pids
      else
        logger.info('Killing your chef-zero instances')
        s = Mixlib::ShellOut.new("pkill -9 -u #{ENV['USER']} -f #{pattern}")
        s.run_command
        # You have to give it a moment to stop or the stat fails
        sleep(1)
      end
    end

    def chef_zero_path
      if TasteTester::Config.chef_zero_path
        return TasteTester::Config.chef_zero_path
      end

      ENV['PATH'].split(':').each do |path|
        zero = "#{path}/chef-zero"
        return zero if File.exist?(zero)
      end
      logger.error('chef-zero not found')
      exit(1)
    end

    def windows?
      Gem.win_platform?
    end
  end
end
