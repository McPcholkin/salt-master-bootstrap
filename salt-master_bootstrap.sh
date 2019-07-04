#!/bin/bash

debian_mirror="http://debian.volia.net/debian/" 
debian_release=stable
debian_arch=i386
server_ip=192.168.1.10
server_id="MySaltMaster.lan"
server_name="MySaltMaster"
user_name="MyUserName" 
user_password="1234567890" 
user_pub_key="ssh-rsa Aa8WkDljpae7BLuO2Pw7eUXhraQ4= rsa-key-20170517"


echo ""
echo "=== Start bootstrap salt master ===" 
echo "" 

# list disk info
echo "Disks:"
sudo fdisk -l | grep "Disk /" | cut -d ' ' -f 2-4 | cut -f 1 -d ','
echo ""

disk_list=($(sudo fdisk -l | grep "Disk /" | cut -d ' ' -f 2 | cut -d ':' -f1))

counter=0 
for disk_line in ${disk_list[*]}
  do
    echo "$counter - $disk_line"
    counter=$((counter+1))
  done

echo ""

read -n1 -r -p "Select target drive: " key_press 
echo ""
if [[ $key_press = *[[:digit:]]* ]]
  then
    work_disk=${disk_list[$key_press]}
    echo "" 
    echo "You select $work_disk"
    echo ""
    read -n1 -r -p "Continue ? (y/n): " key_continue
    echo ""
    if [ "$key_continue" = 'y' ] || [ "$key_continue" = 'Y' ]
      then
        echo ""
        echo "=== Start installing ==="
      else
        echo ""
        echo "Abort!"
        echo ""
        exit 1
    fi
  else
    echo ""
    echo "Error, you must select number betwen 0 and 9"
    exit 1
fi

echo ""

echo "=== Update package list ==="
sudo apt-get update
echo ""
echo "=== Install packages ==="
echo ""
sudo apt-get install --assume-yes debootstrap parted
echo ""

echo "=== Format drive ==="
sudo dd if=/dev/zero of=$work_disk bs=1M count=10
sudo parted $work_disk mktable msdos
sudo parted $work_disk mkpart primary ext4 0% 100%
sudo parted $work_disk set 1 boot on
sudo mkfs.ext4 "$work_disk"1

echo ""


echo "=== Mount disk ==="
echo ""
sudo mount "$work_disk"1 /mnt
echo ""

echo "=== Download base system ==="
echo ""
sudo debootstrap --arch $debian_arch $debian_release /mnt $debian_mirror
echo ""

echo "=== Mount dev, sys and proc ==="
sudo mount --bind /dev /mnt/dev
sudo mount --bind /proc /mnt/proc
sudo mount --bind /sys /mnt/sys
echo ""


echo "=== Work in chroot ==="
echo ""
sudo chroot /mnt apt-get update
echo ""

echo "=== Install salt master ==="
sudo chroot /mnt apt-get install --assume-yes salt-master salt-minion git openssh-server sudo
echo ""

# ------------------------------------
echo "=== Apply salt master config ==="
echo ""
sudo cat <<EOT > /mnt/etc/salt/master.d/interface.conf
interface: $server_ip
EOT

sudo cat <<EOT > /mnt/etc/salt/master.d/roots.conf
file_roots:
  base:
    - /srv/salt/states

pillar_roots:
  base:
    - /srv/salt/pillars
EOT

sudo cat <<EOT > /mnt/etc/salt/minion_id
$server_id
EOT

sudo cat <<EOT >> /mnt/etc/hosts
  
$server_ip salt
EOT

chroot /mnt mkdir -p /srv/salt/states
chroot /mnt mkdir -p /srv/salt/pillars

# ------------------------------------

echo "=== Add important configs ==="
echo ""
# get first network interface name
network_interface=$(ip a | grep enp | grep default | cut -f 2 -d ' ' | cut -f 1 -d ':' | head -n 1)

sudo cat <<EOT > /mnt/etc/network/interfaces.d/lo
# loopback network interface
auto lo
iface lo inet loopback
EOT

sudo cat <<EOT > /mnt/etc/network/interfaces.d/$network_interface
# main network interface
auto $network_interface
allow-hotplug $network_interface
iface $network_interface inet dhcp
EOT

# get disk UUID
disk_uuid=$(blkid "$work_disk"1 | cut -f 2 -d " " | tr -d '"')
sudo cat <<EOT > /mnt/etc/fstab
# root
$disk_uuid / ext4 errors=remount-ro 0 1
EOT


sudo cat <<EOT > /mnt/etc/hostname
$server_name
EOT

# ---------------------------------------

echo "==== Create user ===="
echo ""
sudo chroot /mnt useradd -p $user_password $user_name

# ---------------------------------------

echo "=== Create git repo for salt ==="
echo ""
sudo chroot /mnt useradd git
sudo mkdir /mnt/srv/git
sudo chroot /mnt chown -R git: /srv/git/

