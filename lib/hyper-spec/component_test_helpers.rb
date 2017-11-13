# see component_test_helpers_spec.rb for examples

require 'parser/current'
require 'unparser'
require 'method_source'
require_relative '../../vendor/assets/javascripts/time_cop' # 'hyper-spec/time_cop'

module HyperSpec
  module ComponentTestHelpers
    TOP_LEVEL_COMPONENT_PATCH =
      Opal.compile(File.read(File.expand_path('../../react/top_level_rails_component.rb', __FILE__)))

    class << self
      attr_accessor :current_example
      attr_accessor :description_displayed

      def display_example_description
        "<script type='text/javascript'>console.log(console.log('%c#{current_example.description}'"\
        ",'color:green; font-weight:bold; font-size: 200%'))</script>"
      end
    end

    def build_test_url_for(controller)
      unless controller
        unless defined?(::ReactTestController)
          Object.const_set('ReactTestController', Class.new(ActionController::Base))
        end

        controller = ::ReactTestController
      end

      route_root = controller.name.gsub(/Controller$/, '').underscore

      unless controller.method_defined?(:test)
        controller.class_eval do
          define_method(:test) do
            route_root = self.class.name.gsub(/Controller$/, '').underscore
            test_params = ::Rails.cache.read("/#{route_root}/#{params[:id]}")
            @component_name = test_params[0]
            @component_params = test_params[1]
            render_params = test_params[2]
            render_on = render_params.delete(:render_on) || :client_only
            _mock_time = render_params.delete(:mock_time)
            style_sheet = render_params.delete(:style_sheet)
            javascript = render_params.delete(:javascript)
            code = render_params.delete(:code)

            page = '<%= react_component @component_name, @component_params, '\
                   "{ prerender: #{render_on != :client_only} } %>"
            page = "<script type='text/javascript'>\n#{TOP_LEVEL_COMPONENT_PATCH}\n</script>\n#{page}"

            page = "<script type='text/javascript'>\n#{code}\n</script>\n#{page}" if code

            page = "<%= javascript_include_tag 'time_cop' %>\n#{page}" if true || Lolex.initialized?

            if (render_on != :server_only && !render_params[:layout]) || javascript
              page = "<%= javascript_include_tag '#{javascript || 'application'}' %>\n#{page}"
            end

            if !render_params[:layout] || style_sheet
              page = "<%= stylesheet_link_tag '#{style_sheet || 'application'}' %>\n#{page}"
            end

            if render_on == :server_only # so that test helper wait_for_ajax works
              page = "<script type='text/javascript'>window.jQuery = {'active': 0}</script>\n#{page}"
            else
              page = "<%= javascript_include_tag 'jquery' %>\n"\
                     "<%= javascript_include_tag 'jquery_ujs' %>\n#{page}"
            end

            page = "<script type='text/javascript'>go = function() "\
                   "{window.hyper_spec_waiting_for_go = false}</script>\n#{page}"

            title = view_context.escape_javascript(ComponentTestHelpers.current_example.description)
            title = "#{title}...continued." if ComponentTestHelpers.description_displayed

            page = "<script type='text/javascript'>console.log(console.log('%c#{title}',"\
                   "'color:green; font-weight:bold; font-size: 200%'))</script>\n#{page}"

            ComponentTestHelpers.description_displayed = true
            render_params[:inline] = page
            render render_params
          end
        end

        begin
          routes = ::Rails.application.routes
          routes.disable_clear_and_finalize = true
          routes.clear!
          routes.draw do
            get "/#{route_root}/:id", to: "#{route_root}#test"
          end
          ::Rails.application.routes_reloader.paths.each { |path| load(path) }
          routes.finalize!
          ActiveSupport.on_load(:action_controller) { routes.finalize! }
        ensure
          routes.disable_clear_and_finalize = false
        end
      end

      "/#{route_root}/#{@test_id = (@test_id || 0) + 1}"
    end

    def isomorphic(&block)
      yield
      on_client(&block)
    end

    def evaluate_ruby(str = '', opts = {}, &block)
      insure_mount
      if block
        str = "#{str}\n#{Unparser.unparse Parser::CurrentRuby.parse(block.source).children.last}"
      end
      js = Opal.compile(str).delete("\n").gsub('(Opal);', '(Opal)')
      JSON.parse(evaluate_script("[#{js}].$to_json()"), opts).first
    end

    def expect_evaluate_ruby(str = '', opts = {}, &block)
      insure_mount
      expect(evaluate_ruby(add_opal_block(str, block), opts))
    end

    def add_opal_block(str, block)
      # big assumption here is that we are going to follow this with a .to
      # hence .children.first followed by .children.last
      # probably should do some kind of "search" to make this work nicely
      return str unless block
      "#{str}\n"\
      "#{Unparser.unparse Parser::CurrentRuby.parse(block.source).children.first.children.last}"
    end

    def expect_promise(str = '', opts = {}, &block)
      insure_mount

      str = add_opal_block(str, block)
      str = "#{str}.then { |args| args = [args]; `window.hyper_spec_promise_result = args` }"
      js = Opal.compile(str).delete("\n").gsub('(Opal);', '(Opal)')
      page.evaluate_script('window.hyper_spec_promise_result = false')
      page.execute_script(js)

      Timeout.timeout(Capybara.default_max_wait_time) do
        loop do
          sleep 0.25
          break if page.evaluate_script('!!window.hyper_spec_promise_result')
        end
      end

      result =
        JSON.parse(page.evaluate_script('window.hyper_spec_promise_result.$to_json()'), opts).first
      expect(result)
    end

    def ppr(str)
      js = Opal.compile(str).delete("\n").gsub('(Opal);', '(Opal)')
      execute_script("console.log(#{js})")
    end

    def on_client(&block)
      @client_code =
        "#{@client_code}#{Unparser.unparse Parser::CurrentRuby.parse(block.source).children.last}\n"
    end

    def debugger
      `debugger`
      nil
    end

    def insure_mount
      # rescue in case page is not defined...
      mount unless page.instance_variable_get('@hyper_spec_mounted')
    end

    def client_option(opts = {})
      @client_options ||= {}
      @client_options.merge! opts
    end

    alias client_options client_option

    def mount(component_name = nil, params = nil, opts = {}, &block)
      unless params
        params = opts
        opts = {}
      end

      opts = client_options opts
      test_url = build_test_url_for(opts.delete(:controller))

      if block || @client_code || component_name.nil?
        block_with_helpers = <<-code
          module ComponentHelpers
            def self.js_eval(s)
              `eval(s)`
            end
            def self.dasherize(s)
              `s.replace(/[-_\\s]+/g, '-')
                .replace(/([A-Z\\d]+)([A-Z][a-z])/g, '$1-$2')
                .replace(/([a-z\\d])([A-Z])/g, '$1-$2')
                .toLowerCase()`
            end
            def self.add_class(class_name, styles={})
              style = styles.collect { |attr, value| "\#{dasherize(attr)}:\#{value}"}.join("; ")
              s = "<style type='text/css'> .\#{class_name}{ \#{style} } </style>"
              `$(\#{s}).appendTo("head");`
            end
          end
          class React::Component::HyperTestDummy < React::Component::Base
            def render; end
          end
          #{@client_code}
          #{Unparser.unparse(Parser::CurrentRuby.parse(block.source).children.last) if block}
        code
        opts[:code] = Opal.compile(block_with_helpers)
      end

      component_name ||= 'React::Component::HyperTestDummy'
      ::Rails.cache.write(test_url, [component_name, params, opts])
      visit test_url
      wait_for_ajax unless opts[:no_wait]
      page.instance_variable_set('@hyper_spec_mounted', true)
      Lolex.init(self, client_options[:time_zone], client_options[:clock_resolution])
    end

    [:callback_history_for, :last_callback_for, :clear_callback_history_for,
     :event_history_for, :last_event_for, :clear_event_history_for].each do |method|
      define_method(method) do |event_name|
        evaluate_ruby("React::TopLevelRailsComponent.#{method}('#{event_name}')")
      end
    end

    def run_on_client(&block)
      script = Opal.compile(Unparser.unparse(Parser::CurrentRuby.parse(block.source).children.last))
      execute_script(script)
    end

    def add_class(class_name, style)
      @client_code = "#{@client_code}ComponentHelpers.add_class '#{class_name}', #{style}\n"
    end

    def open_in_chrome
      if false && ['linux', 'freebsd'].include?(`uname`.downcase)
        `google-chrome http://#{page.server.host}:#{page.server.port}#{page.current_path}`
      else
        `open http://#{page.server.host}:#{page.server.port}#{page.current_path}`
      end

      while true
        sleep 1.hour
      end
    end

    def pause(message = nil)
      if message
        puts message
        evaluate_ruby "puts #{message.inspect}.to_s + ' (type go() to continue)'"
      end

      page.evaluate_script('window.hyper_spec_waiting_for_go = true')

      loop do
        sleep 0.25
        break unless page.evaluate_script('window.hyper_spec_waiting_for_go')
      end
    end

    def size_window(width = nil, height = nil)
      width, height = [height, width] if width == :portrait
      width, height = width if width.is_a? Array
      portrait = true if height == :portrait

      case width
      when :small
        width, height = [480, 320]
      when :mobile
        width, height = [640, 480]
      when :tablet
        width, height = [960, 640]
      when :large
        width, height = [1920, 6000]
      when :default, nil
        width, height = [1024, 768]
      end

      width, height = [height, width] if portrait

      Capybara.current_session.current_window.resize_to(width, height)
    end
  end

  RSpec.configure do |config|
    config.before(:each) do |example|
      ComponentTestHelpers.current_example = example
      ComponentTestHelpers.description_displayed = false
    end

    if defined?(ActiveRecord)
      config.before(:all) do
        ActiveRecord::Base.class_eval do
          def attributes_on_client(page)
            page.evaluate_ruby("#{self.class.name}.find(#{id}).attributes", symbolize_names: true)
          end
        end
      end
    end
  end
end
