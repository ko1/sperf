srand(20260320)
call_counts = {"rw127" => 597015, "rw715" => 656716, "rw755" => 14925, "rw334" => 283582, "rw380" => 544776, "rw28" => 22388, "rw570" => 694030, "rw362" => 679104, "rw284" => 74627, "rw474" => 432837}
calls = []
call_counts.each { |name, count| count.times { calls << name } }
calls.shuffle!
calls.each { |name| SperfWorkload.send(name, 0) }
