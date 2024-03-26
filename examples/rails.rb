require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'
  rails_version = ENV["RAILS"]
  case rails_version
  when nil
    gem "rails"
  when "edge", "main"
    gem "rails", github: "rails/rails"
  when /\//
    gem "rails", path: rails_version
  else
    gem "rails", rails_version
  end
  gem "sqlite3"
  gem "vernier", path: "#{__dir__}/.."
end

require "action_controller"
require "action_view"
require "active_record"
require "rails"

ENV["RAILS_ENV"] = "production"

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
class MyApp < Rails::Application
  config.load_defaults 7.0

  config.eager_load = true
  config.cache_classes = true
  config.hosts << ->(_){ true }
  config.secret_key_base = SecureRandom.hex
  config.consider_all_requests_local = true
  config.public_file_server.enabled = false
  config.cache_store = :null_store
  config.log_level = :warn
  config.enable_site_error_reporting = false

  logger           = ActiveSupport::Logger.new(STDOUT)
  logger.formatter = config.log_formatter
  config.logger    = ActiveSupport::TaggedLogging.new(logger)

  routes.append do
    root to: "home#show"
  end

  MyApp.initialize!
end

def silence(stream=STDOUT)
  old = stream.dup
  stream.reopen IO::NULL
  yield
  stream.reopen(old)
  old.dup
end

silence do
  ActiveRecord::Schema.define do
    create_table :users, force: true do |t|
      t.string :login
    end
    create_table :posts, force: true do |t|
      t.belongs_to :user
      t.string :title
      t.text :body
      t.integer :likes
    end
    create_table :comments, force: true do |t|
      t.belongs_to :user
      t.belongs_to :post
      t.string :title
      t.text :body
      t.datetime :posted_at
    end
  end
end

class User < ActiveRecord::Base
end

class Post < ActiveRecord::Base
  has_many :comments
  belongs_to :user
end

class Comment < ActiveRecord::Base
  belongs_to :post
  belongs_to :user
end

users = 0.upto(100).map do |i|
  User.create!(login: "user#{i}")
end
0.upto(100) do |i|
  post = Post.create!(title: "Post number #{i}", body: "blog " * 50, likes: ((i * 1337) % 30), user: users.sample)
  5.times do
    post.comments.create!(post: post, title: "nice post!", body: "keep it up!", posted_at: Time.now, user: users.sample)
  end
end

class HomeController < ActionController::Base
  def show
    posts = Post.order(likes: :desc).includes(:user, comments: :user).first(10)
    render json: posts, include: [:user, comments: { include: :user } ]
  end
end

app = Rails.application
env = Rack::MockRequest.env_for("http://example.org/")
make_request = -> () do
  status, headers, body = app.call(env)
  body.close if body.respond_to?(:close)
  if status
  end
  body = body.each.to_a.join("")
  raise body if status != 200
  [status, headers, body]
end

# warm up
make_request.call

Vernier.trace(out: "rails.json", hooks: [:rails], allocation_sample_rate: 100) do |collector|
  1000.times do
    make_request.call
  end
end
