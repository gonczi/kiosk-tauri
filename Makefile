.PHONY: all clean clean-all download-alpine initramfs uki uki-sb sb-keygen disk disk-sb vmdk repack run tauri-build tauri-build-env

# Configuration
ALPINE_VERSION := 3.21
ALPINE_ARCH := x86_64
ALPINE_MIRROR := https://dl-cdn.alpinelinux.org/alpine

# Directories
BUILD_DIR := build
TOOLS_DIR := $(BUILD_DIR)/tools
ALPINE_DIR := $(BUILD_DIR)/alpine
TAURI_BUILD_ROOT := $(BUILD_DIR)/alpine-build
INITRAMFS_DIR := $(BUILD_DIR)/initramfs
TAURI_APP_DIR := tauri-welcome
TAURI_BIN := $(TAURI_APP_DIR)/src-tauri/target/release/tauri_welcome

# Output files
KERNEL_IMAGE := $(BUILD_DIR)/vmlinuz-lts
ALPINE_INITRAMFS := $(BUILD_DIR)/initramfs-alpine
INITRAMFS_CPIO := $(BUILD_DIR)/initramfs.cpio.gz
UKI_IMAGE := $(BUILD_DIR)/linux.efi
DISK_IMAGE := bootable-usb.img
DISK_IMAGE_SB := bootable-usb-sb.img
VMDK_IMAGE := bootable-usb.vmdk
DISK_MIN_SIZE_MB := 256
DISK_PADDING_MB := 128

# Tools
UKIFY := ukify
SBSIGN := sbsign
SBVERIFY := sbverify
ALPINE_MAKE_ROOTFS_VERSION := v0.8.1
ALPINE_MAKE_ROOTFS := $(TOOLS_DIR)/alpine-make-rootfs
TAURI_BUILD_DEPS_STAMP := $(TAURI_BUILD_ROOT)/.deps-ready
TAURI_BUILD_DEPS := \
	build-base \
	rustup \
	nodejs npm \
	pkgconf \
	gtk+3.0-dev webkit2gtk-4.1-dev \
	glib-dev libsoup3-dev

# Packages installed into the rootfs; dependencies are resolved automatically by apk.
# Kept intentionally minimal, but includes a Tauri-capable Wayland/WebKitGTK runtime.
# NOTE: WebKitGTK requires OpenGL/EGL (Mesa). Mesa/Gallium requires LLVM for shader compilation.
# This stack (WebKit+Mesa+LLVM) accounts for ~400 MB of the initramfs and cannot be removed
# without breaking the webview functionality.
ROOTFS_PACKAGES := \
	linux-lts \
	openssh openssh-server-common openssh-sftp-server \
	dbus \
	gtk+3.0 webkit2gtk-4.1 \
	wayland libxkbcommon xkeyboard-config \
	mesa-egl mesa-gl mesa-dri-gallium libdrm \
	eudev \
	seatd cage \
	adwaita-icon-theme \
	ttf-dejavu \
	curl \
	openssl

all: disk



# Download Alpine Linux rootfs and kernel
$(KERNEL_IMAGE): 
	@echo "Preparing alpine-make-rootfs $(ALPINE_MAKE_ROOTFS_VERSION)..."
	mkdir -p $(BUILD_DIR) $(TOOLS_DIR)
	@if [ ! -x $(ALPINE_MAKE_ROOTFS) ]; then \
		wget -q -O $(ALPINE_MAKE_ROOTFS) https://raw.githubusercontent.com/alpinelinux/alpine-make-rootfs/$(ALPINE_MAKE_ROOTFS_VERSION)/alpine-make-rootfs && \
		chmod +x $(ALPINE_MAKE_ROOTFS); \
	fi

	@echo "Building Alpine rootfs with apk dependency resolution..."
	@SUDO=""; \
	if [ "$$(id -u)" -ne 0 ]; then SUDO="sudo"; fi; \
	$$SUDO rm -rf $(ALPINE_DIR)
	@SUDO=""; \
	if [ "$$(id -u)" -ne 0 ]; then SUDO="sudo"; fi; \
	APK_OPTS="--no-progress --arch $(ALPINE_ARCH)" \
		$$SUDO $(ALPINE_MAKE_ROOTFS) \
		--branch v$(ALPINE_VERSION) \
		--mirror-uri $(ALPINE_MIRROR) \
		--packages "$(ROOTFS_PACKAGES)" \
		$(ALPINE_DIR)

	@echo "Copying kernel to build directory..."
	cp $(ALPINE_DIR)/boot/vmlinuz-lts $(KERNEL_IMAGE)
	@echo "Kernel ready at $(KERNEL_IMAGE)"

