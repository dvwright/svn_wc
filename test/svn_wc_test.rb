# encoding: utf-8
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

require 'yaml'
require File.join(File.dirname(__FILE__), "..", "lib", 'svn_wc')
require 'test/unit'
require 'fileutils'
require 'tempfile'
require 'time'
require 'pp'

# Current test coverage:
# open repo : proves can ssh connect and can access repo
# svn checkout if local working copy not exist
# svn info
# svn add file(s)/dir(s)
# svn commit
# svn update
# svn revert
# svn status
# svn delete
# svn diff
# propset ignore
# log

# NOTE
# svn+ssh is our primary use case, however
# svn+ssh uses ssh authentication functionality, i.e. a valid
# user must exist on the box serving the svn repository
# while this is our target use, creating a test to do this
# involves work I dont feel is appropriate for a unit test
#
# if you do want to test this connection functionality, 
# I did write a test to do it, but you'll have to setup 
# your env your self to run it. (it's commented out)
#
# see: 'def test_checkout_remote_repo_svn_ssh'
#
# more: SSH authentication and authorization
#       http://svnbook.red-bean.com/en/1.0/ch06s03.html 


# unit tests to prove SvnWc::SvnAccess functionality.
class TestSvnWc < Test::Unit::TestCase

  @@svn_wc = SvnWc::RepoAccess.new
  
  def setup
    @conf = {
      #"svn_repo_master"       => "svn+ssh://localhost/home/dwright/svnrepo",
      "svn_repo_master"        => "file://#{Dir.mktmpdir('R')}",
      #"svn_user"              => "svn_test_user",
      #"svn_pass"              => "svn_test_pass",
      "svn_repo_working_copy" => "#{Dir.mktmpdir('F')}",
      "svn_repo_config_path"  => Dir.mktmpdir('N')
    }
    write_conf_file
    sys_create_repo
  end

  def write_conf_file
    @conf_file = new_unique_file_at_path(Dir.mktmpdir('C'))
    File.open(@conf_file, 'w') {|fl| fl.write YAML::dump(@conf) }
  end
  
  def sys_create_repo
    begin
      svnadmin =`which svnadmin`
      svn      =`which svn`
    rescue
      puts 'svn/svnadmin do not seem to be installed, Please install svn/svnadmin'
      exit 1
    end
    begin
      @svn_r_m = @conf['svn_repo_master'].gsub(/file:\/\//, '')
      # create repository for tests
      `"#{svnadmin.chomp}" create "#{@svn_r_m}"`
      # checkout a working copy of the repository just created for testing
      wc = @conf['svn_repo_working_copy']
      `cd "#{wc}" && "#{svn.chomp}" co "#{@conf['svn_repo_master']}"`
      @wc_repo2 = Dir.mktmpdir('E')
    rescue
      puts 'cannot create with the systems svn/svnadmin - all tests will Fail'
      exit 1
    end
  end

  def teardown
   # remove working copy of repo
   FileUtils.rm_rf @conf['svn_repo_working_copy']
   FileUtils.rm_rf @wc_repo2
   FileUtils.rm_rf @svn_r_m
   FileUtils.rm_rf @conf_file
  end

  def test_instantiate
    svn = SvnWc::RepoAccess.new
    assert_kind_of SvnWc::RepoAccess, svn
  end
  
  # username/pass 
  # remote repo url 
  # localpath
  def test_can_load_passed_conf
    conf = Hash.new
    conf['svn_user'] = 'testing'
    conf['svn_pass'] = 'testing'
    conf['svn_repo_master']       = 'file:///opt/something'
    conf['svn_repo_working_copy'] = '/opt/nada'
    svn = SvnWc::RepoAccess.new(YAML::dump(conf))

    assert_equal svn.svn_repo_master, 'file:///opt/something'
    assert_equal svn.svn_user,              'testing'
    assert_equal svn.svn_pass,              'testing'
    assert_equal svn.svn_repo_working_copy, '/opt/nada'
  end

  #def test_exception_on_failed_authenticate
  #  conf = Hash.new
  #  conf['svn_user'] = 'fred'
  #  assert_raise SvnWc::RepoAccessError do
  #    #Svn::Error::AuthnNoProvider
  #     svn = SvnWc::RepoAccess.new(YAML::dump(conf), true)
  #  end
  #end

  #def test_exception_on_no_remote_repo
  #  conf = Hash.new
  #  conf['svn_repo_master'] = 'svn+ssh://user:pass@example.com/no/repo'
  #                               #"svn+ssh://username@hostname/path/to/repository
  #  assert_raise SvnWc::RepoAccessError do
  #    #Svn::Error::AuthnNoProvider
  #    SvnWc::RepoAccess.new(YAML::dump(conf), true)
  #  end
  #end

  def test_exception_if_cant_checkout_repo_to_local
    conf = Hash.new
    conf['svn_repo_working_copy'] = '/opt/nada'
    assert_raise SvnWc::RepoAccessError do
      # permission denied
      SvnWc::RepoAccess.new(YAML::dump(conf), true)
    end
  end

  # wont overwrite/force overwrite
  def test_exception_if_localpath_already_exists
    FileUtils.rm_rf @conf['svn_repo_working_copy']

    if ! File.directory?(@conf['svn_repo_working_copy'])
      FileUtils.mkdir @conf['svn_repo_working_copy'] 
    end

    # the 'dot' dirs
    #assert_equal 2, Dir.entries(@conf['svn_repo_working_copy']).count # 1.8.7 >
    assert_equal 2, Dir.entries(@conf['svn_repo_working_copy']).size # 1.8.6 <

    assert_raise SvnWc::RepoAccessError do
      # already exists, wont overwrite dir
      SvnWc::RepoAccess.new(YAML::dump(@conf), true)
    end

    # the 'dot' dirs
    #assert_equal 2, Dir.entries(@conf['svn_repo_working_copy']).count # 1.8.7 >
    assert_equal 2, Dir.entries(@conf['svn_repo_working_copy']).size # 1.8.6 <

    SvnWc::RepoAccess.new(YAML::dump(@conf), true, true)

    # did a checkout, now more than 2 files
    #assert Dir.entries(@conf['svn_repo_working_copy']).count > 2 # 1.8.7 >
    assert Dir.entries(@conf['svn_repo_working_copy']).size > 2 # 1.8.6 <
  end

  ## NOTE too much 'system' setup work
  #def test_checkout_remote_repo_svn_ssh
  #  FileUtils.rm_rf @conf['svn_repo_working_copy']
  #  assert ! (File.directory?(@conf['svn_repo_working_copy']))
  #  conf = Hash.new
  #  conf['svn_repo_master'] = "svn+ssh://localhost/home/dwright/svnrepo"
  #  SvnWc::RepoAccess.new(YAML::dump(conf), true)
  #  assert_equal svn.svn_repo_working_copy, @conf['svn_repo_working_copy']

  #  # can only get status on checked out repo
  #  assert_equal @conf['svn_repo_master'], svn.info[:root_url]
  #  # now have a working copy
  #  assert File.directory? @conf['svn_repo_working_copy']
  #  FileUtils.rm_rf @conf['svn_repo_working_copy']
  #end

  ## TODO
  #def test_checkout_remote_repo_svn_auth_without_ssh
  #  FileUtils.rm_rf @conf['svn_repo_working_copy']
  #  assert ! (File.directory?(@conf['svn_repo_working_copy']))
  #  conf = Hash.new
  #  conf['svn_repo_master'] = "svn://localhost/home/dwright/svnrepo"
  #  SvnWc::RepoAccess.new(YAML::dump(conf), true)
  #  assert_equal svn.svn_repo_working_copy, @conf['svn_repo_working_copy']

  #  # can only get status on checked out repo
  #  assert_equal @conf['svn_repo_master'], svn.info[:root_url]
  #  # now have a working copy
  #  assert File.directory? @conf['svn_repo_working_copy']
  #  FileUtils.rm_rf @conf['svn_repo_working_copy']
  #end

  def test_can_load_conf_file_and_checkout_repo
    svn = SvnWc::RepoAccess.new
    assert svn.svn_repo_working_copy != @conf['svn_repo_working_copy']

    FileUtils.rm_rf @conf['svn_repo_working_copy']

    svn = SvnWc::RepoAccess.new @conf_file

    assert_equal svn.svn_repo_working_copy, @conf['svn_repo_working_copy']
    assert ! (File.directory?(@conf['svn_repo_working_copy']))

    # do checkout if not exists at local path
    svn = SvnWc::RepoAccess.new(@conf_file, true)
    assert_equal svn.svn_repo_working_copy, @conf['svn_repo_working_copy']

    # can only get status on checked out repo
    # TODO - no args does repo root
    #assert svn.status
    assert_equal @conf['svn_repo_master'], svn.info[:repos_root_url]

    # now have a working copy
    assert File.directory?(@conf['svn_repo_working_copy'])

  end

  #info[:last_changed_author]
  #info[:changelist]
  #info[:url]
  #info[:rev]
  #info[:URL]
  #info[:root_url]
  #info[:uuid]
  def test_can_get_svn_info
    svn = SvnWc::RepoAccess.new(YAML::dump(@conf), true, true)
    #puts svn.info[:url]
    #puts svn.info[:rev]
    #puts svn.info[:URL]
    info = svn.info
    assert_equal info[:repos_root_url], @conf['svn_repo_master']
  end

  def test_add_non_existant_file_fails
    svn = SvnWc::RepoAccess.new(YAML::dump(@conf), true, true)
    file = 'thisfiledoesnotexist.txt'
    begin
      svn.add file
      fail 'cant add a file which does not exist'
    rescue SvnWc::RepoAccessError => e
      assert e.message.match(/is not a working copy/)
      assert e.to_s.match(/Add Failed/)
    end
  end

  def test_commit_non_existant_file_fails
    svn = SvnWc::RepoAccess.new(YAML::dump(@conf), true, true)
    file = 'thisfiledoesnotexist.txt'
    begin
      svn.commit file
      fail 'cant commit file which does not exist'
    rescue SvnWc::RepoAccessError => e
      assert e.message.match(/is not a working copy/)
    end
  end

  def test_add_non_readable_file_fails
    svn = SvnWc::RepoAccess.new(YAML::dump(@conf), true, true)
    file = new_unique_file_at_path
    FileUtils.chmod 0000, file
    begin
      svn.add file
      fail 'lacking permissions to view file'
    rescue SvnWc::RepoAccessError => e
      assert e.message.match(/Permission denied/)
    ensure
      FileUtils.rm file
    end
  end

  def test_try_get_info_on_file_not_under_version_control
    svn = SvnWc::RepoAccess.new(YAML::dump(@conf), true, true)
    file = new_unique_file_at_path
    begin
      info = svn.info(file)
      orig_rev = info[:rev]
      fail 'cant get info on non checked in file'
    rescue SvnWc::RepoAccessError => e
      assert e.message.match(/is not under version control/)
    ensure
      FileUtils.rm file
    end
  end

  def test_add_new_dir_and_file_and_commit_and_delete
    svn = SvnWc::RepoAccess.new(YAML::dump(@conf), true, true)
    file = new_unique_file_at_path
    begin
      svn.info(file)
      fail 'file not in svn'
    rescue SvnWc::RepoAccessError => e
      assert e.message.match(/is not under version control/)
    end
    svn.add file
    rev = svn.commit file
    assert rev >= 1
    svn.delete file
    # commit our delete
    n_rev = svn.commit file
    assert_equal rev+1, n_rev
  end

  def test_add_new_file_with_utf8_symbol_and_commit_and_delete
    # fail on svn 1.6.6 (Centos 5.8) with utf8 issue
    # attributing to utf8 issues, which may be incorrect
    v = `svn --version`.match(/svn, version (\d+\.\d+\.\d+)\s/)[1] rescue '1.6.7'
    if '1.6.6' <= v
      puts "skipping utf8 test for svn version: #{v}"
      return
    end

    svn = SvnWc::RepoAccess.new(YAML::dump(@conf), true, true)
    file = new_unique_file_at_path2('£20')
    begin
      svn.info(file)
      fail 'file not in svn'
    rescue SvnWc::RepoAccessError => e
      #cant get info: bad URI(is not URI?): 
      assert e.message.match(/cant get info/)
    end

    assert_nothing_raised{svn.add file}
    assert_equal 'A', svn.status[0][:status]
    assert svn.status[0][:path].match(File.basename(file))
    rev = svn.commit file
    assert rev >= 1
    svn.delete file
    assert_equal 'D', svn.status[0][:status]
    assert svn.status[0][:path].match(File.basename(file))
    # commit our delete
    n_rev = svn.commit file
    assert_equal [], svn.status
    assert_equal rev+1, n_rev
  end

  def test_add_new_file_with_utf8_symbols_and_commit_and_delete
    # fail on svn 1.6.6 (Centos 5.8) with utf8 issue
    # attributing to utf8 issues, which may be incorrect
    v = `svn --version`.match(/svn, version (\d+\.\d+\.\d+)\s/)[1] rescue '1.6.7'
    if '1.6.6' <= v
      puts "skipping utf8 test for svn version: #{v}"
      return
    end

    svn = SvnWc::RepoAccess.new(YAML::dump(@conf), true, true)
    file = new_unique_file_at_path2('£20_ß£áçkqùë_Jâçqùë')
    begin
      svn.info(file)
      fail 'file not in svn'
    rescue SvnWc::RepoAccessError => e
      #cant get info: bad URI(is not URI?): 
      assert e.message.match(/cant get info/)
    end

    assert_nothing_raised{svn.add file}

    begin
      svn.add file
    rescue SvnWc::RepoAccessError => e
      assert e.message.match(/is already under version control/)
    end

    #assert_equal 'A', svn.status[0][:status]
    # why '?' and not 'A'!?
    assert_equal '?', svn.status[0][:status]
    #assert svn.status[0][:path].match(File.basename(file))
    #assert_equal File.basename(svn.status[0][:path]), File.basename(file)
    rev = svn.commit file
    assert rev >= 1
    svn.delete file
    assert_equal 'D', svn.status[0][:status]
    assert svn.status[0][:path].match(File.basename(file))
    # commit our delete
    n_rev = svn.commit file
    assert_equal [], svn.status
    assert_equal rev+1, n_rev
  end

  def test_add_new_dir_and_file_and_commit_and_delete_with_pre_open_instance
    @@svn_wc.set_conf @conf_file
    @@svn_wc.do_checkout true
    file = new_unique_file_at_path
    begin
      @@svn_wc.info(file)
      fail 'file not in svn'
    rescue SvnWc::RepoAccessError => e
      assert e.message.match(/is not under version control/)
    end
    @@svn_wc.add file
    rev = @@svn_wc.commit file
    assert rev >= 1
    @@svn_wc.delete file
    # commit our delete
    n_rev = @@svn_wc.commit file
    assert_equal rev+1, n_rev
  end

  def test_add_and_commit_several_select_new_dirs_and_files_then_svn_delete
    svn = SvnWc::RepoAccess.new(@conf_file, true, true)

    f = []
    (1..4).each { |d|
      wc_new_dir = File.join @conf['svn_repo_working_copy'], "dir#{d}"
      FileUtils.mkdir wc_new_dir
      wc_new_file = "test_#{d}.txt"
      f[d] = File.join wc_new_dir, wc_new_file
      FileUtils.touch f[d]
    }

    begin
      svn.info(f[1])
      fail 'is not under version control'
    rescue SvnWc::RepoAccessError => e
      assert e.message.match(/is not a working copy/)
    end
    svn.add [File.dirname(f[1]), File.dirname(f[2]), File.dirname(f[4])]
    rev = svn.commit [File.dirname(f[1]), File.dirname(f[2]), File.dirname(f[4]), f[1], f[2], f[4]]
    assert rev >= 1

    begin
      svn.info(f[3])
      fail 'is not under version control'
    rescue SvnWc::RepoAccessError => e
      assert e.message.match(/is not a working copy/)
    end
    assert_equal File.basename(f[4]), File.basename(svn.info(f[4])[:url])

    svn.delete([f[1], f[2], f[4], File.dirname(f[1]), File.dirname(f[2]), File.dirname(f[4])])
    n_rev = svn.commit [File.dirname(f[1]), File.dirname(f[2]), File.dirname(f[4]), f[1], f[2], f[4]]
    assert_equal rev+1, n_rev

    assert ! File.file?(f[4])
    assert File.file?(f[3])
    assert FileUtils.rm_rf(File.dirname(f[3]))
  end
  
  def test_operations_on_specific_dir_not_process_others
    svn = SvnWc::RepoAccess.new(@conf_file, true, true)

    f = []
    (1..4).each { |d|
      wc_new_dir = File.join @conf['svn_repo_working_copy'], "dir#{d}"
      FileUtils.mkdir wc_new_dir
      wc_new_file = "test_#{d}.txt"
      f[d] = File.join wc_new_dir, wc_new_file
      FileUtils.touch f[d]
    }

    begin
      svn.info(f[1])
      fail 'is not under version control'
    rescue SvnWc::RepoAccessError => e
      assert e.message.match(/is not a working copy/)
    end
    #svn.add [File.dirname(f[1]), File.dirname(f[2]), File.dirname(f[4])]
    #rev = svn.commit [File.dirname(f[1]), File.dirname(f[2]), File.dirname(f[4]), f[1], f[2], f[4]]
    #assert rev >= 1
    
    assert !svn.status(File.dirname(f[2])).to_s.match(/dir1/)
    assert svn.status(File.dirname(f[2])).to_s.match(/dir2/)
    assert !svn.status(File.dirname(f[2])).to_s.match(/dir3/)
    assert !svn.status(File.dirname(f[2])).to_s.match(/dir4/)

    assert !svn.status(File.dirname(f[3])).to_s.match(/dir1/)
    assert svn.status(File.dirname(f[3])).to_s.match(/dir3/)
    assert !svn.status(File.dirname(f[3])).to_s.match(/dir2/)
    assert !svn.status(File.dirname(f[3])).to_s.match(/dir4/)

    # not it repo yet
    assert_raise(SvnWc::RepoAccessError) { svn.list(File.dirname(f[3])) }
    svn.add [File.dirname(f[2]), File.dirname(f[3])]
    rev = svn.commit [File.dirname(f[2]), File.dirname(f[3]), f[2], f[3]]

    # list by dir matches specific only
    assert svn.list(File.dirname(f[3]))[1].to_s.match(/test_3.txt/)
    assert !svn.list(File.dirname(f[3]))[1].to_s.match(/test_2.txt/)

    # list matches all
    assert svn.list.to_s.match(/test_2.txt/)
    assert svn.list.to_s.match(/test_3.txt/)


  end
  
  def test_add_commit_update_file_status_revision_modify_diff_revert
    svn = SvnWc::RepoAccess.new(YAML::dump(@conf), true, true)
    f = new_unique_file_at_path
    #p svn.list_entries
    svn.add f
    start_rev = svn.commit f
    #p start_rev
    #svn.up f
    #p svn.info(f)
    #p svn.status(f)
    #add text to f
    File.open(f, 'a') {|fl| fl.write('adding this to file.')}
    #p svn.status(f)
    # M == modified
    assert_equal 'M', svn.status(f)[0][:status]
    assert_equal start_rev, svn.info(f)[:rev] 

    assert svn.diff(f).to_s.match('adding this to file.')

    svn.revert f
    assert_equal svn.commit(f), -1
    assert_equal [start_rev, []], svn.up(f)
    assert_equal start_rev, svn.info(f)[:rev] 
    assert_equal Array.new, svn.diff(f)
  end

  ## TODO not sure if we actually want this
  #def test_add_does_recursive_nested_dirs
  #  svn = SvnWc::RepoAccess.new(YAML::dump(@conf), true, true)
  #  repo_wc = @conf['svn_repo_working_copy']
  #  FileUtils.mkdir_p File.join(repo_wc, 'd1','d2','d3')
  #  nested = File.join(repo_wc, 'd1','d2','d3',"test_#{Time.now.usec.to_s}.txt")
  #  FileUtils.touch nested
  #  # TODO ability to add recursive nested dirs
  #  svn.add nested
 
  #  ## add 1 new file in nested heirerarcy
  #  ## TODO ability to add recursive nested dirs
  #  #FileUtils.mkdir_p @conf['svn_repo_working_copy'] + "/d1/d2/d3"
  #  #nested = @conf['svn_repo_working_copy'] +
  #  #                  "/d1/d2/d3/test_#{Time.now.usec.to_s}.txt"
  #  #FileUtils.touch nested
  #  #svn.add nested

  #  #svn.status.each { |ef|
  #  #  next unless ef[:entry_name].match /test_.*/
  #  #  assert_equal 'A', ef[:status]
  #  #  assert_equal nested, File.join(@conf['svn_repo_working_copy'], ef[:entry_name])
  #  #}
  #  #svn.revert
  #  #assert_equal 1, svn.status.length
  #  #assert_equal File.basename(@conf['svn_repo_working_copy']),
  #  #                   svn.status[0][:entry_name]
  #end

  def test_update_acts_on_whole_repo_by_default_knows_a_m_d
    #conf = Hash.new
    #conf['svn_repo_master']       = 'file:///tmp/svnrepo'
    #conf['svn_repo_working_copy'] = '/tmp/testing'
    #svn = SvnWc::RepoAccess.new(YAML::dump(conf))
    #p svn.list_entries
    #exit
    svn = SvnWc::RepoAccess.new(YAML::dump(@conf), true, true)

    rev = svn.info()[:rev]
    assert_equal [rev, []], svn.update

    (rev1, files)  = check_out_new_working_copy_add_and_commit_new_entries(3)
    assert_equal rev+1, rev1

    fe = Array.new
    files.each { |e| fe.push File.basename(e)}
    assert_equal \
      [(rev + 1), ["A\t#{fe[0]}", "A\t#{fe[1]}", "A\t#{fe[2]}"]],
      svn.update, 'added 3 files into another working copy of the repo, update
                   on current repo finds them, good!'

    # Confirm can do add/delete/modified simultaneously
    # modify, 1 committed file, current repo
    lf = File.join @conf['svn_repo_working_copy'], fe[0]
    File.open(lf, 'a') {|fl| fl.write('local repo file is modified')}
    # delete, 2 committed file, in another repo
    rev2 \
       = delete_and_commit_files_from_another_working_copy_of_repo(
                                                       [files[1], files[2]]
                                                                  )
    # add 1 file, in another repo
    (rev3, file)  = check_out_new_working_copy_add_and_commit_new_entries
    fe.push File.basename(file[0])

    assert_equal \
      [(rev + 3), ["M\t#{fe[0]}", "A\t#{fe[3]}", "D\t#{fe[1]}", "D\t#{fe[2]}"]],
      svn.update, '1 modified locally, 2 deleted in other repo, 1 added other
      repo, update locally, should find all these changes'

  end

  def test_update_can_act_on_specific_dir
    svn = SvnWc::RepoAccess.new(YAML::dump(@conf), true, true)

    rev = svn.info()[:rev]
    assert_equal [rev, []], svn.update

    # add 3 files to a nested subdir under repo root
    dir = 't/t/t'
   (rev1, file) = check_out_new_working_copy_add_commit_new_entry_into_subdir(dir)
    assert_equal rev+1, rev1

    # add 3 files to a different nested subdir under repo root
    dir2 = 'f/f/f'
   (rev2, file2) = check_out_new_working_copy_add_commit_new_entry_into_subdir(dir2)
    assert_equal rev+2, rev2

    # find first nested subdir file
    assert_equal \
    [(rev + 2), ["A\t#{dir}/#{File.basename file}", "A\tt/t/t", "A\tt/t"]],
      #svn.update(File.join(@conf['svn_repo_working_copy'], dir)), # fails
      svn.update(File.join(@conf['svn_repo_working_copy'], 't')),
      'found file under first subdir path of the repo, but not the second subdir, good!'

    # find second nested subdir file
    assert_equal \
    [(rev + 2), ["A\t#{dir2}/#{File.basename file2}", "A\tf/f/f", "A\tf/f"]], #svn.update(File.join(@conf['svn_repo_working_copy'], dir2)),
      svn.update(File.join(@conf['svn_repo_working_copy'], 'f')),
      'update can accept a path to update and only act on that path, great!'

    (rev3, nf) = check_out_new_working_copy_add_commit_new_entry(dir)

    # second nested subdir file - should not see added file
    assert_equal \
    [rev3, []], svn.update(File.join(@conf['svn_repo_working_copy'], 'f')),
      'update can act on passed path (or not act :)'

    # first nested subdir file - should find new file
    assert_equal [rev3, ["A\t#{dir}/#{File.basename nf}"]],
      svn.update(File.join(@conf['svn_repo_working_copy'], dir)),
      'svn update can update based specified on non-top level path, great!'

  end

  def test_add_exception_on_already_added_file
    svn = SvnWc::RepoAccess.new(YAML::dump(@conf), true, true)
    this_wc_rev = 0
    assert_equal [this_wc_rev, []], svn.update

    rev, f_name = check_out_new_working_copy_add_and_commit_new_entries

    assert_equal [rev, ["A\t#{File.basename(f_name.to_s)}"]], svn.update

    (rev, f) = modify_file_and_commit_into_another_working_repo
    File.open(f, 'w') {|fl| fl.write('adding text to file.')}
    #already under version control
    assert_raise(SvnWc::RepoAccessError) { svn.add f }
  end

  def test_list_recursive
    FileUtils.rm_rf @conf['svn_repo_working_copy']

    if ! File.directory?(@conf['svn_repo_working_copy'])
      FileUtils.mkdir @conf['svn_repo_working_copy'] 
    end

    svn = SvnWc::RepoAccess.new(YAML::dump(@conf), true, true)

    # how many files does svn status find?
    r_list = []
    svn.list.each { |ef|
      r_list.push File.join(@conf['svn_repo_working_copy'], ef[:entry])
    }

    # not cross platform
    dt = Dir["#{@conf['svn_repo_working_copy']}/**/*"]
    d_list = []
    dt.each do |item|
      #case File.stat(item).ftype
      d_list.push item
    end

    the_diff = r_list - d_list
    # not cross platform
    assert_equal the_diff, [File.join(@conf['svn_repo_working_copy'], '/')]
    #puts the_diff
    #p d_list.length
    #p r_list.length
    assert_equal d_list.length, r_list.length-1

  end

  def test_status_n_revert_default_to_repo_root
    FileUtils.rm_rf @conf['svn_repo_working_copy']

    if ! File.directory?(@conf['svn_repo_working_copy'])
      FileUtils.mkdir @conf['svn_repo_working_copy']
    end

    svn = SvnWc::RepoAccess.new(YAML::dump(@conf), true, true)

    #puts svn.status
    repo_wc = @conf['svn_repo_working_copy']

    # add 4 new files in the repo root
    num_create = 4
    add_files = []
    (1..num_create).each { |d|
      fl = new_unique_file_at_path
      svn.add fl
      add_files.push fl
    }
    # add 1 new file in nested heirerarcy
    FileUtils.mkdir_p File.join(repo_wc, 'd1','d2','d3')
    nested = File.join(repo_wc, 'd1','d2','d3',"test_#{Time.now.usec.to_s}.txt")
    FileUtils.touch nested
    # TODO ability to add recursive nested dirs
    #svn.add nested
    svn.add File.join(repo_wc, 'd1') # adding 'root' adds all

    add_files.push File.join(repo_wc, 'd1'), File.join(repo_wc, 'd1', 'd2'),
                    File.join(repo_wc, 'd1', 'd2', 'd3'), nested

    was_added = []
    # XXX status should only return modified/added or unknown files
    svn.status.each { |ef|
      assert_equal 'A', ef[:status]
      was_added.push ef[:path]
    }
    assert_equal add_files.sort, was_added.sort

    svn.revert
    svn.status.each { |ef|
      # files we just reverted are not known to svn now, good
      assert_equal '?', ef[:status]
    }

    svn.status.each { |ef|
      add_files.each { |nt|
        begin
          svn.info nt
          flunk 'svn should not know this file'
        rescue
          assert true
        end
      }
    }

    #clean up
    add_files.each {|e1| FileUtils.rm_rf e1 }

  end

  def test_commit_file_not_yet_added_to_svn_raises_exception
    svn = SvnWc::RepoAccess.new(YAML::dump(@conf), true, true)
    file = new_unique_file_at_path
    fails = false
    begin
      svn.commit file
    rescue SvnWc::RepoAccessError => e
      assert e.to_s.match(/is not under version control/)
      fails = true
    ensure
      FileUtils.rm file
    end
    assert fails
  end

  def test_list_entries_verbose
    svn = SvnWc::RepoAccess.new(YAML::dump(@conf), true, true)

    repo_wc = @conf['svn_repo_working_copy']

    dir_ent = Dir.mktmpdir('P', repo_wc)
    file = 'file.txt'
    file = File.join dir_ent, file
    File.open(file, "w") {|f| f.print('contents.')}
    file2 = new_unique_file_at_path dir_ent

    svn.add dir_ent, recurse=true, force=true
    rev = svn.commit repo_wc

    entries =  svn.list_entries.sort_by{|h| h[:entry_name]}

    assert_equal File.basename(entries[0][:entry_name]), 
                 File.basename(file)
    assert_equal File.basename(entries[1][:entry_name]), 
                 File.basename(file2)
    assert_equal entries.size, 2
    assert_nil entries[2]
    # verbose info from list_entries
    #p svn.list_entries(repo_wc, file, verbose=true)
    f_entry = File.join(File.basename(dir_ent), File.basename(file))
    svn.list_entries(repo_wc, file, verbose=true).each do |info|
      # bools
      assert ! info[:absent]
      assert ! info[:entry_conflict]
      assert ! info[:add?]
      assert ! info[:dir?]
      assert ! info[:has_props]
      assert ! info[:deleted]
      #assert ! info[:keep_local]
      assert ! info[:has_prop_mods]
      assert   info[:normal?]
      assert   info[:file?]

      assert_nil info[:copyfrom_url]
      assert_nil info[:conflict_old]
      assert_nil info[:conflict_new]
      assert_nil info[:conflict_wrk]
      assert_nil info[:lock_comment]
      assert_nil info[:lock_owner]
      assert_nil info[:present_props]
      assert_nil info[:lock_token]
      #assert_nil info[:changelist]
      assert_nil info[:prejfile]

      #assert_equal info[:cmt_author], `id`
      assert_equal info[:revision], rev
      assert_equal info[:repo_rev], rev
      assert_equal info[:cmt_rev] , rev
      #assert_equal info[:cmt_date] , rev
      #:checksum=>"bb9c00f6fc03c2213ac1f0278853dc32", :working_size=>9,
      #assert_equal info[:working_size] , 9
      assert_equal info[:schedule], 0
      assert_equal info[:lock_creation_date], 0
      assert_equal info[:copyfrom_rev], -1
      assert_equal info[:prop_time], 0
      assert_equal info[:kind], 1  # i.e. is file
      #assert_equal info[:depth], 3
      assert_equal info[:status]   , ' '
      assert_equal info[:entry_name], f_entry
      assert_equal info[:url], "#{File.join(@conf['svn_repo_master'],f_entry)}"
      assert_equal info[:repos], @conf['svn_repo_master']
    end

    # list and list_entries report the same entry path
    list_entries = []
    entries.each do |info|
      list_entries.push info[:entry_name]
    end

    entries = []
    svn.list.each do |info|
      next unless info[:entry].match(/\.txt$/)
      entries.push info[:entry]
    end

    assert_equal entries, list_entries

  end

  def test_propset_ignore_file
    svn = SvnWc::RepoAccess.new(YAML::dump(@conf), true, true)

    repo_wc = @conf['svn_repo_working_copy']

    dir_ent = Dir.mktmpdir('P', repo_wc)
    file = 'file_to_ignore.txt'
 
    svn.add dir_ent, recurse=false
    svn.propset('ignore', file, dir_ent)
    svn.commit repo_wc

    file = File.join dir_ent, file
    # create file we have already ignored, above
    File.open(file, "w") {|f| f.print('testing propset ignore file.')}

    file2 = new_unique_file_at_path dir_ent

    svn.add dir_ent, recurse=true, force=true
    svn.commit repo_wc

    assert_raise(SvnWc::RepoAccessError) { svn.info file }
    assert_equal File.basename(svn.list_entries[0][:entry_name]), 
                 File.basename(file2)
    assert_equal svn.list_entries.size, 1
    assert_nil svn.list_entries[1]

  end

 # XXX wtf!? why is svn_list ignoring the file, its not set to ignore
 # TODO investiate
  def test_propset_ignore_file_unrevisioned
    svn = SvnWc::RepoAccess.new(YAML::dump(@conf), true, true)

    repo_wc = @conf['svn_repo_working_copy']

    file = File.join repo_wc, 'another_file_to_ignore.txt'
 
    #svn.propset('ignore', file)
    #svn.prop_set(Svn::Core::PROP_IGNORE, file, repo_wc)

    #file = File.join repo_wc, file
    # create file we have already ignored, above
    File.open(file, "w") {|f| f.print('testing propset ignore file.')}
    

    #dir_ent = Dir.mktmpdir('P', repo_wc)
    #file2 = new_unique_file_at_path dir_ent
    file2 = new_unique_file_at_path
    #p svn.list_entries
    #p `ls -l "#{repo_wc}"`

    #svn.add dir_ent, recurse=true, force=true
    #svn.add dir_ent, recurse=true, force=true
    svn.add file2
    #p svn.list_entries
    #svn.commit repo_wc
    svn.commit

    assert_raise(SvnWc::RepoAccessError) { svn.info file }
    assert_equal File.basename(svn.list_entries[0][:entry_name]), 
                 File.basename(file2)
    assert_equal svn.list_entries.size, 1
    assert_nil svn.list_entries[1]
    #p svn.list_entries

  end

  # TODO
  # from client.rb
  #def log(paths, start_rev, end_rev, limit,
  #        discover_changed_paths, strict_node_history,
  #        peg_rev=nil)
  def test_commit_with_message
    log_mess = 'added new file'

    svn = SvnWc::RepoAccess.new(YAML::dump(@conf), true, true)
    file = new_unique_file_at_path
    svn.add file
    o_rev = svn.commit file, log_mess
    assert o_rev >= 1
    args = [file, 0, "HEAD", 0, true, nil]
    svn.log(*args) do |changed_paths, rev, author, date, message|
      assert_equal rev, o_rev
      assert_equal message, log_mess
    end
  end


  #
  # methods used by the tests below here
  #
 
  def new_unique_file_at_path(wc_repo=@conf['svn_repo_working_copy'])
    #Tempfile.new('test_', wc_repo).path
    FileUtils.mkdir_p wc_repo unless File.directory? wc_repo
    new_file_name = File.join(wc_repo, "test_#{Time.now.usec.to_s}.txt")
    FileUtils.touch new_file_name
    new_file_name
  end
 
  def new_unique_file_at_path2(f_name=nil, wc_repo=nil)
    wc_repo =@conf['svn_repo_working_copy'] if wc_repo.nil?
    #Tempfile.new('test_', wc_repo).path
    new_file_name = File.join(wc_repo, "test_#{f_name}_#{Time.now.usec.to_s}.txt")
    FileUtils.touch new_file_name
    new_file_name
  end

  def _working_copy_repo_at_path(wc_repo=@wc_repo2)
    conf = @conf
    wc = conf['svn_repo_working_copy']
    conf['svn_repo_working_copy'] = wc_repo
    svn = SvnWc::RepoAccess.new(YAML::dump(conf), true, true)
    conf['svn_repo_working_copy'] = wc # reset to orig val
    svn
  end

  def delete_and_commit_files_from_another_working_copy_of_repo(files)
    svn = _working_copy_repo_at_path
    svn.delete files
    rev = svn.commit
    raise 'cant get rev' unless rev
    return rev
  end

  def check_out_new_working_copy_add_and_commit_new_entries(num_files=1)
    svn = _working_copy_repo_at_path
    ff = Array.new
    (1..num_files).each {|n|
        f = new_unique_file_at_path(svn.svn_repo_working_copy)
      svn.add f
      ff.push f
    }
    rev = svn.commit ff
    #puts svn.status(f)[0][:status]
    #puts svn.info(f)[:rev]
    #raise 'cant get status' unless 'A' == svn.status(f)[0][:status]
    #raise 'cant get revision' unless rev == svn.info(f)[:rev]@
    raise 'cant get rev' unless rev
    return rev, ff
  end

  def check_out_new_working_copy_add_commit_new_entry_into_subdir(dir)
    svn = _working_copy_repo_at_path

    ff = Array.new
    f = new_unique_file_at_path(File.join(svn.svn_repo_working_copy, dir))
    #p svn

    #svn.add f
    #rev = svn.commit f
    #puts File.exists? f
    dirs = dir.split('/')
    d_to_add = []
    dp = ''
    dirs.each do |d|
      dp << "/#{d}"
      d =  File.join(svn.svn_repo_working_copy, dp)
      #puts "adding #{d}"
      d_to_add.push d
      # just  have to add the top level subdir path
      # then all under it is found
      break
    end
    #d_to_add.push f

    #puts d_to_add.inspect

    svn.add d_to_add
    rev = svn.commit d_to_add
    raise 'cant get rev' unless rev
    return rev, f
  end

  def check_out_new_working_copy_add_commit_new_entry(dir)
    svn = _working_copy_repo_at_path

    f = new_unique_file_at_path(File.join(svn.svn_repo_working_copy, dir))
    #p svn

    svn.add f
    rev = svn.commit f
    raise 'file not created' unless File.exists?(f)
    raise 'cant get rev' unless rev
    return rev, f
  end


  def modify_file_and_commit_into_another_working_repo
    svn = _working_copy_repo_at_path
    f = new_unique_file_at_path(svn.svn_repo_working_copy)
    File.open(f, 'w') {|fl| fl.write('this is the original content of file.')}
    svn.add f
    rev = svn.commit f
    raise 'cant get revision' unless rev == svn.info(f)[:rev]
    return rev, f
  end


end

if VERSION < '1.8.7'
  # File lib/tmpdir.rb, line 99
  def Dir.mktmpdir(prefix_suffix=nil, tmpdir=nil)
    case prefix_suffix
    when nil
      prefix = "d"
      suffix = ""
    when String
      prefix = prefix_suffix
      suffix = ""
    when Array
      prefix = prefix_suffix[0]
      suffix = prefix_suffix[1]
    else
      raise ArgumentError, "unexpected prefix_suffix: #{prefix_suffix.inspect}"
    end
    tmpdir ||= Dir.tmpdir
    t = Time.now.strftime("%Y%m%d")
    n = nil
    begin
      path = "#{tmpdir}/#{prefix}#{t}-#{$$}-#{rand(0x100000000).to_s(36)}"
      path << "-#{n}" if n
      path << suffix
      Dir.mkdir(path, 0700)
    rescue Errno::EEXIST
      n ||= 0
      n += 1
      retry
    end

    if block_given?
      begin
        yield path
      ensure
        FileUtils.remove_entry_secure path
      end
    else
      path
    end
  end
end

