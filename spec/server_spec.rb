# Copyright (c) 2026-present, Meta Platforms, Inc. and affiliates.
# All rights reserved.
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
require 'logger'
require 'rbconfig'
require 'tmpdir'
require 'between_meals/knife'
require_relative '../lib/taste_tester/logging'
require_relative '../lib/taste_tester/config'
require_relative '../lib/taste_tester/state'
require_relative '../lib/taste_tester/server'

describe TasteTester::Server do
  let(:config_hash) { TasteTester::Config.save(true) }
  let(:tmpdir) { Dir.mktmpdir }

  before do
    TasteTester::Config.restore(config_hash)
    TasteTester::Config.ref_file File.join(tmpdir, 'ref.json')
    TasteTester::Config.knife_config File.join(tmpdir, 'knife.rb')
    TasteTester::Config.use_ssh_tunnels true
    TasteTester::Config.bundle false
    TasteTester::Config.use_ssl true
    TasteTester::Config.chef_zero_logging false
    allow(Gem).to receive(:win_platform?).and_return(false)
    allow(BetweenMeals::Knife).to receive(:new).
      and_return(double('knife', :write_user_config => nil))
  end

  after do
    TasteTester::Config.restore(config_hash)
    FileUtils.remove_entry(tmpdir) if File.exist?(tmpdir)
  end

  context '#start' do
    it 'starts chef-zero' do
      TasteTester::Config.bundle false
      allow(TasteTester::Server).to receive(:running?).and_return(false)
      server = TasteTester::Server.new
      expect(server).to receive(:start_chef_zero)
      server.start
    end

    it 'does nothing when running with matching state' do
      TasteTester::Config.bundle true
      TasteTester::State.new.update(
        :ssl => true, :ssh => true, :logging => false, :bundle => true,
      )
      allow(TasteTester::Server).to receive(:running?).and_return(true)
      server = TasteTester::Server.new
      expect(server).not_to receive(:stop_chef_zero)
      expect(server).not_to receive(:start_chef_zero)
      server.start
    end
  end

  context '#stop' do
    it 'stops chef-zero' do
      server = TasteTester::Server.new
      expect(server).to receive(:stop_chef_zero)
      server.stop
    end
  end

  context '#restart' do
    it 'restarts chef-zero' do
      allow(TasteTester::Server).to receive(:running?).and_return(true)
      server = TasteTester::Server.new
      expect(server).to receive(:stop_chef_zero)
      expect(server).to receive(:start_chef_zero)
      server.restart
    end
  end

  context '#stop_chef_zero with real pkill' do
    it 'kills processes matching the pattern' do
      marker = "taste-tester-pkill-probe-#{Process.pid}"
      pid = spawn(
        [RbConfig.ruby, marker], '-e', 'sleep 60',
        :out => File::NULL, :err => File::NULL
      )
      begin
        server = TasteTester::Server.new
        allow(server).to receive(:logger).and_return(Logger.new('/dev/null'))
        server.send(:stop_chef_zero, marker)
        deadline = Time.now + 10
        reaped = nil
        until reaped || Time.now > deadline
          reaped = Process.waitpid(pid, Process::WNOHANG)
          sleep 0.1 unless reaped
        end
        expect(reaped).to eq(pid)
      ensure
        begin
          Process.kill('KILL', pid)
        rescue Errno::ESRCH
          nil
        end
        begin
          Process.waitpid(pid)
        rescue Errno::ECHILD
          nil
        end
      end
    end
  end

  context '.running?' do
    it 'is false without a port' do
      expect(TasteTester::Server.running?).to eq(false)
    end

    it 'reports running when chef-zero answers' do
      TasteTester::State.new.update(:port => 4321)
      allow(TasteTester::Server).to receive(:chef_zero_running?).
        and_return(true)
      expect(TasteTester::Server.running?).to eq(true)
    end

    it 'reports stopped when chef-zero is silent' do
      TasteTester::State.new.update(:port => 4321)
      allow(TasteTester::Server).to receive(:chef_zero_running?).
        and_return(false)
      expect(TasteTester::Server.running?).to eq(false)
    end
  end
end
