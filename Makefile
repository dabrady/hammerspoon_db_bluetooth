mkfile_path := $(abspath $(lastword $(MAKEFILE_LIST)))
# current_dir := $(notdir $(patsubst %/,%,$(dir $(mkfile_path))))

#MODULE := $(current_dir)
MODULE := bluetooth
PREFIX ?= ~/.hammerspoon/hs/_db
HS_APPLICATION ?= /Applications

HEADERS = ${wildcard *.h}
OBJCFILES = ${wildcard *.m}
LUAFILES  = ${wildcard *.lua}
# swap if all objective-c files should be compiled into one target
# SOFILES := $(OBJCFILE:.m=.so)
# swap if all objective-c files should be compiled into one target
# SOFILES  := $(OBJCFILES:.m=.so)
SOFILES := internal.so watcher.so
DEBUG_CFLAGS ?= -g

# special vars for uninstall
space :=
space +=
comma := ,
ALLFILES := $(LUAFILES)
ALLFILES += $(SOFILES)

# .SUFFIXES: .m .so

CC=clang
EXTRA_CFLAGS ?= -Wconversion -Wdeprecated -F$(HS_APPLICATION)/Hammerspoon.app/Contents/Frameworks
CFLAGS  += $(DEBUG_CFLAGS) -fobjc-arc -fmodules -DHS_EXTERNAL_MODULE -Wall -Wextra $(EXTRA_CFLAGS)
LDFLAGS += -dynamiclib -undefined dynamic_lookup

all: verify $(SOFILES)

# swap if all objective-c files should be compiled into one target
# %.so: %.m $(HEADERS) $(OBJCFILE)
# 	$(CC) $< $(CFLAGS) $(LDFLAGS) -o $@
# swap if all objective-c files should be compiled into one target
# %.so: %.m $(HEADERS) $(OBJCFILES)
# 	$(CC) $< $(CFLAGS) $(LDFLAGS) -o $@
internal.so: $(HEADERS) $(OBJCFILES)
	$(CC) $(OBJCFILES) $(CFLAGS) $(LDFLAGS) -o $@
watcher.so: $(HEADERS) $(OBJCFILES)
	$(CC) $(OBJCFILES) $(CFLAGS) $(LDFLAGS) -o $@

install: install-objc install-lua

verify: $(LUAFILES)
	luac-5.3 -p $(LUAFILES) && echo "Passed" || echo "Failed"

install-objc: $(SOFILES)
	mkdir -p $(PREFIX)/$(MODULE)
	install -m 0644 $(SOFILES) $(PREFIX)/$(MODULE)
	@# swap if all objective-c files should be compiled into one target
	@# cp -vpR $(OBJCFILES:.m=.so.dSYM) $(PREFIX)/$(MODULE)
	cp -vpR $(SOFILES:.m=.so.dSYM) $(PREFIX)/$(MODULE)

install-lua: $(LUAFILES)
	mkdir -p $(PREFIX)/$(MODULE)
	install -m 0644 $(LUAFILES) $(PREFIX)/$(MODULE)

clean:
	rm -v -rf $(SOFILES) *.dSYM $(DOC_FILE)

uninstall:
	rm -v -f $(PREFIX)/$(MODULE)/{$(subst $(space),$(comma),$(ALLFILES))}
	@# swap if all objective-c files should be compiled into one target
	@# (pushd $(PREFIX)/$(MODULE)/ ; rm -v -fr $(OBJCFILES:.m=.so.dSYM) ; popd)
	(pushd $(PREFIX)/$(MODULE)/ ; rm -v -fr $(SOFILES:.m=.so.dSYM) ; popd)
	rmdir -p $(PREFIX)/$(MODULE) ; exit 0

.PHONY: all clean uninstall verify install install-objc install-lua
