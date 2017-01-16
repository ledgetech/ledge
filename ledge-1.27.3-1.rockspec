package = "ledge"
version = "1.27.3-1"
source = {
   url = "git://github.com/pintsized/ledge",
   tag = "v1.27.3"
}
description = {
   summary = "An ESI capable HTTP cache module for OpenResty",
   homepage = "https://github.com/pintsized/ledge",
   license = "2-clause BSD",
   maintainer = "James Hurst <james@pintsized.co.uk>"
}
dependencies = {
   "lua ~> 5.1",
   "lua-resty-http >= 0.10",
   "lua-resty-redis-connector >= 0.03",
   "lua-resty-qless >= 0.08",
   "lua-resty-cookie >= 0.1",
   "lua-ffi-zlib >= 0.1"
}
build = {
   type = "builtin",
   modules = {
      ["ledge.esi"] = "lib/ledge/esi.lua",
      ["ledge.header_util"] = "lib/ledge/header_util.lua",
      ["ledge.jobs.collect_entity"] = "lib/ledge/jobs/collect_entity.lua",
      ["ledge.jobs.purge"] = "lib/ledge/jobs/purge.lua",
      ["ledge.jobs.revalidate"] = "lib/ledge/jobs/revalidate.lua",
      ["ledge.ledge"] = "lib/ledge/ledge.lua",
      ["ledge.response"] = "lib/ledge/response.lua"
   }
}
