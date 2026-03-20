srand(20260320)
call_counts = {"rw105" => 243187, "rw424" => 587002, "rw425" => 209644, "rw485" => 561845, "rw990" => 301887, "rw604" => 58700, "rw910" => 436059, "rw864" => 360587, "rw772" => 503145, "rw262" => 737944}
calls = []
call_counts.each { |name, count| count.times { calls << name } }
calls.shuffle!
calls.each { |name| SperfWorkload.send(name, 0) }
