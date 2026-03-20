srand(20260320)
call_counts = {"rw626" => 291572, "rw938" => 391800, "rw734" => 27335, "rw438" => 154897, "rw285" => 738041, "rw856" => 428246, "rw789" => 273349, "rw722" => 455581, "rw575" => 546697, "rw874" => 692482}
calls = []
call_counts.each { |name, count| count.times { calls << name } }
calls.shuffle!
calls.each { |name| SperfWorkload.send(name, 0) }
