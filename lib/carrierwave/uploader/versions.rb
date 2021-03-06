# encoding: utf-8

module CarrierWave
  module Uploader
    module Versions
      extend ActiveSupport::Concern

      include CarrierWave::Uploader::Callbacks

      included do
        class_attribute :versions, :version_names, :instance_reader => false, :instance_writer => false

        self.versions = {}
        self.version_names = []

        attr_accessor :parent_cache_id

        after :cache, :assign_parent_cache_id
        after :cache, :cache_versions!
        after :store, :store_versions!
        after :remove, :remove_versions!
        after :retrieve_from_cache, :retrieve_versions_from_cache!
        after :retrieve_from_store, :retrieve_versions_from_store!
      end

      module ClassMethods

        ##
        # Adds a new version to this uploader
        #
        # === Parameters
        #
        # [name (#to_sym)] name of the version
        # [options (Hash)] optional options hash
        # [&block (Proc)] a block to eval on this version of the uploader
        #
        # === Examples
        #
        #     class MyUploader < CarrierWave::Uploader::Base
        #
        #       version :thumb do
        #         process :scale => [200, 200]
        #       end
        #
        #       version :preview, :if => :image? do
        #         process :scale => [200, 200]
        #       end
        #
        #     end
        #
        def version(name, options = {}, &block)
          name = name.to_sym
          build_version(name, options) unless versions[name]

          versions[name][:uploader].class_eval(&block) if block
          versions[name]
        end

        def recursively_apply_block_to_versions(&block)
          versions.each do |name, version|
            version[:uploader].class_eval(&block)
            version[:uploader].recursively_apply_block_to_versions(&block)
          end
        end

      private

        def build_version(name, options)
          uploader = Class.new(self)
          const_set("Uploader#{uploader.object_id}".gsub('-', '_'), uploader)
          uploader.version_names += [name]
          uploader.versions = {}
          uploader.processors = []

          uploader.class_eval <<-RUBY, __FILE__, __LINE__ + 1
            # Define the enable_processing method for versions so they get the
            # value from the parent class unless explicitly overwritten
            def self.enable_processing(value=nil)
              self.enable_processing = value if value
              if !@enable_processing.nil?
                @enable_processing
              else
                superclass.enable_processing
              end
            end

            # Regardless of what is set in the parent uploader, do not enforce the
            # move_to_cache config option on versions because it moves the original
            # file to the version's target file.
            #
            # If you want to enforce this setting on versions, override this method
            # in each version:
            #
            # version :thumb do
            #   def move_to_cache
            #     true
            #   end
            # end
            #
            def move_to_cache
              false
            end
          RUBY

          class_eval <<-RUBY
            def #{name}
              versions[:#{name}]
            end
          RUBY

          # Add the current version hash to class attribute :versions
          current_version = {
            name => {
              :uploader => uploader,
              :options  => options
            }
          }
          self.versions = versions.merge(current_version)
        end

      end # ClassMethods

      ##
      # Returns a hash mapping the name of each version of the uploader to an instance of it
      #
      # === Returns
      #
      # [Hash{Symbol => CarrierWave::Uploader}] a list of uploader instances
      #
      def versions
        return @versions if @versions
        @versions = {}
        self.class.versions.each do |name, version|
          @versions[name] = version[:uploader].new(model, mounted_as)
        end
        @versions
      end

      ##
      # === Returns
      #
      # [String] the name of this version of the uploader
      #
      def version_name
        self.class.version_names.join('_').to_sym unless self.class.version_names.blank?
      end

      ##
      #
      # === Parameters
      #
      # [name (#to_sym)] name of the version
      #
      # === Returns
      #
      # [Boolean] True when the version exists according to its :if condition
      #
      def version_exists?(name)
        name = name.to_sym

        return false unless self.class.versions.has_key?(name)

        condition = self.class.versions[name][:options][:if]
        if(condition)
          if(condition.respond_to?(:call))
            condition.call(self, :version => name, :file => file)
          else
            send(condition, file)
          end
        else
          true
        end
      end

      ##
      # When given a version name as a parameter, will return the url for that version
      # This also works with nested versions.
      # When given a query hash as a parameter, will return the url with signature that contains query params
      # Query hash only works with AWS (S3 storage).
      #
      # === Example
      #
      #     my_uploader.url                 # => /path/to/my/uploader.gif
      #     my_uploader.url(:thumb)         # => /path/to/my/thumb_uploader.gif
      #     my_uploader.url(:thumb, :small) # => /path/to/my/thumb_small_uploader.gif
      #     my_uploader.url(:query => {"response-content-disposition" => "attachment"})
      #     my_uploader.url(:version, :sub_version, :query => {"response-content-disposition" => "attachment"})
      #
      # === Parameters
      #
      # [*args (Symbol)] any number of versions
      # OR/AND
      # [Hash] query params
      #
      # === Returns
      #
      # [String] the location where this file is accessible via a url
      #
      def url(*args)
        if (version = args.first) && version.respond_to?(:to_sym)
          raise ArgumentError, "Version #{version} doesn't exist!" if versions[version.to_sym].nil?
          # recursively proxy to version
          versions[version.to_sym].url(*args[1..-1]) if version_exists?(version)
        elsif args.first
          super(args.first)
        else
          super
        end
      end

      ##
      # Recreate versions and reprocess them. This can be used to recreate
      # versions if their parameters somehow have changed.
      #
      def recreate_versions!(*versions)
        # Some files could possibly not be stored on the local disk. This
        # doesn't play nicely with processing. Make sure that we're only
        # processing a cached file
        #
        # The call to store! will trigger the necessary callbacks to both
        # process this version and all sub-versions
        if versions.any?
          file = sanitized_file if !cached?
          store_versions!(file, versions)
        else
          cache! if !cached?
          store!
        end
      end

    private
      def assign_parent_cache_id(file)
        active_versions.each do |name, uploader|
          uploader.parent_cache_id = @cache_id
        end
      end

      def active_versions
        versions.select do |name, uploader|
          version_exists?(name)
        end
      end

      def full_filename(for_file)
        [version_name, super(for_file)].compact.join('_')
      end

      def full_original_filename
        [version_name, super].compact.join('_')
      end

      def cache_versions!(new_file)
        # We might have processed the new_file argument after the callbacks were
        # initialized, so get the actual file based off of the current state of
        # our file
        processed_parent = SanitizedFile.new :tempfile => self.file,
          :filename => new_file.original_filename

        active_versions.each do |name, v|
          next if v.cached?

          v.send(:cache_id=, cache_id)
          # If option :from_version is present, create cache using cached file from
          # version indicated
          if self.class.versions[name][:options] && self.class.versions[name][:options][:from_version]
            # Maybe the reference version has not been cached yet
            unless versions[self.class.versions[name][:options][:from_version]].cached?
              versions[self.class.versions[name][:options][:from_version]].cache!(processed_parent)
            end
            processed_version = SanitizedFile.new :tempfile => versions[self.class.versions[name][:options][:from_version]],
              :filename => new_file.original_filename
            v.cache!(processed_version)
          else
            v.cache!(processed_parent)
          end
        end
      end

      def store_versions!(new_file, versions=nil)
        if versions
          active = Hash[active_versions]
          Parallel.each(versions, :in_threads => versions.length) { |v| active[v].try(:store!, new_file) } unless active.empty?
        else
          Parallel.each(active_versions, :in_threads => active_versions.length) { |name, v| v.store!(new_file) }
        end
      end

      def remove_versions!
        versions.each { |name, v| v.remove! }
      end

      def retrieve_versions_from_cache!(cache_name)
        versions.each { |name, v| v.retrieve_from_cache!(cache_name) }
      end

      def retrieve_versions_from_store!(identifier)
        versions.each { |name, v| v.retrieve_from_store!(identifier) }
      end

    end # Versions
  end # Uploader
end # CarrierWave
