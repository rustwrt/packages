"""Lifecycle hooks shared by direct IPK builders."""
POSTINST = """#!/bin/sh
[ -n "$IPKG_INSTROOT" ] && exit 0
chmod 600 /etc/config/sponsorblocktv 2>/dev/null || :
/usr/sbin/sponsorblocktv-merge-config || logger -t sponsorblocktv 'Configuration merge skipped; existing configuration retained'
/etc/init.d/sponsorblocktv enable >/dev/null 2>&1 || :
if [ -f /tmp/sponsorblocktv-was-running ] || [ "$(uci -q get sponsorblocktv.main.enabled)" = 1 ]; then
    /etc/init.d/sponsorblocktv start || logger -t sponsorblocktv 'Start after installation failed'
fi
rm -f /tmp/sponsorblocktv-was-running
exit 0
"""
PRERM = """#!/bin/sh
[ -n "$IPKG_INSTROOT" ] && exit 0
if [ "$1" = upgrade ] && /etc/init.d/sponsorblocktv running; then
    (umask 077; touch /tmp/sponsorblocktv-was-running)
fi
/etc/init.d/sponsorblocktv stop >/dev/null 2>&1 || :
/etc/init.d/sponsorblocktv disable >/dev/null 2>&1 || :
exit 0
"""
