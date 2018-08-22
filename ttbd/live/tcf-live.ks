# TCF Live Image Generator
#
# SPDX-License-Header: GPLv2+
#
# Derived from Fedora's /usr/share/spin-kickstart/fedora-live-base.ks
#
# Generates a basic livecd with the minimal packages, plus what we ask
# for in (included file) tcf-live-packages.ks and with extras from
# tcf-live-extras*.ks.
#
# Will boot straight into the kernel, in text mode, autologin to the
# system console and a serial line in /dev/ttyUSB0.
#
# The system is put to boot, and then the livesys service is started,
# which runs /etc/rc.d/livesys--a script we generate below.
#
# In that script, we:
# - remove root's password
# - allow SSH login
# - disable SELinux
# - mount to /home any virtio with label TCF-home or partion with
#   TCF-home where big data should be written to)
# - swap on to any virtio with label TCF-swap or partion with
#   TCF-swap where big data should be written to)
# - configure networking (using systemd-network):
#   - if a certain MAC we use for virtual machines is set, we
#     configure according to that MAC
#   - if a MAC address in the tables in tcf-live-common-network.ks,
#     then with that.
#
#

lang en_US.UTF-8
keyboard us
timezone US/Eastern
auth --useshadow --passalgo=sha512
# We don't want SELinux, as makes things more complicated
selinux --disabled
# NUCs talk to ttyUSB0, VMs ttyS0
bootloader --timeout=1 --append="no_timer_check console=tty1 console=ttyS0,115200n81 console=ttyUSB0,115200n81"

# No need for firewalls, we'll be on internal networks
firewall --disabled
zerombr
clearpart --all
part / --size 5120 --fstype ext4
services --enabled=serial-getty@ttyUSB0,systemd-networkd,systemd-resolved --disabled=sshd,ModemManager
network --bootproto=dhcp --device=link --activate
shutdown

url --mirrorlist=https://mirrors.fedoraproject.org/metalink?repo=fedora-$releasever&arch=$basearch
repo --name=fedora --mirrorlist=https://mirrors.fedoraproject.org/mirrorlist?repo=fedora-$releasever&arch=$basearch
repo --name=updates --mirrorlist=https://mirrors.fedoraproject.org/mirrorlist?repo=updates-released-f$releasever&arch=$basearch
#repo --name=updates-testing --mirrorlist=http://mirrors.fedoraproject.org/metalink?repo=updates-testing-f$releasever&arch=$basearch
%include tcf-live-repos.ks

# This is generated by the mk-liveimg.sh script and contains
# the list of packages that comes from the tcf-live-*.pkgs files;
# this way we can also import those files in other scripts to do
# verification.
%include tcf-live-packages.ks

%post


#
# This will run in the live system
#
# Setup a script to run upon system boot to configure network
# interfaces for TCF virtual machines
#
# This will be run by the livesys hook in tcf-live.ks which we'll
# create after this
#
cat > /usr/sbin/cfg-vmifs.py <<EOF
#! /usr/bin/python3
#
# If the system sports a network interface created by a TCF virtual
# network setup, then create a systemd-networkd configuration file to
# bring it up with the right address.
#
# TCF VMs always get mac address 02:xx:00:00:00:yy; where xx will be
# the network in hex and yy the index in said network -- which we'll
# feed to IP addresses 192.168.xx.yy/24 and fc00::xx:yy/112 (in dec
# and hex for v4 and v6)
#
import glob

for path in glob.glob("/sys/class/net/*/address"):
    with open(path) as f:
        path_mac = f.read().strip()
        mac = path_mac.split(":")
        if mac[0] == '02' and mac[2] == '00' and mac[3] == '00' \
           and mac[4] == '00':
            network = int(mac[1], 16)
            index = int(mac[5], 16)
            data = dict(
                mac_addr = path_mac.lower(),
                network = network,
                index = index
            )
            with open("/etc/systemd/network/vmif.network", "w") as f:
                f.write("""
[Match]
MACAddress = %(mac_addr)s

[Network]
DHCP = no
Address = 192.168.%(network)d.%(index)d/24
Address = fc00::%(network)02x:%(index)02x/112
""" % data)
EOF
chmod a+x /usr/sbin/cfg-vmifs.py


