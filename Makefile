# gotempo Simply Love module
#
#   make check                    syntax check and run the logic tests
#   make dist                     build the release zip in dist/
#   make release VERSION=v2.0.0   tag the current commit and push it (CI builds the release)

NAME    := gotempo-sl-module
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
DIST    := dist/$(NAME)-$(VERSION)

# What a player actually installs. Everything else in the repo is for developing
# it: the test harness, the generated extract, git's own files.
PAYLOAD := gotempo.lua gotempo README.md LICENSE.md

.PHONY: check dist clean release

# luac5.1 specifically: the engine is Lua 5.1 and a newer luac accepts syntax it
# rejects.
check:
	luac5.1 -p gotempo.lua
	python3 mkharness.py
	lua5.1 picker_test.lua

dist: check
	rm -rf "$(DIST)" "$(DIST).zip"
	mkdir -p "$(DIST)"
	cp -r $(PAYLOAD) "$(DIST)/"
	@# python rather than zip(1): the test harness already needs python, and
	@# zip is not installed everywhere.
	cd dist && python3 -m zipfile -c "$(NAME)-$(VERSION).zip" "$(NAME)-$(VERSION)"
	@echo "built $(DIST).zip"
	@python3 -m zipfile -l "$(DIST).zip"

clean:
	rm -rf dist extracted.lua

# A tag push triggers .github/workflows/release.yml, which builds the same zip
# and publishes a GitHub release.
release:
	@test -n "$(VERSION)" || { echo "usage: make release VERSION=v1.2.3"; exit 1; }
	@echo "$(VERSION)" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$$' || \
		{ echo "VERSION must look like v1.2.3 (got '$(VERSION)')"; exit 1; }
	@git diff --quiet || { echo "working tree is dirty; commit or stash first"; exit 1; }
	$(MAKE) check
	@# Refuse before the tag exists rather than after. A tag pushed on a commit
	@# the branch has not reached leaves GitHub with no workflow on the default
	@# branch, so the release build never runs, and undoing it means deleting a
	@# tag that is already public.
	@git fetch --quiet origin
	@test -z "$$(git log @{u}..HEAD --oneline 2>/dev/null)" || \
		{ echo "HEAD is ahead of its upstream; push the branch first"; exit 1; }
	git tag -a "$(VERSION)" -m "$(NAME) $(VERSION)"
	@# HEAD as well as the tag, for a branch with no upstream set, where the
	@# check above cannot tell whether the commit is on the remote.
	git push origin HEAD "$(VERSION)"
	@echo "Pushed tag $(VERSION). GitHub Actions will build and publish the release."
