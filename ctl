#!/bin/sh

VERSION="v4"

BIN="bin"
PORT=12345
URL="http://127.0.0.1:$PORT"

YACC_FLAGS="-DYYERROR_VERBOSE" # for bison
WARN="-W -Wall -Wextra -Wredundant-decls -Wno-unused"
LINK=""
CC="gcc -g -std=c99 $WARN $YACC_FLAGS"
YACC="yacc -d"
LEX="flex -I"

LIBS="array% expression% head% http% index% memory% pack% relation%"
LIBS="$LIBS string% summary% tuple% transaction% value% version% volume%"
LIBS="$LIBS test/common% lex.yy% y.tab%"
STRUCT_TESTS="test/array% test/expression% test/head% test/http% test/index%"
STRUCT_TESTS="$STRUCT_TESTS test/language% test/list% test/memory%"
STRUCT_TESTS="$STRUCT_TESTS test/multiproc% test/network% test/number%"
STRUCT_TESTS="$STRUCT_TESTS test/pack% test/relation% test/string%"
STRUCT_TESTS="$STRUCT_TESTS test/summary% test/system% test/tuple%"
STRUCT_TESTS="$STRUCT_TESTS test/transaction% test/value%"
PERF_TESTS="test/perf/append% test/perf/expression% test/perf/index%"
PERF_TESTS="$PERF_TESTS test/perf/multiproc% test/perf/number%"
PERF_TESTS="$PERF_TESTS test/perf/relation% test/perf/system% test/perf/tuple%"
PROGS="bandicoot%"

if [ ! "`uname | grep -i CYGWIN`" = "" ]
then
    LIBS="$LIBS system_win32%"
    LINK="-lws2_32"
else
    LIBS="$LIBS system_posix%"
    if [ `uname` = "SunOS" ]
    then
        LINK="-lnsl -lsocket"
    elif [ `uname` = "Linux" ]
    then
        CC="$CC -pthread"
    fi
fi

ALL_VARS=`ls test/data`

create_out_dirs()
{
    mkdir -p "$BIN/test/perf"
    mkdir -p "$BIN/volume"
    mkdir -p "$BIN/test/lsdir/one_dir"
}

prepare_lang()
{
    $YACC language.y
    $LEX language.l
}

prepare_version()
{
    cat > version.c << EOF
const char *VERSION =
    "[bandicoot $VERSION, http://bandilab.org, built on `date -u`]\n";
EOF
}

compile()
{
    create_out_dirs
    prepare_lang
    prepare_version

    for i in `echo $* | sed 's/%//g'`
    do
        echo "[C] $i.o"
        $CC $DIST_CFLAGS -c -o $i.o $i.c
        if [ "$?" != "0" ]
        then
            echo "error: compilation failed."
            exit 1
        fi
    done
}

link()
{
    libs=`echo $LIBS | sed 's/%/.o/g'`
    for obj in `echo $* | sed 's/%/.o/g'`
    do
        e=`echo $BIN/$obj | sed 's/\.o//g'`
        echo "[L] $e"
        $CC $DIST_CFLAGS -o $e $libs $obj $LINK
        if [ "$?" != "0" ]
        then
            echo "error: ld failed."
            exit 1
        fi
    done
}

run()
{
    for e in `echo $* | sed 's/%//g'`
    do
        echo "[T] $e"
        $BIN/$e
        if [ "$?" != "0" ]
        then
            echo "error: test failed."
        fi
    done
}

clean()
{
    find . -name '*.o' -exec rm {} \;
    find . -name '*.log' -exec rm {} \;
    rm -rf version.c y.tab.[ch] lex.yy.c $BIN
    rm -rf "bandicoot-$VERSION"
}

dist()
{
    DIST_CFLAGS=$1

    clean
    compile $LIBS $PROGS
    echo
    link $PROGS
    echo

    d="bandicoot-$VERSION"
    mkdir -p $d

    cp LICENSE NOTICE README $BIN/bandicoot* $d
    if [ -d "$2" ]
    then
        echo "including examples directory $2"
        cp -r $2 $d
    fi

    a="$BIN/$d.tar.gz"
    echo "[A] $a"
    tar cfz $a $d
}

cmd=$1
case $cmd in
    clean)
        clean
        ;;
    pack)
        clean
        compile $LIBS $PROGS $STRUCT_TESTS $PERF_TESTS
        echo
        link $PROGS $STRUCT_TESTS $PERF_TESTS
        echo
        echo "[P] preparing test data"
        $BIN/bandicoot start -c "test/test_defs.b" \
                             -d $BIN/volume \
                             -s $BIN/state \
                             -p $PORT &
        pid=$!

        # we need to finish the initialization
        # before we start storing the variables
        sleep 1

        for v in $ALL_VARS
        do
            curl -s $URL/load_$v > /dev/null
            curl -s --data-binary @test/data/$v $URL/store_$v
            curl -s $URL/load_$v > /dev/null
        done
        kill $pid
        ;;
    perf)
        run $PERF_TESTS 
        ;;
    stress_read)
        while [ true ]
        do
            for v in $ALL_VARS
            do
                curl -s $URL/load_$v -o /dev/null
                if [ "$?" != "0" ]
                then
                    exit
                fi
            done
        done
        ;;
    stress_write)
        while [ true ]
        do
            for v in $ALL_VARS
            do
                curl -s --data-binary @test/data/$v $URL/store_$v > /dev/null
                if [ "$?" != "0" ]
                then
                    exit
                fi
            done
        done
        ;;
    test)
        run $STRUCT_TESTS
        cat test/progs/*.log | sort > bin/lang_test.out
        cat test/progs/all.out | sort > bin/all_sorted.out
        diff -u bin/all_sorted.out bin/lang_test.out
        if [ "$?" != "0" ]
        then
            echo "error: language test failed (inspect the diff above)"
            exit 1
        fi
        ;;
    todos)
        find . -regex '.*\.[chly]' -exec egrep -n -H -i 'fixme|todo|think' {} \;
        ;;
    dist)
        if [ "$2" != "-m32" ] && [ "$2" != "-m64" ]
        then
            echo "error: dist expects either -m32 or -m64 parameter"
            exit 1
        fi

        dist "-Os $2" $3
        ;;
    start)
        $BIN/bandicoot start -c "test/test_defs.b" \
                             -d $BIN/volume \
                             -s $BIN/state \
                             -p $PORT
        ;;
    *)
        echo "unknown command '$cmd', usage: ctl <command>"
        echo "    dist -m32|-m64 [examles/] - build a package for distribution"
        echo "    pack - compile and prepare for running tests"
        echo "    test - execute structured tests (prereq: pack)"
        echo "    perf - execute performance tests (prereq: pack)"
        echo "    start - start-up a bandicoot test instance"
        echo "    stress_read - read stress tests (prereq: start)"
        echo "    stress_write - write stress tests (prereq: start)"
        echo "    clean - remove object files etc."
esac
