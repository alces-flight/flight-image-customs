# Version tag
VERSION=2023.3
DATE="$(date +'%Y-%m-%d_%H-%M-%S')"
BUILDVERSION="flightsolo-${VERSION}_${DATE}"
echo $BUILDVERSION > /etc/solo-release

#Repo
cat << "EOF" > /etc/yum.repos.d/solo2.repo
[openflight]
name=OpenFlight - Base
baseurl=https://repo.openflighthpc.org/openflight/centos/$releasever/$basearch/
enabled=1
gpgcheck=0

[alcesflight]
name=AlcesFlight - Base
baseurl=https://alces-flight.s3-eu-west-1.amazonaws.com/repos/alces-flight/centos/$releasever/$basearch/
enabled=1
gpgcheck=0
EOF

dnf config-manager --set-enabled powertools
dnf -y install epel-release

dnf makecache

#Installs

dnf -y install flight-user-suite
dnf -y install flight-web-suite
dnf -y install python3-websockify xorg-x11-apps netpbm-progs

dnf -y install https://alces-flight.s3.eu-west-1.amazonaws.com/repos/alces-flight-dev/centos/8/x86_64/alces-flight-landing-page-branding-1.7.1-1.el8.x86_64.rpm

dnf -y install flight-plugin-system-systemd-service

sleep 2


#Flight initial config

systemctl enable flight-service
. /etc/profile.d/zz-flight-starter.sh
flight set --global always on
flight start
flight desktop prepare gnome 

#increase timeout on websuite pkg checks
cat << EOF >> /opt/flight/etc/desktop-restapi.local.yaml
command_timeout: 180
EOF

#allow generation of root user ssh keys
sed -i 's/flight_SSH_LOWEST_UID=.*/flight_SSH_LOWEST_UID=0/g;s/flight_SSH_SKIP_USERS=.*/flight_SSH_SKIP_USERS="none"/g' /opt/flight/etc/setup-sshkey.rc

echo "bg_image: /opt/flight/etc/assets/backgrounds/alces-flight.jpg" >> /opt/flight/opt/desktop/etc/config.yml

#cloudinit overrides
cat << "EOF" > /etc/cloud/cloud.cfg.d/50_solo2.cfg
system_info:
  default_user:
    name: flight
EOF

#firewall
firewall-offline-cmd --add-port 5900-6000/tcp 
firewall-offline-cmd --add-service https
firewall-offline-cmd --add-service http

#mutlinode stuff
dnf -y install https://repo.openflighthpc.org/openflight-dev/centos/8/x86_64/flight-gather-0.0.8-1.el8.x86_64.rpm

dnf -y install https://repo.openflighthpc.org/openflight-dev/centos/8/x86_64/flight-hunter-0.3.1-1.el8.x86_64.rpm

cat << EOF > /opt/flight/opt/hunter/etc/config.yml
port: 8888
autorun_mode: hunt
include_self: true
content_command: cat /opt/flight/opt/gather/var/data.yml
auth_key: flight-solo
EOF

firewall-offline-cmd --add-port 8888/tcp 
firewall-offline-cmd --add-port 8888/udp 

#
# First Run
#

# Setup firstrun

mkdir -p /var/lib/firstrun/{bin,scripts}
mkdir -p /var/log/firstrun/

cat << 'EOF' > /var/lib/firstrun/bin/firstrun
#!/bin/bash
function fr {
  echo "-------------------------------------------------------------------------------"
  echo "First Run - Copyright (c) 2023-present Alces Flight Ltd"
  echo "-------------------------------------------------------------------------------"
  echo "Running Firstrun scripts.."
  if [ -f /var/lib/firstrun/RUN ]; then
    for script in `find /var/lib/firstrun/scripts -type f -iname *.bash |sort -h`; do
      echo "Running $script.." >> /root/firstrun.log 2>&1
      /bin/bash $script >> /root/firstrun.log 2>&1
    done
    rm -f /var/lib/firstrun/RUN
  fi
  echo "Done!"
  echo "-------------------------------------------------------------------------------"
}
trap fr EXIT
EOF

cat << EOF > /var/lib/firstrun/bin/firstrun-stop
#!/bin/bash
/bin/systemctl disable firstrun.service
if [ -f /firstrun.reboot ]; then
  echo -n "Reboot flag set.. Rebooting.."
  rm -f /firstrun.rebooot
  shutdown -r now
fi
EOF

cat << EOF >> /etc/systemd/system/firstrun.service
[Unit]
Description=FirstRun service
After=network-online.target remote-fs.target
Before=display-manager.service getty@tty1.service
[Service]
ExecStart=/bin/bash /var/lib/firstrun/bin/firstrun
Type=oneshot
ExecStartPost=/bin/bash /var/lib/firstrun/bin/firstrun-stop
SysVStartPriority=99
TimeoutSec=0
RemainAfterExit=yes
Environment=HOME=/root
Environment=USER=root
[Install]
WantedBy=multi-user.target
EOF

chmod 664 /etc/systemd/system/firstrun.service
systemctl daemon-reload
systemctl enable firstrun.service
touch /var/lib/firstrun/RUN

# Add firstrun scripts

cat << 'EOF' > /var/lib/firstrun/scripts/00_flightprepare.bash
/opt/flight/libexec/flight-starter/setup-sshkey
EOF

cat << 'EOF' > /var/lib/firstrun/scripts/01_flightgather.bash
/opt/flight/bin/flight gather collect
EOF

cat << 'EOF' > /var/lib/firstrun/scripts/02_flighthunter.bash
IP=`ip route get 1.1.1.1 | awk '{ print $7 }'`
echo "target_host: ${IP}" >> /opt/flight/opt/hunter/etc/config.yml

