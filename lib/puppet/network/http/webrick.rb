require 'webrick'
require 'webrick/https'
require 'puppet/network/http/webrick/rest'
require 'thread'

require 'puppet/ssl/certificate'
require 'puppet/ssl/certificate_revocation_list'

class Puppet::Network::HTTP::WEBrick
  def initialize(args = {})
    @listening = false
    @mutex = Mutex.new
  end

  def listen(args = {})
    raise ArgumentError, ":address must be specified." unless args[:address]
    raise ArgumentError, ":port must be specified." unless args[:port]

    arguments = {:BindAddress => args[:address], :Port => args[:port]}
    arguments.merge!(setup_logger)
    arguments.merge!(setup_ssl)

    @server = WEBrick::HTTPServer.new(arguments)
    @server.listeners.each { |l| l.start_immediately = false }

    @server.mount('/', Puppet::Network::HTTP::WEBrickREST, :this_value_is_apparently_necessary_but_unused)

    @mutex.synchronize do
      raise "WEBrick server is already listening" if @listening
      @listening = true
      @thread = Thread.new {
        @server.start { |sock|
          raise "Client disconnected before connection could be established" unless IO.select([sock],nil,nil,6.2)
          sock.accept
          @server.run(sock)
        }
      }
      sleep 0.1 until @server.status == :Running
    end
  end

  def unlisten
    @mutex.synchronize do
      raise "WEBrick server is not listening" unless @listening
      @server.shutdown
      @thread.join
      @server = nil
      @listening = false
    end
  end

  def listening?
    @mutex.synchronize do
      @listening
    end
  end

  # Configure our http log file.
  def setup_logger
    # Make sure the settings are all ready for us.
    Puppet.settings.use(:main, :ssl, Puppet[:name])

    if Puppet.run_mode.master?
      file = Puppet[:masterhttplog]
    else
      file = Puppet[:httplog]
    end

    # open the log manually to prevent file descriptor leak
    file_io = ::File.open(file, "a+")
    file_io.sync = true
    if defined?(Fcntl::FD_CLOEXEC)
      file_io.fcntl(Fcntl::F_SETFD, Fcntl::FD_CLOEXEC)
    end

    args = [file_io]
    args << WEBrick::Log::DEBUG if Puppet::Util::Log.level == :debug

    logger = WEBrick::Log.new(*args)
    return :Logger => logger, :AccessLog => [
      [logger, WEBrick::AccessLog::COMMON_LOG_FORMAT ],
      [logger, WEBrick::AccessLog::REFERER_LOG_FORMAT ]
    ]
  end

  # Add all of the ssl cert information.
  def setup_ssl
    results = {}

    # Get the cached copy.  We know it's been generated, too.
    host = Puppet::SSL::Host.localhost

    raise Puppet::Error, "Could not retrieve certificate for #{host.name} and not running on a valid certificate authority" unless host.certificate

    results[:SSLPrivateKey] = host.key.content
    results[:SSLCertificate] = host.certificate.content
    results[:SSLStartImmediately] = true
    results[:SSLEnable] = true

    raise Puppet::Error, "Could not find CA certificate" unless Puppet::SSL::Certificate.indirection.find(Puppet::SSL::CA_NAME)

    results[:SSLCACertificateFile] = Puppet[:localcacert]
    results[:SSLVerifyClient] = OpenSSL::SSL::VERIFY_PEER

    results[:SSLCertificateStore] = host.ssl_store

    results
  end
end
