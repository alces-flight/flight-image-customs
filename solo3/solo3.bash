#!/bin/bash 
#
# Build a Solo image from source code releases of software
#

set -e

# Variables
flight_ROOT="/opt/flight"

# Third Party Versions
VERSION_RUBY_BUILD="v20240530.1"
VERSION_RUBY=3.3.2

# Flight Tool Versions
VERSION_RUNWAY=1.2.0
VERSION_STARTER=2024.1.0
VERSION_HOWTO=1.1.3
VERSION_DESKTOP=1.11.6
VERSION_DESKTOP_TYPES=1.3.6
VERSION_ENV=1.5.2
VERSION_ENV_TYPES=1.0.8

# Functions 
command_file() {
CMD="$1"
VERS="$2"
DESC="$3"
cat << EOF > $flight_ROOT/libexec/commands/$CMD
: '
: NAME: $CMD
: SYNOPSIS: $DESC
: VERSION: $VERS
: '
#==============================================================================
# Copyright (C) 2020-present Alces Flight Ltd.
#
# This program and the accompanying materials are made available under
# the terms of the Eclipse Public License 2.0 which is available at
# <https://www.eclipse.org/legal/epl-2.0>, or alternative license
# terms made available by Alces Flight Ltd - please direct inquiries
# about licensing to licensing@alces-flight.com.
#
# This project is distributed in the hope that it will be useful, but
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, EITHER EXPRESS OR
# IMPLIED INCLUDING, WITHOUT LIMITATION, ANY WARRANTIES OR CONDITIONS
# OF TITLE, NON-INFRINGEMENT, MERCHANTABILITY OR FITNESS FOR A
# PARTICULAR PURPOSE. See the Eclipse Public License 2.0 for more
# details.
#
# You should have received a copy of the Eclipse Public License 2.0
# along with this project. If not, see:
#
#  https://opensource.org/licenses/EPL-2.0
#
#===============================================================================
EOF
}

# Install dependencies
dnf config-manager --set-enabled crb
dnf -y groupinstall "Development Tools"
dnf install -y autoconf gcc rust patch make bzip2 openssl-devel libyaml-devel libffi-devel readline-devel zlib-devel gdbm-devel ncurses-devel
dnf -y install wget # Used by flight env types
dnf -y install epel-release # Use for some desktop deps, maybe some other stuff too?

# Flight Runway
git clone -b $VERSION_RUNWAY https://github.com/openflighthpc/flight-runway $flight_ROOT

# Ruby
curl -sL https://github.com/rbenv/ruby-build/archive/refs/tags/$VERSION_RUBY_BUILD.tar.gz > /tmp/ruby-build.tar.gz
mkdir /tmp/ruby-build
cd /tmp/ruby-build
tar --strip-components -xzf ruby-build.tar.gz
PREFIX=$flight_ROOT/opt/ruby-build/ ./install.sh

$flight_ROOT/opt/ruby-build/bin/ruby-build $VERSION_RUBY $flight_ROOT/opt/ruby/
export PATH="$flight_ROOT/opt/ruby/bin:$PATH"

# Flight Runway Setup 
cd $flight_ROOT/bin
for a in bundle gem irb rake ruby ; do
  rm -f $a
  ln -s $(which $a) $a
done

cd $flight_ROOT
mv -f pkg/bin/flintegrate bin/flintegrate
mv -f pkg/bin/banner bin/banner
mkdir -p $flight_ROOT/opt/runway
mv pkg/dist $flight_ROOT/opt/runway