BROADCAST_ADDRESS=`ip addr |grep ${IP} |awk '{print $4}'`

/opt/flight/bin/flight service enable hunter 
/opt/flight/bin/flight service restart hunter 

if [ -f /opt/flight/cloudinit.in ]; then
    source /opt/flight/cloudinit.in

    # Prepare Send Command
    if [ ! -z ${SERVER} ] ; then
        SEND_ARG="--server ${SERVER}"
    else
        SEND_ARG="--broadcast --broadcast-address ${BROADCAST_ADDRESS}" 
    fi
    
    # Prepare Identity
    if [ ! -z ${LABEL} ] ; then
        IDENTITY_ARG="--label ${LABEL}"
    elif [ ! -z ${PREFIX} ] ; then
        IDENTITY_ARG="--prefix ${PREFIX}"
    fi

    # Prepare Auth Key
    if [ ! -z ${AUTH_KEY} ] ; then
        AUTH_ARG="--auth $AUTH_KEY"
        # Configure server to use key
        sed -i "s/auth_key: flight-solo/auth_key: $AUTH_KEY/g" /opt/flight/opt/hunter/etc/config.yml
        /opt/flight/bin/flight service restart hunter 
    fi

    echo "  /opt/flight/bin/flight hunter send $SEND_ARG $AUTH_ARG $IDENTITY_ARG -c 'cat /opt/flight/opt/gather/var/data.yml'"
    /opt/flight/bin/flight hunter send $SEND_ARG $AUTH_ARG $IDENTITY_ARG -c 'cat /opt/flight/opt/gather/var/data.yml'
else
    # Broadcast by default
    echo "  /opt/flight/bin/flight hunter send --broadcast --broadcast-address ${BROADCAST_ADDRESS} -c 'cat /opt/flight/opt/gather/var/data.yml'"
    /opt/flight/bin/flight hunter send --broadcast --broadcast-address ${BROADCAST_ADDRESS} -c 'cat /opt/flight/opt/gather/var/data.yml'
fi
EOF

cat << 'EOF' > /var/lib/firstrun/scripts/99_flightpatches.bash
date +%s.%N | sha256sum | cut -c 1-40 > /opt/flight/etc/shared-secret.conf
chmod 0400 /opt/flight/etc/shared-secret.conf
/opt/flight/bin/flight service stack restart
EOF

dnf -y install https://repo.openflighthpc.org/openflight-dev/centos/8/x86_64/flight-profile-0.1.3-3.el8.x86_64.rpm 
dnf -y install https://repo.openflighthpc.org/openflight-dev/centos/8/x86_64/flight-profile-types-0.1.7-1.noarch.rpm
dnf -y install https://repo.openflighthpc.org/openflight/centos/8/x86_64/flight-pdsh-2.34-5.el8.x86_64.rpm
dnf -y install https://repo.openflighthpc.org/openflight-dev/centos/8/x86_64/flight-silo-0.0.0-2.el8.x86_64.rpm

flight profile prepare openflight-slurm-standalone
flight profile prepare openflight-slurm-multinode
flight profile prepare openflight-kubernetes-multinode
flight profile prepare openflight-jupyter-standalone

cat << EOF >> /opt/flight/opt/profile/etc/config.yml
use_hunter: true
EOF

flight silo type prepare aws

# Set release name & version in prompt
sed -i 's/flight_STARTER_desc=.*/flight_STARTER_desc="an Alces Flight Solo HPC environment"/g' /opt/flight/etc/flight-starter.*
sed -i 's/flight_STARTER_product=.*/flight_STARTER_product="Flight Solo"/g' /opt/flight/etc/flight-starter.*
sed -i "s/flight_STARTER_release=.*/flight_STARTER_release='$VERSION'/g" /opt/flight/etc/flight-starter.*

cat << 'EOF' > /usr/lib/systemd/system/flight-service.service
# =============================================================================
# Copyright (C) 2020-present Alces Flight Ltd.
#
# This file is part of Flight Service.
#
# This program and the accompanying materials are made available under
# the terms of the Eclipse Public License 2.0 which is available at
# <https://www.eclipse.org/legal/epl-2.0>, or alternative license
# terms made available by Alces Flight Ltd - please direct inquiries
# about licensing to licensing@alces-flight.com.
#
# Flight Service is distributed in the hope that it will be useful, but
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, EITHER EXPRESS OR
# IMPLIED INCLUDING, WITHOUT LIMITATION, ANY WARRANTIES OR CONDITIONS
# OF TITLE, NON-INFRINGEMENT, MERCHANTABILITY OR FITNESS FOR A
# PARTICULAR PURPOSE. See the Eclipse Public License 2.0 for more
# details.
#
# You should have received a copy of the Eclipse Public License 2.0
# along with Flight Service. If not, see:
#
#  https://opensource.org/licenses/EPL-2.0
#
# For more information on Flight Service, please visit:
# https://github.com/openflighthpc/flight-service
# ==============================================================================
[Unit]
Description=OpenFlightHPC services
After=syslog.target
After=network-online.target
After=cloud-final.service

[Service]
# Workaround for https://bugs.ruby-lang.org/issues/12695
Environment="HOME=/"
Type=oneshot
SyslogIdentifier=flight-service
RemainAfterExit=true
StandardOutput=journal

ExecStart=/opt/flight/bin/flight service stack start
ExecReload=/opt/flight/bin/flight service stack reload
ExecStop=/opt/flight/bin/flight service stack stop

[Install]
WantedBy=multi-user.target
WantedBy=cloud-init.target
EOF

systemctl daemon-reload

#remove key generated on rpm install and allow firstrun 99_flightpatches.bash to do it another way
rm -v /opt/flight/etc/shared-secret.conf

#Cleanup
rm /etc/yum.repos.d/solo2.repo
dnf makecache
