# -*- mode: ruby -*-
# vi: set ft=ruby :

# This is a Vagrantfile, a script for getting up Vagrant virtual environment.
# See https://www.vagrantup.com/ for details.
# This script requires Vagrant 1.9.1+ and Ansible 2.2+
# Visit https://www.ansible.com for getting Ansible.

VAGRANTFILE_API_VERSION = "2"

if system("ansible --version >> /dev/null") != true; then
	warn "Please install Ansible v2.2+ in order to provision this image!"
   exit 1
end

ansible_version = Gem::Version.new(`ansible --version | head -n 1 | cut -d' ' -f2- | tr -d '\n'`)

# Second ansible version is preferred.
if ansible_version < Gem::Version.new('2.2'); then
	warn "Please use ansible version v2.2+ in order to provision this vagrant image! Current version is " + ansible_version.to_s
    exit 1
end

Vagrant.configure("2") do |config|

  config.vm.box = "bytepark/scientific-6.5-64"

  # TTY problem fix
  config.vm.provision "fix-no-tty", type: "shell" do |s|
      s.privileged = false
      s.inline = "if [[ $(sudo grep -Fxq requiretty /etc/sudoers) -eq 0 ]] ; then sudo sed -i '/requiretty/d' /etc/sudoers; else echo 'TTY already fixed. Have fun' ; fi"
  end

  config.vm.provider "virtualbox" do |vbox|
		vbox.customize ["modifyvm", :id, "--memory", "2048"]
		vbox.customize ["modifyvm", :id, "--natdnshostresolver1", "on"]
		vbox.customize ["modifyvm", :id, "--name", "CRADLE::OF::TEARS"]
  end

  config.vm.network "private_network", ip: "192.168.93.93"

  # mysql
  config.vm.network "forwarded_port", guest: 3306, host: 3306
  # apache
  config.vm.network "forwarded_port", guest: 80, host: 8080

  config.vm.hostname = "CRADLEOFTEARS"

  config.vm.synced_folder ".", "/opt/LJR/"

  config.vm.provision "shell", path: "provisioning/fix_locale.sh", run: "always"
  config.vm.provision "shell", path: "provisioning/fix_selinux.sh", run: "always"
  config.vm.provision "ansible" do |ansible|
    ansible.playbook = "provisioning/playbook.yml"
		# ansible.verbose = "vvv"
  end

  config.vm.provision "shell", path: "provisioning/run_services.sh", run: "always"
end
