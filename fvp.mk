################################################################################
# Following variables defines how the NS_USER (Non Secure User - Client
# Application), NS_KERNEL (Non Secure Kernel), S_KERNEL (Secure Kernel) and
# S_USER (Secure User - TA) are compiled
################################################################################
COMPILE_NS_USER   ?= 64
override COMPILE_NS_KERNEL := 64
COMPILE_S_USER    ?= 64
COMPILE_S_KERNEL  ?= 64

OPTEE_OS_PLATFORM = vexpress-fvp

include common.mk

################################################################################
# Variables used for TPM configuration.
################################################################################
BR2_ROOTFS_OVERLAY = $(ROOT)/build/br-ext/board/fvp/overlay
BR2_PACKAGE_FTPM_OPTEE_EXT_SITE ?= $(CURDIR)/br-ext/package/ftpm_optee_ext
BR2_PACKAGE_FTPM_OPTEE_PACKAGE_SITE ?= $(ROOT)/ms-tpm-20-ref

# The fTPM implementation is based on ARM32 architecture whereas the rest of the
# system is built to run on 64-bit mode (COMPILE_S_USER = 64). Therefore set
# BR2_PACKAGE_FTPM_OPTEE_EXT_SDK manually to the arm32 OPTEE toolkit rather than
# relying on OPTEE_OS_TA_DEV_KIT_DIR variable.
BR2_PACKAGE_FTPM_OPTEE_EXT_SDK ?= $(OPTEE_OS_PATH)/out/arm/export-ta_arm32

BR2_PACKAGE_LINUX_FTPM_MOD_EXT_SITE ?= $(CURDIR)/br-ext/package/linux_ftpm_mod_ext
BR2_PACKAGE_LINUX_FTPM_MOD_EXT_PATH ?= $(LINUX_PATH)

################################################################################
# Paths to git projects and various binaries
################################################################################
DEBUG=0
MEASURED_BOOT		?= n
TF_A_PATH		?= $(ROOT)/trusted-firmware-a
ifeq ($(MEASURED_BOOT),y)
# Prefer release mode for TF-A if using Measured Boot, debug may exhaust memory.
TF_A_BUILD		?= release
endif
ifeq ($(DEBUG),1)
TF_A_BUILD		?= debug
else
TF_A_BUILD		?= release
endif
EDK2_PATH		?= $(ROOT)/edk2
EDK2_PLATFORMS_PATH	?= $(ROOT)/edk2-platforms
EDK2_TOOLCHAIN		?= GCC49
EDK2_ARCH		?= AARCH64
ifeq ($(DEBUG),1)
EDK2_BUILD		?= DEBUG
else
EDK2_BUILD		?= RELEASE
endif
EDK2_BIN		?= $(EDK2_PLATFORMS_PATH)/Build/ArmVExpress-FVP-AArch64/$(EDK2_BUILD)_$(EDK2_TOOLCHAIN)/FV/FVP_$(EDK2_ARCH)_EFI.fd
BASE_FVP_PATH		?= $(ROOT)/FVP_Base_RevC-2xAEMv8A
ifeq ($(wildcard $(BASE_FVP_PATH)),)
$(error $(BASE_FVP_PATH) does not exist)
endif
GRUB_PATH		?= $(ROOT)/grub
GRUB_CONFIG_PATH	?= $(BUILD_PATH)/fvp/grub
OUT_PATH		?= $(ROOT)/out
GRUB_BIN		?= $(OUT_PATH)/bootaa64.efi
BOOT_IMG		?= $(OUT_PATH)/boot.img
RAMDISK_MNT_PATH 	?= $(BUILD_PATH)/ramdisk
#FTPM_PATH		?= $(ROOT)/ms-tpm-20-ref/Samples/ARM32-FirmwareTPM/optee_ta

# Build ancillary components to access fTPM if Measured Boot is enabled.
ifeq ($(MEASURED_BOOT),y)
DEFCONFIG_FTPM ?= --br-defconfig build/br-ext/configs/ftpm_optee
DEFCONFIG_TPM_MODULE ?= --br-defconfig build/br-ext/configs/linux_ftpm
DEFCONFIG_TSS ?= --br-defconfig build/br-ext/configs/tss
endif

S_VISOR_PATH   ?= $(ROOT)/s-visor
S_VISOR_BUILD_PATH   ?= $(ROOT)/s-visor/build
S_VISOR_IMAGE  ?= $(S_VISOR_PATH)/build/s_visor.bin
################################################################################
# Targets
################################################################################
all: toolchains arm-tf s-visor boot-img linux edk2
clean: arm-tf-clean boot-img-clean buildroot-clean edk2-clean grub-clean \
    s-visor-clean

