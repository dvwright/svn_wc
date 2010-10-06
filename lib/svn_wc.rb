#--
# Copyright (c) 2009 David Wright
# 
# You are free to modify and use this file under the terms of the GNU LGPL.
# You should have received a copy of the LGPL along with this file.
# 
# Alternatively, you can find the latest version of the LGPL here:
#      
#      http://www.gnu.org/licenses/lgpl.txt
# 
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.
#++

require 'yaml'
require 'pathname'
require 'find'
require 'svn/core'
require 'svn/client'
require 'svn/wc'
require 'svn/repos'
require 'svn/info'
require 'svn/error'

# = SvnWc::RepoAccess

# This module is designed to operate on a working copy (on the local filesystem)
# of a remote Subversion repository.
#
# It aims to provide (simple) client CLI type behavior, it does not do any 
# sort of repository administration type operations, just working directory repository management.
#
# == Current supported operations:
# * open
# * checkout/co
# * list/ls
# * update/up
# * commit/ci
# * status/stat
# * diff
# * info
# * add
# * revert
# * delete
# * log info
# * propset (ignore only)
# * svn+ssh is our primary connection use case, however can connect to, and operate on a (local) file:/// URI as well
#
# Is built on top of the SVN (SWIG) (Subversion) Ruby Bindings and requires that they be installed. 
#
# == Examples 
#
#    require 'svn_wc'
#
#    yconf = Hash.new
#    yconf['svn_user']              = 'test_user'
#    yconf['svn_pass']              = 'test_pass'
#    yconf['svn_repo_master']       = 'svn+ssh://www.example.com/svn_repository'
#    yconf['svn_repo_working_copy'] = '/opt/svn_repo'
#
#    svn = SvnWc::RepoAccess.new(YAML::dump(yconf), do_checkout=true, force=true)
#    # or, can pass path to conf file
#    #svn = SvnWc::RepoAccess.new(File.join(path_to_conf,'conf.yml'), do_checkout=true, force=true)
#
#    info = svn.info
#    puts info[:root_url]           # 'svn+ssh://www.example.com/svn_repository'
#
#    file = Tempfile.new('tmp', svn.svn_repo_working_copy).path
#    begin
#      svn.info(file)
#    rescue SvnWc::RepoAccessError => e
#      puts e.message.match(/is not under version control/)
#    end
#
#    svn.add file
#    puts svn.commit file               # returns the revision number of the commit
#    puts svn.status file               # ' ' empty string, file is current
#
#    File.open(file, 'a') {|f| f.write('adding this to file.')}
#    puts svn.status(file)[0][:status]  # 'M' (modified)
#    puts svn.info(file)[:rev]          # current revision of file
#
#    puts svn.diff(file)                # =~ 'adding this to file.'
#
#    svn.revert file                    # discard working copy changes, get current repo version
#    svn.commit file                    # -1 i.e commit failed, file is current
#
#    svn.delete file
#    svn.commit file  # must commit our delete
#    puts "#{file} deleted' unless File.exists? file
#
#    (In general also works with an Array of files)
#    See test/* for more examples.
#
# See the README.rdoc for more
#
# Category::    Version Control System/SVN/Subversion Ruby Lib
# Package::     SvnWc::RepoAccess
# Author::      David V. Wright <david_v_wright@yahoo.com>
# License::     LGPL License
#
#--
# TODO make sure args are what is expected for all methods
# TODO propset/propget, 
#     look into:
#     #wc_status = infos.assoc(@wc_path).last
#     #assert(wc_status.text_normal?)
#     #assert(wc_status.entry.dir?)
#     #assert(wc_status.entry.normal?)
#     #ctx.prop_set(Svn::Core::PROP_IGNORE, file2, dir_path)
#
# currently, propset IGNORE is enabled
#
# TODO/Think About Delegation: (do we want to do this?)
#      Inherit from or mixin the svn bindings directly, so method calls
#      not defined here explicitly can be run againt the bindings directly
#      (i.e. begin ; send(svn ruby binding method signature) ; rescue)
#++
module SvnWc

  # (general) exception class raised on all errors 
  class RepoAccessError < RuntimeError ; end

  #
  # class that provides API to (common) svn operations (working copy of a repo)
  # also exposes the svn ruby bindings directly
  #
  # It aims to provide (simple) client CLI type behavior,
  # for working directory repository management.  in an API
  #
  class RepoAccess

    VERSION = '0.0.3'

    # initialization
    # three optional parameters
    # 1. Path to yaml conf file (default used, if none specified)
    # 2. Do a checkout from remote svn repo (usually, necessary with first 
    #    time set up only)
    # 3. Force. Overwrite anything that may be preventing a checkout

    def initialize(conf=nil, checkout=false, force=false)
      set_conf(conf) if conf
      do_checkout(force) if checkout == true

      # instance var of out open repo session
      @ctx = svn_session
    end

    #
    # 'expose the abstraction'
    # introduce Delegation, if we don't define the method pass it on to the
    # ruby bindings. 
    #
    #--
    # (yup, this is probably asking for trouble)
    #++
    #
    def method_missing(sym, *args, &block)
      @ctx.send sym, *args, &block
    end

    #--
    # TODO revist these
    #++
    attr_accessor :svn_user, :svn_pass, :svn_repo_master,
                  :svn_repo_working_copy, :cur_file,
                  :svn_repo_config_path, :svn_repo_config_file,
                  :force_checkout
    attr_reader :ctx, :repos

    #
    # set config file with abs path
    #
    def set_conf(conf)
      begin
        conf = load_conf(conf)
        @svn_user              = conf['svn_user']
        @svn_pass              = conf['svn_pass']
        @force_checkout        = conf['force_checkout']
        @svn_repo_master       = conf['svn_repo_master']
        @svn_repo_working_copy = conf['svn_repo_working_copy']
        @svn_repo_config_path  = conf['svn_repo_config_path']
        Svn::Core::Config.ensure(@svn_repo_config_path)
      rescue Exception => e
        raise RepoAccessError, 'errors loading conf file'
      end
    end


    def do_checkout(force=false)
      if @svn_repo_working_copy.nil? 
        raise RepoAccessError, 'conf file not loaded! - Fatal Error' 
      end
      ## do checkout if not exists at specified local path

      if force or @force_checkout
        begin
          FileUtils.rm_rf @svn_repo_working_copy
          FileUtils.mkdir_p @svn_repo_working_copy
        rescue Errno::EACCES => err
          raise RepoAccessError, err.message
        end
      else
        if File.directory? @svn_repo_working_copy
          raise RepoAccessError, 'target local directory  ' << \
          "[#{@svn_repo_working_copy}] exists, please remove" << \
          'or specify another directory'
        end
        begin
          FileUtils.mkdir_p @svn_repo_working_copy
        rescue Errno::EACCES => err
          raise RepoAccessError, err.message
        end
      end

      checkout
    end

    # checkout
    #
    # create a local working copy of a remote svn repo (creates dir if not
    # exist)
    # raises RepoAccessError if something goes wrong
    #

    def checkout
      begin
        svn_session() do |ctx|
           ctx.checkout(@svn_repo_master, @svn_repo_working_copy)
        end
      #rescue Svn::Error::RaLocalReposOpenFailed,
      #       Svn::Error::FsAlreadyExists,
      #rescue Errno::EACCES => e
      rescue Exception => err
        raise RepoAccessError, err.message
      end
    end
    alias_method :co, :checkout
    
    #
    # load conf file (yaml)
    #
    # takes a path to a yaml config file, loads values.
    # raises RepoAccessError if something goes wrong
    #
    # private
    #

    def load_conf(cnf) # :nodoc:

      if cnf.nil? or cnf.empty? 
        raise RepoAccessError, 'No config file provided!'
      elsif cnf and cnf.class == String and File.exists? cnf
        @svn_repo_config_file = cnf
        cnf = IO.read(cnf)
      end

      begin
        YAML::load(cnf)
       rescue Exception => e
        raise RepoAccessError, e.message
      end
    end
    private :load_conf

    #
    # add entities to the repo
    #
    # pass a single entry or list of file(s) with fully qualified path,
    # which must exist,
    #
    # raises RepoAccessError if something goes wrong
    #
    #--
    # "svn/client.rb"  Svn::Client
    #  def add(path, recurse=true, force=false, no_ignore=false)
    #    Client.add3(path, recurse, force, no_ignore, self)
    #  end
    #++

    def add(files=[], recurse=true, force=false, no_ignore=false)

      # TODO make sure args are what is expected for all methods
      raise ArgumentError, 'files is empty' unless files

      svn_session() do |svn|
        begin
          files.each do |ef|
             svn.add(ef, recurse, force, no_ignore)
          end
        #rescue Svn::Error::ENTRY_EXISTS, 
        #       Svn::Error::AuthnNoProvider,
        #       #Svn::Error::WcNotDirectory,
        #       Svn::Error::SvnError => e
        rescue Exception => excp
          raise RepoAccessError, "Add Failed: #{excp.message}"
        end
      end
    end

    #
    # delete entities from the repository
    #
    # pass single entity or list of files with fully qualified path,
    # which must exist,
    #
    # raises RepoAccessError if something goes wrong
    #

    def delete(files=[], recurs=false)
      svn_session() do |svn|
        begin
          svn.delete(files)
        #rescue Svn::Error::AuthnNoProvider,
        #       #Svn::Error::WcNotDirectory,
        #       Svn::Error::ClientModified,
        #       Svn::Error::SvnError => e
        rescue Exception => err
          raise RepoAccessError, "Delete Failed: #{err.message}"
        end
      end
    end
    alias_method :rm, :delete


    #
    # commit entities to the repository
    #
    # params single or list of files (full relative path (to repo root) needed)
    #
    # optional message
    #
    # raises RepoAccessError if something goes wrong
    # returns the revision of the commmit
    #

    def commit(files=[], msg='')
      if files and files.empty? or files.nil? then files = self.svn_repo_working_copy end

      rev = ''
      svn_session(msg) do |svn|
        begin
          rev = svn.commit(files).revision
        #rescue Svn::Error::AuthnNoProvider,
        #       #Svn::Error::WcNotDirectory,
        #       Svn::Error::IllegalTarget,
        #       #Svn::Error::EntryNotFound => e
        #       Exception => e
        rescue Exception => err
          raise RepoAccessError, "Commit Failed: #{err.message}"
        end
      end
      rev
    end
    alias_method :ci, :commit

    #
    # update local working copy with most recent (remote) repo version
    # (does not resolve conflict - or alert or anything at the moment)
    #
    # if nothing passed, does repo root
    #
    # params optional:
    # single or list of files (full relative path (to repo root) needed)
    #
    # raises RepoAccessError if something goes wrong
    #
    # alias up
    def update(paths=[])

      if paths.empty? then paths = self.svn_repo_working_copy end
      #XXX update is a bummer, just returns the rev num, not affected files
      #(svn command line up, also returns altered/new files - mimic that)
      # hence our inplace hack (_pre/_post update_entries)
      #
      # unfortunetly, we cant use 'Repos',  only works on local filesystem repo
      # (NOT remote)
      #p Svn::Repos.open(@svn_repo_master) # Svn::Repos.open('/tmp/svnrepo')
      _pre_update_entries

      rev = String.new
      svn_session() do |svn|
        begin
          #p svn.status paths
          rev = svn.update(paths, nil, 'infinity')
        #rescue Svn::Error::AuthnNoProvider, 
        #       #Svn::Error::FS_NO_SUCH_REVISION,
        #       #Svn::Error::WcNotDirectory,
        #       #Svn::Error::EntryNotFound => e
        #       Exception => e
        rescue Exception => err
          raise RepoAccessError, "Update Failed: #{err.message}"
        end
      end

      _post_update_entries

      return rev, @modified_entries

    end
    alias_method :up, :update

    #
    # get list of entries before doing an update
    #
    def _pre_update_entries #:nodoc:
      @pre_up_entries = Array.new
      @modified_entries = Array.new
      list_entries.each do |ent|
        ##puts "#{ent[:status]} | #{ent[:repo_rev]} | #{ent[:entry_name]}"
        e_name = ent[:entry_name]
        stat = ent[:status]
        @pre_up_entries.push e_name
        ## how does it handle deletes?
        #if info()[:rev] != ent[:repo_rev]
        #  puts "changed file: #{File.join(paths, ent[:entry_name])} | #{ent[:status]} "
        #end
        if stat == 'M' then @modified_entries.push "#{stat}\t#{e_name}" end
      end
    end
    private :_pre_update_entries
    
    #
    # get list of entries after doing an update
    #
    def _post_update_entries #:nodoc:
      post_up_entries = Array.new
      list_entries.each { |ent| post_up_entries.push ent[:entry_name] }

      added   = post_up_entries - @pre_up_entries
      removed = @pre_up_entries - post_up_entries

      if added.length > 0
          added.each {|e_add| @modified_entries.push "A\t#{e_add}" }
      end

      if  removed.length > 0
          removed.each {|e_rm| @modified_entries.push "D\t#{e_rm}" }
      end

    end
    private :_post_update_entries

 
    #
    # get status on dir/file path.
    #
    # if nothing passed, does repo root
    #
    #--
    # TODO/XXX add optional param to return results as a data structure
    # (current behavior)
    # or as a puts 'M' File (like the CLI version, have the latter as the
    # default, this avoids the awkward s.status(file)[0][:status] notation
    # one could just say: s.status file and get the list displayed on stdout
    #++
    def status(path='')

      raise ArgumentError, 'path not a String' if ! (path or path.class == String)

      if path and path.empty? then path = self.svn_repo_working_copy end

      status_info = Hash.new

      if File.file?(path)
        # is single file path
        file = path
        status_info = do_status(File.dirname(path), file)
      elsif File.directory?(path)
        status_info = do_status(path) 
      else
        raise RepoAccessError, "Arg is not a file or directory"
      end
     status_info

    end
    alias_method :stat, :status


    #
    # get status of all entries at (passed) dir level in repo
    # use repo root if not specified
    #
    # private does the real work for 'status'
    #
    # @params [String] optional params, defaults to repo root
    #                          if file passed, get specifics on file, else get
    #                          into on all in dir path passed
    # @returns [Hash] path/status of entries at dir level passed
    #

    def do_status(dir=self.svn_repo_working_copy, file=nil) # :nodoc:

      # set default
      wc_path = Svn::Core.path_canonicalize dir if File.directory? dir

      # override default if set
      wc_path = Svn::Core.path_canonicalize file \
               if (!file.nil? && File.file?(file))

      infos = Array.new
      svn_session() do |svn|
        begin
          # from client.rb
          rev = svn.status(wc_path, rev=nil, depth_or_recurse='infinity',
                           get_all=true, update=true, no_ignore=false,
                           changelists_name=nil #, &status_func
          ) do |path, status|
            infos << [path, status]
          end
        rescue RuntimeError,
                #Svn::Error::WcNotDirectory,
                Exception => svn_err
          raise RepoAccessError, "status check Failed: #{svn_err}"
        end
      end
   
      _file_list infos

    end
    private :do_status


    #
    # create and return list of anon hashes
    # set hashes to contain :path and :status
    #
    def _file_list(info_list) # :nodoc:
      files = Array.new
      info_list.each {|r|
        #p r.inspect
        # file is not modified, we don't want to see it (this is 'status')
        txt_stat = r[1].text_status
        next if ' ' == status_codes(txt_stat)
        f_rec = Hash.new
        f_rec[:path] = r[0]
        f_rec[:status] = status_codes(txt_stat)
        files.push f_rec
      }
      files
    end
    private :_file_list

    #
    # list (ls)
    #
    # list all entries at (passed) dir level in repo
    # use repo root if not specified
    #
    # no repo/file info is returned, just a list of files, with abs_path
    #
    # optional
    #
    # @params [String] working copy directory, defaults to repo root
    #                          if dir  passed, get list for dir, else
    #                          repo_root
    #
    # @params [String] revision, defaults to 'head' (others untested)
    #
    # @params [String] verbose, not currently enabled
    #
    # @params [String] depth of list, default, 'infinity', (whole repo)
    #                  (read the Doxygen docs for possible values - sorry)
    #
    # @returns [Array] list of entries at dir level passed
    #

    def list(wc_path=self.svn_repo_working_copy, rev='head', 
                     verbose=nil, depth='infinity')
      paths = []
      svn_session() do |svn|

        begin
          svn.list(wc_path, rev, verbose, depth) do |path, dirent, lock, abs_path|
            #paths.push(path.empty? ? abs_path : File.join(abs_path, path))
            f_rec = Hash.new
            f_rec[:entry] = path
            f_rec[:last_changed_rev] = dirent.created_rev
            paths.push f_rec
          end
        #rescue Svn::Error::AuthnNoProvider,
        #       #Svn::Error::WcNotDirectory,
        #       Svn::Error::FS_NO_SUCH_REVISION,
        #       #Svn::Error::EntryNotFound => e
        #       Exception => e
        rescue Exception => e
          raise RepoAccessError, "List Failed: #{e.message}"
        end
      end

      paths

    end
    alias_method :ls, :list

    #--
    # TODO what is this? look into, revisit
    #entr = svn.ls(paths,'HEAD')
    #entr.each {|ent| 
    #    ent.each {|k,dir_e| 
    #      next unless dir_e.class == Svn::Ext::Core::Svn_dirent_t
    #      puts "#{dir_e.kind} | #{dir_e.created_rev} | #{dir_e.time2} | #{dir_e.last_author} "
    #      #puts dir_e.public_methods
    #      #puts "#{k} -> #{v.kind} : #{v.created_rev}" 
    #  }
    #}
    #++
 
    # Get list of all entries at (passed) dir level in repo
    # use repo root if nothing passed 
    #
    # params [String, String, String] optional params, defaults to repo root
    #                          if file passed, get specifics on file, else get
    #                          into on all in dir path passed
    #                          3rd arg is verbose flag, if set to true, lot's
    #                          more info is returned about the object
    # returns [Array] list of entries in svn repository
    #

    def list_entries(dir=self.svn_repo_working_copy, file=nil, verbose=false)

      @entry_list, @show, @verbose = [], true, verbose

      Svn::Wc::AdmAccess.open(nil, dir, false, 5) do |adm|
        @adm = adm
        if file.nil?
          #also see walk_entries (in svn bindings) has callback
          adm.read_entries.keys.sort.each { |ef|
            next unless ef.length >= 1 # why this check and not file.exists?
            _collect_get_entry_info(File.join(dir, ef))
          }
        else
          _collect_get_entry_info(file)
        end
      end
      #XXX do we want nil or empty on no entries, choosing empty for now
      #@entry_list unless @entry_list.empty?
      @entry_list
    end

    #
    # private
    #
    # _collect_get_entry_info - initialize empty class varialbe
    # @status_info to keep track of entries, push that onto
    # class variable @entry_list a hash of very useful svn info of each entry
    # requested
    #

    def _collect_get_entry_info(abs_path_file) #:nodoc:
      if File.directory?(abs_path_file)
        Dir.entries(abs_path_file).each do |de|
          next if de == '..' or de == '.' or de == '.svn'
          status_info = _get_entry_info(File.join(abs_path_file, de))
          @entry_list.push status_info if status_info and not status_info.empty?
        end
      else
        status_info = _get_entry_info(abs_path_file)
        @entry_list.push status_info if status_info and not status_info.empty?
      end
    end
    private :_collect_get_entry_info

    #
    # private
    #
    # _get_entry_info - set's class varialbe @status_info (hash)
    # with very useful svn info of each entry requested
    # needs an Svn::Wc::AdmAccess token to obtain detailed repo info
    #
    # NOTE: just does one entry at a time, set's a hash of that one
    # entries svn info
    #-- 
    # TODO - document all the params available from this command
    #++

    def _get_entry_info(abs_path_file) # :nodoc:
      wc = self.svn_repo_working_copy
      entry_repo_location = abs_path_file[(wc.length+1)..-1]

      entry = Svn::Wc::Entry.new(abs_path_file, @adm, @show)
      #@status_info[:entry_name] = entry_repo_location

      status = @adm.status(abs_path_file)
      return if status.entry.nil?

      status_info = Hash.new
      status_info[:entry_name] = entry_repo_location
      status_info[:status]     = status_codes(status.text_status)
      status_info[:repo_rev]   = status.entry.revision
      status_info[:kind]       = status.entry.kind

      if status_info[:kind] == 2
        # remove the repo root abs path, give dirs relative to repo root
        status_info[:dir_name] = entry_repo_location
        _collect_get_entry_info(abs_path_file)
      end
      return status_info if @verbose == false
      # only on demand ; i.e. verbose = true
      status_info[:entry_conflict]     = entry.conflicted?(abs_path_file)
      s_entry_info = %w(
                        lock_creation_date present_props has_prop_mods
                        copyfrom_url conflict_old conflict_new
                        lock_comment copyfrom_rev conflict_wrk
                        cmt_author lock_token lock_owner
                        prop_time has_props schedule text_time revision 
                        checksum cmt_date prejfile normal? file? add? dir?
                        cmt_rev deleted absent repos uuid url
                       ) # working_size changelist keep_local depth

      s_entry_info.each do |each_info|
        status_info[:"#{each_info}"] = status.entry.method(:"#{each_info}").call
      end
      status_info
    end
    private :_get_entry_info

    # get detailed repository info about a specific file or (by default) 
    # the entire repository
    #-- 
    # TODO - document all the params available from this command
    #++
    #
    def info(file=nil)
      wc_path = self.svn_repo_working_copy
      wc_path = file if file and file.class == String

      r_info = Hash.new
      type_info = %w(
                     last_changed_author last_changed_rev
                     last_changed_date conflict_old
                     repos_root_url repos_root_URL
                     copyfrom_rev copyfrom_url conflict_wrk 
                     conflict_new has_wc_info repos_UUID
                     checksum prop_time text_time prejfile
                     schedule taguri lock rev dup url URL
                    ) # changelist depth size tree_conflict working_size

      begin
        @ctx.info(wc_path) do |path, type|
          type_info.each do |t_info|
            r_info[:"#{t_info}"] = type.method(:"#{t_info}").call
          end
        end
      #rescue Svn::Error::WcNotDirectory => e
      #       #Svn::Error::RaIllegalUrl,
      #       #Svn::Error::EntryNotFound,
      #       #Svn::Error::RaIllegalUrl,
      #       #Svn::Error::WC_NOT_DIRECTORY
      #       #Svn::Error::WcNotDirectory => e
      rescue Exception => e
        raise RepoAccessError, "cant get info: #{e.message}"
      end
      r_info
     
    end


    #--
    # this is a good idea but the mapping implementation is crappy, 
    # the svn SWIG bindings *could* (although, unlikly?) change,
    # in which case this mapping would be wrong
    #
    # TODO get the real status message, (i.e. 'none', modified, etc) 
    # and map that to the convenience single character i.e. A, M, ?
    #--
    def status_codes(status) # :nodoc:
      if status == 0 ; raise RepoAccessError, 'Zero Status Unknown' ; end
      status -= 1
      # See this
      #http://svn.collab.net/svn-doxygen/svn__wc_8h-source.html#l03422
      #enum svn_wc_status_kind
      #++
      status_map = [
                ' ', #"svn_wc_status_none"         => 1,
                '?', #"svn_wc_status_unversioned"  => 2,
                ' ', #"svn_wc_status_normal"       => 3,
                'A', #"svn_wc_status_added"        => 4,
                '!', #"svn_wc_status_missing"      => 5,
                'D', #"svn_wc_status_deleted"      => 6,
                'R', #"svn_wc_status_replaced"     => 7,
                'M', #"svn_wc_status_modified"     => 8,
                'G', #"svn_wc_status_merged"       => 9,
                'C', #"svn_wc_status_conflicted"   => 10,
                'I', #"svn_wc_status_ignored"      => 11,
                '~', #"svn_wc_status_obstructed"   => 12,
                'X', #"svn_wc_status_external"     => 13,
                '!', #"svn_wc_status_incomplete"   => 14
      ]
      status_map[status]
    end
    private :status_codes

    # discard working copy changes, get current repository entry
    def revert(file_path='')
      if file_path.empty? then file_path = self.svn_repo_working_copy end
      svn_session() { |svn| svn.revert(file_path) }
    end
 
    # By Default compares current working directory file with 'HEAD' in
    # repository (NOTE: does not yet support diff to previous revisions)
    #--
    # TODO support diffing previous revisions
    #++
    def diff(file='', rev1='', rev2='')
      raise ArgumentError, 'file list empty or nil' unless file and file.size

      raise RepoAccessError, "Diff requires an absolute path to a file" \
         unless File.exists? file

      # can also use new (updated) svn.status(f)[0][:repo_rev]
      rev = info(file)[:rev] 
      out_file = Tempfile.new("svn_diff")
      err_file = Tempfile.new("svn_diff")
      svn_session() do |svn|
        begin
          svn.diff([], file, rev, file, "WORKING", out_file.path, err_file.path)
        rescue Exception => e
               #Svn::Error::EntryNotFound => e
          raise RepoAccessError, "Diff Failed: #{e.message}"
        end
      end
      out_file.readlines
    end

    # currently supports type='ignore' only
    #--
    # TODO support other propset's ; also propget
    #++
    def propset(type, files, dir_path=self.svn_repo_working_copy)
      raise RepoAccessError, 'currently, "ignore" is the only supported propset' \
             unless type == 'ignore'

      svn_session() do |svn|
        files.each do |ef|
          begin
            svn.propset(Svn::Core::PROP_IGNORE, ef, dir_path)
          rescue Exception => e #Svn::Error::EntryNotFound => e
            raise RepoAccessError, "Propset (Ignore) Failed: #{e.message}"
          end
        end
      end
    end

    # svn session set up
    #--
    # from
    # http://svn.collab.net/repos/svn/trunk/subversion/bindings/swig/ruby/test/util.rb
    #++
    def svn_session(commit_msg = String.new) # :nodoc:
      ctx = Svn::Client::Context.new
    
      # Function for commit messages
      ctx.set_log_msg_func do |items|
        [true, commit_msg]
      end

      # don't fail on non CA signed ssl server
      ctx.add_ssl_server_trust_file_provider

      setup_auth_baton(ctx.auth_baton)
      ctx.add_username_provider
    
      # username and password
      ctx.add_simple_prompt_provider(0) do |cred, realm, username, may_save|
        cred.username = @svn_user
        cred.password = @svn_pass
        cred.may_save = false
      end

      return ctx unless block_given?

      begin
        yield ctx
      #ensure
      #  warning!?
      #  ctx.destroy
      end
    end

    def setup_auth_baton(auth_baton) # :nodoc:
      auth_baton[Svn::Core::AUTH_PARAM_CONFIG_DIR] = @svn_repo_config_path
      auth_baton[Svn::Core::AUTH_PARAM_DEFAULT_USERNAME] = @svn_user
    end

  end

end
