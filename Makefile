# Makefile for QEMU.

ifneq ($(words $(subst :, ,$(CURDIR))), 1)
  $(error main directory cannot contain spaces nor colons)
endif

# Always point to the root of the build tree (needs GNU make).
BUILD_DIR=$(CURDIR)

# Before including a proper config-host.mak, assume we are in the source tree
SRC_PATH=.

UNCHECKED_GOALS := %clean TAGS cscope ctags dist \
    html info pdf txt \
    help check-help print-% \
    docker docker-% vm-help vm-test vm-build-%

# All following code might depend on configuration variables
ifneq ($(wildcard config-host.mak),)
# Put the all: rule here so that config-host.mak can contain dependencies.
all:
include config-host.mak

git-submodule-update:

.PHONY: git-submodule-update

git_module_status := $(shell \
  cd '$(SRC_PATH)' && \
  GIT="$(GIT)" ./scripts/git-submodule.sh status $(GIT_SUBMODULES); \
  echo $$?; \
)

ifeq (1,$(git_module_status))
ifeq (no,$(GIT_UPDATE))
git-submodule-update:
	$(call quiet-command, \
            echo && \
            echo "GIT submodule checkout is out of date. Please run" && \
            echo "  scripts/git-submodule.sh update $(GIT_SUBMODULES)" && \
            echo "from the source directory checkout $(SRC_PATH)" && \
            echo && \
            exit 1)
else
git-submodule-update:
	$(call quiet-command, \
          (cd $(SRC_PATH) && GIT="$(GIT)" ./scripts/git-submodule.sh update $(GIT_SUBMODULES)), \
          "GIT","$(GIT_SUBMODULES)")
endif
endif

export NINJA=./ninjatool

# Running meson regenerates both build.ninja and ninjatool, and that is
# enough to prime the rest of the build.
ninjatool: build.ninja

# Only needed in case Makefile.ninja does not exist.
.PHONY: ninja-clean ninja-distclean clean-ctlist
clean-ctlist:
ninja-clean::
ninja-distclean::
build.ninja: config-host.mak

Makefile.ninja: build.ninja ninjatool
	./ninjatool -t ninja2make --omit clean dist uninstall < $< > $@
-include Makefile.ninja

${ninja-targets-c_COMPILER} ${ninja-targets-cpp_COMPILER}: .var.command += -MP

# If MESON is empty, the rule will be re-evaluated after Makefiles are
# reread (and MESON won't be empty anymore).
ifneq ($(MESON),)
Makefile.mtest: build.ninja scripts/mtest2make.py
	$(MESON) introspect --tests | $(PYTHON) scripts/mtest2make.py > $@
-include Makefile.mtest
endif

.git-submodule-status: git-submodule-update config-host.mak

# Check that we're not trying to do an out-of-tree build from
# a tree that's been used for an in-tree build.
ifneq ($(realpath $(SRC_PATH)),$(realpath .))
ifneq ($(wildcard $(SRC_PATH)/config-host.mak),)
$(error This is an out of tree build but your source tree ($(SRC_PATH)) \
seems to have been used for an in-tree build. You can fix this by running \
"$(MAKE) distclean && rm -rf *-linux-user *-softmmu" in your source tree)
endif
endif

CONFIG_SOFTMMU := $(if $(filter %-softmmu,$(TARGET_DIRS)),y)
CONFIG_USER_ONLY := $(if $(filter %-user,$(TARGET_DIRS)),y)
CONFIG_XEN := $(CONFIG_XEN_BACKEND)
CONFIG_ALL=y
-include config-all-devices.mak
-include config-all-disas.mak

config-host.mak: $(SRC_PATH)/configure $(SRC_PATH)/pc-bios $(SRC_PATH)/VERSION
	@echo $@ is out-of-date, running configure
	@if test -f meson-private/coredata.dat; then \
	  ./config.status --skip-meson; \
	else \
	  ./config.status; \
	fi

# Force configure to re-run if the API symbols are updated
ifeq ($(CONFIG_PLUGIN),y)
config-host.mak: $(SRC_PATH)/plugins/qemu-plugins.symbols
endif

else
config-host.mak:
ifneq ($(filter-out $(UNCHECKED_GOALS),$(MAKECMDGOALS)),$(if $(MAKECMDGOALS),,fail))
	@echo "Please call configure before running make!"
	@exit 1
endif
endif

include $(SRC_PATH)/rules.mak

