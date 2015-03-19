# encoding: utf-8
require "logstash/inputs/base"
require "logstash/namespace"
require "logstash/plugin_mixins/aws_config"

require "time"
require "tmpdir"
require "stud/interval"
require "stud/temporary"
require "xz"

# Stream events from files from a S3 bucket.
#
# Each line from each file generates an event.
# Files ending in `.gz` are handled as gzip'ed files.
class LogStash::Inputs::S3 < LogStash::Inputs::Base
  include LogStash::PluginMixins::AwsConfig
  milestone 1

  config_name "s3"

  default :codec, "line"

  # DEPRECATED: The credentials of the AWS account used to access the bucket.
  # Credentials can be specified:
  # - As an ["id","secret"] array
  # - As a path to a file containing AWS_ACCESS_KEY_ID=... and AWS_SECRET_ACCESS_KEY=...
  # - In the environment, if not set (using variables AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY)
  config :credentials, :validate => :array, :default => [], :deprecated => "This only exists to be backwards compatible. This plugin now uses the AwsConfig from PluginMixins"

  # The name of the S3 bucket.
  config :bucket, :validate => :string, :required => true

  # The AWS region for your bucket.
  config :region_endpoint, :validate => ["us-east-1", "us-west-1", "us-west-2",
                                "eu-west-1", "ap-southeast-1", "ap-southeast-2",
                                "ap-northeast-1", "sa-east-1", "us-gov-west-1"], :deprecated => "This only exists to be backwards compatible. This plugin now uses the AwsConfig from PluginMixins"

  # If specified, the prefix of filenames in the bucket must match (not a regexp)
  config :prefix, :validate => :string, :default => nil

  # Where to write the since database (keeps track of the date
  # the last handled file was added to S3). The default will write
  # sincedb files to some path matching "$HOME/.sincedb*"
  # Should be a path with filename not just a directory.
  config :sincedb_path, :validate => :string, :default => nil

  # Name of a S3 bucket to backup processed files to.
  config :backup_to_bucket, :validate => :string, :default => nil

  # Append a prefix to the key (full path including file name in s3) after processing.
  # If backing up to another (or the same) bucket, this effectively lets you
  # choose a new 'folder' to place the files in
  config :backup_add_prefix, :validate => :string, :default => nil

  # Path of a local directory to backup processed files to.
  config :backup_to_dir, :validate => :string, :default => nil

  # Whether to delete processed files from the original bucket.
  config :delete, :validate => :boolean, :default => false

  # Interval to wait between to check the file list again after a run is finished.
  # Value is in seconds.
  config :interval, :validate => :number, :default => 60

  # Ruby style regexp of keys to exclude from the bucket
  config :exclude_pattern, :validate => :string, :default => nil

  # Start date to process
  config :start_date, :validate => :string, :default => nil
  
  # End date to process
  config :end_date, :validate => :string, :default => nil

  # Disable actual file download, list files only
  config :debug_skip_download, :validate => :boolean, :default => false

  # total executors for this input
  config :total_executors, :validate => :number, :default => 1

  public
  def register
    require "digest/md5"
    require "aws-sdk"

    @region = get_region

    @executor_id = ENV['ID']

    @logger.info("Registering s3 input", :bucket => @bucket, :region => @region)

    s3 = get_s3object

    @s3bucket = s3.buckets[@bucket]

    unless @backup_to_bucket.nil?
      @backup_bucket = s3.buckets[@backup_to_bucket]
      unless @backup_bucket.exists?
        s3.buckets.create(@backup_to_bucket)
      end
    end

    unless @backup_to_dir.nil?
      Dir.mkdir(@backup_to_dir, 0700) unless File.exists?(@backup_to_dir)
    end
  end # def register


  public
  def run(queue)
    Stud.interval(@interval) do
      process_files(queue)
    end
  end # def run

  public
  def list_new_files
    objects = {}

    if @start_date and @end_date
      day = Time.parse(@start_date)
      end_day = Time.parse(@end_date)
      while (day < end_day)
        day_text = day.strftime("%Y%m%d")
        day_prefix = @prefix.sub '%YYYYMMDD%', day_text
        @logger.debug("S3 input: Using prefix", :day_prefix => day_prefix)
        @s3bucket.objects.with_prefix(day_prefix).each do |log|
          @logger.debug("S3 input: Found key in today prefix", :key => log.key)
          unless ignore_filename?(log.key)
            if sincedb.newer?(log.last_modified)
              objects[log.key] = log.last_modified
              @logger.debug("S3 input: Adding to objects[]", :key => log.key)
            end
          end
          day = day + 86400
        end
        @start_date = nil
        return objects.keys.sort {|a,b| objects[a] <=> objects[b]}
      end
    end
    
    if @end_date
      end_day = Time.parse(@end_date)
      if (Time.now > end_day)
        return objects
      end
    end
       

    @logger.debug("S3 input: Base prefix is " + @prefix)

    today = Time.now.strftime("%Y%m%d")
    @logger.debug("S3 input: today is " + today)

    today_prefix = @prefix.sub '%YYYYMMDD%', today
    @logger.debug("S3 input: Using prefix "+ today_prefix)

    yesterday = (Time.now - 86400).strftime("%Y%m%d")
    yesterday_prefix = @prefix.sub '%YYYYMMDD%', yesterday

    @logger.debug("S3 input: Using prefix " + today_prefix)
    
    # Checking in todays prefix
    @s3bucket.objects.with_prefix(today_prefix).each do |log|
      @logger.debug("S3 input: Found key in today prefix", :key => log.key)
      unless ignore_filename?(log.key)
        if sincedb.newer?(log.last_modified)
          objects[log.key] = log.last_modified
          @logger.debug("S3 input: Adding to objects[]", :key => log.key)
        end
      end
    end

    if @prefix.include? "%YYYYMMDD%"
      # Checking in yesterday prefix
      @s3bucket.objects.with_prefix(yesterday_prefix).each do |log|
        @logger.debug("S3 input: Found key in yesterday prefix", :key => log.key)
        unless ignore_filename?(log.key)
          if sincedb.newer?(log.last_modified)
            objects[log.key] = log.last_modified
            @logger.debug("S3 input: Adding to objects[]", :key => log.key)
          end
        end
      end
    end

    return objects.keys.sort {|a,b| objects[a] <=> objects[b]}
  end # def fetch_new_files


  public
  def backup_to_bucket(object, key)
    unless @backup_to_bucket.nil?
      backup_key = "#{@backup_add_prefix}#{key}"
      if @delete
        object.move_to(backup_key, :bucket => @backup_bucket)
      else
        object.copy_to(backup_key, :bucket => @backup_bucket)
      end
    end
  end

  public
  def backup_to_dir(filename)
    unless @backup_to_dir.nil?
      FileUtils.cp(filename, @backup_to_dir)
    end
  end

  private
  def process_log_stream(queue, key)
    object = @s3bucket.objects[key]

    if key.end_with?('.xz')
       @codec.decode(XZ.decompress(object.read)) do |event|
	 decorate(event) 
	 queue << event
       end
    else
       @codec.decode(object.read) do |event|
	 decorate(event)
	 queue << event
       end
     end
     backup_to_bucket(object, key)

     delete_file_from_bucket(object)
     	 
   end

  private
  def process_local_log(queue, filename)
    if @debug_skip_download
    	return
    end
    if filename.end_with?('.xz')
      @codec.decode(XZ.decompress(File.open(filename, 'rb').read)) do |event|
        decorate(event)
        queue << event
      end
    else
      @codec.decode(File.open(filename, 'rb').read) do |event|
        decorate(event)
        queue << event
      end
    end
  end # def process_local_log
  
  private
  def sincedb 
    @sincedb ||= if @sincedb_path.nil?
                    @logger.info("Using default generated file for the sincedb", :filename => sincedb_file)
                    SinceDB::File.new(sincedb_file)
                  else
                    @logger.error("S3 input: Configuration error, no HOME or sincedb_path set")
                    SinceDB::File.new(@sincedb_path)
                  end
  end

  private
  def hash(value)
     hashval = 0
     value.each_char do |c|
     hashval = hashval * 31 + c.ord
     end
  return hashval

  end


  private
  def sincedb_file
    partition_prefix = (@executor_id.nil?) ? -1 : @executor_id
    File.join(ENV["HOME"], ".sincedb_" + partition_prefix.to_s + "_" +Digest::MD5.hexdigest("#{@bucket}+#{@prefix}"))
  end

  private
  def process_files(queue, since=nil)
    objects = list_new_files
    objects.each do |key|
      @logger.debug("S3 input processing", :bucket => @bucket, :key => key)

      if @executor_id.nil?
        partition = 0
        @executor_id = "0"
      else
        partition = hash(key) % @total_executors
      end

      #if (partition == @executor_id.to_i)
      if (partition == 0)
        @logger.info("S3 input matched", :bucket => @bucket, :key => key)
        lastmod = @s3bucket.objects[key].last_modified
        #process_log(queue, key)
        process_log_stream(queue, key)

        sincedb.write(lastmod)
      else
           @logger.info("S3 input skipping", :bucket => @bucket, :key => key, :partition => partition, :executor_id => @executor_id.to_i)
      end
    end
  end # def process_files

  private
  def ignore_filename?(filename)
    if (@backup_add_prefix && @backup_to_bucket == @bucket && filename =~ /^#{backup_add_prefix}/)
      return true
    elsif @exclude_pattern.nil?
      return false
    elsif filename =~ Regexp.new(@exclude_pattern)
      return true
    else
      return false
    end
  end

  private
  def process_log(queue, key)
    object = @s3bucket.objects[key]

    tmp = Stud::Temporary.directory("logstash-")

    filename = File.join(tmp, File.basename(key))

    if !@debug_skip_download
	download_remote_file(object, filename)
    end

    process_local_log(queue, filename)

    backup_to_bucket(object, key)
    backup_to_dir(filename)

    FileUtils.rm_rf(tmp)

    delete_file_from_bucket(object)
  end

  private
  def download_remote_file(remote_object, local_filename)
    @logger.debug("S3 input: Download remove file", :remote_key => remote_object.key, :local_filename => local_filename)
    File.open(local_filename, 'wb') do |s3file|
      remote_object.read do |chunk|
        s3file.write(chunk)
      end
    end
  end

  private
  def delete_file_from_bucket(object)
    if @delete and @backup_to_bucket.nil?
      object.delete()
    end
  end

  private
  def get_region
    # TODO: (ph) Deprecated, it will be removed
    if @region_endpoint
      @region_endpoint
    else
      @region
    end
  end

  private
  def get_s3object
    # TODO: (ph) Deprecated, it will be removed
    if @credentials.length == 1
      File.open(@credentials[0]) { |f| f.each do |line|
        unless (/^\#/.match(line))
          if(/\s*=\s*/.match(line))
            param, value = line.split('=', 2)
            param = param.chomp().strip()
            value = value.chomp().strip()
            if param.eql?('AWS_ACCESS_KEY_ID')
              @access_key_id = value
            elsif param.eql?('AWS_SECRET_ACCESS_KEY')
              @secret_access_key = value
            end
          end
        end
      end
      }
    elsif @credentials.length == 2
      @access_key_id = @credentials[0]
      @secret_access_key = @credentials[1]
    end

    if @credentials
      s3 = AWS::S3.new(
        :access_key_id => @access_key_id,
        :secret_access_key => @secret_access_key,
        :region => @region
      )
    else
      s3 = AWS::S3.new(aws_options_hash)
    end
  end

  private
  def aws_service_endpoint(region)
    return { :s3_endpoint => region }
  end

  module SinceDB
    class File
      def initialize(file)
        @sincedb_path = file
      end

      def newer?(date)
        date > read
      end

      def read
        if ::File.exists?(@sincedb_path)
          since = Time.parse(::File.read(@sincedb_path).chomp.strip)
        else
          since = Time.new(0)
        end
        return since
      end

      def write(since = nil)
        since = Time.now() if since.nil?
        ::File.open(@sincedb_path, 'w') { |file| file.write(since.to_s) }
      end
    end
  end
end # class LogStash::Inputs::S3
