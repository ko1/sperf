srand(20260320)
call_counts = {"rw570" => 565371, "rw650" => 438163, "rw471" => 141343, "rw817" => 593640, "rw72" => 699647, "rw800" => 565371, "rw790" => 127208, "rw725" => 522968, "rw458" => 325088, "rw575" => 21201}
calls = []
call_counts.each { |name, count| count.times { calls << name } }
calls.shuffle!
calls.each { |name| SperfWorkload.send(name, 0) }
