# Vernier

Experimental next-generation Ruby sampling profiler. Tracks multiple threads, GVL activity, GC pauses, idle time, and more.

## Installation

```ruby
gem 'vernier'
```

## Usage

### Retained memory

Record a flamegraph of all **retained** allocations from loading `irb`.

```
ruby -r vernier -e 'Vernier.trace_retained(out: "irb_profile.json") { require "irb" }'
```

The output can then be viewed in the [Firefox Profiler (demo)](https://share.firefox.dev/3DhLsFa)

![Screenshot 2023-07-16 at 21-06-19 Ruby_Vernier – 1970-01-01 12 00 00 a m  UTC – Firefox Profiler](https://github.com/jhawthorn/vernier/assets/131752/9ca0b593-70fb-4c8b-aed9-cb33e0e0bc06)

### Time

```
Vernier.trace(out: "time_profile.json") { some_slow_method }
```

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake test` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/jhawthorn/vernier. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [code of conduct](https://github.com/jhawthorn/vernier/blob/main/CODE_OF_CONDUCT.md).

### Resources

* https://profiler.firefox.com/docs/#/
* https://github.com/firefox-devtools/profiler/tree/main/docs-developer
* https://github.com/tmm1/stackprof
* https://github.com/ruby/ruby/pull/5500

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the Vernier project's codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/jhawthorn/vernier/blob/main/CODE_OF_CONDUCT.md).