download-alpine: $(KERNEL_IMAGE)

# Build Tauri app binary for embedding into initramfs
tauri-build: $(TAURI_BIN)
tauri-build-env: $(TAURI_BUILD_DEPS_STAMP)
NPM := $(shell which npm 2>/dev/null || find /usr/local/bin /usr/bin /home -name npm -type f 2>/dev/null | head -1)
CARGO := $(shell which cargo 2>/dev/null || echo $(HOME)/.cargo/bin/cargo)

# Secure Boot signing material (local custom DB key/cert).
SB_DIR := $(BUILD_DIR)/keys
SB_KEY := $(SB_DIR)/db.key
SB_CERT := $(SB_DIR)/db.crt
SB_CERT_DER := $(SB_DIR)/db.cer
UKI_SIGNED_IMAGE := $(BUILD_DIR)/linux-sb.efi

# --- Stage 1: chroot environment setup ---
# Clones Alpine, installs build deps, bootstraps rustup.
# Only re-runs if build/alpine changes or the stamp is missing.
$(TAURI_BUILD_DEPS_STAMP): $(KERNEL_IMAGE)
	@set -e; \
	SUDO=""; \
	if [ "$$(id -u)" -ne 0 ]; then SUDO="sudo"; fi; \
	if [ ! -d "$(ALPINE_DIR)" ]; then \
		echo "ERROR: $(ALPINE_DIR) is missing. Run 'make download-alpine' first."; \
		exit 1; \
	fi; \
	$$SUDO rm -rf "$(abspath $(TAURI_BUILD_ROOT))"; \
	$$SUDO mkdir -p "$(abspath $(TAURI_BUILD_ROOT))"; \
	$$SUDO cp -a "$(abspath $(ALPINE_DIR))/." "$(abspath $(TAURI_BUILD_ROOT))/"; \
	$$SUDO mkdir -p "$(abspath $(TAURI_BUILD_ROOT))/etc"; \
	if [ -f /etc/resolv.conf ]; then \
		$$SUDO cp -L /etc/resolv.conf "$(abspath $(TAURI_BUILD_ROOT))/etc/resolv.conf"; \
	fi; \
	MOUNTED_PROC=0; MOUNTED_DEV=0; \
	cleanup() { \
		[ "$$MOUNTED_DEV"  = "1" ] && $$SUDO umount "$(abspath $(TAURI_BUILD_ROOT))/dev"  || true; \
		[ "$$MOUNTED_PROC" = "1" ] && $$SUDO umount "$(abspath $(TAURI_BUILD_ROOT))/proc" || true; \
	}; \
	trap cleanup EXIT; \
	$$SUDO mkdir -p "$(abspath $(TAURI_BUILD_ROOT))/dev"; \
	if ! $$SUDO mountpoint -q "$(abspath $(TAURI_BUILD_ROOT))/dev"; then \
		$$SUDO mount --bind /dev "$(abspath $(TAURI_BUILD_ROOT))/dev"; MOUNTED_DEV=1; \
	fi; \
	$$SUDO mkdir -p "$(abspath $(TAURI_BUILD_ROOT))/proc"; \
	if ! $$SUDO mountpoint -q "$(abspath $(TAURI_BUILD_ROOT))/proc"; then \
		$$SUDO mount -t proc proc "$(abspath $(TAURI_BUILD_ROOT))/proc"; MOUNTED_PROC=1; \
	fi; \
	$$SUDO chroot "$(abspath $(TAURI_BUILD_ROOT))" /bin/sh -lc 'set -e; \
		echo "Setting up Tauri build environment..."; \
		for attempt in 1 2 3; do \
			apk update && apk add --no-cache $(TAURI_BUILD_DEPS) && break; \
			echo "apk add failed (attempt $$attempt/3), retrying..."; sleep 2; \
			[ $$attempt -eq 3 ] && exit 1; \
		done; \
		export HOME=/root RUSTUP_HOME=/root/.rustup CARGO_HOME=/root/.cargo; \
		export PATH=/root/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; \
		test -x /usr/bin/rustup-init; \
		if [ ! -x /root/.cargo/bin/rustc ]; then \
			echo "Bootstrapping Rust toolchain via rustup..."; \
			/usr/bin/rustup-init -y --profile minimal --default-toolchain stable; \
		fi; \
		/root/.cargo/bin/rustc -vV; \
		echo "Tauri build environment ready."' || exit $$?; \
	$$SUDO touch "$(abspath $(TAURI_BUILD_ROOT))/.deps-ready"

