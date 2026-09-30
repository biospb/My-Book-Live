#!/bin/sh
# Fix the smbstatus crash of Samba 4.25 on 32-bit Debian (t64): lib/audit_logging json_add_time()
# prints the 64-bit tv_usec with "%06ld" (no (long) cast), the next "%s" then takes half of
# tv_usec as a pointer and smbstatus dies in strlen(). smbd is not affected unless JSON audit
# logging is enabled.
#
# The fix is a same-length patch of that format string ("%06ld" -> "%06Ld", glibc reads "L" as
# "ll" for integers) in a private copy of libcommon-auth-private-samba.so.0, used only by a
# /usr/local/sbin/smbstatus wrapper and only while the packaged library is unchanged: after a
# samba-libs upgrade the wrapper runs the packaged smbstatus again.
#
#   sh install-smbstatus-fix.sh        (as root, on the MBL)
set -e
LIB=/usr/lib/powerpc-linux-gnu/samba/libcommon-auth-private-samba.so.0
FIX=/usr/local/lib/samba-fix

n=$(grep -c -a '%s\.%06ld%s' "$LIB" || true)
[ "$n" = 1 ] || { echo "format string not found exactly once ($n), nothing to do" >&2; exit 1; }

mkdir -p "$FIX"
sed 's/%s\.%06ld%s/%s.%06Ld%s/' "$LIB" > "$FIX/libcommon-auth-private-samba.so.0"
cmp -l "$LIB" "$FIX/libcommon-auth-private-samba.so.0" | wc -l | grep -qx 1 || { echo "patch changed more than one byte" >&2; exit 1; }
md5=$(md5sum < "$LIB" | cut -d' ' -f1)

cat > /usr/local/sbin/smbstatus <<EOF
#!/bin/sh
# smbstatus wrapper, see install-smbstatus-fix.sh in My-Book-Live/debian/samba-fix
LIB=$LIB
ORIG_MD5=$md5
if [ "\$(md5sum < "\$LIB" | cut -d" " -f1)" = "\$ORIG_MD5" ]; then
	LD_LIBRARY_PATH=$FIX\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH} exec /usr/bin/smbstatus "\$@"
fi
echo "smbstatus wrapper: samba-libs changed, running the packaged smbstatus (remove /usr/local/sbin/smbstatus if it works)" >&2
exec /usr/bin/smbstatus "\$@"
EOF
chmod 755 /usr/local/sbin/smbstatus
/usr/local/sbin/smbstatus -b >/dev/null && echo "smbstatus fixed"
