Vagrant.configure("2") do |config|
  config.vm.box = "generic/rocky9"
  # config.vm.box = "generic/ubuntu2404"
  # config.vm.box = "generic/debian13"
  # config.vm.box = "generic/rhel9"

  (1..4).each do |i|
    config.vm.define "node#{i}" do |node|
      node.vm.provider "vmware_desktop" do |vb|
        vb.memory = "4096"
        vb.cpus=4
      end
      
      # hyper-v
      # node.vm.provider "hyperv" do |hv|
      #   hv.cpus = 4
      #   hv.memory = 4096
      #   hv.maxmemory = 4096
      #   hv.enable_checkpoints = false
      # end

      node.vm.provision "shell", inline: <<-SHELL
        sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
        sed -i 's/^#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
        echo "root:vagrant" | chpasswd
        systemctl restart sshd
      SHELL
    end
  end
end