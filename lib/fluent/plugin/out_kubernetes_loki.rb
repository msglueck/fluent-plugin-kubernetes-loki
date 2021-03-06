#
# Copyright 2018- Grafana Labs
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'fluent/plugin/output'
require 'net/http'
require 'uri'
require 'yajl'
require 'time'
require 'openssl'

module Fluent
  module Plugin
    # Subclass of Fluent Plugin Output
    class KubernetesLokiOutput < Fluent::Plugin::Output
      Fluent::Plugin.register_output('kubernetes_loki', self)

      helpers :compat_parameters

      DEFAULT_BUFFER_TYPE = 'memory'.freeze

      # url of loki server
      config_param :url, :string, default: 'https://loki'

      # BasicAuth credentials
      config_param :username, :string, default: nil
      config_param :password, :string, default: nil, secret: true

      # Loki tenant id
      config_param :tenant, :string, default: nil

      config_param :drop_single_key, :bool, default: true

      # extra labels to add to all log streams
      config_param :extra_labels, :hash, default: {}

      # format to use when flattening the record to a log line
      config_param :line_format, :enum, list: %i[json key_value], default: :key_value

      # Set Net::HTTP.verify_mode to `OpenSSL::SSL::VERIFY_NONE`
      config_param :ssl_no_verify, :bool, :default => false

      # ca file to use for https request
      config_param :cacert_file, :string, :default => ''

      # specify client sertificate
      config_param :client_cert_path, :string, :default => ''

      # specify private key path
      config_param :private_key_path, :string, :default => ''

      # specify private key passphrase
      config_param :private_key_passphrase, :string, :default => '', :secret => true
      
      config_section :buffer do
        config_set_default :@type, DEFAULT_BUFFER_TYPE
        config_set_default :chunk_keys, []
      end

      def configure(conf)
        compat_parameters_convert(conf, :buffer)
        super

        @ssl_verify_mode = if @ssl_no_verify
                              OpenSSL::SSL::VERIFY_NONE
                           else
                              OpenSSL::SSL::VERIFY_PEER
                           end
        @ca_file = @cacert_file
        
        @label_keys = @label_keys.split(/\s*,\s*/) if @label_keys
      end

      def http_opts(uri)
        opts = {
            use_ssl: uri.scheme == 'https'
        }
        
        opts[:verify_mode] = @ssl_verify_mode if opts[:use_ssl]
        opts[:ca_file] = File.join(@ca_file) if File.file?(@ca_file)
        opts[:cert] = OpenSSL::X509::Certificate.new(File.read(@client_cert_path)) if File.file?(@client_cert_path)
        opts[:key] = OpenSSL::PKey.read(File.read(@private_key_path), @private_key_passphrase) if File.file?(@private_key_path)
        opts
      end

      # flush a chunk to loki
      def write(chunk)
        # streams by label
        payload = generic_to_loki(chunk)
        body = { 'streams': payload }

        # add ingest path to loki url
        uri = URI.parse(url + '/api/prom/push')

        req = Net::HTTP::Post.new(
            uri.request_uri
        )
        req.add_field('Content-Type', 'application/json')
        req.add_field('X-Scope-OrgID', @tenant) if @tenant
        req.body = Yajl.dump(body)
        req.basic_auth(@username, @password) if @username
        opts = {
            use_ssl: uri.scheme == 'https'
        }
        log.info "sending #{req.body.length} bytes"
        res = Net::HTTP.start(uri.hostname, uri.port, **opts) { |http| http.request(req) }
        unless res && res.is_a?(Net::HTTPSuccess)
          res_summary = if res
                          "#{res.code} #{res.message} #{res.body}"
                        else
                          'res=nil'
                        end
          log.warn "failed to #{req.method} #{uri} (#{res_summary})"
          log.warn Yajl.dump(body)

        end
      end

      def generic_to_loki(chunk)
        # log.debug("GenericToLoki: converting #{chunk}")
        streams = chunk_to_loki(chunk)
        payload = payload_builder(streams)
        payload
      end

      private

      def numeric?(val)
        !Float(val).nil?
      rescue StandardError
        false
      end

      def labels_to_protocol(data_labels)
        formatted_labels = []

        # merge extra_labels with data_labels. If there are collisions extra_labels win.
        data_labels = {} if data_labels.nil?
        data_labels = data_labels.merge(@extra_labels)

        unless data_labels.nil?
          data_labels.each do |k, v|
            formatted_labels.push("#{k}=\"#{v}\"")
          end
        end
        '{' + formatted_labels.join(',') + '}'
      end

      def payload_builder(streams)
        payload = []
        streams.each do |k, v|
          # create a stream for each label set.
          # Additionally sort the entries by timestamp just incase we
          # got them out of order.
          # 'labels' => '{worker="0"}',
          payload.push(
              'labels' => labels_to_protocol(k),
              'entries' => v.sort_by { |hsh| Time.parse(hsh['ts']) }
          )
        end
        payload
      end

      def record_to_line(record)
        line = ''
        if @drop_single_key && record.keys.length == 1
          line = record[record.keys[0]]
        else
          case @line_format
          when :json
            line = Yajl.dump(record)
          when :key_value
            formatted_labels = []
            record.each do |k, v|
              formatted_labels.push("#{k}=\"#{v}\"")
            end
            line = formatted_labels.join(' ')
          end
        end
        line
      end

      # this function transforms fluent-bit format to loki/prometheus format
      def transform_labels_loki(input)
        chunk_labels = {}
        transform_map = {
            "namespace_name" => "namespace",
            "pod_name" => "pod",
            "docker_id" => "container_id",
            "container" => "container",
            "annotations" => nil,
        }
        input.each do |k, v|
          if transform_map.key?(k)
            unless transform_map[k].nil?
              new_key = transform_map[k]
              chunk_labels[new_key] = v
            end
          else
            new_key = k.gsub(/[.\-\/]/,"_")
            chunk_labels[new_key] = v
          end
        end
        return chunk_labels
      end

      # convert a line to loki line with labels
      def line_to_loki(record)
        chunk_labels = {}
        line = ''
        if record.is_a?(Hash)
          # extract kubernetes labels
          if record.key?("kubernetes")
            kubernetes_meta = record["kubernetes"]
            kubernetes_meta.each_key do |k|
              if k == "labels"
                labels = kubernetes_meta[k]
                labels.each_key do |l|
                  chunk_labels[l] = labels[l]
                end
              else
                chunk_labels[k] = kubernetes_meta[k]
              end
            end
            record.delete("kubernetes")
          end
          line = record_to_line(record)
        else
          line = record.to_s
        end

        # return both the line content plus the labels found in the record
        {
            line: line,
            labels: transform_labels_loki(chunk_labels)
        }
      end

      # iterate through each chunk and create a loki stream entry
      def chunk_to_loki(chunk)
        streams = {}
        last_time = nil
        chunk.each do |time, record|
          # each chunk has a unique set of labels
          last_time = time if last_time.nil?
          result = line_to_loki(record)
          chunk_labels = result[:labels]
          # initialize a new stream with the chunk_labels if it does not exist
          streams[chunk_labels] = [] if streams[chunk_labels].nil?
          # NOTE: timestamp must include nanoseconds
          # append to matching chunk_labels key
          streams[chunk_labels].push(
              'ts' => Time.at(time.to_f).gmtime.iso8601(6),
              'line' => result[:line]
          )
        end
        streams
      end
    end
  end
end
