# Copyright 2026-present Facebook
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
require 'json'
require 'logger'
require 'tmpdir'
require_relative '../lib/taste_tester/logging'
require_relative '../lib/taste_tester/server'

describe TasteTester::State do
  let(:config_hash) { TasteTester::Config.save(true) }
  let(:tmpdir) { Dir.mktmpdir }
  let(:ref_file) { File.join(tmpdir, 'ref.json') }
  let(:ref) { '426f245cc96aeaf4ef2aa8c274294db91566417c' }

  before do
    TasteTester::Config.restore(config_hash)
    TasteTester::Config.ref_file ref_file
    TasteTester::Config.my_hostname 'localhost'
  end

  after do
    TasteTester::Config.restore(config_hash)
    FileUtils.remove_entry(tmpdir) if File.exist?(tmpdir)
  end

  it 'stores one ref when replacing a cleared upload revision' do
    File.write(ref_file, '{"port":5257,"ssl":false,"ssh":true,"logging":true,"ref":null}')

    TasteTester::Server.new.latest_uploaded_ref = ref

    expect(File.read(ref_file).scan(/"ref"\s*:/).size).to eq(1)
    server = TasteTester::Server.new
    expect(server.latest_uploaded_ref).to eq(ref)
    expect(server.port).to eq(5257)
  end

  it 'stores one timestamp when recording a subsequent upload' do
    server = TasteTester::Server.new
    server.last_upload_time = '2026-01-01 12:00:00'
    server.latest_uploaded_ref = ref
    server.last_upload_time = '2026-01-01 12:01:00'

    expect(File.read(ref_file).scan(/"last_upload_time"\s*:/).size).to eq(1)
    expect(TasteTester::Server.new.last_upload_time).to eq('2026-01-01 12:01:00')
    expect(TasteTester::Server.new.latest_uploaded_ref).to eq(ref)
  end

  it 'replaces saved server settings on a batch update' do
    state = described_class.new
    state.update(:port => 5257, :ssl => false, :ssh => true)
    state.update(:port => 5258, :ssl => true)

    persisted = File.read(ref_file)
    expect(persisted.scan(/"port"\s*:/).size).to eq(1)
    expect(persisted.scan(/"ssl"\s*:/).size).to eq(1)
    expect(JSON.parse(persisted)).to eq('port' => 5258, 'ssl' => true, 'ssh' => true)
  end

  it 'rewrites previously duplicated refs with one current ref' do
    File.write(ref_file, %({"port":5257,"ref":null,"ref":"#{ref}"}))

    described_class.new.ref = nil

    expect(File.read(ref_file).scan(/"ref"\s*:/).size).to eq(1)
    expect(JSON.parse(File.read(ref_file))).to eq('port' => 5257, 'ref' => nil)
  end

  it 'resets to merged values when the ref file holds corrupt JSON' do
    File.write(ref_file, '{"port":5257,"ref":')

    expect { described_class.new.update(:port => 5258, :ssl => true) }.not_to raise_error

    expect(JSON.parse(File.read(ref_file))).to eq('port' => 5258, 'ssl' => true)
  end
end
