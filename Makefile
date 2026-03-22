TESTS_DIR := tests
MINIMAL_INIT := tests/minimal_init.lua

.PHONY: test test-file

test:
	nvim --headless -u $(MINIMAL_INIT) \
		-c "PlenaryBustedDirectory $(TESTS_DIR)/ {minimal_init = '$(MINIMAL_INIT)'}"

test-file:
	nvim --headless -u $(MINIMAL_INIT) \
		-c "PlenaryBustedFile $(FILE)"
