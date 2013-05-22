SHELL := /bin/bash # Cheat by using bash :)

OPENRESTY_PREFIX    = /usr/local/openresty-debug
TEST_FILE          ?= t
REDIS_CMD           = redis-server
SENTINEL_CMD        = $(REDIS_CMD) --sentinel

REDIS_SOCK          = /redis.sock
REDIS_PID           = /redis.pid
REDIS_LOG           = /redis.log

# Define variables used during testing 
TEST_LEDGE_REDIS_PORTS              ?= 6379 6380
TEST_LEDGE_REDIS_DATABASE           ?= 1

TEST_LEDGE_SENTINEL_PORTS           ?= 6381 6382 6383
TEST_LEDGE_SENTINEL_CMD             ?= $(REDIS_CMD) --sentinel
TEST_LEDGE_SENTINEL_MASTER_NAME     ?= mymaster
TEST_LEDGE_SENTINEL_PROMOTION_TIME  ?= 20

REDIS_FIRST_PORT         := $(firstword $(TEST_LEDGE_REDIS_PORTS))
REDIS_SLAVE_ARG           = --slaveof 127.0.0.1 $(REDIS_FIRST_PORT)

REDIS_CLI                 = redis-cli -p $(REDIS_FIRST_PORT) -n $(TEST_LEDGE_REDIS_DATABASE)

TEST_LEDGE_REDIS_VARS = PATH=$(OPENRESTY_PREFIX)/nginx/sbin:$(PATH) \
TEST_LEDGE_REDIS_SOCKET=unix://$(REDIS_PREFIX)$(REDIS_FIRST_PORT)$(REDIS_SOCK) \
TEST_LEDGE_REDIS_DATABASE=$(TEST_LEDGE_REDIS_DATABASE) \
TEST_NGINX_NO_SHUFFLE=1

TEST_LEDGE_SENTINEL_VARS = PATH=$(OPENRESTY_PREFIX)/nginx/sbin:$(PATH) \
TEST_LEDGE_SENTINEL_PORT=$(firstword $(TEST_LEDGE_SENTINEL_PORTS)) \
TEST_LEDGE_SENTINEL_MASTER_NAME=$(TEST_LEDGE_SENTINEL_MASTER_NAME) \
TEST_LEDGE_REDIS_DATABASE=$(TEST_LEDGE_REDIS_DATABASE) \
TEST_NGINX_NO_SHUFFLE=1

# Sentinel configuration can only be set by a config file
define TEST_LEDGE_SENTINEL_CONFIG
sentinel       monitor $(TEST_LEDGE_SENTINEL_MASTER_NAME) 127.0.0.1 $(REDIS_FIRST_PORT) 2
sentinel       down-after-milliseconds $(TEST_LEDGE_SENTINEL_MASTER_NAME) 2000
sentinel       failover-timeout $(TEST_LEDGE_SENTINEL_MASTER_NAME) 10000
sentinel       can-failover $(TEST_LEDGE_SENTINEL_MASTER_NAME) yes
sentinel       parallel-syncs $(TEST_LEDGE_SENTINEL_MASTER_NAME) 5
endef

export TEST_LEDGE_SENTINEL_CONFIG

SENTINEL_CONFIG_FILE = /tmp/sentinel-config

REDIS_PREFIX     = /tmp/redis-

PREFIX          ?= /usr/local
LUA_INCLUDE_DIR ?= $(PREFIX)/include
LUA_LIB_DIR     ?= $(PREFIX)/lib/lua/$(LUA_VERSION)
PROVE           ?= prove -I ../test-nginx/lib
INSTALL         ?= install

.PHONY: all install test check_ports sentinel_config start_redis_instances start_redis_instance stop_redis_instances stop_redis_instance test_ledge test_sentinel

all: ;

install: all
	$(INSTALL) -d $(DESTDIR)/$(LUA_LIB_DIR)/ledge
	$(INSTALL) lib/ledge/*.lua $(DESTDIR)/$(LUA_LIB_DIR)/ledge

test: test_ledge test_sentinel

start_redis_instances: check_ports sentinel_config
	@$(foreach port,$(TEST_LEDGE_REDIS_PORTS), \
		[[ "$(port)" != "$(REDIS_FIRST_PORT)" ]] && \
			SLAVE="$(REDIS_SLAVE_ARG)" || \
			SLAVE="" && \
		$(MAKE) start_redis_instance args="$$SLAVE" port=$(port) prefix=$(REDIS_PREFIX)$(port) && \
	) true

	@$(foreach port,$(TEST_LEDGE_SENTINEL_PORTS), \
		$(MAKE) start_redis_instance \
		port=$(port) args='$(SENTINEL_CONFIG_FILE) --sentinel' prefix=$(REDIS_PREFIX)$(port) && \
	) true

stop_redis_instances: 
	-@$(foreach port,$(TEST_LEDGE_REDIS_PORTS) $(TEST_LEDGE_SENTINEL_PORTS), \
		$(MAKE) stop_redis_instance prefix=$(REDIS_PREFIX)$(port) && \
	) true 2>&1 > /dev/null


start_redis_instance:
	-@mkdir -p $(prefix)
	$(REDIS_CMD) $(args) \
		--pidfile $(prefix)$(REDIS_PID) \
		--bind 127.0.0.1 --port $(port) \
		--unixsocket $(prefix)$(REDIS_SOCK) \
		--unixsocketperm 777 \
		--dir $(prefix) \
		--logfile $(prefix)$(REDIS_LOG) \
		--loglevel debug \
		--daemonize yes

stop_redis_instance:
	-@kill -QUIT `cat $(prefix)$(REDIS_PID)` 2>&1 > /dev/null

flush_db:
	$(REDIS_CLI) flushdb

sentinel_config:
	echo "$$TEST_LEDGE_SENTINEL_CONFIG" > $(SENTINEL_CONFIG_FILE)

check_ports:
	@$(foreach port,$(REDIS_PORTS),! lsof -i :$(port) &&) true 2>&1 > /dev/null

test_ledge: flush_db
	$(TEST_LEDGE_REDIS_VARS) $(PROVE) $(TEST_FILE)

test_sentinel: flush_db
	$(TEST_LEDGE_SENTINEL_VARS) $(PROVE) t/sentinel/01-master_up.t
	$(REDIS_CLI) shutdown
	$(TEST_LEDGE_SENTINEL_VARS) $(PROVE) t/sentinel/02-master_down.t
	sleep $(TEST_LEDGE_SENTINEL_PROMOTION_TIME)
	$(TEST_LEDGE_SENTINEL_VARS) $(PROVE) t/sentinel/03-slave_promoted.t
