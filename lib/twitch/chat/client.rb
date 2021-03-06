module Twitch
  module Chat
    class Client
      MODERATOR_MESSAGES_COUNT = 100
      USER_MESSAGES_COUNT = 20
      TWITCH_PERIOD = 30.0

      attr_accessor :host, :port, :nickname, :password, :connection
      attr_reader :channel, :callbacks

      def initialize(options = {}, &blk)
        options.symbolize_keys!
        options = {
          host: 'irc.chat.twitch.tv',
          port: '6667',
          output: STDOUT
        }.merge!(options)

        @logger = Logger.new(options[:output]) if options[:output]

        @host = options[:host]
        @port = options[:port]
        @nickname = options[:nickname]
        @password = options[:password]
        @channel = Twitch::Chat::Channel.new(options[:channel]) if options[:channel]

        @messages_queue = []

        @connected = false
        @callbacks = {}

        check_attributes!

        if block_given?
          if blk.arity == 1
            yield self
          else
            instance_eval(&blk)
          end
        end

        self.on(:new_moderator) do |user|
          @channel.add_moderator(user)
        end

        self.on(:remove_moderator) do |user|
          @channel.remove_moderator(user)
        end

        self.on(:ping) do
          send_data("PONG :tmi.twitch.tv")
        end
      end

      def connect
        @connection ||= EventMachine::connect(@host, @port, Connection, self)
      end

      def connected?
        @connected
      end

      def on(callback, &blk)
        (@callbacks[callback.to_sym] ||= []) << blk
      end

      def trigger(event_name, *args)
        (@callbacks[event_name.to_sym] || []).each { |blk| blk.call(*args) }
      end

      def run!
        EM.epoll
        EventMachine.run do
          trap("TERM") { EM::stop }
          trap("INT")  { EM::stop }
          handle_message_queue
          connect
        end
      end

      def join(channel)
        @channel = Channel.new(channel)
        send_data "JOIN ##{@channel.name}"
      end

      def part(channel_name = nil)
        channel_name = channel_name || @channel.name
        send_data "PART ##{channel_name}"
        if channel_name.nil?
          @channel = nil
          @messages_queue = []
        end
      end

      def send_message(message)
        @messages_queue << message if @messages_queue.last != message
      end

      def ready
        @connected = true
        authenticate
        join(@channel.name) if @channel

        trigger(:connected)
      end

      def max_messages_count
        if @channel && @channel.moderators.include?(@nickname)
          MODERATOR_MESSAGES_COUNT
        else
          USER_MESSAGES_COUNT
        end
      end

      def message_delay
        TWITCH_PERIOD / max_messages_count
      end

      def disconnect
        trigger(:disconnect)
        @connection.close_connection
      end

      def receive_data(data)
        data.split(/\r?\n/).each do |message|
          @logger.debug(message)

          Twitch::Chat::Message.new(message).tap do |message|
            trigger(:raw, message)

            case message.type
              when :ping
                trigger(:ping)
              when :message
                trigger(:message, message)
              when :mode
                trigger(:mode, *message.params.last(2))

                if message.params[1] == '+o'
                  trigger(:new_moderator, message.params.last)
                elsif message.params[1] == '-o'
                  trigger(:remove_moderator, message.params.last)
                end
              when :slow_mode, :r9k_mode, :subscribers_mode, :slow_mode_off, :r9k_mode_off, :subscribers_mode_off
                trigger(message.type)
              when :subscribe
                trigger(:subscribe, message.params.last.split(' ').first)
              when :not_supported
                trigger(:not_supported, *message.params)
            end
          end
        end
      end

      def unbind(arg = nil)
        part if @channel
        trigger(:disconnect)
      end

    private

      def handle_message_queue
        EM.add_timer(message_delay) do
          if message = @messages_queue.pop
            send_data "PRIVMSG ##{@channel.name} :#{message}"
            @logger.debug("Sent message: PRIVMSG ##{@channel.name} :#{message}")
          end

          handle_message_queue
        end
      end

      def send_data(message)
        return false unless connected?

        message = message + "\n"
        connection.send_data(message)
      end

      def check_attributes!
        [:host, :port, :nickname, :password].each do |attribute|
          raise ArgumentError.new("#{attribute.capitalize} is not defined") if send(attribute).nil?
        end

        nil
      end

      def authenticate
        send_data "PASS #{password}"
        send_data "NICK #{nickname}"
        send_data "TWITCHCLIENT 3"
      end
    end
  end
end