# --- Stage 2: build ---
# Reuses the existing chroot; only re-runs when source files change.
$(TAURI_BIN): $(TAURI_BUILD_DEPS_STAMP)
	@echo "Building Tauri app in Alpine chroot (musl)..."
	@set -e; \
	SUDO=""; \
	if [ "$$(id -u)" -ne 0 ]; then SUDO="sudo"; fi; \
	MOUNTED_PROC=0; MOUNTED_DEV=0; \
	cleanup() { \
		[ "$$MOUNTED_DEV"  = "1" ] && $$SUDO umount "$(abspath $(TAURI_BUILD_ROOT))/dev"  || true; \
		[ "$$MOUNTED_PROC" = "1" ] && $$SUDO umount "$(abspath $(TAURI_BUILD_ROOT))/proc" || true; \
	}; \
	trap cleanup EXIT; \
	$$SUDO mkdir -p "$(abspath $(TAURI_BUILD_ROOT))/dev"; \
	if ! $$SUDO mountpoint -q "$(abspath $(TAURI_BUILD_ROOT))/dev"; then \
		$$SUDO mount --bind /dev "$(abspath $(TAURI_BUILD_ROOT))/dev"; MOUNTED_DEV=1; \
	fi; \
	$$SUDO mkdir -p "$(abspath $(TAURI_BUILD_ROOT))/proc"; \
	if ! $$SUDO mountpoint -q "$(abspath $(TAURI_BUILD_ROOT))/proc"; then \
		$$SUDO mount -t proc proc "$(abspath $(TAURI_BUILD_ROOT))/proc"; MOUNTED_PROC=1; \
	fi; \
	$$SUDO mkdir -p "$(abspath $(TAURI_BUILD_ROOT))/work/tauri-welcome"; \
	cd $(TAURI_APP_DIR) && tar cf - \
		--exclude='node_modules' \
		--exclude='dist' \
		--exclude='src-tauri/target' \
		. | $$SUDO tar xf - -C "$(abspath $(TAURI_BUILD_ROOT))/work/tauri-welcome"; \
	$$SUDO chroot "$(abspath $(TAURI_BUILD_ROOT))" /bin/sh -lc 'set -e; \
		unset RUSTC RUSTC_WRAPPER RUSTFLAGS CARGO_HOME RUSTUP_HOME; \
		unset CARGO_BUILD_RUSTC CARGO_BUILD_RUSTC_WRAPPER CARGO_ENCODED_RUSTFLAGS CARGO_TARGET_DIR; \
		cd /work/tauri-welcome; \
		npm run build; \
		cd src-tauri; \
		env -i \
			HOME=/root \
			USER=root \
			LOGNAME=root \
			SHELL=/bin/sh \
			RUSTUP_HOME=/root/.rustup \
			CARGO_HOME=/root/.cargo \
			PATH=/root/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
			RUSTFLAGS=-C\ target-feature=-crt-static \
			RUSTC=/root/.cargo/bin/rustc \
			/root/.cargo/bin/cargo build --release' || exit $$?; \
	$$SUDO chroot "$(abspath $(TAURI_BUILD_ROOT))" /bin/sh -lc 'set -e; \
		INTERP=$$(readelf -l /work/tauri-welcome/src-tauri/target/release/tauri_welcome 2>/dev/null | sed -n "s/.*Requesting program interpreter: \(.*\)]/\1/p"); \
		if [ "$$INTERP" != "/lib/ld-musl-x86_64.so.1" ]; then \
			echo "ERROR: tauri_welcome is not musl-linked (interp=$$INTERP)"; \
			exit 1; \
		fi; \
		echo "OK: binary is musl-linked (interp=$$INTERP)"' || exit $$?; \
	$$SUDO mkdir -p "$$(dirname "$(abspath $(TAURI_BIN))")"; \
	$$SUDO cp "$(abspath $(TAURI_BUILD_ROOT))/work/tauri-welcome/src-tauri/target/release/tauri_welcome" "$(abspath $(TAURI_BIN))"