# Flight Starter
git clone -b $VERSION_STARTER https://github.com/openflighthpc/flight-starter /tmp/flight-starter
cp -Rv /tmp/flight-starter/dist/* /

# Flight HowTo
git clone -b $VERSION_HOWTO https://github.com/openflighthpc/flight-howto $flight_ROOT/opt/howto

cd $flight_ROOT/opt/howto
rm -f Gemfile.lock # TODO: Fix for jump from Ruby 2.7 -> 3.3.2
$flight_ROOT/bin/bundle config set --local path vendor
$flight_ROOT/bin/bundle config set --local with default
$flight_ROOT/bin/bundle config set --local without development
$flight_ROOT/bin/bundle install

command_file howto $VERSION_HOWTO 'View user guides for your HPC environment'
cat << 'EOF' >> $flight_ROOT/libexec/commands/howto
export RUBYOPT='-W0'
export FLIGHT_CWD=$(pwd)
cd /opt/flight/opt/howto
export FLIGHT_PROGRAM_NAME="${flight_NAME} $(basename $0)"
flexec bundle exec bin/howto "$@"
EOF

# TODO: Add these patches
sed -i 's/File.exists/File.file/g' lib/flight-howto/config.rb
sed -i 's/Dir.exists/Dir.exist/g' lib/flight-howto/template_context.rb

mkdir -p $flight_ROOT/etc/howto.d/ $flight_ROOT/usr/share/howto/
cat << 'EOF' > $flight_ROOT/etc/howto.d/openflight.yaml
PRODUCT_SHORT:  OpenFlight
PRODUCT_LONG:   OpenFlightHPC
PRODUCT_DOMAIN: openflighthpc.org
EOF

# Flight Desktop
git clone -b $VERSION_DESKTOP  https://github.com/openflighthpc/flight-desktop $flight_ROOT/opt/desktop

cd $flight_ROOT/opt/desktop
rm -f Gemfile.lock
sed -i "s|gem 'xdg'.*|gem 'xdg', git: 'https://github.com/bkuhlmann/xdg'|g" Gemfile #TODO: Implement fix
sed -i "s|gem 'flight_configuration'.*|gem 'flight_configuration', github: 'openflighthpc/flight_configuration'|g" Gemfile #TODO: Implement fix
$flight_ROOT/bin/bundle config set --local path vendor
$flight_ROOT/bin/bundle config set --local with default
$flight_ROOT/bin/bundle config set --local without development
$flight_ROOT/bin/bundle install

# TODO: Apply these patches
sed -i 's/File.exists/File.file/g' $flight_ROOT/opt/desktop/lib/desktop/commands/start.rb
sed -i 's/File.exists/File.file/g' $flight_ROOT/opt/desktop/lib/desktop/config.rb
sed -i 's/File.exists/File.file/g' $flight_ROOT/opt/desktop/lib/desktop/type.rb
sed -i "s/gem 'bundler'.*/gem 'bundler'/g" $flight_ROOT/opt/desktop/bin/desktop
sed -i "s,^require_relative 'patches/unicode-display_width',#require_relative 'patches/unicode-display_width',g" $flight_ROOT/opt/desktop/lib/desktop/type.rb
sed -i 's/extend FlightConfiguration::DSL/include FlightConfiguration::DSL/g' $flight_ROOT/opt/desktop/lib/desktop/config.rb
sed -i "s/ERB.new(<<~TEMPLATE, nil, '-')/ERB.new(<<~TEMPLATE, trim_mode: '-')/g" $flight_ROOT/opt/desktop/lib/desktop/cli.rb # Fixes safe_level deprecation warning
sed -i 's/ENV.clone/ENV.to_h/g' $flight_ROOT/opt/desktop/lib/desktop/command_utils.rb # Fixes 'Error, Cannot clone ENV'

cat << EOF > $flight_ROOT/opt/desktop/etc/config.yml
type_paths:
  - $flight_ROOT/usr/lib/desktop/types
  - $flight_ROOT/etc/desktop/types
global_state_path: $flight_ROOT/var/lib/desktop
global_log_path: $flight_ROOT/var/log/desktop
websockify_paths:
  - /opt/flight/opt/websockify/bin/websockify
  - /usr/bin/websockify
EOF

command_file desktop $VERSION_DESKTOP 'Manage interactive GUI desktop sessions'
cat << 'EOF' >> $flight_ROOT/libexec/commands/desktop
export FLIGHT_CWD=$(pwd)
cd /opt/flight/opt/desktop
export FLIGHT_PROGRAM_NAME="${flight_NAME} $(basename $0)"
flexec bundle exec bin/desktop "$@"
EOF

cat << 'EOF' > $flight_ROOT/etc/banner/tips.d/20-desktop.rc
flight_TIP_command="flight desktop"
flight_TIP_synopsis="manage interactive GUI desktop sessions"
EOF

# Flight Desktop Types
mkdir -p $flight_ROOT/usr/lib/desktop/
git clone -b $VERSION_DESKTOP_TYPES https://github.com/openflighthpc/flight-desktop-types  $flight_ROOT/usr/lib/desktop/types

# Flight Env 
git clone -b $VERSION_ENV https://github.com/openflighthpc/flight-env $flight_ROOT/opt/env

cd $flight_ROOT/opt/env
rm -f Gemfile.lock # TODO: Fix for jump from Ruby 2.7 -> 3.3.2
echo "gem 'abbrev'" >> Gemfile # TODO: Fix for "warning: abbrev was loaded from the standard library, but will no longer be part of the default gems since Ruby 3.4.0"
$flight_ROOT/bin/bundle config set --local path vendor
$flight_ROOT/bin/bundle config set --local with default
$flight_ROOT/bin/bundle config set --local without development
$flight_ROOT/bin/bundle install

cat << EOF > $flight_ROOT/opt/env/etc/config.yml
type_paths: 
  - $flight_ROOT/usr/lib/env/types
  - $flight_ROOT/etc/env/types
global_depot_path: $flight_ROOT/var/lib/env
global_build_cache_path: $flight_ROOT/var/cache/env/build
global_cache_path: $flight_ROOT/var/cache/env
EOF

