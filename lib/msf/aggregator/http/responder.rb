require "msf/aggregator/http/request"

module Msf
  module Aggregator
    module Http
      class Responder

        attr_accessor :queue
        attr_accessor :time
        attr_accessor :log_messages
        attr_reader :uri

        def initialize(uri)
          @uri = uri
          @queue = Queue.new
          @thread = Thread.new { process_requests }
          @time = Time.now
          @router = Router.instance
        end

        def process_requests

          while true do
            begin
              request_task = @queue.pop
              connection = request_task.socket
              request_task.headers

              # peer_addr = connection.io.peeraddr[3]

              host, port = @router.get_forward(@uri)
              if host.nil?
                # when no forward found park the connection for now
                # in the future this may get smarter and return a 404 or something
                return send_parked_response(connection)
              end

              client = nil

              begin
                client = get_connection(host, port)
              rescue StandardError => e
                log 'error on console connect ' + e.to_s
                send_parked_response(connection)
                return
              end

              log 'connected to console'

              request_task.headers.each do |line|
                client.write line
              end
              unless request_task.body.nil?
                client.write request_task.body
              end
              client.flush
              # log "From victim: \n" + request_lines.join()

              begin
                response = ''
                request_obj = Responder.get_data(client, true)
                request_obj.headers.each do |line|
                  connection.write line
                  response += line
                end
                unless request_obj.body.nil?
                  connection.write request_obj.body
                end
                connection.flush
                  # log "From console: \n" + response
              rescue
                log $!
              end
              close_connection(client)
              close_connection(connection)
            rescue Exception => e
              log "an error occurred processing request from #{@uri}"
            end
          end

        end

        def stop_processing
          @thread.exit
        end

        def send_parked_response(connection)
          log "sending parked response to #{peer_address(connection)}"
          parked_message = []
          parked_message << 'HTTP/1.1 200 OK'
          parked_message << 'Content-Type: application/octet-stream'
          parked_message << 'Connection: close'
          parked_message << 'Server: Apache'
          parked_message << 'Content-Length: 0'
          parked_message << ' '
          parked_message << ' '
          parked_message.each do |line|
            connection.puts line
          end
          close_connection(connection)
        end

        def self.get_data(connection, guaranteed_length)
          checked_first = has_length = guaranteed_length
          content_length = 0
          request_lines = []

          while (input = connection.gets)
            request_lines << input
            # break for body read
            break if (input.inspect.gsub /^"|"$/, '').eql? '\r\n'

            if !checked_first && !has_length
              has_length = input.include?('POST')
              checked_first = true
            end

            if has_length && input.include?('Content-Length')
              content_length = input[(input.index(':') + 1)..input.length].to_i
            end

          end
          body = ''
          if has_length
            while body.length < content_length
              body += connection.read(content_length - body.length)
            end
          end
          Request.new request_lines, body, connection
        end

        def get_connection(host, port)
          TCPSocket.new host, port
        end

        def close_connection(connection)
          connection.close
        end

        def peer_address(connection)
          connection.peeraddr[3]
        end

        def log(message)
          Logger.log message if @log_messages
        end

        private :log
        private :send_parked_response
      end
    end
  end
end