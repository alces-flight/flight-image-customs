#!/bin/bash 
#
# Build a Solo image from source code releases of software
#

set -e

# Variables
flight_ROOT="/opt/flight"

# Script Execution
SKIP_THIRD_PARTY=""  # Set to 'y' to skip doing compilation/installation of Ruby, Python, Nginx, etc. Useful for when rerunning script to update flight tools

# Third Party Versions
VERSION_RUBY_BUILD="v20240530.1"
VERSION_RUBY=3.3.2
VERSION_NGINX=1.21.4
VERSION_PYTHON=3.8.10
VERSION_NODE=14.19.0
VERSION_YARN=1.22.17

# Flight Tool Versions
VERSION_RUNWAY=1.2.0
VERSION_STARTER=2024.1.0
VERSION_HOWTO=1.1.3
VERSION_DESKTOP=1.11.6
VERSION_DESKTOP_TYPES=1.3.6
VERSION_ENV=1.5.2
VERSION_ENV_TYPES=1.0.8
VERSION_CERT=0.6.1
VERSION_LANDING_PAGE=2.0.2
VERSION_WEBAPP_COMPONENTS=1.0.1
VERSION_SERVICE=1.5.0

# Execution Check

## Don't run if root
if [[ $UID == 0 ]] ; then
    echo "Don't run this script as root, it will break command usage for users on the system"
    exit 1
fi

## Check this user can do sudo dnf
if ! sudo dnf -v >> /dev/null ; then
    echo "User is unable to do sudo of dnf command or incorrect password entered. Exiting."
    exit 1
fi 

## Ensure flight_ROOT exists and is writeable to us
if ! [[ -d $flight_ROOT && -w $flight_ROOT ]] ; then
    echo "The directory $flight_ROOT does not exist or is not writeable by this user."
    echo "Ensure the directory exists, is owned by this user and has 775 permissions."
    exit 1
fi

## TODO: Maybe check that it's either empty or a valid git repo?


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

clone_or_update() {
# If directory is already present then we'll just do a pull and update
# e.g. clone_or_update http://github.com/example/example v1.0.0 /opt/example
REPO=$1
VERS=$2
DEST=$3
if [ ! -d $DEST/.git ] ; then
    git clone -b $VERS $REPO $DEST
else
    cd $DEST
    git fetch
    git checkout $VERS
fi
}

# Install dependencies
sudo dnf config-manager --set-enabled crb
sudo dnf -y groupinstall "Development Tools"
sudo dnf install -y autoconf gcc rust patch make bzip2 openssl-devel libyaml-devel libffi-devel readline-devel zlib-devel gdbm-devel ncurses-devel
sudo dnf -y install wget # Used by flight env types
sudo dnf -y install epel-release # Use for some desktop deps, maybe some other stuff too?

sudo setenforce 0 
sudo sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config

# Flight Runway
clone_or_update https://github.com/openflighthpc/flight-runway $VERSION_RUNWAY $flight_ROOT

# Ruby
if [[ $SKIP_THIRD_PARTY != "y" ]] ; then
    curl -sL https://github.com/rbenv/ruby-build/archive/refs/tags/$VERSION_RUBY_BUILD.tar.gz > /tmp/ruby-build.tar.gz
    mkdir -p /tmp/ruby-build
    cd /tmp/ruby-build
    tar --strip-components 1 -xzf /tmp/ruby-build.tar.gz
    PREFIX=$flight_ROOT/opt/ruby-build/ ./install.sh

    $flight_ROOT/opt/ruby-build/bin/ruby-build $VERSION_RUBY $flight_ROOT/opt/ruby/
fi

export PATH="$flight_ROOT/opt/ruby/bin:$PATH"

# Flight Runway Setup 
cd $flight_ROOT/bin
for a in bundle gem irb rake ruby ; do
  rm -f $a
  ln -sf $(which $a) $a
done

$flight_ROOT/bin/gem install paint --version 2.1.0 --bindir $flight_ROOT/opt/ruby/bin/ --no-document # Dep for banner stuff

