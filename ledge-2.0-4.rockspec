package = "ledge"
version = "2.0-4"
source = {
   url = "git://github.com/pintsized/ledge",
   tag = "v2.0.4"
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
     ["ledge.jobs.collect_entity"] = "lib/ledge/jobs/collect_entity.lua",
     ["ledge.jobs.purge"] = "lib/ledge/jobs/purge.lua",
     ["ledge.jobs.revalidate"] = "lib/ledge/jobs/revalidate.lua",
     ["ledge.stale"] = "lib/ledge/stale.lua",
     ["ledge.esi"] = "lib/ledge/esi.lua",
     ["ledge.range"] = "lib/ledge/range.lua",
     ["ledge.background"] = "lib/ledge/background.lua",
     ["ledge.respone"] = "lib/ledge/response.lua",
     ["ledge.request"] = "lib/ledge/request.lua",
     ["ledge.purge"] = "lib/ledge/purge.lua",
     ["ledge.gzip"] = "lib/ledge/gzip.lua",
     ["ledge.state_machine"] = "lib/ledge/state_machine.lua",
     ["ledge.storage.redis"] = "lib/ledge/storage/redis.lua",
     ["ledge.state_machine.pre_transitions"] = "lib/ledge/state_machine/pre_transitions.lua",
     ["ledge.state_machine.actions"] = "lib/ledge/state_machine/actions.lua",
     ["ledge.state_machine.events"] = "lib/ledge/state_machine/events.lua",
     ["ledge.state_machine.states"] = "lib/ledge/state_machine/states.lua",
     ["ledge.worker"] = "lib/ledge/worker.lua",
     ["ledge.validation"] = "lib/ledge/validation.lua",
     ["ledge.esi.tag_parser"] = "lib/ledge/esi/tag_parser.lua",
     ["ledge.esi.processor"] = "lib/ledge/esi/processor_1_0.lua",
     ["ledge.hader_util"] = "lib/ledge/header_util.lua",
     ["ledge.handler"] = "lib/ledge/handler.lua",
     ["ledge.util"] = "lib/ledge/util.lua",
     ["ledge.collapse"] = "lib/ledge/collapse.lua",
     ["ledge"] = "lib/ledge.lua"
   }
}