include toolchain.mk

################################################################################
# Folders
################################################################################
$(OUT_PATH):
	mkdir -p $@

################################################################################
# TITATNIUM
################################################################################
s-visor: s-visor-clean md5
	cmake -H$(S_VISOR_PATH) -B$(S_VISOR_BUILD_PATH) -G "Ninja"
	ninja -C $(S_VISOR_BUILD_PATH)

s-visor-clean:
	rm -rf $(S_VISOR_BUILD_PATH)

md5:
	cd $(S_VISOR_PATH)/scripts && ./gen_image_md5_per_page.sh
################################################################################
# ARM Trusted Firmware
################################################################################
TF_A_EXPORTS ?= \
	CROSS_COMPILE="$(CCACHE)$(AARCH64_CROSS_COMPILE)"

TF_A_FLAGS ?= \
	BL32=$(S_VISOR_IMAGE) \
	BL33=$(EDK2_BIN) \
	ARM_TSP_RAM_LOCATION=tdram \
	FVP_USE_GIC_DRIVER=FVP_GICV3 \
	PLAT=fvp \
	SPD=opteed

ifneq ($(MEASURED_BOOT),y)
	TF_A_FLAGS += DEBUG=$(DEBUG)
	#TF_A_FLAGs += LOG_LEVEL=50
else
	TF_A_FLAGS += DEBUG=0 \
		      MBEDTLS_DIR=$(ROOT)/mbedtls  \
		      ARM_ROTPK_LOCATION=devel_rsa \
		      GENERATE_COT=1 \
		      MEASURED_BOOT=1 \
		      ROT_KEY=plat/arm/board/common/rotpk/arm_rotprivk_rsa.pem \
		      TPM_HASH_ALG=sha256 \
		      TRUSTED_BOARD_BOOT=1 \
		      EVENT_LOG_LEVEL=20
endif

arm-tf: s-visor
	$(TF_A_EXPORTS) $(MAKE) -C $(TF_A_PATH) $(TF_A_FLAGS) all fip

arm-tf-clean:
	$(TF_A_EXPORTS) $(MAKE) -C $(TF_A_PATH) $(TF_A_FLAGS) clean

################################################################################
# EDK2 / Tianocore
################################################################################
define edk2-env
	export WORKSPACE=$(EDK2_PLATFORMS_PATH)
endef

define edk2-call
	$(EDK2_TOOLCHAIN)_$(EDK2_ARCH)_PREFIX=$(AARCH64_CROSS_COMPILE) \
	build -n `getconf _NPROCESSORS_ONLN` -a $(EDK2_ARCH) \
		-t $(EDK2_TOOLCHAIN) -p Platform/ARM/VExpressPkg/ArmVExpress-FVP-AArch64.dsc -b $(EDK2_BUILD)
endef

edk2: edk2-common

edk2-clean: edk2-clean-common

################################################################################
# Linux kernel
################################################################################
LINUX_DEFCONFIG_COMMON_ARCH := arm64
LINUX_DEFCONFIG_COMMON_FILES := \
		$(LINUX_PATH)/arch/arm64/configs/prototype-config

.PHONY: linux-ftpm-module
linux-ftpm-module: linux
ifeq ($(MEASURED_BOOT),y)
linux-ftpm-module:
	$(MAKE) -C $(LINUX_PATH) $(LINUX_COMMON_FLAGS) M=drivers/char/tpm  \
		modules_install INSTALL_MOD_PATH=$(LINUX_PATH)
endif

linux-defconfig: $(LINUX_PATH)/.config

LINUX_COMMON_FLAGS += ARCH=arm64

linux: linux-common

linux-defconfig-clean: linux-defconfig-clean-common

LINUX_CLEAN_COMMON_FLAGS += ARCH=arm64

linux-clean: linux-clean-common

LINUX_CLEANER_COMMON_FLAGS += ARCH=arm64

linux-cleaner: linux-cleaner-common

################################################################################
# Buildroot
################################################################################

buildroot: linux-ftpm-module

################################################################################
# grub
################################################################################
grub-flags := CC="$(CCACHE)gcc" \
	TARGET_CC="$(AARCH64_CROSS_COMPILE)gcc" \
	TARGET_OBJCOPY="$(AARCH64_CROSS_COMPILE)objcopy" \
	TARGET_NM="$(AARCH64_CROSS_COMPILE)nm" \
	TARGET_RANLIB="$(AARCH64_CROSS_COMPILE)ranlib" \
	TARGET_STRIP="$(AARCH64_CROSS_COMPILE)strip" \
	--disable-werror

