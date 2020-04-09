SHELL := /bin/bash # Cheat by using bash :)

OPENRESTY_PREFIX    = /usr/local/openresty

TEST_FILE          ?= t/01-unit t/02-integration
SENTINEL_TEST_FILE ?= t/03-sentinel

TEST_LEDGE_REDIS_HOST ?= 127.0.0.1
TEST_LEDGE_REDIS_PORT ?= 6379
TEST_LEDGE_REDIS_DATABASE ?= 2
TEST_LEDGE_REDIS_QLESS_DATABASE ?= 3

TEST_NGINX_HOST ?= 127.0.0.1

# Command line arguments for ledge tests
TEST_LEDGE_REDIS_VARS = PATH=$(OPENRESTY_PREFIX)/nginx/sbin:$(PATH) \
TEST_LEDGE_REDIS_HOST=$(TEST_LEDGE_REDIS_HOST) \
TEST_LEDGE_REDIS_PORT=$(TEST_LEDGE_REDIS_PORT) \
TEST_LEDGE_REDIS_SOCKET=unix://$(TEST_LEDGE_REDIS_SOCKET) \
TEST_LEDGE_REDIS_DATABASE=$(TEST_LEDGE_REDIS_DATABASE) \
TEST_LEDGE_REDIS_QLESS_DATABASE=$(TEST_LEDGE_REDIS_QLESS_DATABASE) \
TEST_NGINX_HOST=$(TEST_NGINX_HOST) \
TEST_NGINX_NO_SHUFFLE=1

REDIS_CLI := redis-cli -h $(TEST_LEDGE_REDIS_HOST) -p $(TEST_LEDGE_REDIS_PORT)

###############################################################################
# Deprecated, ues docker copose to run Redis instead
###############################################################################
REDIS_CMD           = redis-server
SENTINEL_CMD        = $(REDIS_CMD) --sentinel

REDIS_SOCK          = /redis.sock
REDIS_PID           = /redis.pid
REDIS_LOG           = /redis.log
REDIS_PREFIX        = /tmp/redis-

# Overrideable ledge test variables
TEST_LEDGE_REDIS_PORTS              ?= 6379 6380

REDIS_FIRST_PORT                    := $(firstword $(TEST_LEDGE_REDIS_PORTS))
REDIS_SLAVE_ARG                     := --slaveof 127.0.0.1 $(REDIS_FIRST_PORT)

# Override ledge socket for running make test on its' own
# (make test TEST_LEDGE_REDIS_SOCKET=/path/to/sock.sock)
TEST_LEDGE_REDIS_SOCKET             ?= $(REDIS_PREFIX)$(REDIS_FIRST_PORT)$(REDIS_SOCK)

# Overrideable ledge + sentinel test variables
TEST_LEDGE_SENTINEL_PORTS           ?= 26379 26380 26381
TEST_LEDGE_SENTINEL_MASTER_NAME     ?= mymaster
TEST_LEDGE_SENTINEL_PROMOTION_TIME  ?= 20

# Command line arguments for ledge + sentinel tests
TEST_LEDGE_SENTINEL_VARS  = PATH=$(OPENRESTY_PREFIX)/nginx/sbin:$(PATH) \
TEST_LEDGE_SENTINEL_PORT=$(firstword $(TEST_LEDGE_SENTINEL_PORTS)) \
TEST_LEDGE_SENTINEL_MASTER_NAME=$(TEST_LEDGE_SENTINEL_MASTER_NAME) \
TEST_LEDGE_REDIS_DATABASE=$(TEST_LEDGE_REDIS_DATABASE) \
TEST_NGINX_NO_SHUFFLE=1

# Sentinel configuration can only be set by a config file
define TEST_LEDGE_SENTINEL_CONFIG
sentinel       monitor $(TEST_LEDGE_SENTINEL_MASTER_NAME) 127.0.0.1 $(REDIS_FIRST_PORT) 2
sentinel       down-after-milliseconds $(TEST_LEDGE_SENTINEL_MASTER_NAME) 2000
sentinel       failover-timeout $(TEST_LEDGE_SENTINEL_MASTER_NAME) 10000
sentinel       parallel-syncs $(TEST_LEDGE_SENTINEL_MASTER_NAME) 5
endef

export TEST_LEDGE_SENTINEL_CONFIG

SENTINEL_CONFIG_PREFIX = /tmp/sentinel



###############################################################################


PREFIX          ?= /usr/local
LUA_INCLUDE_DIR ?= $(PREFIX)/include
LUA_LIB_DIR     ?= $(PREFIX)/lib/lua/$(LUA_VERSION)
PROVE           ?= prove -I ../test-nginx/lib
INSTALL         ?= install

.PHONY: all install test test_all start_redis_instances stop_redis_instances \
	start_redis_instance stop_redis_instance cleanup_redis_instance flush_db \
	check_ports test_ledge test_sentinel coverage delete_sentinel_config check

