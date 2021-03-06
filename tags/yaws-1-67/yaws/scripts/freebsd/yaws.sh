#! /bin/sh
#
# Startup script for Yaws


YAWS_BIN=%prefix%bin/yaws
YAWS_ID=myserverid
CONF=%etcdir%yaws.conf


if [ "x${YAWS_ID}" = x ]; then
    idarg=""
else
    idarg="--id ${YAWS_ID}"
fi

start() {
    $yaws ${idarg} --daemon --heart --conf ${conf}
}

stop() {
    $yaws ${idarg} --stop 
}

reload() {
    $yaws  ${idarg} --hup
}


status() {
   $yaws ${idarg} --status
}

