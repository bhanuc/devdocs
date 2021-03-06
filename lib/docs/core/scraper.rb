require 'set'
require 'html/pipeline'

module Docs
  class Scraper < Doc
    class << self
      attr_accessor :base_url, :root_path, :html_filters, :text_filters, :options

      def inherited(subclass)
        super

        subclass.class_eval do
          extend AutoloadHelper
          autoload_all "docs/filters/#{to_s.demodulize.underscore}", 'filter'
        end

        subclass.root_path = root_path
        subclass.options = options.deep_dup
        subclass.html_filters = html_filters.inheritable_copy
        subclass.text_filters = text_filters.inheritable_copy
      end

      def filters
        html_filters.to_a + text_filters.to_a
      end
    end

    include Instrumentable

    self.html_filters = FilterStack.new
    self.text_filters = FilterStack.new

    self.options = {}

    html_filters.push 'container', 'clean_html', 'normalize_urls', 'internal_urls', 'normalize_paths'
    text_filters.push 'inner_html', 'clean_text', 'attribution'

    def base_url
      @base_url ||= URL.parse self.class.base_url
    end

    def root_url
      @root_url ||= root_path? ? URL.parse(File.join(base_url.to_s, root_path)) : base_url.normalize
    end

    def root_path
      self.class.root_path
    end

    def root_path?
      root_path.present? && root_path != '/'
    end

    def build_page(path)
      response = request_one url_for(path)
      result = handle_response(response)
      yield result if block_given?
      result
    end

    def build_pages
      requested_urls = Set.new [root_url.to_s.downcase]
      instrument 'running.scraper', urls: requested_urls.to_a

      request_all root_url.to_s do |response|
        next unless data = handle_response(response)
        yield data
        next unless data[:internal_urls].present?
        next_urls = data[:internal_urls].select { |url| requested_urls.add?(url.downcase) }
        instrument 'queued.scraper', urls: next_urls
        next_urls
      end
    end

    def options
      @options ||= self.class.options.deep_dup.tap do |options|
        options.merge! base_url: base_url, root_path: root_path, root_url: root_url
        (options[:skip] ||= []).concat ['', '/'] if root_path?
        if options[:only] || options[:only_patterns]
          (options[:only] ||= []).concat root_path? ? [root_path] : ['', '/']
        end
        options.freeze
      end
    end

    def pipeline
      @pipeline ||= ::HTML::Pipeline.new(self.class.filters).tap do |pipeline|
        pipeline.instrumentation_service = Docs
      end
    end

    private

    def request_one(url)
      raise NotImplementedError
    end

    def request_all(url, &block)
      raise NotImplementedError
    end

    def process_response?(response)
      raise NotImplementedError
    end

    def url_for(path)
      if path.empty? || path == '/'
        root_url.to_s
      else
        File.join(base_url.to_s, path)
      end
    end

    def handle_response(response)
      if process_response?(response)
        instrument 'process_response.scraper', response: response do
          process_response(response)
        end
      else
        instrument 'ignore_response.scraper', response: response
      end
    end

    def process_response(response)
      pipeline.call parse(response.body), pipeline_context(response), data = {}
      data
    end

    def pipeline_context(response)
      options.merge url: response.url
    end

    def parse(string)
      Parser.new(string).html
    end
  end
end
