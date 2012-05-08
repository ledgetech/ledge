OPENRESTY_PREFIX=/usr/local/openresty-debug

PREFIX ?=          /usr/local
LUA_INCLUDE_DIR ?= $(PREFIX)/include
LUA_LIB_DIR ?=     $(PREFIX)/lib/lua/$(LUA_VERSION)
INSTALL ?= install

.PHONY: all test install

all: ;

install: all
	$(INSTALL) -d $(DESTDIR)/$(LUA_LIB_DIR)/ledge
	$(INSTALL) -d $(DESTDIR)/$(LUA_LIB_DIR)/ledge/lib
	$(INSTALL) -d $(DESTDIR)/$(LUA_LIB_DIR)/ledge/conf
	$(INSTALL) lib/*.lua $(DESTDIR)/$(LUA_LIB_DIR)/ledge/lib
	$(INSTALL) conf/*.lua $(DESTDIR)/$(LUA_LIB_DIR)/ledge/conf

test: all
	PATH=$(OPENRESTY_PREFIX)/nginx/sbin:$$PATH prove -I../test-nginx/lib -r t