cd $flight_ROOT
mkdir -p $flight_ROOT/opt/runway/bin/
cp -f pkg/bin/flintegrate $flight_ROOT/opt/runway/bin/flintegrate
cp -f pkg/bin/banner $flight_ROOT/opt/runway/bin/banner
rsync -au pkg/dist $flight_ROOT/opt/runway
rsync -au pkg/ruby/openflight* $flight_ROOT/opt/ruby/lib/ruby/site_ruby/*/x86_64-linux/

# Flight Starter
clone_or_update https://github.com/openflighthpc/flight-starter $VERSION_STARTER /tmp/flight-starter
sudo rsync -au /tmp/flight-starter/dist/etc/ /etc/
rsync -au /tmp/flight-starter/dist/opt/flight/ $flight_ROOT/

# Flight HowTo
clone_or_update https://github.com/openflighthpc/flight-howto $VERSION_HOWTO $flight_ROOT/opt/howto

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
cd $flight_ROOT/opt/howto
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
clone_or_update https://github.com/openflighthpc/flight-desktop $VERSION_DESKTOP $flight_ROOT/opt/desktop

cd $flight_ROOT/opt/desktop
rm -f Gemfile.lock
sed -i "s|gem 'xdg'.*|gem 'xdg'|g" Gemfile #TODO: Implement fix
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
  - $flight_ROOT/opt/websockify/bin/websockify
  - /usr/bin/websockify
EOF

command_file desktop $VERSION_DESKTOP 'Manage interactive GUI desktop sessions'
cat << 'EOF' >> $flight_ROOT/libexec/commands/desktop
export FLIGHT_CWD=$(pwd)
cd $flight_ROOT/opt/desktop
export FLIGHT_PROGRAM_NAME="${flight_NAME} $(basename $0)"
flexec bundle exec bin/desktop "$@"
EOF

cat << 'EOF' > $flight_ROOT/etc/banner/tips.d/20-desktop.rc
flight_TIP_command="flight desktop"
flight_TIP_synopsis="manage interactive GUI desktop sessions"
EOF

# Flight Desktop Types
mkdir -p $flight_ROOT/usr/lib/desktop/
clone_or_update https://github.com/openflighthpc/flight-desktop-types $VERSION_DESKTOP_TYPES $flight_ROOT/usr/lib/desktop/types

# Flight Env 
clone_or_update https://github.com/openflighthpc/flight-env $VERSION_ENV $flight_ROOT/opt/env

cd $flight_ROOT/opt/env
rm -f Gemfile.lock # TODO: Fix for jump from Ruby 2.7 -> 3.3.2
echo "gem 'abbrev'" >> Gemfile # TODO: Fix for "warning: abbrev was loaded from the standard library, but will no longer be part of the default gems since Ruby 3.4.0"
sed -i "s|gem 'xdg'.*|gem 'xdg'|g" Gemfile #TODO: Implement fix
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
cd $flight_ROOT/opt/env
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
clone_or_update https://github.com/openflighthpc/flight-env-types $VERSION_ENV_TYPES $flight_ROOT/usr/lib/env/types

# Flight Silo 




#
# Flight Web Suite 
#

# Nginx / WWW
if [[ $SKIP_THIRD_PARTY != "y" ]] ; then
    sudo dnf -y install pcre-devel
    wget -O /tmp/nginx-${VERSION_NGINX}.tar.gz https://nginx.org/download/nginx-${VERSION_NGINX}.tar.gz
    cd /tmp/
    tar xf nginx-${VERSION_NGINX}.tar.gz
    cd nginx-${VERSION_NGINX}
    ./configure --prefix=$flight_ROOT/opt/www/embedded --with-http_ssl_module --with-http_stub_status_module --with-ipv6 --with-debug --with-cc-opt="-L${flight_ROOT}/opt/www/embedded/lib -I${flight_ROOT}/opt/www/embedded/include" --with-ld-opt=-L${flight_ROOT}/opt/www/embedded/lib
    make -j $(nproc)
    make install
fi

mkdir -p $flight_ROOT/etc/www/
cat << EOF > $flight_ROOT/etc/www/nginx.conf
user nobody ;
worker_processes 1;
error_log $flight_ROOT/var/log/www/error.log warn;
pid $flight_ROOT/var/run/www.pid;

events {
    worker_connections 1024;
}

http {
    include $flight_ROOT/opt/www/embedded/conf/mime.types;
    include $flight_ROOT/etc/www/mime.types;
    default_type application/octet-stream;
    log_format main '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                    '\$status \$body_bytes_sent "\$http_referer" '
                    '"\$http_user_agent" "\$http_x_forwarded_for"';
    access_log $flight_ROOT/var/log/www/access.log main;
    sendfile on;
    #tcp_nopush on;
    keepalive_timeout 65;
    gzip on;
    error_page 404 @not-found;
    include $flight_ROOT/etc/www/http.d/*.conf;
}
EOF

mkdir -p $flight_ROOT/etc/logrotate.d/
cat << EOF > $flight_ROOT/etc/logrotate.d/www
# Rotate Flight WWW logs
$flight_ROOT/var/log/www/*.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    create 640 nobody adm
    sharedscripts
      postrotate
      [ -f $flight_ROOT/var/run/www.pid ] && kill -USR1 \`cat $flight_ROOT/var/run/www.pid\`
    endscript
}
EOF

mkdir -p $flight_ROOT/etc/service/types/www/
#TODO: Package these up or store them in a separate repo?
for i in configuration.yml configure.sh metadata.yml reload.sh restart.sh start.sh stop.sh ; do 
    wget -O $flight_ROOT/etc/service/types/www/$i https://raw.githubusercontent.com/openflighthpc/openflight-omnibus-builder/master/builders/flight-www/opt/flight/etc/service/types/www/$i 
done

mkdir -p  $flight_ROOT/etc/www/{http.d,server-http.d,server-https.d}
#TODO: Package these up or store them in a separate repo?
for i in http.d/base-http.conf http.d/geo.conf http.d/https.conf.disabled server-http.d/document-root.conf server-http.d/redirect-http-to-https.conf.disabled server-https.d/document-root.conf server-https.d/downloads.conf server-https.d/ssl-config.conf server-https.d/websocket-proxy.conf error-locations.conf mime.types; do 
    wget -O $flight_ROOT/etc/www/$i https://raw.githubusercontent.com/openflighthpc/openflight-omnibus-builder/master/builders/flight-www/opt/flight/etc/www/$i
    sed -i "s,/opt/flight,$flight_ROOT,g" $flight_ROOT/etc/www/$i
done

command_file www $VERSION_CERT 'Manage the HTTPs server and SSL certificates'
cat << 'EOF' >> $flight_ROOT/libexec/commands/www
if [ "$UID" != 0 ]; then
  exec sudo "${flight_ROOT}"/bin/flight "$(basename "$0")" "$@"
fi

export FLIGHT_PROGRAM_NAME='flight www'
export FLIGHT_CWD=$(pwd)
cd "${flight_ROOT}"/opt/www/cert
${flight_ROOT}/bin/flexec bundle exec bin/cert "$@"
EOF


# Flight Cert
clone_or_update https://github.com/openflighthpc/flight-cert $VERSION_CERT $flight_ROOT/opt/www/cert

cd $flight_ROOT/opt/www/cert
rm -f Gemfile.lock # TODO: Fix for jump from Ruby 2.7 -> 3.3.2
sed -i "s|gem 'flight_configuration'.*|gem 'flight_configuration', github: 'openflighthpc/flight_configuration'|g" Gemfile #TODO: Implement this fix
$flight_ROOT/bin/bundle config set --local path vendor
$flight_ROOT/bin/bundle config set --local with default
$flight_ROOT/bin/bundle config set --local without development
$flight_ROOT/bin/bundle install

#TODO: Docs in flight-cert still think it should be "production" not integrated
cat << 'EOF' > $flight_ROOT/opt/www/cert/.flight-environment
flight_ENVIRONMENT=integrated
EOF

cat << EOF > $flight_ROOT/etc/cert.yaml
program_name: flight www
certbot_bin: $flight_ROOT/opt/certbot/bin/certbot
certbot_plugin_flags: --nginx --nginx-ctl $flight_ROOT/opt/www/embedded/sbin/nginx --nginx-server-root $flight_ROOT/etc/www --config-dir $flight_ROOT/etc/letsencrypt --logs-dir $flight_ROOT/var/log/letsencrypt --work-dir $flight_ROOT/var/lib/letsencrypt
cron_script: "#!/bin/bash\n$flight_ROOT/bin/flight www cert-gen\n"
https_enable_paths:
  - $flight_ROOT/etc/www/http.d/https.conf
  - $flight_ROOT/etc/www/server-http.d/redirect-http-to-https.conf
status_command: $flight_ROOT/bin/flight service status www | grep active
restart_command: $flight_ROOT/bin/flight service restart www | grep 'service has been restarted'
start_command_prompt: $flight_ROOT/bin/flight service start www
EOF

#TODO: Apply these patches
sed -i 's/File.exists/File.file/g' $flight_ROOT/opt/www/cert/lib/flight_cert/commands/cert_install.rb
sed -i 's/File.exists/File.file/g' $flight_ROOT/opt/www/cert/lib/flight_cert/commands/cron_renewal.rb
sed -i 's/File.exists/File.file/g' $flight_ROOT/opt/www/cert/lib/flight_cert/commands/disable_https.rb
sed -i 's/File.exists/File.file/g' $flight_ROOT/opt/www/cert/lib/flight_cert/commands/enable_https.rb

# Flight Python
if [[ $SKIP_THIRD_PARTY != "y" ]] ; then
    sudo dnf -y install bzip2-devel

    wget -O /tmp/Python-$VERSION_PYTHON.tgz https://www.python.org/ftp/python/${VERSION_PYTHON}/Python-${VERSION_PYTHON}.tgz
    cd /tmp/
    tar xf Python-$VERSION_PYTHON.tgz
    cd Python-$VERSION_PYTHON

    ./configure --enable-shared --prefix=$flight_ROOT/opt/python/ LDFLAGS="-Wl,--rpath=$flight_ROOT/opt/python/lib"
    make -j $(nproc)
    make -j $(nproc) install
fi

# Biff tests to save ~75MB 
#rm -rf $(find $flight_ROOT/opt/python/lib/python*/test $flight_ROOT/opt/python/lib/python*/*/test $flight_ROOT/opt/python/lib/python*/*/tests) #defo broke things running it like this

