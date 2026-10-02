.DEFAULT_GOAL := help

.PHONY: help install-dev restart update

help:
	@printf '%s\n' \
	  'make install-dev  Back up the installed plugin and symlink this checkout' \
	  'make restart      Restart the Omarchy shell' \
	  'make update       Install the development link, then restart the shell' \
	  'make help         Show this help'

install-dev:
	@bash scripts/install-dev.sh

restart:
	omarchy restart shell

update: install-dev
	@$(MAKE) --no-print-directory restart
