#!/usr/bin/env bash
set -euo pipefail

#
# test env to replicate "error occurred during dynamic SCS patching (4)"
# https://bugs.gentoo.org/971060"
#

stage3="stage3-arm64-musl-llvm-openrc"
stage3url="https://distfiles.gentoo.org/releases/arm64/autobuilds/current-$stage3"
stage3info="latest-$stage3.txt"

gentoo_commit="9edf18d5b44f8305e6b12b3bf17baf9103545e88"
kernel_version="6.19.6"
kernel_ebuild="https://raw.githubusercontent.com/gentoo/gentoo/$gentoo_commit/sys-kernel/gentoo-kernel/gentoo-kernel-$kernel_version.ebuild"
kernel_manifest="https://raw.githubusercontent.com/gentoo/gentoo/$gentoo_commit/sys-kernel/gentoo-kernel/Manifest"
kernel="vmlinuz-${kernel_version}-gentoo-dist-hardened"

rootfs="rootfs"
init_sh="test_amdgpu.sh"

socket="$rootfs.sock"
mem="1G"
run_log="$rootfs.log"
qemu_cpu="neoverse-n1"
qemu_monitor_socket="${rootfs}_mon.sock"

patches=(
    "https://github.com/peppergrayxyz/linux/commit/e0d0be8a18e6b60392b6661708e1f0779c097b11.patch" # DRM_AMD_DC_HDCP
)

podman_run() {
    podman run -it --arch arm64 -e QEMU_CPU=$qemu_cpu --cgroups=disabled --user root --rootfs "$(pwd)/$rootfs" "$@"
}

