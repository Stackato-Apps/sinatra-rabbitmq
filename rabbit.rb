require 'rubygems'
require 'sinatra'
require 'erb'
require 'cgi'

require 'bunny'
require 'json'

enable :sessions
set :show_exceptions, true

# Extract the connection string for the rabbitmq service from the
# service information provided by Cloud Foundry in an environment
# variable.
def amqp_url
  if not ENV['VCAP_SERVICES']
    return {
      :host => "localhost",
      :port => 5672,
      :username => "guest",
      :password => "guest",
      :vhost => "/",
    }
  end

  services = JSON.parse(ENV['VCAP_SERVICES'], :symbolize_names => true)
  url = services.values.map do |srvs|
    srvs.map do |srv|
      if srv[:label] =~ /^rabbitmq-/
        srv[:credentials]
        srv[:credentials][:heartbeat] = 20
        return srv[:credentials]
      else
        []
      end
    end
  end.flatten!.first
end

# Opens a client connection to the RabbitMQ service, if one isn't
# already open.  This is a class method because a new instance of
# the controller class will be created upon each request.  But AMQP
# connections can be long-lived, so we would like to re-use the
# connection across many requests.
def client
  unless $client
    u = amqp_url
    conn = Bunny.new(u)
    conn.start
    $client = conn.create_channel

    # We only want to accept one un-acked message
    $client.prefetch(1)
  end
  $client
end

# Return the "nameless exchange", pre-defined by AMQP as a means to
# send messages to specific queues.  Again, we use a class method to
# share this across requests.
def nameless_exchange
  $nameless_exchange ||= client.default_exchange
end

# Return a queue named "messages".  This will create the queue on
# the server, if it did not already exist.  Again, we use a class
# method to share this across requests.
def messages_queue
  $messages_queue ||= client.queue("messages", :durable => true, :auto_delete => false)
end

def take_session key
  res = session[key]
  session[key] = nil
  res
end

get '/' do
  @published = take_session(:published)
  @got = take_session(:got)
  erb :index
end

post '/publish' do
  # Send the message from the form's input box to the "messages"
  # queue, via the nameless exchange.  The name of the queue to
  # publish to is specified in the routing key.
  nameless_exchange.publish params[:message], :routing_key => messages_queue.name
  # Notify the user that we published.
  session[:published] = true
  redirect to('/')
end

post '/get' do
  session[:got] = :queue_empty
  _, _, payload = messages_queue.pop
  session[:got] = payload
  redirect to('/')
end