#
# This will run in the live system
#
# FIXME: it'd be better to get this installed from a package
#
# This will initialize a few things in the live system

cat > /etc/rc.d/init.d/livesys << EOF
#!/bin/bash
#
# live: Init script for live image
#
# chkconfig: 345 00 99
# description: Init script for live image.
### BEGIN INIT INFO
# X-Start-Before: display-manager chronyd
### END INIT INFO

. /etc/init.d/functions


if [ -e /.liveimg-configured ] ; then
   exit 0
fi

if ! strstr "\`cat /proc/cmdline\`" rd.live.image || [ "\$1" != "start" ]; then
    exit 0
fi

livedir="LiveOS"
for arg in \`cat /proc/cmdline\` ; do
  if [ "\${arg##rd.live.dir=}" != "\${arg}" ]; then
    livedir=\${arg##rd.live.dir=}
    return
  fi
  if [ "\${arg##live_dir=}" != "\${arg}" ]; then
    livedir=\${arg##live_dir=}
    return
  fi
done

# enable swaps unless requested otherwise
swaps=\`blkid -t TYPE=swap -o device\`
if ! strstr "\`cat /proc/cmdline\`" noswap && [ -n "\$swaps" ] ; then
  for s in \$swaps ; do
    action "Enabling swap partition \$s" swapon \$s
  done
fi
if ! strstr "\`cat /proc/cmdline\`" noswap && [ -f /run/initramfs/live/\${livedir}/swap.img ] ; then
  action "Enabling swap file" swapon /run/initramfs/live/\${livedir}/swap.img
fi

# Remove root password lock
passwd -d root > /dev/null

# turn off firstboot for livecd boots
systemctl --no-reload disable firstboot-text.service 2> /dev/null || :
systemctl --no-reload disable firstboot-graphical.service 2> /dev/null || :
systemctl stop firstboot-text.service 2> /dev/null || :
systemctl stop firstboot-graphical.service 2> /dev/null || :

# don't use prelink on a running live image
sed -i 's/PRELINKING=yes/PRELINKING=no/' /etc/sysconfig/prelink &>/dev/null || :

# don't start cron/at as they tend to spawn things which are
# disk intensive that are painful on a live image
systemctl --no-reload disable crond.service 2> /dev/null || :
systemctl --no-reload disable atd.service 2> /dev/null || :
systemctl stop crond.service 2> /dev/null || :
systemctl stop atd.service 2> /dev/null || :

# Mark things as configured
touch /.liveimg-configured

# SELinux has to be disabled, makes many thing more difficult for no
# gain in a test system
set -x
echo "Disabling SELinux"
setenforce 0

# This script is going be created later and will create
# systemd-networkd configuration files for virtual network
# interfaces.
echo "Running cfg-vmifs"
/usr/sbin/cfg-vmifs.py
echo "Enabling networkd"
systemctl enable systemd-networkd
echo "Restarting networkd"
systemctl restart systemd-networkd

#
# Mount a RW partition where we can do swap
#
# When configuring a physical device, make a partition with a TCF-swap
# label for it to re-format and use:
#
# parted DEVICE -s mkpart logical ext3 0% 100%
# parted DEVICE -s name 2 TCF-swap
#
# When using a VM, provide a disk of any size with a serial number of
# TCF-swap.

for dev in /dev/disk/by-id/virtio-TCF-swap /dev/disk/by-partlabel/TCF-swap; do
   if [ -b "\$dev" ]; then
       # not here
       echo "\$dev: using to swap" 1>&2
       mkswap \$dev > /dev/null
       swapon \$dev
   fi
done

#
# Mount a RW partition where we can do heavy writing (the overlay
# image is very small)
#
# When configuring a physical device, make a partition with a TCF-home
# label for it to re-format and use:
#
# parted DEVICE -s mklabel gpt
# parted DEVICE -s mkpart logical ext3 0% 100%
# parted DEVICE -s name 1 TCF-home
#
# When using a VM, provide a disk of any size with a serial number of
# TCF-home.

for dev in /dev/disk/by-id/virtio-TCF-home /dev/disk/by-partlabel/TCF-home; do
   if [ -b "\$dev" ]; then
       # not here
       echo "\$dev: using to mount /home" 1>&2
       # This is the fastest fs creating, so use that
       mkfs.btrfs -qf "\$dev"
       mount "\$dev" /home
   fi
done

EOF



#
# This is executed in the system making the image
#
# while running inside the chroorted image space, so we can enable
# configs but not run them

chmod 755 /etc/rc.d/init.d/livesys
/sbin/restorecon /etc/rc.d/init.d/livesys
/sbin/chkconfig --add livesys

# enable tmpfs for /tmp
systemctl enable tmp.mount
systemctl enable serial-getty@ttyUSB0
systemctl enable sshd
systemctl enable systemd-networkd
systemctl enable systemd-resolved
# Configure DNS lookups to go through systemd-resolved
ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf

# make it so that we don't do writing to the overlay for things which
# are just tmpdirs/caches
# note https://bugzilla.redhat.com/show_bug.cgi?id=1135475
cat >> /etc/fstab << EOF
vartmp   /var/tmp    tmpfs   defaults   0  0
EOF

# work around for poor key import UI in PackageKit
rm -f /var/lib/rpm/__db*
releasever=$(rpm -q --qf '%{version}\n' --whatprovides system-release)
basearch=$(uname -i)
rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-fedora-$releasever-$basearch
echo "Packages within this LiveCD"
rpm -qa
set -x
# Note that running rpm recreates the rpm db files which aren't needed or wanted
rm -f /var/lib/rpm/__db*

# go ahead and pre-make the man -k cache (#455968)
/usr/bin/mandb

# make sure there aren't core files lying around
rm -f /core*

# remove random seed, the newly installed instance should make it's own
rm -f /var/lib/systemd/random-seed

# convince readahead not to collect
# FIXME: for systemd

echo 'File created by kickstart. See systemd-update-done.service(8).' \
    | tee /etc/.updated >/var/.updated

# Drop the rescue kernel and initramfs, we don't need them on the live media itself.
# See bug 1317709
rm -f /boot/*-rescue*

# Disable network service here, as doing it in the services line
# fails due to RHBZ #1369794
/sbin/chkconfig network off

# Remove machine-id on pre generated images
rm -f /etc/machine-id
touch /etc/machine-id

# This is generated by the mk-liveimg.sh script and includes
# network configuration, etc
%include tcf-live-extras.ks

# Ensure the consoles are logged in automatically
sed -i 's|bin/agetty|bin/agetty --autologin root|' /usr/lib/systemd/system/getty@.service
sed -i 's|bin/agetty|bin/agetty --autologin root|' /usr/lib/systemd/system/serial-getty@.service

passwd --delete root
# Make sure SSH can login w/o password
echo "PermitRootLogin yes" >> /etc/ssh/sshd_config
echo "PermitEmptyPasswords yes" >> /etc/ssh/sshd_config
echo "TCF test node @ \l" > /etc/issue
echo "export PS1=' \# \$ '" >> /etc/profile

%end


%post --nochroot

# Modify ISOLinux boot configuration
# Have it boot straight to the linux0 image, created by the livecd
# tools and at the same time, disable rhgb, so we don't go graphic
# add this so the kernel is verbose:    -e 's/ quiet//' \
sed -i \
    -e 's/^default vesamenu.*/default linux0/' \
    -e 's/ rhgb//' \
    $LIVE_ROOT/isolinux/isolinux.cfg

cp $INSTALL_ROOT/usr/share/licenses/*-release/* $LIVE_ROOT/

# only works on x86, x86_64
if [ "$(uname -i)" = "i386" -o "$(uname -i)" = "x86_64" ]; then
  if [ ! -d $LIVE_ROOT/LiveOS ]; then mkdir -p $LIVE_ROOT/LiveOS ; fi
  cp /usr/bin/livecd-iso-to-disk $LIVE_ROOT/LiveOS
fi

%end