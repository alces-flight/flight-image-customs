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
cat << "EOF" > /etc/cloud/cloud.cfg.d/solo2.cfg
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