# Create initramfs
$(INITRAMFS_CPIO): $(KERNEL_IMAGE) tauri-build init
	@echo "Creating initramfs from Alpine Linux..."
	rm -rf $(INITRAMFS_DIR)
	mkdir -p $(INITRAMFS_DIR)
	
	# Copy Alpine rootfs
	@echo "Copying Alpine rootfs..."
	@SUDO=""; \
	if [ "$$(id -u)" -ne 0 ]; then SUDO="sudo"; fi; \
	cd $(ALPINE_DIR) && \
		$$SUDO tar cf - --exclude='*.apk' --exclude='alpine-minirootfs-*.tar.gz' \
		--exclude='lib/firmware' --exclude='lib/firmware/*' \
		bin sbin lib lib64 usr etc 2>/dev/null | tar xf - -C ../../$(INITRAMFS_DIR)/
	@test -f $(INITRAMFS_DIR)/etc/shadow || (echo "ERROR: $(INITRAMFS_DIR)/etc/shadow is missing (root auth will fail). Rebuild with proper sudo access." && exit 1)
	@test -d $(INITRAMFS_DIR)/usr/share/icons/Adwaita/cursors || (echo "ERROR: Missing Adwaita cursor theme in initramfs (stale Alpine rootfs cache)." && echo "ERROR: Run: sudo rm -rf $(ALPINE_DIR) $(KERNEL_IMAGE) && sudo make repack" && exit 1)
	
	# Create directory structure
	mkdir -p $(INITRAMFS_DIR)/dev
	mkdir -p $(INITRAMFS_DIR)/proc
	mkdir -p $(INITRAMFS_DIR)/sys
	mkdir -p $(INITRAMFS_DIR)/root
	mkdir -p $(INITRAMFS_DIR)/tmp
	mkdir -p $(INITRAMFS_DIR)/mnt
	mkdir -p $(INITRAMFS_DIR)/run
	
	# Note: Device nodes are not created here; devtmpfs will handle them at boot
	# The init script mounts devtmpfs which automatically creates device nodes
	
	# Copy init script
	@echo "Copying init script..."
	cp init $(INITRAMFS_DIR)/init
	chmod +x $(INITRAMFS_DIR)/init

	# Pre-generate SSH host keys at build time to avoid ~10-30s keygen delay at boot
	@echo "Pre-generating SSH host keys..."
	mkdir -p $(INITRAMFS_DIR)/etc/ssh
	@for keytype in rsa ecdsa ed25519; do \
		keyfile="$(INITRAMFS_DIR)/etc/ssh/ssh_host_$${keytype}_key"; \
		if [ ! -f "$$keyfile" ]; then \
			ssh-keygen -q -t $$keytype -N "" -f "$$keyfile" >/dev/null 2>&1; \
		fi; \
	done
	@echo "SSH host keys pre-generated."

	# Copy Tauri app binary
	@echo "Copying Tauri app binary..."
	mkdir -p $(INITRAMFS_DIR)/opt/kiosk
	cp $(TAURI_BIN) $(INITRAMFS_DIR)/opt/kiosk/tauri_welcome
	chmod +x $(INITRAMFS_DIR)/opt/kiosk/tauri_welcome
	@echo "Validating Tauri runtime loader in initramfs..."
	@INTERP=$$(readelf -l $(TAURI_BIN) 2>/dev/null | sed -n 's/.*Requesting program interpreter: \(.*\)]/\1/p'); \
	if [ -z "$$INTERP" ]; then \
		echo "ERROR: Could not detect ELF interpreter for $(TAURI_BIN)"; \
		exit 1; \
	fi; \
	if [ ! -e "$(INITRAMFS_DIR)$$INTERP" ]; then \
		echo "ERROR: Missing runtime loader $$INTERP in initramfs"; \
		echo "ERROR: Cached Alpine rootfs is stale for current package set."; \
		echo "ERROR: Rebuild rootfs: sudo rm -rf $(ALPINE_DIR) $(KERNEL_IMAGE) && sudo make repack"; \
		exit 1; \
	fi
	
	# Create initramfs archive
	@echo "Creating initramfs archive..."
	cd $(INITRAMFS_DIR) && \
		find . | cpio -H newc -o | gzip > ../initramfs.cpio.gz
	
	@echo "Initramfs created: $(INITRAMFS_CPIO)"

