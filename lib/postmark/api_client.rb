module Postmark
  class ApiClient
    attr_reader :http_client, :max_retries
    attr_writer :max_batch_size

    def initialize(api_key, options = {})
      @max_retries = options.delete(:max_retries) || 3
      @http_client = HttpClient.new(api_key, options)
    end

    def api_key=(api_key)
      http_client.api_key = api_key
    end

    def deliver(message_hash = {})
      data = serialize(MessageHelper.to_postmark(message_hash))

      with_retries do
        format_response http_client.post("email", data)
      end
    end

    def deliver_in_batches(message_hashes)
      in_batches(message_hashes) do |batch, offset|
        data = serialize(batch.map { |h| MessageHelper.to_postmark(h) })

        with_retries do
          http_client.post("email/batch", data)
        end
      end
    end

    def deliver_message(message)
      data = serialize(message.to_postmark_hash)

      with_retries do
        response, error = take_response_of { http_client.post("email", data) }
        update_message(message, response)
        raise error if error
        format_response(response, true)
      end
    end

    def deliver_messages(messages)
      in_batches(messages) do |batch, offset|
        data = serialize(batch.map { |m| m.to_postmark_hash })

        with_retries do
          http_client.post("email/batch", data).tap do |response|
            response.each_with_index do |r, i|
              update_message(messages[offset + i], r)
            end
          end
        end
      end
    end

    def delivery_stats
      response = format_response(http_client.get("deliverystats"), true)

      if response[:bounces]
        response[:bounces] = format_response(response[:bounces])
      end

      response
    end

    def get_messages(options = {})
      path, params = extract_messages_path_and_params(options)
      params[:offset] ||= 0
      params[:count] ||= 50
      messages_key = options[:inbound] ? 'InboundMessages' : 'Messages'
      format_response http_client.get(path, params)[messages_key]
    end

    def get_message(id, options = {})
      get_for_message('details', id, options)
    end

    def dump_message(id, options = {})
      get_for_message('dump', id, options)
    end

    def get_bounces(options = {})
      format_response http_client.get("bounces", options)["Bounces"]
    end

    def get_bounced_tags
      http_client.get("bounces/tags")
    end

    def get_bounce(id)
      format_response http_client.get("bounces/#{id}")
    end

    def dump_bounce(id)
      format_response http_client.get("bounces/#{id}/dump")
    end

    def activate_bounce(id)
      format_response http_client.put("bounces/#{id}/activate")["Bounce"]
    end

    def server_info
      format_response http_client.get("server")
    end

    def update_server_info(attributes = {})
      data = HashHelper.to_postmark(attributes)
      format_response http_client.post("server", serialize(data))
    end

    def max_batch_size
      @max_batch_size ||= 500
    end

    protected

    def with_retries
      yield
    rescue DeliveryError
      retries = retries ? retries + 1 : 1
      if retries < self.max_retries
        retry
      else
        raise
      end
    end

    def in_batches(messages)
      r = messages.each_slice(max_batch_size).each_with_index.map do |batch, i|
        yield batch, i * max_batch_size
      end

      format_response r.flatten
    end

    def update_message(message, response)
      response ||= {}
      message['Message-ID'] = response['MessageID']
      message.delivered = !!response['MessageID']
      message.postmark_response = response
    end

    def serialize(data)
      Postmark::Json.encode(data)
    end

    def take_response_of
      [yield, nil]
    rescue DeliveryError => e
      [e.full_response || {}, e]
    end

    def get_for_message(action, id, options = {})
      path, params = extract_messages_path_and_params(options)
      format_response http_client.get("#{path}/#{id}/#{action}", params)
    end

    def format_response(response, compatible = false)
      return {} unless response

      if response.kind_of? Array
        response.map { |entry| Postmark::HashHelper.to_ruby(entry, compatible) }
      else
        Postmark::HashHelper.to_ruby(response, compatible)
      end
    end

    def extract_messages_path_and_params(options = {})
      options = options.dup
      path = options.delete(:inbound) ? 'messages/inbound' : 'messages/outbound'
      [path, options]
    end

  end
end