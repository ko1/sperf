srand(20260320)
call_counts = {"rw266" => 68522, "rw426" => 51392, "rw747" => 736617, "rw50" => 428266, "rw641" => 342612, "rw765" => 197002, "rw630" => 248394, "rw844" => 616702, "rw504" => 702355, "rw605" => 608138}
calls = []
call_counts.each { |name, count| count.times { calls << name } }
calls.shuffle!
calls.each { |name| SperfWorkload.send(name, 0) }