initramfs: $(INITRAMFS_CPIO)

# Create UKI using ukify
$(UKI_IMAGE): $(KERNEL_IMAGE) $(INITRAMFS_CPIO)
	@echo "Creating Unified Kernel Image (UKI)..."
	$(UKIFY) build \
		--linux=$(KERNEL_IMAGE) \
		--initrd=$(INITRAMFS_CPIO) \
		--cmdline="console=tty0 console=ttyS0 earlyprintk=serial,ttyS0,115200 loglevel=7 debug net.ifnames=0 biosdevname=0" \
		--output=$(UKI_IMAGE)
	@echo "UKI created: $(UKI_IMAGE)"

uki: $(UKI_IMAGE)

# Generate a local Secure Boot keypair/certificate used to sign UKI.
# You must enroll $(SB_CERT_DER) into UEFI db (or MOK path via shim) on target hardware.
$(SB_KEY) $(SB_CERT) $(SB_CERT_DER):
	@echo "Generating Secure Boot keypair in $(SB_DIR)..."
	mkdir -p $(SB_DIR)
	@if [ ! -f "$(SB_KEY)" ] || [ ! -f "$(SB_CERT)" ]; then \
		openssl req -new -x509 -newkey rsa:4096 -sha256 -nodes \
			-subj "/CN=Kiosk Secure Boot DB/" \
			-keyout $(SB_KEY) \
			-out $(SB_CERT) \
			-days 3650; \
	fi
	openssl x509 -outform DER -in $(SB_CERT) -out $(SB_CERT_DER)
	@echo "Created: $(SB_KEY), $(SB_CERT), $(SB_CERT_DER)"
	@echo "IMPORTANT: enroll $(SB_CERT_DER) in firmware db before booting signed image."

sb-keygen: $(SB_KEY) $(SB_CERT) $(SB_CERT_DER)

$(UKI_SIGNED_IMAGE): $(UKI_IMAGE) $(SB_KEY) $(SB_CERT)
	@echo "Signing UKI with local Secure Boot key..."
	@command -v $(SBSIGN) >/dev/null 2>&1 || (echo "ERROR: sbsign is required (install sbsigntool)." && exit 1)
	@command -v $(SBVERIFY) >/dev/null 2>&1 || (echo "ERROR: sbverify is required (install sbsigntool)." && exit 1)
	$(SBSIGN) --key $(SB_KEY) --cert $(SB_CERT) --output $(UKI_SIGNED_IMAGE) $(UKI_IMAGE)
	$(SBVERIFY) --cert $(SB_CERT) $(UKI_SIGNED_IMAGE)
	@echo "Signed UKI created: $(UKI_SIGNED_IMAGE)"