all: ;

install: all
	$(INSTALL) -d $(DESTDIR)/$(LUA_LIB_DIR)/ledge
	$(INSTALL) lib/ledge/*.lua $(DESTDIR)/$(LUA_LIB_DIR)/ledge

test: test_ledge
test_all: start_redis_instances test_ledge test_sentinel stop_redis_instances


###############################################################################
# Deprecated, ues docker copose to run Redis instead
##############################################################################
start_redis_instances: check_ports
	@$(foreach port,$(TEST_LEDGE_REDIS_PORTS), \
		[[ "$(port)" != "$(REDIS_FIRST_PORT)" ]] && \
			SLAVE="$(REDIS_SLAVE_ARG)" || \
			SLAVE="" && \
		$(MAKE) start_redis_instance args="$$SLAVE" port=$(port) \
		prefix=$(REDIS_PREFIX)$(port) && \
	) true

	@$(foreach port,$(TEST_LEDGE_SENTINEL_PORTS), \
		echo "port $(port)" > "$(SENTINEL_CONFIG_PREFIX)-$(port).conf"; \
		echo "$$TEST_LEDGE_SENTINEL_CONFIG" >> "$(SENTINEL_CONFIG_PREFIX)-$(port).conf"; \
		$(MAKE) start_redis_instance \
		port=$(port) args="$(SENTINEL_CONFIG_PREFIX)-$(port).conf --sentinel" \
		prefix=$(REDIS_PREFIX)$(port) && \
	) true

stop_redis_instances: delete_sentinel_config
	-@$(foreach port,$(TEST_LEDGE_REDIS_PORTS) $(TEST_LEDGE_SENTINEL_PORTS), \
		$(MAKE) stop_redis_instance cleanup_redis_instance port=$(port) \
		prefix=$(REDIS_PREFIX)$(port) && \
	) true 2>&1 > /dev/null

start_redis_instance:
	-@echo "Starting redis on port $(port) with args: \"$(args)\""
	-@mkdir -p $(prefix)
	@$(REDIS_CMD) $(args) \
		--pidfile $(prefix)$(REDIS_PID) \
		--bind 127.0.0.1 --port $(port) \
		--unixsocket $(prefix)$(REDIS_SOCK) \
		--unixsocketperm 777 \
		--dir $(prefix) \
		--logfile $(prefix)$(REDIS_LOG) \
		--loglevel debug \
		--daemonize yes

stop_redis_instance:
	-@echo "Stopping redis on port $(port)"
	-@[[ -f "$(prefix)$(REDIS_PID)" ]] && kill -QUIT \
	`cat $(prefix)$(REDIS_PID)` 2>&1 > /dev/null || true

cleanup_redis_instance: stop_redis_instance
	-@echo "Cleaning up redis files in $(prefix)"
	-@rm -rf $(prefix)

delete_sentinel_config:
	-@echo "Cleaning up sentinel config files"
	-@rm -f $(SENTINEL_CONFIG_PREFIX)-*.conf

check_ports:
	-@echo "Checking ports $(REDIS_PORTS)"
	@$(foreach port,$(REDIS_PORTS),! lsof -i :$(port) &&) true 2>&1 > /dev/null
###############################################################################

releng:
	@util/lua-releng -eLs

flush_db:
	@$(REDIS_CLI) flushall

test_ledge: releng flush_db
	@$(TEST_LEDGE_REDIS_VARS) $(PROVE) $(TEST_FILE)
	-@echo "Qless errors:"
	@$(REDIS_CLI) -n $(TEST_LEDGE_REDIS_QLESS_DATABASE) llen ql:f:job-error

test_sentinel: releng flush_db
	$(TEST_LEDGE_SENTINEL_VARS) $(PROVE) $(SENTINEL_TEST_FILE)/01-master_up.t
	$(REDIS_CLI) shutdown
	$(TEST_LEDGE_SENTINEL_VARS) $(PROVE) $(SENTINEL_TEST_FILE)/02-master_down.t
	sleep $(TEST_LEDGE_SENTINEL_PROMOTION_TIME)
	$(TEST_LEDGE_SENTINEL_VARS) $(PROVE) $(SENTINEL_TEST_FILE)/03-slave_promoted.t

test_leak: releng flush_db
	$(TEST_LEDGE_REDIS_VARS) TEST_NGINX_CHECK_LEAK=1 $(PROVE) $(TEST_FILE)

coverage: releng flush_db
	@rm -f luacov.stats.out
	@$(TEST_LEDGE_REDIS_VARS) TEST_COVERAGE=1 $(PROVE) $(TEST_FILE)
	@luacov
	@tail -30 luacov.report.out
	-@echo "Qless errors:"
	@$(REDIS_CLI) -n $(TEST_LEDGE_REDIS_QLESS_DATABASE) llen ql:f:job-error

check:
	luacheck lib
