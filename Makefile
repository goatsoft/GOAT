# GOAT: monorepo root. The macOS app lives in apps/goat-macos; these targets
# delegate there so `make build` / `make verify` keep working from the repo root.
MACAPP := apps/goat-macos

.PHONY: gen build run test test-app format lint verify clean release cli dmg module-docs

gen build run test test-app format lint verify clean release cli dmg module-docs:
	$(MAKE) -C $(MACAPP) $@
