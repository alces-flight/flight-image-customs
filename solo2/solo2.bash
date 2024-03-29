# Version tag
VERSION=2024.1
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

CENTOS_VER=$(rpm --eval '%{centos_ver}')

if [[ $CENTOS_VER == 9 ]] ; then
    dnf config-manager --set-enabled crb
    EXTRA_DNF_PACKAGES="lsof"
else
    dnf config-manager --set-enabled powertools
    EXTRA_DNF_PACKAGES="xorg-x11-apps"
fi 

dnf -y install epel-release

dnf makecache

#Installs

dnf -y install flight-user-suite
if [[ $CENTOS_VER == 9 ]] ; then
    dnf -y install ImageMagick
fi
dnf -y install flight-web-suite
dnf -y install python3-websockify netpbm-progs socat $EXTRA_DNF_PACKAGES

dnf -y install alces-flight-landing-page-branding

dnf -y install flight-plugin-system-systemd-service

sleep 2


#Flight initial config

systemctl enable flight-service
. /etc/profile.d/zz-flight-starter.sh
flight set --global always on
flight start
flight desktop prepare gnome 

systemctl set-default multi-user.target
systemctl isolate multi-user.target

#increase timeout on websuite pkg checks
cat << EOF >> /opt/flight/etc/desktop-restapi.local.yaml
command_timeout: 180
EOF

#patch file-manager-api first connection hang/crash
sed -i 's/^# launch_timeout:.*/launch_timeout: 30/g' /opt/flight/etc/file-manager-api.yaml

#allow generation of root user ssh keys
sed -i 's/flight_SSH_LOWEST_UID=.*/flight_SSH_LOWEST_UID=0/g;s/flight_SSH_SKIP_USERS=.*/flight_SSH_SKIP_USERS="none"/g' /opt/flight/etc/setup-sshkey.rc

#use ed25519 key type now ssh-rsa deprecated (EL9)
if [[ $CENTOS_VER == 9 ]] ; then
    sed -i 's/rsa/ed25519/g' /opt/flight/libexec/flight-starter/setup-sshkey
fi

#desktop bg image
echo "bg_image: /opt/flight/etc/assets/backgrounds/alces-flight.jpg" >> /opt/flight/opt/desktop/etc/config.yml

#desktop-restapi key for EL9
if [[ $CENTOS_VER == 9 ]] ; then
    sed -i 's,^# ssh_private_key_path: .*,ssh_private_key_path: "etc/desktop-restapi/flight_desktop_api_key",g;s,^# ssh_public_key_path: .*,ssh_public_key_path: "etc/desktop-restapi/flight_desktop_api_key.pub",g' /opt/flight/etc/desktop-restapi.yaml
fi

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
dnf -y install flight-gather flight-hunter
flight set --global hunter on 

cat << EOF > /opt/flight/opt/hunter/etc/config.yml
port: 8888
autorun_mode: hunt
include_self: true
content_command: cat /opt/flight/opt/gather/var/data.yml
auth_key: flight-solo
default_label: short
default_start: '01'
skip_used_index: true
retry_interval: '15'
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

cat << 'EOF' > /var/lib/firstrun/scripts/01_flightprofile.bash
if [ -f /opt/flight/cloudinit.in ] ; then
    source /opt/flight/cloudinit.in

    if [ ! -z "${PROFILE_ANSWERS}" ] ; then 
        /opt/flight/bin/flight profile configure --answers "$PROFILE_ANSWERS" --accept-defaults
    fi

    # Prepare Auto Remove
    if [ ! -z "${AUTOREMOVE}" ] ; then
        echo "remove_on_shutdown: true" >> /opt/flight/opt/profile/etc/config.yml
        echo "remove_hunter_entry: true" >> /opt/flight/opt/profile/etc/config.yml
    fi
fi
EOF

cat << 'EOF' > /var/lib/firstrun/scripts/02_flighthunter.bash
IP=`ip route get 1.1.1.1 | awk '{ print $7 }'`
echo "target_host: ${IP}" >> /opt/flight/opt/hunter/etc/config.yml

BROADCAST_ADDRESS=`ip addr |grep ${IP} |awk '{print $4}'`

/opt/flight/bin/flight service enable hunter 

if [ -f /opt/flight/cloudinit.in ]; then
    source /opt/flight/cloudinit.in

    # Prepare Send Command
    if [ ! -z ${SERVER} ] ; then
        SEND_ARG="--server ${SERVER}"
        # Set service to send mode to retry sending to SERVER until successful
        sed -i 's/autorun_mode: hunt/autorun_mode: send/g' /opt/flight/opt/hunter/etc/config.yml
        sed -i "s/target_host: .*/target_host: ${SERVER}/g" /opt/flight/opt/hunter/etc/config.yml
    else
        SEND_ARG="--broadcast --broadcast-address ${BROADCAST_ADDRESS}" 
    fi

    # Prepare Identity
    if [ ! -z ${LABEL} ] ; then
        IDENTITY_ARG="--label ${LABEL}"
        echo "presets:" >> /opt/flight/opt/hunter/etc/config.yml
        echo "  label: ${LABEL}" >> /opt/flight/opt/hunter/etc/config.yml
    elif [ ! -z ${PREFIX} ] ; then
        IDENTITY_ARG="--prefix ${PREFIX}"
        echo "presets:" >> /opt/flight/opt/hunter/etc/config.yml
        echo "  prefix: ${PREFIX}" >> /opt/flight/opt/hunter/etc/config.yml
    fi

    # Prepare Auth Key
    if [ ! -z ${AUTH_KEY} ] ; then
        AUTH_ARG="--auth $AUTH_KEY"
        # Configure server to use key
        sed -i "s/auth_key: flight-solo/auth_key: $AUTH_KEY/g" /opt/flight/opt/hunter/etc/config.yml
    fi

    # Prepare Auto Parse
    if [ ! -z "${AUTOPARSEMATCH}" ] ; then 
        echo "auto_parse: $AUTOPARSEMATCH" >> /opt/flight/opt/hunter/etc/config.yml
    fi

    # Prepare Auto Apply
    if [ ! -z "${AUTOAPPLY}" ] ; then
        echo "auto_apply:" >> /opt/flight/opt/hunter/etc/config.yml
        oIFS="$IFS"
        IFS=','
        for line in $AUTOAPPLY ; do
            line=$(echo $line |sed 's/^ *//g')
            echo "  $line" >> /opt/flight/opt/hunter/etc/config.yml
        done
        IFS="$oIFS"
    fi

    # Set Prefixes
    if [ ! -z "${PREFIX_STARTS}" ] ; then
        echo "prefix_starts:" >> /opt/flight/opt/hunter/etc/config.yml
        oIFS="$IFS"
        IFS=','
        for line in $PREFIX_STARTS ; do
            line=$(echo $line |sed 's/^ *//g')
            echo "  $line" >> /opt/flight/opt/hunter/etc/config.yml
        done
        IFS="$oIFS"
    fi
