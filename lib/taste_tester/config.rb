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

require 'mixlib/config'
require 'taste_tester/logging'
require 'between_meals/util'
require 'etc'

module TasteTester
  # Config file parser and config object
  # Uses Mixlib::Config v1 syntax so it works in Chef10 omnibus...
  # it's compatible with v2, so it should work in 11 too.
  module Config
    extend Mixlib::Config
    extend TasteTester::Logging
    extend BetweenMeals::Util

    repo "#{ENV['HOME']}/ops"
    repo_type 'auto'
    base_dir 'chef'
    cookbook_dirs ['cookbooks']
    role_dir 'roles'
    databag_dir 'databags'
    role_type 'rb'
    config_file '/etc/taste-tester-config.rb'
    plugin_path nil
    chef_zero_path nil
    bundle false
    bundle_compression_level 6
    bundle_generation_processes nil
    verbosity Logger::WARN
    timestamp false
    user 'root'
    ref_file "#{ENV['HOME']}/.chef/taste-tester-ref.json"
    knife_config "#{ENV['HOME']}/.chef/knife-#{ENV['USER']}-taste-tester.rb"
    checksum_dir "#{ENV['HOME']}/.chef/checksums"
    skip_repo_checks false
    chef_client_command 'chef-client'
    testing_time 3600
    chef_port_range [5000, 5500]
    tunnel_port 4001
    timestamp_file '/etc/chef/test_timestamp'
    use_ssh_tunnels false
    ssh_command 'ssh'
    ssh_connect_timeout 5
    ssh_cmd_gen_template nil
    use_ssl true
    chef_zero_logging true
    chef_config_path '/etc/chef'
    chef_config 'client.rb'
    my_hostname nil
    track_symlinks false
    transport 'ssh'
    no_repo false
    json false
    jumps nil
    windows_target false
    parallel_hosts Etc.nprocessors

    # Start/End refs for calculating changes in the repo.
    #  - start_ref should be the "master" commit of the repository
    #  - end_ref should be nil to compare with the working set,
    #    or something like '.' to compare with the most recent commit
    vcs_start_ref_git 'origin/HEAD'
    vcs_start_ref_hg 'master'
    vcs_end_ref nil

    skip_pre_upload_hook false
    skip_post_upload_hook false
    skip_pre_test_hook false
    skip_post_test_hook false
    skip_repo_checks_hook false

    def self.cookbooks
      cookbook_dirs.map do |x|
        File.join(repo, base_dir, x)
      end
    end

    def self.relative_cookbook_dirs
      cookbook_dirs.map do |x|
        base_dir && !base_dir.empty? ? File.join(base_dir, x) : x
      end
    end

    def self.roles
      File.join(repo, base_dir, role_dir)
    end

    def self.relative_role_dir
      base_dir && !base_dir.empty? ? File.join(base_dir, role_dir) : role_dir
    end

    def self.databags
      File.join(repo, base_dir, databag_dir)
    end

    def self.relative_databag_dir
      if base_dir && !base_dir.empty?
        File.join(base_dir, databag_dir)
      else
        databag_dir
      end
    end

    def self.absolute_base_dir
      File.join(repo, base_dir)
    end

    def self.chef_port
      require 'taste_tester/state'
      port_range = (
        chef_port_range.first.to_i..chef_port_range.last.to_i
      ).to_a.shuffle
      if TasteTester::State.port
        port_range.unshift(TasteTester::State.port)
      end
      port_range.each do |port|
        unless port_open?(port)
          return port
        end
      end
      logger.error 'Could not find a free port in range' +
        " [#{chef_port_range.first}, #{chef_port_range.last}]"
      exit 1
    end

    def self.testing_end_time
      TasteTester::Config.testing_until ||
        Time.now + TasteTester::Config.testing_time
    end
  end
end
