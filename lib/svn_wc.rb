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
#
#--
# TODO make sure args are what is expected for all methods
# TODO props
#     look into:
#     #wc_status = infos.assoc(@wc_path).last
#     #assert(wc_status.text_normal?)
#     #assert(wc_status.entry.dir?)
#     #assert(wc_status.entry.normal?)
#     #ctx.prop_set(Svn::Core::PROP_IGNORE, file2, dir_path)
#++

module SvnWc

  # (general) exception class raised on all errors 
  class RepoAccessError < RuntimeError ; end

  class RepoAccess

    VERSION = '0.0.1'

    DEFAULT_CONF_FILE  = File.join(File.dirname(File.dirname(\
                               File.expand_path(__FILE__))), 'svn_wc_conf.yaml')

    # initialization
    # three optional parameters
    # 1. Path to yaml conf file (default used, if none specified)
    # 2. Do a checkout from remote svn repo (usually, necessary with first 
    #    time set up only)
    # 3. Force. Overwrite anything that may be preventing a checkout

    def initialize(conf=nil, checkout=false, force=false)
      set_conf(conf)
      do_checkout(force) if checkout == true

      # instance var of out open repo session
      @ctx = svn_session
    end

    #--
    # TODO revist these
    #++
    attr_accessor :svn_user, :svn_pass, :svn_repo_master, \
                  :svn_repo_working_copy, :cur_file
    attr_reader :ctx, :repos

    def do_checkout(force=false)
      ## do checkout if not exists at specified local path
      if File.directory? @svn_repo_working_copy and not force
        raise RepoAccessError, 'target local directory  ' << \
        "[#{@svn_repo_working_copy}] exists, please remove" << \
        'or specify another directory'
      end
      checkout
    end

    def set_conf(conf)
      begin
      conf = load_conf(conf)
      @svn_user              = conf['svn_user']
      @svn_pass              = conf['svn_pass']
      @svn_repo_master       = conf['svn_repo_master']
      @svn_repo_working_copy = conf['svn_repo_working_copy']
      @config_path           = conf['svn_repo_config_path']
      Svn::Core::Config.ensure(@config_path)
      rescue Exception => e
        raise RepoAccessError, 'errors loading conf file'
      end
    end

    # checkout
    #
    # create a local working copy of a remote svn repo (creates dir if not
    # exist)
    # raises RepoAccessError if something goes wrong
    #

    def checkout
      if not File.directory? @svn_repo_working_copy
          begin
            FileUtils.mkdir_p @svn_repo_working_copy
          rescue Errno::EACCES => e
            raise RepoAccessError, e.message
          end
      end

      begin
        svn_session() { |ctx| 
           ctx.checkout(@svn_repo_master, @svn_repo_working_copy) 
        }
      rescue Svn::Error::RaLocalReposOpenFailed,
             Svn::Error::FsAlreadyExists,
             Exception => e
        raise RepoAccessError, e.message
      end
    end
    alias_method :co, :checkout
    
    #
    # load conf file (yaml)
    #
    # takes a path to a yaml config file, loads values. uses default if
    # nothing passed
    # raises RepoAccessError if something goes wrong
    #
    # private
    #

    def load_conf(cnf) # :nodoc:

      if cnf.nil? or cnf.empty? 
        cnf = IO.read(DEFAULT_CONF_FILE)
      elsif cnf and cnf.class == String and File.exists? cnf
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

    def add(files=[])

      # TODO make sure args are what is expected for all methods
      raise ArgumentError, 'files is empty' unless files

      svn_session() do |svn|
        begin
          files.each { |ef|
             svn.add(ef, true)
          }
        rescue Svn::Error::ENTRY_EXISTS, 
               Svn::Error::AuthnNoProvider,
               Svn::Error::WcNotDirectory,
               Svn::Error::SvnError => e
          raise RepoAccessError, "Add Failed: #{e.message}"
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

    def delete(files=[], recurs=nil)
      svn_session() do |svn|
        begin
          svn.delete(files)
        rescue Svn::Error::AuthnNoProvider,
               Svn::Error::WcNotDirectory,
               Svn::Error::ClientModified,
               Svn::Error::SvnError => e
          raise RepoAccessError, "Delete Failed: #{e.message}"
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
        rescue Svn::Error::WcNotDirectory,
               Svn::Error::AuthnNoProvider,
               Svn::Error::IllegalTarget,
               Svn::Error::EntryNotFound => e
          raise RepoAccessError, "Commit Failed: #{e.message}"
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
    #--
    # XXX refactor this (too long)
    #++
    def update(paths=[])

      if paths.empty? then paths = self.svn_repo_working_copy end
      #XXX update is a bummer, just returns the rev num, not affected files
      #(svn command line up, also returns altered/new files - mimic that)
      # hence our inplace hack
      #
      # unfortunetly, we cant use 'Repos',  only works on local filesystem repo
      # (NOT remote)
      #p Svn::Repos.open(@svn_repo_master) # Svn::Repos.open('/tmp/svnrepo')

      pre_up_entries = Array.new
      modified_entries = Array.new
      list_entries.each { |ent|
        ##puts "#{ent[:status]} | #{ent[:repo_rev]} | #{ent[:entry_name]}"
        pre_up_entries.push ent[:entry_name]
        ## how does it handle deletes?
        #if info()[:rev] != ent[:repo_rev]
        #  puts "changed file: #{File.join(paths, ent[:entry_name])} | #{ent[:status]} "
        #end
        if ent[:status] == 'M'
          modified_entries.push "#{ent[:status]}\t#{ent[:entry_name]}"
        end
      }

      rev = String.new
      svn_session() do |svn|
        begin
          #p svn.status paths
          rev = svn.update(paths, nil, 'infinity')
        rescue Svn::Error::WcNotDirectory,
               Svn::Error::AuthnNoProvider, #Svn::Error::FS_NO_SUCH_REVISION,
               Svn::Error::EntryNotFound => e
          raise RepoAccessError, "Update Failed: #{e.message}"
        end
      end

      post_up_entries = Array.new
      list_entries.each { |ent| post_up_entries.push ent[:entry_name] }

      added = post_up_entries - pre_up_entries
      removed = pre_up_entries - post_up_entries

      if added.length > 0 ;
          added.each {|e| modified_entries.push "A\t#{e}" }
      end

      if  removed.length > 0
          removed.each {|e| modified_entries.push "D\t#{e}" }
      end

      return rev, modified_entries

    end
    alias_method :up, :update
     
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

      wc_path = Svn::Core.path_canonicalize dir if File.directory? dir

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
        rescue Svn::Error::WcNotDirectory,
                RuntimeError => svn_err
          raise RepoAccessError, "status check Failed: #{svn_err}"
        end
      end
   
      files = Array.new
      infos.each {|r|
        #p r.inspect
        # file is not modified, we don't want to see it (this is 'status')
        next if ' ' == status_codes(r[1].text_status)
        f_rec = Hash.new
        f_rec[:path] = r[0]
        f_rec[:status] = status_codes(r[1].text_status)
        files.push f_rec
      }

      files

    end
    private :do_status

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
            f_rec[:entry] = (path.empty? ? abs_path : File.join(abs_path, path))
            f_rec[:last_changed_rev] = dirent.created_rev
            paths.push f_rec
          end
        rescue Svn::Error::WcNotDirectory,
               Svn::Error::AuthnNoProvider,
               Svn::Error::FS_NO_SUCH_REVISION,
               Svn::Error::EntryNotFound => e
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
      @entry_list = []
      show = true
      Svn::Wc::AdmAccess.open(nil, dir, false, 5) do |adm|
        if file.nil?
          #also see walk_entries (in svn bindings) has callback
          adm.read_entries.keys.sort.each { |ef|
            next unless ef.length >= 1 # why this check and not file.exists?
            f_path = File.join(dir, ef)
            if File.file? f_path
              _collect_get_entry_info(f_path, adm, show, verbose)
            elsif File.directory? f_path
              _walk_entries(f_path, adm, show, verbose)
            end
          }
        else
          _collect_get_entry_info(file, adm, show, verbose)
        end
      end
      @entry_list
    end

    #
    # private
    #
    # given a dir, iterate each entry, getting detailed file entry info
    #

    def _walk_entries(f_path, adm, show, verbose)#:nodoc:
      Dir.entries(f_path).each do |de|
        next if de == '..' or de == '.' or de == '.svn'
        fp_path  = File.join(f_path, de)
        _collect_get_entry_info(fp_path, adm, show, verbose)
      end
    end
    private :_walk_entries
    

    #
    # private
    #
    # _collect_get_entry_info - initialize empty class varialbe
    # @status_info to keep track of entries, push that onto
    # class variable @entry_list a hash of very useful svn info of each entry
    # requested
    #

    def _collect_get_entry_info(abs_path_file, adm, show, verbose=false)#:nodoc:
      @status_info = {}
      _get_entry_info(abs_path_file, adm, show, verbose)
      @entry_list.push @status_info
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

    def _get_entry_info(abs_path_file, adm, show, verbose=false) # :nodoc:
      wc = self.svn_repo_working_copy
      entry_repo_location = abs_path_file[(wc.length+1)..-1]

      entry = Svn::Wc::Entry.new(abs_path_file, adm, show)
      @status_info[:entry_name] = entry_repo_location

      status = adm.status(abs_path_file)
      return if status.entry.nil?

      @status_info[:status]   = status_codes(status.text_status)
      @status_info[:repo_rev] = status.entry.revision
      @status_info[:kind]     = status.entry.kind

      if @status_info[:kind] == 2
        # remove the repo root abs path, give dirs relative to repo root
        @status_info[:dir_name] = entry_repo_location
        # XXX hmmm, this is a little like a goto, revisit this
        _walk_entries(abs_path_file, adm, show, verbose)
      end
      return if verbose == false
      # only on demand ; i.e. verbose = true
      @status_info[:lock_creation_date] = status.entry.lock_creation_date
      @status_info[:entry_conflict] = entry.conflicted?(abs_path_file)
      @status_info[:present_props]  = status.entry.present_props
      @status_info[:has_prop_mods]  = status.entry.has_prop_mods
      @status_info[:copyfrom_url]   = status.entry.copyfrom_url
      @status_info[:conflict_old]   = status.entry.conflict_old
      @status_info[:conflict_new]   = status.entry.conflict_new
      @status_info[:lock_comment]   = status.entry.lock_comment
      @status_info[:copyfrom_rev]   = status.entry.copyfrom_rev
      @status_info[:working_size]   = status.entry.working_size
      @status_info[:conflict_wrk]   = status.entry.conflict_wrk
      @status_info[:cmt_author]     = status.entry.cmt_author
      @status_info[:changelist]     = status.entry.changelist
      @status_info[:lock_token]     = status.entry.lock_token
      @status_info[:keep_local]     = status.entry.keep_local
      @status_info[:lock_owner]     = status.entry.lock_owner
      @status_info[:prop_time]      = status.entry.prop_time
      @status_info[:has_props]      = status.entry.has_props
      @status_info[:schedule]       = status.entry.schedule
      @status_info[:text_time]      = status.entry.text_time
      @status_info[:revision]       = status.entry.revision
      @status_info[:checksum]       = status.entry.checksum
      @status_info[:cmt_date]       = status.entry.cmt_date
      @status_info[:prejfile]       = status.entry.prejfile
      @status_info[:is_file]        = status.entry.file?
      @status_info[:normal?]        = status.entry.normal?
      @status_info[:cmt_rev]        = status.entry.cmt_rev
      @status_info[:deleted]        = status.entry.deleted
      @status_info[:absent]         = status.entry.absent
      @status_info[:is_add]         = status.entry.add?
      @status_info[:is_dir]         = status.entry.dir?
      @status_info[:repos]          = status.entry.repos
      @status_info[:depth]          = status.entry.depth
      @status_info[:uuid]           = status.entry.uuid
      @status_info[:url]            = status.entry.url
    end
    private :_get_entry_info

    # get detailed repository info about a specific file or (by default) 
    # the entire repository
    #-- 
    # TODO - document all the params available from this command
    #++
    #
    def info(file='')
      if file and not (file.empty? or file.nil? or file.class != String)
        wc_path = file
      else
        wc_path = self.svn_repo_working_copy
      end

      r_info = {}
      begin
        @ctx.info(wc_path) do |path, type|
          r_info[:last_changed_author] = type.last_changed_author
          r_info[:last_changed_rev]  = type.last_changed_rev
          r_info[:last_changed_date] = type.last_changed_date
          r_info[:conflict_old]    = type.conflict_old
          r_info[:tree_conflict]   = type.tree_conflict
          r_info[:repos_root_url]  = type.repos_root_url
          r_info[:repos_root_URL]  = type.repos_root_URL
          r_info[:copyfrom_rev]    = type.copyfrom_rev
          r_info[:copyfrom_url]    = type.copyfrom_url
          r_info[:working_size]    = type.working_size
          r_info[:conflict_wrk]    = type.conflict_wrk
          r_info[:conflict_new]    = type.conflict_new
          r_info[:has_wc_info]     = type.has_wc_info
          r_info[:repos_UUID]      = type.repos_UUID
          r_info[:changelist]      = type.changelist
          r_info[:prop_time]       = type.prop_time
          r_info[:text_time]       = type.text_time
          r_info[:checksum]        = type.checksum
          r_info[:prejfile]        = type.prejfile
          r_info[:schedule]        = type.schedule
          r_info[:taguri]          = type.taguri
          r_info[:depth]           = type.depth
          r_info[:lock]            = type.lock
          r_info[:size]            = type.size
          r_info[:url]             = type.url
          r_info[:dup]             = type.dup
          r_info[:URL]             = type.URL
          r_info[:rev]             = type.rev
        end
      rescue Svn::Error::EntryNotFound,
             Svn::Error::RaIllegalUrl,
             Svn::Error::WcNotDirectory => e
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
        rescue Svn::Error::EntryNotFound => e
          raise RepoAccessError, "Diff Failed: #{e.message}"
        end
      end
      out_file.readlines
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
      auth_baton[Svn::Core::AUTH_PARAM_CONFIG_DIR] = @config_path
      auth_baton[Svn::Core::AUTH_PARAM_DEFAULT_USERNAME] = @svn_user
    end

  end

end

if __FILE__ == $0

  svn = SvnWc::RepoAccess.new
  p svn
  #n = '/tmp/NEW'
  #svn.add n
  #svn.commit n

end