command_file env $VERSION_ENV 'Manage and access HPC application ecosystems'
cat << 'EOF' >> $flight_ROOT/libexec/commands/env
export FLIGHT_CWD=$(pwd)
cd /opt/flight/opt/env
export FLIGHT_PROGRAM_NAME="${flight_NAME} $(basename $0)"
# The following 'exec .../bundle' incantation is used to ensure that flenv
# receives the correct parent shell, rather than the shell of this
# script (which is always bash).
exec ${flight_ROOT:-/opt/flight}/bin/bundle exec bin/flenv "$@"
EOF

#TODO: Add these to Flight Env
curl -sL https://raw.githubusercontent.com/openflighthpc/openflight-omnibus-builder/master/builders/flight-env/opt/flight/etc/profile.d/999-env.sh > $flight_ROOT/etc/profile.d/999-env.sh
curl -sL https://raw.githubusercontent.com/openflighthpc/openflight-omnibus-builder/master/builders/flight-env/opt/flight/etc/profile.d/999-env.csh > $flight_ROOT/etc/profile.d/999-env.csh

cat << 'EOF' > $flight_ROOT/etc/banner/tips.d/10-env.rc
flight_TIP_command="flight env"
flight_TIP_synopsis="manage software package ecosystems"
EOF

cat << 'EOF' > $flight_ROOT/etc/env.rc
flight_ENV_root=${flight_ROOT:-/opt/flight}/opt/env
EOF

cat << 'EOF' > $flight_ROOT/etc/env.cshrc
if ( ! $?flight_ROOT ) then
  setenv flight_ROOT /opt/flight
endif
setenv flight_ENV_root "${flight_ROOT}/opt/env"
EOF

#TODO: Implement these patches
sed -i "s/gem 'bundler'.*/gem 'bundler'/g" $flight_ROOT/opt/env/bin/flenv
sed -i "s,^require_relative 'patches/unicode-display_width',#require_relative 'patches/unicode-display_width',g" $flight_ROOT/opt/env/lib/env/type.rb
sed -i 's/File.exists/File.file/g' $flight_ROOT/opt/env/lib/env/type.rb

#TODO: Actually handle documentation, straight from OpenFlight docs hits parsing issues - perhaps all repos should contain their own man pages? I don't think it makes sense for omnibus to be doing this.
echo '# Flight ENV(1) - Manage and access HPC ecosystems' > $flight_ROOT/usr/share/howto/flight-env.md
curl -sL https://raw.githubusercontent.com/openflighthpc/docs.openflighthpc.org/main/docs/docs/flight-environment/use-flight/flight-user-suite/flight-env/usage.md >> $flight_ROOT/usr/share/howto/flight-env.md
for ecosystem in conda easybuild modules singularity spack ; do 
    echo "# Flight ENV(1) - Using the $ecosystem ecosystem" > $flight_ROOT/usr/share/howto/flight-env-$ecosystem.md
    curl -sL https://raw.githubusercontent.com/openflighthpc/docs.openflighthpc.org/main/docs/docs/flight-environment/use-flight/flight-user-suite/flight-env/ecosystems/$ecosystem.md >> $flight_ROOT/usr/share/howto/flight-env-$ecosystem.md
done

# Flight Env Types
mkdir -p $flight_ROOT/usr/lib/env/
git clone -b $VERSION_ENV_TYPES https://github.com/openflighthpc/flight-env-types  $flight_ROOT/usr/lib/env/types

# TODO: Fix this bug - works as expected after logout+in
# [rocky@sfcleansource1 ~]$ flight env create conda@test
# Creating environment conda@test
#    > ✅ Verifying prerequisites
#    > ✅ Fetching prerequisite (miniconda)
#    > ✅ Creating environment (conda@test)
# Environment conda@test has been created
# [rocky@sfcleansource1 ~]$ flight env list
# ┌────────────┬───────┐
# │ Name       │ Scope │
# ├────────────┼───────┤
# │ conda@test │ user  │
# └────────────┴───────┘
# [rocky@sfcleansource1 ~]$ flight env activate conda
# flight env: directly executed activation not possible; try --subshell, or: 'eval "$(flight_ENV_eval=true bin/flenv activate conda)"'

# TODO: Fix this bug - Newer conda ? Newer Ruby? cannot resolve:
# conda install tensorflow
# But can resolve
# conda install --solver classic tensorflow # actually this doesn't work
# Could be forcibly overridden in our env stuff by setting CONDA_SOLVER to classic 
# IT'S BECAUSE PYTHON 3.12 IS NOT YET SUPPORTED BY TENSORFLOW
# TODO: Actually do some good version locking in Env Types stuff so we can prevent this from happening


# Flight Silo 




#
# Flight Web Suite 
#

# Probs adapt sf dev script for source running 


#
# Tidy up
#
rm -rf /tmp/ruby-build
rm -rf /tmp/flight-starter
rm -rf /opt/flight/pkg