#
# setup rootfs
#
if [ ! -f "$rootfs/setup.done" ]; then

    mkdir -p "$rootfs"

    stage3file="$(curl -fsSL $stage3url/$stage3info \
        | awk '/\.tar\.xz([[:space:]]|$)/ {print $1; exit}' \
        | xargs -n1 basename)"

    wget -nc "$stage3url/$stage3file"
    wget -nc "$stage3url/$stage3file.sha256"
    sha256sum --check "$stage3file.sha256"

    tar xvpf "$stage3file" --skip-old-files --xattrs-include='*.*' --numeric-owner --exclude='./dev/*' -C "$rootfs"

    cp --dereference /etc/resolv.conf "$rootfs/etc"

    cat >"$rootfs/etc/portage/package.accept_keywords/gentoo-kernel" <<-EOL
		=sys-kernel/gentoo-kernel-$kernel_version ~*
		=virtual/dist-kernel-$kernel_version ~*
		EOL
    cat >"$rootfs/etc/portage/package.use/gentoo-kernel" <<-EOL
		sys-kernel/gentoo-kernel -debug -initramfs
		EOL
    cat >"$rootfs/etc/portage/package.use/cpu-flags" <<-EOL
		*/* CPU_FLAGS_ARM: edsp neon thumb vfp vfpv3 vfpv4 vfp-d32 aes sha1 sha2 crc32 asimddp v4 v5 v6 v7 v8 thumb2
		EOL
    cat >"$rootfs/etc/portage/package.use/video_cards" <<-EOL
		*/* VIDEO_CARDS: amdgpu radeonsi
		EOL
    cat >>"$rootfs/etc/portage/make.conf" <<-EOL
		ACCEPT_LICENSE="-* @FREE @BINARY-REDISTRIBUTABLE"
		EOL
    
    mkdir -p "$rootfs/var/db/repos/local/"{metadata,profiles}
    echo 'local' > "$rootfs/var/db/repos/local/profiles/repo_name"
    echo '8' > "$rootfs/var/db/repos/local/profiles/eapi"
    
    cat >"$rootfs/var/db/repos/local/metadata/layout.conf" <<-EOL
		masters = gentoo
		auto-sync = false
		profile-formats = portage-2
		thin-manifests = true
		sign-manifests = false
		EOL
    
    mkdir -p "$rootfs/etc/portage/repos.conf"
    cat >"$rootfs/etc/portage/repos.conf/local.conf" <<-EOL
		[local]
		location = /var/db/repos/local
		EOL

    mkdir -p "$rootfs/var/db/repos/local/virtual/dist-kernel"
    mkdir -p "$rootfs/var/db/repos/local/sys-kernel/gentoo-kernel"
    wget -nc -P "$rootfs/var/db/repos/local/sys-kernel/gentoo-kernel" "$kernel_ebuild"
    wget -nc -P "$rootfs/var/db/repos/local/sys-kernel/gentoo-kernel" "$kernel_manifest"

    mkdir -p "$rootfs/var/db/repos/local/profiles/musl-llvm-hardened"
    echo "arm64 musl-llvm-hardened dev" > "$rootfs/var/db/repos/local/profiles/profiles.desc"
    echo '8' > "$rootfs/var/db/repos/local/profiles/musl-llvm-hardened/eapi"
    cat >"$rootfs/var/db/repos/local/profiles/musl-llvm-hardened/parent" <<-EOL
		gentoo:default/linux/arm64/23.0/musl/llvm
		gentoo:features/hardened/arm64
		EOL

    mkdir -p "$rootfs/etc/portage/patches/sys-kernel/gentoo-kernel"
    for patch in "${patches[@]}"; do
        wget -nc -P "$rootfs/etc/portage/patches/sys-kernel/gentoo-kernel" "$patch"
    done

    mkdir -p "$rootfs/etc/kernel/config.d"
    cat >"$rootfs/etc/kernel/config.d/kernel.config" <<-EOL
		CONFIG_VIRTIO=y
		CONFIG_VIRTIO_PCI=y
		CONFIG_FUSE_FS=y
		CONFIG_VIRTIO_FS=y
		
		DRM_AMD_DC_HDCP=y
		EOL

    cat >"$rootfs/setup.sh" <<-EOL
		#!/usr/bin/env bash
		set -euo pipefail
		
		emerge-webrsync
		emerge --sync
		eselect news read
		getuto

		virtual_kernel=\$(printf '%s\n' /var/db/repos/gentoo/virtual/dist-kernel/dist-kernel-*.ebuild | sort -V | tail -n1)
		cp "\$virtual_kernel" "/var/db/repos/local/virtual/dist-kernel/dist-kernel-$kernel_version.ebuild"
		
		eselect profile set local:musl-llvm-hardened

		date > "setup.done"
		exit 0
		EOL

    cat >"$rootfs/build.sh" <<-EOL
		#!/bin/sh
		FEATURES="keepwork" emerge =sys-kernel/gentoo-kernel-$kernel_version
		EOL

    cat >"$rootfs/boot/$init_sh" <<-EOL
		#!/bin/sh
		modprobe amdgpu
		poweroff -f
		EOL
    
    chmod +x "$rootfs/setup.sh" "$rootfs/build.sh" "$rootfs/boot/$init_sh"

    podman_run "./setup.sh"
fi

#
# build the kernel
#
if [ ! -f "$rootfs/boot/$kernel" ]; then
    podman_run "./build.sh"
fi

#
# boot the kernel & run test script
#
[ -f "$rootfs/boot/$kernel" ] || exit 1

/usr/libexec/virtiofsd --socket-path=$socket --shared-dir $rootfs &
virtiofsd_pid=$!

cleanup() {
kill "$virtiofsd_pid" 2>/dev/null || true
}
trap cleanup EXIT

qemu-system-aarch64 \
-machine virt,gic-version=3 \
-cpu $qemu_cpu \
-smp 2 \
-m "$mem" \
-kernel "$rootfs/boot/$kernel" \
-object memory-backend-memfd,id=mem,size=$mem,share=on \
-numa node,memdev=mem \
-chardev socket,id=char0,path="$socket" \
-device vhost-user-fs-pci,chardev=char0,tag=sysroot \
-append "rootfstype=virtiofs root=sysroot rw init=/boot/$init_sh console=ttyAMA0 loglevel=8 earlycon=pl011,0x9000000" \
-chardev stdio,id=char1,logfile="$run_log",signal=off \
-serial chardev:char1 \
-display none \
-monitor unix:"$qemu_monitor_socket",server,nowait \
-nodefaults \
-nographic \
-no-reboot

echo "done."