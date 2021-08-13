FROM scratch
WORKDIR /
ADD focal-server-cloudimg-amd64-root.tar /
# Files we don't want to include in the squashfs image
ADD excludes /excludes
# Fix apt to use local mirror with https
RUN sed -e 's^http://archive\.ubuntu\.com^http://gringotts.chr.is^g' \
        -e 's^http://security\.ubuntu\.com^http://gringotts.chr.is^g' \
        -i /etc/apt/sources.list
RUN env DEBIAN_FRONTEND=noninteractive \
    apt-get update --quiet && \
    apt-get upgrade --assume-yes --quiet && \
    apt-get autoremove --assume-yes --purge --quiet && \
    # eatmydata speeds things up a bit
    apt-get install --assume-yes --quiet eatmydata && \
    # Remove Canonical cruft
    eatmydata -- apt-get remove --purge --assume-yes --quiet \
       snapd lxcfs lxd lxd-client pollinate popularity-contest \
       motd-news-config && \ 
    # Calm grub installer since we're installing in a container
    echo "grub-pc grub-pc/install_devices_empty boolean true" | debconf-set-selections && \
    # Don't install dumpcap setuid root
    echo "wireshark-common wireshark-common/install-setuid boolean false" | debconf-set-selections && \
    # Don't look for a resume image, speeds up booting
    echo "RESUME=none" > /etc/initramfs-tools/conf.d/resume && \
    #
    # cloud-initramfs-rooturl is the magic package that makes this 
    # possible.  Limit packages to only those required to install
    # and troubleshoot as this causes the squashfs image to grow
    # and requires more memory on the VM.  Let cloud-init take care
    # of the rest.
    #
    eatmydata -- apt-get install --assume-yes --quiet \
       -o Dpkg::Options::="--force-confdef" \
       -o Dpkg::Options::="--force-confold" \
       cloud-initramfs-rooturl && \
    # Patch the rooturl script to use /bin/wget instead of wget,
    # so we don't invoke busybox and instead pick up the full wget
    # and gain https support
    # https://git.busybox.net/busybox/tree/docs/nofork_noexec.txt?h=1_24_stable
    #
    eatmydata -- apt-get install --assume-yes --quiet \
       -o Dpkg::Options::="--force-confdef" \
       -o Dpkg::Options::="--force-confold" \
       linux-image-generic \
       zsh squashfs-tools rsync lshw curtin netplan.io \
       dns-root-data ebtables lldpd tshark uidmap \
       ipmitool apparmor jq zfsutils-linux zfs-zed && \
    # Allow grub installer to install when curtin runs
    echo "grub-pc grub-pc/install_devices_empty boolean false" | debconf-set-selections && \
    # Clean up local apt package files
    apt-get autoremove --purge --assume-yes && apt-get clean && \
    # Give every machine a unique id, otherwise we get things like duplicate
    # MAC addresses on virtual interfaces and DHCP client IDs
	rm /etc/machine-id
    
# Make a nice debian package manifest list 
RUN dpkg-query -W -f='${binary:Package}\t${Version}\n' > /squashfs.manifest
# Finally package it all up into a squashfs image
RUN mksquashfs / rootfs.xz -comp xz -wildcards -ef excludes && exit 0
CMD /bin/bash

