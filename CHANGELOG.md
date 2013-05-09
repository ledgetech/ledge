## Changelog

### v0.07 (9 May 2013)

Numerous bug fixes, improved tests and feature implementations over the last 7 months. I promise to do more tagging in future! Here's a summary:

* Major refactor adding state-machine-like control to select code paths.
* Collapsed forwarding.
* ESI parser.
* Serving stale content.
* PURGE requests.
* Background revalidation.
* Redis authentication (thanks @jaakkos).
* Major fixes to revalidation logic.
* Avoid proxying with unknown HTTP methods.
* Travis builds.
* Lots more tests.
* Probably more that I've forgotten.

Thanks to @hamishforbes and @benagricola for numerous patches and tests.

### v0.06 (30 Oct 2012)

* Refactor: Complete code base refactor and new usage syntax. Too many changes to list.
* Feature (#26): Age header calculation.
* Feature (#30): Revalidation (end-to-end specific and unspecified).
* Feature (#24): Offline mode now throws a 503 when necessary.
* Feature: More complete request cache acceptance / response cacheability criteria.
* Feature (#27): Hop-by-hop headers no longer cached.
* Feature: ESI processer.

### v0.05 (no tag)

### v0.04 (20 Jul 2012)

* Feature: Offline / maintenance modes.
* Feature (#23): Added support for `max-age` / `s-maxage`.
* Refactor (#11): Config mechanism santised and refactored.
* Feature: Added support for `init_by_lua` using `ledge.gset()`.
* Bugfix (#19): Cache items are now fully removed when updated.
* Bugfix (#17): Via header now shows the server name (rather than host name).
* Feature (#7): Headers in the form `Cache-Control: no-cache|no-store|private=FIELDNAME` are now honoured.
* Feature: Redis data is now stored atomically.

### v0.03 (26 Jun 2012)

* Feature: Added the `before_save` event.
* Feature: `Via` header now includes ledge version.
* Feature (#7): `Set-Cookie` is removed when `Cache-Control: no-cache="set-cookie"` is present.
* Feature (#8): `$cache_key` no longer required in nginx.conf.
* Feature (#8): New config option `cache_key_spec` for providing a table used to create cache keys.
* Feature (#9): `X-Cache` headers no longer sent for non-cacheable responses.
* Bugfix (#12): Fixed fatal error when `ledge.bind()` was not called at least once.
* Bugfix (#14): Fixed fatal error when `res.cacheable()` was true, but `res.ttl` was `0`.
