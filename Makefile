OPENRESTY_PREFIX = /usr/local/openresty-debug
TEST_FILE 		?= t
REDIS_CMD 		 = redis-server -

# Define variables used during testing 
TEST_LEDGE_REDIS_PORT 				?= 6379
TEST_LEDGE_REDIS_PREFIX 			?= /tmp/redis-server
TEST_LEDGE_REDIS_SOCKET 			?= $(TEST_LEDGE_REDIS_PREFIX).sock
TEST_LEDGE_REDIS_PIDFILE 			?= $(TEST_LEDGE_REDIS_PREFIX).pid
TEST_LEDGE_REDIS_CMD 				?= $(REDIS_CMD)
TEST_LEDGE_REDIS_DATABASE 			?= 1

TEST_LEDGE_SENTINEL_PORT 			?= 26379
TEST_LEDGE_SENTINEL_PREFIX 			?= /tmp/redis-server
TEST_LEDGE_SENTINEL_SOCKET 			?= $(TEST_LEDGE_SENTINEL_PREFIX).sock
TEST_LEDGE_SENTINEL_PIDFILE 		?= $(TEST_LEDGE_SENTINEL_PREFIX).pid
TEST_LEDGE_SENTINEL_CMD 			?= $(REDIS_CMD) --sentinel
TEST_LEDGE_SENTINEL_MASTER_NAME 	?= mymaster
TEST_LEDGE_SENTINEL_PROMOTION_TIME	?= 20

define TEST_LEDGE_REDIS_CONFIG
daemonize yes
pidfile        $(TEST_LEDGE_REDIS_PIDFILE)
logfile        $(TEST_LEDGE_REDIS_PREFIX).log
port           $(TEST_LEDGE_REDIS_PORT)
dir            $(TEST_LEDGE_REDIS_PREFIX)
unixsocket     $(TEST_LEDGE_REDIS_SOCKET)
unixsocketperm 777
endef

export TEST_LEDGE_REDIS_CONFIG 

REDIS_DIRS = $(TEST_LEDGE_REDIS_PREFIX)

PREFIX ?=          /usr/local
LUA_INCLUDE_DIR ?= $(PREFIX)/include
LUA_LIB_DIR ?=     $(PREFIX)/lib/lua/$(LUA_VERSION)
INSTALL ?= install

.PHONY: all install test start_redis_instances stop_redis_instances test_ledge test_sentinel

all: ;

install: all
	$(INSTALL) -d $(DESTDIR)/$(LUA_LIB_DIR)/ledge
	$(INSTALL) lib/ledge/*.lua $(DESTDIR)/$(LUA_LIB_DIR)/ledge

test: start_redis_instances 
	# Run test suite, and _always_ `make stop_redis_instances` - but exit with the status
	# of the test-make. 
	$(MAKE) test_ledge; STATUS=$$?; $(MAKE) stop_redis_instances; exit $$STATUS

start_redis_instances:
	@-mkdir -p $(REDIS_DIRS) 
	@echo "$$TEST_LEDGE_REDIS_CONFIG" | $(TEST_LEDGE_REDIS_CMD)
	@redis-cli -n $(TEST_LEDGE_REDIS_DATABASE) flushdb

stop_redis_instances:
	@kill -QUIT `cat $(TEST_LEDGE_REDIS_PIDFILE)`
	
test_ledge: 
	PATH=$(OPENRESTY_PREFIX)/nginx/sbin:$$PATH \
	TEST_LEDGE_REDIS_DATABASE=$(TEST_LEDGE_REDIS_DATABASE) \
	TEST_LEDGE_REDIS_SOCKET=$(TEST_LEDGE_REDIS_SOCKET) \
	TEST_NGINX_NO_SHUFFLE=1 \
	prove -I../test-nginx/lib $(TEST_FILE)

test_sentinel: start_redis_instances
	PATH=$(OPENRESTY_PREFIX)/nginx/sbin:$$PATH TEST_LEDGE_SENTINEL_PORT=$(TEST_LEDGE_SENTINEL_PORT) TEST_LEDGE_SENTINEL_MASTER_NAME=$(TEST_LEDGE_SENTINEL_MASTER_NAME) TEST_LEDGE_REDIS_DATABASE=$(TEST_LEDGE_REDIS_DATABASE) TEST_NGINX_NO_SHUFFLE=1 prove -I../test-nginx/lib t/sentinel/01-master_up.t
	redis-cli shutdown
	PATH=$(OPENRESTY_PREFIX)/nginx/sbin:$$PATH TEST_LEDGE_SENTINEL_PORT=$(TEST_LEDGE_SENTINEL_PORT) TEST_LEDGE_SENTINEL_MASTER_NAME=$(TEST_LEDGE_SENTINEL_MASTER_NAME) TEST_LEDGE_REDIS_DATABASE=$(TEST_LEDGE_REDIS_DATABASE) TEST_NGINX_NO_SHUFFLE=1 prove -I../test-nginx/lib t/sentinel/02-master_down.t
	sleep $(TEST_LEDGE_SENTINEL_PROMOTION_TIME)
	PATH=$(OPENRESTY_PREFIX)/nginx/sbin:$$PATH TEST_LEDGE_SENTINEL_PORT=$(TEST_LEDGE_SENTINEL_PORT) TEST_LEDGE_SENTINEL_MASTER_NAME=$(TEST_LEDGE_SENTINEL_MASTER_NAME) TEST_LEDGE_REDIS_DATABASE=$(TEST_LEDGE_REDIS_DATABASE) TEST_NGINX_NO_SHUFFLE=1 prove -I../test-nginx/lib t/sentinel/03-slave_promoted.t
