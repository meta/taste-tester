# Copyright 2020-present Facebook
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
require 'pathname'
require 'rubygems/package'
require 'stringio'
require 'tempfile'
require 'tmpdir'
require 'zlib'
require 'between_meals/util'
require 'mixlib/shellout'
require_relative '../lib/taste_tester/logging'
require_relative '../lib/taste_tester/exceptions'
require_relative '../lib/taste_tester/config'
require_relative '../lib/taste_tester/client'

describe TasteTester::Client do
  let(:config_hash) do
    TasteTester::Config.save(true)
  end

  let(:tmpdir) { Dir.mktmpdir }
  let(:bundle_dir) { File.join(tmpdir, 'bundle') }
  let(:repo_dir) { File.join(tmpdir, 'repo') }

  let(:knife) do
    double('knife',
           :write_user_config => nil,
           :cookbook_upload_all => nil,
           :role_upload_all => nil,
           :databag_upload_all => nil)
  end

  let(:repo) { double('repo', :exists? => true) }

  let(:server) do
    double('server',
           :user => 'root',
           :host => 'mock_host',
           :port => 1234,
           :bundle_dir => bundle_dir,
           :latest_uploaded_ref => 'mock_ref')
  end

  let(:client) { TasteTester::Client.new(server) }

  before do
    TasteTester::Config.restore(config_hash)
    # THIS IS VERY IMPORTANT!!! If we don't mock **every** call to
    # Mixlib::ShellOut we can nuke the data on any machine that runs the unit
    # tests so we mock it to return BS, this ensures if we miss mocking a call
    # the tests fail rather than nuking the host
    allow_any_instance_of(Mixlib::ShellOut).to receive(:run_command).
      and_return(nil)
    FileUtils.mkdir_p(bundle_dir)
    FileUtils.mkdir_p(repo_dir)
    TasteTester::Config.repo repo_dir
    TasteTester::Config.base_dir 'chef'
    TasteTester::Config.cookbook_dirs ['cookbooks']
    TasteTester::Config.role_dir 'roles'
    TasteTester::Config.databag_dir 'databags'
    TasteTester::Config.ref_file File.join(tmpdir, 'ref.json')
    TasteTester::Config.knife_config File.join(tmpdir, 'knife.rb')
    TasteTester::Config.checksum_dir File.join(tmpdir, 'checksums')
    TasteTester::Config.bundle false
    TasteTester::Config.bundle_compression_level 6
    TasteTester::Config.bundle_generation_processes 1
    allow(BetweenMeals::Knife).to receive(:new).and_return(knife)
    allow(BetweenMeals::Repo).to receive(:get).and_return(repo)
    allow_any_instance_of(TasteTester::Client).to receive(:logger).
      and_return(Logger.new('/dev/null'))
  end

  after do
    TasteTester::Config.restore(config_hash)
    FileUtils.remove_entry(tmpdir) if File.exist?(tmpdir)
  end

  def tar_entries(data)
    entries = []
    Gem::Package::TarReader.new(StringIO.new(data)) do |tar|
      tar.each do |entry|
        entries << [
          entry.full_name,
          entry.read,
          entry.header.typeflag,
          entry.header.linkname,
          entry.header.mode,
        ]
      end
    end
    entries
  end

  def bundle_entries(path)
    tar_entries(bundle_raw(path))
  end

  def bundle_raw(path)
    Zlib::GzipReader.wrap(File.open(path, 'rb'), &:read)
  end

  def write_repo_file(relative_path, content)
    path = File.join(repo_dir, relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def write_chunk(path, entries)
    File.open(path, 'wb') do |file|
      Minitar::Writer.open(file) do |writer|
        entries.each do |name, content|
          writer.add_file_simple(
            name, :mode => 0o644, :size => content.bytesize
          ) do |data, _opts|
            data.write(content)
          end
        end
      end
    end
  end

  context 'harness' do
    it 'builds a client from stubbed collaborators against tmpdir fixtures' do
      expect(client.instance_variable_get(:@server)).to eq(server)
      expect(client.instance_variable_get(:@knife)).to eq(knife)
      expect(client.instance_variable_get(:@repo)).to eq(repo)
      expect(TasteTester::Config.repo).to eq(repo_dir)
      expect(knife).to have_received(:write_user_config)
    end
  end

  # Private methods are exercised with `send`; that is the only
  # exception to testing through the public API, forced by `private`
  # in `client.rb`.
  context 'assemble_bundle' do
    let(:chunks_dir) { File.join(tmpdir, 'chunks') }
    let(:dest) { File.join(bundle_dir, 'tt.tgz') }
    let(:chunk1) { File.join(chunks_dir, 'chunk1.tar') }
    let(:chunk2) { File.join(chunks_dir, 'chunk2.tar') }

    before do
      FileUtils.mkdir_p(chunks_dir)
      write_chunk(chunk1, [['a.txt', 'AAA'], ['b.txt', 'BBB']])
      write_chunk(chunk2, [['c.txt', 'CCC']])
    end

    it 'concatenates two chunks, stripping the middle end blocks' do
      expect(client.send(:assemble_bundle, [chunk1, chunk2])).to eq(0)
      expect(File.exist?(dest)).to eq(true)
      raw = bundle_raw(dest)
      expect(raw.bytesize).to eq(4096)
      expect(raw[-1024..-1]).to eq("\0" * 1024)
      expect(raw[2048, 5]).to eq('c.txt')
      expect(bundle_entries(dest)).to eq(
        [
          ['a.txt', 'AAA', '0', '', 0o644],
          ['b.txt', 'BBB', '0', '', 0o644],
          ['c.txt', 'CCC', '0', '', 0o644],
        ],
      )
    end

    it 'sorts chunk paths, so input order does not matter' do
      client.send(:assemble_bundle, [chunk2, chunk1])
      sorted = bundle_raw(dest)
      client.send(:assemble_bundle, [chunk1, chunk2])
      expect(bundle_raw(dest)).to eq(sorted)
      expect(bundle_entries(dest).map(&:first)).to eq(
        ['a.txt', 'b.txt', 'c.txt'],
      )
    end

    it 'round-trips a single chunk' do
      client.send(:assemble_bundle, [chunk1])
      expect(bundle_entries(dest).map { |name, content, _, _, _| [name, content] }).to eq(
        [['a.txt', 'AAA'], ['b.txt', 'BBB']],
      )
    end

    it 'writes a valid empty bundle for an empty file list' do
      expect(client.send(:assemble_bundle, [])).to eq(0)
      expect(bundle_raw(dest)).to eq("\0" * 1024)
      expect(bundle_entries(dest)).to eq([])
    end

    it 'replaces an existing bundle and leaves no stray tempfile' do
      File.write(dest, 'SENTINEL')
      client.send(:assemble_bundle, [chunk1])
      expect(bundle_entries(dest).map(&:first)).to eq(['a.txt', 'b.txt'])
      expect(Dir.children(bundle_dir)).to eq(['tt.tgz'])
    end

    it 'returns nil and leaves an existing bundle untouched when a chunk is missing' do
      File.write(dest, 'SENTINEL')
      expect(
        client.send(:assemble_bundle, [File.join(chunks_dir, 'nope.tar')]),
      ).to be_nil
      expect(File.read(dest)).to eq('SENTINEL')
    end

    it 'returns nil and creates nothing when a chunk is missing and no bundle exists' do
      expect(
        client.send(:assemble_bundle, [File.join(chunks_dir, 'nope.tar')]),
      ).to be_nil
      expect(File.exist?(dest)).to eq(false)
    end

    it 'returns nil when the bundle directory does not exist' do
      missing_dir = File.join(tmpdir, 'no-such-dir')
      missing_server = double('server',
                              :user => 'root',
                              :host => 'mock_host',
                              :port => 1234,
                              :bundle_dir => missing_dir,
                              :latest_uploaded_ref => 'mock_ref')
      missing_client = TasteTester::Client.new(missing_server)
      expect(missing_client.send(:assemble_bundle, [chunk1])).to be_nil
      expect(File.exist?(missing_dir)).to eq(false)
    end

    it 'copies a chunk smaller than 1024 bytes whole' do
      small = File.join(chunks_dir, 'small.tar')
      File.write(small, 'X' * 100)
      client.send(:assemble_bundle, [small])
      expect(bundle_raw(dest)).to eq(('X' * 100) + ("\0" * 1024))
    end

    it 'contributes nothing from a chunk of exactly 1024 bytes' do
      exact = File.join(chunks_dir, 'exact.tar')
      File.write(exact, 'Y' * 1024)
      client.send(:assemble_bundle, [exact])
      expect(bundle_raw(dest)).to eq("\0" * 1024)
      expect(bundle_entries(dest)).to eq([])
    end

    it 'round-trips at compression level 0' do
      TasteTester::Config.bundle_compression_level 0
      client.send(:assemble_bundle, [chunk1])
      expect(bundle_entries(dest).map { |name, content, _, _, _| [name, content] }).to eq(
        [['a.txt', 'AAA'], ['b.txt', 'BBB']],
      )
    end

    it 'round-trips at compression level 6' do
      TasteTester::Config.bundle_compression_level 6
      client.send(:assemble_bundle, [chunk1])
      expect(bundle_entries(dest).map { |name, content, _, _, _| [name, content] }).to eq(
        [['a.txt', 'AAA'], ['b.txt', 'BBB']],
      )
    end

    it 'raises instead of returning nil for an invalid compression level' do
      TasteTester::Config.bundle_compression_level 99
      expect do
        client.send(:assemble_bundle, [chunk1])
      end.to raise_error(Zlib::StreamError)
    end
  end

  context 'gen_file_list' do
    let(:cookbooks) { File.join(repo_dir, 'chef', 'cookbooks') }

    before do
      FileUtils.mkdir_p(cookbooks)
    end

    it 'returns nil for a path that does not exist' do
      expect(client.send(:gen_file_list, 'chef/nope', 'cookbooks')).to be_nil
    end

    it 'returns nil for a regular file' do
      File.write(File.join(cookbooks, 'file.txt'), 'x')
      expect(client.send(:gen_file_list, 'chef/cookbooks/file.txt', 'cookbooks')).to be_nil
    end

    it 'returns an empty list for an empty directory' do
      expect(client.send(:gen_file_list, 'chef/cookbooks', 'cookbooks')).to eq([])
    end

    it 'lists regular files at top level and nested, never directories' do
      FileUtils.mkdir_p(File.join(cookbooks, 'cb1', 'recipes'))
      File.write(File.join(cookbooks, 'cb1', 'metadata.rb'), 'y')
      File.write(File.join(cookbooks, 'cb1', 'recipes', 'default.rb'), 'x')
      result = client.send(:gen_file_list, 'chef/cookbooks', 'cookbooks')
      expect(result.sort).to eq(
        [
          [cookbooks, 'cb1/metadata.rb', 'cookbooks'],
          [cookbooks, 'cb1/recipes/default.rb', 'cookbooks'],
        ].sort,
      )
    end

    it 'preserves the destination verbatim' do
      File.write(File.join(cookbooks, 'file.txt'), 'x')
      expect(client.send(:gen_file_list, 'chef/cookbooks', 'my-dest')).to eq(
        [[cookbooks, 'file.txt', 'my-dest']],
      )
    end

    it 'lists dotfiles and never lists dot entries' do
      FileUtils.mkdir_p(File.join(cookbooks, 'cb1'))
      File.write(File.join(cookbooks, '.hidden'), 'h')
      File.write(File.join(cookbooks, 'cb1', '.dotfile'), 'd')
      result = client.send(:gen_file_list, 'chef/cookbooks', 'cookbooks')
      expect(result.sort).to eq(
        [
          [cookbooks, '.hidden', 'cookbooks'],
          [cookbooks, 'cb1/.dotfile', 'cookbooks'],
        ].sort,
      )
    end

    it 'follows a symlinked directory at the top level' do
      real_dir = File.join(tmpdir, 'realdir')
      FileUtils.mkdir_p(real_dir)
      File.write(File.join(real_dir, 'shared.rb'), 's')
      File.symlink(real_dir, File.join(cookbooks, 'linked'))
      result = client.send(:gen_file_list, 'chef/cookbooks', 'cookbooks')
      expect(result).to eq([[cookbooks, 'linked/shared.rb', 'cookbooks']])
    end

    it 'does not follow a symlinked directory below the top level' do
      real_dir = File.join(tmpdir, 'realdir')
      FileUtils.mkdir_p(real_dir)
      File.write(File.join(real_dir, 'shared.rb'), 's')
      FileUtils.mkdir_p(File.join(cookbooks, 'cb1'))
      File.write(File.join(cookbooks, 'cb1', 'kept.rb'), 'k')
      File.symlink(real_dir, File.join(cookbooks, 'cb1', 'nestedlink'))
      result = client.send(:gen_file_list, 'chef/cookbooks', 'cookbooks')
      expect(result).to eq([[cookbooks, 'cb1/kept.rb', 'cookbooks']])
    end

    it 'lists a symlinked regular file as a file entry' do
      target = File.join(cookbooks, 'target.rb')
      File.write(target, 't')
      File.symlink(target, File.join(cookbooks, 'link.rb'))
      result = client.send(:gen_file_list, 'chef/cookbooks', 'cookbooks')
      expect(result.sort).to eq(
        [
          [cookbooks, 'link.rb', 'cookbooks'],
          [cookbooks, 'target.rb', 'cookbooks'],
        ].sort,
      )
    end
  end

  context 'generate_intermediate_tar' do
    let(:base) { File.join(tmpdir, 'base') }

    before do
      FileUtils.mkdir_p(base)
    end

    def intermediate_entries(path)
      tar_entries(File.read(path))
    end

    it 'writes a regular file with mode 0644 in the bundle directory' do
      File.write(File.join(base, 'hello.txt'), 'hello')
      path = client.send(
        :generate_intermediate_tar, [[base, 'hello.txt', 'cookbooks']], 0, '12345'
      )
      expect(File.dirname(path)).to eq(bundle_dir)
      expect(File.basename(path)).to start_with('12345')
      expect(intermediate_entries(path)).to eq(
        [['cookbooks/hello.txt', 'hello', '0', '', 0o644]],
      )
    end

    it 'writes a symlink entry with its readlink target' do
      File.write(File.join(base, 'hello.txt'), 'hello')
      File.symlink('hello.txt', File.join(base, 'alink'))
      path = client.send(
        :generate_intermediate_tar, [[base, 'alink', 'cookbooks']], 0, '12345'
      )
      expect(intermediate_entries(path)).to eq(
        [['cookbooks/alink', nil, '2', 'hello.txt', 0o644]],
      )
    end

    it 'raises for a symlink whose destination name is longer than 100 characters' do
      rel = 's' * 91
      expect(File.join('cookbooks', rel).size).to eq(101)
      File.write(File.join(base, 'hello.txt'), 'hello')
      File.symlink('hello.txt', File.join(base, rel))
      expect do
        client.send(
          :generate_intermediate_tar, [[base, rel, 'cookbooks']], 0, '12345'
        )
      end.to raise_error(RuntimeError, 'Add support for long symlink paths')
    end

    it 'succeeds for a symlink whose destination name is exactly 100 characters' do
      rel = 's' * 90
      expect(File.join('cookbooks', rel).size).to eq(100)
      File.write(File.join(base, 'hello.txt'), 'hello')
      File.symlink('hello.txt', File.join(base, rel))
      path = client.send(
        :generate_intermediate_tar, [[base, rel, 'cookbooks']], 0, '12345'
      )
      expect(intermediate_entries(path).map(&:first)).to eq(
        [File.join('cookbooks', rel)],
      )
    end

    it 'skips a file ignored by the relative-path chefignore check' do
      File.write(File.join(base, 'chefignore'), "ignored.rb\n")
      File.write(File.join(base, 'ignored.rb'), 'ign')
      File.write(File.join(base, 'kept.rb'), 'keep')
      path = client.send(
        :generate_intermediate_tar,
        [[base, 'ignored.rb', 'cookbooks'], [base, 'kept.rb', 'cookbooks']],
        0, '12345'
      )
      expect(intermediate_entries(path).map(&:first)).to eq(['cookbooks/kept.rb'])
    end

    it 'skips a file ignored only by the minus-first chefignore check' do
      File.write(File.join(base, 'chefignore'), "thing.rb\n")
      FileUtils.mkdir_p(File.join(base, 'subdir'))
      File.write(File.join(base, 'subdir', 'thing.rb'), 'ign')
      File.write(File.join(base, 'kept.rb'), 'keep')
      path = client.send(
        :generate_intermediate_tar,
        [[base, 'subdir/thing.rb', 'cookbooks'], [base, 'kept.rb', 'cookbooks']],
        0, '12345'
      )
      expect(intermediate_entries(path).map(&:first)).to eq(['cookbooks/kept.rb'])
    end

    it 'returns a valid empty tar for an empty bucket' do
      path = client.send(:generate_intermediate_tar, [], 0, '12345')
      expect(File.size(path)).to eq(1024)
      expect(intermediate_entries(path)).to eq([])
    end

    it 'raises for a missing file in the bucket' do
      expect do
        client.send(
          :generate_intermediate_tar, [[base, 'gone.txt', 'cookbooks']], 0, '12345'
        )
      end.to raise_error(Errno::ENOENT)
    end

    it 'keeps both entries when two bucket entries share a destination name' do
      base2 = File.join(tmpdir, 'base2')
      FileUtils.mkdir_p(base2)
      File.write(File.join(base, 'one.txt'), 'ONE')
      File.write(File.join(base2, 'one.txt'), 'TWO')
      path = client.send(
        :generate_intermediate_tar,
        [[base, 'one.txt', 'cookbooks'], [base2, 'one.txt', 'cookbooks']],
        0, '12345'
      )
      expect(intermediate_entries(path)).to eq(
        [
          ['cookbooks/one.txt', 'ONE', '0', '', 0o644],
          ['cookbooks/one.txt', 'TWO', '0', '', 0o644],
        ],
      )
    end
  end

  context 'bundle_upload with one process' do
    let(:dest) { File.join(bundle_dir, 'tt.tgz') }

    before do
      allow(client).to receive(:puts)
      write_repo_file('chef/cookbooks/cb1/metadata.rb', 'meta')
      write_repo_file('chef/cookbooks/cb1/recipes/default.rb', 'recipe')
      write_repo_file('chef/cookbooks/cb1/chefignore', "ignored.rb\n")
      write_repo_file('chef/cookbooks/cb1/ignored.rb', 'ign')
      File.symlink(
        'metadata.rb',
        File.join(repo_dir, 'chef', 'cookbooks', 'cb1', 'link.rb'),
      )
      write_repo_file('chef/roles/web.rb', 'role')
      write_repo_file('chef/databags/bag1/item.json', '{}')
    end

    it 'creates tt.tgz with the cookbook, role, and databag entries, and cleans up chunks' do
      client.send(:bundle_upload)
      entries = bundle_entries(dest)
      expect(entries.map(&:first).sort).to eq(
        [
          'cookbooks/cb1/chefignore',
          'cookbooks/cb1/link.rb',
          'cookbooks/cb1/metadata.rb',
          'cookbooks/cb1/recipes/default.rb',
          'data_bags/bag1/item.json',
          'roles/web.rb',
        ],
      )
      by_name = entries.to_h { |name, content, typeflag, linkname, _| [name, [content, typeflag, linkname]] }
      expect(by_name['cookbooks/cb1/metadata.rb']).to eq(['meta', '0', ''])
      expect(by_name['cookbooks/cb1/recipes/default.rb']).to eq(['recipe', '0', ''])
      expect(by_name['cookbooks/cb1/link.rb']).to eq([nil, '2', 'metadata.rb'])
      expect(by_name['roles/web.rb']).to eq(['role', '0', ''])
      expect(by_name['data_bags/bag1/item.json']).to eq(['{}', '0', ''])
      expect(Dir.children(bundle_dir)).to eq(['tt.tgz'])
    end

    it 'cleans up chunk files when assembly fails, and the error propagates' do
      allow(client).to receive(:assemble_bundle).and_raise(RuntimeError, 'boom')
      expect { client.send(:bundle_upload) }.to raise_error(RuntimeError, 'boom')
      expect(Dir.children(bundle_dir)).to eq([])
    end
  end

  context 'bundle_upload with empty fixture dirs' do
    let(:dest) { File.join(bundle_dir, 'tt.tgz') }

    before do
      allow(client).to receive(:puts)
      FileUtils.mkdir_p(File.join(repo_dir, 'chef', 'cookbooks'))
      FileUtils.mkdir_p(File.join(repo_dir, 'chef', 'roles'))
      FileUtils.mkdir_p(File.join(repo_dir, 'chef', 'databags'))
    end

    it 'produces a valid empty bundle with one process' do
      client.send(:bundle_upload)
      expect(bundle_entries(dest)).to eq([])
      expect(Dir.children(bundle_dir)).to eq(['tt.tgz'])
    end

    it 'raises ArgumentError with two processes and leaves nothing behind' do
      TasteTester::Config.bundle_generation_processes 2
      expect { client.send(:bundle_upload) }.to raise_error(ArgumentError)
      expect(Dir.children(bundle_dir)).to eq([])
    end
  end

  context 'bundle_upload with multiple processes' do
    let(:dest) { File.join(bundle_dir, 'tt.tgz') }
    let(:file_count) { 5 }

    before do
      allow(client).to receive(:puts)
      allow(Parallel).to receive(:map) do |range, **_opts, &block|
        range.map { |i| block.call(i) }
      end
      file_count.times do |n|
        write_repo_file("chef/cookbooks/cb1/file#{n}.rb", "content#{n}")
      end
      FileUtils.mkdir_p(File.join(repo_dir, 'chef', 'roles'))
      FileUtils.mkdir_p(File.join(repo_dir, 'chef', 'databags'))
    end

    def capture_buckets_and_chunks
      buckets = []
      assembled = []
      allow(client).to receive(:generate_intermediate_tar).and_wrap_original do |original, bucket, i, prefix|
        buckets << bucket
        original.call(bucket, i, prefix)
      end
      allow(client).to receive(:assemble_bundle).and_wrap_original do |original, files|
        assembled << files
        original.call(files)
      end
      [buckets, assembled]
    end

    it 'splits five files into buckets of three and two with two processes' do
      TasteTester::Config.bundle_generation_processes 2
      buckets, assembled = capture_buckets_and_chunks
      client.send(:bundle_upload)
      expect(buckets.map(&:size)).to eq([3, 2])
      expect(assembled.size).to eq(1)
      expect(assembled.first.size).to eq(2)
      expect(bundle_entries(dest).map(&:first).sort).to eq(
        (0...5).map { |n| "cookbooks/cb1/file#{n}.rb" },
      )
    end

    context 'with four files' do
      let(:file_count) { 4 }

      it 'splits four files into one-file buckets with three processes' do
        TasteTester::Config.bundle_generation_processes 3
        buckets, assembled = capture_buckets_and_chunks
        client.send(:bundle_upload)
        expect(buckets.map(&:size)).to eq([1, 1, 1, 1])
        expect(assembled.size).to eq(1)
        expect(assembled.first.size).to eq(4)
        expect(bundle_entries(dest).map(&:first).sort).to eq(
          (0...4).map { |n| "cookbooks/cb1/file#{n}.rb" },
        )
      end
    end

    it 'falls back to Etc.nprocessors when bundle_generation_processes is nil' do
      TasteTester::Config.bundle_generation_processes nil
      allow(Etc).to receive(:nprocessors).and_return(4)
      buckets, _assembled = capture_buckets_and_chunks
      client.send(:bundle_upload)
      expect(Etc).to have_received(:nprocessors)
      expect(buckets.map(&:size)).to eq([1, 1, 1, 1, 1])
      expect(bundle_entries(dest).map(&:first).sort).to eq(
        (0...5).map { |n| "cookbooks/cb1/file#{n}.rb" },
      )
    end
  end

  context 'full' do
    it 'uploads with knife and never bundles when bundle is false' do
      TasteTester::Config.bundle false
      expect(client).not_to receive(:bundle_upload)
      expect(knife).to receive(:cookbook_upload_all).ordered
      expect(knife).to receive(:role_upload_all).ordered
      expect(knife).to receive(:databag_upload_all).ordered
      client.send(:full)
    end

    it 'bundles then uploads with knife when bundle is :compatible' do
      TasteTester::Config.bundle :compatible
      expect(client).to receive(:bundle_upload).ordered
      expect(knife).to receive(:cookbook_upload_all).ordered
      expect(knife).to receive(:role_upload_all).ordered
      expect(knife).to receive(:databag_upload_all).ordered
      client.send(:full)
    end

    it 'bundles and returns before any knife call when bundle is true' do
      TasteTester::Config.bundle true
      expect(client).to receive(:bundle_upload)
      expect(knife).not_to receive(:cookbook_upload_all)
      expect(knife).not_to receive(:role_upload_all)
      expect(knife).not_to receive(:databag_upload_all)
      client.send(:full)
    end

    it 'propagates a bundle_upload error without falling through to knife' do
      TasteTester::Config.bundle true
      allow(client).to receive(:bundle_upload).and_raise(RuntimeError, 'boom')
      expect(knife).not_to receive(:cookbook_upload_all)
      expect { client.send(:full) }.to raise_error(RuntimeError, 'boom')
    end
  end

  context 'partial' do
    let(:changeset) do
      double('changeset', :cookbooks => [], :roles => [], :databags => [])
    end

    before do
      allow(BetweenMeals::Changeset).to receive(:new).and_return(changeset)
    end

    it 'consults the changeset and never bundles when bundle is false' do
      TasteTester::Config.bundle false
      expect(client).not_to receive(:bundle_upload)
      client.send(:partial)
      expect(BetweenMeals::Changeset).to have_received(:new)
      expect(changeset).to have_received(:cookbooks)
      expect(changeset).to have_received(:roles)
      expect(changeset).to have_received(:databags)
    end

    it 'bundles then consults the changeset when bundle is :compatible' do
      TasteTester::Config.bundle :compatible
      expect(client).to receive(:bundle_upload)
      client.send(:partial)
      expect(BetweenMeals::Changeset).to have_received(:new)
    end

    it 'bundles and returns before constructing a changeset when bundle is true' do
      TasteTester::Config.bundle true
      expect(client).to receive(:bundle_upload)
      expect(BetweenMeals::Changeset).not_to receive(:new)
      client.send(:partial)
    end

    it 'propagates a bundle_upload error without constructing a changeset' do
      TasteTester::Config.bundle true
      allow(client).to receive(:bundle_upload).and_raise(RuntimeError, 'boom')
      expect(BetweenMeals::Changeset).not_to receive(:new)
      expect { client.send(:partial) }.to raise_error(RuntimeError, 'boom')
    end
  end
end