else
    # Broadcast by default
    echo "  /opt/flight/bin/flight hunter send --broadcast --broadcast-address ${BROADCAST_ADDRESS}"
    /opt/flight/bin/flight hunter send --broadcast --broadcast-address ${BROADCAST_ADDRESS}
fi

# Restart Service
/opt/flight/bin/flight service restart hunter
EOF

cat << 'EOF' > /var/lib/firstrun/scripts/03_pubkeyshare.bash
if [ -f /opt/flight/cloudinit.in ] ; then
    source /opt/flight/cloudinit.in
    if [[ ${SHAREPUBKEY} == "true" ]] ; then
        firewall-cmd --add-port 1234/tcp --zone public
        firewall-cmd --add-port 1234/tcp --zone public --permanent
        cat << 'EOD' > /usr/lib/systemd/system/flight-sharepubkey.service
[Unit]
Description=Share Public SSH Key On Port 1234

[Service]
ExecStart=/usr/bin/socat -U TCP4-LISTEN:1234,reuseaddr,fork FILE:"/root/.ssh/id_alcescluster.pub",rdonly

[Install]
WantedBy=multi-user.target
EOD
        systemctl enable flight-sharepubkey --now
    fi
fi
EOF

cat << 'EOF' > /var/lib/firstrun/scripts/04_getpubkey.bash
if [ -f /opt/flight/cloudinit.in ] ; then
    source /opt/flight/cloudinit.in
    if [ ! -z ${SERVER} ] ; then
        count=120
        until socat -u TCP:$SERVER:1234 STDOUT >> /root/.ssh/authorized_keys ; do
            sleep 1
            count=$((count - 1))
            if [[ $count == 0 ]] ; then
                echo "Failed to receive SSH Public Key from $SERVER"
                break
            fi
        done
    fi
fi
EOF

cat << 'EOF' > /var/lib/firstrun/scripts/00_flightpatches.bash
# Generate new shared secret
date +%s.%N | sha256sum | cut -c 1-40 > /opt/flight/etc/shared-secret.conf
chmod 0400 /opt/flight/etc/shared-secret.conf

# Generate new Console API key
ssh-keygen -b 521 -t ecdsa -f "/opt/flight/etc/console-api/flight_console_api_key" -q -N "" -C "Flight Console API Key"

# Generate new Desktop API key
ssh-keygen -b 4096 -t rsa -f "/opt/flight/etc/desktop-restapi/id_rsa" -q -N "" -C "Flight Desktop RestAPI Key"
ssh-keygen -b 521 -t ed25519 -f "/opt/flight/etc/desktop-restapi/flight_desktop_api_key" -q -N "" -C "Flight Desktop API Key"

# Restart any running services (shouldn't be any, just to be safe)
/opt/flight/bin/flight service stack restart
EOF

dnf -y install flight-profile flight-profile-types flight-profile-api
dnf -y install flight-pdsh
flight set --global profile on

flight profile prepare openflight-slurm-standalone
flight profile prepare openflight-slurm-multinode
#flight profile prepare openflight-kubernetes-multinode
flight profile prepare openflight-jupyter-standalone

cat << EOF >> /opt/flight/opt/profile/etc/config.yml
use_hunter: true
EOF

flight silo type prepare aws
flight silo type prepare openstack
echo "software_dir: ~/apps" >> /opt/flight/opt/silo/etc/config.yml

# Set release name & version in prompt
sed -i 's/flight_STARTER_desc=.*/flight_STARTER_desc="an Alces Flight Solo HPC environment"/g' /opt/flight/etc/flight-starter.*
sed -i 's/flight_STARTER_product=.*/flight_STARTER_product="Flight Solo"/g' /opt/flight/etc/flight-starter.*
sed -i "s/flight_STARTER_release=.*/flight_STARTER_release='$VERSION'/g" /opt/flight/etc/flight-starter.*
sed -i 's,flight_STARTER_help_url=.*,flight_STARTER_help_url="https://openflighthpc.org/latest/docs",g' /opt/flight/etc/flight-starter.*

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

#remove keys generated on rpm install and allow firstrun 00_flightpatches.bash to do it another way
rm -fv /opt/flight/etc/shared-secret.conf
rm -fv /opt/flight/etc/console-api/flight_console_api_key*
rm -fv /opt/flight/etc/desktop-restapi/id_rsa* /opt/flight/etc/desktop-restapi/flight_desktop_api_key* 

#Cleanup
rm /etc/yum.repos.d/solo2.repo
dnf makecache
