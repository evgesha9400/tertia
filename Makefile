.PHONY: build test package install register run cli mcp render-previews clean

# Overridable paths and tools (`make cli TERTIA_BUILD_DIR=/tmp/b`, `make install INSTALL_APP=...`). `make package`
# publishes to TERTIA_DIST_APP, which `make install` and `make run` then read. TERTIA_BUILD_DIR is used by `build`
# only: packaging always keeps its own per-run build directory so it never races a concurrent `make build`. Paths may
# contain spaces.
TERTIA_BUILD_DIR ?= $(CURDIR)/.build/direct
TERTIA_DIST_APP ?= $(CURDIR)/dist/Tertia.app
INSTALL_APP ?= $(HOME)/Applications/Tertia.app
PLUGINKIT ?= pluginkit
LSREGISTER ?= /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
export TERTIA_DIST_APP

# Message prefix for a failed registration step; `install` names the bundle replacement that already committed. The
# retry command names INSTALL_APP single-quoted for a POSIX shell (each ' written as '\''), so it can be pasted as is.
REGISTER_CONTEXT ?= For $(INSTALL_APP),
INSTALL_APP_SQ = $(subst ','\'',$(INSTALL_APP))
define register_step
$(2) || { echo "$(REGISTER_CONTEXT) registration step '$(1)' failed; to retry, run: make register INSTALL_APP='$(INSTALL_APP_SQ)'" >&2; exit 1; }
endef

build:
	TERTIA_BUILD_DIR="$(TERTIA_BUILD_DIR)" ./Scripts/build.sh

test:
	./Scripts/test.sh

package:
	./Scripts/package_app.sh

# Stages and verifies a copy first, copied under the package lock next to TERTIA_DIST_APP so a concurrent `make package`
# never swaps the source mid-copy. Installs run one at a time (.tertia-install.lock next to INSTALL_APP), which also
# covers removing stages left by killed installs; the verified bundle is swapped in atomically (renamex_np
# RENAME_SWAP), so the installed app is never missing. A failed registration afterwards names its step: the bundle is
# already replaced, and `make register` retries only that part.
install: package
	@set -e; dir="$$(dirname "$(INSTALL_APP)")"; name="$$(basename "$(INSTALL_APP)")"; mkdir -p "$$dir"; \
	src_dir="$$(dirname "$(TERTIA_DIST_APP)")"; src_name="$$(basename "$(TERTIA_DIST_APP)")"; \
	stage="$$dir/.$$name.stage.$$$$"; \
	trap 'rm -rf "$$stage"' EXIT; \
	rm -rf "$$stage"; \
	python3 -I Scripts/publish.py lock "$$src_dir/.$$src_name.lock" cp -R "$(TERTIA_DIST_APP)" "$$stage"; \
	xattr -cr "$$stage"; codesign --verify --deep --strict "$$stage"; \
	python3 -I Scripts/publish.py lock "$$dir/.tertia-install.lock" /bin/sh -c \
	  'python3 -I Scripts/publish.py remove-dead "$$1/.$$2.stage."* && exec python3 -I Scripts/publish.py swap "$$3" "$$4"' \
	  sh "$$dir" "$$name" "$$stage" "$(INSTALL_APP)"
	@$(MAKE) --no-print-directory register REGISTER_CONTEXT="Installed $(INSTALL_APP) (bundle replaced), but"
	@echo "Installed to $(INSTALL_APP)"

register:
	@$(call register_step,lsregister,"$(LSREGISTER)" -f "$(INSTALL_APP)")
	@$(call register_step,pluginkit,"$(PLUGINKIT)" -a "$(INSTALL_APP)/Contents/PlugIns/TertiaWidget.appex")

run:
	open "$(INSTALL_APP)" || open "$(TERTIA_DIST_APP)"

cli: build
	"$(TERTIA_BUILD_DIR)/TertiaApp" timetable --club 39

mcp: build
	"$(TERTIA_BUILD_DIR)/TertiaApp" mcp

render-previews: build
	perl -e 'alarm 30; exec @ARGV' "$(TERTIA_BUILD_DIR)/TertiaApp" render-previews --out ./dist/previews

# Takes the build, package, and (for an overridden TERTIA_DIST_APP) destination locks before touching anything, so a
# running build, package, or test is never cut off; refuses when an existing TERTIA_DIST_APP is not a Tertia bundle.
# Empties .build and dist at every depth except lock files and live runs' directories (`pkg.<pid>`, `.stage.<pid>`),
# then removes an overridden TERTIA_DIST_APP with its dead staging bundles.
clean:
	@python3 -I Scripts/publish.py clean --timeout "$${TERTIA_LOCK_TIMEOUT:-90}" .build dist "$(TERTIA_DIST_APP)"