uki-sb: $(UKI_SIGNED_IMAGE)

# Create bootable disk image
$(DISK_IMAGE): $(UKI_IMAGE)
	@echo "Creating bootable disk image..."
	
	# Create empty disk image
	@UKI_SIZE_MB=$$(( ($$(stat -c%s $(UKI_IMAGE)) + 1048575) / 1048576 )); \
	DISK_SIZE_MB=$$(( $$UKI_SIZE_MB + $(DISK_PADDING_MB) )); \
	if [ $$DISK_SIZE_MB -lt $(DISK_MIN_SIZE_MB) ]; then DISK_SIZE_MB=$(DISK_MIN_SIZE_MB); fi; \
	echo "Creating $$DISK_SIZE_MB MB disk image (UKI $$UKI_SIZE_MB MB + $(DISK_PADDING_MB) MB padding)..."; \
	dd if=/dev/zero of=$(DISK_IMAGE) bs=1M count=$$DISK_SIZE_MB status=progress
	
	# Create GPT partition table and EFI system partition
	@echo "Creating GPT partition table..."
	parted -s $(DISK_IMAGE) mklabel gpt
	parted -s $(DISK_IMAGE) mkpart primary fat32 1MiB 100%
	parted -s $(DISK_IMAGE) set 1 esp on
	
	# Format the partition using mformat (mtools)
	@echo "Creating FAT32 filesystem using mtools..."
	@PART_OFFSET=$$(parted -s $(DISK_IMAGE) unit B print | grep '^ 1' | awk '{print $$2}' | sed 's/B//'); \
	echo "Partition offset: $$PART_OFFSET bytes"; \
	mformat -i $(DISK_IMAGE)@@$$PART_OFFSET -F -v EFIBOOT ::
	
	# Create directory structure and copy files using mtools
	@echo "Creating EFI directory structure..."
	@PART_OFFSET=$$(parted -s $(DISK_IMAGE) unit B print | grep '^ 1' | awk '{print $$2}' | sed 's/B//'); \
	mmd -i $(DISK_IMAGE)@@$$PART_OFFSET ::/EFI; \
	mmd -i $(DISK_IMAGE)@@$$PART_OFFSET ::/EFI/BOOT; \
	echo "Copying UKI to EFI partition..."; \
	mcopy -i $(DISK_IMAGE)@@$$PART_OFFSET $(UKI_IMAGE) ::/EFI/BOOT/BOOTX64.EFI
	
	@echo "=========================================="
	@echo "Bootable disk image created: $(DISK_IMAGE)"
	@echo "=========================================="
	chmod a+r $(DISK_IMAGE) $(UKI_IMAGE) $(INITRAMFS_CPIO) $(KERNEL_IMAGE)
	@echo ""
	@echo "Image components and sizes:"
	@echo "  Kernel:    $$(ls -lh $(KERNEL_IMAGE) | awk '{print $$5}') ($(KERNEL_IMAGE))"
	@echo "  Initramfs: $$(ls -lh $(INITRAMFS_CPIO) | awk '{print $$5}') ($(INITRAMFS_CPIO))"
	@echo "  UKI:       $$(ls -lh $(UKI_IMAGE) | awk '{print $$5}') ($(UKI_IMAGE))"
	@echo "  Tauri app: $$(ls -lh $(TAURI_BIN) | awk '{print $$5}') ($(TAURI_BIN))"
	@echo "  Disk img:  $$(ls -lh $(DISK_IMAGE) | awk '{print $$5}') ($(DISK_IMAGE))"
	@echo ""
	@echo "To write to USB drive:"
	@echo "  sudo dd if=$(DISK_IMAGE) of=/dev/sdX bs=4M status=progress && sync"
	@echo "  (Replace /dev/sdX with your USB drive)"
	@echo ""
	@echo "To test in QEMU:"
	@echo "  make run"

disk: $(DISK_IMAGE)