# lor is defined in rules.mak
CONFIG_BLOCK := $(call lor,$(CONFIG_SOFTMMU),$(CONFIG_TOOLS))

generated-files-y += .git-submodule-status

# Don't try to regenerate Makefile or configure
# We don't generate any of them
Makefile: ;
configure: ;

.PHONY: all clean cscope distclean html info install install-doc \
	pdf txt recurse-all dist msi FORCE

$(call set-vpath, $(SRC_PATH))

LIBS+=-lz $(LIBS_TOOLS)

ifdef BUILD_DOCS
DOCS+=docs/interop/qemu-qmp-ref.html docs/interop/qemu-qmp-ref.txt docs/interop/qemu-qmp-ref.7
DOCS+=docs/interop/qemu-ga-ref.html docs/interop/qemu-ga-ref.txt docs/interop/qemu-ga-ref.7
else
DOCS=
endif

SUBDIR_MAKEFLAGS=$(if $(V),,--no-print-directory --quiet) BUILD_DIR=$(BUILD_DIR)

ifneq ($(wildcard config-host.mak),)
include $(SRC_PATH)/Makefile.objs
endif

include $(SRC_PATH)/tests/Makefile.include

all: $(DOCS) $(if $(BUILD_DOCS),sphinxdocs) recurse-all modules

# LIBFDT_lib="": avoid breaking existing trees with objects requiring -fPIC
DTC_MAKE_ARGS=-I$(SRC_PATH)/dtc VPATH=$(SRC_PATH)/dtc -C dtc V="$(V)" LIBFDT_lib=""
DTC_CFLAGS=$(CFLAGS) $(QEMU_CFLAGS)
DTC_CPPFLAGS=-I$(SRC_PATH)/dtc/libfdt

.PHONY: dtc/all
dtc/all: .git-submodule-status dtc/libfdt
	$(call quiet-command,$(MAKE) $(DTC_MAKE_ARGS) CPPFLAGS="$(DTC_CPPFLAGS)" CFLAGS="$(DTC_CFLAGS)" LDFLAGS="$(QEMU_LDFLAGS)" ARFLAGS="$(ARFLAGS)" CC="$(CC)" AR="$(AR)" LD="$(LD)" $(SUBDIR_MAKEFLAGS) libfdt,)

dtc/%: .git-submodule-status
	@mkdir -p $@

# Overriding CFLAGS causes us to lose defines added in the sub-makefile.
# Not overriding CFLAGS leads to mis-matches between compilation modes.
# Therefore we replicate some of the logic in the sub-makefile.
# Remove all the extra -Warning flags that QEMU uses that Capstone doesn't;
# no need to annoy QEMU developers with such things.
CAP_CFLAGS = $(patsubst -W%,,$(CFLAGS) $(QEMU_CFLAGS))
CAP_CFLAGS += -DCAPSTONE_USE_SYS_DYN_MEM
CAP_CFLAGS += -DCAPSTONE_HAS_ARM
CAP_CFLAGS += -DCAPSTONE_HAS_ARM64
CAP_CFLAGS += -DCAPSTONE_HAS_POWERPC
CAP_CFLAGS += -DCAPSTONE_HAS_X86

.PHONY: capstone/all
capstone/all: .git-submodule-status
	$(call quiet-command,$(MAKE) -C $(SRC_PATH)/capstone CAPSTONE_SHARED=no BUILDDIR="$(BUILD_DIR)/capstone" CC="$(CC)" AR="$(AR)" LD="$(LD)" RANLIB="$(RANLIB)" CFLAGS="$(CAP_CFLAGS)" $(SUBDIR_MAKEFLAGS) $(BUILD_DIR)/capstone/$(LIBCAPSTONE))

.PHONY: slirp/all
slirp/all: .git-submodule-status
	$(call quiet-command,$(MAKE) -C $(SRC_PATH)/slirp		\
		BUILD_DIR="$(BUILD_DIR)/slirp" 			\
		PKG_CONFIG="$(PKG_CONFIG)" 				\
		CC="$(CC)" AR="$(AR)" 	LD="$(LD)" RANLIB="$(RANLIB)"	\
		CFLAGS="$(QEMU_CFLAGS) $(CFLAGS)" LDFLAGS="$(QEMU_LDFLAGS)")

