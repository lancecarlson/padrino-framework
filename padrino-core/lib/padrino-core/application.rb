module Padrino
  class ApplicationSetupError < RuntimeError # @private
  end

  ##
  # Subclasses of this become independent Padrino applications (stemming from Sinatra::Application)
  # These subclassed applications can be easily mounted into other Padrino applications as well.
  #
  class Application < Sinatra::Base
    ##
    # Returns the logger for this application.
    #
    # @return [Padrino::Logger] Logger associated with this app.
    #
    def logger
      Padrino.logger
    end

    class << self

      def inherited(base) # @private
        logger.devel "Setup #{base}"
        CALLERS_TO_IGNORE.concat(PADRINO_IGNORE_CALLERS)
        base.default_configuration!
        base.prerequisites.concat([
          File.join(base.root, "/models.rb"),
          File.join(base.root, "/models/**/*.rb"),
          File.join(base.root, "/lib.rb"),
          File.join(base.root, "/lib/**/*.rb")
        ]).uniq!
        Padrino.require_dependencies(base.prerequisites)
        Padrino::Application.descendants.push(base)
        super(base) # Loading the subclass inherited method
      end

      ##
      # Track descendants of {Padrino::Application}
      #
      # @return [Array]
      #
      def descendants
        @_descendants ||= []
      end

      ##
      # Reloads the application files from all defined load paths
      #
      # This method is used from our Padrino Reloader during development mode
      # in order to reload the source files.
      #
      # @return [TrueClass]
      #
      # @example
      #   MyApp.reload!
      #
      def reload!
        logger.devel "Reloading #{self}"
        @_dependencies = nil # Reset dependencies
        reset! # Reset sinatra app
        reset_router! # Reset all routes
        Padrino.require_dependencies(self.app_file, :force => true) # Reload the app file
        require_dependencies # Reload dependencies
        default_filters!     # Reload filters
        default_routes!      # Reload default routes
        default_errors!      # Reload our errors
        I18n.reload! if defined?(I18n) # Reload also our translations
        true
      end

      ##
      # Resets application routes to only routes not defined by the user
      #
      # @return [TrueClass]
      #
      # @example
      #   MyApp.reset_routes!
      #
      def reset_routes!
        reset_router!
        default_routes!
        true
      end

      ##
      # Returns the routes of our app.
      #
      # @example
      #   MyApp.routes
      #
      def routes
        router.routes
      end

      def register(*extensions, &block) # @private
        added_methods = extensions.map { |m| m.public_instance_methods }
        extensions.each do |m|
          added_methods << m.const_get(:ClassMethods).public_instance_methods if m.const_defined?(:ClassMethods)
        end
        Sinatra::Delegator.delegate(*added_methods.uniq.flatten)
        super(*extensions, &block)
      end

      ##
      # Setup the application by registering initializers, load paths and logger
      # Invoked automatically when an application is first instantiated
      #
      # @return [TrueClass]
      #
      def setup_application!
        return if @_configured
        self.require_dependencies
        self.default_filters!
        self.default_routes!
        self.default_errors!
        if defined?(I18n)
          I18n.load_path << self.locale_path
          I18n.reload!
        end
        @_configured = true
        @_configured
      end

      ##
      # Run the Padrino app as a self-hosted server using
      # Thin, Mongrel or WEBrick (in that order)
      #
      # @see Padrino::Server#start
      #
      def run!(options={})
        return unless Padrino.load!
        Padrino.mount(self.to_s).to("/")
        Padrino.run!(options)
      end

      ##
      # @return [Array]
      #   directory that need to be added to +$LOAD_PATHS+ from this application
      #
      def load_paths
        @_load_paths ||= %w(models lib mailers controllers helpers).map { |path| File.join(self.root, path) }
      end

      ##
      # Returns default list of path globs to load as dependencies
      # Appends custom dependency patterns to the be loaded for your Application
      #
      # @return [Array]
      #   list of path globs to load as dependencies
      #
      # @example
      #   MyApp.dependencies << "#{Padrino.root}/uploaders/**/*.rb"
      #   MyApp.dependencies << Padrino.root('other_app', 'controllers.rb')
      #
      def dependencies
        @_dependencies ||= [
          "urls.rb", "config/urls.rb", "mailers/*.rb", "mailers.rb",
          "controllers/**/*.rb", "controllers.rb", "helpers/**/*.rb", "helpers.rb"
        ].map { |file| Dir[File.join(self.root, file)] }.flatten
      end

      ##
      # An array of file to load before your app.rb, basically are files wich our app depends on.
      #
      # By default we look for files:
      #
      #   # List of default files that we are looking for:
      #   yourapp/models.rb
      #   yourapp/models/**/*.rb
      #   yourapp/lib.rb
      #   yourapp/lib/**/*.rb
      #
      # @example Adding a custom perequisite
      #   MyApp.prerequisites << Padrino.root('my_app', 'custom_model.rb')
      #
      def prerequisites
        @_prerequisites ||= []
      end

      protected
        ##
        # Defines default settings for Padrino application
        #
        def default_configuration!
          # Reset and register our routing system
          reset!
          register Padrino::Routing
          # Overwriting Sinatra defaults
          set :app_file, File.expand_path(caller_files.first || $0) # Assume app file is first caller
          set :environment, Padrino.env
          set :reload, Proc.new { development? }
          set :logging, Proc.new { development? }
          set :method_override, true
          set :sessions, false
          set :public_folder, Proc.new { Padrino.root('public', uri_root) }
          set :views, Proc.new { File.join(root,   "views") }
          set :images_path, Proc.new { File.join(public, "images") }
          set :protection, false
          # Padrino specific
          set :uri_root, "/"
          set :app_name, self.to_s.underscore.to_sym
          set :default_builder, 'StandardFormBuilder'
          set :flash, defined?(Rack::Flash)
          set :authentication, false
          # Padrino locale
          set :locale_path, Proc.new { Dir[File.join(self.root, "/locale/**/*.{rb,yml}")] }
          # Load the Global Configurations
          class_eval(&Padrino.apps_configuration) if Padrino.apps_configuration
        end

        ##
        # We need to add almost __sinatra__ images.
        #
        def default_routes!
          configure :development do
            get '*__sinatra__/:image.png' do
              content_type :png
              filename = File.dirname(__FILE__) + "/images/#{params[:image]}.png"
              send_file filename
            end
          end
        end

        ##
        # This filter it's used for know the format of the request, and automatically set the content type.
        #
        def default_filters!
          before do
            unless @_content_type
              @_content_type = :html
              response['Content-Type'] = 'text/html;charset=utf-8'
            end
          end
        end

        ##
        # This log errors for production environments
        #
        def default_errors!
          configure :production do
            error ::Exception do
              boom = env['sinatra.error']
              logger.error ["#{boom.class} - #{boom.message}:", *boom.backtrace].join("\n ")
              response.status = 500
              content_type 'text/html'
              '<h1>Internal Server Error</h1>'
            end unless errors.has_key?(::Exception)
          end
        end

        ##
        # Requires all files within the application load paths
        #
        def require_dependencies
          Padrino.set_load_paths(*load_paths)
          Padrino.require_dependencies(dependencies, :force => true)
        end

      private

        # Overrides the default middleware for Sinatra based on Padrino conventions
        # Also initializes the application after setting up the middleware
        def setup_default_middleware(builder)
          setup_sessions builder
          builder.use Padrino::ShowExceptions         if show_exceptions?
          builder.use Padrino::Logger::Rack, uri_root if Padrino.logger && logging?
          builder.use Padrino::Reloader::Rack         if reload?
          builder.use Rack::Flash, :sweep => true     if flash?
          builder.use Rack::MethodOverride            if method_override?
          builder.use Rack::Head
          setup_protection builder
          setup_application!
        end
    end # self
  end # Application
end # Padrino
