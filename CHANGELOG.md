## Changelog

### v0.03 (26 Jun 2012)

* Feature: Added the `before_save` event.
* Feature: `Via` header now includes ledge version.
* Feature (#7): `Set-Cookie` is removed when `Cache-Control: no-cache="set-cookie"` is present.
* Feature (#8): `$cache_key` no longer required in nginx.conf.
* Feature (#8): New config option `cache_key_spec` for providing a table used to create cache keys.
* Feature (#9): `X-Cache` headers no longer sent for non-cacheable responses.
* Bugfix (#12): Fixed fatal error when `ledge.bind()` was not called at least once.
* Bugfix (#14): Fixed fatal error when `res.cacheable()` was true, but `res.ttl` was `0`.