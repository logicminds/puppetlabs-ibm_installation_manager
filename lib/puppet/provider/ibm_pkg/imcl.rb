# Provider for installing and querying packages with IBM Installation
# Manager.  This could almost be a provider for the package resource, but I'm
# not sure how.  We need to be able to support multiple installations of the
# exact same package of the exact same version but in different locations.
#
# This could also use some work.  I'm obviously lacking in Ruby experience and
# familiarity with the Puppet development APIs.
#
# Right now, this is pretty basic - we can check the existence of a package
# and install/uninstall it.  We don't support updating here.  Updating is
# less than trivial.  Updates are done by the user downloading the massive
# IBM package and extracting it in the right way.  For things like WebSphere,
# several services need to be stopped prior to updating.
#
# Version numbers are also weird.  We're using Puppet's 'versioncmp' here,
# which appears to work for IBM's scheme.  Basically, if the specified version
# or a higher version is installed, we consider the resource to be satisfied.
# Specifically, if the specified path has the specified version or greater
# installed, we're satisfied.
#
# IBM Installation Manager keeps an XML file at
# /var/ibm/InstallationManager/installed.xml that includes all the installed
# packages, their locations, "fixpacks", and other useful information. This
# appears to be *much* more useful than the 'imcl' tool, which doesn't return
# terribly useful information (and it's slower).
#
# We attempt to make an educated guess for the location of 'imcl' by parsing
# that XML file.  Otherwise, the user can explicitly provide that via the
# 'imcl_path' parameter.
#
# A user can provide a 'response file' for installation, which will include
# pretty much *all* the information for installing - paths, versions,
# repositories, etc.  Otherwise, they can provide values for the other
# parameters.  Finally, they can provide their own arbitrary options.
#
require 'rexml/document'
include REXML

Puppet::Type.type(:ibm_pkg).provide(:imcl) do

  commands :kill => 'kill'
  commands :chown => 'chown'
  confine  :exists => '/var/ibm/InstallationManager/installed.xml'
  binding.pry

  commands :imcl  => imcl_command_path

  # returns the path to the command
  # this is required because it is unlikely that the system would have this in the path
  def self.imcl_command_path
    if resource[:imcl_path]
      resource[:imcl_path]
    else
      doc = REXML::Document.new(self.registry)
      path = XPath.first(doc, '//installInfo/location[@id="IBM Installation Manager"]/@path')
      File.join(path, 'tools','imcl')
      registry.close
    end
  end


  # returns a file handle by opening the registry file
  # easier to mock when extracted to method like this
  def self.registry
    File.open('/var/ibm/InstallationManager/installed.xml')
  end


  def initialize(value={})
    super(value)
    # if no response file, check for respository file
    # unless resource[:response]
    #   unless File.exists?(resource[:repository])
    #     raise Puppet::Error, "Ibm_pkg[#{resource[:package]}]: #{resource[:repository]} not found."
    #   end
    # end
  end

  ## The bulk of this is from puppet/lib/puppet/provider/service/base
  ## IBM requires that all services be stopped prior to installing software
  ## to the target. They won't do it for you, and there's not really a clear
  ## way to say "stop everything that matters".  So for now, we're just
  ## going to search the process table for anything that matches our target
  ## directory and kill it.  We've got to come up with something better for
  ## this.
  def stopprocs
    ps = Facter.value :ps
    regex = Regexp.new(resource[:target])
    self.debug "Executing '#{ps}' to find processes that match #{resource[:target]}"
    pid = []
    IO.popen(ps) { |table|
      table.each_line { |line|
        if regex.match(line)
          self.debug "Process matched: #{line}"
          ary = line.sub(/^\s+/, '').split(/\s+/)
          pid << ary[1]
        end
      }
    }

    ## If a PID matches, attempt to kill it.
    unless pid.empty?
      pids = ''
      pid.each do |thepid|
        pids += "#{thepid} "
      end
      begin
        self.debug "Attempting to kill PID #{pids}"
        command = "/bin/kill #{pids}"
        output = kill(pids, :combine => true, :failonfail => false)
      rescue Puppet::ExecutionFailure
        err = <<-EOF
        Could not kill #{self.name}, PID #{thepid}.
        In order to install/upgrade to specified target: #{resource[:target]},
        all related processes need to be stopped.
        Output of 'kill #{thepid}': #{output}
        EOF

        @resource.fail Puppet::Error, err, $!
      end
    end
  end

  def create
    if resource[:response]
      cmd_options = "input #{resource[:response]}"
    else
      cmd_options = ["install #{resource[:package]}_#{resource[:version]}",
                     "-repositories #{resource[:repository]}", "-installationDirectory #{resource[:target]}",
                     '-acceptLicense']
    end
    cmd_options += resource[:options] if resource[:options]
    result = Puppet::Util::Execution.execute(command, :uid => resource[:user], :combine => true)

    stopprocs  # stop related processes before we install
    imcl(cmd_options)
    # change owner
    if resource.manage_ownership?
      FileUtils.chown_R(resource[:package_owner], resource[:package_group], resource[:target])
    end
  end

  def exists?
    @property_hash[:ensure] == :present
  end

  def destroy
    remove = 'uninstall ' + resource[:package] + '_' + resource[:version]
    remove += ' -s -installationDirectory ' + resource[:target]
    imcl(remove)
  end

  def self.prefetch(resources)
    packages = instances
    if packages
      resources.keys.each do | name|
        if provider = packages.find{|package| packages.name == name }
          resources[name].provider = provider
        end
      end
    end
  end

  def self.installed_packages
    ## Determine if the specified package has been installed to the specified
    ## location by parsing IBM IM's "installed.xml" file.
    ## I *think* this is a pretty safe bet.  This seems to be a pretty hard-
    ## coded path for it on Linux and AIX.
    doc = REXML::Document.new(registry)
    packages = []
    doc.elements.each("/installInfo/location") do |item|
      product_name = item.attributes["id"]   # IBM Installation Manager
      path         = item.attributes["path"]  # /opt/Apps/WebSphere/was8.5/product/eclipse
      XPath.each(item, "package") do |package|
        id           = package.attributes['id']  # com.ibm.cic.agent
        version      = package.attributes['version'] # 1.6.2000.20130301_2248
        repository   = package.first.elements.find {|i| i.attributes['name'] == 'agent.sourceRepositoryLocation'}.attributes['value']
        packages << {
          :name => "#{id}_#{version}_#{path}",
          :product_name => product_name,
          :path         => path,
          :package_id   => id,
          :version      => version,
          :repository   => "#{repository}/repository.config"
        }
      end
    end
  end

  def self.instances
    # get a list of installed packages
    installed_packages.map do |package|
      new(
        :ensure => :present,
        :package => package[:package_id],
        :name => package[:name],
        :version => package[:version],
        :target  => package[:path],
        :repository => package[:repository],
      )
    end
  end

end