# Build a copy of disk image that boots a signed UKI.
$(DISK_IMAGE_SB): $(DISK_IMAGE) $(UKI_SIGNED_IMAGE) $(SB_CERT_DER)
	@echo "Creating Secure Boot disk image copy..."
	cp $(DISK_IMAGE) $(DISK_IMAGE_SB)
	@PART_OFFSET=$$(parted -s $(DISK_IMAGE_SB) unit B print | grep '^ 1' | awk '{print $$2}' | sed 's/B//'); \
	mcopy -o -i $(DISK_IMAGE_SB)@@$$PART_OFFSET $(UKI_SIGNED_IMAGE) ::/EFI/BOOT/BOOTX64.EFI; \
	mcopy -o -i $(DISK_IMAGE_SB)@@$$PART_OFFSET $(SB_CERT_DER) ::/EFI/BOOT/DB.CER
	@echo "=========================================="
	@echo "Secure Boot disk image created: $(DISK_IMAGE_SB)"
	@echo "EFI payload: $(UKI_SIGNED_IMAGE)"
	@echo "Certificate copied as EFI/BOOT/DB.CER"
	@echo "=========================================="

disk-sb: $(DISK_IMAGE_SB)

# Create VMware-compatible VMDK image from raw disk image
$(VMDK_IMAGE): $(DISK_IMAGE)
	@echo "Creating VMware-compatible VMDK image..."
	@command -v qemu-img >/dev/null 2>&1 || (echo "ERROR: qemu-img is required (install qemu-utils)." && exit 1)
	qemu-img convert -f raw -O vmdk $(DISK_IMAGE) $(VMDK_IMAGE)

vmdk: $(VMDK_IMAGE)

repack:
	@echo "Repacking from cached Alpine rootfs..."
	rm -f $(INITRAMFS_CPIO) $(UKI_IMAGE) $(DISK_IMAGE) $(TAURI_BIN)
	$(MAKE) disk

# Run in QEMU
run: $(DISK_IMAGE)
	@echo "Starting QEMU..."
	@echo "Window will show system console, terminal shows kernel logs"
	@echo "SSH access: ssh root@localhost -p 2222 (password: alpine)"
	@echo "Tip: To exit QEMU, close the window or press Ctrl+C in terminal"
	@echo ""
	qemu-system-x86_64 -enable-kvm -m 2G \
		-drive file=/dev/sda,format=raw,if=virtio \
		-snapshot \
		-bios /usr/share/ovmf/OVMF.fd \
		-vga std \
		-display sdl,gl=off \
		-device virtio-keyboard-pci \
		-device virtio-mouse-pci \
		-serial stdio \
		-netdev user,id=net0,hostfwd=tcp::2222-:22 \
		-device e1000,netdev=net0

clean:
	@echo "Cleaning build directory..."
	rm -rf $(BUILD_DIR) $(DISK_IMAGE)
	rm -f build.log
	rm -rf $(TAURI_BUILD_ROOT)
	@echo "Cleaning Tauri build artifacts..."
	rm -rf $(TAURI_APP_DIR)/dist
	rm -rf $(TAURI_APP_DIR)/src-tauri/target
	@echo "Clean complete."

help:
	@echo "Makefile targets:"
	@echo "  all             - Build everything and create bootable disk image (default)"
	@echo "  download-alpine - Download Alpine Linux rootfs and kernel"
	@echo "  initramfs       - Create initramfs"
	@echo "  uki             - Create Unified Kernel Image"
	@echo "  sb-keygen       - Generate local Secure Boot signing key/certificate"
	@echo "  uki-sb          - Sign UKI with local Secure Boot key"
	@echo "  disk            - Create bootable disk image"
	@echo "  disk-sb         - Create signed bootable disk image copy"
	@echo "  vmdk            - Create VMware-compatible VMDK from bootable-usb.img"
	@echo "  repack          - Rebuild disk image from cached Alpine rootfs"
	@echo "  run             - Run in QEMU (window + console logs)"
	@echo "  clean           - Remove build artifacts"
	@echo "  help            - Show this help message"
