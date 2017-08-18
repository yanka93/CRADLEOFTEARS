need to install on clients:

apt-get install libcrypt-cracklib-perl 

to make the dictionary indexes, need to do:

# apt-get install cracklib-runtime wenglish

$ /usr/sbin/crack_mkdict /usr/share/dict/words | /usr/sbin/crack_packer $LJHOME/cgi-bin/cracklib/dict

