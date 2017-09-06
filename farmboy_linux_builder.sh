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

# Disable root login
passwd -R /mnt -l root

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

run cat \>usr/share/libalpm/hooks/confmerge <<EOS
[Trigger]
Operation = Upgrade
Type = File
Target = etc/*
Target = etc/*/*
Target = etc/*/*/*
Target = etc/*/*/*/*
Target = etc/*/*/*/*/*
Target = usr/share/applications/*

[Action]
Description = Merging of configuration files
When = PostTransaction
Exec = /usr/local/sbin/confmerge
NeedsTargets
EOS

run cat \>usr/local/sbin/confmerge <<'EOS'
#!/bin/sh
# Try to automatically update configuration after an upgrade.

# Extension used for back-up copies of default configuration files
# ("original" files). Must match the one used during system
# installation and configuration.
ORIG="bak-default"

# Extensione used for new versions of modified configuration files.
NEW="pacnew"

# diff(1) additional options. They help to reduce patch sizes.
# The most useful in this context are:
# -a  --text
#        Treat all files as text.
# -b  --ignore-space-change
#        Ignore changes in the amount of white space.
# -B  --ignore-blank-lines
#        Ignore changes whose lines are all blank.
# -i  --ignore-case
#        Ignore case differences in file contents.
DIFFOPTS="-abB"

PATCHOPTS="-Nsp0"

echoerr() { >&2 echo "$0: $@"; }

PATCH=$(mktemp -t sysupgrade_patch.XXXXXXXXXX) || exit 1
trap "rm -f $PATCHFILE; exit 1" HUP INT QUIT TERM EXIT

cd /

# Try to merge a modified old and default new configuration file.
merge_file() {
  # Ignore already merged files.
  if [ -f "$file.$NEW" ]; then
    if [ -f "$1.$ORIG" ]; then
      # Capture edits made in a patch file.
      diff $DIFFOPTS -u "$1.$ORIG" "$1" >$PATCH

      # Test whether the patch applies on the new
      # default configuration file with no errors.
      if patch --dry-run $PATCHOPTS "$1.$NEW" <$PATCH >/dev/null; then
        # Install the new default file.
        mv "$1.$NEW" "$1.$ORIG"

        # Make a copy of it...
        cp "$1.$ORIG" "$1"
        # ... and patch it to redo the user's edits.
        patch $PATCHOPTS "$1" <$PATCH
        # Remove pesky patch backup files.
        rm -f "$1~"
      else
        echoerr "warning: merging of \`$file' and \`$file.$ORIG' failed; \`$file.$NEW' has been left in place. Check for conflicts and merge manually."
      fi
    else
      # Original missing... can't merge.
      # Install the new file as the new default anyway.
      mv "$file.$NEW" "$file.$ORIG"

      echoerr "warning: original version of \`$file.$ORIG' was missing and has been created. Manually check the differences with \`$file', which may be obsolete and not work."
    fi
  fi
}

while IFS= read -r file; do
  # Ignore directories.
  if [ -f "$file" ]; then
    merge_file "$file"
  fi
done
EOS
run chmod +x usr/local/sbin/confmerge

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
  git abs yaourt vim alsa-utils unrar timidity++ soundfont-fluid \
  qrencode tlp ethtool

run arch-chroot /mnt <<EOS
systemctl enable tlp tlp-sleep
systemctl mask systemd-rfkill.service systemd-rfkill.socket
systemctl enable NetworkManager-dispatcher.service
EOS

if [ "$LAMP" = true ]; then
  run pacman-chroot -S apache php php-apache mariadb
  run chmod o+x 'home/$FIRSTUSER'
  run mkdir 'home/$FIRSTUSER/public_html'
  run chown '$FIRSTUSER:$FIRSTUSER' 'home/$FIRSTUSER/public_html'
  run chmod o+rx 'home/$FIRSTUSER/public_html'
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

if [ "$VIRTUALBOX" = true ]; then
  if [ "$LTSKERNEL" = true ]; then
    run pacman-chroot -S virtualbox virtualbox-host-dkms linux-lts-headers
  else
    run pacman-chroot -S virtualbox virtualbox-host-modules-arch
  fi
fi

msg 'Installing the GUI (please wait)...'
pacman-cleanup
# Note: needed packages should be listed explicitely even if they are
# dependencies of other packages, so that they won't be removed by a
# recursive removal of the the latter
run pacman-chroot -Sy xorg-server xorg-drivers lightdm lightdm-gtk-greeter \
  ttf-dejavu artwiz-fonts openbox pcmanfm-gtk3 lilyterm '$BROWSER' \
  asunder filezilla galculator gimp gmrun gnome-keyring gnome-mplayer \
  gnumeric guvcview networkmanager network-manager-applet tint2 \
  usb_modeswitch modemmanager obconf openbox-menu gnome-icon-theme \
  transmission-gtk xsane viewnior xarchiver xdotool xfce4-notifyd \
  xpdf gvfs xorg-xhost xorg-xprop imagemagick gnome-alsamixer \
  volumeicon lxappearance-obconf lxinput xfce4-notes-plugin xorg-xrandr \
  accountsservice gksu libreoffice-still calibre lxsession-gtk3

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

if [ "$THEMES" = true ]; then
  run pacman-chroot -S openbox-themes numix-gtk-theme adapta-gtk-theme \
    gtk-engine-murrine noto-fonts ttf-roboto arc-gtk-theme arc-icon-theme \
    gnome-themes-standard arc-solid-gtk-theme deepin-gtk-theme \
    gtk-theme-overglossed-hybrid gtk-theme-slickness
fi

pacman-chroot -S aspell-$LANGCODE 2>/dev/null
pacman-cleanup

msg 'Configuring the GUI...'

# Set gksu to use sudo by default
# since the root account is disabled
run arch-chroot /mnt <<EOS
su - '$FIRSTUSER' -c 'gconftool-2 --set --type boolean /apps/gksu/sudo-mode true'
EOS

bak etc/conf.d/wireless-regdom
run ed etc/conf.d/wireless-regdom <<EOS
,s/^#\(WIRELESS_REGDOM="IT"\)/\1/
wq
EOS

bak etc/lightdm/lightdm.conf
run ed etc/lightdm/lightdm.conf <<EOS
,s/^#\(pam-service=lightdm\)/\1/
,s/^#\(pam-autologin-service=lightdm-autologin\)/\1/
,s/^#\(autologin-user=\)/\1$FIRSTUSER/
,s/^#\(autologin-user-timeout=0\)/\1/
wq
EOS
run groupadd -R /mnt -r autologin
run useradd -R /mnt -m -G wheel,audio,autologin,optical,vboxusers '$FIRSTUSER'
run chpasswd -R /mnt <<<"$FIRSTUSER:$FIRSTUSERPWD" -
bak etc/pam.d/lightdm
run ed etc/pam.d/lightdm <<EOS
2i
auth        sufficient  pam_succeed_if.so user ingroup nopasswdlogin
.
wq
EOS
run groupadd -R /mnt -r nopasswdlogin
# Skipped, because we want the screen locker to ask for a password,
# so we only configured nopasswdlogin but did not enable it
#run gpasswd -Q /mnt -a '$FIRSTUSER' nopasswdlogin
run arch-chroot /mnt <<EOS
systemctl enable lightdm NetworkManager ModemManager
EOS

bak etc/lightdm/lightdm-gtk-greeter.conf
run ed etc/lightdm/lightdm-gtk-greeter.conf <<EOS
,s/^#\(background=\)/\1\/usr\/share\/pixmaps\/farmboy_linux.jpg/
wq
EOS
cd -
run cp farmboy_linux.jpg /mnt/usr/share/pixmaps/
cd -

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
application/vnd.openxmlformats-officedocument.wordprocessingml.document=libreoffice-writer.desktop
audio/mpeg=gnome-mplayer.desktop
audio/ogg=gnome-mplayer.desktop
image/gif=viewnior.desktop
image/jpeg=viewnior.desktop
image/png=viewnior.desktop
text/plain=mousepad.desktop
Video/mp4=gnome-mplayer.desktop
video/ogg=gnome-mplayer.desktop
video/x-flv=gnome-mplayer.desktop
video/x-matroska=gnome-mplayer.desktop
video/x-msvideo=gnome-mplayer.desktop
EOS

run mkdir etc/skel/.config/volumeicon
run cat\>etc/skel/.config/volumeicon/volumeicon <<EOS
[Alsa]
card=default

[Notification]
show_notification=true
notification_type=0

[StatusIcon]
stepsize=5
onclick=gnome-alsamixer
theme=Default
use_panel_specific_icons=false
lmb_slider=true
mmb_mute=false
use_horizontal_slider=false
show_sound_level=false
use_transparent_background=false

[Hotkeys]
up_enabled=false
down_enabled=false
mute_enabled=false
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
/usr/bin/volumeicon &
/usr/bin/udiskie --tray &
/usr/bin/xfce4-notes &
/usr/bin/tint2 &
/usr/bin/light-locker &
/usr/bin/lxsession &
/usr/bin/pamac-tray &
#/usr/bin/lilyterm &
/usr/bin/$BROWSER &
EOS

# Disable automount in pcmanfm since it is done by udiskie
bak etc/xdg/pcmanfm/default/pcmanfm.conf
run ed etc/xdg/pcmanfm/default/pcmanfm.conf <<EOS
,s/^\(mount_on_startup\)=1/\1=0/
,s/^\(mount_removable\)=1/\1=0/
wq
EOS

bak etc/xdg/openbox/rc.xml
run ed etc/xdg/openbox/rc.xml <<EOS
,s/<followMouse>no</<followMouse>yes</
,s/<titleLayout>NLIMC</<titleLayout>NLSDIMC</
/<font place="MenuItem">
/<size>9<
s/9/18/
,s/<number>4</<number>1</
,s/<drawContents>yes</<drawContents>no</
,s/<popupShow>Nonpixel</<popupShow>Always<
,s/<name>Konqueror</<name>PCManFM</
,s/<command>kfmclient openProfile filemanagement</<command>pcmanfm</

/<\/chainQuitKey>/a

  <keybind key="XF86AudioRaiseVolume">
    <action name="Execute">
      <command>amixer set Master 5%+ unmute</command>
    </action>
  </keybind>
  <keybind key="XF86AudioLowerVolume">
    <action name="Execute">
      <command>amixer set  Master 5%- unmute</command>
    </action>
  </keybind>
  <keybind key="XF86AudioMute">
    <action name="Execute">
      <command>amixer set Master toggle</command>
    </action>
  </keybind>
  <keybind key="C-Print">
    <action name="Execute">
      <command>sh -c "import -window root ~/Desktop/ss_`date '+%Y%m%d-%H%M%S'`.png"</command>
    </action>
  </keybind>
  <keybind key="A-Print">
    <action name="Execute">
      <command>/usr/local/bin/winscreenshot</command>
    </action>
  </keybind>
  <keybind key="Super-space">
    <action name="ShowMenu">
      <menu>root-menu</menu>
    </action>
  </keybind>
  <!-- Keybinding for running a run dialog box -->
  <keybind key="A-F2">
    <action name="execute">
      <execute>gmrun</execute>
    </action>
  </keybind>
  <keybind key="XF86PowerOff">
    <action name="ShowMenu">
      <execute>exit-menu</execute>
    </action>
  </keybind>
  <!-- Keybinding for turning off screen with shortcut -->
  <keybind key="W-l">
      <action name="Execute">
          <command>/usr/local/bin/blankscreen</command>
      </action>
  </keybind>
.
wq
EOS

run cat \>usr/local/bin/winscreenshot <<'EOS'
#!/bin/sh
# Requires: xorg-xprop for xprop, imagemagick for import
# See: https://wiki.archlinux.org/index.php/Taking_a_Screenshot#Screenshot_of_the_active.2Ffocused_window
activeWinLine=$(xprop -root | grep '_NET_ACTIVE_WINDOW(WINDOW)')
activeWinId=${activeWinLine:40}
import -border -window $activeWinId ~/Desktop/ss_$(date +%F_%H%M%S_%N).png

# Or number files and save in home directory:
#numfiles=$(ls -1 [0-9]*.png 2>/dev/null | wc -l)
#((numfiles++))
#import -frame -window "$activeWinId" $numfiles.png
EOS
run chmod +x usr/local/bin/winscreenshot

run cat \>usr/local/bin/blankscreen <<EOS
#!/bin/bash
# http://superuser.com/questions/374637/linux-how-to-turn-off-screen-with-shortcut

# Without sleeping, remnants of the last keyboard activity
# (I guess) sometimes turns the screen back on immediately
sleep 1; xset dpms force off
EOS
run chmod +x usr/local/bin/blankscreen

run cat \>usr/share/applications/showdesktop.desktop <<EOS
[Desktop Entry]
Name=Show Desktop
GenericName=Minimizer
Icon=user-desktop
Exec=xdotool key super+d
Terminal=false
Type=Application
StartupNotify=false
NoDisplay=true
EOS

bak etc/xdg/openbox/menu.xml
run cat \>etc/xdg/openbox/menu.xml <<EOS
<?xml version="1.0" encoding="UTF-8"?>

<openbox_menu xmlns="http://openbox.org/3.4/menu">

<menu id="desktop-app-menu" label="Applications"
  execute="/usr/bin/openbox-menu lxde-applications.menu" />

<menu id="exit-menu" label="Quit">
  <item label="Suspend" icon="/usr/share/icons/gnome/16x16/actions/xfce-system-exit.png">
    <action name="Execute">
      <command>systemctl suspend</command>
    </action>
  </item>
  <item label="Hibernate" icon="/usr/share/icons/gnome/16x16/actions/xfce-system-lock.png">
    <action name="Execute">
      <command>systemctl hibernate</command>
    </action>
  </item>
  <item label="Lock Screen" icon="/usr/share/icons/gnome/16x16/actions/xfce-system-lock.png">
    <action name="Execute">
      <command>light-locker-command -l</command>
    </action>
  </item>
  <item label="Log Out" icon="/usr/share/icons/gnome/16x16/actions/system-log-out.png">
    <action name="Exit">
      <prompt>Are you sure you want to exit and login again?</prompt>
    </action>
  </item>
  <item label="Restart" icon="/usr/share/icons/gnome/16x16/actions/redo.png">
    <action name="Execute">
      <command>systemctl reboot</command>
      <prompt>Are you sure you want to reboot your computer?</prompt>
    </action>
  </item>
  <item label="Power Off" icon="/usr/share/icons/gnome/16x16/actions/system-shutdown.png">
    <action name="Execute">
      <command>systemctl poweroff</command>
      <prompt>Are you sure you want to shut your computer down?</prompt>
    </action>
  </item>
</menu>

<menu id="system-menu" label="System">
  <item label="Window Manager Configuration">
    <action name="Execute">
      <command>obconf</command>
      <startupnotify><enabled>yes</enabled></startupnotify>
    </action>
  </item>
  <item label="Reload Window Manager Conf">
    <action name="Reconfigure" />
  </item>
  <separator />
  <item label="Run program" icon="/usr/share/icons/gnome/16x16/actions/system-run.png">
    <action name="Execute">
      <command>gmrun</command>
    </action>
  </item>
  <item label="Manage Printers">
    <action name="Execute">
      <command>xdg-open http://localhost:631/</command>
      <startupnotify>
        <enabled>no</enabled>
        <icon>cups</icon>
      </startupnotify>
    </action>
  </item>
</menu>

<menu id="root-menu" label="Openbox 3">
  <menu id="desktop-app-menu"/>
  <separator />
  <menu id="client-list-menu"/>
  <menu id="system-menu"/>
  <separator />
  <item label="Online support   " icon="/usr/share/icons/gnome/16x16/emblems/emblem-web.png">
    <action name="Execute">
      <command>xdg-open http://www.farmboylinux.com</command>
    </action>
  </item>
  <separator />
  <menu id="exit-menu" />
</menu>

</openbox_menu>
EOS

run cat \>usr/share/applications/startmenu.desktop <<EOS
[Desktop Entry]
Name=Open AppMenu
GenericName=Start menu
Icon=open-menu-symbolic
Exec=xdotool key super+space
Terminal=false
Type=Application
StartupNotify=false
NoDisplay=true
EOS

bak etc/xdg/tint2/tint2rc
run ed etc/xdg/tint2/tint2rc <<EOS
,s/\(border_width =\) 0/\1 1/
,s/\(panel_items = LTS\)C/\1BC/
,s/\(autohide_show_timeout =\) 0/\1 0.3/
,s/\(autohide_hide_timeout =\) 0.5/\1 2/
,s/\(taskbar_name =\) 1/\1 0/
,s/\(urgent_nb_of_blink =\) 100000/\1 8/
,s/\(systray_padding =\) 0 4 2/\1 0 0 2/
,s/\(launcher_item_app = \/usr\/share\/applications\/tint2conf.desktop\)/#\1/
,s/\(launcher_item_app = \/usr\/local\/share\/applications\/tint2conf.desktop\)/#\1/
a
launcher_item_app = /usr/share/applications/startmenu.desktop
launcher_item_app = /usr/share/applications/showdesktop.desktop
.
,s/\(launcher_item_app = \/usr\/local\/share\/applications\/iceweasel.desktop\)/#\1/
,s/\(launcher_item_app = /usr/share/applications/chromium\)-browser.desktop/\1.desktop/
+a
launcher_item_app = /usr/share/applications/opera.desktop
launcher_item_app = /usr/share/applications/pcmanfm.desktop
launcher_item_app = /usr/share/applications/asoundconf-gtk.desktop

.
,s/\(time2_format =\) %A %d %B/\1 %a %d %b/
,s/\(clock_rclick_command =\) orage/\1 osmo/
,s/\(battery_hide =\) 101/\1 98/
wq
EOS

bak usr/share/applications/tint2.desktop
run ed usr/share/applications/tint2.desktop <<EOS
a
NoDisplay=true
.
wq
EOS

run cat \> usr/local/bin/setavatar <<'EOF'
#!/bin/sh
# Sets or change LightDM user avatars. See:
# https://wiki.archlinux.org/index.php/LightDM#Changing_your_avatar
# Deps: ed imagemagick

SELF=$(basename $0)
if [ $# -ne 2 ]; then
  echo "Syntax: $SELF userName iconFile" > /dev/stderr
  exit 1
fi

# check username exists
if ! id $1 >/dev/null 2>&1; then
  echo "$SELF: unexistent user \`$1'" > /dev/stderr
  exit 1
fi

if [ ! -f "$2" ]; then
  echo "$SELF: unexistent avatar file \`$2'" > /dev/stderr
  exit 1
fi

ed /var/lib/AccountsService/users/$1 <<EOS
,g/^Icon=/d
a
Icon=/var/lib/AccountsService/icons/$1
.
wq
EOS

convert "$2" -resize 96x96 png:/var/lib/AccountsService/icons/$1
EOF
run chmod +x usr/local/bin/setavatar

msg 'Building additional packages from source code...'
run arch-chroot /mnt <<EOS
mkdir -p /tmp/aur-builds
cd /tmp/aur-builds
# Add package names to compile here
pkgs=(ttf-ms-fonts asoundconf soundfont-sgm tclreadline glabels-light pamac-aur)
if [ "$TOR" = true ]; then
  # unfortunately localized versions are often old
  pkgs+=(tor-browser-en)
  su - '$FIRSTUSER' -c 'gpg --keyserver pool.sks-keyservers.net --recv-keys D1483FA6C3C07136'
fi
if [ "$BROWSER" = opera ]; then
  pkgs+=(pepper-flash)
fi

for pkg in "\${pkgs[@]}"; do
  curl -sLO "https://aur.archlinux.org/cgit/aur.git/snapshot/\$pkg.tar.gz"
  tar zxf "\$pkg.tar.gz"
  chown -R '$FIRSTUSER' "\$pkg"
  . "\$pkg/PKGBUILD"
  pacman --noconfirm --needed -Sy \${depends[@]} \${makedepends[@]}

  # Build as ordinary user for security
  su - '$FIRSTUSER' <<EOB
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

run cat \> etc/skel/.tclshrc <<EOS
if {$tcl_interactive} {
  package require tclreadline
  ::tclreadline::Loop
}
EOS

cd /
umount /mnt
msg 'Installation ended successfully. Rebooting...'

# Ring the bell repeatedly so to alert user we are almost done
echo -e '\07\07\07\07\07'

reboot

# TODO: consider to switch from pcmanfm to spacefm if you want dvd autoplay
# http://mrbluecoat.blogspot.it/2013/12/auto-play-cds-and-dvds-on-lubuntu-1310.html

# optionals:
# pacmanxg audacity bc bind-tools bluez bluez-utils celestia chromium dos2unix dropbox elinks
# geany geany-plugins gnupg google-talkplugin tor-browser-en
# mlocate networkmanager-openvpn osmo pidgin
# pkgfile rfkill screen sigil simplescreenrecorder skype skype-call-recorder
# stellarium subdownloader syasokoban teamviewer testdisk tidy whois
# wine wine-mono wine_gecko winetricks words youtube-dl wget mkvtoolnix-gui
# mlocate mp3gain mp3info ntfs-3g obexfs pwgen qbittorent musescore soundfont-sgm
# vkeybd vmpk dosfstools mtools dnsutils elinks lxappearance zsh

# php php-apache php-phpdbg phpmyadmin

# optional AUR packages
# ace-of-penguins asoundconf pepper-flash tpad retropong
# retrotetris

# TO BACK UP
#etc/{adjtime,locale.conf,skel/.config/mimeapps.list,NetworkManager/system-connections,X11/xorg.conf.d/{00-keyboard.conf,70-synaptics.conf}}

