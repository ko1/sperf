Gem::Specification.new do |spec|
  spec.name          = "sperf"
  spec.version       = "0.1.0"
  spec.authors       = ["Koichi Sasada"]
  spec.summary       = "Safepoint-based sampling performance profiler for Ruby"
  spec.description   = "A safepoint-based sampling performance profiler that uses thread CPU time deltas as weights to correct safepoint bias. Outputs pprof, collapsed stacks, or text report."
  spec.homepage      = "https://github.com/ko1/sperf"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 3.4.0"

  spec.files         = Dir["lib/**/*.rb", "ext/**/*.{c,h,rb}", "exe/*", "LICENSE", "README.md"]
  spec.bindir        = "exe"
  spec.executables   = ["sperf"]
  spec.extensions    = ["ext/sperf/extconf.rb"]
  spec.require_paths = ["lib"]

  spec.add_development_dependency "rake-compiler", "~> 1.2"
  spec.add_development_dependency "test-unit", "~> 3.6"
end
