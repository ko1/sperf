srand(20260320)
call_counts = {"rw808" => 302405, "rw348" => 34364, "rw662" => 171821, "rw157" => 384880, "rw987" => 295533, "rw812" => 460481, "rw34" => 556701, "rw904" => 618557, "rw558" => 536082, "rw413" => 639176}
calls = []
call_counts.each { |name, count| count.times { calls << name } }
calls.shuffle!
calls.each { |name| SperfWorkload.send(name, 0) }
