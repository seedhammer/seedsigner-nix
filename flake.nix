{
  description = "Builds SeedSigner disk image for Raspberry Pi";

  inputs = {
    nixpkgs.url = "nixpkgs";
    utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, utils }:
    utils.lib.eachDefaultSystem (system:
      let
        arch = builtins.head (builtins.split "-" system);
        localpkgs = import nixpkgs {
          inherit system;
        };
        crosspkgs = import nixpkgs {
          inherit system;
          crossSystem = {
            config = "armv6l-unknown-linux-musleabihf";
            gcc = {
              arch = "armv6k";
              fpu = "vfp";
            };
          };
        };
        timestamp = "2009/01/03T12:15:05";
        loader-lib = "ld-musl-armhf.so.1";
      in
      {
        formatter = localpkgs.nixpkgs-fmt;
        lib = {
          mkkernel =
            let
              pkgs = crosspkgs;
            in
            debug: pkgs.stdenv.mkDerivation {
              name = "Raspberry Pi Linux kernel";

              src = pkgs.fetchFromGitHub {
                owner = "raspberrypi";
                repo = "linux";
                rev = "0afb5e98488aed7017b9bf321b575d0177feb7ed";
                sha256 = "t+xq0HmT163TaE+5/sb2ZkNWDbBoiwbXk3oi6YEYsIA=";
                # Remove files that introduce case sensitivity clashes on darwin.
                postFetch = ''
                  rm $out/include/uapi/linux/netfilter/xt_*.h
                  rm $out/include/uapi/linux/netfilter_ipv4/ipt_*.h
                  rm $out/include/uapi/linux/netfilter_ipv6/ip6t_*.h
                  rm $out/net/netfilter/xt_*.c
                  rm $out/tools/memory-model/litmus-tests/Z6.0+poonce*
                '';
              };

              # For reproducible builds.
              KBUILD_BUILD_TIMESTAMP = timestamp;
              KBUILD_BUILD_USER = "seedsigner";
              KBUILD_BUILD_HOST = "seedsigner.com";

              enableParallelBuilding = true;

              makeFlags = [
                "ARCH=arm"
                "CROSS_COMPILE=${pkgs.stdenv.cc.targetPrefix}"
              ];

              depsBuildBuild = [ pkgs.buildPackages.stdenv.cc ];

              nativeBuildInputs = with pkgs.buildPackages; [
                elf-header
                bison
                flex
                openssl
                bc
                perl
              ];

              patches = [
                ./patches/kernel_missing_includes.patch
              ];

              hardeningDisable = [ "bindnow" "format" "fortify" "stackprotector" "pic" "pie" ];

              postPatch = ''
                patchShebangs scripts/config
              '';

              configurePhase = ''
                export HOSTCC=$CC_FOR_BUILD
                export HOSTCXX=$CXX_FOR_BUILD
                export HOSTAR=$AR_FOR_BUILD
                export HOSTLD=$LD_FOR_BUILD

                make $makeFlags -j$NIX_BUILD_CORES \
                  HOSTCC=$HOSTCC HOSTCXX=$HOSTCXX HOSTAR=$HOSTAR HOSTLD=$HOSTLD \
                  CC=$CC OBJCOPY=$OBJCOPY OBJDUMP=$OBJDUMP READELF=$READELF \
                  HOSTCFLAGS="-D_POSIX_C_SOURCE=200809L" \
                  bcmrpi_defconfig

                # Disable networking (including bluetooth).
                ./scripts/config --disable NET
                # There's no need for security models, and leaving it enabled
                # leads to build errors because of the files removed in postFetch above.
                ./scripts/config --disable SECURITY
                # Disable sound support.
                ./scripts/config --disable SOUND
                # Disable features we don't need.
                ./scripts/config --disable EXT4_FS
                ./scripts/config --disable F2FS_FS
                ./scripts/config --disable PSTORE
                ./scripts/config --disable NLS_CODEPAGE_437
                ./scripts/config --disable INPUT_TOUCHSCREEN
                ./scripts/config --disable RC_MAP
                # Enable v4l2
                ./scripts/config --enable MEDIA_SUPPORT
                ./scripts/config --enable VIDEO_V4L2
                ./scripts/config --enable VIDEO_DEV
                # Enable camera driver.
                ./scripts/config --enable I2C_BCM2835
                ./scripts/config --enable I2C_MUX
                ./scripts/config --enable REGULATOR_FIXED_VOLTAGE
                ./scripts/config --enable I2C_MUX_PINCTRL
                ./scripts/config --enable VIDEO_BCM2835_UNICAM
                ./scripts/config --enable VIDEO_CODEC_BCM2835
                ./scripts/config --enable VIDEO_ISP_BCM2835
                ./scripts/config --enable VIDEO_OV5647
                # Enable SPI.
                ./scripts/config --enable SPI_BCM2835
                # Enable FTDI USB serial driver.
                ./scripts/config --enable USB_SERIAL
                ./scripts/config --enable USB_SERIAL_FTDI_SIO

                # Disable HDMI framebuffer device.
                # ./scripts/config --disable FB_BCM2708

                # Enable display driver.
                ./scripts/config --enable BACKLIGHT_GPIO
                ./scripts/config --enable DRM
                ./scripts/config --enable DRM_PANEL_MIPI_DBI
                ./scripts/config --disable LOGO
                ./scripts/config --enable FRAMEBUFFER_CONSOLE_DEFERRED_TAKEOVER
              '' + (if debug then ''
                ./scripts/config --disable CONFIG_USB_DWCOTG
                ./scripts/config --enable CONFIG_USB_DWC2
                ./scripts/config --enable CONFIG_USB_G_SERIAL
                # For mounting the SD card.
                ./scripts/config --enable NLS_CODEPAGE_437
              '' else "");

              buildPhase = ''
                export HOSTCC=$CC_FOR_BUILD
                export HOSTCXX=$CXX_FOR_BUILD
                export HOSTAR=$AR_FOR_BUILD
                export HOSTLD=$LD_FOR_BUILD

                make $makeFlags -j$NIX_BUILD_CORES \
                  HOSTCC=$HOSTCC HOSTCXX=$HOSTCXX HOSTAR=$HOSTAR HOSTLD=$HOSTLD \
                  CC=$CC OBJCOPY=$OBJCOPY OBJDUMP=$OBJDUMP READELF=$READELF \
                  HOSTCFLAGS="-D_POSIX_C_SOURCE=200809L" \
                  zImage dtbs
              '';

              installPhase = ''
                mkdir -p $out/overlays
                cp arch/arm/boot/zImage $out/kernel.img
                cp arch/arm/boot/dts/*rpi-zero*.dtb $out/
                cp arch/arm/boot/dts/overlays/dwc2.dtbo $out/overlays/
                cp arch/arm/boot/dts/overlays/ov5647.dtbo $out/overlays/
                cp arch/arm/boot/dts/overlays/mipi-dbi-spi.dtbo $out/overlays/
              '';

              allowedReferences = [ ];
            };
          panel-firmware =
            let
              pkgs = localpkgs;
              # firmware is the commands required to initialize the st7789 panel.
              firmware = pkgs.writeText "firmware.txt" ''
                command 0x11 # exit sleep mode
                delay 120

                command 0x3A 0x05 # set pixel format 16-bit
                command 0xB2 0x05 0x05 0x00 0x33 0x33 # PORCTRL
                command 0xB7 0x75 # GCTRL
                command 0xC2 0x01 0x0FF # VDVVRHEN
                command 0xC3 0x13 # VHRS
                command 0xC4 0x20 # VDVS
                command 0xBB 0x22 # VCOMS
                command 0xC5 0x20 # VCMOFSET
                command 0xD0 0xA4 0xA1 # PWRCTRL1

                # gamma
                command 0xE0 0xD0 0x05 0x0A 0x09 0x08 0x05 0x2E 0x44 0x45 0x0F 0x17 0x16 0x2B 0x33
                command 0xE1 0xD0 0x05 0x0A 0x09 0x08 0x05 0x2E 0x43 0x45 0x0F 0x16 0x16 0x2B 0x33

                command 0x29 # display on
                command 0x21 # invert mode

                command 0x36 0x60 # set address mode
              '';
              firmware-converter = pkgs.fetchurl {
                url = "https://raw.githubusercontent.com/notro/panel-mipi-dbi/374b15f78611c619c381c643c5b3a8b5d23f479b/mipi-dbi-cmd";
                hash = "sha256-ZOx6l84IFpyooPFdgumCL2WUBqCKi0G36X6H8QjyNEc=";
              };
            in
            pkgs.stdenvNoCC.mkDerivation {
              name = "panel-firmware";

              dontUnpack = true;

              installPhase = ''
                ${pkgs.python3}/bin/python3 ${firmware-converter} $out ${firmware}
              '';
            };
          mkinitramfs = debug:
            let
              pkgs = localpkgs;
              panel-firmware = self.lib.${system}.panel-firmware;
              python = crosspkgs.pkgsStatic.python3;
            in
            pkgs.stdenvNoCC.mkDerivation {
              name = "initramfs";

              src = ./.;

              buildPhase = ''
                # Create initramfs with main program and libraries.
                mkdir -p initramfs/lib/firmware initramfs/bin initramfs/seedsigner initramfs/python

                # Copy python3.
                cp ${python}/bin/python3 initramfs/bin/
                cp -a ${python}/lib/ initramfs/python

                # Copy python source.
                cp -R src/* initramfs/seedsigner/

                cp -R "${self.packages.${system}.camera-driver}"/* initramfs/
                cp ${panel-firmware} initramfs/lib/firmware/panel.bin
                # Set constant mtimes and permissions for determinism.
                chmod 0755 `find initramfs`
                ${pkgs.coreutils}/bin/touch -d '${timestamp}' `find initramfs`

                ${pkgs.findutils}/bin/find initramfs -mindepth 1 -printf '%P\n'\
                  | sort \
                  | ${pkgs.cpio}/bin/cpio -D initramfs --reproducible -H newc -o --owner +0:+0 --quiet \
                  | ${pkgs.gzip}/bin/gzip > initramfs.cpio.gz
              '';

              installPhase = ''
                mkdir -p $out
                cp initramfs.cpio.gz $out/
              '';

              allowedReferences = [ ];
            };
          mkimage = debug:
            let
              pkgs = localpkgs;
              firmware = self.packages.${system}.firmware;
              kernel =
                if debug then
                  self.packages.${system}.kernel-debug
                else
                  self.packages.${system}.kernel;

              initramfs = self.lib.${system}.mkinitramfs debug;
              img-name = if debug then "seedsigner-debug.img" else "seedsigner.img";
              cmdlinetxt = pkgs.writeText "cmdline.txt" "console=tty1 oops=panic rdinit=/seedsigner/hello.py PYTHONHOME=/python";
              configtxt = pkgs.writeText "config.txt" (''
                initramfs initramfs.cpio.gz followkernel
                disable_splash=1
                boot_delay=0
                force_turbo=1
                camera_auto_detect=1
                dtoverlay=mipi-dbi-spi
                dtparam=width=240
                dtparam=height=240
                dtparam=width-mm=23
                dtparam=height-mm=23
                dtparam=reset-gpio=27
                dtparam=dc-gpio=25
                dtparam=backlight-gpio=24
                dtparam=write-only
                dtparam=speed=40000000
              '' + (if debug then "dtoverlay=dwc2" else ""));
              util-linux = self.packages.${system}.util-linux;
            in
            pkgs.stdenvNoCC.mkDerivation {
              name = "disk-image";

              dontUnpack = true;
              buildPhase = ''
                sectorsToBlocks() {
                  echo $(( ( "$1" * 512 ) / 1024 ))
                }

                sectorsToBytes() {
                  echo $(( "$1" * 512 ))
                }

                # Create disk image.
                dd if=/dev/zero of=disk.img bs=1M count=40
                ${util-linux}/bin/sfdisk disk.img <<EOF
                  label: dos
                  label-id: 0xceedb0ad

                  disk.img1 : type=c, bootable
                EOF

                # Create boot partition.
                START=$(${util-linux}/bin/fdisk -l -o Start disk.img|tail -n 1)
                SECTORS=$(${util-linux}/bin/fdisk -l -o Sectors disk.img|tail -n 1)
                ${pkgs.dosfstools}/bin/mkfs.vfat --invariant -i deadbeef -n boot disk.img --offset $START $(sectorsToBlocks $SECTORS)
                OFFSET=$(sectorsToBytes $START)

                # Copy boot files.
                mkdir -p boot/overlays overlays
                cp ${cmdlinetxt} boot/cmdline.txt
                cp ${configtxt} boot/config.txt
                cp ${firmware}/boot/bootcode.bin ${firmware}/boot/start.elf \
                  ${firmware}/boot/fixup.dat \
                  ${kernel}/kernel.img ${kernel}/*.dtb \
                  ${initramfs}/initramfs.cpio.gz boot/
                cp ${kernel}/overlays/* overlays/

                chmod 0755 `find boot overlays`
                ${pkgs.coreutils}/bin/touch -d '${timestamp}' `find boot overlays`
                ${pkgs.mtools}/bin/mcopy -bpm -i "disk.img@@$OFFSET" boot/* ::
                # mcopy doesn't copy directories deterministically, so rely on sorted shell globbing
                # instead.
                ${pkgs.mtools}/bin/mcopy -bpm -i "disk.img@@$OFFSET" overlays/* ::overlays
              '';

              installPhase = ''
                mkdir -p $out
                cp disk.img $out/${img-name}
              '';

              allowedReferences = [ ];
            };
        };
        packages =
          {
            go-deps = let pkgs = localpkgs; in pkgs.stdenvNoCC.mkDerivation {
              pname = "go-deps";
              version = "1";

              src = builtins.filterSource
                (path: type: baseNameOf path == "go.mod" || baseNameOf path == "go.sum")
                ./.;

              dontBuild = true;

              nativeBuildInputs = with pkgs.buildPackages; [
                cacert
                go_1_20
              ];

              installPhase = ''
                mkdir -p $out
                export HOME="$PWD/gohome"
                GOMODCACHE=$out go mod download
              '';

              outputHashMode = "recursive";
              outputHashAlgo = "sha256";
              outputHash = "ST/4Sx0jItRvT9kgFqxkGMKBJF8f+/vaxb8+OWZHqZU=";
            };
            util-linux =
              let
                pkgs = localpkgs;
                stdenv = pkgs.stdenv;
              in
              stdenv.mkDerivation {
                name = "util-linux";

                src = pkgs.fetchFromGitHub {
                  owner = "util-linux";
                  repo = "util-linux";
                  rev = "v2.39-rc2";
                  sha256 = "lgC5YhoQb1xbvAQ7gLojo0fel/iXpaNTjS6mUkHc+Vk=";
                };

                nativeBuildInputs = with pkgs.buildPackages; [
                  autoconf
                  automake
                  gettext
                  bison
                  libtool
                  pkg-config
                ];

                buildInputs = with pkgs; [
                  ncurses
                ];

                postPatch = pkgs.lib.optionalString stdenv.isDarwin ''
                  substituteInPlace autogen.sh --replace glibtoolize libtoolize
                '';

                configureFlags = [
                  "--disable-asciidoc"
                  "--disable-wall"
                  "--disable-mount"
                ];

                preConfigure = ''
                  ./autogen.sh
                '';
              };
            libcamera =
              let
                pkgs = crosspkgs;
                cpu = pkgs.targetPlatform.parsed.cpu;
                cross-file = pkgs.writeText "cross-file.conf" ''
                  [properties]
                  needs_exe_wrapper = true

                  [host_machine]
                  system = 'linux'
                  cpu_family = '${cpu.family}'
                  cpu = '${cpu.name}'
                  endian = 'little'
                '';
              in
              pkgs.stdenv.mkDerivation rec {
                pname = "libcamera";
                version = "0.0.5";

                src = pkgs.fetchgit {
                  url = "https://git.libcamera.org/libcamera/libcamera.git";
                  rev = "v${version}";
                  hash = "sha256-rd1YIEosg4+H/FJBYCoxdQlV9F0evU5fckHJrSdVPOE";
                };

                patches = [
                  # Disable IPA signature validation: we don't need it and it depends
                  # on openssl which is fiddly to build reproducibly.
                  ./patches/libcamera_disable_signature.patch
                ];

                postPatch = ''
                  patchShebangs utils/
                '';

                dontUseNinjaInstall = true;
                dontUseMesonConfigure = true;

                nativeBuildInputs = with pkgs.pkgsBuildHost; [
                  meson
                  ninja
                  pkg-config
                  python3
                  python3Packages.jinja2
                  python3Packages.pyyaml
                  python3Packages.ply
                ];

                buildInputs = with pkgs.pkgsStatic; [
                  libyaml
                ];

                configurePhase = ''
                  meson setup build \
                    -Dv4l2=false \
                    -Dqcam=disabled \
                    -Dcam=disabled \
                    -Dgstreamer=disabled \
                    -Dtracing=disabled \
                    -Dpipelines=raspberrypi \
                    -Ddocumentation=disabled \
                    -Dlc-compliance=disabled \
                    -Dwerror=false \
                    --cross-file=${cross-file} \
                    --buildtype=plain \
                    --prefix=/ \
                    --libdir=lib
                  cd build
                '';

                ninjaFlags = [ "-v" ];

                installPhase = ''
                  mkdir -p $out/lib/libcamera $out/share/libcamera/ipa/raspberrypi $out/include
                  cp -P ./src/libcamera/base/libcamera-base.so.${version} \
                    ./src/libcamera/base/libcamera-base.so \
                    ./src/libcamera/libcamera.so.${version} \
                    ./src/libcamera/libcamera.so \
                    $out/lib
                  cp ./src/ipa/raspberrypi/ipa_rpi.so $out/lib/libcamera
                  cp ../src/ipa/raspberrypi/data/*.json $out/share/libcamera/ipa/raspberrypi
                  cp -a ../include/libcamera include/libcamera $out/include
                  patchelf --set-rpath "/lib" `find $out/lib -type f`
                '';

                strictDeps = true;
                enableParallelBuilding = true;

                allowedReferences = [ ];
              };
            camera-driver = let pkgs = crosspkgs; in pkgs.stdenv.mkDerivation {
              name = "camera-driver";

              dontUnpack = true;

              nativeBuildInputs = with pkgs.buildPackages; [
                binutils
              ];

              installPhase = ''
                mkdir -p $out/lib/libcamera
                LIBCAM="${self.packages.${system}.libcamera}"
                chmod +w `find $out/`
                prefix=${pkgs.stdenv.targetPlatform.config}
                cclib="${pkgs.stdenv.cc.cc.lib}/$prefix/lib"

                cp "$cclib/libstdc++.so.6" \
                  "$cclib/libgcc_s.so.1" \
                  "$cclib/libatomic.so.1" \
                  $out/lib/
                chmod +w `find $out/`
                patchelf --set-rpath "/lib" `find $out/lib -type f`
                # Copy the dynamic link while stripping it of indeterministic sections.
                "$prefix"-objcopy -R .note.gnu.build-id "${pkgs.stdenv.cc.libc}/lib/${loader-lib}" \
                  $out/lib/${loader-lib}
                cp -R "$LIBCAM/lib/" $out/
                cp -R "$LIBCAM/share/" $out/
              '';

              strictDeps = true;

              allowedReferences = [ ];
            };
            kernel = self.lib.${system}.mkkernel false;
            kernel-debug = self.lib.${system}.mkkernel true;
            firmware = localpkgs.fetchFromGitHub {
              owner = "raspberrypi";
              repo = "firmware";
              rev = "0d6514f32722e4acf091ab2af9715793ffd6b727";
              sparseCheckout = [ "boot" ];
              sha256 = "sha256-lX33EMZas1cdCFb/UZc6yjIWZ/4Rj2/yI07GZjnL7fs=";
            };
            initramfs = self.lib.${system}.mkinitramfs false;
            initramfs-debug = self.lib.${system}.mkinitramfs true;
            image = self.lib.${system}.mkimage false;
            image-debug = self.lib.${system}.mkimage true;
            default = self.packages.${system}.image;
          };
      });
}
