## Changelog

### v0.08 (20 August 2013)

* Feature (#52): Support for Redis sentinel
* Feature (#67): Handling aborted connections
* Feature (#82): Support for serving stale content if the origin errors (stale-if-error)
* Bugfix (#65): 304 responses should include other headers (cache control etc)
* Bugfix (#66): Serving stale with ORIGIN_MODE_BYPASS generates header errors
* Bugfix (#69): Ledge doesn't honour the no-store request cache control directive
* Bugfix (#68): Error when specifying only redis_socket in redis_hosts
* Bugfix (#71): Ledge should add a Warning header when in BYPASS (and AVOID) mode
* Bugfix: Allow multiple ESI var replacements within other ESI tag
* Bugfix: (#78): Always read the request body before fetching from the origin (For compatibility with Openresty 1.4.1.1)
* Numerous improvements to the Travis CI builds to support testing Sentinel.

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
