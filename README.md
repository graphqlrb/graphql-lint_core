# graphql-lint_core

Shared schema loading, operation validation, configuration, and diagnostics for the GraphQL Lint Suite. Each product gem installs this dependency automatically.

This gem requires Ruby 3.3 or later and graphql-ruby 2.5 or later in the 2.x series.

## Development

```sh
bundle install
bundle exec rake test spikes
bundle exec rake build
```

The version in `lib/graphql/lint_core/version.rb` is specific to this gem. The
release workflow publishes the package for its matching version tag through
RubyGems Trusted Publishing. Keep patch releases compatible with the Core APIs
used by product gems.

Licensed under the [MIT License](LICENSE.txt).
