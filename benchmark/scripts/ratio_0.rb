srand(20260320)
call_counts = {"rw826" => 415584, "rw815" => 164502, "rw650" => 614719, "rw801" => 424242, "rw953" => 683983, "rw802" => 545455, "rw579" => 233766, "rw210" => 519481, "rw271" => 60606, "rw627" => 337662}
calls = []
call_counts.each { |name, count| count.times { calls << name } }
calls.shuffle!
calls.each { |name| SperfWorkload.send(name, 0) }
