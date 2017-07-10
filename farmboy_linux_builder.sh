#!/bin/zsh
# (c) 2017 Antonio Bonifati aka Farmboy
# distributed under the GNU General Public License v3.0

# Sets up Farmboy Linux from Arch Linux standard installation disk.
# Please DOUBLE CHECK the .conf configuration file before running this script.

trap 'exit 1' TERM
export TOP_PID=$$

function msg {
  echo -ne "\n$@"
}

function run {
  echo "# $@" >> "$LOG"
  eval "$@" >> "$LOG" 2>&1
  local ret=$?
  if [ $ret -ne 0 ]; then
    echo -e "$* failed with exit code $ret." >&2
    echo "See log file $LOG." >&2
    echo 'Installation interrupted' >&2
    kill -s TERM $TOP_PID
  fi
}

function bak {
  run cp "$1" "$1.$BAK"
}

function pacman-cleanup {
  run yes \| pacman -r /mnt --cachedir /mnt/var/cache/pacman/pkg -Scc
}

function pacman-chroot {
  pacman -r /mnt --config /mnt/etc/pacman.conf \
    --cachedir /mnt/var/cache/pacman/pkg --hookdir /mnt/etc/pacman.d/hooks \
    --gpgdir /mnt/etc/pacman.d/gnupg --noconfirm "$@"
}

echo 'F A R M B O Y  L I N U X'
echo 'up to date, fast & clean'
echo 'GPL (c) Antonio Bonifati'

msg 'Loading configuration...'
BASE=${0%.*}
. "$BASE.conf"
LANGCODE=${LANG%_*}

LOG="$(readlink -f $BASE.log)"
msg "Logging to $LOG"
: >"$LOG"

msg "Setting $KEYMAP keyboard..."
run loadkeys '$KEYMAP'

msg 'Updating system clock...'
run timedatectl set-ntp true

msg 'Partioning...'
# escape all / for ed, harmless for command line usage
INSTALLDISK="${INSTALLDISK//\//\\\/}"
for n in "$INSTALLDISK"*; do umount $n 2>/dev/null; done
OVERWRITE=$([ "$ALLDISK" = true ] && echo o)
# no more need to make the linux partition bootable, just informative
# so we better do not do it, since there could be another (i.e. windows)
# partition bootable and we cannot have two
run fdisk '$INSTALLDISK' <<EOS
$OVERWRITE
n
p
$INSTALLPART


w
EOS
partprobe 2>/dev/null
run mkfs.ext4 -F '$INSTALLDISK$INSTALLPART'
run mount '$INSTALLDISK$INSTALLPART' /mnt
cd /mnt
SWAPFILE="${SWAPFILE#/}"
run fallocate -l '$(head -n1 /proc/meminfo | awk "{ print \$2 }")K' '$SWAPFILE'
run chmod 600 '$SWAPFILE'
run mkswap '$SWAPFILE'
run swapon '$SWAPFILE'

msg 'Installing the base system (please wait)...'
run pacstrap /mnt base base-devel
run pacman --noconfirm -Sy ed os-prober

if [ "$LTSKERNEL" = true ]; then
  run pacman-chroot -Sy linux-lts
  run pacman-chroot -R linux
fi 

msg 'Configuring the base system...'

bak etc/fstab
run genfstab -U /mnt '>>' etc/fstab
run ed etc/fstab <<EOS
,s/^\/mnt//
,s/relatime/noatime/g
wq
EOS

run ln -sf ../usr/share/zoneinfo/'$TIMEZONE' etc/localtime
run hwclock --systohc
run arch-chroot /mnt <<EOS
systemctl enable systemd-timesyncd.service
EOS

bak etc/locale.gen
run ed etc/locale.gen <<EOS
,s/^#\($LOCALES\)/\1/
wq
EOS
run arch-chroot /mnt <<EOS
locale-gen
EOS

run echo LANG='$LANG' \>etc/locale.conf
run echo KEYMAP='$KEYMAP' \>etc/vconsole.conf
run echo '$HOSTNAME' \>etc/hostname

run pacman-chroot -Sy intel-ucode grub os-prober

