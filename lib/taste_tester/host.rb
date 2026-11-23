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
require 'base64'
require 'open3'
require 'colorize'

require 'taste_tester/ssh'
require 'taste_tester/noop'
require 'taste_tester/locallink'
require 'taste_tester/tunnel'
require 'taste_tester/exceptions'

module TasteTester
  # Wrapper around IO to stream, prefixing the lines with the hostname
  class IO < ::IO
    def initialize(prefix, fd)
      @prefix = prefix.nil? || prefix.empty? ? '' : "#{prefix} "
      @first = true
      super(fd)
    end

    def <<(obj)
      if @first
        @first = false
        super(@prefix) if @prefix
      end
      msg = obj.to_s
      if msg[-1] == "\n"
        @first = true
        msg.chomp!
      end
      super(msg.gsub("\n", "\n#{@prefix}"))
      super("\n") if @first
    end
  end

  # Manage state of the remote node
  class Host
    include TasteTester::Logging

    TASTE_TESTER_CONFIG = 'client-taste-tester.rb'.freeze
    USER_PREAMBLE = '# TasteTester by '.freeze

    attr_reader :name

    def initialize(name, server)
      @name = name
      @user = ENV['USER']
      @server = server
      if TasteTester::Config.use_ssh_tunnels
        @tunnel = TasteTester::Tunnel.new(@name, @server)
      end
    end

    def runchef
      logger.warn("Running '#{TasteTester::Config.chef_client_command}' " +
                  "on #{@name}")
      transport = get_transport
      transport << TasteTester::Config.chef_client_command

      io = TasteTester::IO.new(name, 1)
      status, = transport.run(io)
      status
    end

    def get_transport
      case TasteTester::Config.transport
      when 'locallink'
        TasteTester::LocalLink.new
      when 'noop'
        TasteTester::NoOp.new
      else
        TasteTester::SSH.new(@name)
      end
    end

    def test
      logger.warn("Taste-testing on #{@name}")

      if TasteTester::Config.use_ssh_tunnels
        # Nuke any existing tunnels that may be there
        TasteTester::Tunnel.kill(@name)

        # Then setup the tunnel
        @tunnel.run
      end

      serialized_config = Base64.encode64(config).delete("\n")

      # Then setup the testing
      transport = get_transport

      # see if someone else is taste-testing
      transport << we_testing

      if TasteTester::Config.windows_target
        add_windows_test_cmds(transport, serialized_config)
      else
        add_sane_os_test_cmds(transport, serialized_config)
      end

      # look again to see if someone else is taste-testing. This is where
      # we work out if we won or lost a race with another user.
      transport << we_testing

      status, output = transport.run

      case status
      when 0
        # no problem, keep going.
        nil
      when 42
        fail TasteTester::Exceptions::AlreadyTestingError, output.chomp
      else
        transport.error!
      end

      # Then run any other stuff they wanted
      cmds = TasteTester::Hooks.test_remote_cmds(
        TasteTester::Config.dryrun,
        @name,
      )

      if cmds&.any?
        transport = get_transport
        cmds.each { |c| transport << c }
        transport.run!
      end
      status
    end

    def untest
      logger.warn("Removing #{@name} from taste-tester")
      transport = get_transport
      if TasteTester::Config.use_ssh_tunnels
        TasteTester::Tunnel.kill(@name)
      end
      if TasteTester::Config.windows_target
        add_windows_untest_cmds(transport)
      else
        add_sane_os_untest_cmds(transport)
      end
      transport.run!
    end

    def we_testing
      config_file = "#{TasteTester::Config.chef_config_path}/" +
        TasteTester::Config.chef_config
      # Look for signature of TasteTester
      # 1. Look for USER_PREAMBLE line prefix
      # 2. See if user is us, or someone else
      # 3. if someone else is testing: emit username, exit with code 42 which
      #    short circuits the test verb
      # This is written as a squiggly heredoc so the indentation of the awk is
      # preserved. Later we remove the newlines to make it a bit easier to read.
      if TasteTester::Config.windows_target
        shellcode = <<~ENDOFSHELLCODE
          Get-Content #{config_file} | ForEach-Object {
            if (\$_ -match "#{USER_PREAMBLE}" ) {
              $user = \$_.Split()[-1]
              if (\$user -ne "#{@user}") {
                echo \$user
                exit 42
              }
            }
          }
        ENDOFSHELLCODE
      else
        shellcode = <<~ENDOFSHELLCODE
          awk "\\$0 ~ /^#{USER_PREAMBLE}/{
            if (\\$NF != \\"#{@user}\\"){
              print \\$NF;
              exit 42
            }
          }" #{config_file}
        ENDOFSHELLCODE
        shellcode.chomp!
      end
      shellcode
    end

    def keeptesting
      logger.warn("Renewing taste-tester on #{@name} until" +
        " #{TasteTester::Config.testing_end_time.strftime('%y%m%d%H%M.%S')}")
      if TasteTester::Config.use_ssh_tunnels
        TasteTester::Tunnel.kill(@name)
        @tunnel = TasteTester::Tunnel.new(@name, @server)
        @tunnel.run
      else
        transport = get_transport
        transport << touchcmd
        transport.run!
      end
    end

    private

    # Sources must be 'registered' with the Eventlog, so check if we have
    # registered and register if necessary
    def create_eventlog_if_needed_cmd
      get_src = 'Get-EventLog -LogName Application -source taste-tester 2>$null'
      mk_src = 'New-EventLog -source "taste-tester" -LogName Application'
      "if (-Not (#{get_src})) { #{mk_src} }"
    end

    # Remote testing commands for most OSes...
    def add_sane_os_test_cmds(transport, serialized_config)
      transport << 'logger -t taste-tester Moving server into taste-tester' +
        " for #{@user}"
      transport << touchcmd
      # shell redirection is also racy, so make a temporary file first
      transport << "tmpconf=$(mktemp #{TasteTester::Config.chef_config_path}/" +
        "#{TASTE_TESTER_CONFIG}.TMPXXXXXX)"
      transport << "/bin/echo -n \"#{serialized_config}\" | base64 --decode" +
        ' > "${tmpconf}"'
      # then rename it to replace any existing file
      transport << 'mv -f "${tmpconf}" ' +
        "#{TasteTester::Config.chef_config_path}/#{TASTE_TESTER_CONFIG}"
      transport << "( ln -vsf #{TasteTester::Config.chef_config_path}" +
        "/#{TASTE_TESTER_CONFIG} #{TasteTester::Config.chef_config_path}/" +
        "#{TasteTester::Config.chef_config}; true )"
    end

    # Remote testing commands for Windows
    def add_windows_test_cmds(transport, serialized_config)
      # This is the closest equivalent to 'bash -x' - but if we put it on
      # by default the way we do with linux it badly breaks our output. So only
      # set it if we're in debug
      #
      # This isn't the most optimal place for this. It should be in ssh_util
      # and we should jam this into the beggining of the cmds list we get,
      # but this is early enough and good enough for now and we can think about
      # that when we refactor tunnel.sh, ssh.sh and ssh_util.sh into one sane
      # class.
      if logger.level == Logger::DEBUG
        transport << 'Set-PSDebug -trace 1'
      end

      ttconfig =
        "#{TasteTester::Config.chef_config_path}/#{TASTE_TESTER_CONFIG}"
      realconfig = "#{TasteTester::Config.chef_config_path}/" +
        TasteTester::Config.chef_config
      [
        create_eventlog_if_needed_cmd,
        'Write-EventLog -LogName "Application" -Source "taste-tester" ' +
          '-EventID 1 -EntryType Information ' +
          "-Message \"Moving server into taste-tester for #{@user}\"",
        touchcmd,
        "$b64 = \"#{serialized_config}\"",
        "$ttconfig = \"#{ttconfig}\"",
        "$realconfig = \"#{realconfig}\"",

        '$tmp64 = (New-TemporaryFile).name',
        '$tmp = (New-TemporaryFile).name',

        '$b64 | Out-File -Encoding ASCII $tmp64 -Force',

        # Remove our tmp file before we write to it or certutil crashes...
        "#{win_rm_f} $tmp",
        'certutil -decode $tmp64 $tmp',
        'mv $tmp $ttconfig -Force',

        'New-Item -ItemType SymbolicLink -Value $ttconfig $realconfig -Force',
      ].each do |cmd|
        transport << cmd
      end
    end

    def touchcmd
      if TasteTester::Config.windows_target
        # There's no good touch equivalent in Windows. You can force
        # creation of a new file, but that'll nuke it's contents, which if we're
        # 'keeptesting'ing, then we'll loose the contents (PID and such).
        # We can set the timestamp with Get-Item.creationtime, but it must exist
        # if we're not gonna crash. So do both.
        [
          "$ts = \"#{TasteTester::Config.timestamp_file}\"",
          'if (-Not (Test-Path $ts)) { New-Item -ItemType file $ts }',
          '(Get-Item "$ts").LastWriteTime=("' +
            "#{TasteTester::Config.testing_end_time}\")",
        ].join(';')
      else
        touch = Base64.encode64(
          "if [ 'Darwin' = $(uname) ]; then touch -t \"$(date -r " +
          "#{TasteTester::Config.testing_end_time.to_i} +'%Y%m%d%H%M.%S')\" " +
          "#{TasteTester::Config.timestamp_file}; else touch --date \"$(date " +
          "-d @#{TasteTester::Config.testing_end_time.to_i} +'%Y-%m-%d %T')\"" +
          " #{TasteTester::Config.timestamp_file}; fi",
        ).delete("\n")
        "/bin/echo -n '#{touch}' | base64 --decode | bash"
      end
    end

    # Remote untesting commands for Windows
    def add_windows_untest_cmds(transport)
      config_prod = TasteTester::Config.chef_config.split('.').join('-prod.')
      tt_config =
        "#{TasteTester::Config.chef_config_path}/#{TASTE_TESTER_CONFIG}"
      pem_file = "#{TasteTester::Config.chef_config_path}/client-prod.pem"
      pem_link = "#{TasteTester::Config.chef_config_path}/client.pem"

      [
        'New-Item -ItemType SymbolicLink -Force -Value ' +
          "#{TasteTester::Config.chef_config_path}/#{config_prod} " +
          "#{TasteTester::Config.chef_config_path}/" +
          TasteTester::Config.chef_config,
        'New-Item -ItemType SymbolicLink -Force -Value ' +
          "#{pem_file} #{pem_link}",
        "#{win_rm_f} #{tt_config}",
        "#{win_rm_f} #{TasteTester::Config.timestamp_file}",
        create_eventlog_if_needed_cmd,
        'Write-EventLog -LogName "Application" -Source "taste-tester" ' +
          '-EventID 4 -EntryType Information -Message "Returning server ' +
          'to production"',
      ].each do |cmd|
        transport << cmd
      end
    end

    # Remote untesting commands for most OSes...
    def add_sane_os_untest_cmds(transport)
      config_prod = TasteTester::Config.chef_config.split('.').join('-prod.')
      [
        "ln -vsf #{TasteTester::Config.chef_config_path}/#{config_prod} " +
          "#{TasteTester::Config.chef_config_path}/" +
          TasteTester::Config.chef_config,
        "ln -vsf #{TasteTester::Config.chef_config_path}/client-prod.pem " +
          "#{TasteTester::Config.chef_config_path}/client.pem",
        "rm -vf #{TasteTester::Config.chef_config_path}/#{TASTE_TESTER_CONFIG}",
        "rm -vf #{TasteTester::Config.timestamp_file}",
        'logger -t taste-tester Returning server to production',
      ].each do |cmd|
        transport << cmd
      end
    end

    def win_rm_f
      'Remove-Item -Force -ErrorAction SilentlyContinue'
    end

    def config
      scheme = TasteTester::Config.use_ssl ? 'https' : 'http'
      if TasteTester::Config.use_ssh_tunnels
        url = "#{scheme}://localhost:#{@tunnel.port}"
      else
        url = +"#{scheme}://#{@server.host}"
        url << ":#{TasteTester::State.port}" if TasteTester::State.port
      end
      ttconfig = <<~ENDOFSCRIPT
        #{USER_PREAMBLE}#{@user}
        # Prevent people from screwing up their permissions
        if Process.euid != 0
          puts 'Please run chef as root!'
          Process.exit!
        end

        log_level :info
        log_location STDOUT
        ssl_verify_mode :verify_none
        ohai.plugin_path << File.join('#{TasteTester::Config.chef_config_path}', 'ohai_plugins')
      ENDOFSCRIPT

      if TasteTester::Config.bundle
        ttconfig += <<~ENDOFSCRIPT
          taste_tester_dest = File.join(Dir.tmpdir, 'taste-tester')
          puts 'INFO: Downloading bundle from #{url}...'
          FileUtils.rmtree(taste_tester_dest)
          FileUtils.mkpath(taste_tester_dest)
          FileUtils.touch(File.join(taste_tester_dest, 'chefignore'))
          uri = URI.parse('#{url}/file_store/tt.tgz')
          Net::HTTP.start(
            uri.hostname,
            uri.port,
            :use_ssl => #{TasteTester::Config.use_ssl},
            # we expect self signed certificates
            :verify_mode => OpenSSL::SSL::VERIFY_NONE,
          ) do |http|
            http.request_get(uri) do |response|
              # the use of stringIO means we are buffering the entire file in
              # memory. This isn't very efficient, but it should work for
              # most practical cases.
              stream = Zlib::GzipReader.new(StringIO.new(response.body))
              Gem::Package::TarReader.new(stream).each do |e|
                dest = File.join(taste_tester_dest, e.full_name)
                FileUtils.mkpath(File.dirname(dest))
                if e.symlink?
                  File.symlink(e.header.linkname, dest)
                else
                  File.open(dest, 'wb+') do |f|
                    # https://github.com/rubygems/rubygems/pull/2303
                    # IO.copy_stream(e, f)
                    # workaround:
                    f.write(e.read)
                  end
                end
              end
            end
          end
          puts 'INFO: Download complete'
          solo true
          local_mode true
        ENDOFSCRIPT
      else
        ttconfig += <<~ENDOFSCRIPT
          chef_server_url '#{url}'
        ENDOFSCRIPT
      end

      extra = TasteTester::Hooks.test_remote_client_rb_extra_code(@name)
      if extra
        ttconfig += <<~ENDOFSCRIPT
          # Begin user-hook specified code
                  #{extra}
          # End user-hook secified code

        ENDOFSCRIPT
      end

      ttconfig += <<~ENDOFSCRIPT
        puts 'INFO: Running on #{@name} in taste-tester by #{@user}'
      ENDOFSCRIPT

      if TasteTester::Config.bundle
        # This is last in the configuration file because it needs to override
        # any values in test_remote_client_rb_extra_code
        ttconfig += <<~ENDOFSCRIPT
          chef_repo_path taste_tester_dest
        ENDOFSCRIPT
      end
      ttconfig
    end
  end
end