GRUB_MODULES += boot chain configfile echo efinet eval ext2 fat font gettext \
		gfxterm gzio help linux loadenv lsefi normal part_gpt \
		part_msdos read regexp search search_fs_file search_fs_uuid \
		search_label terminal terminfo test tftp time

$(GRUB_PATH)/configure: $(GRUB_PATH)/configure.ac
	cd $(GRUB_PATH) && ./autogen.sh

$(GRUB_PATH)/Makefile: $(GRUB_PATH)/configure
	cd $(GRUB_PATH) && ./configure --target=aarch64 --enable-boot-time $(grub-flags)

.PHONY: grub
grub: $(GRUB_PATH)/Makefile | $(OUT_PATH)
	$(MAKE) -C $(GRUB_PATH) && \
	cd $(GRUB_PATH) && ./grub-mkimage \
		--output=$(GRUB_BIN) \
		--config=$(GRUB_CONFIG_PATH)/grub.cfg \
		--format=arm64-efi \
		--directory=grub-core \
		--prefix=/boot/grub \
		$(GRUB_MODULES)

.PHONY: grub-clean
grub-clean:
	@if [ -e $(GRUB_PATH)/Makefile ]; then $(MAKE) -C $(GRUB_PATH) clean; fi
	@rm -f $(GRUB_BIN)
	@rm -f $(GRUB_PATH)/configure

################################################################################
# OP-TEE
################################################################################
OPTEE_OS_COMMON_FLAGS += CFG_ARM_GICV3=y

ifeq ($(MEASURED_BOOT),y)
	OPTEE_OS_COMMON_FLAGS += CFG_DT=y CFG_CORE_TPM_EVENT_LOG=y
endif

optee-os: optee-os-common

optee-os-clean: ftpm-clean optee-os-clean-common


################################################################################
# Boot Image
################################################################################

.PHONY: boot-img
boot-img: linux grub buildroot
	$(eval dev_name := $(shell sudo losetup -Pf --show $(BOOT_IMG)))
	$(eval subdev_name := $(dev_name)p1)
	@if [ -e $(RAMDISK_MNT_PATH) ]; then rm -r $(RAMDISK_MNT_PATH); fi
	mkdir $(RAMDISK_MNT_PATH)
	sudo mount $(subdev_name) $(RAMDISK_MNT_PATH)
	sudo rm -rf $(RAMDISK_MNT_PATH)/*
	sudo cp $(LINUX_PATH)/arch/arm64/boot/Image $(RAMDISK_MNT_PATH)
	sudo cp $(LINUX_PATH)/arch/arm64/boot/dts/arm/fvp-base-revc.dtb $(RAMDISK_MNT_PATH)
	sudo cp $(LINUX_PATH)/arch/arm64/boot/dts/arm/foundation-v8-gicv3-psci.dtb $(RAMDISK_MNT_PATH)
	sudo mkdir -p $(RAMDISK_MNT_PATH)/EFI/BOOT
	sudo cp $(ROOT)/out-br/images/rootfs.cpio.gz $(RAMDISK_MNT_PATH)/initrd.img
	sudo cp $(GRUB_BIN) $(RAMDISK_MNT_PATH)/EFI/BOOT/bootaa64.efi
	sudo cp $(GRUB_CONFIG_PATH)/grub.cfg $(RAMDISK_MNT_PATH)/EFI/BOOT/grub.cfg
	sudo umount $(RAMDISK_MNT_PATH)
	sudo losetup -d $(dev_name)

.PHONY: boot-img-clean
boot-img-clean:
	rm -f $(BOOT_IMG)

################################################################################
# Run targets
################################################################################
# This target enforces updating root fs etc
run: all
	$(MAKE) run-only

run-only:
	@cd $(BASE_FVP_PATH); \
	$(BASE_FVP_PATH)/models/Linux64_GCC-6.4/FVP_Base_RevC-2xAEMv8A \
	-C cluster0.has_arm_v8-5=1 \
	-C cluster0.NUM_CORES=4 \
	-C cluster0.scheduler_mode=2 \
	-C bp.hostbridge.interfaceName="tap0" \
	-C bp.smsc_91c111.enabled=true \
	-C bp.secure_memory=true \
	-C bp.dram_size=8 \
	--data="$(TF_A_PATH)/build/fvp/$(TF_A_BUILD)/bl1.bin"@0x0  \
	--data="$(TF_A_PATH)/build/fvp/$(TF_A_BUILD)/fip.bin"@0x8000000 \
	-C bp.virtioblockdevice.image_path=$(BOOT_IMG) \
	-C bp.virtioblockdevice.quiet=1 