# Biff static libpython for ~25MB
#rm -rf $(find $flight_ROOT/opt/python/lib/python*/config-*-x86_64-linux-gnu) # this might break things, don't think so but python borked

# TODO: Ensure path is correct before doing links
cd $flight_ROOT/opt/python/bin/
ln -sf python3 python
ln -sf pip3 pip

#for i in python3 python pip3 pip ; do 
#    ln -s $flight_ROOT/opt/python/bin/$i $flight_ROOT/bin/
#done

cat << 'EOF' > $flight_ROOT/bin/pip3
_setup() {
  local a xdg_config
  IFS=: read -a xdg_config <<< "${XDG_CONFIG_HOME:-$HOME/.config}:${XDG_CONFIG_DIRS:-/etc/xdg}"
  for a in "${xdg_config[@]}"; do
    if [ -e "${a}"/flight.rc ]; then
      source "${a}"/flight.rc
      break
    fi
  done
  if [ -d "${flight_ROOT}"/libexec/hooks ]; then
    shopt -s nullglob
    for a in "${flight_ROOT}"/libexec/hooks/*.sh; do
      source "${a}"
    done
    shopt -u nullglob
  fi
}

flight_ROOT=${flight_ROOT:-$(cd $(dirname ${BASH_SOURCE[0]})/.. && pwd)}
_setup
unset _setup

exec ${flight_ROOT}/opt/python/bin/pip3 "$@"
EOF

cat << 'EOF' > $flight_ROOT/bin/python3
_setup() {
  local a xdg_config
  IFS=: read -a xdg_config <<< "${XDG_CONFIG_HOME:-$HOME/.config}:${XDG_CONFIG_DIRS:-/etc/xdg}"
  for a in "${xdg_config[@]}"; do
    if [ -e "${a}"/flight.rc ]; then
      source "${a}"/flight.rc
      break
    fi
  done
  if [ -d "${flight_ROOT}"/libexec/hooks ]; then
    shopt -s nullglob
    for a in "${flight_ROOT}"/libexec/hooks/*.sh; do
      source "${a}"
    done
    shopt -u nullglob
  fi
}

flight_ROOT=${flight_ROOT:-$(cd $(dirname ${BASH_SOURCE[0]})/.. && pwd)}
_setup
unset _setup

exec ${flight_ROOT}/opt/python/bin/python3 "$@"
EOF

cd $flight_ROOT/bin/
ln -sf python3 python
ln -sf pip3 pip

chmod +x $flight_ROOT/bin/python* $flight_ROOT/bin/pip*

# Flight Certbot
PATH="$flight_ROOT/opt/python/bin:$PATH"
mkdir -p $flight_ROOT/opt/certbot
cd $flight_ROOT/opt/certbot

pip3 install pipenv

cat << 'EOF' > $flight_ROOT/opt/certbot/Pipfile
[[source]]
name = "pypi"
url = "https://pypi.org/simple"
verify_ssl = true

[dev-packages]

[packages]
certbot = "*"
certbot-nginx = "*"
EOF

PIPENV_VENV_IN_PROJECT=true
pipenv install
mkdir -p bin
for i in $(ls .venv/bin/) ; do 
    ln -sf ../.venv/bin/$i bin/$i
done

# Flight Landing Page
mkdir -p $flight_ROOT/opt/www/src/
clone_or_update https://github.com/openflighthpc/flight-landing-page $VERSION_LANDING_PAGE /tmp/landing-page 
rsync -au /tmp/landing-page/{bin,Gemfile,landing-page} $flight_ROOT/opt/www/
mkdir -p $flight_ROOT/opt/www/landing-page/branding/{content,layouts}

mkdir -p $flight_ROOT/usr/share/www/downloads/config-packs/

cd $flight_ROOT/opt/www/
$flight_ROOT/bin/bundle config set --local path vendor
$flight_ROOT/bin/bundle config set --local with default
$flight_ROOT/bin/bundle config set --local without development
$flight_ROOT/bin/bundle install

#TODO: Include this with repo
wget -O $flight_ROOT/opt/www/bin/landing-page https://raw.githubusercontent.com/openflighthpc/openflight-omnibus-builder/master/builders/flight-www/opt/flight/opt/www/bin/landing-page
chmod +x $flight_ROOT/opt/www/bin/landing-page
sed -i 's,/opt/flight,$flight_ROOT,g' $flight_ROOT/opt/www/bin/landing-page

#TODO: Apply these patches
cat << 'EOF' > $flight_ROOT/opt/www/landing-page/lib/attributes_to_content.rb
class AttributesToContent < Nanoc::Filter
  identifier :attributes_to_content

  def run(content, item)
    if item.is_a? Hash
      item = item[:item]
    end
    item.attributes.to_h
  end
end
EOF
sed -i 's/metadata_content, \*\*kwargs/metadata_content, kwargs/g' $flight_ROOT/opt/www/landing-page/lib/metadata_to_json.rb
sed -i 's/content, keys:/content, keys/g' $flight_ROOT/opt/www/landing-page/lib/prefix_url.rb

cat << EOF > $flight_ROOT/libexec/commands/landing-page
: '
: NAME: landing-page
: SYNOPSIS: Flight WWW landing page
: VERSION: $VERSION_LANDING_PAGE
: ROOT: true
: '
if [ "\$UID" != 0 ]; then
  exec sudo "\${flight_ROOT}"/bin/flight "\$(basename "\$0")" "\$@"
fi

"\${flight_ROOT}"/opt/www/bin/landing-page "\$@"
EOF

# Flight NodeJS
if [[ $SKIP_THIRD_PARTY != "y" ]] ; then
wget -O /tmp/node-v${VERSION_NODE}.tar.gz https://nodejs.org/dist/v${VERSION_NODE}/node-v${VERSION_NODE}-linux-x64.tar.gz
cd /tmp/
tar xf node-v${VERSION_NODE}.tar.gz
mv node-v${VERSION_NODE}-linux-x64 $flight_ROOT/opt/nodejs/

cat << 'EOF' > $flight_ROOT/bin/node
_setup() {
  local a xdg_config
  IFS=: read -a xdg_config <<< "${XDG_CONFIG_HOME:-$HOME/.config}:${XDG_CONFIG_DIRS:-/etc/xdg}"
  for a in "${xdg_config[@]}"; do
    if [ -e "${a}"/flight.rc ]; then
      source "${a}"/flight.rc
      break
    fi
  done
  if [ -d "${flight_ROOT}"/libexec/hooks ]; then
    shopt -s nullglob
    for a in "${flight_ROOT}"/libexec/hooks/*.sh; do
      source "${a}"
    done
    shopt -u nullglob
  fi
}

flight_ROOT=${flight_ROOT:-$(cd $(dirname ${BASH_SOURCE[0]})/.. && pwd)}
_setup
unset _setup

exec ${flight_ROOT}/opt/nodejs/bin/node "$@"
EOF
chmod +x $flight_ROOT/bin/node

cat << 'EOF' > $flight_ROOT/bin/npm
_setup() {
  local a xdg_config
  IFS=: read -a xdg_config <<< "${XDG_CONFIG_HOME:-$HOME/.config}:${XDG_CONFIG_DIRS:-/etc/xdg}"
  for a in "${xdg_config[@]}"; do
    if [ -e "${a}"/flight.rc ]; then
      source "${a}"/flight.rc
      break
    fi
  done
  if [ -d "${flight_ROOT}"/libexec/hooks ]; then
    shopt -s nullglob
    for a in "${flight_ROOT}"/libexec/hooks/*.sh; do
      source "${a}"
    done
    shopt -u nullglob
  fi
}

flight_ROOT=${flight_ROOT:-$(cd $(dirname ${BASH_SOURCE[0]})/.. && pwd)}
_setup
unset _setup

exec /opt/flight/bin/node /opt/flight/opt/nodejs/bin/npm "$@"
EOF
chmod +x $flight_ROOT/bin/npm
fi

# Flight Yarn 
if [[ $SKIP_THIRD_PARTY != "y" ]] ; then
wget -O /tmp/yarn-v${VERSION_YARN}.tar.gz https://github.com/yarnpkg/yarn/releases/download/v${VERSION_YARN}/yarn-v${VERSION_YARN}.tar.gz
cd /tmp/
tar xf yarn-v${VERSION_YARN}.tar.gz
rsync -au yarn-v${VERSION_YARN}/{bin,lib,package.json,preinstall.js} $flight_ROOT/opt/nodejs/

cat << 'EOF' > $flight_ROOT/bin/yarn
_setup() {
  local a xdg_config
  IFS=: read -a xdg_config <<< "${XDG_CONFIG_HOME:-$HOME/.config}:${XDG_CONFIG_DIRS:-/etc/xdg}"
  for a in "${xdg_config[@]}"; do
    if [ -e "${a}"/flight.rc ]; then
      source "${a}"/flight.rc
      break
    fi
  done
  if [ -d "${flight_ROOT}"/libexec/hooks ]; then
    shopt -s nullglob
    for a in "${flight_ROOT}"/libexec/hooks/*.sh; do
      source "${a}"
    done
    shopt -u nullglob
  fi
}

flight_ROOT=${flight_ROOT:-$(cd $(dirname ${BASH_SOURCE[0]})/.. && pwd)}
_setup
unset _setup

exec ${flight_ROOT}/bin/node \
     ${flight_ROOT}/opt/nodejs/bin/yarn.js "$@"
EOF
chmod +x $flight_ROOT/bin/yarn
fi

# Flight WebApp Components
clone_or_update https://github.com/openflighthpc/flight-webapp-components $VERSION_WEBAPP_COMPONENTS /tmp/flight-webapp-components
cd /tmp/flight-webapp-components

export REACT_APP_LOGIN_API_BASE_URL="/login/api/v0"
export PATH="$flight_ROOT/bin/:$PATH"
yarn install
yarn run build
cd builder
yarn add react-router-dom@6
yarn install
yarn run build
cd ..
bash bin/setup-yarn-link-webapp-components.sh
mkdir -p $flight_ROOT/opt/www/landing-page/default/content/{js,styles}
cp -vf builder/build/static/js/main.js $flight_ROOT/opt/www/landing-page/default/content/js/login.js
cp -vf builder/build/static/css/main.css $flight_ROOT/opt/www/landing-page/default/content/styles/login.css

# Flight Service 
clone_or_update https://github.com/openflighthpc/flight-service $VERSION_SERVICE $flight_ROOT/opt/service

cd $flight_ROOT/opt/service
rm -f Gemfile.lock
sed -i "s|gem 'xdg'.*|gem 'xdg'|g" Gemfile #TODO: Implement fix
echo "gem 'abbrev'" >> Gemfile # TODO: Fix for "warning: abbrev was loaded from the standard library, but will no longer be part of the default gems since Ruby 3.4.0"
#TODO: Bump commander-openflighthpc cos it's locked to old one
$flight_ROOT/bin/bundle config set --local path vendor
$flight_ROOT/bin/bundle config set --local with default
$flight_ROOT/bin/bundle config set --local without development
$flight_ROOT/bin/bundle install

#TODO: Apply these patches
sed -i "s,^require_relative 'patches/unicode-display_width',#require_relative 'patches/unicode-display_width',g" $flight_ROOT/opt/service/lib/service/cli.rb
sed -i "s,^require_relative 'patches/unicode-display_width',#require_relative 'patches/unicode-display_width',g" $flight_ROOT/opt/service/lib/service/command_utils.rb
sed -i "s,^require_relative 'patches/unicode-display_width',#require_relative 'patches/unicode-display_width',g" $flight_ROOT/opt/service/lib/service/table.rb
sed -i 's/File.exists/File.file/g' $flight_ROOT/opt/service/lib/service/command_utils.rb
sed -i 's/File.exists/File.file/g' $flight_ROOT/opt/service/lib/service/commands/configure.rb
sed -i 's/File.exists/File.file/g' $flight_ROOT/opt/service/lib/service/commands/info.rb
sed -i 's/File.exists/File.file/g' $flight_ROOT/opt/service/lib/service/type.rb

cat << EOF > $flight_ROOT/opt/service/etc/config.yml
type_paths:
  - $flight_ROOT/etc/service/types
env_dir: $flight_ROOT/etc/service/env
service_etc_dir: $flight_ROOT/var/lib/service
service_state_dir: $flight_ROOT/var/run/service
service_log_dir: $flight_ROOT/var/log/service
EOF

cat << EOF > $flight_ROOT/libexec/commands/service
: '
: NAME: service
: SYNOPSIS: Manage HPC environment services
: VERSION: $VERSION_SERVICE
: ROOT: true
: '
if [ "\$UID" != 0 ]; then
  exec sudo "\${flight_ROOT}"/bin/flight "\$(basename "\$0")" "\$@"
fi
export FLIGHT_CWD=\$(pwd)
cd \${flight_ROOT}/opt/service
export FLIGHT_PROGRAM_NAME="\${flight_NAME} \$(basename \$0)"
flexec bundle exec bin/service "\$@"
EOF

#
# Tidy up
#
rm -rf /tmp/ruby-build
rm -rf /tmp/flight-starter
rm -rf /opt/flight/pkg
rm -rf /tmp/nginx-${VERSION_NGINX} /tmp/nginx-${VERSION_NGINX}.tar.gz
rm -rf /tmp/Python-${VERSION_PYTHON} /tmp/Python-${VERSION_PYTHON}.tgz
rm -rf /tmp/landing-page
