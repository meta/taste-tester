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
require 'timeout'
require 'chef/mash'

require 'between_meals/util'
require 'taste_tester/config'

module TasteTester
  # State of taste-tester processes
  class State
    include TasteTester::Config
    include TasteTester::Logging
    extend TasteTester::Logging
    include ::BetweenMeals::Util

    def initialize
      ref_dir = File.dirname(File.expand_path(TasteTester::Config.ref_file))
      unless File.directory?(ref_dir)
        begin
          FileUtils.mkpath(ref_dir)
        rescue StandardError => e
          logger.error("Chef temp dir #{ref_dir} missing and can't be created")
          logger.error(e)
          exit(1)
        end
      end
    end

    def port
      TasteTester::State.read(:port)
    end

    def port=(port)
      write(:port, port)
    end

    def ssl
      TasteTester::State.read(:ssl)
    end

    def ssl=(ssl)
      write(:ssl, ssl)
    end

    def logging
      TasteTester::State.read(:logging)
    end

    def logging=(logging)
      write(:logging, logging)
    end

    def ssh
      TasteTester::State.read(:ssh)
    end

    def ssh=(ssh)
      write(:ssh, ssh)
    end

    def ref
      TasteTester::State.read(:ref)
    end

    def ref=(ref)
      write(:ref, ref)
    end

    def last_upload_time
      TasteTester::State.read(:last_upload_time)
    end

    def last_upload_time=(time)
      write(:last_upload_time, time)
    end

    def bundle
      val = TasteTester::State.read(:bundle)
      # promote value to symbol to match config value.
      return :compatible if val == 'compatible'
      val
    end

    def bundle=(bundle)
      write(:bundle, bundle)
    end

    def update(vals)
      merge(vals)
    end

    def self.port
      TasteTester::State.read(:port)
    end

    def wipe
      # Save port between restarts. It might not be free when we restart, but
      # at least we'll try to keep the same
      port = self.port
      real_wipe
      write(:port, port)
    end

    def real_wipe
      if TasteTester::Config.ref_file &&
         File.exist?(TasteTester::Config.ref_file)
        File.delete(TasteTester::Config.ref_file)
      end
    end

    def self.read(key)
      JSON.parse(File.read(TasteTester::Config.ref_file))[key.to_s]
    rescue StandardError => e
      logger.debug(e)
      nil
    end

    private

    def write(key, val)
      merge({ key => val })
    end

    def merge(vals)
      # we generally use symbols for the keys, but to/from JSON will
      # give us strings, and thus duplicate keys, which is bad. So
      # use a Mash
      state = Mash.new
      begin
        state = JSON.parse(File.read(TasteTester::Config.ref_file))
      rescue StandardError
        state = {}
      end
      state.merge!(vals)
      ff = File.open(
        TasteTester::Config.ref_file,
        'w',
      )
      ff.write(state.to_json)
      ff.close
    rescue StandardError => e
      logger.error('Unable to write the reffile')
      logger.debug(e)
      exit 0
    end
  end
end
