source 'https://rubygems.org'

git_source(:github) do |repo_name|
  repo_name = "#{repo_name}/#{repo_name}" unless repo_name.include?('/')
  "https://github.com/#{repo_name}.git"
end

# Bundle edge Rails instead: gem 'rails', github: 'rails/rails'
gem 'rails', '~> 7.2.0'
# Use postgresql as the database for Active Record
gem 'pg', '~> 1.5'
# Use Puma as the app server
gem 'puma', '~> 8.0'
# Build JSON APIs with ease. Read more: https://github.com/rails/jbuilder
gem 'jbuilder', '~> 2.15'
# Redis als gemeinsamer Cache aller Puma-Worker (config/environments/production.rb).
# NICHT fuer ActionCable -- die Anwendung nutzt keine Websockets, config/cable.yml
# ist ein unbenutzter Rails-Rest.
gem 'redis', '~> 5.4'
# connection_pool bewusst unter 3.0 halten: activesupport 7.2.3.2 ruft in
# ActiveSupport::Cache::RedisCacheStore#initialize noch
# `ConnectionPool.new(pool_options)` mit einem positionalen Hash auf, waehrend
# connection_pool 3.0 ausschliesslich Keyword-Argumente annimmt
# (`initialize(timeout:, size:, ...)`). Mit 3.0.2 stirbt der Store deshalb
# schon beim Erzeugen:
#   wrong number of arguments (given 1, expected 0) (ArgumentError)
#   activesupport-7.2.3.2/lib/active_support/cache/redis_cache_store.rb:153
# Nachgestellt am 12.09.2026. Verlangt wird die 3.x von niemandem --
# activesupport will >= 2.2.5, redis-client >= 0.
#
# Der Riegel kann weg, sobald activesupport >= 8.1.2 im Lockfile steht. NICHT
# schon mit Rails 8.0: Dort steht der positionale Aufruf unveraendert in
# Zeile 153, und auch 8.1.0/8.1.1 haben ihn (Zeile 163). Erst 8.1.2 schreibt
# ConnectionPool.new(**pool_options).
gem 'connection_pool', '~> 2.5'
# Use ActiveModel has_secure_password
gem 'bcrypt'

# Use Capistrano for deployment
# gem 'capistrano-rails', group: :development

gem 'rack-attack'

# Use Rack CORS for handling Cross-Origin Resource Sharing (CORS), making cross-origin AJAX possible
gem 'rack-cors'

gem 'jwt'

gem 'dotenv-rails'

group :development, :test do
  # Call 'byebug' anywhere in the code to stop execution and get a debugger console
  gem 'byebug', platforms: %i[mri mingw x64_mingw]

  gem 'rubocop'
  gem 'rubocop-rails'
  gem 'rubocop-rspec'

  gem 'guard'
  gem 'guard-rspec', require: false

  # Test-Daten als Factories statt YAML-Fixtures. Lizenz-/History-JSONB lässt
  # sich pro Test gezielter komponieren als statisch in fixtures/*.yml.
  gem 'factory_bot_rails'

  # N+1-Queries beim Entwickeln/Testen sichtbar machen (siehe Issue #26).
  # Aktivierung in config/environments/development.rb.
  gem 'bullet'
end

group :test do
  # OpenAPI-Schema-Validierung der API-Responses in Tests.
  # Spec liegt in docs/openapi/openapi.yml.
  gem 'committee-rails', '~> 0.7'
  gem 'simplecov', require: false

  # Auf der 5er-Linie halten: test_helper.rb nutzt `require 'minitest/mock'`,
  # das minitest 6 entfernt/verschiebt. Ohne Pin zieht bundler 6.0 → LoadError.
  gem 'minitest', '~> 5.27'
end

group :development do
  gem 'listen', '~> 3.8'
  # Spring speeds up development by keeping your application running in the background. Read more: https://github.com/rails/spring
  gem 'spring'
  gem 'spring-watcher-listen', '~> 2.1.0'
end

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem 'tzinfo-data', platforms: %i[mingw mswin x64_mingw jruby]

# xlsx export
gem 'xlsxtream'

# pdf rendering
gem 'wicked_pdf'
gem 'wkhtmltopdf-binary'

# 6.0 update
gem 'bootsnap'

gem 'sentry-rails'
gem 'sentry-ruby'

gem 'paper_trail', '~> 17.0'

# https://gist.github.com/kule/9425fb7d4c2a13e556ef
gem 'request_store'

# excel export
gem 'caxlsx'
gem 'caxlsx_rails'

# excel import
gem 'creek'

# calendar import
gem 'icalendar'

# active storage
gem 'image_processing', '>= 1.2'
gem 'ruby-vips', '~> 2.2' # libvips-Backend für ActiveStorage-Varianten (Logo-Verkleinerung)

gem 'letter_opener', groups: %i[development]
