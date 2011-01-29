require 'lockfile'
require 'inifile'
require 'net/ssh'
require 'tmpdir'

module Gitolite
	def self.get_urls(project)
		urls = {:read_only => [], :developer => []}
		read_only_baseurls = Setting.plugin_redmine_gitolite['readOnlyBaseUrls'].split(/[\r\n\t ,;]+/)
		developer_baseurls = Setting.plugin_redmine_gitolite['developerBaseUrls'].split(/[\r\n\t ,;]+/)

		project_path = ''
		project_path += project.parent.identifier + "/" if project.parent
		project_path += project.identifier + ".git"

		read_only_baseurls.each {|baseurl| urls[:read_only] << baseurl + project_path}
		developer_baseurls.each {|baseurl| urls[:developer] << baseurl + project_path}
		return urls
	end

	def self.update_repositories(projects)
		projects = (projects.is_a?(Array) ? projects : [projects])
	
		if(defined?(@recursionCheck))
			if(@recursionCheck)
				return
			end
		end
		@recursionCheck = true

		# Don't bother doing anything if none of the projects we've been handed have a Git repository
		unless projects.detect{|p|  p.repository.is_a?(Repository::Git) }.nil?

			lockfile=File.new(File.join(RAILS_ROOT,"tmp",'redmine_gitolite_lock'),File::CREAT|File::RDONLY)
			retries=5
			loop do
				break if lockfile.flock(File::LOCK_EX|File::LOCK_NB)
				retries-=1
				sleep 2
				raise Lockfile::MaxTriesLockError if retries<=0
			end


			# HANDLE GIT

			# create tmp dir
			local_dir = File.join(RAILS_ROOT,"tmp","redmine_gitolite_#{Time.now.to_i}")

			Dir.mkdir local_dir

			# clone repo
			`git clone #{Setting.plugin_redmine_gitolite['gitoliteUrl']} #{local_dir}/gitolite`

			changed = false
			projects.select{|p| p.repository.is_a?(Repository::Git)}.each do |project|
				# fetch users
				users = project.member_principals.map(&:user).compact.uniq
				write_users = users.select{ |user| user.allowed_to?( :commit_access, project ) }
				read_users = users.select{ |user| user.allowed_to?( :view_changesets, project ) && !user.allowed_to?( :commit_access, project ) }
				# write key files
				users.map{|u| u.gitolite_public_keys.active}.flatten.compact.uniq.each do |key|
					File.open(File.join(local_dir, 'gitolite/keydir',"#{key.identifier}.pub"), 'w') {|f| f.write(key.key.gsub(/\n/,'')) }
				end

				# delete inactives
				users.map{|u| u.gitolite_public_keys.inactive}.flatten.compact.uniq.each do |key|
					File.unlink(File.join(local_dir, 'gitolite/keydir',"#{key.identifier}.pub")) rescue nil
				end

				# write config file
				conf = IniFile.new(File.join(local_dir,'gitolite','gitolite.conf'))
				original = conf.clone
				name = "#{project.identifier}"

				conf["group #{name}_readonly"]['readonly'] = name
				conf["group #{name}_readonly"]['members'] = read_users.map{|u| u.gitolite_public_keys.active}.flatten.map{ |key| "#{key.identifier}" }.join(' ')

				conf["group #{name}"]['writable'] = name
				conf["group #{name}"]['members'] = write_users.map{|u| u.gitolite_public_keys.active}.flatten.map{ |key| "#{key.identifier}" }.join(' ')

				# git-daemon support for read-only anonymous access
				if User.anonymous.allowed_to?( :view_changesets, project )
					conf["repo #{name}"]['daemon'] = 'yes'
				else
					conf["repo #{name}"]['daemon'] = 'no'
				end
				# Enable/disable gitweb
				if User.anonymous.allowed_to?( :view_gitweb, project )
					conf["repo #{name}"]['gitweb'] = 'yes'
				else
					conf["repo #{name}"]['gitweb'] = 'no'
				end

				unless conf.eql?(original)
					conf.write 
					changed = true
				end

			end
			if changed
				git_push_file = File.join(local_dir, 'git_push.bat')

	      new_dir= File.join(local_dir,'gitolite')
				File.open(git_push_file, "w") do |f|
				  f.puts "#!/bin/sh"
					f.puts "cd #{new_dir}"
					f.puts "git add keydir/* gitolite.conf"
					f.puts "git config user.email '#{Setting.mail_from}'"
					f.puts "git config user.name 'Redmine'"
					f.puts "git commit -a -m 'updated by Redmine Gitolite'"
					f.puts "git push"
				end
				File.chmod(0755, git_push_file)

				# add, commit, push, and remove local tmp dir
				`#{git_push_file}`
			end
			# remove local copy
			`rm -Rf #{local_dir}`

			lockfile.flock(File::LOCK_UN)
		end
		@recursionCheck = false

	end
	
end