ROM_DIRS = $(addprefix pc-bios/, $(ROMS))
ROM_DIRS_RULES=$(foreach t, all clean, $(addsuffix /$(t), $(ROM_DIRS)))
# Only keep -O and -g cflags
.PHONY: $(ROM_DIRS_RULES)
$(ROM_DIRS_RULES):
	$(call quiet-command,$(MAKE) $(SUBDIR_MAKEFLAGS) -C $(dir $@) V="$(V)" TARGET_DIR="$(dir $@)" CFLAGS="$(filter -O% -g%,$(CFLAGS))" $(notdir $@),)

.PHONY: recurse-all recurse-clean
recurse-all: $(ROM_DIRS)
recurse-clean: $(addsuffix /clean, $(ROM_DIRS))

######################################################################

clean: recurse-clean ninja-clean clean-ctlist
	-test -f ninjatool && ./ninjatool $(if $(V),-v,) -t clean
# avoid old build problems by removing potentially incorrect old files
	rm -f config.mak op-i386.h opc-i386.h gen-op-i386.h op-arm.h opc-arm.h gen-op-arm.h
	find . \( -name '*.so' -o -name '*.dll' -o -name '*.mo' -o -name '*.[oda]' \) -type f \
		! -path ./roms/edk2/ArmPkg/Library/GccLto/liblto-aarch64.a \
		! -path ./roms/edk2/ArmPkg/Library/GccLto/liblto-arm.a \
		! -path ./roms/edk2/BaseTools/Source/Python/UPT/Dll/sqlite3.dll \
		-exec rm {} +
	rm -f TAGS cscope.* *.pod *~ */*~
	rm -f fsdev/*.pod scsi/*.pod
	rm -f $(foreach f,$(generated-files-y),$(f) $(f)-timestamp)

VERSION ?= $(shell cat VERSION)

dist: qemu-$(VERSION).tar.bz2

qemu-%.tar.bz2:
	$(SRC_PATH)/scripts/make-release "$(SRC_PATH)" "$(patsubst qemu-%.tar.bz2,%,$@)"

distclean: clean ninja-distclean
	-test -f ninjatool && ./ninjatool $(if $(V),-v,) -t clean -g
	rm -f config-host.mak config-host.h* $(DOCS)
	rm -f tests/tcg/config-*.mak
	rm -f config-all-disas.mak config.status
	rm -f po/*.mo tests/qemu-iotests/common.env
	rm -f roms/seabios/config.mak roms/vgabios/config.mak
	rm -f qemu-plugins-ld.symbols qemu-plugins-ld64.symbols
	rm -f *-config-target.h *-config-devices.mak *-config-devices.h
	rm -rf meson-private meson-logs meson-info compile_commands.json
	rm -f Makefile.ninja ninjatool ninjatool.stamp Makefile.mtest
	rm -f config.log
	rm -f linux-headers/asm
	rm -f docs/version.texi
	rm -f docs/interop/qemu-ga-qapi.texi docs/interop/qemu-qmp-qapi.texi
	rm -f docs/interop/qemu-qmp-ref.7 docs/interop/qemu-ga-ref.7
	rm -f docs/interop/qemu-qmp-ref.txt docs/interop/qemu-ga-ref.txt
	rm -f docs/interop/qemu-qmp-ref.pdf docs/interop/qemu-ga-ref.pdf
	rm -f docs/interop/qemu-qmp-ref.html docs/interop/qemu-ga-ref.html
	rm -Rf .sdk

KEYMAPS=da     en-gb  et  fr     fr-ch  is  lt  no  pt-br  sv \
ar      de     en-us  fi  fr-be  hr     it  lv  nl         pl  ru     th \
de-ch  es     fo  fr-ca  hu     ja  mk  pt  sl     tr \
bepo    cz

ifdef INSTALL_BLOBS
BLOBS=bios.bin bios-256k.bin bios-microvm.bin sgabios.bin vgabios.bin vgabios-cirrus.bin \
vgabios-stdvga.bin vgabios-vmware.bin vgabios-qxl.bin vgabios-virtio.bin \
vgabios-ramfb.bin vgabios-bochs-display.bin vgabios-ati.bin \
openbios-sparc32 openbios-sparc64 openbios-ppc QEMU,tcx.bin QEMU,cgthree.bin \
pxe-e1000.rom pxe-eepro100.rom pxe-ne2k_pci.rom \
pxe-pcnet.rom pxe-rtl8139.rom pxe-virtio.rom \
efi-e1000.rom efi-eepro100.rom efi-ne2k_pci.rom \
efi-pcnet.rom efi-rtl8139.rom efi-virtio.rom \
efi-e1000e.rom efi-vmxnet3.rom \
qemu-nsis.bmp \
bamboo.dtb canyonlands.dtb petalogix-s3adsp1800.dtb petalogix-ml605.dtb \
multiboot.bin linuxboot.bin linuxboot_dma.bin kvmvapic.bin pvh.bin \
s390-ccw.img s390-netboot.img \
slof.bin skiboot.lid \
palcode-clipper \
u-boot.e500 u-boot-sam460-20100605.bin \
qemu_vga.ndrv \
edk2-licenses.txt \
hppa-firmware.img \
opensbi-riscv32-sifive_u-fw_jump.bin opensbi-riscv32-virt-fw_jump.bin \
opensbi-riscv64-sifive_u-fw_jump.bin opensbi-riscv64-virt-fw_jump.bin
else
BLOBS=
endif

install-doc: $(DOCS)
	$(INSTALL_DIR) "$(DESTDIR)$(qemu_docdir)"
	$(INSTALL_DATA) docs/interop/qemu-qmp-ref.html "$(DESTDIR)$(qemu_docdir)/interop"
	$(INSTALL_DATA) docs/interop/qemu-qmp-ref.txt "$(DESTDIR)$(qemu_docdir)/interop"
ifdef CONFIG_POSIX
	$(INSTALL_DIR) "$(DESTDIR)$(mandir)/man1"
	$(INSTALL_DATA) $(MANUAL_BUILDDIR)/system/qemu.1 "$(DESTDIR)$(mandir)/man1"
	$(INSTALL_DIR) "$(DESTDIR)$(mandir)/man7"
	$(INSTALL_DATA) docs/interop/qemu-qmp-ref.7 "$(DESTDIR)$(mandir)/man7"
ifeq ($(CONFIG_GUEST_AGENT),y)
	$(INSTALL_DATA) docs/interop/qemu-ga-ref.html "$(DESTDIR)$(qemu_docdir)/interop"
	$(INSTALL_DATA) docs/interop/qemu-ga-ref.txt "$(DESTDIR)$(qemu_docdir)/interop"
	$(INSTALL_DATA) docs/interop/qemu-ga-ref.7 "$(DESTDIR)$(mandir)/man7"
endif
endif
ifdef CONFIG_VIRTFS
	$(INSTALL_DIR) "$(DESTDIR)$(mandir)/man1"
	$(INSTALL_DATA) $(MANUAL_BUILDDIR)/tools/virtfs-proxy-helper.1 "$(DESTDIR)$(mandir)/man1"
endif
ifeq ($(CONFIG_LINUX)$(CONFIG_SECCOMP)$(CONFIG_LIBCAP_NG),yyy)
	$(INSTALL_DATA) $(MANUAL_BUILDDIR)/tools/virtiofsd.1 "$(DESTDIR)$(mandir)/man1"
endif

install-datadir:
	$(INSTALL_DIR) "$(DESTDIR)$(qemu_datadir)"

install-localstatedir:
ifdef CONFIG_POSIX
ifeq ($(CONFIG_GUEST_AGENT),y)
	$(INSTALL_DIR) "$(DESTDIR)$(qemu_localstatedir)"/run
endif
endif

ICON_SIZES=16x16 24x24 32x32 48x48 64x64 128x128 256x256 512x512

# Needed by "meson install"
export DESTDIR
install: all $(if $(BUILD_DOCS),install-doc) \
	install-datadir install-localstatedir
ifdef CONFIG_TRACE_SYSTEMTAP
	$(INSTALL_PROG) "scripts/qemu-trace-stap" $(DESTDIR)$(bindir)
endif
ifneq ($(BLOBS),)
	set -e; for x in $(BLOBS); do \
		$(INSTALL_DATA) $(SRC_PATH)/pc-bios/$$x "$(DESTDIR)$(qemu_datadir)"; \
	done
endif
	for s in $(ICON_SIZES); do \
		mkdir -p "$(DESTDIR)$(qemu_icondir)/hicolor/$${s}/apps"; \
		$(INSTALL_DATA) $(SRC_PATH)/ui/icons/qemu_$${s}.png \
			"$(DESTDIR)$(qemu_icondir)/hicolor/$${s}/apps/qemu.png"; \
	done; \
	mkdir -p "$(DESTDIR)$(qemu_icondir)/hicolor/32x32/apps"; \
	$(INSTALL_DATA) $(SRC_PATH)/ui/icons/qemu_32x32.bmp \
		"$(DESTDIR)$(qemu_icondir)/hicolor/32x32/apps/qemu.bmp"; \
	mkdir -p "$(DESTDIR)$(qemu_icondir)/hicolor/scalable/apps"; \
	$(INSTALL_DATA) $(SRC_PATH)/ui/icons/qemu.svg \
		"$(DESTDIR)$(qemu_icondir)/hicolor/scalable/apps/qemu.svg"
	mkdir -p "$(DESTDIR)$(qemu_desktopdir)"
	$(INSTALL_DATA) $(SRC_PATH)/ui/qemu.desktop \
		"$(DESTDIR)$(qemu_desktopdir)/qemu.desktop"
ifdef CONFIG_GTK
	$(MAKE) -C po $@
endif
	$(INSTALL_DIR) "$(DESTDIR)$(qemu_datadir)/keymaps"
	set -e; for x in $(KEYMAPS); do \
		$(INSTALL_DATA) $(SRC_PATH)/pc-bios/keymaps/$$x "$(DESTDIR)$(qemu_datadir)/keymaps"; \
	done

# documentation
MAKEINFO=makeinfo
MAKEINFOINCLUDES= -I docs -I $(<D) -I $(@D)
MAKEINFOFLAGS=--no-split --number-sections $(MAKEINFOINCLUDES)
TEXI2PODFLAGS=$(MAKEINFOINCLUDES) -DVERSION="$(VERSION)" -DCONFDIR="$(qemu_confdir)"
TEXI2PDFFLAGS=$(if $(V),,--quiet) -I $(SRC_PATH) $(MAKEINFOINCLUDES)

docs/version.texi: $(SRC_PATH)/VERSION config-host.mak
	$(call quiet-command,(\
		echo "@set VERSION $(VERSION)" && \
		echo "@set CONFDIR $(qemu_confdir)" \
	)> $@,"GEN","$@")

%.html: %.texi docs/version.texi
	$(call quiet-command,LC_ALL=C $(MAKEINFO) $(MAKEINFOFLAGS) --no-headers \
	--html $< -o $@,"GEN","$@")

%.info: %.texi docs/version.texi
	$(call quiet-command,$(MAKEINFO) $(MAKEINFOFLAGS) $< -o $@,"GEN","$@")

%.txt: %.texi docs/version.texi
	$(call quiet-command,LC_ALL=C $(MAKEINFO) $(MAKEINFOFLAGS) --no-headers \
	--plaintext $< -o $@,"GEN","$@")

%.pdf: %.texi docs/version.texi
	$(call quiet-command,texi2pdf $(TEXI2PDFFLAGS) $< -o $@,"GEN","$@")

docs/interop/qemu-qmp-qapi.texi: qapi/qapi-doc.texi
	@cp -p $< $@

docs/interop/qemu-ga-qapi.texi: qga/qga-qapi-doc.texi
	@cp -p $< $@

html: docs/interop/qemu-qmp-ref.html docs/interop/qemu-ga-ref.html sphinxdocs
info: docs/interop/qemu-qmp-ref.info docs/interop/qemu-ga-ref.info
pdf: docs/interop/qemu-qmp-ref.pdf docs/interop/qemu-ga-ref.pdf
txt: docs/interop/qemu-qmp-ref.txt docs/interop/qemu-ga-ref.txt

docs/interop/qemu-ga-ref.dvi docs/interop/qemu-ga-ref.html \
    docs/interop/qemu-ga-ref.info docs/interop/qemu-ga-ref.pdf \
    docs/interop/qemu-ga-ref.txt docs/interop/qemu-ga-ref.7: \
	docs/interop/qemu-ga-ref.texi docs/interop/qemu-ga-qapi.texi

docs/interop/qemu-qmp-ref.dvi docs/interop/qemu-qmp-ref.html \
    docs/interop/qemu-qmp-ref.info docs/interop/qemu-qmp-ref.pdf \
    docs/interop/qemu-qmp-ref.txt docs/interop/qemu-qmp-ref.7: \
	docs/interop/qemu-qmp-ref.texi docs/interop/qemu-qmp-qapi.texi

$(filter %.1 %.7 %.8,$(DOCS)): scripts/texi2pod.pl
	$(call quiet-command, \
	  perl -Ww -- $(SRC_PATH)/scripts/texi2pod.pl $(TEXI2PODFLAGS) $< $@.pod && \
	  $(POD2MAN) --section=$(subst .,,$(suffix $@)) --center=" " --release=" " $@.pod > $@, \
	  "GEN","$@")

man: $(filter %.1 %.7 %.8,$(DOCS))

ifdef CONFIG_WIN32

INSTALLER = qemu-setup-$(VERSION)$(EXESUF)

nsisflags = -V2 -NOCD

ifneq ($(wildcard $(SRC_PATH)/dll),)
ifeq ($(ARCH),x86_64)
# 64 bit executables
DLL_PATH = $(SRC_PATH)/dll/w64
nsisflags += -DW64
else
# 32 bit executables
DLL_PATH = $(SRC_PATH)/dll/w32
endif
endif

.PHONY: installer
installer: $(INSTALLER)

INSTDIR=/tmp/qemu-nsis

$(INSTALLER): $(SRC_PATH)/qemu.nsi
	$(MAKE) install DESTDIR=${INSTDIR}
ifdef SIGNCODE
	(cd ${INSTDIR}/${bindir}; \
         for i in *.exe; do \
           $(SIGNCODE) $${i}; \
         done \
        )
endif # SIGNCODE
	(cd ${INSTDIR}/${bindir}; \
         for i in qemu-system-*.exe; do \
           arch=$${i%.exe}; \
           arch=$${arch#qemu-system-}; \
           echo Section \"$$arch\" Section_$$arch; \
           echo SetOutPath \"\$$INSTDIR\"; \
           echo File \"\$${BINDIR}\\$$i\"; \
           echo SectionEnd; \
         done \
        ) >${INSTDIR}/${bindir}/system-emulations.nsh
	makensis $(nsisflags) \
                $(if $(BUILD_DOCS),-DCONFIG_DOCUMENTATION="y") \
                $(if $(CONFIG_GTK),-DCONFIG_GTK="y") \
                -DBINDIR="${INSTDIR}/${bindir}" \
                $(if $(DLL_PATH),-DDLLDIR="$(DLL_PATH)") \
                -DSRCDIR="$(SRC_PATH)" \
                -DOUTFILE="$(INSTALLER)" \
                -DDISPLAYVERSION="$(VERSION)" \
                $(SRC_PATH)/qemu.nsi
	rm -r ${INSTDIR}
ifdef SIGNCODE
	$(SIGNCODE) $(INSTALLER)
endif # SIGNCODE
endif # CONFIG_WIN

# Add a dependency on the generated files, so that they are always
# rebuilt before other object files
ifneq ($(wildcard config-host.mak),)
ifneq ($(filter-out $(UNCHECKED_GOALS),$(MAKECMDGOALS)),$(if $(MAKECMDGOALS),,fail))
Makefile: $(generated-files-y)
endif
endif

# Include automatically generated dependency files
# Dependencies in Makefile.objs files come from our recursive subdir rules
-include $(wildcard *.d tests/*.d)

include $(SRC_PATH)/tests/docker/Makefile.include
include $(SRC_PATH)/tests/vm/Makefile.include

print-help-run = printf "  %-30s - %s\\n" "$1" "$2"
print-help = $(quiet-@)$(call print-help-run,$1,$2)

.PHONY: help
help:
	@echo  'Generic targets:'
	$(call print-help,all,Build all)
ifdef CONFIG_MODULES
	$(call print-help,modules,Build all modules)
endif
	$(call print-help,dir/file.o,Build specified target only)
	$(call print-help,install,Install QEMU, documentation and tools)
	$(call print-help,ctags/TAGS,Generate tags file for editors)
	$(call print-help,cscope,Generate cscope index)
	$(call print-help,sparse,Run sparse on the QEMU source)
	@echo  ''
	@echo  'Cleaning targets:'
	$(call print-help,clean,Remove most generated files but keep the config)
	$(call print-help,distclean,Remove all generated files)
	$(call print-help,dist,Build a distributable tarball)
	@echo  ''
	@echo  'Test targets:'
	$(call print-help,check,Run all tests (check-help for details))
	$(call print-help,docker,Help about targets running tests inside containers)
	$(call print-help,vm-help,Help about targets running tests inside VM)
	@echo  ''
	@echo  'Documentation targets:'
	$(call print-help,html info pdf txt,Build documentation in specified format)
	@echo  ''
ifdef CONFIG_WIN32
	@echo  'Windows targets:'
	$(call print-help,installer,Build NSIS-based installer for QEMU)
ifdef QEMU_GA_MSI_ENABLED
	$(call print-help,msi,Build MSI-based installer for qemu-ga)
endif
	@echo  ''
endif
	$(call print-help,$(MAKE) [targets],(quiet build, default))
	$(call print-help,$(MAKE) V=1 [targets],(verbose build))
