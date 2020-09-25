# typed: true
# frozen_string_literal: true

require 'socket'
require 'securerandom'
require 'sentry/interface'
require 'sentry/backtrace'
require 'sentry/utils/deep_merge'

module Sentry
  class Event
    extend T::Sig
    # See Sentry server default limits at
    # https://github.com/getsentry/sentry/blob/master/src/sentry/conf/server.py
    MAX_MESSAGE_SIZE_IN_BYTES = 1024 * 8
    REQUIRED_OPTION_KEYS = [:configuration].freeze

    SDK = { "name" => "sentry-ruby", "version" => Sentry::VERSION }.freeze

    attr_accessor :id, :logger, :transaction, :server_name, :release, :modules,
                  :extra, :tags, :context, :configuration, :checksum,
                  :fingerprint, :environment, :server_os, :runtime,
                  :breadcrumbs, :user, :backtrace, :platform, :sdk
    alias event_id id

    attr_reader :level, :timestamp, :time_spent

    sig {
      params(
        configuration: Configuration,
        message: T.nilable(String),
        user: T::Hash[Symbol, T.untyped],
        extra: T::Hash[Symbol, T.untyped],
        tags: T::Hash[Symbol, T.untyped],
        backtrace: T::Array[String],
        level: T.any(Symbol, String),
        checksum: T.nilable(String),
        fingerprint: T::Array[String],
        server_name: T.nilable(String),
        release: T.nilable(String),
        environment: T.nilable(String)
      ).void
    }
    def initialize(
      configuration:,
      message: nil,
      user: {}, extra: {}, tags: {},
      backtrace: [], level: :error, checksum: nil, fingerprint: [],
      server_name: nil, release: nil, environment: nil
    )
      # this needs to go first because some setters rely on configuration
      @configuration = configuration

      # Set some simple default values
      @id            = SecureRandom.uuid.delete("-")
      @timestamp     = Time.now.utc
      @platform      = :ruby
      @sdk           = SDK

      # Set some attributes with empty hashes to allow merging
      @interfaces        = {}

      @user          = user
      @extra         = extra
      @tags          = configuration.tags.merge(tags)

      @server_os     = {} # TODO: contexts
      @runtime       = {} # TODO: contexts

      @checksum = checksum
      @fingerprint = fingerprint

      @server_name = server_name
      @environment = environment
      @release = release

      # these 2 needs custom setter methods
      self.level         = level
      self.message       = message if message

      # Allow attributes to be set on the event at initialization
      yield self if block_given?
      # options.each_pair { |key, val| public_send("#{key}=", val) unless val.nil? }

      if !backtrace.empty?
        interface(:stacktrace) do |int|
          int.frames = stacktrace_interface_from(backtrace)
        end
      end

      set_core_attributes_from_configuration
    end

    sig {returns(String)}
    def message
      @interfaces[:logentry]&.unformatted_message.to_s
    end

    sig {params(message: String).void}
    def message=(message)
      interface(:message) do |int|
        int.message = message.byteslice(0...MAX_MESSAGE_SIZE_IN_BYTES) # Messages limited to 10kb
      end
    end

    sig {params(time: T.any(Time, String)).void}
    def timestamp=(time)
      @timestamp = time.is_a?(Time) ? time.strftime('%Y-%m-%dT%H:%M:%S') : time
    end

    sig {params(time: T.any(Float, Integer)).void}
    def time_spent=(time)
      @time_spent = time.is_a?(Float) ? (time * 1000).to_i : time
    end

    sig {params(new_level: T.any(String, Symbol)).void}
    def level=(new_level) # needed to meet the Sentry spec
      @level = new_level.to_s == "warn" ? :warning : new_level
    end

    def interface(name, value = nil, &block)
      int = Interface.registered[name]
      raise(Error, "Unknown interface: #{name}") unless int

      @interfaces[int.sentry_alias] = int.new(value, &block) if value || block
      @interfaces[int.sentry_alias]
    end

    def [](key)
      interface(key)
    end

    def []=(key, value)
      interface(key, value)
    end

    sig {returns(T::Hash[Symbol, T.untyped])}
    def to_hash
      data = [:checksum, :environment, :event_id, :extra, :fingerprint, :level,
              :logger, :message, :modules, :platform, :release, :sdk, :server_name,
              :tags, :time_spent, :timestamp, :transaction, :user].each_with_object({}) do |att, memo|
        memo[att] = public_send(att) if public_send(att)
      end

      # TODO-v4: Fix this
      # data[:breadcrumbs] = @breadcrumbs.to_hash unless @breadcrumbs.empty?

      @interfaces.each_pair do |name, int_data|
        data[name.to_sym] = int_data.to_hash
      end
      data
    end

    sig {returns(T::Hash[String, T.untyped])}
    def to_json_compatible
      JSON.parse(JSON.generate(to_hash))
    end

    def add_exception_interface(exc)
      interface(:exception) do |exc_int|
        exceptions = Sentry::Utils::ExceptionCauseChain.exception_to_array(exc).reverse
        backtraces = Set.new
        exc_int.values = exceptions.map do |e|
          SingleExceptionInterface.new do |int|
            int.type = e.class.to_s
            int.value = e.to_s
            int.module = e.class.to_s.split('::')[0...-1].join('::')

            int.stacktrace =
              if e.backtrace && !backtraces.include?(e.backtrace.object_id)
                backtraces << e.backtrace.object_id
                StacktraceInterface.new do |stacktrace|
                  stacktrace.frames = stacktrace_interface_from(e.backtrace)
                end
              end
          end
        end
      end
    end

    def stacktrace_interface_from(backtrace)
      Backtrace.parse(backtrace, configuration: configuration).lines.reverse.each_with_object([]) do |line, memo|
        frame = StacktraceInterface::Frame.new(configuration: configuration)
        frame.abs_path = line.file if line.file
        frame.function = line.method if line.method
        frame.lineno = line.number
        frame.in_app = line.in_app
        frame.module = line.module_name if line.module_name

        if configuration[:context_lines] && frame.abs_path
          frame.pre_context, frame.context_line, frame.post_context = \
            configuration.linecache.get_file_context(frame.abs_path, frame.lineno, configuration[:context_lines])
        end

        memo << frame if frame.filename
      end
    end

    private

    def set_core_attributes_from_configuration
      @server_name ||= configuration.server_name
      @release     ||= configuration.release
      @modules       = list_gem_specs if configuration.send_modules
      @environment ||= configuration.current_environment
    end

    def add_rack_context
      interface :http do |int|
        int.from_rack(context.rack_env)
      end
      # context.user[:ip_address] = calculate_real_ip_from_rack
    end

    # When behind a proxy (or if the user is using a proxy), we can't use
    # REMOTE_ADDR to determine the Event IP, and must use other headers instead.
    # def calculate_real_ip_from_rack
    #   Utils::RealIp.new(
    #     :remote_addr => context.rack_env["REMOTE_ADDR"],
    #     :client_ip => context.rack_env["HTTP_CLIENT_IP"],
    #     :real_ip => context.rack_env["HTTP_X_REAL_IP"],
    #     :forwarded_for => context.rack_env["HTTP_X_FORWARDED_FOR"]
    #   ).calculate_ip
    # end

    def list_gem_specs
      # Older versions of Rubygems don't support iterating over all specs
      Hash[Gem::Specification.map { |spec| [spec.name, spec.version.to_s] }] if Gem::Specification.respond_to?(:map)
    end
  end
end
