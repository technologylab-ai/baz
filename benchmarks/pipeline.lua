-- wrk 4.2.0: cache request bytes once; no per-response Lua in timed runs.
-- Pattern follows wg/wrk a211dd5a7050b1f9e8a9870b95513060e72ac4a0/scripts/pipeline.lua.
init = function(args)
  local depth = tonumber(args[1])
  assert(depth == 1 or depth == 16 or depth == 32 or depth == 64 or depth == 128)
  local requests = {}
  for i = 1, depth do requests[i] = wrk.format() end
  request_bytes = table.concat(requests)
end
request = function() return request_bytes end
done = function(summary, latency, requests)
  io.write(string.format('RESULT {"requests":%.0f,"duration_us":%.0f,"bytes":%.0f,' ..
    '"connect_errors":%.0f,"read_errors":%.0f,"write_errors":%.0f,' ..
    '"status_errors":%.0f,"timeout_errors":%.0f,"latency_mean_us":%.3f,' ..
    '"latency_p50_us":%.3f,"latency_p99_us":%.3f,"latency_max_us":%.3f}\n',
    summary.requests, summary.duration, summary.bytes,
    summary.errors.connect, summary.errors.read, summary.errors.write,
    summary.errors.status, summary.errors.timeout, latency.mean,
    latency:percentile(50), latency:percentile(99), latency.max))
end
