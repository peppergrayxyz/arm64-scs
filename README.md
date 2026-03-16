# arm64-scs
gentoo-rootfs to replicate "error occurred during dynamic SCS patching (4)" (https://bugs.gentoo.org/971060)



 build and run arm64-scs rootfs (needs `qemu` and `podman`):
 ```sh
 ./arm64-scs.sh
 ```

expected result:

 ```sh
[    0.000000] Booting Linux on physical CPU 0x0000000000 [0x414fd0c1]
[    0.000000] Linux version 6.19.6-gentoo-dist-hardened (portage@47ce1ba728e1) (clang version 21.1.8+libcxx, LLD 21.1.8) #1 SMP PREEMPT_DYNAMIC

...

[    3.647023] Run /boot/test_amdgpu.sh as init process
[    3.648662]   with arguments:
[    3.648857]     /boot/test_amdgpu.sh
[    3.648938]   with environment:
[    3.649721]     HOME=/
[    3.650519]     TERM=linux
[    6.143556] Modules: module amdgpu: error occurred during dynamic SCS patching (4)
modprobe: ERROR: could not insert 'amdgpu': Exec format error
[    6.491644] reboot: Power down
 ```

logs:
- build: `rootfs/var/tmp/portage/sys-kernel/gentoo-kernel-6.19.6/temp/build.log`
- run: `rootfs.log`