RESUME_OFFSET=$(filefrag -v $SWAPFILE | awk 'NR == 4 { print $4+0 }')
bak etc/default/grub
run ed etc/default/grub <<EOS
,s/^\(GRUB_CMDLINE_LINUX_DEFAULT="quiet\)/\1 resume=$INSTALLDISK$INSTALLPART resume_offset=$RESUME_OFFSET/
,s/^\(GRUB_TIMEOUT=\)5/\1$GRUB_TIMEOUT/
wq
EOS

# GRUB searcher has issues finding ext* partitions after a large NTFS partition
# See: https://bbs.archlinux.org/viewtopic.php?id=169650
run grub-install --boot-directory=/mnt/boot --target=i386-pc --disk-module=native '${INSTALLDISK}'
run arch-chroot /mnt <<EOS
grub-mkconfig -o /boot/grub/grub.cfg
EOS

bak etc/bash.bashrc
run cat '>>' etc/bash.bashrc <<EOS

# Protect against accidentally overwriting/deleting a file.
alias cp='cp -i'
alias mv='mv -i'
alias rm='rm -i'

alias vi=vim
EOS

bak etc/mkinitcpio.conf
run ed etc/mkinitcpio.conf <<EOS
,s/^\(HOOKS="base udev \)/\1resume /
wq
EOS
run arch-chroot /mnt <<EOS
mkinitcpio -p linux
EOS

bak etc/sudoers
run ed etc/sudoers <<EOS
,s/^# \(%wheel ALL=(ALL) ALL\)/\1/
wq
EOS

# Remove pulseaudio, most users do not need to play two audio streams at once.
# Changing default soundcard will be done with asoundconf-gtk. No need for
# pasystray, except for re-routing audio without restarting an application, but
# this most users can do without. Very few ones need network audio as well.
pacman-chroot -R pulseaudio pulseaudio-alsa

msg 'Installing optionals (please wait)...'
pacman-cleanup
 
# this rep provides yaourt but also openbox-menu
bak etc/pacman.conf
run cat '>>' etc/pacman.conf <<EOS
[archlinuxfr]
SigLevel = Never
Server = http://repo.archlinux.fr/\$arch
EOS
run pacman-chroot -Sy crda openssh ed bash-completion zip unzip \
  git abs yaourt vim alsa-utils unrar timidity++ soundfont-fluid

if [ "$LAMP" = true ]; then
  run pacman-chroot -S apache php php-apache mariadb
  run chmod o+x 'home/$NORMALUSER'
  run mkdir 'home/$NORMALUSER/public_html'
  run chown '$NORMALUSER:$NORMALUSER' 'home/$NORMALUSER/public_html'
  run chmod o+rx 'home/$NORMALUSER/public_html'
  bak etc/httpd/conf/httpd.conf
  run ed etc/httpd/conf/httpd.conf <<EOS
,s/^\(LoadModule mpm_event_module modules\/mod_mpm_event\.so\)/#\1/
,s/^#\(LoadModule mpm_prefork_module modules\/mod_mpm_prefork\.so\)/\1/
/^#LoadModule rewrite_module/
a
LoadModule php7_module modules/libphp7.so
AddHandler php7-script php
.
/^Include conf\/extra\/proxy-html\.conf/

a

Include conf/extra/php7_module.conf
.
wq
EOS

  bak etc/php/php.ini
  run ed etc/php/php.ini <<EOS
,s/^;\(extension=mysqli\.so\)/\1/
,s/^;\(extension=pdo_mysql\.so\)/\1/
wq
EOS

  run arch-chroot /mnt <<EOS
mysql_install_db --user=mysql --basedir=/usr --datadir=/var/lib/mysql
EOS

  run arch-chroot /mnt <<EOS
  systemctl enable httpd mariadb
EOS

  msg 'After first boot, consider running: # mysql_secure_installation'
fi

msg 'Installing the GUI (please wait)...'
pacman-cleanup
run pacman-chroot -Sy xorg-server xorg-drivers lightdm lightdm-gtk-greeter \
  ttf-dejavu artwiz-fonts openbox pcmanfm-gtk3 lilyterm '$BROWSER' abiword \
  asunder filezilla galculator gimp gmrun gnome-keyring gnome-mplayer gnumeric \
  guvcview networkmanager network-manager-applet tint2 usb_modeswitch \
  modemmanager obconf openbox-menu pulseaudio pulseaudio-alsa gnome-icon-theme \
  transmission-gtk pavucontrol xsane viewnior xarchiver xdotool xfce4-notifyd \
  xpdf gvfs xorg-xhost

if [ "$BROWSER" = firefox ]; then
  run pacman-chroot -S firefox-i18n-$LANGCODE thunderbird thunderbird-i18n-$LANGCODE \
    flashplugin
  EMAILCLIENT=thunderbird
elif [ "$BROWSER" = chromium ]; then
  run pacman-chroot --noconfirm -S sylpheed
  EMAILCLIENT=sylpheed
else
  EMAILCLIENT=opera
fi

pacman-chroot -S aspell-$LANGCODE 2>/dev/null
pacman-cleanup

msg 'Configuring the GUI...'

bak etc/conf.d/wireless-regdom
run ed etc/conf.d/wireless-regdom <<EOS
,s/^#\(WIRELESS_REGDOM="IT"\)/\1/
wq
EOS

bak etc/lightdm/lightdm.conf
run ed etc/lightdm/lightdm.conf <<EOS
,s/^#\(pam-service=lightdm\)/\1/
,s/^#\(pam-autologin-service=lightdm-autologin\)/\1/
,s/^#\(autologin-user=\)/\1$NORMALUSER/
,s/^#\(autologin-user-timeout=0\)/\1/
wq
EOS
run groupadd -R /mnt -r autologin
run useradd -R /mnt -m -G wheel,audio,autologin '$NORMALUSER'
# Later we could add the user to group group with:
#run gpasswd -Q /mnt -a '$NORMALUSER' group
bak etc/pam.d/lightdm
run ed etc/pam.d/lightdm <<EOS
2i
auth        sufficient  pam_succeed_if.so user ingroup nopasswdlogin
.
wq
EOS
run groupadd -R /mnt -r nopasswdlogin
run gpasswd -Q /mnt -a '$NORMALUSER' nopasswdlogin
run arch-chroot /mnt <<EOS
systemctl enable lightdm NetworkManager ModemManager
EOS
bak etc/lightdm/lightdm-gtk-greeter.conf
run ed etc/lightdm/lightdm-gtk-greeter.conf <<EOS
,s/^#\(background=\)/\1#82a7d6/
wq
EOS

run cat \>etc/X11/xorg.conf.d/00-keyboard.conf <<EOS
Section "InputClass"
        Identifier "system-keyboard"
        MatchIsKeyboard "on"
        Option "XkbLayout" "$KEYMAP"
EndSection
EOS

run cat \>etc/udev/rules.d/100-dvd.rules <<EOS
# gnome-mplayer and others need a /dev/dvd link
KERNEL=="sr0", SYMLINK+="dvd"
EOS

bak etc/lilyterm.conf
run ed etc/lilyterm.conf <<EOS
,s/^\(font_name = Monospace\) 12/\1 18/
,s/^\(web_browser =\) firefox/\1 $BROWSER/
,s/^\(file_manager =\) firefox/\1 pcmanfm/
,s/^\(ftp_client =\) firefox/\1 filezilla/
,s/^\(email_client =\) thunderbird/\1 $EMAILCLIENT/
wq
EOS

bak etc/timidity++/timidity.cfg
# Highest-quality soundfonts must come last.
run ed etc/timidity++/timidity.cfg << EOS
,s/^# \(soundfont \/usr\/share\/soundfonts\/\)DX7Piano.SF2/\1FluidR3_GM.sf2/
a
soundfont /usr/share/soundfonts/SGM-V2.01.sf2
.
wq
EOS

run mkdir etc/skel/.config
run cat\>etc/skel/.config/mimeapps.list <<EOS
[Default Applications]
application/pdf=xpdf.desktop
image/jpeg=viewnior.desktop
image/png=viewnior.desktop
image/gif=viewnior.desktop
audio/mpeg=gnome-mplayer.desktop
EOS

run cat\>etc/X11/xorg.conf.d/70-synaptics.conf <<EOS
Section "InputClass"
    Identifier "touchpad"
    Driver "synaptics"
    MatchIsTouchpad "on"
        Option "TapButton1" "1"
        Option "TapButton2" "3"
        Option "TapButton3" "2"
        Option "VertEdgeScroll" "on"
        Option "VertTwoFingerScroll" "on"
        Option "HorizEdgeScroll" "on"
        Option "HorizTwoFingerScroll" "on"
        Option "CircularScrolling" "on"
        Option "CircScrollTrigger" "2"
        Option "EmulateTwoFingerMinZ" "40"
        Option "EmulateTwoFingerMinW" "8"
        Option "CoastingSpeed" "0"
        Option "FingerLow" "30"
        Option "FingerHigh" "50"
        Option "MaxTapTime" "125"
EndSection
EOS

bak etc/xdg/openbox/autostart
run cat \>etc/xdg/openbox/autostart <<EOS
/usr/bin/pcmanfm -d --desktop &
/usr/bin/nm-applet &
/usr/bin/tint2 &
/usr/bin/lilyterm &
/usr/bin/$BROWSER &
EOS

msg 'Building additional packages from source code...'
run arch-chroot /mnt <<EOS
mkdir -p /tmp/aur-builds
cd /tmp/aur-builds
# Add package names to compile here
pkgs=(ttf-ms-fonts asoundconf soundfont-sgm)
if [ "$TOR" = true ]; then
  # unfortunately localized versions are often old
  pkgs+=(tor-browser-en)
  su - '$NORMALUSER' -c 'gpg --keyserver pool.sks-keyservers.net --recv-keys D1483FA6C3C07136'
fi
if [ "$BROWSER" = opera ]; then
  pkgs+=(pepper-flash)
fi

for pkg in "\${pkgs[@]}"; do
  curl -sLO "https://aur.archlinux.org/cgit/aur.git/snapshot/\$pkg.tar.gz"
  tar zxf "\$pkg.tar.gz"
  chown -R '$NORMALUSER' "\$pkg"
  . "\$pkg/PKGBUILD"
  pacman --noconfirm --needed -Sy \${depends[@]} \${makedepends[@]}

  # Build as ordinary user for security
  su - '$NORMALUSER' <<EOB
    cd "/tmp/aur-builds/\$pkg"
    makepkg -s
EOB

  # Install as root
  pacman --noconfirm -U "\$pkg/\$pkg-\$pkgver-\$pkgrel-"*.pkg.tar.xz

  # Clean up to free disk space right away
  # although cleaning of /tmp is done by arch-chroot on exit
  rm -fr "\$pkg" "\$pkg.tar.gz"
done
EOS

# Ring the bell repeatedly so to alert user we are almost done
echo -e '\07\07\07\07\07'

# INTERACTIVE STUFF - LEFT AS LAST
msg 'Please set a root (administrator) password.'
msg 'You will have to type it twice and blindly.'
echo
passwd -R /mnt

msg "Please set the normal user $NORMALUSER password."
echo
passwd -R /mnt "$NORMALUSER"

cd /
umount /mnt
read -s '?Installation ended. Press enter to reboot, ctrl-c to stay...'
reboot

# TODO: consider to switch from pcmanfm to spacefm if you want dvd autoplay
# http://mrbluecoat.blogspot.it/2013/12/auto-play-cds-and-dvds-on-lubuntu-1310.html

# optionals:
# pacmanxg audacity bc bind-tools bluez bluez-utils celestia chromium dos2unix dropbox elinks
# geany geany-plugins gnupg google-talkplugin imagemagick tor-browser-en
# mlocate networkmanager-openvpn osmo pidgin
# pkgfile rfkill screen sigil simplescreenrecorder skype skype-call-recorder
# stellarium subdownloader syasokoban teamviewer testdisk tidy whois
# wine wine-mono wine_gecko winetricks words youtube-dl wget mkvtoolnix-gui
# mlocate mp3gain mp3info ntfs-3g obexfs pwgen qbittorent musescore soundfont-sgm
# vkeybd vmpk dosfstools mtools dnsutils elinks lxappearance zsh

# php php-apache php-phpdbg phpmyadmin

# optional AUR packages
# ace-of-penguins asoundconf pepper-flash tpad openbox-menu retropong
# retrotetris

# TO BACK UP
#etc/{adjtime,locale.conf,skel/.config/mimeapps.list,NetworkManager/system-connections,X11/xorg.conf.d/{00-keyboard.conf,70-synaptics.conf}}