sudo mkdir /mnt/srv/git/states.git
sudo mkdir /mnt/srv/git/pillars.git
sudo chroot /mnt chown -R git: /srv/git/states.git
sudo chroot /mnt chown -R git: /srv/git/pillars.git
sudo chroot /mnt git init --bare /srv/git/states.git
sudo chroot /mnt git init --bare /srv/git/pillars.git

# create hook to fetch new configs after commit
sudo cat <<EOT > /mnt/srv/git/states.git/hooks/post-receive
#!/bin/bash

TRAGET="/srv/salt/states"
GIT_DIR="/srv/git/states.git"
BRANCH="master"

while read oldrev newrev ref
do
    # only checking out the master (or whatever branch you would like to deploy)
    if [[ \$ref = refs/heads/\$BRANCH ]];
    then
        echo "Ref \$ref received. Deploying \${BRANCH} branch to production..."
        git --work-tree=\$TRAGET --git-dir=\$GIT_DIR checkout -f
    else
        echo "Ref \$ref received. Doing nothing: only the \${BRANCH} branch may be deployed on this server."
    fi
done
EOT

sudo cat <<EOT > /mnt/srv/git/pillars.git/hooks/post-receive
#!/bin/bash

TRAGET="/srv/salt/pillars"
GIT_DIR="/srv/git/pillars.git"
BRANCH="master"

while read oldrev newrev ref
do
    # only checking out the master (or whatever branch you would like to deploy)
    if [[ \$ref = refs/heads/\$BRANCH ]];
    then
        echo "Ref \$ref received. Deploying \${BRANCH} branch to production..."
        git --work-tree=\$TRAGET --git-dir=\$GIT_DIR checkout -f
    else
        echo "Ref \$ref received. Doing nothing: only the \${BRANCH} branch may be deployed on this server."
    fi
done
EOT

sudo chroot /mnt chmod +x /srv/git/states.git/hooks/post-receive
sudo chroot /mnt chmod +x /srv/git/pillars.git/hooks/post-receive

sudo chroot /mnt chown -R git: /srv/git
sudo chroot /mnt chown -R git: /srv/salt

# -------------------------------------------

echo ""
echo "=== Add user pub key ==="
sudo mkdir -p /mnt/home/$user_name/.ssh
sudo cat <<EOT > /mnt/home/$user_name/.ssh/authorized_keys
# $user_name key
$user_pub_key
EOT
sudo chroot /mnt chown -R $user_name: /home/$user_name

sudo mkdir -p /mnt/home/git/.ssh
sudo cat <<EOT > /mnt/home/git/.ssh/authorized_keys
# $user_name key
$user_pub_key
EOT
sudo chroot /mnt chown -R git: /home/git

sudo cat <<EOT > /mnt/etc/sudoers.d/$user_name
$user_name ALL=(ALL) NOPASSWD: ALL
EOT

# ------------------------------------

echo ""
echo "=== Install kernel ==="
sudo chroot /mnt apt-get install --assume-yes linux-image-686-pae
echo ""

echo "=== Install grub ==="
sudo chroot /mnt apt-get install --assume-yes grub2
#sudo chroot /mnt grub-install --target=i386-pc --boot-directory="/boot" $work_disk 
echo ""

echo "=== Update system ==="
sudo chroot /mnt apt-get update --assume-yes
sudo chroot /mnt apt-get dist-upgrade --assume-yes


# -------------------------------------------

echo ""
echo "=== Umount chroot ==="

sudo umount -l /mnt/proc
sudo umount -l /mnt/dev
sudo umount -l /mnt/sys
sudo umount -l /mnt

# ------------------------------------------

echo "=== Create repo on other PC ==="
echo ""
echo "mkdir -p ~/my_projects/git/salt/states"
echo "mkdir -p ~/my_projects/git/salt/pillars"

echo "git -C ~/my_projects/git/salt/states init ~/my_projects/git/salt/states"
echo "git -C ~/my_projects/git/salt/pillars init ~/my_projects/git/salt/pillars"

echo "touch ~/my_projects/git/salt/states/readme.md"
echo "touch ~/my_projects/git/salt/pillars/readme.md"

echo "git -C ~/my_projects/git/salt/states add ~/my_projects/git/salt/states/readme.md"
echo "git -C ~/my_projects/git/salt/pillars add ~/my_projects/git/salt/pillars/readme.md"

echo "git -C ~/my_projects/git/salt/states commit -m 'init commit'"
echo "git -C ~/my_projects/git/salt/pillars commit -m 'init commit'"

echo "git -C ~/my_projects/git/salt/states remote add origin git@$server_name:/srv/git/states.git"
echo "git -C ~/my_projects/git/salt/pillars remote add origin git@$server_name:/srv/git/pillars.git"

echo "git -C ~/my_projects/git/salt/states push --set-upstream origin master"
echo "git -C ~/my_projects/git/salt/pillars push --set-upstream origin master"

echo ""
echo ""
echo "=== Bootstrap DONE! ==="
echo ""

exit 0
