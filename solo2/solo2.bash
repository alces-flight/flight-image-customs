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

dnf -y install alces-flight-landing-page-branding

dnf -y install flight-plugin-system-systemd-service

dnf -y install flight-profile

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

#prepare the openflight-slurm-standalone spin
flight profile prepare openflight-slurm-standalone

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

#Cleanup
rm /etc/yum.repos.d/solo2.repo
dnf makecache

#mutlinode stuff
dnf -y install https://repo.openflighthpc.org/openflight-dev/centos/8/x86_64/flight-gather-0.0.7-1.el8.x86_64.rpm

dnf -y install https://repo.openflighthpc.org/openflight-dev/centos/8/x86_64/flight-hunter-0.1.2-1.el8.x86_64.rpm

cat << EOF > /opt/flight/opt/hunter/etc/config.yml
port: 8888
autorun_mode: hunt
include_self: true
payload_file: /opt/flight/opt/gather/var/data.yml
EOF

firewall-offline-cmd --add-port 8888/tcp 

cat << "EOF" > /etc/cloud/cloud.cfg.d/99_flightgather.cfg
merge_how:
 - name: list
   settings: [append]
 - name: dict
   settings: [no_replace, recurse_list]
runcmd:
  - /opt/flight/bin/flight gather collect
EOF

cat << "EOF" > /etc/cloud/cloud.cfg.d/96_flighthunt.cfg
merge_how:
 - name: list
   settings: [append]
 - name: dict
   settings: [no_replace, recurse_list]
runcmd:
  - "IP=`ip route get 1.1.1.1 | awk '{ print $7 }'`; echo \"target_host: ${IP}\" >> /opt/flight/opt/hunter/etc/config.yml"
  - if [ -f /opt/flight/cloudinit.in ]; then source /opt/flight/cloudinit.in ; /opt/flight/bin/flight hunter send  --server "${SERVER}" -f /opt/flight/opt/gather/var/data.yml; fi
EOF

flight service enable hunter

dnf -y install https://repo.openflighthpc.org/openflight-dev/centos/8/x86_64/flight-profile-0.1.1-1.el8.x86_64.rpm 
dnf -y install https://repo.openflighthpc.org/openflight-dev/centos/8/x86_64/flight-profile-types-0.1.3-1.noarch.rpm
dnf -y install https://repo.openflighthpc.org/openflight/centos/8/x86_64/flight-pdsh-2.34-5.el8.x86_64.rpm

flight profile prepare openflight-slurm-multinode

cat << EOF >> /opt/flight/opt/profile/etc/config.yml
use_hunter: true
EOF

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

#remove key generated on rpm install and do it another way....
rm -v /opt/flight/etc/shared-secret.conf
cat << "EOF" > /etc/cloud/cloud.cfg.d/95_flightpatches.cfg
merge_how:
 - name: list
   settings: [append]
 - name: dict
   settings: [no_replace, recurse_list]
runcmd:
 - date +%s.%N | sha256sum | cut -c 1-40 > /opt/flight/etc/shared-secret.conf; chmod 0400 /opt/flight/etc/shared-secret.conf; /opt/flight/bin/flight service stack restart
EOF
