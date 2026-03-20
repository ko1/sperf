srand(20260320)
call_counts = {"rw963" => 131980, "rw331" => 791878, "rw459" => 162437, "rw203" => 558376, "rw437" => 213198, "rw631" => 487310, "rw883" => 40609, "rw218" => 944162, "rw170" => 101523, "rw300" => 568527}
calls = []
call_counts.each { |name, count| count.times { calls << name } }
calls.shuffle!
calls.each { |name| SperfWorkload.send(name, 0) }
