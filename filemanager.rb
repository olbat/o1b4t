# Copyright 2011 - Luc Sarzyniec <mail@olbat.net>

require 'semaphore'
require 'errors'
require 'thread'
require 'uri'
require 'digest/sha2'


# Thread-safe library that allow you to download, extract, compress and hash (archive) files
class FileManager
  # The maximum simultaneous extracting task number
  MAX_SIMULTANEOUS_EXTRACT = 8
  # The maximum simultaneous caching archive task number
  MAX_SIMULTANEOUS_CACHE = 4
  # The maximum simultaneous hashing task number
  MAX_SIMULTANEOUS_HASH = 4

  # The directory used to store downloaded files
  PATH_DEFAULT_DOWNLOAD='/tmp/downloads/'
  # The directory used to store archive extraction cache
  PATH_DEFAULT_CACHE='/tmp/extractcache/'
  # The directory used to store compressed files
  PATH_DEFAULT_COMPRESS='/tmp/files/'

  BIN_TAR='tar' # :nodoc:
  BIN_GUNZIP='gunzip' # :nodoc:
  BIN_BUNZIP2='bunzip2' # :nodoc:
  BIN_UNZIP='unzip' # :nodoc:

  @@extractsem = Semaphore.new(MAX_SIMULTANEOUS_EXTRACT) # :nodoc:
  @@cachesem = Semaphore.new(MAX_SIMULTANEOUS_CACHE) # :nodoc:
  @@hashsem = Semaphore.new(MAX_SIMULTANEOUS_HASH) # :nodoc:
  @@archivecachelock = {} # :nodoc:
  @@hashcachelock = {} # :nodoc:
  @@hashcache = {} # :nodoc:
  @@archivecache = [] # :nodoc:
  
  # Download a file using a specific protocol and store it on the local machine
  # ==== Attributes
  # * +uri_str+ The URI of the file to download
  # * +dir+ The directory to save the file to
  # ==== Returns
  # String value describing the path to the downloaded file on the local machine
  # ==== Exceptions
  # * +InvalidParameterError+ if the specified URI is not valid
  # * +ResourceNotFoundError+ if can't reach the specified file
  # * +NotImplementedError+ if the protocol specified in the URI is not supported (atm only file:// is supported)
  #
  def self.download(uri_str,dir=PATH_DEFAULT_DOWNLOAD)
    begin
      uri = URI.parse(URI.decode(uri_str))
    rescue URI::InvalidURIError
      raise InvalidParameterError, uri_str
    end

    ret = ""
    
    case uri.scheme
      when "file"
        ret = uri.path
        raise ResourceNotFoundError, ret unless File.exists?(ret)
      else
        raise NotImplementedError, uri.scheme
    end

    return ret
  end

  # Extract an archive file in the specified directory using a cache. The cache: if unarchiving two times the same archive, the unarchive cache is used to only have to copy files from the cache (no need to unarchive another time). Only MAX_SIMULTANEOUS_EXTRACT files can be extracted at the same time (semaphore).
  # ==== Attributes
  # * +archivefile+ The path to the archive file (String)
  # * +targetdir+ The directory to unarchive the file to
  # ==== Returns
  # String value describing the path to the directory (on the local machine) the file was unarchived to
  # ==== Exceptions
  # * +ResourceNotFoundError+ if can't reach the specified archive file
  # * +NotImplementedError+ if the archive file format is not supported (available: tar, gzip, bzip, zip, (tgz,...))
  #
  def self.extract(archivefile,targetdir="",override=true)
    raise ResourceNotFoundError, archivefile \
      unless File.exists?(archivefile)
    
    if targetdir.empty?
      targetdir = File.dirname(archivefile)
    end

    cachedir = cache_archive(archivefile)
    filehash = file_hash(archivefile)

    exists = File.exists?(targetdir) 
    if !exists or override
      @@extractsem.synchronize do
        system("mkdir -p #{targetdir}") unless exists
        system("cp -Rf #{File.join(cachedir,'*')} #{targetdir}")
      end
    end

    return targetdir
  end

  # Extract an archive file in the specified directory without using the cache and the MAX_SIMULTANEOUS_EXTRACT limitation.
  # ==== Attributes
  # * +archivefile+ The path to the archive file (String)
  # * +targetdir+ The directory to unarchive the file to
  # ==== Returns
  # String value describing the path to the directory (on the local machine) the file was unarchived to
  # ==== Exceptions
  # * +ResourceNotFoundError+ if can't reach the specified archive file
  # * +NotImplementedError+ if the archive file format is not supported (available: tar, gzip, bzip, zip, (tgz,...))
  #
  def self.extract!(archivefile,target_dir)
    raise ResourceNotFoundError, archivefile \
      unless File.exists?(archivefile)

    unless File.exists?(target_dir)
      system("mkdir -p #{target_dir}")
    end

    basename = File.basename(archivefile)
    extname = File.extname(archivefile)
    system("ln -sf #{archivefile} #{File.join(target_dir,basename)}")
    case extname
      when ".tar"
        system("cd #{target_dir}; #{BIN_TAR} xf #{basename}")
      when ".gz", ".gzip"
        if File.extname(File.basename(basename,extname)) == ".tar"
          system("cd #{target_dir}; #{BIN_TAR} xzf #{basename}")
        else
          system("cd #{target_dir}; #{BIN_GUNZIP} #{basename}")
        end
      when ".bz2", "bzip2"
        if File.extname(File.basename(basename,extname)) == ".tar"
          system("cd #{target_dir}; #{BIN_TAR} xjf #{basename}")
        else
          system("cd #{target_dir}; #{BIN_BUNZIP2} #{basename}")
        end
      when ".zip"
        system("cd #{target_dir}; #{BIN_UNZIP} #{basename}")
      else
        raise NotImplementedError, File.extname(archivefile)
    end

    system("rm #{File.join(target_dir,basename)}")
  end

  # Cache an archive fine in the cache. Only one file can be cached at the same time (mutex).
  # ==== Attributes
  # * +archivefile+ The path to the archive file (String)
  # ==== Returns
  # String value describing the path to the directory (on the local machine) the file was cached to
  # 
  def self.cache_archive(archivefile)
    filehash = file_hash(archivefile)
    cachedir = File.join(PATH_DEFAULT_CACHE,filehash)

    unless @@archivecache.include?(filehash)
      @@archivecachelock[filehash] = Mutex.new unless @@archivecachelock[filehash] 
      if @@archivecachelock[filehash].locked?
        @@archivecachelock[filehash].synchronize {}
      else
        @@archivecachelock[filehash].synchronize do
          @@cachesem.synchronize do
            if File.exists?(cachedir)
              system("rm -R #{cachedir}")
            end
            extract!(archivefile,cachedir)
          end
        end
      end
      @@archivecache << filehash unless @@archivecache.include?(filehash)
    end

    return cachedir
  end

  # Compress a file using TGZ archive format.
  # ==== Attributes
  # * +filepath+ The path to the file (String)
  # ==== Returns
  # String value describing the path to the directory (on the local machine) the generated archive file is store to
  # 
  def self.compress(filepath)
    raise ResourceNotFoundError, filepath \
      unless File.exists?(filepath)
    unless File.exists?(PATH_DEFAULT_COMPRESS)
      system("mkdir -p #{PATH_DEFAULT_COMPRESS}")
    end

    basename = File.basename(filepath)
    respath = "#{File.join(PATH_DEFAULT_COMPRESS,basename)}.tar.gz"
    system("#{BIN_TAR} czf #{respath} -C #{filepath} .")
    
    return respath
  end

  # Get a "unique" file identifier from a specific file
  # ==== Attributes
  # * +filename+ The path to the file (String)
  # ==== Returns
  # String value describing the "unique" hash
  #
  def self.file_hash(filename)
    unless @@hashcache[filename] and @@hashcache[filename][:mtime] == (mtime= File.mtime(filename))
      @@hashcachelock[filename] = Mutex.new unless @@hashcachelock[filename]
      if @@hashcachelock[filename].locked?
        @@hashcachelock[filename].synchronize{}
      else
        @@hashcachelock[filename].synchronize do
          @@hashsem.synchronize do
            mtime = File.mtime(filename) unless mtime
            @@hashcache[filename] = {
              :mtime => mtime,
              :hash => "#{File.basename(filename)}-#{mtime.to_i.to_s}-#{File.stat(filename).size.to_s}-#{Digest::SHA256.file(filename).hexdigest}"
            } unless @@hashcache[filename]
          end
        end
      end
    end
    return @@hashcache[filename][:hash]
  end
end