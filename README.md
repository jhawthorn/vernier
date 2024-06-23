# Vernier

Next-generation Ruby 3.2.1+ sampling profiler. Tracks multiple threads, GVL activity, GC pauses, idle time, and more.

<img width="500" alt="Screenshot 2024-02-29 at 22 47 43" src="https://github.com/jhawthorn/vernier/assets/131752/aa995a41-d74f-405f-8ada-2522dd72c2c8">

## Examples

[Livestreamed demo: Pairin' with Aaron (YouTube)](https://www.youtube.com/watch?v=9nvX3OHykGQ#t=27m43)

Sidekiq jobs from Mastodon (time, threaded)
: https://share.firefox.dev/44jZRf3

Puma web requests from Mastodon (time, threaded)
: https://share.firefox.dev/48FOTnF

Rails benchmark - lobste.rs (time)
: https://share.firefox.dev/3Ld89id

`require "irb"` (retained memory)
: https://share.firefox.dev/3DhLsFa

## Installation

Vernier requires Ruby version 3.2.1 or greater

```ruby
gem "vernier", "~> 1.0"
```

## Usage

The output can be viewed in the web app at https://vernier.prof or locally using the [`profile-viewer` gem](https://github.com/tenderlove/profiler/tree/ruby) (both are lightly customized versions of the firefox profiler frontend, which profiles are also compatible with).

- **Flame Graph**: Shows proportionally how much time is spent within particular stack frames. Frames are grouped together, which means that x-axis / left-to-right order is not meaningful.
- **Stack Chart**: Shows the stack at each sample with the x-axis representing time and can be read left-to-right.


### Time


#### Command line

The easiest way to record a program or script is via the CLI

```
$ vernier run -- ruby -e 'sleep 1'
starting profiler with interval 500
#<Vernier::Result 1.001589 seconds, 1 threads, 2002 samples, 1 unique>
written to /tmp/profile20240328-82441-gkzffc.vernier.json
```

#### Block of code

``` ruby
Vernier.profile(out: "time_profile.json") do
  some_slow_method
end
```

Alternatively you can use the aliases `Vernier.run` and `Vernier.trace`.

#### Start and stop

```ruby
Vernier.start_profile(out: "time_profile.json")

some_slow_method

# some other file

some_other_slow_method

Vernier.stop_profile
```

### Retained memory

#### Block of code

Record a flamegraph of all **retained** allocations from loading `irb`.

```
ruby -r vernier -e 'Vernier.trace_retained(out: "irb_profile.json") { require "irb" }'
```

Retained-memory flamegraphs must be interpreted a little differently than a typical profiling flamegraph. In a retained-memory flamegraph, the x-axis represents a proportion of memory in bytes,  _not time or samples_ The topmost boxes on the y-axis represent the retained objects, with their stacktrace below; their width represents the percentage of overall retained memory each object occupies.

### Options

Option | Description
:- | :-
`mode` | The sampling mode to use. One of `:wall`, `:retained` or `:custom`. Default is `:wall`.
`out` | The file to write the profile to.
`interval` | The sampling interval in microseconds. Default is `500`. Only available in `:wall` mode.
`allocation_sample_rate` | The allocation sampling interval in number of allocations. Default is `0` (disabled). Only available in `:wall` mode.
`gc` | Initiate a full and immediate garbage collection cycle before profiling. Default is `true`. Only available in `:retained` mode.

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
