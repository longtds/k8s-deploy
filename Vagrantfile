Vagrant.configure("2") do |config|
  # config.vm.box = "generic/rocky8"
  config.vm.box = "generic/rocky9"
  # config.vm.box = "generic/ubuntu2204"
  # config.vm.box = "generic/ubuntu2404"
  # config.vm.box = "generic/debian11"
  # config.vm.box = "generic/debian12"
  # config.vm.box = "generic/centos8"
  # config.vm.box = "generic/rhel8"
  # config.vm.box = "generic/rhel9"

  (1..5).each do |i|
    config.vm.define "node#{i}" do |node|
      node.vm.synced_folder "./.ssh", "/vagrant"
      node.vm.provider "libvirt" do |vb|
        vb.memory = "4096"
        vb.cpus=2
      end
      node.vm.provision "shell", inline: <<-SHELL
        mkdir -p {/root/.ssh,/data}
        cp -r /vagrant/* /root/.ssh/ && chmod 600 -R /root/.ssh
        sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/g' /etc/ssh/sshd_config
        systemctl restart sshd
      SHELL
    end
  end
end