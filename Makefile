export EMACS ?= $(shell command -v emacs 2>/dev/null)
CASK_DIR := $(shell cask package-directory)
CASK_EMACS := cask emacs --batch

MATCH ?=
ELISP_FILES := pimacs-extensions.el pimacs-hashline.el
INTEGRATION_TESTS := integration/pimacs-extensions-integration-tests.el
FIXTURE_DIR := integration/fixture

$(CASK_DIR): Cask
	cask install
	@touch $(CASK_DIR)

.PHONY: cask
cask: $(CASK_DIR)

.PHONY: setup
setup: cask
	cd $(FIXTURE_DIR) && npm install

.PHONY: compile
compile: cask
	@$(CASK_EMACS) -L . -l pcre2el -f batch-byte-compile $(ELISP_FILES); \
	ret=$$?; rm -f *.elc; exit $$ret

.PHONY: typecheck
typecheck:
	cd $(FIXTURE_DIR) && npm run check

.PHONY: integration
integration: compile typecheck
	@test -x "$(FIXTURE_DIR)/node_modules/.bin/proxay" || \
	  (echo "Run 'make setup' to install integration dependencies." >&2; exit 1)
	@$(CASK_EMACS) -L . -l $(INTEGRATION_TESTS) \
	  --eval '(ert-run-tests-batch-and-exit "$(MATCH)")'

.PHONY: test
test: integration

.PHONY: package-lint
package-lint: cask
	@$(CASK_EMACS) -Q \
	  --eval '(require (quote package-lint))' \
	  --eval '(setq package-lint--sane-prefixes "^pimacs-enable-extensions$$")' \
	  --eval '(setq package-lint-main-file "pimacs-extensions.el")' \
	  -f package-lint-batch-and-exit pimacs-extensions.el

.PHONY: format
format: cask
	@$(CASK_EMACS) -L . --eval " \
	  (let ((inhibit-message t) \
	        (message-log-max nil)) \
	    (setq-default indent-tabs-mode nil) \
	    (dolist (file command-line-args-left) \
	      (with-current-buffer (find-file-noselect file) \
	        (indent-region (point-min) (point-max)) \
	        (save-buffer))))" \
	  $(ELISP_FILES) $(INTEGRATION_TESTS)

.PHONY: verify
verify: format integration package-lint
