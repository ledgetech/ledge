OPENRESTY_PREFIX=/usr/local/openresty-debug
TEST_LEDGE_REDIS_DATABASE=1
TEST_FILE ?= t

PREFIX ?=          /usr/local
LUA_INCLUDE_DIR ?= $(PREFIX)/include
LUA_LIB_DIR ?=     $(PREFIX)/lib/lua/$(LUA_VERSION)
INSTALL ?= install

.PHONY: all test install

all: ;

install: all
	$(INSTALL) -d $(DESTDIR)/$(LUA_LIB_DIR)/ledge
	$(INSTALL) lib/ledge/*.lua $(DESTDIR)/$(LUA_LIB_DIR)/ledge

test: all
	redis-cli -n $(TEST_LEDGE_REDIS_DATABASE) flushdb
	PATH=$(OPENRESTY_PREFIX)/nginx/sbin:$$PATH TEST_LEDGE_REDIS_DATABASE=$(TEST_LEDGE_REDIS_DATABASE) TEST_NGINX_NO_SHUFFLE=1 prove -I../test-nginx/lib -r $(TEST_FILE)
