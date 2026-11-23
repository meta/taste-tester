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

Gem::Specification.new do |s|
  s.name = 'taste_tester'
  s.version = '0.0.21'
  s.summary = 'Taste Tester'
  s.description = 'Utility for testing Chef changes using chef-zero'
  s.license = 'Apache-2.0'
  s.authors = ['Phil Dibowitz', 'Marcin Sawicki']
  s.homepage = 'https://github.com/facebook/taste-tester'
  s.platform = Gem::Platform::RUBY
  s.extra_rdoc_files = %w{README.md LICENSE}

  s.bindir = %w{bin}
  s.executables = %w{taste-tester}
  s.files = %w{README.md LICENSE} +
    Dir.glob('{lib,scripts}/**/*', File::FNM_DOTMATCH).
            reject { |f| File.directory?(f) }

  s.add_dependency 'between_meals', '>= 0.0.11'
  s.add_dependency 'chef'
  s.add_dependency 'colorize'
  # without an explicit dependency, json is resolved to 1.7.7 on Ruby 2.4
  # which doesn't compile.
  s.add_dependency 'json', '>= 2.0.0'
  s.add_dependency 'minitar', '>= 0.6.1'
  s.add_dependency 'mixlib-config'
end
