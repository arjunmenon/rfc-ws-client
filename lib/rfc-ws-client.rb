require "rfc-ws-client/version"

require "openssl"
require 'uri'
require 'socket'
require 'securerandom'
require "digest/sha1"
require 'rainbow'
require 'base64'

module RfcWebsocket
  class Websocket
    WEB_SOCKET_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    OPCODE_TEXT = 0x01
    OPCODE_BINARY = 0x02
    OPCODE_CLOSE = 0x08
    OPCODE_PING = 0x09
    OPCODE_PONG = 0x0a
    DEBUG = true

    def initialize(uri, protocol = "")
      uri = URI.parse(uri) unless uri.is_a?(URI)
      @protocol = protocol

      if uri.scheme == "ws"
        default_port = 80
      elsif uri.scheme = "wss"
        default_port = 443
      else
        raise "unsupported scheme: #{uri.scheme}"
      end
      host = uri.host + ((!uri.port || uri.port == default_port) ? "" : ":#{uri.port}")
      path = (uri.path.empty? ? "/" : uri.path) + (uri.query ? "?" + uri.query : "")

      @socket = TCPSocket.new(uri.host, uri.port || default_port)
      if uri.scheme == "wss"
        @socket = OpenSSL::SSL::SSLSocket.new(@socket)
        @socket.sync_close = true
        @socket.connect
      end

      request_key = SecureRandom::base64(16)
      write(handshake(host, path, request_key))
      flush()

      status_line = gets.chomp
      raise "bad response: #{status_line}" unless status_line.start_with?("HTTP/1.1 101")

      header = {}
      while line = gets
        line.chomp!
        break if line.empty?
        if !(line =~ /\A(\S+): (.*)\z/n)
          raise "invalid response: #{line}"
        end
        header[$1.downcase] = $2
      end
      raise "upgrade missing" unless header["upgrade"]
      raise "connection missing" unless header["connection"]
      accept = header["sec-websocket-accept"]
      raise "sec-websocket-accept missing" unless accept
      expected_accept = Digest::SHA1.base64digest(request_key + WEB_SOCKET_GUID)
      raise "sec-websocket-accept is invalid, actual: #{accept}, expected: #{expected_accept}" unless accept == expected_accept
    end

    def send_message(message, opts = {binary: false})
      write(encode(message, opts[:binary] ? OPCODE_BINARY : OPCODE_TEXT))
    end

    def receive
      begin
        bytes = read(2).unpack("C*")
        fin = (bytes[0] & 0x80) != 0
        opcode = bytes[0] & 0x0f
        mask = (bytes[1] & 0x80) != 0
        plength = bytes[1] & 0x7f
        if plength == 126
          bytes = read(2)
          plength = bytes.unpack("n")[0]
        elsif plength == 127
          bytes = read(8)
          (high, low) = bytes.unpack("NN")
          plength = high * (2 ** 32) + low
        end
        mask_key = mask ? read(4).unpack("C*") : nil
        payload = read(plength)
        payload = apply_mask(payload, mask_key) if mask
        case opcode
        when OPCODE_TEXT
          return payload.force_encoding("UTF-8"), false
        when OPCODE_BINARY
          return payload, true
        when OPCODE_CLOSE
          close
          return nil, nil
        when OPCODE_PING
          write(encode(payload, OPCODE_PONG))
          #TODO fix recursion
          return receive
        when OPCODE_PONG
        else
          raise "received unknown opcode: #{opcode}"
        end
      rescue EOFError
        return nil, nil
      end
    end

    def close(code = 1000, msg = nil)
      write(encode [code ? code : 1000, msg].pack("nA*"), OPCODE_CLOSE)
      @socket.close
    end

    private

    def gets(delim = $/)
      line = @socket.gets(delim)
      print line.color(:green) if DEBUG
      line
    end

    def write(data)
      print data.color(:yellow) if DEBUG
      @socket.write(data)
      @socket.flush
    end

    def read(num_bytes)
      str = @socket.read(num_bytes)
      if str && str.bytesize == num_bytes
        print str.color(:green) if DEBUG
        str
      else
        raise(EOFError)
      end
    end

    def flush
      @socket.flush
    end

    def handshake(host, path, request_key)
      headers = ["GET #{path} HTTP/1.1"]
      headers << "Connection: keep-alive, Upgrade"
      headers << "Host: #{host}"
      headers << "Sec-WebSocket-Key: #{request_key}"
      headers << "Sec-WebSocket-Version: 13"
      headers << "Upgrade: websocket"
      headers << "User-Agent: rfc-ws-client"
      headers << "\r\n"
      headers.join "\r\n"
    end

    def encode(data, opcode)
      frame = []
      frame << (opcode | 0x80)

      packr = "CC"

      if opcode == OPCODE_TEXT
        data.force_encoding("UTF-8")
        if !data.valid_encoding?
          raise "Invalid UTF!"
        end
      end

      # append frame length and mask bit 0x80
      len = data ? data.bytesize : 0
      if len <= 125
        frame << (len | 0x80)
      elsif len < 65536
        frame << (126 | 0x80)
        frame << len
        packr << "n"
      else
        frame << (127 | 0x80)
        frame << len
        packr << "L!>"
      end

      # generate a masking key
      key = rand(2 ** 31)

      # mask each byte with the key
      frame << key
      packr << "N"

      # Apply the masking key to every byte
      len.times do |i|
        frame << ((data.getbyte(i) ^ (key >> ((3 - (i % 4)) * 8))) & 0xFF)
      end

      frame.pack("#{packr}C*")
    end
  end
end
