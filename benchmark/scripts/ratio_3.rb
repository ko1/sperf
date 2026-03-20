srand(20260320)
call_counts = {"rw676" => 384342, "rw766" => 661922, "rw982" => 270463, "rw600" => 512456, "rw713" => 277580, "rw344" => 135231, "rw742" => 697509, "rw455" => 348754, "rw425" => 64057, "rw995" => 647686}
calls = []
call_counts.each { |name, count| count.times { calls << name } }
calls.shuffle!
calls.each { |name| SperfWorkload.send(name, 0) }
