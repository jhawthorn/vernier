# Vernier

Experimental Ruby profiling tool

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'vernier'
```

And then execute:

    $ bundle install

Or install it yourself as:

    $ gem install vernier

## Usage

Record a flamegraph of all **retained** allocations from requiring `irb`.

```
ruby -r vernier -e 'Vernier.trace_retained { require "irb" }'
```

The output can then be viewed in speedscope or other flamegraph tools

<img width="1082" alt="Screen Shot 2022-04-26 at 8 11 19 PM" src="https://user-images.githubusercontent.com/131752/165440422-3a11f5cc-3018-4455-8918-887c2afa6d6e.png">


## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake test` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/jhawthorn/vernier. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [code of conduct](https://github.com/jhawthorn/vernier/blob/main/CODE_OF_CONDUCT.md).

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the Vernier project's codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/jhawthorn/vernier/blob/main/CODE_OF_CONDUCT.md).
