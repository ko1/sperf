srand(20260320)
call_counts = {"rw136" => 407484, "rw428" => 332640, "rw726" => 773389, "rw289" => 174636, "rw488" => 490644, "rw730" => 440748, "rw803" => 207900, "rw469" => 49896, "rw805" => 582121, "rw387" => 540542}
calls = []
call_counts.each { |name, count| count.times { calls << name } }
calls.shuffle!
calls.each { |name| SperfWorkload.send(name, 0) }
